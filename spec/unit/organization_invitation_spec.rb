# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rhino::OrganizationInvitation do
  let(:org) { Organization.create!(name: "Test Org", slug: "test-org-inv") }
  let(:role) { Role.create!(name: "Member", slug: "member-inv", permissions: []) }
  let(:user) { User.create!(name: "Inviter", email: "inviter@test.com") }

  # ------------------------------------------------------------------
  # Token generation
  # ------------------------------------------------------------------

  describe "token generation" do
    it "auto-generates a 64-character token" do
      invitation = described_class.create!(
        organization: org,
        email: "new@test.com",
        role: role,
        invited_by: user.id
      )

      expect(invitation.token).to be_present
      expect(invitation.token.length).to eq(64)
    end

    it "generates unique tokens" do
      inv1 = described_class.create!(organization: org, email: "a@test.com", role: role, invited_by: user.id)
      inv2 = described_class.create!(organization: org, email: "b@test.com", role: role, invited_by: user.id)

      expect(inv1.token).not_to eq(inv2.token)
    end
  end

  # ------------------------------------------------------------------
  # Expiration
  # ------------------------------------------------------------------

  describe "expiration" do
    it "auto-sets expires_at from config" do
      invitation = described_class.create!(
        organization: org,
        email: "exp@test.com",
        role: role,
        invited_by: user.id
      )

      expect(invitation.expires_at).to be_present
      expect(invitation.expires_at).to be > Time.current
    end

    it "uses configured expires_days" do
      Rhino.config.invitations[:expires_days] = 14

      invitation = described_class.create!(
        organization: org,
        email: "exp14@test.com",
        role: role,
        invited_by: user.id
      )

      expect(invitation.expires_at).to be_within(1.minute).of(14.days.from_now)
    end

    it "detects expired invitations" do
      invitation = described_class.create!(
        organization: org,
        email: "expired@test.com",
        role: role,
        invited_by: user.id
      )
      invitation.update_column(:expires_at, 1.day.ago)

      expect(invitation.expired?).to be true
    end

    it "detects non-expired invitations" do
      invitation = described_class.create!(
        organization: org,
        email: "valid@test.com",
        role: role,
        invited_by: user.id
      )

      expect(invitation.expired?).to be false
      expect(invitation.pending?).to be true
    end
  end

  # ------------------------------------------------------------------
  # Scopes
  # ------------------------------------------------------------------

  describe "scopes" do
    before do
      # Pending
      described_class.create!(organization: org, email: "pending@test.com", role: role, invited_by: user.id)

      # Expired
      inv = described_class.create!(organization: org, email: "expired@test.com", role: role, invited_by: user.id)
      inv.update_column(:expires_at, 1.day.ago)
    end

    it "filters pending invitations" do
      pending = described_class.pending
      expect(pending.count).to eq(1)
      expect(pending.first.email).to eq("pending@test.com")
    end

    it "filters expired invitations" do
      expired = described_class.expired
      expect(expired.count).to eq(1)
      expect(expired.first.email).to eq("expired@test.com")
    end
  end

  # ------------------------------------------------------------------
  # Accept
  # ------------------------------------------------------------------

  describe "#accept!" do
    it "updates status to accepted" do
      invitation = described_class.create!(
        organization: org,
        email: "accept@test.com",
        role: role,
        invited_by: user.id
      )

      accept_user = User.create!(name: "New User", email: "accept@test.com")
      invitation.accept!(accept_user)

      invitation.reload
      expect(invitation.status).to eq("accepted")
      expect(invitation.accepted_at).to be_present
    end
  end

  # ------------------------------------------------------------------
  # Validations
  # ------------------------------------------------------------------

  describe "validations" do
    it "requires email" do
      expect {
        described_class.create!(organization: org, email: nil, role: role, invited_by: user.id)
      }.to raise_error(ActiveRecord::RecordInvalid)
    end

    it "requires unique token" do
      inv1 = described_class.create!(organization: org, email: "unique@test.com", role: role, invited_by: user.id)
      inv2 = described_class.new(organization: org, email: "unique2@test.com", role: role, invited_by: user.id)
      inv2.token = inv1.token

      expect(inv2.valid?).to be false
      expect(inv2.errors[:token]).to be_present
    end
  end

  # ------------------------------------------------------------------
  # Statuses
  # ------------------------------------------------------------------

  describe "statuses" do
    it "defines valid statuses" do
      expect(described_class::STATUSES).to eq(%w[pending accepted expired cancelled])
    end

    it "defaults to pending status" do
      invitation = described_class.create!(
        organization: org,
        email: "default@test.com",
        role: role,
        invited_by: user.id
      )
      expect(invitation.status).to eq("pending")
    end
  end
end
