# frozen_string_literal: true

require "spec_helper"
require "rhino/controllers/auth_controller"
require "ostruct"

# Fix callback ordering: generate_token runs before_create (after validation),
# but validates :token, presence: true fails without it.
unless Rhino::OrganizationInvitation.instance_methods.include?(:ensure_token_for_auth_test)
  Rhino::OrganizationInvitation.class_eval do
    before_validation :ensure_token_for_auth_test, on: :create

    private

    def ensure_token_for_auth_test
      self.token ||= SecureRandom.hex(32)
    end
  end
end

RSpec.describe "Authentication" do
  # ------------------------------------------------------------------
  # Helpers
  # ------------------------------------------------------------------

  def call_action(action, params: {}, headers: {})
    controller = Rhino::AuthController.new

    env = Rack::MockRequest.env_for("/api/auth/#{action}", method: "POST")
    env["action_dispatch.request.request_parameters"] = params.stringify_keys
    env["action_dispatch.request.path_parameters"] = {
      controller: "rhino/auth",
      action: action.to_s
    }

    headers.each do |key, value|
      env["HTTP_#{key.upcase.tr('-', '_')}"] = value
    end

    request = ActionDispatch::Request.new(env)
    response = ActionDispatch::Response.new

    controller.dispatch(action.to_sym, request, response)

    body = begin
      JSON.parse(response.body)
    rescue JSON::ParserError
      {}
    end

    OpenStruct.new(status: response.status, body: body)
  end

  def create_user(attrs = {})
    User.create!({ name: "Test User", email: "user@example.com" }.merge(attrs))
  end

  def create_organization(attrs = {})
    Organization.create!({ name: "Test Organization", slug: "test-org" }.merge(attrs))
  end

  def create_role(attrs = {})
    Role.create!({ name: "Editor", slug: "editor", permissions: [] }.merge(attrs))
  end

  def create_user_in_organization(org, role, user_attrs = {})
    user = create_user(user_attrs)
    UserRole.create!(user: user, organization: org, role: role)
    user
  end

  def create_invitation(org, role, inviter, attrs = {})
    Rhino::OrganizationInvitation.create!({
      organization: org,
      email: "invitee@example.com",
      role: role,
      invited_by: inviter.id
    }.merge(attrs))
  end

  # ==================================================================
  # Login
  # ==================================================================

  describe "POST /api/auth/login" do
    it "returns token and organization slug with valid credentials" do
      org = create_organization
      role = create_role
      user = create_user_in_organization(org, role)

      response = call_action(:login, params: { email: "user@example.com", password: "password" })

      expect(response.status).to eq(200)
      expect(response.body["token"]).to be_present
      expect(response.body["organization_slug"]).to eq("test-org")
    end

    it "returns 401 with invalid password" do
      create_user

      response = call_action(:login, params: { email: "user@example.com", password: "wrong-password" })

      expect(response.status).to eq(401)
      expect(response.body["message"]).to eq("Invalid credentials")
    end

    it "returns 401 with non-existent email" do
      response = call_action(:login, params: { email: "nobody@example.com", password: "password" })

      expect(response.status).to eq(401)
      expect(response.body["message"]).to eq("Invalid credentials")
    end

    it "returns null organization slug when user has no organizations" do
      create_user

      response = call_action(:login, params: { email: "user@example.com", password: "password" })

      expect(response.status).to eq(200)
      expect(response.body["organization_slug"]).to be_nil
    end

    it "returns 401 when email is blank" do
      response = call_action(:login, params: { email: "", password: "password" })

      expect(response.status).to eq(401)
      expect(response.body["message"]).to eq("Invalid credentials")
    end

    it "returns 401 when password is blank" do
      response = call_action(:login, params: { email: "user@example.com", password: "" })

      expect(response.status).to eq(401)
      expect(response.body["message"]).to eq("Invalid credentials")
    end

    it "stores api_token on user after login" do
      user = create_user

      response = call_action(:login, params: { email: "user@example.com", password: "password" })

      user.reload
      expect(user.api_token).to be_present
      expect(response.body["token"]).to eq(user.api_token)
    end
  end

  # ==================================================================
  # Logout
  # ==================================================================

  describe "POST /api/auth/logout" do
    it "invalidates the api token" do
      user = create_user(api_token: "valid-token-123")

      response = call_action(:logout, headers: { "Authorization" => "Bearer valid-token-123" })

      expect(response.status).to eq(200)
      expect(response.body["message"]).to eq("Logged out successfully")

      user.reload
      expect(user.api_token).not_to eq("valid-token-123")
    end

    it "returns 401 when not authenticated" do
      response = call_action(:logout)

      expect(response.status).to eq(401)
    end

    it "returns 401 with invalid token" do
      response = call_action(:logout, headers: { "Authorization" => "Bearer invalid-token" })

      expect(response.status).to eq(401)
    end
  end

  # ==================================================================
  # Password Recovery
  # ==================================================================

  describe "POST /api/auth/password/recover" do
    it "returns success and sets reset token for existing email" do
      user = create_user

      response = call_action(:recover_password, params: { email: "user@example.com" })

      expect(response.status).to eq(200)
      expect(response.body["message"]).to eq("Password recovery email sent.")

      user.reload
      expect(user.reset_password_token).to be_present
      expect(user.reset_password_sent_at).to be_present
    end

    it "returns success even for non-existent email (prevents enumeration)" do
      response = call_action(:recover_password, params: { email: "nobody@example.com" })

      expect(response.status).to eq(200)
      expect(response.body["message"]).to eq("Password recovery email sent.")
    end

    it "returns 422 when email is blank" do
      response = call_action(:recover_password, params: { email: "" })

      expect(response.status).to eq(422)
      expect(response.body["errors"]["email"]).to be_present
    end
  end

  # ==================================================================
  # Password Reset
  # ==================================================================

  describe "POST /api/auth/password/reset" do
    it "resets password with valid token" do
      user = create_user(
        reset_password_token: "valid-reset-token",
        reset_password_sent_at: 10.minutes.ago
      )
      old_digest = user.password_digest

      response = call_action(:reset, params: {
        token: "valid-reset-token",
        email: "user@example.com",
        password: "newpassword123",
        password_confirmation: "newpassword123"
      })

      expect(response.status).to eq(200)
      expect(response.body["message"]).to eq("Password has been reset.")

      user.reload
      expect(user.reset_password_token).to be_nil
      expect(user.reset_password_sent_at).to be_nil
      expect(user.password_digest).not_to eq(old_digest)
    end

    it "returns 400 with invalid token" do
      create_user(
        reset_password_token: "real-token",
        reset_password_sent_at: 10.minutes.ago
      )

      response = call_action(:reset, params: {
        token: "wrong-token",
        email: "user@example.com",
        password: "newpassword123",
        password_confirmation: "newpassword123"
      })

      expect(response.status).to eq(400)
      expect(response.body["message"]).to eq("Token is invalid or expired.")
    end

    it "returns 400 with expired token (older than 1 hour)" do
      create_user(
        reset_password_token: "expired-token",
        reset_password_sent_at: 2.hours.ago
      )

      response = call_action(:reset, params: {
        token: "expired-token",
        email: "user@example.com",
        password: "newpassword123",
        password_confirmation: "newpassword123"
      })

      expect(response.status).to eq(400)
      expect(response.body["message"]).to eq("Token is invalid or expired.")
    end

    it "returns 422 when required fields are missing" do
      response = call_action(:reset, params: {})

      expect(response.status).to eq(422)
      expect(response.body["errors"]).to include("token", "email", "password")
    end

    it "returns 422 when password confirmation does not match" do
      create_user(
        reset_password_token: "some-token",
        reset_password_sent_at: 10.minutes.ago
      )

      response = call_action(:reset, params: {
        token: "some-token",
        email: "user@example.com",
        password: "newpassword123",
        password_confirmation: "different"
      })

      expect(response.status).to eq(422)
      expect(response.body["errors"]["password_confirmation"]).to be_present
    end

    it "returns 422 when password is shorter than 8 characters" do
      create_user

      response = call_action(:reset, params: {
        token: "some-token",
        email: "user@example.com",
        password: "short",
        password_confirmation: "short"
      })

      expect(response.status).to eq(422)
      expect(response.body["errors"]["password"]).to be_present
    end

    it "returns 400 when email does not exist" do
      response = call_action(:reset, params: {
        token: "some-token",
        email: "nonexistent@example.com",
        password: "newpassword123",
        password_confirmation: "newpassword123"
      })

      expect(response.status).to eq(400)
      expect(response.body["message"]).to eq("Token is invalid or expired.")
    end
  end

  # ==================================================================
  # Registration with Invitation
  # ==================================================================

  describe "POST /api/auth/register" do
    it "registers user with valid invitation" do
      org = create_organization
      role = create_role
      inviter = create_user(email: "admin@example.com")

      invitation = create_invitation(org, role, inviter, email: "newuser@example.com")

      response = call_action(:register_with_invitation, params: {
        token: invitation.token,
        name: "New User",
        email: "newuser@example.com",
        password: "password123",
        password_confirmation: "password123"
      })

      expect(response.status).to eq(201)
      expect(response.body["message"]).to eq("Registration successful")
      expect(response.body["token"]).to be_present
      expect(response.body["organization_slug"]).to eq("test-org")
      expect(response.body["user"]).to be_present

      # User was created
      new_user = User.find_by(email: "newuser@example.com")
      expect(new_user).to be_present
      expect(new_user.name).to eq("New User")

      # Invitation was accepted
      invitation.reload
      expect(invitation.status).to eq("accepted")
      expect(invitation.accepted_at).to be_present

      # User was added to organization
      expect(UserRole.exists?(user_id: new_user.id, organization_id: org.id, role_id: role.id)).to be true
    end

    it "returns 404 with invalid token" do
      response = call_action(:register_with_invitation, params: {
        token: SecureRandom.hex(32),
        name: "New User",
        email: "newuser@example.com",
        password: "password123",
        password_confirmation: "password123"
      })

      expect(response.status).to eq(404)
      expect(response.body["message"]).to eq("Invalid or expired invitation token")
    end

    it "returns 422 with expired invitation" do
      org = create_organization
      role = create_role
      inviter = create_user(email: "admin@example.com")

      invitation = create_invitation(org, role, inviter,
        email: "newuser@example.com",
        expires_at: 1.day.ago
      )

      response = call_action(:register_with_invitation, params: {
        token: invitation.token,
        name: "New User",
        email: "newuser@example.com",
        password: "password123",
        password_confirmation: "password123"
      })

      expect(response.status).to eq(422)
      expect(response.body["message"]).to eq("This invitation has expired")

      invitation.reload
      expect(invitation.status).to eq("expired")
    end

    it "returns 422 when email does not match invitation" do
      org = create_organization
      role = create_role
      inviter = create_user(email: "admin@example.com")

      invitation = create_invitation(org, role, inviter, email: "invited@example.com")

      response = call_action(:register_with_invitation, params: {
        token: invitation.token,
        name: "New User",
        email: "different@example.com",
        password: "password123",
        password_confirmation: "password123"
      })

      expect(response.status).to eq(422)
      expect(response.body["message"]).to eq("Email does not match the invitation")
    end

    it "returns 422 when required fields are missing" do
      response = call_action(:register_with_invitation, params: {})

      expect(response.status).to eq(422)
      expect(response.body["errors"]).to include("token", "name", "email", "password")
    end

    it "returns 422 when email is already taken" do
      create_user(email: "taken@example.com")

      response = call_action(:register_with_invitation, params: {
        token: SecureRandom.hex(32),
        name: "New User",
        email: "taken@example.com",
        password: "password123",
        password_confirmation: "password123"
      })

      expect(response.status).to eq(422)
      expect(response.body["errors"]["email"]).to be_present
    end

    it "returns 422 when password confirmation does not match" do
      response = call_action(:register_with_invitation, params: {
        token: SecureRandom.hex(32),
        name: "New User",
        email: "newuser@example.com",
        password: "password123",
        password_confirmation: "different"
      })

      expect(response.status).to eq(422)
      expect(response.body["errors"]["password_confirmation"]).to be_present
    end

    it "returns 422 when password is shorter than 8 characters" do
      response = call_action(:register_with_invitation, params: {
        token: SecureRandom.hex(32),
        name: "New User",
        email: "newuser@example.com",
        password: "short",
        password_confirmation: "short"
      })

      expect(response.status).to eq(422)
      expect(response.body["errors"]["password"]).to be_present
    end
  end
end
