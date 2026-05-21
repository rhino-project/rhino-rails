# frozen_string_literal: true

require "rhino/commands/base_command"
require "fileutils"
require "rhino/blueprint/blueprint_parser"
require "rhino/blueprint/blueprint_validator"
require "rhino/blueprint/manifest_manager"
require "rhino/blueprint/generators/policy_generator"
require "rhino/blueprint/generators/test_generator"
require "rhino/blueprint/generators/seeder_generator"
require "rhino/blueprint/generators/factory_generator"

module Rhino
  module Commands
    # Zero-token deterministic code generation from YAML blueprint specs.
    # Port of rhino-server BlueprintCommand.php / rhino-adonis-server blueprint.ts.
    #
    # Usage: rails rhino:blueprint [OPTIONS]
    class BlueprintCommand < BaseCommand
      attr_accessor :options

      def initialize
        super
        @options = {
          dir: ".rhino/blueprints",
          model: nil,
          force: false,
          dry_run: false,
          skip_tests: false,
          skip_seeders: false
        }
        @migration_timestamp_offset = 0
      end

      def perform
        print_banner

        blueprints_dir = Rails.root.join(options[:dir]).to_s

        unless Dir.exist?(blueprints_dir)
          say "Blueprint directory not found: #{blueprints_dir}", :red
          say "Run 'rails rhino:install' first, or create the directory manually.", :yellow
          return
        end

        parser = Rhino::Blueprint::BlueprintParser.new
        validator = Rhino::Blueprint::BlueprintValidator.new
        manifest = Rhino::Blueprint::ManifestManager.new(blueprints_dir)

        # 1. Parse roles
        roles_file = File.join(blueprints_dir, "_roles.yaml")
        roles = {}

        if File.exist?(roles_file)
          begin
            roles = parser.parse_roles(roles_file)
            role_result = validator.validate_roles(roles)
            unless role_result[:valid]
              say "Role validation errors:", :red
              role_result[:errors].each { |e| say "  • #{e}", :red }
              return
            end
            say "  ✓ Parsed #{roles.length} roles", :green
          rescue => e
            say "  ✗ #{e.message}", :red
            return
          end
        else
          say "  ⚠ No _roles.yaml found — role cross-reference disabled", :yellow
        end

        # 2. Discover YAML files
        yaml_files = Dir.glob(File.join(blueprints_dir, "*.yaml"))
                        .reject { |f| File.basename(f).start_with?("_", ".") }
                        .sort

        if options[:model]
          yaml_files = yaml_files.select { |f| File.basename(f, ".yaml") == options[:model] }
        end

        if yaml_files.empty?
          say "No blueprint YAML files found in #{blueprints_dir}", :yellow
          return
        end

        say "  Found #{yaml_files.length} blueprint(s)", :cyan

        # 3. Process each blueprint
        is_multi_tenant = multi_tenant_enabled?
        org_identifier = detect_org_identifier
        generated_count = 0
        skipped_count = 0
        all_blueprints = []
        all_generated_files = {}

        yaml_files.each do |yaml_file|
          filename = File.basename(yaml_file)

          begin
            blueprint = parser.parse_model(yaml_file)
          rescue => e
            say "  ✗ #{filename}: #{e.message}", :red
            next
          end

          # Validate
          result = validator.validate_model(blueprint, roles)

          unless result[:valid]
            say "  ✗ #{filename}:", :red
            result[:errors].each { |e| say "    • #{e}", :red }
            next
          end

          result[:warnings].each { |w| say "    ⚠ #{w}", :yellow }

          # Check manifest
          current_hash = parser.compute_file_hash(yaml_file)

          unless options[:force]
            unless manifest.has_changed?(filename, current_hash)
              say "  ⊘ #{blueprint[:model]} — unchanged, skipping", :light_black
              skipped_count += 1
              all_blueprints << blueprint
              next
            end
          end

          all_blueprints << blueprint
          generated_files = []

          say "  → #{blueprint[:model]}...", :cyan

          unless options[:dry_run]
            # Generate model
            model_path = generate_model(blueprint, is_multi_tenant)
            generated_files << model_path
            say "    ✓ Model: #{model_path}", :green

            # Generate migration
            migration_path = generate_migration(blueprint)
            generated_files << migration_path
            say "    ✓ Migration: #{migration_path}", :green

            # Generate factory
            factory_path = generate_factory(blueprint)
            generated_files << factory_path
            say "    ✓ Factory: #{factory_path}", :green

            # Generate scope
            scope_path = generate_scope(blueprint)
            generated_files << scope_path
            say "    ✓ Scope: #{scope_path}", :green

            # Generate policy
            policy_path = generate_policy(blueprint)
            generated_files << policy_path
            say "    ✓ Policy: #{policy_path}", :green

            # Generate tests
            unless options[:skip_tests]
              test_path = generate_tests(blueprint, is_multi_tenant, org_identifier)
              generated_files << test_path
              say "    ✓ Tests: #{test_path}", :green
            end

            # Register in config
            register_model_in_config(blueprint[:model])

            # Record in manifest
            manifest.record_generation(filename, current_hash, generated_files)
            all_generated_files[filename] = generated_files
          end

          generated_count += 1
        end

        # 4. Generate cross-model seeders
        unless options[:skip_seeders] || options[:dry_run] || all_blueprints.empty?
          generate_seeders(roles, all_blueprints, is_multi_tenant)
        end

        # 5. Save manifest
        manifest.save unless options[:dry_run]

        # 6. Summary
        say ""
        say "Blueprint generation complete!", :green
        say "  Generated: #{generated_count} model(s)", :cyan
        say "  Skipped:   #{skipped_count} (unchanged)", :light_black
        say ""
      end

      private

      # ----------------------------------------------------------------
      # Banner
      # ----------------------------------------------------------------

      def print_banner
        say ""
        say "  + Rhino :: Blueprint :: Zero-Token Code Generation +", :cyan
        say ""
      end

      # ----------------------------------------------------------------
      # Model generation
      # ----------------------------------------------------------------

      def generate_model(blueprint, is_multi_tenant)
        name = blueprint[:model]
        table_name = blueprint[:table]
        columns = blueprint[:columns]
        opts = blueprint[:options]

        belongs_to_org = opts[:belongs_to_organization]
        soft_deletes = opts[:soft_deletes]
        audit_trail = opts[:audit_trail]

        fillable = columns.map { |c| c[:name] }.reject { |n| n == "organization_id" }
        filter_cols = columns.reject { |c| %w[text json].include?(c[:type]) }.map { |c| c[:name] }
        sort_cols = (columns.reject { |c| %w[text json].include?(c[:type]) }.map { |c| c[:name] } + ["created_at"]).uniq
        field_cols = (["id"] + columns.map { |c| c[:name] } + ["created_at"]).uniq
        include_cols = columns.select { |c| c[:type] == "foreignId" && c[:foreign_model] }
                              .map { |c| c[:name].sub(/_id\z/, "") }

        content = <<~RUBY
          # frozen_string_literal: true

          class #{name} < Rhino::RhinoModel
        RUBY

        content += "  include Rhino::BelongsToOrganization\n" if belongs_to_org
        content += "  include Discard::Model\n" if soft_deletes
        content += "  include Rhino::HasAuditTrail\n" if audit_trail

        # Relationships
        fk_columns = columns.select { |c| c[:type] == "foreignId" && c[:foreign_model] }
        has_relationships = fk_columns.any? { |col| !(belongs_to_org && col[:foreign_model] == "Organization") }

        if has_relationships
          content += "\n"
          fk_columns.each do |col|
            relation_name = col[:name].sub(/_id\z/, "")
            next if belongs_to_org && col[:foreign_model] == "Organization"

            opts = "class_name: '#{col[:foreign_model]}'"
            opts += ", optional: true" if col[:nullable]
            content += "  belongs_to :#{relation_name}, #{opts}\n"
          end
        end

        # Query Builder configuration
        content += "\n"
        content += "  rhino_filters #{filter_cols.map { |c| ":#{c}" }.join(', ')}\n" unless filter_cols.empty?
        content += "  rhino_sorts #{sort_cols.map { |c| ":#{c}" }.join(', ')}\n" unless sort_cols.empty?
        content += "  rhino_fields #{field_cols.map { |c| ":#{c}" }.join(', ')}\n" unless field_cols.empty?
        content += "  rhino_includes #{include_cols.map { |c| ":#{c}" }.join(', ')}\n" unless include_cols.empty?

        # Validations

        columns.each do |col|
          validations = column_to_validations(col, table_name)
          content += "  validates :#{col[:name]}, #{validations}, allow_nil: true\n" unless validations.empty?
        end

        content += "end\n"

        path = "app/models/#{name.underscore}.rb"
        write_file(path, content)
        path
      end

      # ----------------------------------------------------------------
      # Migration generation
      # ----------------------------------------------------------------

      def generate_migration(blueprint)
        table_name = blueprint[:table]
        columns = blueprint[:columns]
        soft_deletes = blueprint[:options][:soft_deletes]
        belongs_to_org = blueprint[:options][:belongs_to_organization]

        timestamp = (Time.current + @migration_timestamp_offset).strftime("%Y%m%d%H%M%S")
        @migration_timestamp_offset += 1
        class_name = "Create#{blueprint[:model].pluralize}"

        lines = []

        # Add organization reference if belongs_to_organization
        if belongs_to_org && multi_tenant_enabled?
          lines << "t.references :organization, null: false, foreign_key: true"
        end

        columns.each do |col|
          lines << column_to_migration_line(col)
        end

        content = <<~RUBY
          # frozen_string_literal: true

          class #{class_name} < ActiveRecord::Migration[8.0]
            def change
              create_table :#{table_name} do |t|
          #{lines.map { |l| "      #{l}" }.join("\n")}
          #{"      t.datetime :discarded_at\n      t.index :discarded_at" if soft_deletes}
                t.timestamps
              end
            end
          end
        RUBY

        path = "db/migrate/#{timestamp}_create_#{table_name}.rb"
        write_file(path, content)
        path
      end

      # ----------------------------------------------------------------
      # Factory generation
      # ----------------------------------------------------------------

      def generate_factory(blueprint)
        factory_gen = Rhino::Blueprint::Generators::FactoryGenerator.new
        content = factory_gen.generate(blueprint)

        path = "spec/factories/#{blueprint[:model].underscore.pluralize}.rb"
        write_file(path, content)
        path
      end

      # ----------------------------------------------------------------
      # Scope generation
      # ----------------------------------------------------------------

      def generate_scope(blueprint)
        name = blueprint[:model]

        content = <<~RUBY
          # frozen_string_literal: true

          module Scopes
            class #{name}Scope < Rhino::ResourceScope
              # Custom query scope for #{name}.
              # Applied automatically to all #{name} queries via HasAutoScope.
              #
              # Available methods: user, organization, role
              #
              # def apply(relation)
              #   relation.where(active: true)
              # end
            end
          end
        RUBY

        path = "app/models/scopes/#{name.underscore}_scope.rb"
        write_file(path, content)
        path
      end

      # ----------------------------------------------------------------
      # Policy generation
      # ----------------------------------------------------------------

      def generate_policy(blueprint)
        policy_gen = Rhino::Blueprint::Generators::PolicyGenerator.new
        content = policy_gen.generate(blueprint)

        path = "app/policies/#{blueprint[:model].underscore}_policy.rb"
        write_file(path, content)
        path
      end

      # ----------------------------------------------------------------
      # Test generation
      # ----------------------------------------------------------------

      def generate_tests(blueprint, is_multi_tenant, org_identifier)
        test_gen = Rhino::Blueprint::Generators::TestGenerator.new
        content = test_gen.generate(blueprint, is_multi_tenant, org_identifier)

        path = "spec/models/#{blueprint[:model].underscore}_spec.rb"
        write_file(path, content)
        path
      end

      # ----------------------------------------------------------------
      # Seeder generation
      # ----------------------------------------------------------------

      def generate_seeders(roles, blueprints, is_multi_tenant)
        seeder_gen = Rhino::Blueprint::Generators::SeederGenerator.new
        aggregated = seeder_gen.aggregate_permissions(blueprints)

        if is_multi_tenant
          # Role seeder
          role_content = seeder_gen.generate_role_seeder(roles)
          write_file("db/seeds/role_seeder.rb", role_content)
          say "  ✓ Seeder: db/seeds/role_seeder.rb", :green

          # UserRole seeder
          user_role_content = seeder_gen.generate_user_role_seeder(roles, aggregated)
          write_file("db/seeds/user_role_seeder.rb", user_role_content)
          say "  ✓ Seeder: db/seeds/user_role_seeder.rb", :green
        else
          # UserPermission seeder
          user_perm_content = seeder_gen.generate_user_permission_seeder(roles, aggregated)
          write_file("db/seeds/user_permission_seeder.rb", user_perm_content)
          say "  ✓ Seeder: db/seeds/user_permission_seeder.rb", :green
        end
      end

      # ----------------------------------------------------------------
      # Config registration
      # ----------------------------------------------------------------

      def register_model_in_config(name)
        config_path = Rails.root.join("config/initializers/rhino.rb")
        return unless File.exist?(config_path)

        content = File.read(config_path)
        slug = name.underscore.pluralize

        # Check if model is already registered (non-commented line)
        return if content.match?(/^\s+\w+\.model\s+:#{slug}\b/)

        # Detect the block variable name used in the config file (e.g., config, c, etc.)
        block_var = content.match(/Rhino\.configure\s+do\s+\|(\w+)\|/)&.captures&.first || "config"

        new_entry = "  #{block_var}.model :#{slug}, '#{name}'"

        # Try to insert before the commented-out example line (matching any variable name)
        if content.include?("# #{block_var}.model :posts, 'Post'")
          content = content.gsub(
            "# #{block_var}.model :posts, 'Post'",
            "#{new_entry}\n  # #{block_var}.model :posts, 'Post'"
          )
        elsif content.match?(/# \w+\.model :posts, 'Post'/)
          content = content.sub(
            /# (\w+)\.model :posts, 'Post'/,
            "#{new_entry}\n  # \\1.model :posts, 'Post'"
          )
        else
          # Fallback: insert after the Models section comment
          content = content.sub(
            /(# Register your models here.*?\n)/,
            "\\1#{new_entry}\n"
          )
        end

        File.write(config_path, content)
      end

      # ----------------------------------------------------------------
      # Helpers
      # ----------------------------------------------------------------

      def multi_tenant_enabled?
        config_path = Rails.root.join("config/initializers/rhino.rb")
        return false unless File.exist?(config_path)

        File.read(config_path).include?("route_group :tenant")
      end

      def detect_org_identifier
        config_path = Rails.root.join("config/initializers/rhino.rb")
        return "id" unless File.exist?(config_path)

        content = File.read(config_path)
        if content.match(/organization_identifier_column.*?['"](\w+)['"]/)
          $1
        else
          "slug"
        end
      end

      def write_file(relative_path, content)
        full_path = Rails.root.join(relative_path)
        FileUtils.mkdir_p(File.dirname(full_path))
        File.write(full_path, content)
      end

      def column_to_validations(column, _table_name)
        parts = []

        case column[:type]
        when "string"
          parts << "length: { maximum: 255 }"
        when "integer", "bigInteger"
          parts << "numericality: { only_integer: true }"
        when "boolean"
          parts << "inclusion: { in: [true, false] }"
        when "decimal", "float"
          parts << "numericality: true"
        end

        parts.join(", ")
      end

      def column_to_migration_line(col)
        case col[:type]
        when "foreignId", "references"
          ref_name = col[:name].sub(/_id\z/, "")
          foreign_table = col[:foreign_model]&.underscore&.pluralize

          # If the reference name doesn't match the foreign model's table,
          # we need to specify the target table explicitly
          if foreign_table && foreign_table != ref_name.pluralize
            line = "t.references :#{ref_name}, foreign_key: { to_table: :#{foreign_table} }"
          else
            line = "t.references :#{ref_name}, foreign_key: true"
          end
          line += ", null: true" if col[:nullable]
          line
        when "decimal"
          precision = col[:precision] || 8
          scale = col[:scale] || 2
          line = "t.decimal :#{col[:name]}, precision: #{precision}, scale: #{scale}"
          line += ", null: true" if col[:nullable]
          line
        else
          line = "t.#{col[:type]} :#{col[:name]}"
          line += ", null: true" if col[:nullable]
          line += ", default: #{col[:default].inspect}" if col[:default]
          line
        end
      end
    end
  end
end
