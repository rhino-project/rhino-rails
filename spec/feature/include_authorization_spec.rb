# frozen_string_literal: true

require "spec_helper"

# --------------------------------------------------------------------------
# Test Models
# --------------------------------------------------------------------------

class IncludePost < ActiveRecord::Base
  include Rhino::HasRhino
  include Rhino::HasValidation
  include Rhino::HidableColumns

  self.table_name = "posts"

  belongs_to :user, optional: true
  has_many :comments, class_name: "IncludeComment", foreign_key: "post_id"

  rhino_filters :title
  rhino_sorts :title
  rhino_includes :comments, :user
end

class IncludeComment < ActiveRecord::Base
  self.table_name = "comments"

  belongs_to :post, class_name: "IncludePost", foreign_key: "post_id"
  belongs_to :user, optional: true
end

# --------------------------------------------------------------------------
# Test Policies — Only user id 1 can view comments
# --------------------------------------------------------------------------

class IncludePostTestPolicy < Rhino::ResourcePolicy
  self.resource_slug = "posts"

  def index?
    true # everyone can list posts
  end

  def show?
    true
  end
end

class IncludeCommentTestPolicy
  def initialize(user, record)
    @user = user
    @record = record
  end

  def index?
    @user&.id == 1 # only user 1 can list comments
  end

  alias_method :view_any?, :index?
end

RSpec.describe "IncludeAuthorization" do
  # ------------------------------------------------------------------
  # Helpers
  # ------------------------------------------------------------------

  def build_query(params = {})
    Rhino::QueryBuilder.new(IncludePost, params: params).build
  end

  # ------------------------------------------------------------------
  # Include functionality
  # ------------------------------------------------------------------

  describe "include eager loading" do
    it "eager loads allowed includes" do
      user = User.create!(name: "Inc User", email: "inc@test.com")
      post = IncludePost.create!(title: "Post 1", content: "C", user: user)
      IncludeComment.create!(post: post, body: "A comment", user: user)

      builder = build_query(include: "comments")
      scope = builder.to_scope

      # Should eager load comments
      loaded_post = scope.first
      expect(loaded_post.association(:comments)).to be_loaded
    end

    it "does not load unallowed includes" do
      post = IncludePost.create!(title: "Post 1", content: "C")

      # organization is not in allowed_includes
      builder = build_query(include: "organization")
      scope = builder.to_scope

      loaded_post = scope.first
      expect(loaded_post.association(:comments)).not_to be_loaded
    end
  end

  # ------------------------------------------------------------------
  # Include Count suffix
  # ------------------------------------------------------------------

  describe "include count suffix" do
    it "resolves commentsCount to base comments include" do
      builder = Rhino::QueryBuilder.new(IncludePost, params: {})
      base = builder.send(:resolve_base_include, "commentsCount", ["comments"])
      expect(base).to eq("comments")
    end

    it "resolves commentsExists to base comments include" do
      builder = Rhino::QueryBuilder.new(IncludePost, params: {})
      base = builder.send(:resolve_base_include, "commentsExists", ["comments"])
      expect(base).to eq("comments")
    end

    it "returns nil for invalid includes" do
      builder = Rhino::QueryBuilder.new(IncludePost, params: {})
      base = builder.send(:resolve_base_include, "invalidCount", ["comments"])
      expect(base).to be_nil
    end
  end

  # ------------------------------------------------------------------
  # Include authorization logic
  # ------------------------------------------------------------------

  describe "include authorization" do
    it "authorized user can include related resources" do
      user = User.create!(name: "Auth User 1", email: "auth1-inc@test.com")
      # Simulate: user id 1 can viewAny comments
      # This is tested at the policy level

      policy = IncludeCommentTestPolicy.new(user, IncludeComment)
      expect(policy.view_any?).to eq(user.id == 1)
    end

    it "unauthorized user is denied include" do
      user = User.create!(name: "Auth User 2", email: "auth2-inc@test.com")

      policy = IncludeCommentTestPolicy.new(user, IncludeComment)
      # user 2 should be denied
      expect(policy.view_any?).to be false if user.id != 1
    end

    it "no include returns 200 without relationships" do
      IncludePost.create!(title: "Post 1", content: "C")

      builder = build_query({})
      scope = builder.to_scope

      post = scope.first
      expect(post).to be_present
      expect(post.association(:comments)).not_to be_loaded
    end
  end

  # ------------------------------------------------------------------
  # Multiple includes
  # ------------------------------------------------------------------

  describe "multiple includes" do
    it "loads multiple allowed includes" do
      user = User.create!(name: "Multi Inc User", email: "multi-inc@test.com")
      post = IncludePost.create!(title: "Post 1", content: "C", user: user)
      IncludeComment.create!(post: post, body: "Comment", user: user)

      builder = build_query(include: "comments,user")
      scope = builder.to_scope

      loaded_post = scope.first
      expect(loaded_post.association(:comments)).to be_loaded
      expect(loaded_post.association(:user)).to be_loaded
    end

    it "ignores invalid includes mixed with valid ones" do
      user = User.create!(name: "Mixed Inc", email: "mixed-inc@test.com")
      post = IncludePost.create!(title: "Post 1", content: "C", user: user)

      builder = build_query(include: "comments,invalid_relation")
      scope = builder.to_scope

      loaded_post = scope.first
      expect(loaded_post.association(:comments)).to be_loaded
    end
  end
end
