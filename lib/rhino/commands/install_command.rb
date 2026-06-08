# frozen_string_literal: true

require "rhino/commands/base_command"

module Rhino
  module Commands
    # Interactive setup wizard — mirrors Laravel `php artisan rhino:install` exactly.
    #
    # Usage: rails rhino:install
    class InstallCommand < BaseCommand
      def perform
        say ""
        say "+ Rhino :: Install :: Let's build something great +", :cyan
        say ""

        features = multi_select("Which features would you like to configure?") do |menu|
          menu.default 1
          menu.choice "Publish config & routes", "publish"
          menu.choice "Multi-tenant support (Organizations, Roles)", "multi_tenant"
          menu.choice "Audit trail (change logging)", "audit_trail"
        end

        test_framework = select("Which test framework do you use?") do |menu|
          menu.default 1
          menu.choice "RSpec", "rspec"
          menu.choice "Minitest", "minitest"
        end

        identifier_column = "id"
        roles = ["admin"]

        if features.include?("multi_tenant")
          identifier_column = ask("What column should be used to identify organizations?", default: "id")

          roles_input = ask("What roles should your app have?", default: "admin, editor, viewer")
          roles = (["admin"] + roles_input.split(",").map(&:strip)).uniq
        end

        say ""

        if features.include?("publish")
          task("Publishing config") { publish_config(test_framework) }
          task("Publishing routes") { publish_routes }
          task("Creating blueprint directory") { create_blueprint_directory }
        end

        if features.include?("multi_tenant")
          task("Creating migrations") { create_multi_tenant_migrations }
          task("Creating models") { create_multi_tenant_models(roles) }
          task("Creating factories") { create_factories }
          task("Creating policies") { create_policies }
          task("Updating config") { update_config(identifier_column) }
          task("Creating seeders") { create_seeders(roles) }
        end

        if features.include?("audit_trail")
          task("Creating audit trail migration") { create_audit_trail_migration }
        end

        say ""
        run_post_install_steps(features)

        install_ai_skill

        say ""
        say "Rhino installed successfully!", :green
        say ""

        print_next_steps(features)
      end

      private

      # ----------------------------------------------------------------
      # Publish
      # ----------------------------------------------------------------

      def publish_config(test_framework)
        template_path = File.expand_path("../../templates/rhino.rb", __FILE__)
        dest_path = Rails.root.join("config/initializers/rhino.rb")

        FileUtils.mkdir_p(File.dirname(dest_path))

        content = File.read(template_path)
        content = content.gsub('test_framework: "rspec"', "test_framework: \"#{test_framework}\"")
        File.write(dest_path, content)
      end

      def publish_routes
        template_path = File.expand_path("../../templates/routes.rb", __FILE__)
        dest_path = Rails.root.join("config/routes/rhino.rb")

        FileUtils.mkdir_p(File.dirname(dest_path))
        FileUtils.cp(template_path, dest_path)
      end

      # ----------------------------------------------------------------
      # Multi-tenant
      # ----------------------------------------------------------------

      def create_multi_tenant_migrations
        timestamp = Time.current.strftime("%Y%m%d%H%M%S")
        migrations_path = Rails.root.join("db/migrate")
        FileUtils.mkdir_p(migrations_path)

        templates_dir = File.expand_path("../../templates/multi_tenant/migrations", __FILE__)

        {
          "create_users" => "#{timestamp}00",
          "create_organizations" => "#{timestamp}01",
          "create_roles" => "#{timestamp}02",
          "create_user_roles" => "#{timestamp}03",
          "create_org_role_permissions" => "#{timestamp}04"
        }.each do |name, ts|
          template = File.join(templates_dir, "#{name}.rb.erb")
          next unless File.exist?(template)

          content = ERB.new(File.read(template), trim_mode: "-").result(binding)
          File.write(migrations_path.join("#{ts}_#{name}.rb"), content)
        end
      end

      def create_multi_tenant_models(roles)
        models_path = Rails.root.join("app/models")
        FileUtils.mkdir_p(models_path)

        templates_dir = File.expand_path("../../templates/multi_tenant/models", __FILE__)

        %w[user organization role user_role org_role_permission].each do |model|
          template = File.join(templates_dir, "#{model}.rb.erb")
          next unless File.exist?(template)

          content = ERB.new(File.read(template), trim_mode: "-").result_with_hash(roles: roles)
          File.write(models_path.join("#{model}.rb"), content)
        end
      end

      def create_factories
        factories_path = Rails.root.join("spec/factories")
        FileUtils.mkdir_p(factories_path)

        templates_dir = File.expand_path("../../templates/multi_tenant/factories", __FILE__)

        %w[users organizations roles user_roles].each do |factory|
          template = File.join(templates_dir, "#{factory}.rb.erb")
          next unless File.exist?(template)

          content = ERB.new(File.read(template), trim_mode: "-").result(binding)
          File.write(factories_path.join("#{factory}.rb"), content)
        end
      end

      def create_policies
        policies_path = Rails.root.join("app/policies")
        FileUtils.mkdir_p(policies_path)

        templates_dir = File.expand_path("../../templates/multi_tenant/policies", __FILE__)

        %w[organization_policy role_policy user_policy].each do |policy|
          template = File.join(templates_dir, "#{policy}.rb.erb")
          next unless File.exist?(template)

          content = ERB.new(File.read(template), trim_mode: "-").result(binding)
          File.write(policies_path.join("#{policy}.rb"), content)
        end
      end

      def update_config(identifier_column)
        config_path = Rails.root.join("config/initializers/rhino.rb")
        return unless File.exist?(config_path)

        content = File.read(config_path)

        # Update organization_identifier_column
        content = content.gsub(
          'organization_identifier_column: "id"',
          "organization_identifier_column: \"#{identifier_column}\""
        )

        # Add organization and role models
        unless content.include?("config.model :organizations")
          content = content.gsub(
            "# config.model :posts, 'Post'",
            "config.model :organizations, 'Organization'\n  config.model :roles, 'Role'\n  # config.model :posts, 'Post'"
          )
        end

        # Add tenant route group
        unless content.include?("config.route_group :tenant")
          content = content.gsub(
            "# config.route_group :default",
            "config.route_group :tenant, prefix: \":organization\", middleware: [Rhino::Middleware::ResolveOrganizationFromRoute], models: :all\n  # config.route_group :default"
          )
        end

        File.write(config_path, content)
      end

      def create_seeders(roles)
        seeders_path = Rails.root.join("db/seeds")
        FileUtils.mkdir_p(seeders_path)

        templates_dir = File.expand_path("../../templates/multi_tenant/seeders", __FILE__)

        template = File.join(templates_dir, "role_seeder.rb.erb")
        if File.exist?(template)
          content = ERB.new(File.read(template), trim_mode: "-").result_with_hash(roles: roles)
          File.write(seeders_path.join("role_seeder.rb"), content)
        end

        template = File.join(templates_dir, "organization_seeder.rb.erb")
        if File.exist?(template)
          content = ERB.new(File.read(template), trim_mode: "-").result(binding)
          File.write(seeders_path.join("organization_seeder.rb"), content)
        end
      end

      # ----------------------------------------------------------------
      # Audit trail
      # ----------------------------------------------------------------

      def create_audit_trail_migration
        timestamp = Time.current.strftime("%Y%m%d%H%M%S")
        migrations_path = Rails.root.join("db/migrate")
        FileUtils.mkdir_p(migrations_path)

        # Check for existing
        existing = Dir.glob(migrations_path.join("*_create_audit_logs.rb"))
        return unless existing.empty?

        template = File.expand_path("../../templates/audit_trail/create_audit_logs.rb.erb", __FILE__)
        if File.exist?(template)
          content = ERB.new(File.read(template), trim_mode: "-").result(binding)
          File.write(migrations_path.join("#{timestamp}_create_audit_logs.rb"), content)
        end
      end

      # ----------------------------------------------------------------
      # Post-install
      # ----------------------------------------------------------------

      def run_post_install_steps(features)
        has_migrations = features.include?("multi_tenant") || features.include?("audit_trail")

        if has_migrations
          if yes?("Would you like to run migrations now?")
            task("Running migrations") { system("rails db:migrate") }
          end
        end

        if features.include?("multi_tenant")
          if yes?("Would you like to seed the database?")
            task("Seeding database") { system("rails db:seed") }
          end
        end
      end

      def print_next_steps(features)
        say "Remaining steps:", :yellow
        say ""

        step = 1

        if features.include?("audit_trail")
          say "  #{step}. Add Rhino::HasAuditTrail concern to your models:"
          say "     include Rhino::HasAuditTrail"
          step += 1
        end

        if features.include?("multi_tenant")
          say "  #{step}. Add Rhino::HasPermissions concern to your User model:"
          say "     include Rhino::HasPermissions"
          step += 1
        end

        say ""
      end

      # ----------------------------------------------------------------
      # Blueprint directory
      # ----------------------------------------------------------------

      def create_blueprint_directory
        bp_dir = Rails.root.join(".rhino", "blueprints")
        FileUtils.mkdir_p(bp_dir)

        guide_path = bp_dir.join("..", "BLUEPRINT.md")
        unless File.exist?(guide_path)
          File.write(guide_path, blueprint_guide_content)
        end
      end

      def blueprint_guide_content
        <<~MD
          # Rhino Blueprint — AI Guide

          Use this file to teach AI assistants how to generate valid YAML blueprint files.

          ## Quick Start

          1. Create `_roles.yaml` in `.rhino/blueprints/` with your role definitions
          2. Create `{model_slug}.yaml` for each model
          3. Run `rails rhino:blueprint` to generate all files

          ## Roles Format

          ```yaml
          roles:
            owner:
              name: Owner
              description: "Full access"
            viewer:
              name: Viewer
              description: "Read-only"
          ```

          ## Model Format

          ```yaml
          model: Contract
          slug: contracts

          options:
            belongs_to_organization: true
            soft_deletes: true

          columns:
            title:
              type: string
              filterable: true

          permissions:
            owner:
              actions: [index, show, store, update, destroy]
              show_fields: "*"
              create_fields: "*"
              update_fields: "*"
          ```

          ## Valid Column Types
          string, text, integer, bigInteger, boolean, date, datetime, timestamp, decimal, float, json, uuid, foreignId

          ## Valid Actions
          index, show, store, update, destroy, trashed, restore, forceDelete
        MD
      end

      # ----------------------------------------------------------------
      # AI Skill
      # ----------------------------------------------------------------

      def install_ai_skill
        say ""

        ai_tools = multi_select("Install Rhino AI Skill for which tools? (select none to skip)") do |menu|
          menu.default 1
          menu.choice "Claude Code (.claude/skills/rhino/)", "claude"
          menu.choice "Cursor (.cursor/rules/rhino/)", "cursor"
          menu.choice "AI Directory (.ai/skills/rhino/)", "ai"
        end

        return if ai_tools.empty?

        url = "https://rhino-project.github.io/rhino-docs/skills/rails/SKILL.md"

        destinations = {
          "claude" => ".claude/skills/rhino/SKILL.md",
          "cursor" => ".cursor/rules/rhino/SKILL.md",
          "ai" => ".ai/skills/rhino/SKILL.md"
        }

        # Download once
        require "net/http"
        require "uri"

        uri = URI.parse(url)
        response = Net::HTTP.get_response(uri)

        # Follow redirect if needed
        if response.is_a?(Net::HTTPRedirection)
          uri = URI.parse(response["location"])
          response = Net::HTTP.get_response(uri)
        end

        unless response.is_a?(Net::HTTPSuccess)
          say "  Could not download skill file. You can manually download it from:", :yellow
          say "  #{url}"
          return
        end

        content = response.body

        ai_tools.each do |tool|
          dest_file = Rails.root.join(destinations[tool])

          task("Installing skill for #{tool}") do
            FileUtils.mkdir_p(File.dirname(dest_file))
            File.write(dest_file, content)
          end
        end

        say "  AI Skill installed successfully.", :green
      rescue StandardError => e
        say "  Could not download skill file (#{e.message}). You can manually download it from:", :yellow
        say "  #{url}"
      end
    end
  end
end
