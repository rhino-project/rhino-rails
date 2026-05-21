# frozen_string_literal: true

module Rhino
  module Blueprint
    # Validates parsed blueprint data structures.
    # Port of rhino-server BlueprintValidator.php / rhino-adonis-server blueprint_validator.ts.
    class BlueprintValidator
      VALID_COLUMN_TYPES = %w[
        string text integer bigInteger boolean date datetime
        timestamp decimal float json uuid foreignId
      ].freeze

      VALID_ACTIONS = %w[
        index show store update destroy trashed restore forceDelete
      ].freeze

      # Validate role definitions.
      #
      # @param roles [Hash<String, Hash>]
      # @return [Hash] { valid:, errors: }
      def validate_roles(roles)
        errors = []

        if roles.empty?
          errors << "At least one role is required"
          return { valid: false, errors: errors }
        end

        roles.each do |slug, role|
          unless slug.match?(/\A[a-z][a-z0-9_]*\z/)
            errors << "Invalid role slug '#{slug}' — must match /^[a-z][a-z0-9_]*$/"
          end

          if role[:name].nil? || role[:name].strip.empty?
            errors << "Role '#{slug}' must have a non-empty name"
          end
        end

        { valid: errors.empty?, errors: errors }
      end

      # Validate a full model blueprint.
      #
      # @param blueprint [Hash]
      # @param valid_roles [Hash] optional role definitions for cross-reference
      # @return [Hash] { valid:, errors:, warnings: }
      def validate_model(blueprint, valid_roles = {})
        errors = []
        warnings = []

        # Model name
        if blueprint[:model].nil? || blueprint[:model].strip.empty?
          errors << "Model name is required"
        elsif !blueprint[:model].match?(/\A[A-Z][a-zA-Z0-9]*\z/)
          errors << "Invalid model name '#{blueprint[:model]}' — must be PascalCase (match /^[A-Z][a-zA-Z0-9]*$/)"
        end

        # Columns
        errors.concat(validate_columns(blueprint[:columns]))

        # Permissions
        column_names = blueprint[:columns].map { |c| c[:name] }
        perm_result = validate_permissions(blueprint[:permissions], valid_roles, column_names)
        errors.concat(perm_result[:errors])
        warnings.concat(perm_result[:warnings])

        # Options
        errors.concat(validate_options(blueprint[:options]))

        # Relationships
        errors.concat(validate_relationships(blueprint[:relationships]))

        { valid: errors.empty?, errors: errors, warnings: warnings }
      end

      # Validate columns.
      #
      # @param columns [Array<Hash>]
      # @return [Array<String>] errors
      def validate_columns(columns)
        errors = []
        seen = Set.new

        columns.each do |col|
          if col[:name].nil? || col[:name].strip.empty?
            errors << "Column name is required"
            next
          end

          if seen.include?(col[:name])
            errors << "Duplicate column name '#{col[:name]}'"
          end
          seen.add(col[:name])

          unless VALID_COLUMN_TYPES.include?(col[:type])
            errors << "Invalid column type '#{col[:type]}' for column '#{col[:name]}'"
          end

          if col[:type] == "foreignId" && col[:foreign_model].nil?
            errors << "Column '#{col[:name]}' is foreignId but missing 'foreign_model'"
          end
        end

        errors
      end

      # Validate permissions.
      #
      # @return [Hash] { errors:, warnings: }
      def validate_permissions(permissions, valid_roles, column_names)
        errors = []
        warnings = []
        has_roles = !valid_roles.empty?

        permissions.each do |role, perm|
          # Check role exists
          if has_roles && !valid_roles.key?(role)
            errors << "Unknown role '#{role}' in permissions"
          end

          # Check actions
          perm[:actions].each do |action|
            unless VALID_ACTIONS.include?(action)
              errors << "Invalid action '#{action}' for role '#{role}'"
            end
          end

          # Check field references
          all_column_names = ["id"] + column_names
          check_field_references(perm[:show_fields], all_column_names, role, "show_fields", warnings)
          check_field_references(perm[:create_fields], all_column_names, role, "create_fields", warnings)
          check_field_references(perm[:update_fields], all_column_names, role, "update_fields", warnings)

          # Warn on conflicts
          if perm[:hidden_fields].any? && perm[:show_fields].any?
            perm[:hidden_fields].each do |field|
              if perm[:show_fields].include?(field)
                warnings << "Role '#{role}': field '#{field}' is in both show_fields and hidden_fields"
              end
            end
          end

          # Warn on create_fields without store action
          if perm[:create_fields].any? && !perm[:create_fields].include?("*") &&
             perm[:create_fields].any? { |f| f != "*" } && !perm[:actions].include?("store")
            warnings << "Role '#{role}': has create_fields but no 'store' action"
          end

          # Warn on update_fields without update action
          if perm[:update_fields].any? && !perm[:update_fields].include?("*") &&
             perm[:update_fields].any? { |f| f != "*" } && !perm[:actions].include?("update")
            warnings << "Role '#{role}': has update_fields but no 'update' action"
          end
        end

        { errors: errors, warnings: warnings }
      end

      # Validate options.
      def validate_options(options)
        errors = []

        if options[:except_actions]
          options[:except_actions].each do |action|
            unless VALID_ACTIONS.include?(action)
              errors << "Invalid action '#{action}' in except_actions"
            end
          end
        end

        errors
      end

      # Validate relationships.
      def validate_relationships(relationships)
        errors = []
        valid_types = %w[belongsTo hasMany hasOne belongsToMany]

        relationships.each do |rel|
          rel = rel.transform_keys(&:to_s) if rel.is_a?(Hash)

          if rel["type"].nil?
            errors << "Relationship is missing type"
          elsif !valid_types.include?(rel["type"])
            errors << "Invalid relationship type '#{rel["type"]}'"
          end

          if rel["model"].nil?
            errors << "Relationship is missing model"
          end
        end

        errors
      end

      private

      def check_field_references(fields, column_names, role, field_key, warnings)
        return if fields.empty? || (fields.length == 1 && fields[0] == "*")

        fields.each do |field|
          if field != "*" && !column_names.include?(field)
            warnings << "Role '#{role}': unknown field '#{field}' in #{field_key}"
          end
        end
      end
    end
  end
end
