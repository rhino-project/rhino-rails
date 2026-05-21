# frozen_string_literal: true

require "spec_helper"
require "rhino/blueprint/blueprint_validator"

RSpec.describe Rhino::Blueprint::BlueprintValidator do
  let(:validator) { described_class.new }

  def make_column(overrides = {})
    {
      name: "title", type: "string", nullable: false, unique: false,
      index: false, default: nil, filterable: false, sortable: false,
      searchable: false, precision: nil, scale: nil, foreign_model: nil
    }.merge(overrides)
  end

  def make_options(overrides = {})
    {
      belongs_to_organization: false, soft_deletes: true, audit_trail: false,
      owner: nil, except_actions: [], pagination: false, per_page: 25
    }.merge(overrides)
  end

  def make_blueprint(overrides = {})
    {
      model: "Post", slug: "posts", table: "posts",
      options: make_options, columns: [make_column],
      relationships: [], permissions: {}, source_file: "posts.yaml"
    }.merge(overrides)
  end

  def make_roles
    {
      "owner" => { name: "Owner", description: "Full access" },
      "admin" => { name: "Admin", description: "Admin access" },
      "viewer" => { name: "Viewer", description: "Read-only" }
    }
  end

  # ──────────────────────────────────────────────
  # validate_roles
  # ──────────────────────────────────────────────

  describe "#validate_roles" do
    it "validates valid roles" do
      result = validator.validate_roles(make_roles)
      expect(result[:valid]).to be true
      expect(result[:errors]).to be_empty
    end

    it "rejects empty roles" do
      result = validator.validate_roles({})
      expect(result[:valid]).to be false
      expect(result[:errors]).to include(match(/At least one role/))
    end

    it "rejects invalid role slug" do
      roles = { "Invalid-Slug" => { name: "Bad", description: "" } }
      result = validator.validate_roles(roles)
      expect(result[:valid]).to be false
      expect(result[:errors]).to include(match(/Invalid role slug/))
    end

    it "rejects role missing name" do
      roles = { "admin" => { name: "", description: "test" } }
      result = validator.validate_roles(roles)
      expect(result[:valid]).to be false
      expect(result[:errors]).to include(match(/non-empty name/))
    end
  end

  # ──────────────────────────────────────────────
  # validate_model
  # ──────────────────────────────────────────────

  describe "#validate_model" do
    it "validates valid minimal blueprint" do
      result = validator.validate_model(make_blueprint)
      expect(result[:valid]).to be true
      expect(result[:errors]).to be_empty
    end

    it "rejects missing model name" do
      result = validator.validate_model(make_blueprint(model: ""))
      expect(result[:valid]).to be false
      expect(result[:errors]).to include(match(/Model name is required/))
    end

    it "rejects non-PascalCase model name" do
      result = validator.validate_model(make_blueprint(model: "blogPost"))
      expect(result[:valid]).to be false
      expect(result[:errors]).to include(match(/PascalCase/))
    end

    it "rejects invalid column type" do
      bp = make_blueprint(columns: [make_column(name: "field", type: "varchar")])
      result = validator.validate_model(bp)
      expect(result[:valid]).to be false
      expect(result[:errors]).to include(match(/Invalid column type 'varchar'/))
    end

    it "rejects duplicate column names" do
      bp = make_blueprint(columns: [make_column(name: "title"), make_column(name: "title")])
      result = validator.validate_model(bp)
      expect(result[:valid]).to be false
      expect(result[:errors]).to include(match(/Duplicate column name 'title'/))
    end

    it "rejects foreignId without foreign_model" do
      bp = make_blueprint(columns: [make_column(name: "user_id", type: "foreignId", foreign_model: nil)])
      result = validator.validate_model(bp)
      expect(result[:valid]).to be false
      expect(result[:errors]).to include(match(/missing 'foreign_model'/))
    end

    it "rejects unknown role in permissions" do
      bp = make_blueprint(permissions: {
        "unknown_role" => {
          actions: ["index"], show_fields: ["*"],
          create_fields: [], update_fields: [], hidden_fields: []
        }
      })
      result = validator.validate_model(bp, make_roles)
      expect(result[:valid]).to be false
      expect(result[:errors]).to include(match(/Unknown role 'unknown_role'/))
    end

    it "rejects invalid action name" do
      bp = make_blueprint(permissions: {
        "owner" => {
          actions: ["delete"], show_fields: ["*"],
          create_fields: [], update_fields: [], hidden_fields: []
        }
      })
      result = validator.validate_model(bp, make_roles)
      expect(result[:valid]).to be false
      expect(result[:errors]).to include(match(/Invalid action 'delete'/))
    end

    it "warns on unknown field in show_fields" do
      bp = make_blueprint(
        columns: [make_column(name: "title")],
        permissions: {
          "owner" => {
            actions: %w[index show], show_fields: %w[title nonexistent_field],
            create_fields: [], update_fields: [], hidden_fields: []
          }
        }
      )
      result = validator.validate_model(bp, make_roles)
      expect(result[:warnings]).to include(match(/unknown field 'nonexistent_field'/))
    end

    it "warns on show/hidden field conflict" do
      bp = make_blueprint(
        columns: [make_column(name: "title")],
        permissions: {
          "viewer" => {
            actions: %w[index show], show_fields: ["title"],
            create_fields: [], update_fields: [], hidden_fields: ["title"]
          }
        }
      )
      result = validator.validate_model(bp, make_roles)
      expect(result[:warnings]).to include(match(/both show_fields and hidden_fields/))
    end

    it "warns on create_fields without store action" do
      bp = make_blueprint(
        columns: [make_column(name: "title")],
        permissions: {
          "viewer" => {
            actions: %w[index show], show_fields: ["title"],
            create_fields: ["title"], update_fields: [], hidden_fields: []
          }
        }
      )
      result = validator.validate_model(bp, make_roles)
      expect(result[:warnings]).to include(match(/create_fields but no 'store' action/))
    end

    it "rejects invalid except_action" do
      bp = make_blueprint(options: make_options(except_actions: ["invalid_action"]))
      result = validator.validate_model(bp)
      expect(result[:valid]).to be false
      expect(result[:errors]).to include(match(/Invalid action 'invalid_action'/))
    end

    it "rejects invalid relationship type" do
      bp = make_blueprint(relationships: [{ "type" => "manyToMany", "model" => "User" }])
      result = validator.validate_model(bp)
      expect(result[:valid]).to be false
      expect(result[:errors]).to include(match(/Invalid relationship type 'manyToMany'/))
    end

    it "validates full valid blueprint with all features" do
      bp = make_blueprint(
        model: "Contract", slug: "contracts", table: "contracts",
        options: make_options(belongs_to_organization: true, soft_deletes: true),
        columns: [
          make_column(name: "title", type: "string", filterable: true),
          make_column(name: "total_value", type: "decimal", nullable: true, precision: 10, scale: 2),
          make_column(name: "user_id", type: "foreignId", foreign_model: "User")
        ],
        relationships: [{ "type" => "belongsTo", "model" => "User", "foreign_key" => "user_id" }],
        permissions: {
          "owner" => {
            actions: %w[index show store update destroy trashed restore forceDelete],
            show_fields: ["*"], create_fields: ["*"], update_fields: ["*"], hidden_fields: []
          },
          "viewer" => {
            actions: %w[index show], show_fields: %w[id title],
            create_fields: [], update_fields: [], hidden_fields: ["total_value"]
          }
        }
      )
      result = validator.validate_model(bp, make_roles)
      expect(result[:valid]).to be true
      expect(result[:errors]).to be_empty
    end
  end
end
