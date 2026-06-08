# frozen_string_literal: true

require "spec_helper"

# Layered permissions: effective = (role ∪ granted) − denied, deny always wins.
#
#   - role    → org_role_permissions[(org, role)].permissions   (shared role layer)
#   - granted → user_roles.granted_permissions                  (per-user additive)
#   - denied  → user_roles.denied_permissions                   (per-user subtractive)
#   - legacy  → user_roles.permissions                          (back-compat allow layer)
#
# See PERMISSIONS_DESIGN.md §4 for the cross-stack conformance truth table.
RSpec.describe "Rhino::HasPermissions (layered)" do
  # Build a fresh, isolated (user, org, role) triple with the given layers.
  def scenario(role: nil, granted: [], denied: [], legacy: [])
    uid = SecureRandom.uuid
    user = User.create!(name: "U #{uid}", email: "u-#{uid}@example.com")
    org = Organization.create!(name: "O #{uid}", slug: "o-#{uid}")
    role_rec = Role.create!(name: "R #{uid}", slug: "r-#{uid}")

    OrgRolePermission.create!(organization: org, role: role_rec, permissions: role) unless role.nil?

    UserRole.create!(
      user: user, organization: org, role: role_rec,
      permissions: legacy, granted_permissions: granted, denied_permissions: denied
    )

    [user, org]
  end

  def can?(permission, **layers)
    user, org = scenario(**layers)
    user.has_permission?(permission, org)
  end

  # ------------------------------------------------------------------
  # Truth table (PERMISSIONS_DESIGN.md §4) — the conformance spec
  # ------------------------------------------------------------------

  TRUTH_TABLE = [
    # [name, role, granted, denied, request, expected]
    ["default deny",                [],            [],              [],              "posts.update", false],
    ["role grants",                 ["posts.*"],   [],              [],              "posts.update", true],
    ["grant grants",                [],            ["posts.update"], [],             "posts.update", true],
    ["deny over role",              ["posts.*"],   [],              ["posts.update"], "posts.update", false],
    ["deny over superadmin",        ["*"],         [],              ["posts.update"], "posts.update", false],
    ["deny wildcard hits",          ["*"],         [],              ["posts.*"],     "posts.index",  false],
    ["deny wildcard scoped",        ["*"],         [],              ["posts.*"],     "users.index",  true],
    ["grant adds to role",          ["posts.index"], ["posts.update"], [],           "posts.update", true],
    ["still inherits role",         ["posts.index"], ["posts.update"], [],           "posts.index",  true],
    ["not granted anywhere",        ["posts.*"],   [],              [],              "comments.update", false],
    ["deny over grant wildcard",    [],            ["*"],           ["posts.*"],     "posts.update", false],
    ["grant wildcard else allowed", [],            ["*"],           ["posts.*"],     "comments.index", true]
  ].freeze

  describe "truth table conformance" do
    TRUTH_TABLE.each do |name, role, granted, denied, request, expected|
      it "#{name}: role=#{role} granted=#{granted} denied=#{denied} #{request} → #{expected}" do
        result = can?(request, role: role, granted: granted, denied: denied)
        expect(result).to be(expected)
      end
    end
  end

  # ------------------------------------------------------------------
  # Edge cases explicitly requested
  # ------------------------------------------------------------------

  describe "grant + deny precedence" do
    it "follows deny when the same ability is both granted and denied" do
      expect(can?("posts.update", granted: ["posts.update"], denied: ["posts.update"])).to be false
    end

    it "only blocks the denied ability within a granted wildcard" do
      user, org = scenario(granted: ["posts.*"], denied: ["posts.destroy"])
      expect(user.has_permission?("posts.update", org)).to be true
      expect(user.has_permission?("posts.index", org)).to be true
      expect(user.has_permission?("posts.destroy", org)).to be false
    end
  end

  describe "user_role delta over role layer" do
    it "unions the user grant with the role layer (does not replace it)" do
      user, org = scenario(role: %w[posts.index posts.show], granted: ["posts.update"])
      expect(user.has_permission?("posts.index", org)).to be true
      expect(user.has_permission?("posts.show", org)).to be true
      expect(user.has_permission?("posts.update", org)).to be true
      expect(user.has_permission?("posts.destroy", org)).to be false
    end

    it "lets a user-level deny override the role layer" do
      user, org = scenario(role: ["*"], denied: ["posts.destroy"])
      expect(user.has_permission?("posts.update", org)).to be true
      expect(user.has_permission?("posts.destroy", org)).to be false
      expect(user.has_permission?("users.index", org)).to be true
    end

    it "grants from the role layer alone with no user permissions" do
      user, org = scenario(role: %w[posts.* comments.index])
      expect(user.has_permission?("posts.update", org)).to be true
      expect(user.has_permission?("comments.index", org)).to be true
      expect(user.has_permission?("comments.store", org)).to be false
    end
  end

  # ------------------------------------------------------------------
  # Backward compatibility (legacy user_roles.permissions + global role.permissions)
  # ------------------------------------------------------------------

  describe "backward compatibility" do
    it "honors legacy user_roles.permissions when there is no role layer" do
      user, org = scenario(legacy: %w[posts.index posts.show])
      expect(user.has_permission?("posts.index", org)).to be true
      expect(user.has_permission?("posts.update", org)).to be false
    end

    it "still allows a user-level deny to carve out of a legacy wildcard" do
      user, org = scenario(legacy: ["*"], denied: ["posts.destroy"])
      expect(user.has_permission?("posts.update", org)).to be true
      expect(user.has_permission?("posts.destroy", org)).to be false
    end

    it "falls back to the global roles.permissions only when the union is empty" do
      user = User.create!(name: "F", email: "f-#{SecureRandom.uuid}@example.com")
      org = Organization.create!(name: "O", slug: "o-#{SecureRandom.uuid}")
      role = Role.create!(name: "R", slug: "r-#{SecureRandom.uuid}", permissions: ["*"])
      UserRole.create!(user: user, organization: org, role: role, permissions: [])

      expect(user.has_permission?("anything.here", org)).to be true
    end

    it "prefers the union over the global role fallback (does not leak global role.permissions)" do
      user = User.create!(name: "P", email: "p-#{SecureRandom.uuid}@example.com")
      org = Organization.create!(name: "O", slug: "o-#{SecureRandom.uuid}")
      role = Role.create!(name: "R", slug: "r-#{SecureRandom.uuid}", permissions: ["*"])
      UserRole.create!(user: user, organization: org, role: role, permissions: ["posts.index"])

      expect(user.has_permission?("posts.index", org)).to be true
      expect(user.has_permission?("posts.store", org)).to be false
    end
  end

  # ------------------------------------------------------------------
  # Org / role isolation
  # ------------------------------------------------------------------

  describe "isolation" do
    it "scopes the role layer to the organization" do
      user = User.create!(name: "M", email: "m-#{SecureRandom.uuid}@example.com")
      role = Role.create!(name: "Shared", slug: "shared-#{SecureRandom.uuid}")
      org_a = Organization.create!(name: "A", slug: "a-#{SecureRandom.uuid}")
      org_b = Organization.create!(name: "B", slug: "b-#{SecureRandom.uuid}")

      OrgRolePermission.create!(organization: org_a, role: role, permissions: ["*"])
      OrgRolePermission.create!(organization: org_b, role: role, permissions: ["posts.index"])
      UserRole.create!(user: user, organization: org_a, role: role)
      UserRole.create!(user: user, organization: org_b, role: role)

      expect(user.has_permission?("posts.destroy", org_a)).to be true
      expect(user.has_permission?("posts.index", org_b)).to be true
      expect(user.has_permission?("posts.destroy", org_b)).to be false
    end

    it "does not apply another role's role layer" do
      user = User.create!(name: "U", email: "u-#{SecureRandom.uuid}@example.com")
      org = Organization.create!(name: "O", slug: "o-#{SecureRandom.uuid}")
      mine = Role.create!(name: "Mine", slug: "mine-#{SecureRandom.uuid}")
      other = Role.create!(name: "Other", slug: "other-#{SecureRandom.uuid}")

      OrgRolePermission.create!(organization: org, role: other, permissions: ["*"])
      UserRole.create!(user: user, organization: org, role: mine)

      expect(user.has_permission?("posts.index", org)).to be false
    end
  end

  # ------------------------------------------------------------------
  # Non-tenant (users.permissions) — deny still wins
  # ------------------------------------------------------------------

  describe "non-tenant resolution" do
    it "uses users.permissions when no org context" do
      user = User.create!(name: "D", email: "d-#{SecureRandom.uuid}@example.com",
                          permissions: %w[posts.index posts.show])
      expect(user.has_permission?("posts.index")).to be true
      expect(user.has_permission?("posts.store")).to be false
    end

    it "lets a user-level deny override users.permissions" do
      user = User.create!(name: "D", email: "d-#{SecureRandom.uuid}@example.com",
                          permissions: ["*"], denied_permissions: ["posts.destroy"])
      expect(user.has_permission?("posts.update")).to be true
      expect(user.has_permission?("posts.destroy")).to be false
    end
  end

  # ------------------------------------------------------------------
  # explain_permission — deciding layer
  # ------------------------------------------------------------------

  describe "#explain_permission" do
    it "reports the deciding layer" do
      user, org = scenario(
        role: ["posts.index"], granted: ["comments.index"],
        denied: ["posts.destroy"], legacy: ["tags.index"]
      )

      expect(user.explain_permission("posts.destroy", org)[:reason]).to eq("denied")
      expect(user.explain_permission("posts.index", org)[:reason]).to eq("role")
      expect(user.explain_permission("comments.index", org)[:reason]).to eq("granted")
      expect(user.explain_permission("tags.index", org)[:reason]).to eq("legacy")
      expect(user.explain_permission("widgets.index", org)[:reason]).to eq("default-deny")
      expect(user.explain_permission("posts.index", org)[:granted]).to be true
    end
  end
end
