# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rhino::HasPermissions do
  # ------------------------------------------------------------------
  # Helpers
  # ------------------------------------------------------------------

  def create_user_with_permissions(permissions, user_id: nil, org: nil)
    id = user_id || SecureRandom.uuid
    user = User.create!(
      name: "User #{id}",
      email: "user-#{id}@example.com"
    )

    org ||= Organization.create!(name: "Test Org", slug: "test-org-#{SecureRandom.uuid}")
    role = Role.create!(name: "Test Role", slug: "test-role-#{SecureRandom.uuid}", permissions: permissions)
    UserRole.create!(user: user, organization: org, role: role)

    [user, org]
  end

  def create_user_without_permissions
    User.create!(
      name: "No Perms User",
      email: "noperms-#{SecureRandom.uuid}@example.com"
    )
  end

  def create_user_with_direct_permissions(permissions)
    User.create!(
      name: "Direct Perm User",
      email: "direct-#{SecureRandom.uuid}@example.com",
      permissions: permissions
    )
  end

  # ------------------------------------------------------------------
  # Basic permission checks (org-scoped via role)
  # ------------------------------------------------------------------

  describe "#has_permission?" do
    it "returns true with exact permission" do
      user, org = create_user_with_permissions(["posts.index"])
      expect(user.has_permission?("posts.index", org)).to be true
    end

    it "returns false without matching permission" do
      user, org = create_user_with_permissions(["posts.index"])
      expect(user.has_permission?("posts.store", org)).to be false
    end

    it "returns false for nil user (no permissions)" do
      user = create_user_without_permissions
      expect(user.has_permission?("posts.index")).to be false
    end

    it "returns false for blank permission string" do
      user, org = create_user_with_permissions(["*"])
      expect(user.has_permission?("", org)).to be false
      expect(user.has_permission?(nil, org)).to be false
    end
  end

  # ------------------------------------------------------------------
  # Wildcard permissions
  # ------------------------------------------------------------------

  describe "wildcard permissions" do
    it "grants all access with * wildcard" do
      user, org = create_user_with_permissions(["*"])

      expect(user.has_permission?("posts.index", org)).to be true
      expect(user.has_permission?("posts.store", org)).to be true
      expect(user.has_permission?("blogs.destroy", org)).to be true
      expect(user.has_permission?("anything.here", org)).to be true
    end

    it "grants all actions on a resource with resource.*" do
      user, org = create_user_with_permissions(["posts.*"])

      expect(user.has_permission?("posts.index", org)).to be true
      expect(user.has_permission?("posts.store", org)).to be true
      expect(user.has_permission?("posts.destroy", org)).to be true
      expect(user.has_permission?("blogs.index", org)).to be false
    end
  end

  # ------------------------------------------------------------------
  # Individual action permissions
  # ------------------------------------------------------------------

  describe "individual action permissions" do
    it "maps each action to correct permission" do
      actions = {
        "posts.index" => "posts.index",
        "posts.show" => "posts.show",
        "posts.store" => "posts.store",
        "posts.update" => "posts.update",
        "posts.destroy" => "posts.destroy"
      }

      actions.each do |permission, _|
        user, org = create_user_with_permissions([permission])

        # Should have the granted permission
        expect(user.has_permission?(permission, org)).to be(true),
          "Expected #{permission} to be allowed"

        # Should not have other permissions
        other_perms = actions.keys - [permission]
        other_perms.each do |other|
          expect(user.has_permission?(other, org)).to be(false),
            "Expected #{other} to be denied when only #{permission} is granted"
        end
      end
    end
  end

  # ------------------------------------------------------------------
  # Multiple permissions
  # ------------------------------------------------------------------

  describe "multiple permissions" do
    it "allows granted actions and denies others" do
      user, org = create_user_with_permissions(["posts.index", "posts.show", "posts.store"])

      expect(user.has_permission?("posts.index", org)).to be true
      expect(user.has_permission?("posts.show", org)).to be true
      expect(user.has_permission?("posts.store", org)).to be true
      expect(user.has_permission?("posts.update", org)).to be false
      expect(user.has_permission?("posts.destroy", org)).to be false
    end
  end

  # ------------------------------------------------------------------
  # User without any permissions
  # ------------------------------------------------------------------

  describe "user without user_roles" do
    it "is denied all permissions" do
      user = create_user_without_permissions

      expect(user.has_permission?("posts.index")).to be false
      expect(user.has_permission?("posts.store")).to be false
    end
  end

  # ------------------------------------------------------------------
  # Organization-scoped permissions (via role)
  # ------------------------------------------------------------------

  describe "organization-scoped permissions" do
    it "checks permissions in the correct organization" do
      user = User.create!(name: "Multi-org User", email: "multiorg@example.com")

      org1 = Organization.create!(name: "Org A", slug: "org-a")
      org2 = Organization.create!(name: "Org B", slug: "org-b")

      role1 = Role.create!(name: "Admin", slug: "admin-scope-test", permissions: ["*"])
      role2 = Role.create!(name: "Viewer", slug: "viewer-scope-test", permissions: ["posts.index", "posts.show"])

      UserRole.create!(user: user, organization: org1, role: role1)
      UserRole.create!(user: user, organization: org2, role: role2)

      # In org1: can do everything
      expect(user.has_permission?("posts.store", org1)).to be true
      expect(user.has_permission?("posts.destroy", org1)).to be true

      # In org2: read-only
      expect(user.has_permission?("posts.index", org2)).to be true
      expect(user.has_permission?("posts.store", org2)).to be false
      expect(user.has_permission?("posts.destroy", org2)).to be false
    end
  end

  # ------------------------------------------------------------------
  # User role pivot permissions
  # ------------------------------------------------------------------

  describe "user_role.permissions (pivot-level)" do
    it "grants access via user_role.permissions when present" do
      user = User.create!(name: "Pivot User", email: "pivot-#{SecureRandom.uuid}@example.com")
      org = Organization.create!(name: "Pivot Org", slug: "pivot-org-#{SecureRandom.uuid}")
      role = Role.create!(name: "Empty Role", slug: "empty-#{SecureRandom.uuid}")
      UserRole.create!(user: user, organization: org, role: role, permissions: ["categories.*", "projects.index"])

      expect(user.has_permission?("categories.index", org)).to be true
      expect(user.has_permission?("categories.store", org)).to be true
      expect(user.has_permission?("projects.index", org)).to be true
      expect(user.has_permission?("projects.store", org)).to be false
    end

    it "prefers user_role.permissions over role.permissions" do
      user = User.create!(name: "Override User", email: "override-#{SecureRandom.uuid}@example.com")
      org = Organization.create!(name: "Override Org", slug: "override-org-#{SecureRandom.uuid}")
      role = Role.create!(name: "Full Role", slug: "full-override-#{SecureRandom.uuid}", permissions: ["*"])
      UserRole.create!(user: user, organization: org, role: role, permissions: ["posts.index"])

      # user_role.permissions overrides role.permissions
      expect(user.has_permission?("posts.index", org)).to be true
      expect(user.has_permission?("posts.store", org)).to be false
    end

    it "falls back to role.permissions when user_role.permissions is empty" do
      user = User.create!(name: "Fallback User", email: "fallback-#{SecureRandom.uuid}@example.com")
      org = Organization.create!(name: "Fallback Org", slug: "fallback-org-#{SecureRandom.uuid}")
      role = Role.create!(name: "Full Role", slug: "full-fallback-#{SecureRandom.uuid}", permissions: ["*"])
      UserRole.create!(user: user, organization: org, role: role, permissions: [])

      expect(user.has_permission?("posts.index", org)).to be true
      expect(user.has_permission?("anything.here", org)).to be true
    end
  end

  # ------------------------------------------------------------------
  # Role slug for validation
  # ------------------------------------------------------------------

  describe "#role_slug_for_validation" do
    it "returns the role slug" do
      user, org = create_user_with_permissions(["posts.index"])
      slug = user.role_slug_for_validation(org)
      expect(slug).to be_a(String)
      expect(slug).to start_with("test-role")
    end

    it "returns nil when user has no roles" do
      user = create_user_without_permissions
      expect(user.role_slug_for_validation(nil)).to be_nil
    end
  end

  # ------------------------------------------------------------------
  # User-level permissions (non-org-scoped, via users.permissions)
  # ------------------------------------------------------------------

  describe "user-level permissions" do
    it "grants access via users.permissions when no org context" do
      user = create_user_with_direct_permissions(["posts.index", "posts.show"])

      expect(user.has_permission?("posts.index")).to be true
      expect(user.has_permission?("posts.show")).to be true
      expect(user.has_permission?("posts.store")).to be false
    end

    it "supports wildcard * in users.permissions" do
      user = create_user_with_direct_permissions(["*"])

      expect(user.has_permission?("posts.index")).to be true
      expect(user.has_permission?("blogs.destroy")).to be true
      expect(user.has_permission?("anything.here")).to be true
    end

    it "supports resource wildcard in users.permissions" do
      user = create_user_with_direct_permissions(["posts.*"])

      expect(user.has_permission?("posts.index")).to be true
      expect(user.has_permission?("posts.store")).to be true
      expect(user.has_permission?("posts.destroy")).to be true
      expect(user.has_permission?("blogs.index")).to be false
    end

    it "org context checks role permissions not user permissions" do
      user, org = create_user_with_permissions(["posts.index"])
      user.update!(permissions: ["*"])

      # With org: uses role.permissions (limited), not users.permissions
      expect(user.has_permission?("posts.index", org)).to be true
      expect(user.has_permission?("posts.store", org)).to be false
    end

    it "org context uses role permissions even when user has broad direct permissions" do
      user = User.create!(
        name: "Dual User",
        email: "dual-#{SecureRandom.uuid}@example.com",
        permissions: ["posts.index"]
      )

      org = Organization.create!(name: "Check Org", slug: "check-org-#{SecureRandom.uuid}")
      role = Role.create!(name: "Full", slug: "full-#{SecureRandom.uuid}", permissions: ["*"])
      UserRole.create!(user: user, organization: org, role: role)

      # With org context: uses role.permissions (full access)
      expect(user.has_permission?("posts.store", org)).to be true
      expect(user.has_permission?("anything.here", org)).to be true

      # Without org context: uses users.permissions (limited)
      expect(user.has_permission?("posts.index")).to be true
      expect(user.has_permission?("posts.store")).to be false
    end

    it "does not use users.permissions when organization is provided" do
      org = Organization.create!(name: "Test Org GP", slug: "test-org-gp-#{SecureRandom.uuid}")
      user = create_user_with_direct_permissions(["*"])

      expect(user.has_permission?("posts.index", org)).to be false
    end

    it "returns false for nil permissions" do
      user = User.create!(
        name: "No Perms User",
        email: "noperms-#{SecureRandom.uuid}@example.com",
        permissions: nil
      )

      expect(user.has_permission?("posts.index")).to be false
    end

    it "returns false for empty permissions" do
      user = create_user_with_direct_permissions([])

      expect(user.has_permission?("posts.index")).to be false
    end

    it "parses string permissions (JSON encoded)" do
      user = User.create!(
        name: "String Perms",
        email: "strperms-#{SecureRandom.uuid}@example.com",
        permissions: '["posts.index", "posts.show"]'
      )

      expect(user.has_permission?("posts.index")).to be true
      expect(user.has_permission?("posts.show")).to be true
      expect(user.has_permission?("posts.store")).to be false
    end

    it "handles invalid JSON string permissions gracefully" do
      user = User.create!(
        name: "Bad JSON",
        email: "badjson-#{SecureRandom.uuid}@example.com",
        permissions: "not valid json"
      )

      expect(user.has_permission?("posts.index")).to be false
    end

    it "handles non-array non-string permissions" do
      user = User.create!(
        name: "Weird Perms",
        email: "weird-#{SecureRandom.uuid}@example.com",
        permissions: 42
      )

      expect(user.has_permission?("posts.index")).to be false
    end
  end
end
