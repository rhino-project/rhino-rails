# frozen_string_literal: true

require "spec_helper"

RSpec.describe "RouteGroups" do
  # ------------------------------------------------------------------
  # Configuration
  # ------------------------------------------------------------------

  describe "configuration" do
    it "registers route groups via DSL" do
      Rhino.reset_configuration!
      Rhino.configure do |c|
        c.model :posts, "Post"
        c.model :blogs, "Blog"
        c.route_group :default, prefix: "", models: :all
      end

      expect(Rhino.config.route_groups).to have_key(:default)
      expect(Rhino.config.models_for_group(:default)).to contain_exactly(:posts, :blogs)
    end

    it "supports :all wildcard for models" do
      Rhino.reset_configuration!
      Rhino.configure do |c|
        c.model :posts, "Post"
        c.model :blogs, "Blog"
        c.route_group :admin, prefix: "admin", models: :all
      end

      expect(Rhino.config.models_for_group(:admin)).to contain_exactly(:posts, :blogs)
    end

    it "supports '*' string wildcard for models" do
      Rhino.reset_configuration!
      Rhino.configure do |c|
        c.model :posts, "Post"
        c.model :blogs, "Blog"
        c.route_group :admin, prefix: "admin", models: "*"
      end

      expect(Rhino.config.models_for_group(:admin)).to contain_exactly(:posts, :blogs)
    end

    it "supports array of model slugs" do
      Rhino.reset_configuration!
      Rhino.configure do |c|
        c.model :posts, "Post"
        c.model :blogs, "Blog"
        c.route_group :driver, prefix: "driver", models: [:posts]
      end

      expect(Rhino.config.models_for_group(:driver)).to eq([:posts])
    end

    it "filters out unregistered slugs from model list" do
      Rhino.reset_configuration!
      Rhino.configure do |c|
        c.model :posts, "Post"
        c.route_group :driver, prefix: "driver", models: [:posts, :nonexistent]
      end

      expect(Rhino.config.models_for_group(:driver)).to eq([:posts])
    end
  end

  # ------------------------------------------------------------------
  # Domain configuration
  # ------------------------------------------------------------------

  describe "domain configuration" do
    it "defaults domain to nil when not provided (backward compatible)" do
      Rhino.reset_configuration!
      Rhino.configure do |c|
        c.model :posts, "Post"
        c.route_group :default, prefix: "", models: :all
      end

      expect(Rhino.config.route_groups[:default][:domain]).to be_nil
    end

    it "stores a literal domain" do
      Rhino.reset_configuration!
      Rhino.configure do |c|
        c.model :posts, "Post"
        c.route_group :admin, prefix: "admin", domain: "admin.example.com", models: :all
      end

      expect(Rhino.config.route_groups[:admin][:domain]).to eq("admin.example.com")
    end

    it "stores a parameterized domain" do
      Rhino.reset_configuration!
      Rhino.configure do |c|
        c.model :posts, "Post"
        c.route_group :tenant, prefix: "", domain: "{organization}.example.com", models: :all
      end

      expect(Rhino.config.route_groups[:tenant][:domain]).to eq("{organization}.example.com")
    end

    it "normalizes a blank/empty-string domain to nil" do
      Rhino.reset_configuration!
      Rhino.configure do |c|
        c.model :posts, "Post"
        c.route_group :a, prefix: "a", domain: "", models: :all
        c.route_group :b, prefix: "b", domain: "   ", models: :all
      end

      expect(Rhino.config.route_groups[:a][:domain]).to be_nil
      expect(Rhino.config.route_groups[:b][:domain]).to be_nil
    end

    it "trims surrounding whitespace from a domain" do
      Rhino.reset_configuration!
      Rhino.configure do |c|
        c.model :posts, "Post"
        c.route_group :admin, prefix: "admin", domain: "  admin.example.com  ", models: :all
      end

      expect(Rhino.config.route_groups[:admin][:domain]).to eq("admin.example.com")
    end

    it "allows domain and prefix to be configured independently and together" do
      Rhino.reset_configuration!
      Rhino.configure do |c|
        c.model :posts, "Post"
        c.route_group :admin, prefix: "admin", domain: "admin.example.com", models: :all
      end

      group = Rhino.config.route_groups[:admin]
      expect(group[:prefix]).to eq("admin")
      expect(group[:domain]).to eq("admin.example.com")
    end
  end

  # ------------------------------------------------------------------
  # Tenant group detection
  # ------------------------------------------------------------------

  describe "tenant group detection" do
    it "detects presence of tenant group" do
      Rhino.reset_configuration!
      Rhino.configure do |c|
        c.model :posts, "Post"
        c.route_group :tenant, prefix: ":organization", models: :all
      end

      expect(Rhino.config.has_tenant_group?).to be true
    end

    it "returns false when no tenant group exists" do
      Rhino.reset_configuration!
      Rhino.configure do |c|
        c.model :posts, "Post"
        c.route_group :default, prefix: "", models: :all
      end

      expect(Rhino.config.has_tenant_group?).to be false
    end
  end

  # ------------------------------------------------------------------
  # Public group detection
  # ------------------------------------------------------------------

  describe "public group detection" do
    it "detects presence of public group" do
      Rhino.reset_configuration!
      Rhino.configure do |c|
        c.model :posts, "Post"
        c.route_group :public, prefix: "public", models: [:posts]
      end

      expect(Rhino.config.has_public_group?).to be true
    end

    it "marks models in public group as public" do
      Rhino.reset_configuration!
      Rhino.configure do |c|
        c.model :posts, "Post"
        c.model :blogs, "Blog"
        c.route_group :public, prefix: "public", models: [:posts]
      end

      expect(Rhino.config.public_model?(:posts)).to be true
      expect(Rhino.config.public_model?(:blogs)).to be false
    end
  end

  # ------------------------------------------------------------------
  # Multiple groups with same model
  # ------------------------------------------------------------------

  describe "same model in multiple groups" do
    it "allows the same model in different groups" do
      Rhino.reset_configuration!
      Rhino.configure do |c|
        c.model :posts, "Post"
        c.route_group :tenant, prefix: ":organization", models: :all
        c.route_group :admin, prefix: "admin", models: :all
        c.route_group :public, prefix: "public", models: [:posts]
      end

      expect(Rhino.config.model_in_group?(:posts, :tenant)).to be true
      expect(Rhino.config.model_in_group?(:posts, :admin)).to be true
      expect(Rhino.config.model_in_group?(:posts, :public)).to be true
    end
  end

  # ------------------------------------------------------------------
  # Hybrid logistics platform config
  # ------------------------------------------------------------------

  describe "hybrid logistics platform configuration" do
    before do
      Rhino.reset_configuration!
      Rhino.configure do |c|
        c.model :posts, "Post"
        c.model :blogs, "Blog"

        c.route_group :tenant, prefix: ":organization", models: :all
        c.route_group :driver, prefix: "driver", models: [:posts]
        c.route_group :admin, prefix: "admin", models: :all
        c.route_group :public, prefix: "public", models: [:blogs]

        c.multi_tenant = { organization_identifier_column: "slug" }
      end
    end

    it "has 4 route groups" do
      expect(Rhino.config.route_groups.size).to eq(4)
    end

    it "tenant group includes all models" do
      expect(Rhino.config.models_for_group(:tenant)).to contain_exactly(:posts, :blogs)
    end

    it "driver group includes only specified models" do
      expect(Rhino.config.models_for_group(:driver)).to eq([:posts])
    end

    it "admin group includes all models" do
      expect(Rhino.config.models_for_group(:admin)).to contain_exactly(:posts, :blogs)
    end

    it "public group includes only specified models" do
      expect(Rhino.config.models_for_group(:public)).to eq([:blogs])
    end

    it "only blogs are public" do
      expect(Rhino.config.public_model?(:blogs)).to be true
      expect(Rhino.config.public_model?(:posts)).to be false
    end

    it "has tenant group detected" do
      expect(Rhino.config.has_tenant_group?).to be true
    end

    it "has public group detected" do
      expect(Rhino.config.has_public_group?).to be true
    end

    it "organization_identifier_column is slug" do
      expect(Rhino.config.multi_tenant[:organization_identifier_column]).to eq("slug")
    end
  end

  # ------------------------------------------------------------------
  # Middleware configuration
  # ------------------------------------------------------------------

  describe "middleware configuration" do
    it "stores middleware array for each group" do
      Rhino.reset_configuration!
      Rhino.configure do |c|
        c.model :posts, "Post"
        c.route_group :tenant, prefix: ":organization", middleware: ["ResolveOrg", "VerifyMembership"], models: :all
        c.route_group :driver, prefix: "driver", middleware: ["VerifyDriver"], models: [:posts]
        c.route_group :admin, prefix: "admin", middleware: [], models: :all
      end

      expect(Rhino.config.route_groups[:tenant][:middleware]).to eq(["ResolveOrg", "VerifyMembership"])
      expect(Rhino.config.route_groups[:driver][:middleware]).to eq(["VerifyDriver"])
      expect(Rhino.config.route_groups[:admin][:middleware]).to eq([])
    end

    it "wraps single middleware in array" do
      Rhino.reset_configuration!
      Rhino.configure do |c|
        c.model :posts, "Post"
        c.route_group :driver, prefix: "driver", middleware: "VerifyDriver", models: [:posts]
      end

      expect(Rhino.config.route_groups[:driver][:middleware]).to eq(["VerifyDriver"])
    end
  end

  # ------------------------------------------------------------------
  # Backward compatibility
  # ------------------------------------------------------------------

  describe "backward compatibility" do
    it "works with a simple single default group" do
      Rhino.reset_configuration!
      Rhino.configure do |c|
        c.model :posts, "Post"
        c.model :blogs, "Blog"
        c.route_group :default, prefix: "", middleware: [], models: :all
      end

      expect(Rhino.config.route_groups.size).to eq(1)
      expect(Rhino.config.models_for_group(:default)).to contain_exactly(:posts, :blogs)
      expect(Rhino.config.has_tenant_group?).to be false
      expect(Rhino.config.has_public_group?).to be false
    end
  end
end
