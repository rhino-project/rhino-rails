# frozen_string_literal: true

require "spec_helper"
require "rhino/blueprint/generators/seeder_generator"

RSpec.describe Rhino::Blueprint::Generators::SeederGenerator do
  let(:generator) { described_class.new }

  def make_permission(overrides = {})
    {
      actions: [], show_fields: [], create_fields: [],
      update_fields: [], hidden_fields: []
    }.merge(overrides)
  end

  def make_blueprint(slug, permissions)
    {
      model: slug.capitalize, slug: slug, table: slug,
      options: { belongs_to_organization: false, soft_deletes: true, audit_trail: false,
                 owner: nil, except_actions: [], pagination: false, per_page: 25 },
      columns: [], relationships: [], permissions: permissions,
      source_file: "#{slug}.yaml"
    }
  end

  def make_roles
    {
      "owner" => { name: "Owner", description: "Full access" },
      "admin" => { name: "Admin", description: "Admin access" },
      "viewer" => { name: "Viewer", description: "Read-only access" }
    }
  end

  let(:all_actions) { %w[index show store update destroy trashed restore forceDelete] }

  # ──────────────────────────────────────────────
  # aggregate_permissions
  # ──────────────────────────────────────────────

  describe "#aggregate_permissions" do
    it "aggregates permissions from multiple blueprints" do
      blueprints = [
        make_blueprint("contracts", { "admin" => make_permission(actions: %w[index show store]) }),
        make_blueprint("alerts", { "admin" => make_permission(actions: %w[index show]) })
      ]

      result = generator.aggregate_permissions(blueprints)

      expect(result["admin"]).to include(
        "contracts.index", "contracts.show", "contracts.store",
        "alerts.index", "alerts.show"
      )
    end

    it "uses model.* wildcard when role has all 8 actions" do
      blueprints = [
        make_blueprint("contracts", { "owner" => make_permission(actions: all_actions) }),
        make_blueprint("alerts", { "owner" => make_permission(actions: %w[index show]) })
      ]

      result = generator.aggregate_permissions(blueprints)

      expect(result["owner"]).to include("contracts.*")
      expect(result["owner"]).to include("alerts.index")
      expect(result["owner"]).not_to include("contracts.index")
    end

    it "simplifies to global * when all models have wildcard" do
      blueprints = [
        make_blueprint("contracts", { "owner" => make_permission(actions: all_actions) }),
        make_blueprint("alerts", { "owner" => make_permission(actions: all_actions) })
      ]

      result = generator.aggregate_permissions(blueprints)
      expect(result["owner"]).to eq(["*"])
    end

    it "handles empty blueprints" do
      result = generator.aggregate_permissions([])
      expect(result).to eq({})
    end

    it "deduplicates permissions" do
      blueprints = [
        make_blueprint("contracts", { "admin" => make_permission(actions: %w[index show]) })
      ]

      result = generator.aggregate_permissions(blueprints)
      index_count = result["admin"].count { |p| p == "contracts.index" }
      expect(index_count).to eq(1)
    end
  end

  # ──────────────────────────────────────────────
  # generate_role_seeder
  # ──────────────────────────────────────────────

  describe "#generate_role_seeder" do
    it "generates role seeder with find_or_create_by! for each role" do
      output = generator.generate_role_seeder(make_roles)

      expect(output).to include("find_or_create_by!(slug: 'owner')")
      expect(output).to include("r.name = 'Owner'")
      expect(output).to include("find_or_create_by!(slug: 'admin')")
      expect(output).to include("find_or_create_by!(slug: 'viewer')")
    end

    it "generated Ruby is syntactically valid" do
      output = generator.generate_role_seeder(make_roles)

      open_do = output.scan(/\bdo\b/).length
      end_count = output.scan(/\bend\b/).length
      expect(open_do).to eq(end_count)
    end
  end

  # ──────────────────────────────────────────────
  # generate_user_role_seeder
  # ──────────────────────────────────────────────

  describe "#generate_user_role_seeder" do
    it "generates multi-tenant seeder with Organization + User + UserRole" do
      perms = { "owner" => ["*"], "admin" => ["contracts.*", "alerts.index"] }
      output = generator.generate_user_role_seeder(make_roles, perms)

      expect(output).to include("Organization.find_or_create_by!")
      expect(output).to include("UserRole.find_or_create_by!")
      expect(output).to include("'owner@demo.com'")
      expect(output).to include("'admin@demo.com'")
      expect(output).to include("['*']")
      expect(output).to include("'contracts.*'")
    end

    it "generated Ruby is syntactically valid" do
      perms = { "owner" => ["*"] }
      output = generator.generate_user_role_seeder(make_roles, perms)

      open_do = output.scan(/\bdo\b/).length
      end_count = output.scan(/\bend\b/).length
      expect(open_do).to eq(end_count)
    end
  end

  # ──────────────────────────────────────────────
  # generate_user_permission_seeder
  # ──────────────────────────────────────────────

  describe "#generate_user_permission_seeder" do
    it "generates non-tenant seeder with direct permissions on User" do
      perms = { "owner" => ["*"], "viewer" => ["contracts.index", "contracts.show"] }
      output = generator.generate_user_permission_seeder(make_roles, perms)

      expect(output).to include("User.find_or_create_by!")
      expect(output).to include("'owner@demo.com'")
      expect(output).to include("u.permissions = ['*']")
      expect(output).to include("'contracts.index'")
      expect(output).not_to include("Organization")
      expect(output).not_to include("UserRole")
    end

    it "generated Ruby is syntactically valid" do
      perms = { "admin" => ["contracts.*"] }
      output = generator.generate_user_permission_seeder(make_roles, perms)

      open_do = output.scan(/\bdo\b/).length
      end_count = output.scan(/\bend\b/).length
      expect(open_do).to eq(end_count)
    end
  end
end
