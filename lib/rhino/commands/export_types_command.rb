# frozen_string_literal: true

require "rhino/commands/base_command"
require "json"
require "tempfile"
require "fileutils"
require "shellwords"

module Rhino
  module Commands
    # Generate TypeScript interfaces from registered Rhino models via
    # OpenAPI intermediate format + npx openapi-typescript.
    #
    # Mirrors the Laravel `php artisan rhino:export-types` command exactly.
    #
    # Usage:
    #   rails rhino:export_types
    #   rails rhino:export_types -- --output=path/to/types.d.ts
    class ExportTypesCommand < BaseCommand
      attr_accessor :options

      def initialize
        super
        @options = { output: nil }
      end

      def perform
        models = Rhino.config.models

        if models.empty?
          say "No models registered in Rhino configuration.", :yellow
          return true
        end

        output_paths = resolve_output_paths

        if output_paths.empty?
          say "No output paths configured. Set RHINO_CLIENT_PATH and/or RHINO_MOBILE_PATH in .env, or use --output flag.", :red
          return false
        end

        schemas = {}

        models.each do |slug, model_class_name|
          model_class = begin
            model_class_name.constantize
          rescue NameError
            say "Model class does not exist: #{model_class_name}", :red
            next
          end

          interface_name = slug_to_interface_name(slug)
          properties = introspect_columns(model_class)

          if properties.empty?
            say "No columns found for model: #{slug} (#{model_class_name})", :yellow
            next
          end

          schemas[interface_name] = {
            type: "object",
            properties: properties
          }
        end

        if schemas.empty?
          say "No schemas generated.", :yellow
          return true
        end

        openapi_spec = build_openapi_spec(schemas)

        temp_file = Tempfile.new(["rhino_openapi_", ".json"])
        begin
          temp_file.write(JSON.pretty_generate(openapi_spec))
          temp_file.flush

          output_paths.each do |output_path|
            dir = File.dirname(output_path)
            FileUtils.mkdir_p(dir) unless Dir.exist?(dir)

            exit_code = run_openapi_typescript(temp_file.path, output_path)

            if exit_code != 0
              say "Failed to generate types at #{output_path}. Is openapi-typescript installed? Run: npm install -g openapi-typescript", :red
              return false
            end

            say "Generated TypeScript types at: #{output_path}", :green
          end
        ensure
          temp_file.close
          temp_file.unlink
        end

        true
      end

      private

      # Resolve target paths from --output flag, config, or env vars.
      def resolve_output_paths
        explicit = options[:output]
        return [explicit] if explicit

        paths = []

        client_path = Rhino.config.respond_to?(:client_path) && Rhino.config.client_path ||
                      ENV["RHINO_CLIENT_PATH"]
        if client_path && !client_path.empty?
          paths << File.join(client_path.chomp("/"), "src", "types", "rhino.d.ts")
        end

        mobile_path = Rhino.config.respond_to?(:mobile_path) && Rhino.config.mobile_path ||
                      ENV["RHINO_MOBILE_PATH"]
        if mobile_path && !mobile_path.empty?
          paths << File.join(mobile_path.chomp("/"), "src", "types", "rhino.d.ts")
        end

        paths
      end

      # Convert slug to PascalCase singular interface name.
      # posts -> Post, blog_categories -> BlogCategory, blog-categories -> BlogCategory
      def slug_to_interface_name(slug)
        slug.to_s.underscore.singularize.camelize
      end

      # Introspect ActiveRecord columns and return OpenAPI property definitions.
      def introspect_columns(model_class)
        return {} unless model_class.respond_to?(:columns_hash)

        properties = {}

        model_class.columns_hash.each do |name, column|
          openapi_type = map_column_type(column.type.to_s)
          prop = openapi_type.dup

          if column.null
            prop[:nullable] = true
          end

          properties[name] = prop
        end

        properties
      end

      # Map ActiveRecord column type to OpenAPI type definition.
      def map_column_type(db_type)
        case db_type.downcase
        when "integer", "int", "bigint", "smallint", "tinyint", "mediumint"
          { type: "integer" }
        when "decimal", "float", "double", "real", "numeric"
          { type: "number" }
        when "boolean", "bool"
          { type: "boolean" }
        when "timestamp", "datetime", "timestamptz", "date", "time"
          { type: "string", format: "date-time" }
        when "json", "jsonb"
          { type: "object" }
        else
          { type: "string" }
        end
      end

      # Build a minimal OpenAPI 3.0.3 spec containing only component schemas.
      def build_openapi_spec(schemas)
        app_name = begin
          Rails.application.class.module_parent_name
        rescue StandardError
          "API"
        end

        {
          openapi: "3.0.3",
          info: {
            title: "#{app_name} Models",
            version: "1.0.0"
          },
          paths: {},
          components: {
            schemas: schemas
          }
        }
      end

      # Shell out to npx openapi-typescript to produce the .d.ts file.
      def run_openapi_typescript(input_file, output_file)
        command = "npx openapi-typescript #{Shellwords.escape(input_file)} -o #{Shellwords.escape(output_file)} 2>&1"
        output = `#{command}`
        exit_code = $?.exitstatus

        if exit_code != 0
          say output, :red
        end

        exit_code
      end
    end
  end
end
