# frozen_string_literal: true

require "spec_helper"
require "request_store"

# --------------------------------------------------------------------------
# Test Models
# --------------------------------------------------------------------------

class HidablePost < ActiveRecord::Base
  include Rhino::HidableColumns
  self.table_name = "posts"
end

class HidablePostWithAdditional < ActiveRecord::Base
  include Rhino::HidableColumns
  self.table_name = "posts"

  rhino_additional_hidden :status, :is_published
end

class HidablePostWithComputed < ActiveRecord::Base
  include Rhino::HidableColumns
  self.table_name = "posts"

  def days_until_expiry
    42
  end

  def secret_score
    "classified"
  end

  def rhino_computed_attributes
    {
      'days_until_expiry' => days_until_expiry,
      'secret_score' => secret_score
    }
  end
end

# --------------------------------------------------------------------------
# Test Policies
# --------------------------------------------------------------------------

class HidablePostPolicy < Rhino::ResourcePolicy
  self.resource_slug = "posts"

  def hidden_attributes_for_show(user)
    return ["status", "is_published", "content"] unless user
    return [] if user.id == 1 # admin
    ["status"] # regular user
  end
end

class HidablePostWithAdditionalPolicy < Rhino::ResourcePolicy
  self.resource_slug = "posts"

  def hidden_attributes_for_show(user)
    return ["content"] unless user
    []
  end
end

