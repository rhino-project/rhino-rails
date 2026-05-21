# frozen_string_literal: true

module Rhino
  # Format validation concern for models.
  #
  # This concern runs ActiveModel validations on request data before
  # it reaches the database. Field permissions (which fields each role
  # can write) are controlled by the policy, not the model.
  #
  # Also provides cross-tenant FK validation: any belongs_to FK in the
  # submitted data is checked to ensure the referenced record belongs
  # to the current organization (directly or via FK chain).
  #
  # Usage:
  #   class Post < ApplicationRecord
  #     include Rhino::HasValidation
  #
  #     # Standard Rails validations for type/format (use allow_nil: true)
  #     validates :title, length: { maximum: 255 }, allow_nil: true
  #     validates :status, inclusion: { in: %w[draft published] }, allow_nil: true
  #   end
  #
  # Field permissions are defined on the policy:
  #   class PostPolicy < Rhino::ResourcePolicy
  #     def permitted_attributes_for_create(user)
  #       has_role?(user, 'admin') ? ['*'] : ['title', 'content']
  #     end
  #   end
  module HasValidation
    extend ActiveSupport::Concern

    # Validate data for a given action.
    # Filters to only permitted fields, then runs ActiveModel validations
    # and cross-tenant FK validation.
    #
    # @param params [Hash] The request data
    # @param permitted_fields [Array<String>] Fields the user is allowed to set (['*'] for all)
    # @param organization [Object, nil] Current organization for FK scoping (optional)
    # @return [Hash] { valid: Boolean, errors: Hash, validated: Hash }
    def validate_for_action(params, permitted_fields:, organization: nil)
      # Filter to only permitted fields
      if permitted_fields == ['*']
        filtered = params.each_with_object({}) { |(k, v), h| h[k.to_s] = v }
      else
        permitted = permitted_fields.map(&:to_s)
        filtered = params.each_with_object({}) do |(k, v), h|
          h[k.to_s] = v if permitted.include?(k.to_s)
        end
      end

      # Remove organization_id from validated data — managed by framework
      filtered.delete("organization_id") if organization

      # Run ActiveModel validations on a temp instance
      temp = self.class.new
      safe_attrs = filtered.select { |k, _| temp.respond_to?("#{k}=") }
      temp.assign_attributes(safe_attrs)

      errors = {}
      unless temp.valid?
        temp.errors.each do |error|
          field_name = error.attribute.to_s
          if filtered.key?(field_name)
            errors[field_name] ||= []
            errors[field_name] << error.message
          end
        end
      end

      # Cross-tenant FK validation
      if organization
        fk_errors = validate_foreign_keys_for_organization(filtered, organization)
        errors.merge!(fk_errors)
      end

      if errors.any?
        { valid: false, errors: errors, validated: {} }
      else
        { valid: true, errors: {}, validated: filtered }
      end
    end

    private

    # Cache for FK chain lookups (class-level)
    @@fk_chain_cache = {}
    @@org_column_cache = {}

    # Validate that all FK references in the data belong to the current organization.
    # Walks belongs_to associations on the model, checks if the referenced table
    # is org-scoped (directly or via FK chain), and verifies the record exists
    # within the org's scope.
    def validate_foreign_keys_for_organization(data, organization)
      errors = {}
      org_id = organization.id

      self.class.reflect_on_all_associations(:belongs_to).each do |assoc|
        fk_column = assoc.foreign_key.to_s
        next unless data.key?(fk_column)
        next if data[fk_column].nil?

        # Skip organization_id itself
        next if fk_column == "organization_id"

        begin
          related_class = assoc.klass
          related_table = related_class.table_name
        rescue StandardError
          next
        end

        # Direct: related table has organization_id
        if table_has_organization_id?(related_table)
          unless related_class.where(
            related_class.primary_key => data[fk_column],
            organization_id: org_id
          ).exists?
            errors[fk_column] = ["does not belong to your organization"]
          end
          next
        end

        # Indirect: walk FK chain to find org-scoped ancestor
        chain = find_organization_fk_chain(related_table)
        next unless chain

        unless record_belongs_to_organization?(related_table, related_class.primary_key, data[fk_column], org_id, chain)
          errors[fk_column] = ["does not belong to your organization"]
        end
      end

      errors
    end

    # Check if a table has an organization_id column.
    def table_has_organization_id?(table)
      unless @@org_column_cache.key?(table)
        @@org_column_cache[table] = ActiveRecord::Base.connection.column_exists?(table, :organization_id)
      end
      @@org_column_cache[table]
    end

    # Find the FK chain from a table to an org-scoped ancestor.
    # Returns array of steps or nil.
    # Each step: { local_column:, foreign_table:, foreign_column: }
    def find_organization_fk_chain(table)
      return @@fk_chain_cache[table] if @@fk_chain_cache.key?(table)

      chain = walk_fk_chain(table, 5, [])
      @@fk_chain_cache[table] = chain
      chain
    end

    def walk_fk_chain(table, max_depth, visited)
      return nil if max_depth <= 0 || visited.include?(table)

      visited = visited + [table]

      begin
        foreign_keys = ActiveRecord::Base.connection.foreign_keys(table)
      rescue StandardError
        return nil
      end

      foreign_keys.each do |fk|
        local_column = fk.column
        foreign_table = fk.to_table
        foreign_column = fk.primary_key || "id"

        if table_has_organization_id?(foreign_table)
          return [{ local_column: local_column, foreign_table: foreign_table, foreign_column: foreign_column }]
        end

        deeper = walk_fk_chain(foreign_table, max_depth - 1, visited)
        if deeper
          deeper.unshift({ local_column: local_column, foreign_table: foreign_table, foreign_column: foreign_column })
          return deeper
        end
      end

      nil
    end

    # Check if a specific record belongs to the organization via FK chain.
    # Builds a SQL EXISTS query with nested subqueries.
    def record_belongs_to_organization?(table, pk_column, pk_value, org_id, chain)
      # Build from innermost (org-scoped table) outward
      # The chain goes: table → chain[0].foreign_table → chain[1].foreign_table → ... → org-scoped table
      # We need to verify: record in `table` with pk_value → chain walks → org_id matches

      query = build_chain_exists_query(table, pk_column, pk_value, org_id, chain, 0)
      ActiveRecord::Base.connection.select_value(query).present?
    end

    def build_chain_exists_query(table, pk_column, pk_value, org_id, chain, index)
      step = chain[index]

      if index == chain.length - 1
        # Last step: the foreign table has organization_id
        sanitize_sql([
          "SELECT 1 FROM #{quote_table(table)} " \
          "WHERE #{quote_column(pk_column)} = ? " \
          "AND #{quote_column(step[:local_column])} IN (" \
          "SELECT #{quote_column(step[:foreign_column])} FROM #{quote_table(step[:foreign_table])} " \
          "WHERE organization_id = ?)",
          pk_value, org_id
        ])
      else
        # Intermediate step: recurse deeper
        inner = build_inner_chain_query(step[:foreign_table], step[:foreign_column], org_id, chain, index + 1)
        sanitize_sql([
          "SELECT 1 FROM #{quote_table(table)} " \
          "WHERE #{quote_column(pk_column)} = ? " \
          "AND #{quote_column(step[:local_column])} IN (#{inner})",
          pk_value
        ])
      end
    end

    def build_inner_chain_query(table, pk_column, org_id, chain, index)
      step = chain[index]

      if index == chain.length - 1
        sanitize_sql([
          "SELECT #{quote_column(pk_column)} FROM #{quote_table(table)} " \
          "WHERE #{quote_column(step[:local_column])} IN (" \
          "SELECT #{quote_column(step[:foreign_column])} FROM #{quote_table(step[:foreign_table])} " \
          "WHERE organization_id = ?)",
          org_id
        ])
      else
        inner = build_inner_chain_query(step[:foreign_table], step[:foreign_column], org_id, chain, index + 1)
        "SELECT #{quote_column(pk_column)} FROM #{quote_table(table)} " \
        "WHERE #{quote_column(step[:local_column])} IN (#{inner})"
      end
    end

    def sanitize_sql(args)
      ActiveRecord::Base.send(:sanitize_sql_array, args)
    end

    def quote_table(name)
      ActiveRecord::Base.connection.quote_table_name(name)
    end

    def quote_column(name)
      ActiveRecord::Base.connection.quote_column_name(name)
    end
  end
end
