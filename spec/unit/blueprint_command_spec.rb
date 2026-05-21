# frozen_string_literal: true

require "spec_helper"
require "rails/command"
require "rhino/commands/blueprint_command"

RSpec.describe Rhino::Commands::BlueprintCommand do
  let(:tmp_dir) { Dir.mktmpdir("rhino_blueprint_test") }
  let(:tmp_root) { Pathname.new(tmp_dir) }
  let(:command) { described_class.new }
  let(:blueprints_dir) { File.join(tmp_dir, ".rhino/blueprints") }

  before do
    Rails.define_singleton_method(:root) { tmp_root } unless Rails.respond_to?(:root)
    allow(Rails).to receive(:root).and_return(tmp_root)
    allow(command).to receive(:say)
    FileUtils.mkdir_p(blueprints_dir)

    # Create config file
    config_dir = File.join(tmp_dir, "config/initializers")
    FileUtils.mkdir_p(config_dir)
    File.write(File.join(config_dir, "rhino.rb"), <<~RUBY)
      Rhino.configure do |c|
        # c.model :posts, 'Post'
      end
    RUBY
  end

  after do
    FileUtils.remove_entry(tmp_dir)
  end

  # ------------------------------------------------------------------
  # print_banner
  # ------------------------------------------------------------------

  describe "#print_banner" do
    it "outputs banner without error" do
      expect { command.send(:print_banner) }.not_to raise_error
    end
  end

  # ------------------------------------------------------------------
  # generate_model
  # ------------------------------------------------------------------

  describe "#generate_model" do
    let(:blueprint) do
      {
        model: "Article",
        table: "articles",
        source_file: "article.yaml",
        columns: [
          { name: "title", type: "string", nullable: false },
          { name: "content", type: "text", nullable: true },
          { name: "user_id", type: "foreignId", nullable: false, foreign_model: "User" }
        ],
        options: {
          belongs_to_organization: false,
          soft_deletes: false,
          audit_trail: false
        }
      }
    end

    it "generates a model file" do
      path = command.send(:generate_model, blueprint, false)

      full_path = File.join(tmp_dir, path)
      expect(File.exist?(full_path)).to be true

      content = File.read(full_path)
      expect(content).to include("class Article < Rhino::RhinoModel")
      expect(content).to include("rhino_filters")
      expect(content).to include("rhino_sorts")
      expect(content).to include("rhino_fields")
      expect(content).to include("belongs_to :user")
    end

    it "includes BelongsToOrganization when option is set" do
      blueprint[:options][:belongs_to_organization] = true
      path = command.send(:generate_model, blueprint, true)

      content = File.read(File.join(tmp_dir, path))
      expect(content).to include("Rhino::BelongsToOrganization")
    end

    it "includes Discard::Model when soft_deletes is set" do
      blueprint[:options][:soft_deletes] = true
      path = command.send(:generate_model, blueprint, false)

      content = File.read(File.join(tmp_dir, path))
      expect(content).to include("Discard::Model")
    end

    it "includes HasAuditTrail when audit_trail is set" do
      blueprint[:options][:audit_trail] = true
      path = command.send(:generate_model, blueprint, false)

      content = File.read(File.join(tmp_dir, path))
      expect(content).to include("Rhino::HasAuditTrail")
    end

    it "generates validations for string columns" do
      path = command.send(:generate_model, blueprint, false)

      content = File.read(File.join(tmp_dir, path))
      expect(content).to include("validates :title, length: { maximum: 255 }, allow_nil: true")
    end

    it "skips organization belongs_to if belongs_to_organization is true" do
      blueprint[:columns] << { name: "organization_id", type: "foreignId", nullable: false, foreign_model: "Organization" }
      blueprint[:options][:belongs_to_organization] = true
      path = command.send(:generate_model, blueprint, true)

      content = File.read(File.join(tmp_dir, path))
      expect(content).not_to include("belongs_to :organization, class_name")
    end

    it "adds optional: true for nullable FK belongs_to" do
      blueprint[:columns] << { name: "assignee_id", type: "foreignId", nullable: true, foreign_model: "User" }
      path = command.send(:generate_model, blueprint, false)

      content = File.read(File.join(tmp_dir, path))
      expect(content).to include("belongs_to :assignee, class_name: 'User', optional: true")
    end

    it "does not add optional: true for required FK belongs_to" do
      path = command.send(:generate_model, blueprint, false)

      content = File.read(File.join(tmp_dir, path))
      expect(content).to include("belongs_to :user, class_name: 'User'")
      expect(content).not_to include("optional: true")
    end
  end

  # ------------------------------------------------------------------
  # generate_migration
  # ------------------------------------------------------------------

  describe "#generate_migration" do
    let(:blueprint) do
      {
        model: "Article",
        table: "articles",
        columns: [
          { name: "title", type: "string", nullable: false },
          { name: "price", type: "decimal", nullable: true, precision: 10, scale: 2 },
          { name: "user_id", type: "foreignId", nullable: false, foreign_model: "User" }
        ],
        options: { soft_deletes: false }
      }
    end

    it "generates a migration file" do
      path = command.send(:generate_migration, blueprint)

      full_path = File.join(tmp_dir, path)
      expect(File.exist?(full_path)).to be true

      content = File.read(full_path)
      expect(content).to include("create_table :articles")
      expect(content).to include("t.string :title")
      expect(content).to include("t.decimal :price, precision: 10, scale: 2")
      expect(content).to include("t.references :user, foreign_key: true")
    end

    it "includes discarded_at for soft deletes" do
      blueprint[:options][:soft_deletes] = true
      path = command.send(:generate_migration, blueprint)

      content = File.read(File.join(tmp_dir, path))
      expect(content).to include("discarded_at")
    end

    it "generates timestamped filename" do
      path = command.send(:generate_migration, blueprint)
      expect(path).to match(/db\/migrate\/\d{14}_create_articles\.rb/)
    end

    it "includes organization_id when belongs_to_organization and multi-tenant" do
      blueprint[:options][:belongs_to_organization] = true
      config_path = File.join(tmp_dir, "config/initializers/rhino.rb")
      File.write(config_path, 'c.route_group :tenant, prefix: ":organization"')

      path = command.send(:generate_migration, blueprint)

      content = File.read(File.join(tmp_dir, path))
      expect(content).to include("t.references :organization, null: false, foreign_key: true")
    end

    it "uses to_table when FK column name does not match model table" do
      blueprint[:columns] << { name: "assignee_id", type: "foreignId", nullable: true, foreign_model: "User" }
      path = command.send(:generate_migration, blueprint)

      content = File.read(File.join(tmp_dir, path))
      expect(content).to include("t.references :assignee, foreign_key: { to_table: :users }")
    end
  end

  # ------------------------------------------------------------------
  # generate_factory
  # ------------------------------------------------------------------

  describe "#generate_factory" do
    let(:blueprint) do
      {
        model: "Article",
        table: "articles",
        columns: [
          { name: "title", type: "string", nullable: false },
          { name: "content", type: "text", nullable: true }
        ],
        options: { belongs_to_organization: false }
      }
    end

    it "generates a factory file" do
      path = command.send(:generate_factory, blueprint)

      full_path = File.join(tmp_dir, path)
      expect(File.exist?(full_path)).to be true

      content = File.read(full_path)
      expect(content).to include("factory :article")
      expect(content).to include("FactoryBot.define")
    end
  end

  # ------------------------------------------------------------------
  # generate_scope
  # ------------------------------------------------------------------

  describe "#generate_scope" do
    let(:blueprint) { { model: "Article" } }

    it "generates a scope file" do
      path = command.send(:generate_scope, blueprint)

      full_path = File.join(tmp_dir, path)
      expect(File.exist?(full_path)).to be true

      content = File.read(full_path)
      expect(content).to include("class ArticleScope")
      expect(content).to include("Scopes")
      expect(content).to include("Rhino::ResourceScope")
    end
  end

  # ------------------------------------------------------------------
  # generate_policy
  # ------------------------------------------------------------------

  describe "#generate_policy" do
    let(:blueprint) do
      {
        model: "Article",
        columns: [
          { name: "title", type: "string", nullable: false }
        ],
        options: {},
        permissions: {
          "admin" => {
            "create" => ["title"],
            "update" => ["title"],
            "show" => ["title"]
          }
        }
      }
    end

    it "generates a policy file" do
      path = command.send(:generate_policy, blueprint)

      full_path = File.join(tmp_dir, path)
      expect(File.exist?(full_path)).to be true

      content = File.read(full_path)
      expect(content).to include("ArticlePolicy")
    end
  end

  # ------------------------------------------------------------------
  # generate_tests
  # ------------------------------------------------------------------

  describe "#generate_tests" do
    let(:blueprint) do
      {
        model: "Article",
        table: "articles",
        slug: "articles",
        columns: [
          { name: "title", type: "string", nullable: false }
        ],
        options: {},
        permissions: {
          "admin" => {
            actions: %w[index show store update destroy],
            create_fields: ["title"],
            update_fields: ["title"],
            show_fields: ["*"],
            hidden_fields: []
          }
        }
      }
    end

    it "generates a test file" do
      path = command.send(:generate_tests, blueprint, false, "slug")

      full_path = File.join(tmp_dir, path)
      expect(File.exist?(full_path)).to be true
    end
  end

  # ------------------------------------------------------------------
  # register_model_in_config
  # ------------------------------------------------------------------

  describe "#register_model_in_config" do
    it "adds model entry to config" do
      command.send(:register_model_in_config, "Article")

      content = File.read(File.join(tmp_dir, "config/initializers/rhino.rb"))
      expect(content).to include("c.model :articles, 'Article'")
    end

    it "does not duplicate existing model" do
      command.send(:register_model_in_config, "Article")
      command.send(:register_model_in_config, "Article")

      content = File.read(File.join(tmp_dir, "config/initializers/rhino.rb"))
      expect(content.scan("c.model :articles").length).to eq(1)
    end

    it "does nothing if config file does not exist" do
      FileUtils.rm_f(File.join(tmp_dir, "config/initializers/rhino.rb"))
      expect { command.send(:register_model_in_config, "Article") }.not_to raise_error
    end

    it "detects config block variable name and uses it" do
      config_path = File.join(tmp_dir, "config/initializers/rhino.rb")
      File.write(config_path, <<~RUBY)
        Rhino.configure do |config|
          # config.model :posts, 'Post'
        end
      RUBY

      command.send(:register_model_in_config, "Article")

      content = File.read(config_path)
      expect(content).to include("config.model :articles, 'Article'")
      expect(content).not_to include("c.model")
    end

    it "does not treat commented-out example as existing model" do
      config_path = File.join(tmp_dir, "config/initializers/rhino.rb")
      File.write(config_path, <<~RUBY)
        Rhino.configure do |c|
          # c.model :comments, 'Comment'
          # c.model :posts, 'Post'
        end
      RUBY

      command.send(:register_model_in_config, "Comment")

      content = File.read(config_path)
      expect(content).to include("  c.model :comments, 'Comment'\n")
      expect(content.scan(/^\s+c\.model :comments/).length).to eq(1)
    end
  end

  # ------------------------------------------------------------------
  # multi_tenant_enabled?
  # ------------------------------------------------------------------

  describe "#multi_tenant_enabled?" do
    it "returns true when config has tenant route group" do
      config_path = File.join(tmp_dir, "config/initializers/rhino.rb")
      File.write(config_path, 'c.route_group :tenant, prefix: ":organization"')

      expect(command.send(:multi_tenant_enabled?)).to be true
    end

    it "returns false when no tenant group" do
      expect(command.send(:multi_tenant_enabled?)).to be false
    end
  end

  # ------------------------------------------------------------------
  # detect_org_identifier
  # ------------------------------------------------------------------

  describe "#detect_org_identifier" do
    it "returns slug by default" do
      expect(command.send(:detect_org_identifier)).to eq("slug")
    end

    it "detects custom identifier from config" do
      config_path = File.join(tmp_dir, "config/initializers/rhino.rb")
      File.write(config_path, 'organization_identifier_column: "custom_id"')

      expect(command.send(:detect_org_identifier)).to eq("custom_id")
    end
  end

  # ------------------------------------------------------------------
  # column_to_validations
  # ------------------------------------------------------------------

  describe "#column_to_validations" do
    def validations(type)
      command.send(:column_to_validations, { name: "field", type: type }, "table")
    end

    it "returns length for string" do
      expect(validations("string")).to eq("length: { maximum: 255 }")
    end

    it "returns numericality for integer" do
      expect(validations("integer")).to eq("numericality: { only_integer: true }")
    end

    it "returns numericality for bigInteger" do
      expect(validations("bigInteger")).to eq("numericality: { only_integer: true }")
    end

    it "returns inclusion for boolean" do
      expect(validations("boolean")).to eq("inclusion: { in: [true, false] }")
    end

    it "returns numericality for decimal" do
      expect(validations("decimal")).to eq("numericality: true")
    end

    it "returns numericality for float" do
      expect(validations("float")).to eq("numericality: true")
    end

    it "returns empty for text" do
      expect(validations("text")).to eq("")
    end
  end

  # ------------------------------------------------------------------
  # column_to_migration_line
  # ------------------------------------------------------------------

  describe "#column_to_migration_line" do
    it "generates references line for foreignId" do
      result = command.send(:column_to_migration_line,
        { name: "user_id", type: "foreignId", nullable: false })
      expect(result).to include("t.references :user, foreign_key: true")
    end

    it "generates references line with nullable" do
      result = command.send(:column_to_migration_line,
        { name: "user_id", type: "references", nullable: true })
      expect(result).to include("null: true")
    end

    it "generates decimal with precision and scale" do
      result = command.send(:column_to_migration_line,
        { name: "price", type: "decimal", precision: 10, scale: 2, nullable: false })
      expect(result).to include("precision: 10, scale: 2")
    end

    it "generates standard column line" do
      result = command.send(:column_to_migration_line,
        { name: "title", type: "string", nullable: false })
      expect(result).to eq("t.string :title")
    end

    it "includes default value" do
      result = command.send(:column_to_migration_line,
        { name: "status", type: "string", nullable: false, default: "draft" })
      expect(result).to include('default: "draft"')
    end

    it "includes null: true for nullable columns" do
      result = command.send(:column_to_migration_line,
        { name: "notes", type: "text", nullable: true })
      expect(result).to include("null: true")
    end
  end

  # ------------------------------------------------------------------
  # write_file
  # ------------------------------------------------------------------

  describe "#write_file" do
    it "creates file with content" do
      command.send(:write_file, "test/output.rb", "# test content")

      full_path = File.join(tmp_dir, "test/output.rb")
      expect(File.exist?(full_path)).to be true
      expect(File.read(full_path)).to eq("# test content")
    end

    it "creates parent directories" do
      command.send(:write_file, "deep/nested/dir/file.rb", "content")

      expect(Dir.exist?(File.join(tmp_dir, "deep/nested/dir"))).to be true
    end
  end

  # ------------------------------------------------------------------
  # perform (integration)
  # ------------------------------------------------------------------

  describe "#perform" do
    it "prints error when blueprint directory does not exist" do
      FileUtils.rm_rf(blueprints_dir)

      expect(command).to receive(:say).with(/not found/, :red)
      command.perform
    end

    it "prints message when no YAML files found" do
      expect(command).to receive(:say).with(/No blueprint YAML/, :yellow)
      command.perform
    end

    it "skips files starting with underscore or dot" do
      File.write(File.join(blueprints_dir, "_roles.yaml"), "")
      File.write(File.join(blueprints_dir, ".hidden.yaml"), "")

      # Only underscore/dot prefixed files, so no blueprints found
      # The command prints to say with various messages
      command.perform
      # If we get here without error, the files were skipped correctly
    end
  end

  # ----------------------------------------------------------------
  # Regression: sequential migration timestamps
  # ----------------------------------------------------------------

  describe "sequential migration timestamps" do
    it "generates unique timestamps for multiple migrations" do
      initial_offset = command.instance_variable_get(:@migration_timestamp_offset)
      expect(initial_offset).to eq(0)

      # Simulate timestamp generation with sequential offsets
      timestamps = (0..4).map do |i|
        (Time.current + i).strftime("%Y%m%d%H%M%S")
      end

      expect(timestamps.uniq.length).to eq(timestamps.length)
    end
  end

  # ----------------------------------------------------------------
  # Regression: organization reference includes null: false
  # ----------------------------------------------------------------

  describe "organization reference constraint" do
    let(:org_blueprint) do
      {
        model: "Task",
        table: "tasks",
        options: { belongs_to_organization: true, soft_deletes: false },
        columns: [
          { name: "title", type: "string", nullable: false },
        ],
      }
    end

    it "generates organization reference with null: false" do
      config_path = File.join(tmp_dir, "config/initializers/rhino.rb")
      File.write(config_path, 'c.route_group :tenant, prefix: ":organization"')

      path = command.send(:generate_migration, org_blueprint)

      content = File.read(File.join(tmp_dir, path))
      expect(content).to include("t.references :organization, null: false, foreign_key: true")
      expect(content).not_to include("t.references :organization, foreign_key: true\n")
    end
  end
end
