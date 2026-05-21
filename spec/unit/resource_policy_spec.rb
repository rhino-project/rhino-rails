# frozen_string_literal: true

require "spec_helper"

# --------------------------------------------------------------------------
# Test Policies
# --------------------------------------------------------------------------

class ExplicitSlugPolicy < Rhino::ResourcePolicy
  self.resource_slug = "posts"
end

class OverrideWithParentPolicy < Rhino::ResourcePolicy
  self.resource_slug = "posts"

  # Custom delete: only allow if user owns the post AND has permission.
  def destroy?
    return false unless super

    record.respond_to?(:user_id) && user.id == record.user_id
  end
end

class FullOverridePolicy < Rhino::ResourcePolicy
  self.resource_slug = "posts"

  # Anyone authenticated can view, regardless of permissions.
  def index?
    user.present?
  end
end

RSpec.describe Rhino::ResourcePolicy do
  # ------------------------------------------------------------------
  # Helpers
  # ------------------------------------------------------------------

  def create_user_with_permissions(permissions)
    id = SecureRandom.uuid
    User.create!(name: "Policy User", email: "policy-#{id}@example.com", permissions: permissions)
  end

  def create_user_with_org_permissions(permissions)
    id = SecureRandom.uuid
    user = User.create!(name: "Policy User", email: "policy-#{id}@example.com", permissions: permissions)
    org = Organization.create!(name: "Policy Org", slug: "policy-org-#{id}")
    role = Role.create!(name: "Policy Role", slug: "policy-role-#{id}", permissions: permissions)
    UserRole.create!(user: user, organization: org, role: role)
    user
  end

  def create_user_without_permissions
    User.create!(name: "No Perms", email: "noperms-policy-#{SecureRandom.uuid}@example.com")
  end

  # ------------------------------------------------------------------
  # Basic permission checks
  # ------------------------------------------------------------------

  describe "basic permission checks" do
    it "allows user with exact permission" do
      user = create_user_with_permissions(["posts.index"])
      policy = ExplicitSlugPolicy.new(user, Post)
      expect(policy.index?).to be true
    end

    it "denies user without matching permission" do
      user = create_user_with_permissions(["posts.index"])
      policy = ExplicitSlugPolicy.new(user, Post)
      expect(policy.create?).to be false
    end

    it "denies guest user (nil)" do
      policy = ExplicitSlugPolicy.new(nil, Post)
      expect(policy.index?).to be false
      expect(policy.show?).to be false
      expect(policy.create?).to be false
      expect(policy.update?).to be false
      expect(policy.destroy?).to be false
    end
  end

  # ------------------------------------------------------------------
  # Wildcard permissions
  # ------------------------------------------------------------------

  describe "wildcard permissions" do
    it "grants all access with * wildcard" do
      user = create_user_with_permissions(["*"])
      policy = ExplicitSlugPolicy.new(user, Post)

      expect(policy.index?).to be true
      expect(policy.show?).to be true
      expect(policy.create?).to be true
      expect(policy.update?).to be true
      expect(policy.destroy?).to be true
    end

    it "grants all actions on resource with resource.*" do
      user = create_user_with_permissions(["posts.*"])
      policy = ExplicitSlugPolicy.new(user, Post)

      expect(policy.index?).to be true
      expect(policy.show?).to be true
      expect(policy.create?).to be true
      expect(policy.update?).to be true
      expect(policy.destroy?).to be true
    end
  end

  # ------------------------------------------------------------------
  # Action → Permission mapping
  # ------------------------------------------------------------------

  describe "action to permission mapping" do
    it "maps each policy method to the correct permission" do
      mapping = {
        index?: "posts.index",
        show?: "posts.show",
        create?: "posts.store",
        update?: "posts.update",
        destroy?: "posts.destroy"
      }

      mapping.each do |method, permission|
        user = create_user_with_permissions([permission])
        policy = ExplicitSlugPolicy.new(user, Post.new)

        expect(policy.send(method)).to be(true),
          "Expected #{method} to be allowed with permission '#{permission}'"

        # Other methods should fail
        (mapping.keys - [method]).each do |other_method|
          expect(policy.send(other_method)).to be(false),
            "Expected #{other_method} to be denied when only '#{permission}' is granted"
        end
      end
    end
  end

  # ------------------------------------------------------------------
  # Soft delete permissions
  # ------------------------------------------------------------------

  describe "soft delete permissions" do
    it "checks trashed permission" do
      user = create_user_with_permissions(["posts.trashed"])
      policy = ExplicitSlugPolicy.new(user, Post)
      expect(policy.view_trashed?).to be true
    end

    it "checks restore permission" do
      user = create_user_with_permissions(["posts.restore"])
      policy = ExplicitSlugPolicy.new(user, Post)
      expect(policy.restore?).to be true
    end

    it "checks forceDelete permission" do
      user = create_user_with_permissions(["posts.forceDelete"])
      policy = ExplicitSlugPolicy.new(user, Post)
      expect(policy.force_delete?).to be true
    end
  end

  # ------------------------------------------------------------------
  # Policy override patterns
  # ------------------------------------------------------------------

  describe "override with parent composition" do
    it "allows when user owns the post AND has permission" do
      user = create_user_with_permissions(["posts.destroy"])
      post = Post.new(user_id: user.id)
      policy = OverrideWithParentPolicy.new(user, post)
      expect(policy.destroy?).to be true
    end

    it "denies when user has permission but does NOT own the post" do
      user = create_user_with_permissions(["posts.destroy"])
      post = Post.new(user_id: 999)
      policy = OverrideWithParentPolicy.new(user, post)
      expect(policy.destroy?).to be false
    end

    it "denies when user owns the post but lacks permission" do
      user = create_user_with_permissions(["posts.index"])
      post = Post.new(user_id: user.id)
      policy = OverrideWithParentPolicy.new(user, post)
      expect(policy.destroy?).to be false
    end
  end

  describe "full override ignores permissions" do
    it "allows any authenticated user for viewAny" do
      user = create_user_without_permissions
      policy = FullOverridePolicy.new(user, Post)
      expect(policy.index?).to be true
    end

    it "still denies other methods via default ResourcePolicy" do
      user = create_user_without_permissions
      policy = FullOverridePolicy.new(user, Post)
      expect(policy.create?).to be false
    end
  end

  # ------------------------------------------------------------------
  # Auto-resolution of resource slug
  # ------------------------------------------------------------------

  describe "auto-resolution of resource slug from config" do
    it "resolves slug from Rhino config" do
      user = create_user_with_permissions(["posts.index"])
      policy = PostPolicy.new(user, Post)
      expect(policy.index?).to be true
    end
  end

  # ------------------------------------------------------------------
  # Attribute permission defaults
  # ------------------------------------------------------------------

  describe "attribute permission defaults" do
    it "returns ['*'] for permitted_attributes_for_show" do
      policy = described_class.new(nil, Post.new)
      expect(policy.permitted_attributes_for_show(nil)).to eq(['*'])
    end

    it "returns [] for hidden_attributes_for_show" do
      policy = described_class.new(nil, Post.new)
      expect(policy.hidden_attributes_for_show(nil)).to eq([])
    end

    it "returns ['*'] for permitted_attributes_for_create" do
      policy = described_class.new(nil, Post.new)
      expect(policy.permitted_attributes_for_create(nil)).to eq(['*'])
    end

    it "returns ['*'] for permitted_attributes_for_update" do
      policy = described_class.new(nil, Post.new)
      expect(policy.permitted_attributes_for_update(nil)).to eq(['*'])
    end
  end

  # ------------------------------------------------------------------
  # has_role?
  # ------------------------------------------------------------------

  describe "has_role?" do
    it "returns false for nil user" do
      policy = described_class.new(nil, Post.new)
      expect(policy.has_role?(nil, 'admin')).to be false
    end

    it "returns true when user has matching role" do
      user = create_user_with_org_permissions(["*"])
      # Need org in RequestStore for has_role? to work
      policy = described_class.new(user, Post.new)
      org = Organization.last
      allow(policy).to receive(:current_organization).and_return(org)
      expect(policy.has_role?(user, user.user_roles.first.role.slug)).to be true
    end

    it "returns false when user has different role" do
      user = create_user_with_org_permissions(["*"])
      policy = described_class.new(user, Post.new)
      org = Organization.last
      allow(policy).to receive(:current_organization).and_return(org)
      expect(policy.has_role?(user, 'nonexistent')).to be false
    end
  end

  # ------------------------------------------------------------------
  # Aliases
  # ------------------------------------------------------------------

  # ------------------------------------------------------------------
  # Fallback when user doesn't implement has_permission?
  # ------------------------------------------------------------------

  describe "check_permission fallback" do
    it "allows when user does not respond to has_permission?" do
      user = double("basic_user")
      allow(user).to receive(:respond_to?).with(:has_permission?).and_return(false)
      allow(user).to receive(:respond_to?).with(:role_slug_for_validation).and_return(false)
      allow(user).to receive(:nil?).and_return(false)
      allow(user).to receive(:present?).and_return(true)

      policy = ExplicitSlugPolicy.new(user, Post)
      expect(policy.index?).to be true
    end
  end

  # ------------------------------------------------------------------
  # Auto-resolve slug from instance
  # ------------------------------------------------------------------

  describe "auto-resolve slug from model instance" do
    it "resolves slug from Rhino config using a model instance" do
      # Use a policy without explicit resource_slug
      policy_class = Class.new(Rhino::ResourcePolicy)
      user = create_user_with_permissions(["posts.index"])
      post = Post.new(title: "Test")

      policy = policy_class.new(user, post)
      expect(policy.index?).to be true
    end
  end

  # ------------------------------------------------------------------
  # Method aliases
  # ------------------------------------------------------------------

  describe "method aliases" do
    it "aliases view_any? to index?" do
      user = create_user_with_permissions(["posts.index"])
      policy = ExplicitSlugPolicy.new(user, Post)
      expect(policy.view_any?).to eq(policy.index?)
    end

    it "aliases view? to show?" do
      user = create_user_with_permissions(["posts.show"])
      policy = ExplicitSlugPolicy.new(user, Post.new)
      expect(policy.view?).to eq(policy.show?)
    end

    it "aliases delete? to destroy?" do
      user = create_user_with_permissions(["posts.destroy"])
      policy = ExplicitSlugPolicy.new(user, Post.new)
      expect(policy.delete?).to eq(policy.destroy?)
    end
  end
end
