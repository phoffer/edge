module Edge
  module Jungle
    # acts_as_jungle models a tree/multi-tree structure.
    module ActsAsJungle
      # options:
      #
      # * dependent - passed to children has_many (default: none)
      # * foreign_key - column name to use for parent foreign_key (default: parent_id)
      # * order - how to order children (default: none)
      # * optional - passed to belongs_to (default: none)
      def acts_as_jungle(options={})
        options.assert_valid_keys :foreign_key, :order, :dependent, :optional

        class_attribute :jungle_foreign_key
        self.jungle_foreign_key = options[:foreign_key] || "parent_id"

        class_attribute :jungle_order
        self.jungle_order = options[:order] || nil

        common_options = {
          :class_name => self.name,
          :foreign_key => jungle_foreign_key
        }

        dependent_options = options[:dependent] ? { dependent: options[:dependent] } : {}

        optional_options = options[:optional] ? { optional: options[:optional] } : {}

        belongs_to :parent, common_options.merge(inverse_of: :children).merge(optional_options)

        if jungle_order
          has_many :children, -> { order(jungle_order) }, common_options.merge(inverse_of: :parent).merge(dependent_options)
        else
          has_many :children, common_options.merge(inverse_of: :parent).merge(dependent_options)
        end

        scope :root, -> { where(jungle_foreign_key => nil) }

        include Edge::Jungle::InstanceMethods
        extend Edge::Jungle::ClassMethods
      end
    end

    module ClassMethods
      # Finds entire jungle and preloads all associations. It can be used at
      # the end of an ActiveRecord finder chain.
      #
      # Example:
      #    # loads all locations
      #    Location.find_jungle
      #
      #    # loads all nodes with matching names and all there descendants
      #    Category.where(:name => %w{clothing books electronics}).find_jungle
      def find_jungle
        new_scope = unscoped.joins("INNER JOIN all_nodes USING(#{connection.quote_column_name primary_key})")
        new_scope = new_scope.order(jungle_order) if jungle_order

        sql = <<-SQL
          #{cte_sql}
          #{new_scope.to_sql}
        SQL
        records = find_by_sql sql

        records_by_id = records.each_with_object({}) { |r, h| h[r.id] = r }

        # Set all children associations to an empty array
        records.each do |r|
          children_association = r.association(:children)
          children_association.target = []
        end

        top_level_records = []

        records.each do |r|
          parent = records_by_id[r[jungle_foreign_key]]
          if parent
            r.association(:parent).target = parent
            parent.association(:children).target.push(r)
          else
            top_level_records.push(r)
          end
        end

        top_level_records
      end

      # Finds an a tree or trees by id.
      #
      # If any requested ids are not found it raises
      # ActiveRecord::RecordNotFound.
      def find_tree(id_or_ids)
        trees = where(:id => id_or_ids).find_jungle
        if id_or_ids.kind_of?(Array)
          raise ActiveRecord::RecordNotFound unless trees.size == id_or_ids.size
          trees
        else
          raise ActiveRecord::RecordNotFound if trees.empty?
          trees.first
        end
      end

      # Returns a new scope that includes previously scoped records and their descendants by subsuming the previous scope into a subquery
      #
      # Only where scopes can precede this in a scope chain
      def with_descendants
        subquery_scope = unscoped
          .joins("INNER JOIN all_nodes USING(#{connection.quote_column_name primary_key})")
          .select(primary_key)

        subquery_sql = <<-SQL
          #{cte_sql}
          #{subquery_scope.to_sql}
        SQL

        unscoped.where <<-SQL
          #{connection.quote_column_name primary_key} IN (#{subquery_sql})
        SQL
      end

      private
      def cte_sql
        quoted_table_name = '"locations"'
        original_scope = (current_scope || all).select(primary_key, jungle_foreign_key)
        iterated_scope = unscoped.select(primary_key, jungle_foreign_key)
          .joins("INNER JOIN all_nodes ON #{connection.quote_table_name table_name}.#{connection.quote_column_name jungle_foreign_key}=all_nodes.#{connection.quote_column_name primary_key}")
        <<-SQL
          WITH RECURSIVE all_nodes AS (
            #{original_scope.to_sql}
            UNION
            #{iterated_scope.to_sql}
          )
        SQL
      end
    end

    module InstanceMethods
      # Returns the root of this node. If this node is root returns self.
      def root
        parent ? parent.root : self
      end

      # Returns true is this node is a root or false otherwise
      def root?
        !self[jungle_foreign_key]
      end

      # Returns all sibling nodes (nodes that have the same parent). If this
      # node is a root node it returns an empty array.
      def siblings
        parent ? parent.children - [self] : []
      end

      # Returns all ancestors ordered by nearest ancestors first.
      def ancestors
        _ancestors = []
        node = self
        while(node = node.parent)
          _ancestors.push(node)
        end

        _ancestors
      end

      # Returns all descendants
      def descendants
        if children.present?
          children + children.flat_map(&:descendants)
        else
          []
        end
      end
    end
  end
end

ActiveRecord::Base.extend Edge::Jungle::ActsAsJungle