RSpec.describe Rhino::HidableColumns do
  before(:each) do
    RequestStore.store[:rhino_current_user] = nil
  end

  # ------------------------------------------------------------------
  # Base hidden columns
  # ------------------------------------------------------------------

  describe "BASE_HIDDEN_COLUMNS" do
    it "includes sensitive columns" do
      expect(Rhino::HidableColumns::BASE_HIDDEN_COLUMNS).to include(
        "password", "password_digest", "remember_token",
        "created_at", "updated_at", "deleted_at", "discarded_at",
        "email_verified_at"
      )
    end
  end

  # ------------------------------------------------------------------
  # hidden_columns_for
  # ------------------------------------------------------------------

  describe "#hidden_columns_for" do
    it "returns base hidden columns for model without policy" do
      post = HidablePost.create!(title: "Test", content: "Content")
      hidden = post.hidden_columns_for
      expect(hidden).to include("password", "password_digest", "created_at", "updated_at")
    end

    it "includes additional hidden columns" do
      post = HidablePostWithAdditional.create!(title: "Test", content: "Content")
      hidden = post.hidden_columns_for
      expect(hidden).to include("status", "is_published")
    end

    it "includes policy-based hidden columns for guest" do
      allow(Pundit::PolicyFinder).to receive(:new).and_return(
        double(policy: HidablePostPolicy)
      )

      post = HidablePost.create!(title: "Test", content: "Content")
      hidden = post.hidden_columns_for
      expect(hidden).to include("status", "is_published", "content")
    end

    it "includes fewer hidden columns for admin" do
      allow(Pundit::PolicyFinder).to receive(:new).and_return(
        double(policy: HidablePostPolicy)
      )

      admin = User.create!(id: 1, name: "Admin", email: "admin-hid@test.com")
      RequestStore.store[:rhino_current_user] = admin
      post = HidablePost.create!(title: "Test", content: "Content")
      hidden = post.hidden_columns_for

      expect(hidden).not_to include("status", "is_published", "content")
    end

    it "deduplicates column names" do
      allow(Pundit::PolicyFinder).to receive(:new).and_return(
        double(policy: HidablePostWithAdditionalPolicy)
      )

      post = HidablePostWithAdditional.create!(title: "Test", content: "Content")
      hidden = post.hidden_columns_for
      expect(hidden).to eq(hidden.uniq)
    end
  end

  # ------------------------------------------------------------------
  # as_rhino_json
  # ------------------------------------------------------------------

  describe "#as_rhino_json" do
    it "excludes hidden columns from JSON output" do
      post = HidablePost.create!(title: "Test", content: "Visible", status: "published")
      json = post.as_rhino_json

      expect(json).not_to have_key("created_at")
      expect(json).not_to have_key("updated_at")
      expect(json).not_to have_key("discarded_at")

      expect(json).to have_key("id")
      expect(json).to have_key("title")
      expect(json["title"]).to eq("Test")
    end

    it "includes additional hidden columns in exclusion" do
      post = HidablePostWithAdditional.create!(title: "Test", content: "Visible", status: "published")
      json = post.as_rhino_json

      expect(json).not_to have_key("status")
      expect(json).not_to have_key("is_published")
    end

    it "resolves user from RequestStore automatically" do
      allow(Pundit::PolicyFinder).to receive(:new).and_return(
        double(policy: HidablePostPolicy)
      )

      post = HidablePost.create!(title: "Test", content: "Content", status: "draft")

      # Guest — status, is_published, content hidden
      json = post.as_rhino_json
      expect(json).not_to have_key("status")
      expect(json).not_to have_key("content")

      # Admin — sees everything
      admin = User.create!(id: 1, name: "Admin", email: "admin-rs@test.com")
      RequestStore.store[:rhino_current_user] = admin
      json = post.as_rhino_json
      expect(json).to have_key("status")
      expect(json).to have_key("content")
    end
  end

  # ------------------------------------------------------------------
  # rhino_computed_attributes
  # ------------------------------------------------------------------

  describe "#rhino_computed_attributes" do
    it "returns empty hash by default" do
      post = HidablePost.create!(title: "Test", content: "Content")
      expect(post.rhino_computed_attributes).to eq({})
    end

    it "includes computed attributes in as_rhino_json output" do
      post = HidablePostWithComputed.create!(title: "Test", content: "Content")
      json = post.as_rhino_json

      expect(json).to have_key("days_until_expiry")
      expect(json["days_until_expiry"]).to eq(42)
      expect(json).to have_key("secret_score")
      expect(json["secret_score"]).to eq("classified")
      expect(json).to have_key("title")
    end

    it "policy blacklist hides computed attributes" do
      policy_class = Class.new(Rhino::ResourcePolicy) do
        self.resource_slug = "posts"

        def hidden_attributes_for_show(user)
          return ["secret_score"] unless user
          []
        end
      end

      allow(Pundit::PolicyFinder).to receive(:new).and_return(
        double(policy: policy_class)
      )

      post = HidablePostWithComputed.create!(title: "Test", content: "Content")

      # Guest: secret_score hidden by policy
      json = post.as_rhino_json
      expect(json).to have_key("days_until_expiry")
      expect(json).not_to have_key("secret_score")

      # Auth user: sees everything
      user = User.create!(id: 2, name: "User", email: "user-bl@test.com")
      RequestStore.store[:rhino_current_user] = user
      json = post.as_rhino_json
      expect(json).to have_key("secret_score")
      expect(json).to have_key("days_until_expiry")
    end

    it "policy whitelist filters computed attributes" do
      policy_class = Class.new(Rhino::ResourcePolicy) do
        self.resource_slug = "posts"

        def permitted_attributes_for_show(user)
          return ["id", "title", "days_until_expiry"] unless user
          ["*"]
        end
      end

      allow(Pundit::PolicyFinder).to receive(:new).and_return(
        double(policy: policy_class)
      )

      post = HidablePostWithComputed.create!(title: "Test", content: "Content")

      # Guest: only id, title, days_until_expiry permitted
      json = post.as_rhino_json
      expect(json).to have_key("id")
      expect(json).to have_key("title")
      expect(json).to have_key("days_until_expiry")
      expect(json).not_to have_key("secret_score")
      expect(json).not_to have_key("content")

      # Auth user: sees everything
      user = User.create!(id: 3, name: "User", email: "user-wl@test.com")
      RequestStore.store[:rhino_current_user] = user
      json = post.as_rhino_json
      expect(json).to have_key("secret_score")
      expect(json).to have_key("days_until_expiry")
    end

    it "computed attributes not in whitelist are excluded (security)" do
      policy_class = Class.new(Rhino::ResourcePolicy) do
        self.resource_slug = "posts"

        def permitted_attributes_for_show(user)
          ["id", "title"] # secret_score and days_until_expiry NOT listed
        end
      end

      allow(Pundit::PolicyFinder).to receive(:new).and_return(
        double(policy: policy_class)
      )

      post = HidablePostWithComputed.create!(title: "Test", content: "Content")
      json = post.as_rhino_json

      expect(json).to have_key("id")
      expect(json).to have_key("title")
      expect(json).not_to have_key("days_until_expiry")
      expect(json).not_to have_key("secret_score")
    end

    it "computed attributes in blacklist are excluded (security)" do
      policy_class = Class.new(Rhino::ResourcePolicy) do
        self.resource_slug = "posts"

        def hidden_attributes_for_show(user)
          ["secret_score", "days_until_expiry"]
        end
      end

      allow(Pundit::PolicyFinder).to receive(:new).and_return(
        double(policy: policy_class)
      )

      post = HidablePostWithComputed.create!(title: "Test", content: "Content")
      json = post.as_rhino_json

      expect(json).to have_key("title")
      expect(json).not_to have_key("secret_score")
      expect(json).not_to have_key("days_until_expiry")
    end
  end

  # ------------------------------------------------------------------
  # Edge cases
  # ------------------------------------------------------------------

  describe "edge cases" do
    it "handles missing policy gracefully" do
      post = HidablePost.create!(title: "Test", content: "Content")
      expect { post.hidden_columns_for }.not_to raise_error
    end

    it "handles policy without hidden_attributes_for_show method" do
      allow(Pundit::PolicyFinder).to receive(:new).and_return(
        double(policy: Class.new { def initialize(u, r); end })
      )

      post = HidablePost.create!(title: "Test", content: "Content")
      hidden = post.hidden_columns_for
      expect(hidden).to include("password")
    end

    it "handles policy that raises an error in policy_hidden_columns" do
      error_policy_class = Class.new do
        def initialize(u, r); end
        def hidden_attributes_for_show(user)
          raise StandardError, "broken policy"
        end
      end

      allow(Pundit::PolicyFinder).to receive(:new).and_return(
        double(policy: error_policy_class)
      )

      post = HidablePost.create!(title: "Test", content: "Content")
      hidden = post.hidden_columns_for
      expect(hidden).to include("password")
    end

    it "handles policy that raises an error in policy_permitted_attributes" do
      error_policy_class = Class.new do
        def initialize(u, r); end
        def permitted_attributes_for_show(user)
          raise StandardError, "broken policy"
        end
      end

      allow(Pundit::PolicyFinder).to receive(:new).and_return(
        double(policy: error_policy_class)
      )

      post = HidablePost.create!(title: "Test", content: "Content")
      json = post.as_rhino_json
      expect(json).to have_key("id")
    end

    it "handles rhino_computed_attributes returning non-hash gracefully" do
      post = HidablePost.create!(title: "Test", content: "Content")
      allow(post).to receive(:rhino_computed_attributes).and_return(nil)
      expect { post.as_rhino_json }.not_to raise_error
    end
  end

  # ------------------------------------------------------------------
  # Backward compat: as_json overrides still work with policy
  # ------------------------------------------------------------------

  describe "as_json overrides" do
    it "computed attributes via as_json are also filtered by policy" do
      policy_class = Class.new(Rhino::ResourcePolicy) do
        self.resource_slug = "posts"

        def hidden_attributes_for_show(user)
          ["risk_score"]
        end
      end

      allow(Pundit::PolicyFinder).to receive(:new).and_return(
        double(policy: policy_class)
      )

      post = HidablePost.create!(title: "Test", content: "Content")
      def post.as_json(options = {})
        super.merge("risk_score" => "high", "days_left" => 10)
      end

      json = post.as_rhino_json
      expect(json).not_to have_key("risk_score")
      expect(json).to have_key("days_left")
    end
  end

  # ------------------------------------------------------------------
  # permitted_attributes_for_show filtering
  # ------------------------------------------------------------------

  describe "permitted_attributes_for_show filtering" do
    it "hides columns not in permitted list" do
      policy_class = Class.new(Rhino::ResourcePolicy) do
        self.resource_slug = "posts"

        def permitted_attributes_for_show(user)
          return ['id', 'title'] unless user
          ['*']
        end
      end

      allow(Pundit::PolicyFinder).to receive(:new).and_return(
        double(policy: policy_class)
      )

      post = HidablePost.create!(title: "Test", content: "Content", status: "draft")
      json = post.as_rhino_json

      expect(json).to have_key("id")
      expect(json).to have_key("title")
      expect(json).not_to have_key("content")
      expect(json).not_to have_key("status")
      expect(json).not_to have_key("blog_id")
    end
  end
end
