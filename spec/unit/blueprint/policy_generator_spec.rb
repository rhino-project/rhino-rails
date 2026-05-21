# frozen_string_literal: true

require "spec_helper"
require "rhino/blueprint/generators/policy_generator"

RSpec.describe Rhino::Blueprint::Generators::PolicyGenerator do
  let(:generator) { described_class.new }

  def make_permission(overrides = {})
    {
      actions: %w[index show], show_fields: ["*"],
      create_fields: [], update_fields: [], hidden_fields: []
    }.merge(overrides)
  end

  # ──────────────────────────────────────────────
  # group_roles_by_fields
  # ──────────────────────────────────────────────

  describe "#group_roles_by_fields" do
    it "groups roles with identical wildcard fields" do
      permissions = {
        "owner" => make_permission(show_fields: ["*"]),
        "admin" => make_permission(show_fields: ["*"])
      }

      groups = generator.group_roles_by_fields(permissions, :show_fields)

      expect(groups.length).to eq(1)
      expect(groups[0][:fields]).to eq(["*"])
      expect(groups[0][:roles]).to contain_exactly("owner", "admin")
    end

    it "groups roles with identical field lists" do
      permissions = {
        "admin" => make_permission(create_fields: %w[title status]),
        "manager" => make_permission(create_fields: %w[title status]),
        "viewer" => make_permission(create_fields: [])
      }

      groups = generator.group_roles_by_fields(permissions, :create_fields)

      expect(groups.length).to eq(1) # viewer has empty so skipped
      admin_group = groups.find { |g| g[:roles].include?("admin") }
      expect(admin_group[:roles]).to include("manager")
    end

    it "handles single role" do
      permissions = { "admin" => make_permission(show_fields: ["title"]) }

      groups = generator.group_roles_by_fields(permissions, :show_fields)
      expect(groups.length).to eq(1)
      expect(groups[0][:roles]).to eq(["admin"])
    end
  end

  # ──────────────────────────────────────────────
  # build_role_condition
  # ──────────────────────────────────────────────

  describe "#build_role_condition" do
    it "builds single role condition" do
      expect(generator.build_role_condition(["admin"])).to eq("has_role?(user, 'admin')")
    end

    it "builds two-role condition with ||" do
      result = generator.build_role_condition(%w[owner admin])
      expect(result).to eq("has_role?(user, 'owner') || has_role?(user, 'admin')")
    end

    it "builds multi-role condition for 3+ roles" do
      result = generator.build_role_condition(%w[owner admin manager])
      expect(result).to include("has_role?(user, 'owner')")
      expect(result).to include("has_role?(user, 'admin')")
      expect(result).to include("has_role?(user, 'manager')")
      expect(result).to include("||")
    end
  end

  # ──────────────────────────────────────────────
  # fields_to_ruby_array
  # ──────────────────────────────────────────────

  describe "#fields_to_ruby_array" do
    it "wildcard returns ['*']" do
      expect(generator.fields_to_ruby_array(["*"])).to eq("['*']")
    end

    it "empty returns []" do
      expect(generator.fields_to_ruby_array([])).to eq("[]")
    end

    it "short fields inline" do
      result = generator.fields_to_ruby_array(%w[id title status])
      expect(result).to eq("['id', 'title', 'status']")
    end

    it "long fields multiline" do
      long_fields = (0..14).map { |i| "very_long_field_name_#{i}" }
      result = generator.fields_to_ruby_array(long_fields)
      expect(result).to include("\n")
    end
  end

  # ──────────────────────────────────────────────
  # build_permitted_attributes_method
  # ──────────────────────────────────────────────

  describe "#build_permitted_attributes_method" do
    it "generates default return for no permissions" do
      result = generator.build_permitted_attributes_method("permitted_attributes_for_show", {}, :show_fields)
      expect(result).to include("['*']")
    end

    it "generates method with mixed wildcard/restricted roles" do
      permissions = {
        "owner" => make_permission(show_fields: ["*"]),
        "viewer" => make_permission(show_fields: %w[id title])
      }

      result = generator.build_permitted_attributes_method("permitted_attributes_for_show", permissions, :show_fields)

      expect(result).to include("permitted_attributes_for_show")
      expect(result).to include("has_role?(user, 'owner')")
      expect(result).to include("['*']")
      expect(result).to include("has_role?(user, 'viewer')")
      expect(result).to include("'id'")
      expect(result).to include("'title'")
      expect(result).to include("[]")
    end

    it "skips roles with empty field lists" do
      permissions = {
        "owner" => make_permission(create_fields: ["*"]),
        "viewer" => make_permission(create_fields: [])
      }

      result = generator.build_permitted_attributes_method("permitted_attributes_for_create", permissions, :create_fields)

      expect(result).to include("has_role?(user, 'owner')")
      expect(result).not_to include("has_role?(user, 'viewer')")
    end
  end

  # ──────────────────────────────────────────────
  # build_hidden_attributes_method
  # ──────────────────────────────────────────────

  describe "#build_hidden_attributes_method" do
    it "returns empty array when no hidden fields defined" do
      permissions = {
        "owner" => make_permission(hidden_fields: []),
        "admin" => make_permission(hidden_fields: [])
      }

      result = generator.build_hidden_attributes_method(permissions)
      expect(result).to include("[]")
      expect(result).not_to include("has_role?")
    end

    it "generates method for roles with hidden fields" do
      permissions = {
        "owner" => make_permission(hidden_fields: []),
        "viewer" => make_permission(hidden_fields: %w[total_value secret_field])
      }

      result = generator.build_hidden_attributes_method(permissions)
      expect(result).to include("has_role?(user, 'viewer')")
      expect(result).to include("'total_value'")
      expect(result).to include("'secret_field'")
    end

    it "groups roles with identical hidden fields" do
      permissions = {
        "viewer" => make_permission(hidden_fields: ["salary"]),
        "guest" => make_permission(hidden_fields: ["salary"])
      }

      result = generator.build_hidden_attributes_method(permissions)
      expect(result).to include("has_role?(user, 'viewer')")
      expect(result).to include("has_role?(user, 'guest')")
      # Both should be in same condition block
      if_count = result.scan(/return.*if/).length
      expect(if_count).to eq(1)
    end
  end

  # ──────────────────────────────────────────────
  # Full generate
  # ──────────────────────────────────────────────

  describe "#generate" do
    let(:blueprint) do
      {
        model: "Contract", slug: "contracts", table: "contracts",
        options: { belongs_to_organization: true, soft_deletes: true, audit_trail: false,
                   owner: nil, except_actions: [], pagination: false, per_page: 25 },
        columns: [
          { name: "title", type: "string", nullable: false, unique: false, index: false,
            default: nil, filterable: true, sortable: true, searchable: false,
            precision: nil, scale: nil, foreign_model: nil },
          { name: "total_value", type: "decimal", nullable: true, unique: false, index: false,
            default: nil, filterable: false, sortable: false, searchable: false,
            precision: 10, scale: 2, foreign_model: nil }
        ],
        relationships: [],
        permissions: {
          "owner" => { actions: %w[index show store update destroy], show_fields: ["*"],
                       create_fields: ["*"], update_fields: ["*"], hidden_fields: [] },
          "viewer" => { actions: %w[index show], show_fields: %w[id title],
                        create_fields: [], update_fields: [], hidden_fields: ["total_value"] }
        },
        source_file: "contracts.yaml"
      }
    end

    it "generates complete policy class with all 4 methods" do
      output = generator.generate(blueprint)

      expect(output).to include("class ContractPolicy < Rhino::ResourcePolicy")
      expect(output).to include("self.resource_slug = 'contracts'")
      expect(output).to include("permitted_attributes_for_show")
      expect(output).to include("hidden_attributes_for_show")
      expect(output).to include("permitted_attributes_for_create")
      expect(output).to include("permitted_attributes_for_update")
    end

    it "generated Ruby is syntactically valid" do
      output = generator.generate(blueprint)

      # Check balanced keywords
      expect(output.scan(/\bdef\b/).length).to eq(output.scan(/\bend\b/).length - 1) # -1 for class end
      expect(output).to include("class ContractPolicy")
    end
  end
end
