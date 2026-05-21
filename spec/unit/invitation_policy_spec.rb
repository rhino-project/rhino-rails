# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rhino::InvitationPolicy do
  def create_user(attrs = {})
    User.create!({
      name: "Test User",
      email: "user-#{SecureRandom.uuid}@example.com",
      permissions: ["*"]
    }.merge(attrs))
  end

  def create_organization(attrs = {})
    Organization.create!({ name: "Test Org", slug: "org-#{SecureRandom.uuid}" }.merge(attrs))
  end

  def create_role(attrs = {})
    Role.create!({ name: "Admin", slug: "admin-#{SecureRandom.uuid}", permissions: ["*"] }.merge(attrs))
  end

  def create_user_in_org(org, role, user_attrs = {})
    user = create_user(user_attrs)
    UserRole.create!(user: user, organization: org, role: role)
    user
  end

  def create_invitation(org, role, inviter, attrs = {})
    Rhino::OrganizationInvitation.create!({
      organization: org,
      email: "invitee-#{SecureRandom.uuid}@example.com",
      role: role,
      invited_by: inviter.id,
      token: SecureRandom.hex(32)
    }.merge(attrs))
  end

  # ------------------------------------------------------------------
  # index?
  # ------------------------------------------------------------------

  describe "#index?" do
    it "allows user who belongs to the organization" do
      org = create_organization
      role = create_role
      user = create_user_in_org(org, role)
      invitation = create_invitation(org, role, user)

      policy = described_class.new(user, invitation)
      expect(policy.index?).to be true
    end

    it "denies nil user" do
      org = create_organization
      role = create_role
      user = create_user
      invitation = create_invitation(org, role, user)

      policy = described_class.new(nil, invitation)
      expect(policy.index?).to be false
    end

    it "denies user not in organization" do
      org = create_organization
      other_org = create_organization
      role = create_role
      user = create_user_in_org(other_org, role)
      inviter = create_user
      invitation = create_invitation(org, role, inviter)

      policy = described_class.new(user, invitation)
      expect(policy.index?).to be false
    end
  end

  # ------------------------------------------------------------------
  # create?
  # ------------------------------------------------------------------

  describe "#create?" do
    it "allows user who belongs to organization" do
      org = create_organization
      role = create_role
      user = create_user_in_org(org, role)
      invitation = create_invitation(org, role, user)

      policy = described_class.new(user, invitation)
      expect(policy.create?).to be true
    end

    it "denies nil user" do
      org = create_organization
      role = create_role
      user = create_user
      invitation = create_invitation(org, role, user)

      policy = described_class.new(nil, invitation)
      expect(policy.create?).to be false
    end

    it "checks role_allowed? as part of create authorization" do
      org = create_organization
      role = create_role
      user = create_user_in_org(org, role)
      invitation = create_invitation(org, role, user)

      # When allowed_roles is nil, create? should succeed
      Rhino.config.invitations[:allowed_roles] = nil
      policy = described_class.new(user, invitation)
      expect(policy.create?).to be true
    end

    it "allows when allowed_roles is nil (default)" do
      org = create_organization
      role = create_role
      user = create_user_in_org(org, role)
      invitation = create_invitation(org, role, user)

      policy = described_class.new(user, invitation)
      expect(policy.create?).to be true
    end
  end

  # ------------------------------------------------------------------
  # update?
  # ------------------------------------------------------------------

  describe "#update?" do
    it "allows when user belongs to org and invitation is pending" do
      org = create_organization
      role = create_role
      user = create_user_in_org(org, role)
      invitation = create_invitation(org, role, user)

      policy = described_class.new(user, invitation)
      expect(policy.update?).to be true
    end

    it "denies when invitation is not pending" do
      org = create_organization
      role = create_role
      user = create_user_in_org(org, role)
      invitation = create_invitation(org, role, user)
      invitation.update!(status: "accepted")

      policy = described_class.new(user, invitation)
      expect(policy.update?).to be false
    end

    it "denies when user does not belong to org" do
      org = create_organization
      other_org = create_organization
      role = create_role
      user = create_user_in_org(other_org, role)
      inviter = create_user
      invitation = create_invitation(org, role, inviter)

      policy = described_class.new(user, invitation)
      expect(policy.update?).to be false
    end
  end

  # ------------------------------------------------------------------
  # destroy?
  # ------------------------------------------------------------------

  describe "#destroy?" do
    it "allows when user belongs to org and invitation is pending" do
      org = create_organization
      role = create_role
      user = create_user_in_org(org, role)
      invitation = create_invitation(org, role, user)

      policy = described_class.new(user, invitation)
      expect(policy.destroy?).to be true
    end

    it "denies when invitation is not pending" do
      org = create_organization
      role = create_role
      user = create_user_in_org(org, role)
      invitation = create_invitation(org, role, user)
      invitation.update!(status: "cancelled")

      policy = described_class.new(user, invitation)
      expect(policy.destroy?).to be false
    end

    it "denies nil user" do
      org = create_organization
      role = create_role
      inviter = create_user
      invitation = create_invitation(org, role, inviter)

      policy = described_class.new(nil, invitation)
      expect(policy.destroy?).to be false
    end
  end

  # ------------------------------------------------------------------
  # user_belongs_to_organization? (private)
  # ------------------------------------------------------------------

  describe "#user_belongs_to_organization? (private)" do
    it "returns false when record does not respond to organization_id" do
      user = create_user
      record = double("record")
      allow(record).to receive(:respond_to?).with(:organization_id).and_return(false)

      policy = described_class.new(user, record)
      expect(policy.send(:user_belongs_to_organization?)).to be false
    end

    it "returns true when user does not respond to user_roles" do
      # If user has no user_roles method, policy allows by default
      user = double("user")
      allow(user).to receive(:respond_to?).with(:user_roles).and_return(false)
      allow(user).to receive(:nil?).and_return(false)
      allow(user).to receive(:present?).and_return(true)

      org = create_organization
      role = create_role
      inviter = create_user
      invitation = create_invitation(org, role, inviter)

      policy = described_class.new(user, invitation)
      expect(policy.send(:user_belongs_to_organization?)).to be true
    end
  end

  # ------------------------------------------------------------------
  # role_allowed? (private)
  # ------------------------------------------------------------------

  describe "#role_allowed? (private)" do
    it "returns true when allowed_roles is nil" do
      org = create_organization
      role = create_role
      user = create_user_in_org(org, role)
      invitation = create_invitation(org, role, user)

      Rhino.config.invitations[:allowed_roles] = nil

      policy = described_class.new(user, invitation)
      expect(policy.send(:role_allowed?)).to be true
    end

    it "allows when user role slug matches allowed_roles" do
      org = create_organization
      role = create_role(slug: "admin")
      user = create_user_in_org(org, role)
      invitation = create_invitation(org, role, user)

      Rhino.config.invitations[:allowed_roles] = ["admin"]

      policy = described_class.new(user, invitation)
      expect(policy.send(:role_allowed?)).to be true

      Rhino.config.invitations[:allowed_roles] = nil
    end

    it "denies when user role slug does not match allowed_roles" do
      org = create_organization
      role = create_role(slug: "viewer")
      user = create_user_in_org(org, role)
      invitation = create_invitation(org, role, user)

      Rhino.config.invitations[:allowed_roles] = ["admin"]

      policy = described_class.new(user, invitation)
      expect(policy.send(:role_allowed?)).to be false

      Rhino.config.invitations[:allowed_roles] = nil
    end
  end
end
