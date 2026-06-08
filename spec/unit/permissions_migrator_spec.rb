# frozen_string_literal: true

require "spec_helper"
require "rhino/permissions_migrator"

# Rhino::PermissionsMigrator lifts per-user user_roles.permissions into the
# shared org_role_permissions role layer, reducing each user row to its delta
# while preserving effective permissions exactly.
RSpec.describe Rhino::PermissionsMigrator do
  def org(id = nil)
    Organization.create!(name: "O #{SecureRandom.uuid}", slug: "o-#{id || SecureRandom.uuid}")
  end

  def role(id = nil)
    Role.create!(name: "R #{SecureRandom.uuid}", slug: "r-#{id || SecureRandom.uuid}")
  end

  def user
    User.create!(name: "U", email: "u-#{SecureRandom.uuid}@example.com")
  end

  it "is a dry-run by default (no writes)" do
    o = org; r = role; u = user
    UserRole.create!(user: u, organization: o, role: r, permissions: ["*"])

    result = described_class.call

    expect(OrgRolePermission.count).to eq(0)
    expect(UserRole.first.permissions).to eq(["*"])
    expect(result.groups_migrated).to eq(1)
  end

  it "lifts the intersection into the role layer and reduces rows to deltas" do
    o = org; r = role
    u1 = user; u2 = user
    UserRole.create!(user: u1, organization: o, role: r, permissions: ["posts.*"])
    UserRole.create!(user: u2, organization: o, role: r, permissions: ["posts.*", "comments.index"])

    described_class.call(apply: true)

    layer = OrgRolePermission.find_by(organization_id: o.id, role_id: r.id)
    expect(layer.permissions).to contain_exactly("posts.*")

    ur1 = UserRole.find_by(user_id: u1.id)
    expect(ur1.permissions).to eq([])
    expect(ur1.granted_permissions).to eq([])

    ur2 = UserRole.find_by(user_id: u2.id)
    expect(ur2.permissions).to eq([])
    expect(ur2.granted_permissions).to eq(["comments.index"])

    # Effective permissions preserved.
    expect(u1.has_permission?("posts.update", o)).to be true
    expect(u1.has_permission?("comments.index", o)).to be false
    expect(u2.has_permission?("comments.index", o)).to be true
  end

  it "is idempotent" do
    o = org; r = role; u = user
    UserRole.create!(user: u, organization: o, role: r, permissions: ["*"])

    described_class.call(apply: true)
    described_class.call(apply: true)

    expect(OrgRolePermission.where(organization_id: o.id, role_id: r.id).count).to eq(1)
    expect(u.has_permission?("anything.here", o)).to be true
  end

  it "skips a group that already has a role layer" do
    o = org; r = role; u = user
    UserRole.create!(user: u, organization: o, role: r, permissions: ["posts.*"])
    OrgRolePermission.create!(organization: o, role: r, permissions: ["comments.*"])

    result = described_class.call(apply: true)

    expect(result.skipped_existing).to eq(1)
    expect(OrgRolePermission.find_by(organization_id: o.id, role_id: r.id).permissions).to eq(["comments.*"])
    expect(UserRole.first.permissions).to eq(["posts.*"])
  end

  it "leaves non-tenant (NULL organization) rows untouched" do
    r = role; u = user
    UserRole.create!(user: u, organization: nil, role: r, permissions: ["posts.*"])

    described_class.call(apply: true)

    expect(OrgRolePermission.count).to eq(0)
    expect(UserRole.first.permissions).to eq(["posts.*"])
  end
end
