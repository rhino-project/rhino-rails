# frozen_string_literal: true

require "spec_helper"

# --------------------------------------------------------------------------
# Test Policies for policy-driven validation
# --------------------------------------------------------------------------

class PolicyDrivenPostPolicy < Rhino::ResourcePolicy
  self.resource_slug = "posts"

  def permitted_attributes_for_create(user)
    if has_role?(user, 'admin')
      ['*']
    else
      ['title', 'content']
    end
  end

  def permitted_attributes_for_update(user)
    if has_role?(user, 'admin')
      ['*']
    else
      ['title', 'content']
    end
  end
end

RSpec.describe "PolicyDrivenValidation" do
  # ------------------------------------------------------------------
  # Helpers
  # ------------------------------------------------------------------

  def create_user_with_role(role_slug, permissions: ["*"])
    user = User.create!(name: "RB User", email: "rb-#{SecureRandom.uuid}@test.com")
    org = Organization.create!(name: "RB Org", slug: "rb-org-#{SecureRandom.uuid}")
    role = Role.create!(name: role_slug.capitalize, slug: role_slug, permissions: permissions)
    UserRole.create!(user: user, organization: org, role: role)
    [user, org]
  end

  # ------------------------------------------------------------------
  # Policy-driven field permissions
  # ------------------------------------------------------------------

  describe "policy-driven field permissions" do
    it "admin can set all fields with wildcard" do
      admin, org = create_user_with_role("admin")

      policy = PolicyDrivenPostPolicy.new(admin, Post)
      allow(policy).to receive(:current_organization).and_return(org)

      permitted = policy.permitted_attributes_for_create(admin)
      expect(permitted).to eq(['*'])
    end

    it "non-admin gets restricted fields" do
      editor, org = create_user_with_role("editor", permissions: ["posts.store"])

      policy = PolicyDrivenPostPolicy.new(editor, Post)
      allow(policy).to receive(:current_organization).and_return(org)

      permitted = policy.permitted_attributes_for_create(editor)
      expect(permitted).to eq(['title', 'content'])
    end

    it "validates only permitted fields" do
      instance = Post.new
      result = instance.validate_for_action(
        { "title" => "Hello", "content" => "World", "is_published" => true },
        permitted_fields: ['title', 'content']
      )

      expect(result[:valid]).to be true
      expect(result[:validated]).to have_key("title")
      expect(result[:validated]).to have_key("content")
      expect(result[:validated]).not_to have_key("is_published")
    end

    it "validates all fields for admin (wildcard)" do
      instance = Post.new
      result = instance.validate_for_action(
        { "title" => "Hello", "content" => "World", "is_published" => true },
        permitted_fields: ['*']
      )

      expect(result[:valid]).to be true
      expect(result[:validated]).to have_key("is_published")
    end
  end

  # ------------------------------------------------------------------
  # ActiveModel validation still works
  # ------------------------------------------------------------------

  describe "ActiveModel validation" do
    it "enforces model-level length constraint" do
      instance = Post.new
      result = instance.validate_for_action(
        { "title" => "a" * 256, "content" => "Content" },
        permitted_fields: ['*']
      )

      expect(result[:valid]).to be false
      expect(result[:errors]).to have_key("title")
    end
  end

  # ------------------------------------------------------------------
  # has_role? integration
  # ------------------------------------------------------------------

  describe "has_role? integration" do
    it "correctly identifies admin role" do
      admin, org = create_user_with_role("admin")

      policy = PolicyDrivenPostPolicy.new(admin, Post)
      allow(policy).to receive(:current_organization).and_return(org)

      expect(policy.has_role?(admin, 'admin')).to be true
      expect(policy.has_role?(admin, 'editor')).to be false
    end

    it "correctly identifies non-admin role" do
      editor, org = create_user_with_role("editor", permissions: ["posts.store"])

      policy = PolicyDrivenPostPolicy.new(editor, Post)
      allow(policy).to receive(:current_organization).and_return(org)

      expect(policy.has_role?(editor, 'editor')).to be true
      expect(policy.has_role?(editor, 'admin')).to be false
    end
  end
end
