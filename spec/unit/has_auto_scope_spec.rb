# frozen_string_literal: true

require "spec_helper"
require "request_store"

# Define scope classes before models reference them

# Legacy class-method scope (Scopes:: convention)
module Scopes
  class ScopedArticleScope
    def self.apply(relation)
      relation.where(status: "published")
    end
  end
end

# Legacy class-method scope (ModelScopes:: convention)
module ModelScopes
  class ScopedPostScope
    def self.apply(relation)
      relation.where(status: "published")
    end
  end
end

# ResourceScope subclass with user-aware filtering
module Scopes
  class ScopedProjectScope < Rhino::ResourceScope
    def apply(relation)
      if role == "viewer"
        relation.where(status: "active")
      else
        relation
      end
    end
  end
end

RSpec.describe Rhino::HasAutoScope do
  before(:all) do
    ActiveRecord::Schema.define do
      create_table :scoped_posts, force: true do |t|
        t.string :title
        t.string :status
        t.timestamps
      end

      create_table :scoped_articles, force: true do |t|
        t.string :title
        t.string :status
        t.timestamps
      end

      create_table :scoped_projects, force: true do |t|
        t.string :name
        t.string :status
        t.timestamps
      end

      create_table :unscoped_items, force: true do |t|
        t.string :name
        t.timestamps
      end
    end
  end

  let!(:scoped_post_class) do
    Class.new(ActiveRecord::Base) do
      self.table_name = "scoped_posts"
      def self.name; "ScopedPost"; end

      include Rhino::HasAutoScope
    end
  end

  let!(:scoped_article_class) do
    Class.new(ActiveRecord::Base) do
      self.table_name = "scoped_articles"
      def self.name; "ScopedArticle"; end

      include Rhino::HasAutoScope
    end
  end

  let!(:scoped_project_class) do
    Class.new(ActiveRecord::Base) do
      self.table_name = "scoped_projects"
      def self.name; "ScopedProject"; end

      include Rhino::HasAutoScope
    end
  end

  let!(:unscoped_item_class) do
    Class.new(ActiveRecord::Base) do
      self.table_name = "unscoped_items"
      def self.name; "UnscopedItem"; end

      include Rhino::HasAutoScope
    end
  end

  describe ".rhino_auto_scope_class" do
    it "finds scope class via Scopes:: convention" do
      expect(scoped_article_class.rhino_auto_scope_class).to eq(Scopes::ScopedArticleScope)
    end

    it "finds scope class via ModelScopes:: convention (fallback)" do
      expect(scoped_post_class.rhino_auto_scope_class).to eq(ModelScopes::ScopedPostScope)
    end

    it "finds ResourceScope subclass via Scopes:: convention" do
      expect(scoped_project_class.rhino_auto_scope_class).to eq(Scopes::ScopedProjectScope)
    end

    it "returns nil when no scope class exists" do
      expect(unscoped_item_class.rhino_auto_scope_class).to be_nil
    end
  end

  describe "default_scope" do
    it "applies scope when scope class exists (Scopes:: convention)" do
      scoped_article_class.create!(title: "Draft Article", status: "draft")
      scoped_article_class.create!(title: "Published Article", status: "published")

      results = scoped_article_class.all.to_a
      expect(results.size).to eq(1)
      expect(results.first.title).to eq("Published Article")
    end

    it "applies scope when scope class exists (ModelScopes:: convention)" do
      scoped_post_class.create!(title: "Draft Post", status: "draft")
      scoped_post_class.create!(title: "Published Post", status: "published")

      results = scoped_post_class.all.to_a
      expect(results.size).to eq(1)
      expect(results.first.title).to eq("Published Post")
    end

    it "returns all records when no scope class exists" do
      unscoped_item_class.create!(name: "Item A")
      unscoped_item_class.create!(name: "Item B")

      results = unscoped_item_class.all.to_a
      expect(results.size).to eq(2)
    end

    it "can be bypassed with unscoped" do
      scoped_post_class.create!(title: "Draft", status: "draft")
      scoped_post_class.create!(title: "Published", status: "published")

      results = scoped_post_class.unscoped.to_a
      expect(results.size).to eq(2)
    end
  end

  describe "ResourceScope integration" do
    let(:mock_org) { Struct.new(:id).new(1) }
    let(:mock_user) do
      user = Struct.new(:role_slug) do
        def respond_to?(method, *args)
          return true if method == :role_slug_for_validation
          super
        end

        def role_slug_for_validation(_org)
          role_slug
        end
      end.new(role_slug)
      user
    end

    before do
      scoped_project_class.create!(name: "Active Project", status: "active")
      scoped_project_class.create!(name: "Archived Project", status: "archived")
    end

    after do
      RequestStore.store[:rhino_current_user] = nil
      RequestStore.store[:rhino_organization] = nil
    end

    context "when user is a viewer" do
      let(:role_slug) { "viewer" }

      it "applies role-based filtering" do
        RequestStore.store[:rhino_current_user] = mock_user
        RequestStore.store[:rhino_organization] = mock_org

        results = scoped_project_class.all.to_a
        expect(results.size).to eq(1)
        expect(results.first.name).to eq("Active Project")
      end
    end

    context "when user is an admin" do
      let(:role_slug) { "admin" }

      it "returns all records for non-viewer roles" do
        RequestStore.store[:rhino_current_user] = mock_user
        RequestStore.store[:rhino_organization] = mock_org

        results = scoped_project_class.all.to_a
        expect(results.size).to eq(2)
      end
    end

    context "when no user is present" do
      it "returns all records" do
        RequestStore.store[:rhino_current_user] = nil
        RequestStore.store[:rhino_organization] = nil

        results = scoped_project_class.all.to_a
        expect(results.size).to eq(2)
      end
    end
  end
end
