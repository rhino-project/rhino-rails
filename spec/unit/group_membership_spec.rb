# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rhino::GroupMembership do
  def create_user(attrs = {})
    User.create!({ name: "U", email: "u-#{SecureRandom.hex(4)}@x.com" }.merge(attrs))
  end

  def create_org(attrs = {})
    Organization.create!({ name: "O", slug: "o-#{SecureRandom.hex(4)}" }.merge(attrs))
  end

  def create_role(attrs = {})
    Role.create!({ name: "R", slug: "r-#{SecureRandom.hex(4)}", permissions: [] }.merge(attrs))
  end

  describe ".member?" do
    it "returns false for a nil user" do
      expect(described_class.member?(nil, "driver")).to be false
    end

    it "matches an exact route_group row (non-tenant)" do
      user = create_user
      role = create_role
      UserRole.create!(user: user, role: role, organization: nil, route_group: "driver")

      expect(described_class.member?(user, "driver")).to be true
      expect(described_class.member?(user, "admin")).to be false
    end

    it "treats a NULL route_group row as a wildcard matching any group" do
      user = create_user
      role = create_role
      UserRole.create!(user: user, role: role, organization: nil, route_group: nil)

      expect(described_class.member?(user, "driver")).to be true
      expect(described_class.member?(user, "admin")).to be true
    end

    it "requires the organization to match for the tenant group" do
      user = create_user
      role = create_role
      org_a = create_org
      org_b = create_org
      UserRole.create!(user: user, role: role, organization: org_a, route_group: "tenant")

      expect(described_class.member?(user, "tenant", org_a)).to be true
      expect(described_class.member?(user, "tenant", org_b)).to be false
    end

    it "denies the tenant group when no organization is resolved" do
      user = create_user
      role = create_role
      org_a = create_org
      UserRole.create!(user: user, role: role, organization: org_a, route_group: "tenant")

      expect(described_class.member?(user, "tenant", nil)).to be false
    end

    it "ignores organization for non-tenant groups" do
      user = create_user
      role = create_role
      org_a = create_org
      UserRole.create!(user: user, role: role, organization: org_a, route_group: "driver")

      # Non-tenant group: org is ignored, so membership holds regardless.
      expect(described_class.member?(user, "driver", nil)).to be true
    end
  end

  describe "unique membership index (NULL org / NULL group)" do
    it "rejects a duplicate NULL-org / NULL-group wildcard membership" do
      user = create_user
      role = create_role
      UserRole.create!(user: user, role: role, organization: nil, route_group: nil)

      # A plain (user_id, organization_id, role_id, route_group) index would
      # allow this because NULLs compare distinct; the COALESCE expression index
      # collapses them so the duplicate is rejected.
      expect do
        UserRole.create!(user: user, role: role, organization: nil, route_group: nil)
      end.to raise_error(ActiveRecord::RecordNotUnique)
    end

    it "still allows distinct wildcard memberships for different roles" do
      user = create_user
      role_a = create_role
      role_b = create_role
      UserRole.create!(user: user, role: role_a, organization: nil, route_group: nil)

      expect do
        UserRole.create!(user: user, role: role_b, organization: nil, route_group: nil)
      end.not_to raise_error
    end
  end

  describe ".matching_membership" do
    it "prefers an exact route_group row over a NULL wildcard row" do
      user = create_user
      exact_role = create_role(permissions: ["posts.index"])
      wildcard_role = create_role(permissions: ["*"])
      UserRole.create!(user: user, role: wildcard_role, organization: nil, route_group: nil)
      UserRole.create!(user: user, role: exact_role, organization: nil, route_group: "driver")

      membership = described_class.matching_membership(user, "driver")
      expect(membership.role_id).to eq(exact_role.id)
    end

    it "falls back to the NULL wildcard row when no exact row exists" do
      user = create_user
      wildcard_role = create_role(permissions: ["*"])
      UserRole.create!(user: user, role: wildcard_role, organization: nil, route_group: nil)

      membership = described_class.matching_membership(user, "driver")
      expect(membership.role_id).to eq(wildcard_role.id)
    end

    it "returns nil when nothing matches" do
      user = create_user
      expect(described_class.matching_membership(user, "driver")).to be_nil
    end

    it "returns nil for a nil-group request even when memberships exist" do
      user = create_user
      role = create_role(permissions: ["*"])
      UserRole.create!(user: user, role: role, organization: nil, route_group: "driver")

      # The permission source for a nil group is undefined; deny rather than
      # leak permissions from an arbitrary unrelated membership row.
      expect(described_class.matching_membership(user, nil)).to be_nil
    end
  end
end

RSpec.describe Rhino::AuthRejected do
  it "defaults to status 403" do
    err = described_class.new("nope")
    expect(err.status).to eq(403)
    expect(err.message).to eq("nope")
  end

  it "carries a custom status" do
    err = described_class.new("conflict", status: 409)
    expect(err.status).to eq(409)
  end
end

RSpec.describe Rhino::AuthHooks do
  it "provides no-op defaults that never raise" do
    hooks = described_class.new
    user = Object.new
    expect { hooks.after_login(user, {}) }.not_to raise_error
    expect { hooks.after_logout(user, {}) }.not_to raise_error
    expect { hooks.after_register(user, {}) }.not_to raise_error
    expect { hooks.after_password_recover(user, {}) }.not_to raise_error
    expect { hooks.after_password_reset(user, {}) }.not_to raise_error
  end
end
