# frozen_string_literal: true

require "rhino/commands/base_command"

module Rhino
  module Commands
    # Interactive scaffold generator — mirrors Laravel `php artisan rhino:generate` exactly.
    #
    # Usage: rails rhino:generate  (or rails rhino:g)
    class GenerateCommand < BaseCommand
      def perform
        print_styled_header

        type = select("What type of resource would you like to generate?") do |menu|
          menu.choice "Model (with migration and factory)", "model"
          menu.choice "Policy (extends ResourcePolicy)", "policy"
          menu.choice "Scope (for ScopedDB)", "scope"
        end

        name = ask("What is the resource name? (PascalCase singular, e.g., Post):")
        name = name.strip.camelize

        if name.blank? || name !~ /\A[A-Za-z][A-Za-z0-9]*\z/
          say "Invalid name. Must start with a letter and contain only alphanumeric characters.", :red
          return
        end

        case type
        when "model"
          generate_model(name)
        when "policy"
          generate_policy(name)
        when "scope"
          generate_scope(name)
        end
      end

      private

      def print_styled_header
        text = "+ Rhino :: Generate :: Scaffold your resources +"
        say ""
        say "  ┌#{"─" * (text.length + 8)}┐", :cyan
        say "  │    #{text}    │", :cyan
        say "  └#{"─" * (text.length + 8)}┘", :cyan
        say ""
      end

      # ----------------------------------------------------------------
      # Model generation
      # ----------------------------------------------------------------

      def generate_model(name)
        table_name = name.underscore.pluralize

        # Multi-tenant check
        belongs_to_org = false
        owner_relation = nil
        is_multi_tenant = multi_tenant_enabled?

        if is_multi_tenant
          belongs_to_org = yes?("Does this model belong to an organization?")

          unless belongs_to_org
            existing_models = get_existing_models
            if existing_models.any?
              has_parent = yes?("Does this model have a parent that belongs to an organization?")
              if has_parent
                owner_model = select("Which model is the parent owner?", existing_models)
                owner_relation = owner_model.underscore.camelize(:lower)
              end
            end
          end
        end

        # Collect columns
        columns = []
        if yes?("Would you like to define columns interactively?")
          columns = collect_columns
        end

        # Auto-add organization_id FK
        if belongs_to_org
          columns.unshift({
            name: "organization_id",
            type: "references",
            nullable: false,
            unique: false,
            index: true,
            default: nil,
            foreign_model: "Organization"
          })
        end

        # Auto-add owner FK
        if owner_relation
          owner_fk = "#{owner_relation.underscore}_id"
          unless columns.any? { |c| c[:name] == owner_fk }
            columns.unshift({
              name: owner_fk,
              type: "references",
              nullable: false,
              unique: false,
              index: true,
              default: nil,
              foreign_model: owner_relation.camelize
            })
          end
        end

        # Additional options
        options = collect_additional_options

        # Role access
        role_access = {}
        if options[:policy] && is_multi_tenant
          role_access = collect_role_access(name)
        end

        # Generate model
        task("Creating #{name} model") do
          write_model_file(name, columns, belongs_to_org, owner_relation, options)
        end

        # Generate migration
        unless columns.empty?
          task("Creating migration for #{table_name}") do
            write_migration_file(name, columns, options[:soft_deletes])
          end
        end

        # Generate factory
        task("Creating #{name} factory") do
          write_factory_file(name, columns)
        end

        # Register in config
        task("Registering #{name} in config/initializers/rhino.rb") do
          register_model_in_config(name)
        end

        # Generate policy
        if options[:policy]
          task("Generating #{name}Policy") do
            write_policy_file(name)
          end
        end

        # Generate scope
        task("Generating #{name}Scope") do
          write_scope_file(name)
        end

        say ""
        say "#{name} model generated successfully!", :green
        print_created_files(name, options)
        print_model_next_steps(name, table_name)
      end

      # ----------------------------------------------------------------
      # Policy generation
      # ----------------------------------------------------------------

      def generate_policy(name)
        policy_name = name.end_with?("Policy") ? name : "#{name}Policy"
        model_name = policy_name.sub(/Policy\z/, "")

        task("Generating #{policy_name}") do
          write_policy_file(model_name)
        end

        say ""
        say "#{policy_name} generated successfully!", :green
        say ""
        say "  Created: app/policies/#{policy_name.underscore}.rb"
        say ""
        say "  Next steps:", :yellow
        say "    1. Customize the authorization methods you need."
        say ""
      end

      # ----------------------------------------------------------------
      # Scope generation
      # ----------------------------------------------------------------

      def generate_scope(name)
        scope_name = name.end_with?("Scope") ? name : "#{name}Scope"
        model_name = scope_name.sub(/Scope\z/, "")

        task("Generating #{scope_name}") do
          write_scope_file(model_name)
        end

        say ""
        say "#{scope_name} generated successfully!", :green
        say ""
        say "  Created: app/models/scopes/#{scope_name.underscore}.rb"
        say ""
      end

      # ----------------------------------------------------------------
      # Column collection
      # ----------------------------------------------------------------

      def collect_columns
        columns = []

        loop do
          col_name = ask("Column name (snake_case, e.g., title) — leave blank to finish:")
          break if col_name.nil? || col_name.blank?

          col_type = select("Column type for '#{col_name}'") do |menu|
            menu.choice "string (VARCHAR 255)", "string"
            menu.choice "text (TEXT)", "text"
            menu.choice "integer", "integer"
            menu.choice "bigInteger", "bigint"
            menu.choice "boolean", "boolean"
            menu.choice "date", "date"
            menu.choice "datetime", "datetime"
            menu.choice "decimal (8, 2)", "decimal"
            menu.choice "float", "float"
            menu.choice "json", "json"
            menu.choice "uuid", "uuid"
            menu.choice "references (foreign key)", "references"
          end

          column = {
            name: col_name,
            type: col_type,
            nullable: false,
            unique: false,
            index: false,
            default: nil,
            foreign_model: nil
          }

          if col_type == "references"
            existing = get_existing_models
            if existing.any?
              column[:foreign_model] = select("Which model does '#{col_name}' reference?", existing)
            end
          end

          column[:nullable] = yes?("Is '#{col_name}' nullable?")
          column[:unique] = yes?("Should '#{col_name}' be unique?")

          columns << column

          break unless yes?("Add another column?")
        end

        columns
      end

      def collect_additional_options
        say "Additional options:", :yellow

        options = multi_select("Select additional options:") do |menu|
          menu.choice "Soft deletes", :soft_deletes
          menu.choice "Generate policy", :policy
          menu.choice "Audit trail", :audit_trail
        end

        {
          soft_deletes: options.include?(:soft_deletes),
          policy: options.include?(:policy),
          audit_trail: options.include?(:audit_trail)
        }
      end

      def collect_role_access(name)
        roles = get_roles_from_config
        return {} if roles.empty?

        slug = name.underscore.pluralize
        role_access = { "admin" => "editor" }

        non_admin_roles = roles.reject { |r| r == "admin" }
        return role_access if non_admin_roles.empty?

        say ""
        say "Define role access for #{slug}:", :cyan
        say ""

        non_admin_roles.each do |role|
          access = select("Access level for '#{role}'") do |menu|
            menu.choice "Editor — all actions on this model", "editor"
            menu.choice "Viewer — read-only (index, show)", "viewer"
            menu.choice "Writer — create & edit (index, show, store, update)", "writer"
            menu.choice "No access", "none"
          end
          role_access[role] = access
        end

        role_access
      end

      # ----------------------------------------------------------------
      # File writers
      # ----------------------------------------------------------------

      def write_model_file(name, columns, belongs_to_org, owner_relation, options)
        template = File.expand_path("../../templates/generate/model.rb.erb", __FILE__)
        dest = Rails.root.join("app/models/#{name.underscore}.rb")
        FileUtils.mkdir_p(File.dirname(dest))

        table_name = name.underscore.pluralize

        # Build data for template
        fillable = columns.map { |c| c[:name] }.reject { |n| n == "organization_id" && belongs_to_org }
        filter_cols = columns.reject { |c| %w[text json].include?(c[:type]) }.map { |c| c[:name] }
        sort_cols = (columns.reject { |c| %w[text json].include?(c[:type]) }.map { |c| c[:name] } + ["created_at"]).uniq
        field_cols = (["id"] + columns.map { |c| c[:name] } + ["created_at"]).uniq
        include_cols = columns.select { |c| c[:type] == "references" && c[:foreign_model] }
                              .map { |c| c[:name].sub(/_id\z/, "") }

        validation_rules = columns.to_h { |c| [c[:name], column_to_rails_validations(c)] }

        content = ERB.new(File.read(template), trim_mode: "-").result_with_hash(
          name: name,
          table_name: table_name,
          fillable: fillable,
          filter_cols: filter_cols,
          sort_cols: sort_cols,
          field_cols: field_cols,
          include_cols: include_cols,
          validation_rules: validation_rules,
          columns: columns,
          belongs_to_org: belongs_to_org,
          owner_relation: owner_relation,
          soft_deletes: options[:soft_deletes],
          audit_trail: options[:audit_trail]
        )

        File.write(dest, content)
      end

      def write_migration_file(name, columns, soft_deletes)
        template = File.expand_path("../../templates/generate/migration.rb.erb", __FILE__)
        table_name = name.underscore.pluralize
        timestamp = Time.current.strftime("%Y%m%d%H%M%S")
        dest = Rails.root.join("db/migrate/#{timestamp}_create_#{table_name}.rb")
        FileUtils.mkdir_p(File.dirname(dest))

        content = ERB.new(File.read(template), trim_mode: "-").result_with_hash(
          table_name: table_name,
          class_name: "Create#{name.pluralize}",
          columns: columns,
          soft_deletes: soft_deletes
        )

        File.write(dest, content)
      end

      def write_factory_file(name, columns)
        template = File.expand_path("../../templates/generate/factory.rb.erb", __FILE__)
        dest = Rails.root.join("spec/factories/#{name.underscore.pluralize}.rb")
        FileUtils.mkdir_p(File.dirname(dest))

        content = ERB.new(File.read(template), trim_mode: "-").result_with_hash(
          name: name,
          columns: columns
        )

        File.write(dest, content)
      end

      def write_policy_file(name)
        template = File.expand_path("../../templates/generate/policy.rb.erb", __FILE__)
        dest = Rails.root.join("app/policies/#{name.underscore}_policy.rb")
        FileUtils.mkdir_p(File.dirname(dest))

        content = ERB.new(File.read(template), trim_mode: "-").result_with_hash(name: name)

        File.write(dest, content)
      end

      def write_scope_file(name)
        template = File.expand_path("../../templates/generate/scope.rb.erb", __FILE__)
        dest = Rails.root.join("app/models/scopes/#{name.underscore}_scope.rb")
        FileUtils.mkdir_p(File.dirname(dest))

        table_name = name.underscore.pluralize
        content = ERB.new(File.read(template), trim_mode: "-").result_with_hash(
          name: name,
          table_name: table_name
        )

        File.write(dest, content)
      end

      def register_model_in_config(name)
        config_path = Rails.root.join("config/initializers/rhino.rb")
        return unless File.exist?(config_path)

        content = File.read(config_path)
        slug = name.underscore.pluralize

        # Check if model is already registered (non-commented line)
        return if content.match?(/^\s+\w+\.model\s+:#{slug}\b/)

        # Detect the block variable name used in the config file
        block_var = content.match(/Rhino\.configure\s+do\s+\|(\w+)\|/)&.captures&.first || "config"

        new_entry = "  #{block_var}.model :#{slug}, '#{name}'"

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

      def column_to_rails_validations(column)
        validations = []

        case column[:type]
        when "string"
          validations << "length: { maximum: 255 }"
        when "integer", "bigint"
          validations << "numericality: { only_integer: true }"
        when "boolean"
          validations << "inclusion: { in: [true, false] }"
        when "references"
          validations << "numericality: { only_integer: true }"
        end

        validations
      end

      def column_to_faker(column)
        case column[:name]
        when "name", "full_name" then "Faker::Name.name"
        when "email" then "Faker::Internet.email"
        when "title" then "Faker::Lorem.sentence(word_count: 3)"
        when "description", "content", "body" then "Faker::Lorem.paragraph"
        when "slug" then "Faker::Internet.slug"
        when "phone", "phone_number" then "Faker::PhoneNumber.phone_number"
        when "url", "website" then "Faker::Internet.url"
        when /\Ais_/ then "[true, false].sample"
        else
          case column[:type]
          when "string" then "Faker::Lorem.sentence(word_count: 3)"
          when "text" then "Faker::Lorem.paragraph"
          when "integer", "bigint" then "Faker::Number.between(from: 1, to: 100)"
          when "boolean" then "[true, false].sample"
          when "date" then "Faker::Date.between(from: 1.year.ago, to: Date.today)"
          when "datetime" then "Faker::Time.between(from: 1.year.ago, to: Time.current)"
          when "decimal", "float" then "Faker::Number.decimal(l_digits: 3, r_digits: 2)"
          when "json" then "{}"
          when "uuid" then "SecureRandom.uuid"
          when "references"
            if column[:foreign_model]
              "association :#{column[:name].sub(/_id\z/, '')}"
            else
              "Faker::Number.between(from: 1, to: 10)"
            end
          else
            "Faker::Lorem.word"
          end
        end
      end

      def multi_tenant_enabled?
        config_path = Rails.root.join("config/initializers/rhino.rb")
        return false unless File.exist?(config_path)

        content = File.read(config_path)
        content.include?("route_group :tenant")
      end

      def get_existing_models
        models_path = Rails.root.join("app/models")
        return [] unless Dir.exist?(models_path)

        Dir.glob(models_path.join("*.rb")).map do |f|
          File.basename(f, ".rb").camelize
        end.reject { |m| m == "ApplicationRecord" }
      end

      def get_roles_from_config
        config_path = Rails.root.join("config/initializers/rhino.rb")
        return [] unless File.exist?(config_path)

        content = File.read(config_path)
        if content =~ /roles.*?\[(.*?)\]/m
          $1.scan(/"([^"]+)"/).flatten
        else
          []
        end
      end

      def print_created_files(name, options)
        table_name = name.underscore.pluralize
        say ""
        say "Created files:", :yellow
        say ""
        say "  Model       app/models/#{name.underscore}.rb"
        say "  Migration   db/migrate/..._create_#{table_name}.rb"
        say "  Factory     spec/factories/#{table_name}.rb"
        say "  Config      config/initializers/rhino.rb (registered as '#{table_name}')"
        say "  Policy      app/policies/#{name.underscore}_policy.rb" if options[:policy]
        say "  Scope       app/models/scopes/#{name.underscore}_scope.rb"
      end

      def print_model_next_steps(name, table_name)
        say ""
        say "Next steps:", :yellow
        say ""
        say "  1. Run migrations: rails db:migrate"
        say "  2. Review the generated model at: app/models/#{name.underscore}.rb"
        say "  3. Run tests: rspec"
        say "  4. Your API endpoints: GET/POST /api/#{table_name}, GET/PUT/DELETE /api/#{table_name}/{id}"
        say ""
      end
    end
  end
end
