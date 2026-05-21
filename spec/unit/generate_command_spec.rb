# frozen_string_literal: true

require "spec_helper"
require "rails/command"
require "rhino/commands/generate_command"

RSpec.describe Rhino::Commands::GenerateCommand do
  let(:tmp_dir) { Dir.mktmpdir("rhino_generate_test") }
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
  # column_to_rails_validations
  # ------------------------------------------------------------------

  describe "#column_to_rails_validations" do
    def validations(column_attrs)
      column = { name: "field", type: "string", nullable: false, unique: false,
                 index: false, default: nil, foreign_model: nil }.merge(column_attrs)
      command.send(:column_to_rails_validations, column)
    end

    it "string column returns length validation" do
      expect(validations(type: "string")).to eq(["length: { maximum: 255 }"])
    end

    it "text column returns no validations" do
      expect(validations(type: "text")).to eq([])
    end

    it "integer column returns numericality" do
      expect(validations(type: "integer")).to eq(["numericality: { only_integer: true }"])
    end

    it "bigint column returns numericality" do
      expect(validations(type: "bigint")).to eq(["numericality: { only_integer: true }"])
    end

    it "boolean column returns inclusion" do
      expect(validations(type: "boolean")).to eq(["inclusion: { in: [true, false] }"])
    end

    it "date column returns no validations" do
      expect(validations(type: "date")).to eq([])
    end

    it "datetime column returns no validations" do
      expect(validations(type: "datetime")).to eq([])
    end

    it "decimal column returns no validations" do
      expect(validations(type: "decimal")).to eq([])
    end

    it "float column returns no validations" do
      expect(validations(type: "float")).to eq([])
    end

    it "json column returns no validations" do
      expect(validations(type: "json")).to eq([])
    end

    it "uuid column returns no validations" do
      expect(validations(type: "uuid")).to eq([])
    end

    it "references column returns numericality" do
      result = validations(type: "references", name: "user_id", foreign_model: "User")
      expect(result).to eq(["numericality: { only_integer: true }"])
    end
  end

  # ------------------------------------------------------------------
  # column_to_faker
  # ------------------------------------------------------------------

  describe "#column_to_faker" do
    def faker(column_attrs)
      column = { name: "field", type: "string", nullable: false, unique: false,
                 index: false, default: nil, foreign_model: nil }.merge(column_attrs)
      command.send(:column_to_faker, column)
    end

    it "name column" do
      expect(faker(name: "name")).to eq("Faker::Name.name")
    end

    it "email column" do
      expect(faker(name: "email")).to eq("Faker::Internet.email")
    end

    it "title column" do
      expect(faker(name: "title")).to eq("Faker::Lorem.sentence(word_count: 3)")
    end

    it "description column" do
      expect(faker(name: "description")).to eq("Faker::Lorem.paragraph")
    end

    it "slug column" do
      expect(faker(name: "slug")).to eq("Faker::Internet.slug")
    end

    it "phone column" do
      expect(faker(name: "phone")).to eq("Faker::PhoneNumber.phone_number")
    end

    it "is_* column" do
      expect(faker(name: "is_active")).to eq("[true, false].sample")
    end

    it "string type fallback" do
      expect(faker(name: "custom_field", type: "string"))
        .to eq("Faker::Lorem.sentence(word_count: 3)")
    end

    it "integer type" do
      expect(faker(name: "count", type: "integer"))
        .to eq("Faker::Number.between(from: 1, to: 100)")
    end

    it "boolean type" do
      expect(faker(name: "active", type: "boolean"))
        .to eq("[true, false].sample")
    end

    it "json type" do
      expect(faker(name: "metadata", type: "json")).to eq("{}")
    end

    it "uuid type" do
      expect(faker(name: "uuid_field", type: "uuid")).to eq("SecureRandom.uuid")
    end

    it "references with foreign model" do
      result = faker(name: "user_id", type: "references", foreign_model: "User")
      expect(result).to eq("association :user")
    end

    it "date type" do
      result = faker(name: "start_date", type: "date")
      expect(result).to include("Faker::Date.between")
    end

    it "decimal type" do
      result = faker(name: "price", type: "decimal")
      expect(result).to include("Faker::Number.decimal")
    end
  end

  # ------------------------------------------------------------------
  # write_model_file
  # ------------------------------------------------------------------

  describe "#write_model_file" do
    let(:columns) do
      [
        { name: "title", type: "string", nullable: false, unique: false,
          index: false, default: nil, foreign_model: nil },
        { name: "content", type: "text", nullable: true, unique: false,
          index: false, default: nil, foreign_model: nil }
      ]
    end

    it "generates a model file" do
      command.send(:write_model_file, "Article", columns, false, nil,
                   { soft_deletes: false, audit_trail: false })

      path = File.join(tmp_dir, "app/models/article.rb")
      expect(File.exist?(path)).to be true

      content = File.read(path)
      expect(content).to include("class Article < Rhino::RhinoModel")
      expect(content).to include("rhino_filters")
      expect(content).to include("rhino_sorts")
    end

    it "includes BelongsToOrganization when belongs_to_org is true" do
      command.send(:write_model_file, "Article", columns, true, nil,
                   { soft_deletes: false, audit_trail: false })

      content = File.read(File.join(tmp_dir, "app/models/article.rb"))
      expect(content).to include("Rhino::BelongsToOrganization")
    end

    it "includes Discard::Model when soft_deletes is true" do
      command.send(:write_model_file, "Article", columns, false, nil,
                   { soft_deletes: true, audit_trail: false })

      content = File.read(File.join(tmp_dir, "app/models/article.rb"))
      expect(content).to include("Discard::Model")
    end

    it "includes HasAuditTrail when audit_trail is true" do
      command.send(:write_model_file, "Article", columns, false, nil,
                   { soft_deletes: false, audit_trail: true })

      content = File.read(File.join(tmp_dir, "app/models/article.rb"))
      expect(content).to include("Rhino::HasAuditTrail")
    end

    it "does not include rhino_owner (auto-detected from belongs_to)" do
      command.send(:write_model_file, "Comment", columns, false, "post",
                   { soft_deletes: false, audit_trail: false })

      content = File.read(File.join(tmp_dir, "app/models/comment.rb"))
      expect(content).not_to include("rhino_owner")
    end

    it "generates belongs_to for references columns" do
      cols_with_ref = columns + [{
        name: "user_id", type: "references", nullable: false, unique: false,
        index: true, default: nil, foreign_model: "User"
      }]

      command.send(:write_model_file, "Article", cols_with_ref, false, nil,
                   { soft_deletes: false, audit_trail: false })

      content = File.read(File.join(tmp_dir, "app/models/article.rb"))
      expect(content).to include('belongs_to :user, class_name: "User"')
    end
  end

  # ------------------------------------------------------------------
  # write_migration_file
  # ------------------------------------------------------------------

  describe "#write_migration_file" do
    let(:columns) do
      [
        { name: "title", type: "string", nullable: false, unique: false,
          index: false, default: nil, foreign_model: nil },
        { name: "user_id", type: "references", nullable: false, unique: false,
          index: true, default: nil, foreign_model: "User" }
      ]
    end

    it "generates a migration file with correct table name" do
      command.send(:write_migration_file, "Article", columns, false)

      files = Dir.glob(File.join(tmp_dir, "db/migrate/*_create_articles.rb"))
      expect(files.length).to eq(1)

      content = File.read(files.first)
      expect(content).to include("create_table :articles")
      expect(content).to include("t.string :title")
      expect(content).to include("t.references :user")
    end

    it "includes discarded_at when soft_deletes is true" do
      command.send(:write_migration_file, "Article", columns, true)

      files = Dir.glob(File.join(tmp_dir, "db/migrate/*_create_articles.rb"))
      content = File.read(files.first)
      expect(content).to include("discarded_at")
      expect(content).to include("add_index :articles, :discarded_at")
    end
  end

  # ------------------------------------------------------------------
  # write_factory_file
  # ------------------------------------------------------------------

  describe "#write_factory_file" do
    it "generates a factory file" do
      columns = [
        { name: "title", type: "string", nullable: false, unique: false,
          index: false, default: nil, foreign_model: nil },
        { name: "email", type: "string", nullable: false, unique: true,
          index: false, default: nil, foreign_model: nil }
      ]

      command.send(:write_factory_file, "Article", columns)

      path = File.join(tmp_dir, "spec/factories/articles.rb")
      expect(File.exist?(path)).to be true

      content = File.read(path)
      expect(content).to include("factory :article")
      expect(content).to include("Faker::Lorem.sentence")
      expect(content).to include("Faker::Internet.email")
    end

    it "generates association for references columns" do
      columns = [
        { name: "user_id", type: "references", nullable: false, unique: false,
          index: true, default: nil, foreign_model: "User" }
      ]

      command.send(:write_factory_file, "Comment", columns)

      content = File.read(File.join(tmp_dir, "spec/factories/comments.rb"))
      expect(content).to include("association :user")
    end
  end

  # ------------------------------------------------------------------
  # write_policy_file
  # ------------------------------------------------------------------

  describe "#write_policy_file" do
    it "generates a policy file" do
      command.send(:write_policy_file, "Article")

      path = File.join(tmp_dir, "app/policies/article_policy.rb")
      expect(File.exist?(path)).to be true

      content = File.read(path)
      expect(content).to include("class ArticlePolicy < Rhino::ResourcePolicy")
      expect(content).to include("Attribute Permissions")
    end
  end

  # ------------------------------------------------------------------
  # write_scope_file
  # ------------------------------------------------------------------

  describe "#write_scope_file" do
    it "generates a scope file" do
      command.send(:write_scope_file, "Article")

      path = File.join(tmp_dir, "app/models/scopes/article_scope.rb")
      expect(File.exist?(path)).to be true

      content = File.read(path)
      expect(content).to include("class ArticleScope")
      expect(content).to include("Rhino::ResourceScope")
      expect(content).to include("def apply")
    end
  end

  # ------------------------------------------------------------------
  # register_model_in_config
  # ------------------------------------------------------------------

  describe "#register_model_in_config" do
    before do
      config_dir = File.join(tmp_dir, "config/initializers")
      FileUtils.mkdir_p(config_dir)

      File.write(File.join(config_dir, "rhino.rb"), <<~RUBY)
        Rhino.configure do |c|
          # c.model :posts, 'Post'
        end
      RUBY
    end

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
    it "returns true when config has route_group :tenant" do
      config_dir = File.join(tmp_dir, "config/initializers")
      FileUtils.mkdir_p(config_dir)
      File.write(File.join(config_dir, "rhino.rb"), 'c.route_group :tenant, prefix: ":organization"')

      expect(command.send(:multi_tenant_enabled?)).to be true
    end

    it "returns false when config has no tenant route group" do
      config_dir = File.join(tmp_dir, "config/initializers")
      FileUtils.mkdir_p(config_dir)
      File.write(File.join(config_dir, "rhino.rb"), 'c.route_group :default, prefix: ""')

      expect(command.send(:multi_tenant_enabled?)).to be false
    end

    it "returns false when config file does not exist" do
      expect(command.send(:multi_tenant_enabled?)).to be false
    end
  end

  # ------------------------------------------------------------------
  # get_roles_from_config
  # ------------------------------------------------------------------

  describe "#get_roles_from_config" do
    it "parses roles from config" do
      config_dir = File.join(tmp_dir, "config/initializers")
      FileUtils.mkdir_p(config_dir)
      File.write(File.join(config_dir, "rhino.rb"),
                 'roles: ["admin", "editor", "viewer"]')

      expect(command.send(:get_roles_from_config)).to eq(%w[admin editor viewer])
    end

    it "returns empty array when no roles found" do
      config_dir = File.join(tmp_dir, "config/initializers")
      FileUtils.mkdir_p(config_dir)
      File.write(File.join(config_dir, "rhino.rb"), "Rhino.configure { }")

      expect(command.send(:get_roles_from_config)).to eq([])
    end

    it "returns empty array when config does not exist" do
      expect(command.send(:get_roles_from_config)).to eq([])
    end
  end

  # ------------------------------------------------------------------
  # get_existing_models
  # ------------------------------------------------------------------

  describe "#get_existing_models" do
    it "lists model files excluding ApplicationRecord" do
      models_dir = File.join(tmp_dir, "app/models")
      FileUtils.mkdir_p(models_dir)
      File.write(File.join(models_dir, "post.rb"), "")
      File.write(File.join(models_dir, "comment.rb"), "")
      File.write(File.join(models_dir, "application_record.rb"), "")

      models = command.send(:get_existing_models)
      expect(models).to include("Post", "Comment")
      expect(models).not_to include("ApplicationRecord")
    end

    it "returns empty array when models directory does not exist" do
      expect(command.send(:get_existing_models)).to eq([])
    end
  end

  # ------------------------------------------------------------------
  # print_styled_header
  # ------------------------------------------------------------------

  describe "#print_styled_header" do
    it "outputs header without error" do
      expect { command.send(:print_styled_header) }.not_to raise_error
    end
  end

  # ------------------------------------------------------------------
  # generate_policy
  # ------------------------------------------------------------------

  describe "#generate_policy" do
    it "generates a policy file for named model" do
      command.send(:generate_policy, "Article")

      path = File.join(tmp_dir, "app/policies/article_policy.rb")
      expect(File.exist?(path)).to be true

      content = File.read(path)
      expect(content).to include("class ArticlePolicy < Rhino::ResourcePolicy")
    end
  end

  # ------------------------------------------------------------------
  # generate_scope
  # ------------------------------------------------------------------

  describe "#generate_scope" do
    it "generates a scope file for named model" do
      command.send(:generate_scope, "Article")

      path = File.join(tmp_dir, "app/models/scopes/article_scope.rb")
      expect(File.exist?(path)).to be true

      content = File.read(path)
      expect(content).to include("ArticleScope")
    end
  end

  # ------------------------------------------------------------------
  # write_migration_file with different column types
  # ------------------------------------------------------------------

  describe "#write_migration_file with various types" do
    it "generates decimal column in migration" do
      columns = [
        { name: "price", type: "decimal", nullable: false, unique: false,
          index: false, default: nil, foreign_model: nil }
      ]

      command.send(:write_migration_file, "Product", columns, false)

      files = Dir.glob(File.join(tmp_dir, "db/migrate/*_create_products.rb"))
      content = File.read(files.first)
      expect(content).to include("t.decimal :price")
    end

    it "generates boolean column in migration" do
      columns = [
        { name: "is_active", type: "boolean", nullable: false, unique: false,
          index: false, default: nil, foreign_model: nil }
      ]

      command.send(:write_migration_file, "Setting", columns, false)

      files = Dir.glob(File.join(tmp_dir, "db/migrate/*_create_settings.rb"))
      content = File.read(files.first)
      expect(content).to include("t.boolean :is_active")
    end

    it "generates json column in migration" do
      columns = [
        { name: "metadata", type: "json", nullable: true, unique: false,
          index: false, default: nil, foreign_model: nil }
      ]

      command.send(:write_migration_file, "Config", columns, false)

      files = Dir.glob(File.join(tmp_dir, "db/migrate/*_create_configs.rb"))
      content = File.read(files.first)
      expect(content).to include("t.json :metadata")
    end
  end
end
