# frozen_string_literal: true

require "spec_helper"
require "rhino/controllers/invitations_controller"
require "ostruct"

# Ensure token is generated before validation for tests
unless Rhino::OrganizationInvitation.instance_methods.include?(:ensure_token_for_inv_ctrl_test)
  Rhino::OrganizationInvitation.class_eval do
    before_validation :ensure_token_for_inv_ctrl_test, on: :create

    private

    def ensure_token_for_inv_ctrl_test
      self.token ||= SecureRandom.hex(32)
    end
  end
end

RSpec.describe Rhino::InvitationsController do
  # ------------------------------------------------------------------
  # Helpers
  # ------------------------------------------------------------------

  def call_action(action, params: {}, headers: {}, env_overrides: {}, skip_auth: false)
    controller = Rhino::InvitationsController.new

    # Stub policy authorization for tests that focus on controller logic
    if skip_auth
      allow(controller).to receive(:authorize).and_return(true)
    end

    method = case action.to_s
             when "index" then "GET"
             when "create", "resend", "accept" then "POST"
             when "cancel" then "DELETE"
             else "GET"
             end

    env = Rack::MockRequest.env_for("/api/invitations", method: method)
    env["action_dispatch.request.request_parameters"] = params.stringify_keys
    env["action_dispatch.request.path_parameters"] = {
      controller: "rhino/invitations",
      action: action.to_s
    }.merge(params.slice(:id).transform_keys(&:to_s).transform_keys(&:to_sym))

    headers.each do |key, value|
      env["HTTP_#{key.upcase.tr('-', '_')}"] = value
    end

    env_overrides.each { |k, v| env[k] = v }

    request = ActionDispatch::Request.new(env)
    response = ActionDispatch::Response.new

    begin
      controller.dispatch(action.to_sym, request, response)
    rescue Pundit::NotAuthorizedError
      response.status = 403
      response.body = { message: "This action is unauthorized." }.to_json
      response.content_type = "application/json"
    end

    body = begin
      JSON.parse(response.body)
    rescue JSON::ParserError
      {}
    end

    OpenStruct.new(status: response.status, body: body, headers: response.headers)
  end

  def auth_headers(user)
    { "Authorization" => "Bearer #{user.api_token}" }
  end

  def create_user(attrs = {})
    User.create!({
      name: "Test User",
      email: "user-#{SecureRandom.uuid}@example.com",
      permissions: ["*"],
      api_token: SecureRandom.hex(20)
    }.merge(attrs))
  end

  def create_organization(attrs = {})
    Organization.create!({ name: "Test Org", slug: "test-org-#{SecureRandom.uuid}" }.merge(attrs))
  end

  def create_role(attrs = {})
    Role.create!({ name: "Editor", slug: "editor-#{SecureRandom.uuid}", permissions: ["*"] }.merge(attrs))
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
      invited_by: inviter.id
    }.merge(attrs))
  end

  # ==================================================================
  # Authentication
  # ==================================================================

  describe "authentication" do
    it "returns 401 when no token is provided for index" do
      response = call_action(:index)
      expect(response.status).to eq(401)
      expect(response.body["message"]).to eq("Unauthenticated.")
    end

    it "returns 401 when no token is provided for create" do
      response = call_action(:create)
      expect(response.status).to eq(401)
    end

    it "does not require authentication for accept" do
      response = call_action(:accept, params: { token: "" })
      # Will be 422 for missing token, not 401
      expect(response.status).to eq(422)
    end
  end

  # ==================================================================
  # INDEX
  # ==================================================================

  describe "GET index" do
    it "returns invitations for the organization" do
      org = create_organization
      role = create_role
      user = create_user_in_org(org, role)
      create_invitation(org, role, user, email: "a@test.com")
      create_invitation(org, role, user, email: "b@test.com")

      response = call_action(:index,
        headers: auth_headers(user),
        env_overrides: { "rhino.organization" => org },
        skip_auth: true)

      expect(response.status).to eq(200)
      expect(response.body.length).to eq(2)
    end

    it "filters by pending status" do
      org = create_organization
      role = create_role
      user = create_user_in_org(org, role)
      create_invitation(org, role, user, email: "pending@test.com")
      create_invitation(org, role, user,
        email: "expired@test.com",
        expires_at: 1.day.ago)

      response = call_action(:index,
        params: { status: "pending" },
        headers: auth_headers(user),
        env_overrides: { "rhino.organization" => org },
        skip_auth: true)

      expect(response.status).to eq(200)
      emails = response.body.map { |i| i["email"] }
      expect(emails).to include("pending@test.com")
      expect(emails).not_to include("expired@test.com")
    end

    it "filters by expired status" do
      org = create_organization
      role = create_role
      user = create_user_in_org(org, role)
      create_invitation(org, role, user, email: "pending@test.com")
      create_invitation(org, role, user,
        email: "expired@test.com",
        expires_at: 1.day.ago)

      response = call_action(:index,
        params: { status: "expired" },
        headers: auth_headers(user),
        env_overrides: { "rhino.organization" => org },
        skip_auth: true)

      expect(response.status).to eq(200)
      emails = response.body.map { |i| i["email"] }
      expect(emails).to include("expired@test.com")
      expect(emails).not_to include("pending@test.com")
    end

    it "returns all invitations with status=all" do
      org = create_organization
      role = create_role
      user = create_user_in_org(org, role)
      create_invitation(org, role, user, email: "a@test.com")
      create_invitation(org, role, user, email: "b@test.com", expires_at: 1.day.ago)

      response = call_action(:index,
        params: { status: "all" },
        headers: auth_headers(user),
        env_overrides: { "rhino.organization" => org },
        skip_auth: true)

      expect(response.status).to eq(200)
      expect(response.body.length).to eq(2)
    end
  end

  # ==================================================================
  # CREATE
  # ==================================================================

  describe "POST create" do
    it "creates a new invitation" do
      org = create_organization
      role = create_role
      user = create_user_in_org(org, role)

      response = call_action(:create,
        params: { email: "newinvitee@test.com", role_id: role.id },
        headers: auth_headers(user),
        env_overrides: { "rhino.organization" => org },
        skip_auth: true)

      expect(response.status).to eq(201)
      expect(response.body["email"]).to eq("newinvitee@test.com")
    end

    it "returns 422 when email is blank" do
      org = create_organization
      role = create_role
      user = create_user_in_org(org, role)

      response = call_action(:create,
        params: { email: "", role_id: role.id },
        headers: auth_headers(user),
        env_overrides: { "rhino.organization" => org },
        skip_auth: true)

      expect(response.status).to eq(422)
      expect(response.body["errors"]["email"]).to be_present
    end

    it "returns 422 when role_id is blank" do
      org = create_organization
      role = create_role
      user = create_user_in_org(org, role)

      response = call_action(:create,
        params: { email: "test@test.com", role_id: "" },
        headers: auth_headers(user),
        env_overrides: { "rhino.organization" => org },
        skip_auth: true)

      expect(response.status).to eq(422)
      expect(response.body["errors"]["role_id"]).to be_present
    end

    it "returns 422 when user is already a member" do
      org = create_organization
      role = create_role
      user = create_user_in_org(org, role)
      create_user_in_org(org, role, email: "member@test.com")

      response = call_action(:create,
        params: { email: "member@test.com", role_id: role.id },
        headers: auth_headers(user),
        env_overrides: { "rhino.organization" => org },
        skip_auth: true)

      expect(response.status).to eq(422)
      expect(response.body["message"]).to include("already a member")
    end

    it "returns 422 when pending invitation exists for email" do
      org = create_organization
      role = create_role
      user = create_user_in_org(org, role)
      create_invitation(org, role, user, email: "duplicate@test.com")

      response = call_action(:create,
        params: { email: "duplicate@test.com", role_id: role.id },
        headers: auth_headers(user),
        env_overrides: { "rhino.organization" => org },
        skip_auth: true)

      expect(response.status).to eq(422)
      expect(response.body["message"]).to include("pending invitation")
    end
  end

  # ==================================================================
  # RESEND
  # ==================================================================

  describe "POST resend" do
    it "resends a pending invitation" do
      org = create_organization
      role = create_role
      user = create_user_in_org(org, role)
      invitation = create_invitation(org, role, user)

      response = call_action(:resend,
        params: { id: invitation.id },
        headers: auth_headers(user),
        env_overrides: { "rhino.organization" => org },
        skip_auth: true)

      expect(response.status).to eq(200)
      expect(response.body["message"]).to include("resent")
    end

    it "returns 422 when invitation is not pending" do
      org = create_organization
      role = create_role
      user = create_user_in_org(org, role)
      invitation = create_invitation(org, role, user)
      invitation.update!(status: "cancelled")

      response = call_action(:resend,
        params: { id: invitation.id },
        headers: auth_headers(user),
        env_overrides: { "rhino.organization" => org },
        skip_auth: true)

      expect(response.status).to eq(422)
      expect(response.body["message"]).to include("pending")
    end
  end

  # ==================================================================
  # CANCEL
  # ==================================================================

  describe "DELETE cancel" do
    it "cancels a pending invitation" do
      org = create_organization
      role = create_role
      user = create_user_in_org(org, role)
      invitation = create_invitation(org, role, user)

      response = call_action(:cancel,
        params: { id: invitation.id },
        headers: auth_headers(user),
        env_overrides: { "rhino.organization" => org },
        skip_auth: true)

      expect(response.status).to eq(200)
      expect(response.body["message"]).to include("cancelled")
      expect(invitation.reload.status).to eq("cancelled")
    end

    it "returns 422 when invitation is not pending" do
      org = create_organization
      role = create_role
      user = create_user_in_org(org, role)
      invitation = create_invitation(org, role, user)
      invitation.update!(status: "accepted")

      response = call_action(:cancel,
        params: { id: invitation.id },
        headers: auth_headers(user),
        env_overrides: { "rhino.organization" => org },
        skip_auth: true)

      expect(response.status).to eq(422)
      expect(response.body["message"]).to include("pending")
    end
  end

  # ==================================================================
  # ACCEPT
  # ==================================================================

  describe "POST accept" do
    it "returns 422 when token is blank" do
      response = call_action(:accept, params: { token: "" })

      expect(response.status).to eq(422)
      expect(response.body["errors"]["token"]).to be_present
    end

    it "returns 404 when token is invalid" do
      response = call_action(:accept, params: { token: "nonexistent" })

      expect(response.status).to eq(404)
      expect(response.body["message"]).to include("Invalid")
    end

    it "returns requires_registration when no user is authenticated" do
      org = create_organization
      role = create_role
      inviter = create_user
      invitation = create_invitation(org, role, inviter)

      response = call_action(:accept, params: { token: invitation.token })

      expect(response.status).to eq(200)
      expect(response.body["requires_registration"]).to be true
    end

    it "accepts invitation for authenticated user" do
      org = create_organization
      role = create_role
      inviter = create_user
      invitation = create_invitation(org, role, inviter)
      accepter = create_user(email: "accepter-#{SecureRandom.uuid}@test.com")

      response = call_action(:accept,
        params: { token: invitation.token },
        headers: auth_headers(accepter))

      expect(response.status).to eq(200)
      expect(response.body["message"]).to include("accepted")
      expect(invitation.reload.status).to eq("accepted")
    end

    it "returns 422 when invitation is expired" do
      org = create_organization
      role = create_role
      inviter = create_user
      invitation = create_invitation(org, role, inviter, expires_at: 1.day.ago)
      accepter = create_user

      response = call_action(:accept,
        params: { token: invitation.token },
        headers: auth_headers(accepter))

      expect(response.status).to eq(422)
      expect(response.body["message"]).to include("expired")
    end
  end
end
