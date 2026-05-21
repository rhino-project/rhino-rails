# frozen_string_literal: true

require "spec_helper"
require "rails/command"
require "rhino/commands/install_command"

RSpec.describe Rhino::Commands::InstallCommand do
  let(:tmp_dir) { Dir.mktmpdir("rhino_install_test") }
  let(:tmp_root) { Pathname.new(tmp_dir) }
  let(:command) { described_class.new }

  before do
    Rails.define_singleton_method(:root) { tmp_root } unless Rails.respond_to?(:root)
    allow(Rails).to receive(:root).and_return(tmp_root)
    allow(command).to receive(:say)
  end

  after do
    FileUtils.remove_entry(tmp_dir)
  end

  # ------------------------------------------------------------------
  # publish_config
  # ------------------------------------------------------------------

  describe "#publish_config" do
    it "creates config/initializers/rhino.rb" do
      command.send(:publish_config, "rspec")

      path = File.join(tmp_dir, "config/initializers/rhino.rb")
      expect(File.exist?(path)).to be true

      content = File.read(path)
      expect(content).to include("Rhino.configure")
      expect(content).to include("Models")
      expect(content).to include("Multi-tenant")
    end

    it "creates parent directories if they don't exist" do
      command.send(:publish_config, "rspec")

      expect(Dir.exist?(File.join(tmp_dir, "config/initializers"))).to be true
    end

    it "uses fully qualified middleware constant in comments" do
      command.send(:publish_config, "rspec")

      path = File.join(tmp_dir, "config/initializers/rhino.rb")
      content = File.read(path)
      expect(content).to include("Rhino::Middleware::ResolveOrganizationFromRoute")
      expect(content).not_to match(/\b(?<!:)ResolveOrganizationFromRoute/)
    end

    it "publishes a config that can be evaluated without NameError" do
      command.send(:publish_config, "rspec")

      path = File.join(tmp_dir, "config/initializers/rhino.rb")
      content = File.read(path)

      Rhino.reset_configuration!
      expect { eval(content) }.not_to raise_error
    end
  end

  # ------------------------------------------------------------------
  # publish_routes
  # ------------------------------------------------------------------

  describe "#publish_routes" do
    it "copies routes template to config/routes/rhino.rb" do
      command.send(:publish_routes)

      path = File.join(tmp_dir, "config/routes/rhino.rb")
      expect(File.exist?(path)).to be true

      content = File.read(path)
      expect(content).to include("Rhino routes")
    end
  end

  # ------------------------------------------------------------------
  # create_multi_tenant_migrations
  # ------------------------------------------------------------------

  describe "#create_multi_tenant_migrations" do
    it "creates 4 migration files" do
      command.send(:create_multi_tenant_migrations)

      user_files = Dir.glob(File.join(tmp_dir, "db/migrate/*_create_users.rb"))
      org_files = Dir.glob(File.join(tmp_dir, "db/migrate/*_create_organizations.rb"))
      role_files = Dir.glob(File.join(tmp_dir, "db/migrate/*_create_roles.rb"))
      user_role_files = Dir.glob(File.join(tmp_dir, "db/migrate/*_create_user_roles.rb"))

      expect(user_files.length).to eq(1)
      expect(org_files.length).to eq(1)
      expect(role_files.length).to eq(1)
      expect(user_role_files.length).to eq(1)
    end

    it "generates non-empty migration content" do
      command.send(:create_multi_tenant_migrations)

      Dir.glob(File.join(tmp_dir, "db/migrate/*.rb")).each do |f|
        content = File.read(f)
        expect(content).not_to be_empty
        expect(content).to include("create_table")
      end
    end

    it "generates timestamped filenames" do
      command.send(:create_multi_tenant_migrations)

      Dir.glob(File.join(tmp_dir, "db/migrate/*.rb")).each do |f|
        basename = File.basename(f)
        expect(basename).to match(/\A\d{16}_/)
      end
    end
  end

  # ------------------------------------------------------------------
  # create_multi_tenant_models
  # ------------------------------------------------------------------

  describe "#create_multi_tenant_models" do
    it "creates User, Organization, Role, and UserRole models" do
      command.send(:create_multi_tenant_models, %w[admin editor viewer])

      %w[user organization role user_role].each do |model|
        path = File.join(tmp_dir, "app/models/#{model}.rb")
        expect(File.exist?(path)).to be true
        expect(File.read(path)).not_to be_empty
      end
    end

    it "generates User model with HasPermissions and has_secure_password" do
      command.send(:create_multi_tenant_models, %w[admin])

      user_content = File.read(File.join(tmp_dir, "app/models/user.rb"))
      expect(user_content).to include("Rhino::HasPermissions")
      expect(user_content).to include("has_secure_password")
      expect(user_content).to include("has_many :user_roles")
    end

    it "passes roles to the Role model template" do
      command.send(:create_multi_tenant_models, %w[admin editor])

      role_content = File.read(File.join(tmp_dir, "app/models/role.rb"))
      expect(role_content).not_to be_empty
    end
  end

  # ------------------------------------------------------------------
  # create_factories
  # ------------------------------------------------------------------

  describe "#create_factories" do
    it "creates 4 factory files in spec/factories" do
      command.send(:create_factories)

      %w[users organizations roles user_roles].each do |factory|
        path = File.join(tmp_dir, "spec/factories/#{factory}.rb")
        expect(File.exist?(path)).to be true
        expect(File.read(path)).not_to be_empty
      end
    end
  end

  # ------------------------------------------------------------------
  # create_policies
  # ------------------------------------------------------------------

  describe "#create_policies" do
    it "creates OrganizationPolicy and RolePolicy" do
      command.send(:create_policies)

      %w[organization_policy role_policy].each do |policy|
        path = File.join(tmp_dir, "app/policies/#{policy}.rb")
        expect(File.exist?(path)).to be true
        expect(File.read(path)).not_to be_empty
      end
    end
  end

  # ------------------------------------------------------------------
  # create_seeders
  # ------------------------------------------------------------------

  describe "#create_seeders" do
    it "creates role seeder with correct content" do
      roles = %w[admin editor viewer]
      command.send(:create_seeders, roles)

      seeder_path = File.join(tmp_dir, "db/seeds/role_seeder.rb")
      expect(File.exist?(seeder_path)).to be true

      content = File.read(seeder_path)
      roles.each do |role|
        expect(content).to include(role)
      end
      expect(content).to include("find_or_create_by!")
    end

    it "creates organization seeder" do
      command.send(:create_seeders, %w[admin])

      seeder_path = File.join(tmp_dir, "db/seeds/organization_seeder.rb")
      expect(File.exist?(seeder_path)).to be true
      expect(File.read(seeder_path)).not_to be_empty
    end

    it "includes descriptions for standard roles" do
      command.send(:create_seeders, %w[admin editor viewer])

      content = File.read(File.join(tmp_dir, "db/seeds/role_seeder.rb"))
      expect(content).to include("Administrator role with full access")
      expect(content).to include("Editor role with create, read, and update access")
      expect(content).to include("Viewer role with read-only access")
    end
  end

  # ------------------------------------------------------------------
  # create_audit_trail_migration
  # ------------------------------------------------------------------

  describe "#create_audit_trail_migration" do
    it "creates an audit_logs migration" do
      command.send(:create_audit_trail_migration)

      files = Dir.glob(File.join(tmp_dir, "db/migrate/*_create_audit_logs.rb"))
      expect(files.length).to eq(1)

      content = File.read(files.first)
      expect(content).to include("create_table")
      expect(content).to include("audit_logs")
    end

    it "skips if audit_logs migration already exists" do
      # Create an existing migration
      migrate_dir = File.join(tmp_dir, "db/migrate")
      FileUtils.mkdir_p(migrate_dir)
      File.write(File.join(migrate_dir, "20240101000000_create_audit_logs.rb"), "existing")

      command.send(:create_audit_trail_migration)

      files = Dir.glob(File.join(tmp_dir, "db/migrate/*_create_audit_logs.rb"))
      expect(files.length).to eq(1)
      expect(File.read(files.first)).to eq("existing")
    end
  end

  # ------------------------------------------------------------------
  # update_config
  # ------------------------------------------------------------------

  describe "#update_config" do
    before do
      command.send(:publish_config, "rspec")
    end

    it "updates organization_identifier_column in config" do
      config_path = File.join(tmp_dir, "config/initializers/rhino.rb")
      content = File.read(config_path, encoding: "UTF-8")
      content += "\n  c.multi_tenant = {\n    organization_identifier_column: \"id\"\n  }\n"
      File.write(config_path, content)

      command.send(:update_config, "slug")

      updated = File.read(config_path, encoding: "UTF-8")
      expect(updated).to include('organization_identifier_column: "slug"')
    end

    it "does nothing if config file does not exist" do
      FileUtils.rm_f(File.join(tmp_dir, "config/initializers/rhino.rb"))
      expect { command.send(:update_config, "id") }.not_to raise_error
    end

    it "adds organization and role models to config" do
      command.send(:update_config, "slug")

      config_path = File.join(tmp_dir, "config/initializers/rhino.rb")
      updated = File.read(config_path, encoding: "UTF-8")
      expect(updated).to include("config.model :organizations, 'Organization'")
      expect(updated).to include("config.model :roles, 'Role'")
    end

    it "adds tenant route group to config with fully qualified middleware" do
      command.send(:update_config, "slug")

      config_path = File.join(tmp_dir, "config/initializers/rhino.rb")
      content = File.read(config_path, encoding: "UTF-8")
      expect(content).to include("config.route_group :tenant")
      expect(content).to include("Rhino::Middleware::ResolveOrganizationFromRoute")
    end

    it "uses the config block variable, not a different name" do
      command.send(:update_config, "slug")

      config_path = File.join(tmp_dir, "config/initializers/rhino.rb")
      content = File.read(config_path, encoding: "UTF-8")
      # All non-comment lines using model/route_group must use "config.", not "c."
      active_lines = content.lines.reject { |l| l.strip.start_with?("#") }
      active_lines.each do |line|
        next unless line.match?(/\.(model|route_group)\s+:/)

        expect(line).to include("config."), "Expected 'config.' but found: #{line.strip}"
      end
    end

    it "does not duplicate organizations model if already present" do
      command.send(:update_config, "slug")
      command.send(:update_config, "slug")

      config_path = File.join(tmp_dir, "config/initializers/rhino.rb")
      content = File.read(config_path, encoding: "UTF-8")
      expect(content.scan("config.model :organizations").length).to eq(1)
    end

    it "generates config that can be evaluated without NameError" do
      command.send(:update_config, "slug")

      config_path = File.join(tmp_dir, "config/initializers/rhino.rb")
      content = File.read(config_path, encoding: "UTF-8")

      # The middleware constant must be resolvable at eval time
      expect(defined?(Rhino::Middleware::ResolveOrganizationFromRoute)).to be_truthy

      # The generated config must eval without raising NameError
      Rhino.reset_configuration!
      expect { eval(content) }.not_to raise_error
    end
  end

  # ------------------------------------------------------------------
  # create_blueprint_directory
  # ------------------------------------------------------------------

  describe "#create_blueprint_directory" do
    it "creates .rhino/blueprints directory" do
      command.send(:create_blueprint_directory)

      expect(Dir.exist?(File.join(tmp_dir, ".rhino/blueprints"))).to be true
    end

    it "creates BLUEPRINT.md guide file" do
      command.send(:create_blueprint_directory)

      guide_path = File.join(tmp_dir, ".rhino/BLUEPRINT.md")
      expect(File.exist?(guide_path)).to be true
      expect(File.read(guide_path)).to include("Rhino Blueprint")
    end

    it "does not overwrite existing BLUEPRINT.md" do
      FileUtils.mkdir_p(File.join(tmp_dir, ".rhino"))
      File.write(File.join(tmp_dir, ".rhino/BLUEPRINT.md"), "custom content")

      command.send(:create_blueprint_directory)

      content = File.read(File.join(tmp_dir, ".rhino/BLUEPRINT.md"))
      expect(content).to eq("custom content")
    end
  end

  # ------------------------------------------------------------------
  # print_next_steps
  # ------------------------------------------------------------------

  describe "#print_next_steps" do
    it "prints audit trail step when included" do
      expect(command).to receive(:say).with(/HasAuditTrail/).at_least(:once)
      command.send(:print_next_steps, ["audit_trail"])
    end

    it "prints multi_tenant step when included" do
      expect(command).to receive(:say).with(/HasPermissions/).at_least(:once)
      command.send(:print_next_steps, ["multi_tenant"])
    end

    it "prints both steps when both features included" do
      expect(command).to receive(:say).with(/HasAuditTrail/).at_least(:once)
      expect(command).to receive(:say).with(/HasPermissions/).at_least(:once)
      command.send(:print_next_steps, ["audit_trail", "multi_tenant"])
    end
  end

  # ------------------------------------------------------------------
  # blueprint_guide_content
  # ------------------------------------------------------------------

  describe "#blueprint_guide_content" do
    it "returns markdown content" do
      content = command.send(:blueprint_guide_content)
      expect(content).to include("Rhino Blueprint")
      expect(content).to include("Quick Start")
      expect(content).to include("Valid Column Types")
    end
  end
end
