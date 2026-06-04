# frozen_string_literal: true

require "spec_helper"

# Hooks classes used across the group-auth config tests.
class CfgDriverHooks < Rhino::AuthHooks; end

RSpec.describe "Configuration: group-aware auth" do
  let(:config) { Rhino::Configuration.new }

  describe "#auth / #enforce_group_membership?" do
    it "defaults enforce_group_membership to false" do
      expect(config.auth[:enforce_group_membership]).to be false
      expect(config.enforce_group_membership?).to be false
    end

    it "can be enabled" do
      config.auth = { enforce_group_membership: true }
      expect(config.enforce_group_membership?).to be true
    end

    it "merges partial auth config over defaults" do
      config.auth = {}
      expect(config.auth[:enforce_group_membership]).to be false
    end

    it "accepts string keys" do
      config.auth = { "enforce_group_membership" => true }
      expect(config.enforce_group_membership?).to be true
    end
  end

  describe "#route_group auth: and hooks:" do
    it "stores auth and hooks keys" do
      config.route_group :driver, prefix: "driver", auth: true, hooks: CfgDriverHooks
      group = config.route_groups[:driver]
      expect(group[:auth]).to be true
      expect(group[:hooks]).to eq(CfgDriverHooks)
    end

    it "defaults auth to false and hooks to nil" do
      config.route_group :driver, prefix: "driver"
      group = config.route_groups[:driver]
      expect(group[:auth]).to be false
      expect(group[:hooks]).to be_nil
    end
  end

  describe "#group_auth_enabled?" do
    it "is true for a group with auth: true" do
      config.route_group :driver, prefix: "driver", auth: true
      expect(config.group_auth_enabled?(:driver)).to be true
    end

    it "is false for a group without auth" do
      config.route_group :driver, prefix: "driver"
      expect(config.group_auth_enabled?(:driver)).to be false
    end

    it "is never true for the public group even if auth: true is set" do
      config.route_group :public, prefix: "public", auth: true
      expect(config.group_auth_enabled?(:public)).to be false
    end
  end

  describe "#auth_enabled_groups" do
    it "returns only auth-enabled non-public groups" do
      config.route_group :tenant, prefix: ":organization", auth: true
      config.route_group :driver, prefix: "driver", auth: true
      config.route_group :admin, prefix: "admin", auth: false
      config.route_group :public, prefix: "public", auth: true

      expect(config.auth_enabled_groups).to contain_exactly(:tenant, :driver)
    end
  end

  describe "#auth_enabled_legacy_groups (§11.1)" do
    it "returns auth-enabled groups with empty prefix AND no domain" do
      config.route_group :default, prefix: "", auth: true
      expect(config.auth_enabled_legacy_groups).to eq([:default])
    end

    it "excludes groups with a prefix" do
      config.route_group :driver, prefix: "driver", auth: true
      expect(config.auth_enabled_legacy_groups).to be_empty
    end

    it "excludes groups with a domain" do
      config.route_group :admin, prefix: "", domain: "admin.example.com", auth: true
      expect(config.auth_enabled_legacy_groups).to be_empty
    end

    it "excludes auth: false groups" do
      config.route_group :default, prefix: "", auth: false
      expect(config.auth_enabled_legacy_groups).to be_empty
    end
  end

  describe "#hooks_for_group" do
    it "instantiates a configured hooks class" do
      config.route_group :driver, prefix: "driver", auth: true, hooks: CfgDriverHooks
      expect(config.hooks_for_group(:driver)).to be_a(CfgDriverHooks)
    end

    it "resolves a hooks class given as a string" do
      config.route_group :driver, prefix: "driver", auth: true, hooks: "CfgDriverHooks"
      expect(config.hooks_for_group(:driver)).to be_a(CfgDriverHooks)
    end

    it "returns nil when no hooks are configured" do
      config.route_group :driver, prefix: "driver", auth: true
      expect(config.hooks_for_group(:driver)).to be_nil
    end

    it "returns nil for an unknown group" do
      expect(config.hooks_for_group(:nope)).to be_nil
    end

    it "returns nil for a nil group" do
      expect(config.hooks_for_group(nil)).to be_nil
    end
  end

  describe "#group_is_tenant?" do
    it "is true only for the :tenant group" do
      expect(config.group_is_tenant?(:tenant)).to be true
      expect(config.group_is_tenant?("tenant")).to be true
      expect(config.group_is_tenant?(:driver)).to be false
      expect(config.group_is_tenant?(nil)).to be false
    end
  end
end
