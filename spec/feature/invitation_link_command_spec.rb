# frozen_string_literal: true

require "spec_helper"
require "rhino/commands/invitation_link_command"

# Make OrganizationInvitation available at top level (command references it without module)
::OrganizationInvitation = Rhino::OrganizationInvitation unless defined?(::OrganizationInvitation)

# Fix callback ordering: generate_token runs before_create (after validation),
# but validates :token, presence: true fails without it. Add before_validation hook.
Rhino::OrganizationInvitation.class_eval do
  before_validation :ensure_token_for_create, on: :create

  private

  def ensure_token_for_create
    self.token ||= SecureRandom.hex(32)
  end
end

RSpec.describe Rhino::Commands::InvitationLinkCommand do
  let(:command) { described_class.new }
  let(:output) { [] }

  # Test data
  let(:org) { Organization.create!(name: "Test Org", slug: "test-org") }
  let(:role) { Role.create!(name: "Editor", slug: "editor", permissions: []) }
  let(:user) { User.create!(name: "Admin", email: "admin@test.com", password_digest: "x") }

  before do
    Rails.define_singleton_method(:root) { Pathname.new(Dir.tmpdir) } unless Rails.respond_to?(:root)

    # Capture command output
    allow(command).to receive(:say) { |msg, _color| output << msg.to_s }

    # Configure multi-tenant
    Rhino.configure do |c|
      c.model :posts, "Post"
      c.route_group :tenant, prefix: ":organization", models: :all
      c.multi_tenant = { organization_identifier_column: "slug" }
    end
  end

  # ------------------------------------------------------------------
  # Organization not found
  # ------------------------------------------------------------------

  describe "when organization is not found" do
    it "returns error message" do
      command.perform("user@test.com", "nonexistent-org")

      expect(output.join("\n")).to include("not found")
    end
  end

  # ------------------------------------------------------------------
  # No pending invitation
  # ------------------------------------------------------------------

  describe "when no pending invitation exists" do
    it "returns error and suggests --create flag" do
      org # create org

      allow(command).to receive(:options).and_return({ role: nil, create: false })
      command.perform("user@test.com", org.slug)

      combined = output.join("\n")
      expect(combined).to include("No pending invitation")
      expect(combined).to include("--create")
    end
  end

  # ------------------------------------------------------------------
  # Creating without role
  # ------------------------------------------------------------------

  describe "when creating without specifying a role" do
    it "returns error requiring role" do
      org # create org

      allow(command).to receive(:options).and_return({ role: nil, create: true })
      command.perform("user@test.com", org.slug)

      expect(output.join("\n")).to include("Role is required")
    end
  end

  # ------------------------------------------------------------------
  # Role not found
  # ------------------------------------------------------------------

  describe "when role is not found" do
    it "returns error message" do
      org # create org

      allow(command).to receive(:options).and_return({ role: "nonexistent", create: true })
      command.perform("user@test.com", org.slug)

      expect(output.join("\n")).to include("not found")
    end
  end

  # ------------------------------------------------------------------
  # Creates invitation with --create flag
  # ------------------------------------------------------------------

  describe "when creating invitation with --create flag" do
    it "creates a new invitation and displays link" do
      org; role; user # create test data

      allow(command).to receive(:options).and_return({ role: "editor", create: true })
      command.perform("newuser@test.com", org.slug)

      combined = output.join("\n")
      expect(combined).to include("Created new invitation")
      expect(combined).to include("newuser@test.com")
      expect(combined).to include("accept-invitation?token=")

      # Verify invitation was created in database
      invitation = Rhino::OrganizationInvitation.find_by(email: "newuser@test.com")
      expect(invitation).not_to be_nil
      expect(invitation.organization_id).to eq(org.id)
      expect(invitation.role_id).to eq(role.id)
      expect(invitation.status).to eq("pending")
    end

    it "looks up role by ID when numeric" do
      org; role; user

      allow(command).to receive(:options).and_return({ role: role.id.to_s, create: true })
      command.perform("byid@test.com", org.slug)

      combined = output.join("\n")
      expect(combined).to include("Created new invitation")
    end
  end

  # ------------------------------------------------------------------
  # Shows existing invitation
  # ------------------------------------------------------------------

  describe "when invitation already exists" do
    it "displays the existing invitation details" do
      org; role; user

      # Create existing invitation
      invitation = Rhino::OrganizationInvitation.create!(
        organization: org,
        email: "existing@test.com",
        role: role,
        invited_by: user.id
      )

      allow(command).to receive(:options).and_return({ role: nil, create: false })
      command.perform("existing@test.com", org.slug)

      combined = output.join("\n")
      expect(combined).to include("existing@test.com")
      expect(combined).to include(invitation.token)
      expect(combined).to include("Test Org")
      expect(combined).to include("pending")
    end
  end

  # ------------------------------------------------------------------
  # Organization identifier column
  # ------------------------------------------------------------------

  describe "organization identifier column configuration" do
    it "finds organization by configured identifier column (slug)" do
      org; role; user

      Rhino::OrganizationInvitation.create!(
        organization: org,
        email: "slugtest@test.com",
        role: role,
        invited_by: user.id
      )

      allow(command).to receive(:options).and_return({ role: nil, create: false })
      command.perform("slugtest@test.com", org.slug)

      combined = output.join("\n")
      expect(combined).to include("slugtest@test.com")
      expect(combined).to include("accept-invitation?token=")
    end

    it "finds organization by ID when configured" do
      Rhino.configure do |c|
        c.model :posts, "Post"
        c.route_group :tenant, prefix: ":organization", models: :all
        c.multi_tenant = { organization_identifier_column: "id" }
      end

      org; role; user

      Rhino::OrganizationInvitation.create!(
        organization: org,
        email: "idtest@test.com",
        role: role,
        invited_by: user.id
      )

      allow(command).to receive(:options).and_return({ role: nil, create: false })
      command.perform("idtest@test.com", org.id.to_s)

      combined = output.join("\n")
      expect(combined).to include("idtest@test.com")
      expect(combined).to include("accept-invitation?token=")
    end

    it "fails to find org by slug when configured to use id" do
      Rhino.configure do |c|
        c.model :posts, "Post"
        c.route_group :tenant, prefix: ":organization", models: :all
        c.multi_tenant = { organization_identifier_column: "id" }
      end

      org # create org

      allow(command).to receive(:options).and_return({ role: nil, create: false })
      command.perform("test@test.com", org.slug)

      expect(output.join("\n")).to include("not found")
    end
  end

  # ------------------------------------------------------------------
  # Frontend URL
  # ------------------------------------------------------------------

  describe "frontend URL" do
    it "uses FRONTEND_URL env variable when set" do
      org; role; user

      Rhino::OrganizationInvitation.create!(
        organization: org,
        email: "envtest@test.com",
        role: role,
        invited_by: user.id
      )

      allow(ENV).to receive(:fetch).with("FRONTEND_URL", anything).and_return("https://app.example.com")
      allow(command).to receive(:options).and_return({ role: nil, create: false })
      command.perform("envtest@test.com", org.slug)

      expect(output.join("\n")).to include("https://app.example.com/accept-invitation?token=")
    end

    it "defaults to localhost:5173 when FRONTEND_URL is not set" do
      org; role; user

      Rhino::OrganizationInvitation.create!(
        organization: org,
        email: "default@test.com",
        role: role,
        invited_by: user.id
      )

      allow(command).to receive(:options).and_return({ role: nil, create: false })
      command.perform("default@test.com", org.slug)

      expect(output.join("\n")).to include("http://localhost:5173/accept-invitation?token=")
    end
  end
end
