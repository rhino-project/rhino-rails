# frozen_string_literal: true

require "spec_helper"

# --------------------------------------------------------------------------
# Test Models
# --------------------------------------------------------------------------

class RoutablePost < ActiveRecord::Base
  include Rhino::HasRhino
  include Rhino::HasValidation
  include Rhino::HidableColumns

  self.table_name = "posts"
end

class RoutablePostWithMiddleware < ActiveRecord::Base
  include Rhino::HasRhino
  include Rhino::HasValidation
  include Rhino::HidableColumns

  self.table_name = "posts"

  rhino_middleware "throttle:60,1"

  rhino_middleware_actions(
    store: ["verified"],
    update: ["verified"]
  )
end

class RoutablePostWithExcept < ActiveRecord::Base
  include Rhino::HasRhino
  include Rhino::HasValidation
  include Rhino::HidableColumns

  self.table_name = "posts"

  rhino_except_actions :destroy, :update
end

RSpec.describe "RouteRegistration" do
  # ------------------------------------------------------------------
  # Basic route config registration
  # ------------------------------------------------------------------

  describe "basic model registration" do
    it "registers models in config" do
      Rhino.configure do |c|
        c.model :posts, "Post"
        c.model :blogs, "Blog"
      end

      expect(Rhino.config.models).to have_key(:posts)
      expect(Rhino.config.models).to have_key(:blogs)
    end

    it "registers multiple models" do
      Rhino.configure do |c|
        c.model :posts, "Post"
        c.model :blogs, "Blog"
      end

      expect(Rhino.config.models.size).to eq(2)
    end
  end

  # ------------------------------------------------------------------
  # Route URL structure
  # ------------------------------------------------------------------

  describe "route URL structure" do
    it "generates correct slug-based paths" do
      Rhino.configure do |c|
        c.model :posts, "Post"
      end

      expect(Rhino.config.models[:posts]).to eq("Post")
    end
  end

  # ------------------------------------------------------------------
  # Soft delete route detection
  # ------------------------------------------------------------------

  describe "soft delete route detection" do
    it "detects soft delete model for route registration" do
      expect(Post.uses_soft_deletes?).to be true
    end

    it "does not detect soft deletes on non-soft-delete model" do
      expect(Blog.uses_soft_deletes?).to be false
    end
  end

  # ------------------------------------------------------------------
  # Model-level middleware
  # ------------------------------------------------------------------

  describe "model-level middleware" do
    it "stores model middleware" do
      expect(RoutablePostWithMiddleware.rhino_model_middleware).to eq(["throttle:60,1"])
    end

    it "stores per-action middleware" do
      map = RoutablePostWithMiddleware.rhino_middleware_actions_map
      expect(map["store"]).to eq(["verified"])
      expect(map["update"]).to eq(["verified"])
    end

    it "model without middleware has empty arrays" do
      expect(RoutablePost.rhino_model_middleware).to eq([])
      expect(RoutablePost.rhino_middleware_actions_map).to eq({})
    end
  end

  # ------------------------------------------------------------------
  # Except actions
  # ------------------------------------------------------------------

  describe "except actions" do
    it "stores excepted actions" do
      expect(RoutablePostWithExcept.rhino_except_actions_list).to contain_exactly("destroy", "update")
    end

    it "model without except has empty array" do
      expect(RoutablePost.rhino_except_actions_list).to eq([])
    end
  end

  # ------------------------------------------------------------------
  # Route groups configuration
  # ------------------------------------------------------------------

  describe "route groups configuration" do
    it "configures a tenant route group with prefix" do
      Rhino.configure do |c|
        c.model :posts, "Post"
        c.route_group :tenant, prefix: ":organization", middleware: ["ResolveOrg"], models: :all
      end

      expect(Rhino.config.has_tenant_group?).to be true
      expect(Rhino.config.route_groups[:tenant][:prefix]).to eq(":organization")
    end

    it "configures multiple route groups" do
      Rhino.reset_configuration!
      Rhino.configure do |c|
        c.model :posts, "Post"
        c.route_group :tenant, prefix: ":organization", models: :all
        c.route_group :driver, prefix: "driver", models: [:posts]
        c.route_group :admin, prefix: "admin", models: :all
      end

      expect(Rhino.config.route_groups.size).to eq(3)
    end
  end

  # ------------------------------------------------------------------
  # Public route group
  # ------------------------------------------------------------------

  describe "public route group" do
    it "marks models as public via public route group" do
      Rhino.configure do |c|
        c.model :posts, "Post"
        c.route_group :public, prefix: "public", models: [:posts]
      end

      expect(Rhino.config.public_model?(:posts)).to be true
    end

    it "non-public models are not in public group" do
      Rhino.configure do |c|
        c.model :posts, "Post"
        c.route_group :default, models: :all
      end

      expect(Rhino.config.public_model?(:posts)).to be false
    end
  end

  # ------------------------------------------------------------------
  # Route defaults (model slug)
  # ------------------------------------------------------------------

  describe "route defaults / model slug resolution" do
    it "resolves model from slug" do
      Rhino.configure do |c|
        c.model :posts, "Post"
      end

      model_class = Rhino.config.resolve_model("posts")
      expect(model_class).to eq(Post)
    end

    it "raises error for unknown slug" do
      Rhino.configure do |c|
        c.model :posts, "Post"
      end

      expect {
        Rhino.config.resolve_model("nonexistent")
      }.to raise_error(ActiveRecord::RecordNotFound)
    end
  end

  # ------------------------------------------------------------------
  # Empty config
  # ------------------------------------------------------------------

  describe "empty config" do
    it "has no models when none configured" do
      Rhino.reset_configuration!

      expect(Rhino.config.models).to be_empty
    end
  end
end
