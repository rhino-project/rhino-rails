# frozen_string_literal: true

require "spec_helper"

# A test model that uses BelongsToOrganization
class OrgPost < ActiveRecord::Base
  self.table_name = "posts"

  include Rhino::BelongsToOrganization
end

RSpec.describe Rhino::BelongsToOrganization do
  def create_organization(attrs = {})
    Organization.create!({ name: "Test Org", slug: "test-org-#{SecureRandom.uuid}" }.merge(attrs))
  end

  describe "included behavior" do
    it "adds belongs_to :organization association" do
      assoc = OrgPost.reflect_on_association(:organization)
      expect(assoc).to be_present
      expect(assoc.macro).to eq(:belongs_to)
    end

    it "registers a before_create callback" do
      callbacks = OrgPost._create_callbacks.map(&:filter)
      expect(callbacks).to include(:set_organization_from_context)
    end

    it "applies default scope when RequestStore has rhino_organization" do
      org = create_organization
      other_org = create_organization

      Post.create!(title: "Org1 Post", organization_id: org.id)
      Post.create!(title: "Org2 Post", organization_id: other_org.id)

      # Simulate RequestStore
      if defined?(RequestStore)
        RequestStore.store[:rhino_organization] = org
        begin
          scoped = OrgPost.all
          # The default scope should filter by org — check the generated SQL
          expect(scoped.to_sql).to include("organization_id")
        ensure
          RequestStore.store.delete(:rhino_organization)
        end
      end
    end

    it "returns all records when no RequestStore organization" do
      org = create_organization
      Post.create!(title: "Post 1", organization_id: org.id)
      Post.create!(title: "Post 2", organization_id: org.id)

      # Without RequestStore, default scope should return all
      expect(OrgPost.all.count).to be >= 2
    end
  end

  describe ".for_organization" do
    it "returns records for specific organization using unscoped" do
      org1 = create_organization
      org2 = create_organization

      Post.create!(title: "Org1 Post", organization_id: org1.id)
      Post.create!(title: "Org2 Post", organization_id: org2.id)

      results = OrgPost.for_organization(org1)
      expect(results.map(&:title)).to include("Org1 Post")
      expect(results.map(&:title)).not_to include("Org2 Post")
    end
  end

  describe "#set_organization_from_context" do
    it "does not override existing organization_id" do
      org1 = create_organization
      org2 = create_organization

      post = OrgPost.new(title: "Test", organization_id: org1.id)
      post.send(:set_organization_from_context)

      expect(post.organization_id).to eq(org1.id)
    end

    it "does nothing when RequestStore has no organization" do
      # Ensure RequestStore has no org set
      if defined?(RequestStore)
        RequestStore.store[:rhino_organization] = nil
      end

      post = OrgPost.new(title: "Test")
      post.send(:set_organization_from_context)
      expect(post.organization_id).to be_nil
    end
  end
end
