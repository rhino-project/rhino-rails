# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rhino::Configuration do
  subject(:config) { described_class.new }

  describe "#initialize" do
    it "sets default values" do
      expect(config.models).to eq({})
      expect(config.route_groups).to eq({})
      expect(config.multi_tenant[:organization_identifier_column]).to eq("id")
      expect(config.invitations[:expires_days]).to eq(7)
      expect(config.nested[:max_operations]).to eq(50)
      expect(config.test_framework).to eq("rspec")
      expect(config.route_key).to be_nil
    end
  end

  describe "#route_key" do
    it "defaults to nil" do
      expect(config.route_key).to be_nil
    end

    it "is settable" do
      config.route_key = "hash_id"
      expect(config.route_key).to eq("hash_id")
    end

    it "is cleared by Rhino.reset_configuration!" do
      Rhino.config.route_key = "hash_id"
      Rhino.reset_configuration!
      expect(Rhino.config.route_key).to be_nil
    end
  end

  describe "#model" do
    it "registers a model with its slug" do
      config.model :posts, "Post"
      expect(config.models[:posts]).to eq("Post")
    end

    it "converts slug to symbol" do
      config.model "posts", "Post"
      expect(config.models[:posts]).to eq("Post")
    end
  end

  describe "#route_group" do
    it "registers a route group with configuration" do
      config.route_group :tenant, prefix: ":organization", middleware: ["SomeMiddleware"], models: :all
      expect(config.route_groups[:tenant]).to eq({
        prefix: ":organization",
        domain: nil,
        middleware: ["SomeMiddleware"],
        models: :all,
        auth: false,
        hooks: nil,
        tenant: true
      })
    end

    it "defaults to empty prefix, no middleware, and all models" do
      config.route_group :default
      expect(config.route_groups[:default]).to eq({
        prefix: "",
        domain: nil,
        middleware: [],
        models: :all,
        auth: false,
        hooks: nil,
        tenant: true
      })
    end

    it "accepts array of model slugs" do
      config.route_group :driver, prefix: "driver", models: [:trips, :trucks]
      expect(config.route_groups[:driver][:models]).to eq([:trips, :trucks])
    end
  end

  describe "#public_model?" do
    it "returns true for models in public route group" do
      config.model :posts, "Post"
      config.route_group :public, prefix: "public", models: [:posts]
      expect(config.public_model?(:posts)).to be true
    end

    it "returns false when no public route group exists" do
      config.model :posts, "Post"
      expect(config.public_model?(:posts)).to be false
    end

    it "converts string slugs to symbols" do
      config.model :posts, "Post"
      config.route_group :public, prefix: "public", models: [:posts]
      expect(config.public_model?("posts")).to be true
    end
  end

  describe "#resolve_model" do
    before { config.model :posts, "Post" }

    it "resolves a model class from its slug" do
      expect(config.resolve_model(:posts)).to eq(Post)
    end

    it "raises RecordNotFound for unknown slugs" do
      expect { config.resolve_model(:unknown) }.to raise_error(ActiveRecord::RecordNotFound)
    end

    it "raises RecordNotFound for invalid class names" do
      config.model :invalid, "NonExistentModel"
      expect { config.resolve_model(:invalid) }.to raise_error(ActiveRecord::RecordNotFound)
    end
  end

  describe "#slug_for" do
    before do
      config.model :posts, "Post"
      config.model :blogs, "Blog"
    end

    it "returns the slug for a model class" do
      expect(config.slug_for(Post)).to eq(:posts)
    end

    it "returns the slug for a model instance" do
      expect(config.slug_for(Post.new)).to eq(:posts)
    end

    it "returns nil for unregistered models" do
      expect(config.slug_for(Comment)).to be_nil
    end
  end

  describe "#has_tenant_group?" do
    it "returns false by default" do
      expect(config.has_tenant_group?).to be false
    end

    it "returns true when tenant group is configured" do
      config.route_group :tenant, prefix: ":organization"
      expect(config.has_tenant_group?).to be true
    end
  end

  describe "#has_public_group?" do
    it "returns false by default" do
      expect(config.has_public_group?).to be false
    end

    it "returns true when public group is configured" do
      config.route_group :public, prefix: "public"
      expect(config.has_public_group?).to be true
    end
  end

  describe "#models_for_group" do
    before do
      config.model :posts, "Post"
      config.model :blogs, "Blog"
    end

    it "returns all models for :all wildcard" do
      config.route_group :default, models: :all
      expect(config.models_for_group(:default)).to contain_exactly(:posts, :blogs)
    end

    it "returns all models for '*' wildcard" do
      config.route_group :default, models: "*"
      expect(config.models_for_group(:default)).to contain_exactly(:posts, :blogs)
    end

    it "returns only specified models" do
      config.route_group :driver, models: [:posts]
      expect(config.models_for_group(:driver)).to eq([:posts])
    end

    it "filters out unregistered model slugs" do
      config.route_group :driver, models: [:posts, :nonexistent]
      expect(config.models_for_group(:driver)).to eq([:posts])
    end

    it "returns empty array for unknown group" do
      expect(config.models_for_group(:unknown)).to eq([])
    end
  end

  describe "#model_in_group?" do
    before do
      config.model :posts, "Post"
      config.model :blogs, "Blog"
      config.route_group :driver, models: [:posts]
    end

    it "returns true when model is in the group" do
      expect(config.model_in_group?(:posts, :driver)).to be true
    end

    it "returns false when model is not in the group" do
      expect(config.model_in_group?(:blogs, :driver)).to be false
    end
  end
end
