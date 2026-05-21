# frozen_string_literal: true

require "spec_helper"
require "request_store"

RSpec.describe Rhino::ResourceScope do
  let(:scope) { described_class.new }

  after do
    RequestStore.store[:rhino_current_user] = nil
    RequestStore.store[:rhino_organization] = nil
  end

  describe "#user" do
    it "returns the current user from RequestStore" do
      user = double("User")
      RequestStore.store[:rhino_current_user] = user

      expect(scope.user).to eq(user)
    end

    it "returns nil when no user is stored" do
      RequestStore.store[:rhino_current_user] = nil

      expect(scope.user).to be_nil
    end
  end

  describe "#organization" do
    it "returns the current organization from RequestStore" do
      org = double("Organization")
      RequestStore.store[:rhino_organization] = org

      expect(scope.organization).to eq(org)
    end

    it "returns nil when no organization is stored" do
      RequestStore.store[:rhino_organization] = nil

      expect(scope.organization).to be_nil
    end
  end

  describe "#role" do
    it "returns the user's role slug for the current organization" do
      org = double("Organization")
      user = double("User")
      allow(user).to receive(:respond_to?).with(:role_slug_for_validation).and_return(true)
      allow(user).to receive(:role_slug_for_validation).with(org).and_return("admin")

      RequestStore.store[:rhino_current_user] = user
      RequestStore.store[:rhino_organization] = org

      expect(scope.role).to eq("admin")
    end

    it "returns nil when no user is present" do
      RequestStore.store[:rhino_current_user] = nil
      RequestStore.store[:rhino_organization] = double("Organization")

      expect(scope.role).to be_nil
    end

    it "returns nil when no organization is present" do
      RequestStore.store[:rhino_current_user] = double("User")
      RequestStore.store[:rhino_organization] = nil

      expect(scope.role).to be_nil
    end

    it "returns nil when user does not respond to role_slug_for_validation" do
      user = double("User")
      allow(user).to receive(:respond_to?).with(:role_slug_for_validation).and_return(false)

      RequestStore.store[:rhino_current_user] = user
      RequestStore.store[:rhino_organization] = double("Organization")

      expect(scope.role).to be_nil
    end
  end

  describe "#apply" do
    it "raises NotImplementedError for the base class" do
      relation = double("Relation")
      expect { scope.apply(relation) }.to raise_error(NotImplementedError)
    end
  end

  describe "subclass" do
    let(:subclass) do
      Class.new(described_class) do
        def apply(relation)
          if role == "viewer"
            relation.where(visible: true)
          else
            relation
          end
        end
      end
    end

    it "can access user, organization, and role" do
      org = double("Organization")
      user = double("User")
      allow(user).to receive(:respond_to?).with(:role_slug_for_validation).and_return(true)
      allow(user).to receive(:role_slug_for_validation).with(org).and_return("viewer")

      RequestStore.store[:rhino_current_user] = user
      RequestStore.store[:rhino_organization] = org

      relation = double("Relation")
      filtered_relation = double("FilteredRelation")
      allow(relation).to receive(:where).with(visible: true).and_return(filtered_relation)

      instance = subclass.new
      expect(instance.apply(relation)).to eq(filtered_relation)
    end

    it "returns unfiltered relation for non-viewer roles" do
      org = double("Organization")
      user = double("User")
      allow(user).to receive(:respond_to?).with(:role_slug_for_validation).and_return(true)
      allow(user).to receive(:role_slug_for_validation).with(org).and_return("admin")

      RequestStore.store[:rhino_current_user] = user
      RequestStore.store[:rhino_organization] = org

      relation = double("Relation")

      instance = subclass.new
      expect(instance.apply(relation)).to eq(relation)
    end
  end
end
