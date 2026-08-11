# frozen_string_literal: true

require "spec_helper"
require "rhino/blueprint/generators/test_generator"

RSpec.describe Rhino::Blueprint::Generators::TestGenerator do
  let(:generator) { described_class.new }

  def make_permission(overrides = {})
    {
      actions: [], show_fields: [], create_fields: [],
      update_fields: [], hidden_fields: []
    }.merge(overrides)
  end

  def make_blueprint(overrides = {})
    {
      model: "Contract", slug: "contracts", table: "contracts",
      options: { belongs_to_organization: true, soft_deletes: true, audit_trail: false,
                 owner: nil, except_actions: [], pagination: false, per_page: 25 },
      columns: [
        { name: "title", type: "string" },
        { name: "total_value", type: "decimal" }
      ],
      relationships: [],
      permissions: {
        "owner" => make_permission(
          actions: %w[index show store update destroy trashed restore forceDelete],
          show_fields: ["*"], create_fields: ["*"], update_fields: ["*"]
        ),
        "viewer" => make_permission(
          actions: %w[index show], show_fields: %w[id title],
          hidden_fields: ["total_value"]
        )
      },
      source_file: "contracts.yaml"
    }.merge(overrides)
  end

  describe "#generate multi-tenant" do
    it "generates complete RSpec test file" do
      output = generator.generate(make_blueprint, true, "slug")

      expect(output).to include("require 'rails_helper'")
      expect(output).to include("Contract — CRUD & Permissions")
      expect(output).to include("organization")
    end

    it "uses create_user_with_role helper" do
      output = generator.generate(make_blueprint, true, "id")

      expect(output).to include("create_user_with_role")
      expect(output).to include("def create_user_with_role")
    end

    it "multi-tenant CRUD tests use create_user_with_role" do
      output = generator.generate(make_blueprint, true, "id")

      expect(output).to include("create_user_with_role('owner', org,")
      expect(output).to include("create_user_with_role('viewer', org,")
    end

    it "generated code is syntactically balanced" do
      output = generator.generate(make_blueprint, true, "id")

      open_do = output.scan(/\bdo\b/).length
      end_count = output.scan(/\bend\b/).length
      expect(end_count).to be >= open_do
    end

    it "generates context blocks per role" do
      output = generator.generate(make_blueprint, true, "slug")

      expect(output).to include("context 'as owner' do")
      expect(output).to include("context 'as viewer' do")
    end

    it "generates individual it blocks per action" do
      output = generator.generate(make_blueprint, true, "slug")

      expect(output).to include("it 'can list contracts'")
      expect(output).to include("it 'can show contracts'")
      expect(output).to include("it 'can create contracts'")
      expect(output).to include("it 'cannot create contracts'")
    end

    it "uses let(:user) inside context blocks" do
      output = generator.generate(make_blueprint, true, "slug")

      expect(output).to include("let(:user) { create_user_with_role('owner', org,")
      expect(output).to include("let(:user) { create_user_with_role('viewer', org,")
    end

    it "generates multi-tenant URLs with org identifier" do
      output = generator.generate(make_blueprint, true, "slug")
      expect(output).to include('#{org.slug}')
    end

    it "generates allowed action tests with correct HTTP status" do
      output = generator.generate(make_blueprint, true, "slug")

      expect(output).to include("it 'can list contracts'")
      expect(output).to include("it 'can force delete contracts'")
    end

    it "generates blocked action tests with forbidden status" do
      output = generator.generate(make_blueprint, true, "slug")

      expect(output).to include("it 'cannot create contracts'")
      expect(output).to include("it 'cannot update contracts'")
      expect(output).to include("it 'cannot delete contracts'")
    end

    it "generates field visibility test for restricted show_fields" do
      output = generator.generate(make_blueprint, true, "slug")

      expect(output).to include("shows only permitted fields")
      expect(output).to include("have_key('id')")
      expect(output).to include("have_key('title')")
      expect(output).to include("not_to have_key('total_value')")
    end
  end

  describe "#generate with route_key" do
    it "uses record.id in member URLs when no route_key is configured" do
      output = generator.generate(make_blueprint, false)

      expect(output).to include('/api/contracts/#{record.id}"')
      expect(output).not_to include("record.hash_id")
    end

    it "uses the route key attribute in member URLs when configured" do
      bp = make_blueprint(
        options: { belongs_to_organization: false, soft_deletes: true, audit_trail: false,
                   owner: nil, except_actions: [], pagination: false, per_page: 25,
                   route_key: "hash_id" },
        columns: [
          { name: "hash_id", type: "string" },
          { name: "title", type: "string" },
          { name: "total_value", type: "decimal" }
        ]
      )
      output = generator.generate(bp, false)

      expect(output).to include('/api/contracts/#{record.hash_id}"')
      expect(output).to include('/api/contracts/#{record.hash_id}/restore')
      expect(output).to include('/api/contracts/#{record.hash_id}/force-delete')
      expect(output).not_to include('#{record.id}')
    end
  end

  describe "#generate non-tenant" do
    it "generates complete RSpec test file" do
      output = generator.generate(make_blueprint, false)

      expect(output).to include("require 'rails_helper'")
      expect(output).to include("Contract — CRUD & Permissions")
      expect(output).not_to include("Organization")
    end

    it "uses create_user_with_permissions helper" do
      output = generator.generate(make_blueprint, false)

      expect(output).to include("create_user_with_permissions")
      expect(output).to include("def create_user_with_permissions")
    end

    it "generates non-tenant URLs without org prefix" do
      output = generator.generate(make_blueprint, false)
      expect(output).to include('"/api/contracts"')
      expect(output).not_to include('#{org.')
    end

    it "generates context blocks per role for non-tenant" do
      output = generator.generate(make_blueprint, false)

      expect(output).to include("context 'as owner' do")
      expect(output).to include("context 'as viewer' do")
    end
  end

  describe "edge cases" do
    it "returns empty role contexts for no permissions" do
      bp = make_blueprint(permissions: {})
      output = generator.generate(bp, true, "slug")

      expect(output).to include("Contract — CRUD & Permissions")
      expect(output).not_to include("context 'as")
    end

    it "handles forbidden field tests for restricted create_fields" do
      bp = make_blueprint(permissions: {
        "admin" => make_permission(
          actions: %w[index show store],
          create_fields: ["title"],
          show_fields: ["*"]
        )
      })
      output = generator.generate(bp, false)

      expect(output).to include("returns 403 when setting restricted fields")
      expect(output).to include("total_value")
      expect(output).to include(":forbidden")
    end

    it "skips forbidden field test for wildcard create_fields" do
      bp = make_blueprint(permissions: {
        "owner" => make_permission(
          actions: %w[index show store],
          create_fields: ["*"],
          show_fields: ["*"]
        )
      })
      output = generator.generate(bp, false)

      expect(output).not_to include("returns 403 when setting restricted fields")
    end

    it "skips field visibility test for wildcard show_fields" do
      bp = make_blueprint(permissions: {
        "owner" => make_permission(
          actions: %w[index show],
          show_fields: ["*"]
        )
      })
      output = generator.generate(bp, false)

      expect(output).not_to include("shows only permitted fields")
    end
  end

  describe "#actions_to_permissions" do
    it "uses wildcard when all actions present" do
      all = %w[index show store update destroy trashed restore forceDelete]
      result = generator.actions_to_permissions(all, "contracts")
      expect(result).to eq("['contracts.*']")
    end

    it "lists individual permissions for partial actions" do
      result = generator.actions_to_permissions(%w[index show], "contracts")
      expect(result).to eq("['contracts.index', 'contracts.show']")
    end
  end
end
