# frozen_string_literal: true

require "yaml"
require "digest"

module Rhino
  module Blueprint
    # Parses YAML blueprint files into normalized data structures.
    # Port of rhino-server BlueprintParser.php / rhino-adonis-server blueprint_parser.ts.
    class BlueprintParser
      # Parse _roles.yaml file into normalized role definitions.
      #
      # @param file_path [String]
      # @return [Hash<String, Hash>] e.g. { 'owner' => { name: 'Owner', description: '...' } }
      def parse_roles(file_path)
        content = read_file(file_path)

        raise "Blueprint roles file is empty: #{file_path}" if content.strip.empty?

        parsed = begin
          YAML.safe_load(content, permitted_classes: [Symbol])
        rescue Psych::SyntaxError
          raise "Invalid YAML syntax in: #{file_path}"
        end

        raise "Invalid YAML structure in: #{file_path}" unless parsed.is_a?(Hash)
        raise "Missing 'roles' key in: #{file_path}" unless parsed["roles"]

        roles = {}

        parsed["roles"].each do |slug, value|
          raise "Invalid role definition for '#{slug}' — expected a hash" unless value.is_a?(Hash)

          roles[slug] = {
            name: value["name"] || slug_to_name(slug),
            description: value["description"] || ""
          }
        end

        roles
      end

      # Parse a model blueprint YAML file into normalized structure.
      #
      # @param file_path [String]
      # @return [Hash] ParsedBlueprint hash
      def parse_model(file_path)
        content = read_file(file_path)

        raise "Blueprint file is empty: #{file_path}" if content.strip.empty?

        parsed = begin
          YAML.safe_load(content, permitted_classes: [Symbol])
        rescue Psych::SyntaxError
          raise "Invalid YAML syntax in: #{file_path}"
        end

        raise "Invalid YAML structure in: #{file_path}" unless parsed.is_a?(Hash)
        raise "Missing 'model' key in: #{file_path}" unless parsed["model"]

        model_name = parsed["model"]
        slug = parsed["slug"] || model_to_slug(model_name)
        table = parsed["table"] || slug

        source_file = File.basename(file_path)

        {
          model: model_name,
          slug: slug,
          table: table,
          options: normalize_options(parsed["options"] || {}),
          columns: normalize_columns(parsed["columns"] || {}),
          relationships: parsed["relationships"] || [],
          permissions: normalize_permissions(parsed["permissions"] || {}),
          source_file: source_file
        }
      end

      # Compute SHA-256 hash of a file's contents.
      #
      # @param file_path [String]
      # @return [String] 64-char hex hash
      def compute_file_hash(file_path)
        Digest::SHA256.hexdigest(File.read(file_path))
      end

      # ──────────────────────────────────────────────
      # Normalization helpers
      # ──────────────────────────────────────────────

      def normalize_options(options)
        {
          belongs_to_organization: options.fetch("belongs_to_organization", false),
          soft_deletes: options.fetch("soft_deletes", true),
          audit_trail: options.fetch("audit_trail", false),
          owner: options.fetch("owner", nil),
          except_actions: options.fetch("except_actions", []),
          pagination: options.fetch("pagination", false),
          per_page: options.fetch("per_page", 25)
        }
      end

      def normalize_columns(columns)
        result = []

        columns.each do |name, value|
          if value.is_a?(String)
            # Short syntax: field_name: type
            result << {
              name: name,
              type: value,
              nullable: false,
              unique: false,
              index: false,
              default: nil,
              filterable: false,
              sortable: false,
              searchable: false,
              precision: nil,
              scale: nil,
              foreign_model: nil
            }
          elsif value.is_a?(Hash)
            result << {
              name: name,
              type: value.fetch("type", "string"),
              nullable: value.fetch("nullable", false),
              unique: value.fetch("unique", false),
              index: value.fetch("index", false),
              default: value.fetch("default", nil),
              filterable: value.fetch("filterable", false),
              sortable: value.fetch("sortable", false),
              searchable: value.fetch("searchable", false),
              precision: value.fetch("precision", nil),
              scale: value.fetch("scale", nil),
              foreign_model: value.fetch("foreign_model", nil)
            }
          end
        end

        result
      end

      def normalize_permissions(permissions)
        result = {}

        permissions.each do |role, value|
          next unless value.is_a?(Hash)

          result[role] = {
            actions: value["actions"] || [],
            show_fields: normalize_field_list(value["show_fields"]),
            create_fields: normalize_field_list(value["create_fields"]),
            update_fields: normalize_field_list(value["update_fields"]),
            hidden_fields: normalize_field_list(value["hidden_fields"])
          }
        end

        result
      end

      def normalize_field_list(value)
        return [] if value.nil?
        return ["*"] if value == "*"
        return [value] if value.is_a?(String)
        return value if value.is_a?(Array)

        []
      end

      private

      def read_file(file_path)
        File.read(file_path)
      rescue Errno::ENOENT
        raise "File not found or unreadable: #{file_path}"
      end

      def slug_to_name(slug)
        slug.split("_").map(&:capitalize).join(" ")
      end

      def model_to_slug(model_name)
        # PascalCase → snake_case plural
        snake = model_name.gsub(/([A-Z])/, '_\1').downcase.sub(/\A_/, "")

        # Simple pluralization
        if snake.end_with?("y") && !snake.match?(/[aeiou]y\z/)
          snake[0..-2] + "ies"
        elsif snake.match?(/(s|x|z|ch|sh)\z/)
          snake + "es"
        else
          snake + "s"
        end
      end
    end
  end
end
