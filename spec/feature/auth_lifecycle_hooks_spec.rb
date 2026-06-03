# frozen_string_literal: true

require "spec_helper"
require "rhino/controllers/auth_controller"
require "ostruct"

# Ensure invitation tokens exist before validation (same shim as authentication_spec).
unless Rhino::OrganizationInvitation.instance_methods.include?(:ensure_token_for_hooks_test)
  Rhino::OrganizationInvitation.class_eval do
    before_validation :ensure_token_for_hooks_test, on: :create

    private

    def ensure_token_for_hooks_test
      self.token ||= SecureRandom.hex(32)
    end
  end
end

# A recording hooks class: captures every event + context, and may be told to
# reject a specific event.
class RecordingAuthHooks < Rhino::AuthHooks
  CALLS = []
  REJECT = {}

  class << self
    def reset!
      CALLS.clear
      REJECT.clear
    end

    def reject!(event, status: 403, message: "rejected by hook")
      REJECT[event] = { status: status, message: message }
    end
  end

  %i[after_login after_logout after_register after_password_recover after_password_reset].each do |event|
    define_method(event) do |user, context = {}|
      CALLS << { event: event, user_id: user&.id, context: context }
      if (cfg = REJECT[event])
        raise Rhino::AuthRejected.new(cfg[:message], status: cfg[:status])
      end
    end
  end
end

RSpec.describe "Auth lifecycle hooks" do
  before { RecordingAuthHooks.reset! }

  # Dispatch a controller action with a resolved route_group default.
  def call_action(action, route_group:, params: {}, headers: {})
    controller = Rhino::AuthController.new

    env = Rack::MockRequest.env_for("/api/#{route_group}/auth/#{action}", method: "POST")
    env["action_dispatch.request.request_parameters"] = params.stringify_keys
    env["action_dispatch.request.path_parameters"] = {
      controller: "rhino/auth",
      action: action.to_s,
      route_group: route_group
    }
    headers.each { |k, v| env["HTTP_#{k.upcase.tr('-', '_')}"] = v }

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

  def configure_with_hooks(hooks: RecordingAuthHooks)
    Rhino.reset_configuration!
    Rhino.configure do |c|
      c.model :posts, "Post"
      c.route_group :driver, prefix: "driver", auth: true, hooks: hooks, models: [:posts]
      c.route_group :nohook, prefix: "nohook", auth: true, models: [:posts]
    end
  end

  def make_user(attrs = {})
    User.create!({ name: "U", email: "u@x.com" }.merge(attrs))
  end

  # ==================================================================
  # after_login
  # ==================================================================

  describe "after_login" do
    it "fires with the correct context after a successful login" do
      configure_with_hooks
      make_user

      res = call_action(:login, route_group: "driver", params: { email: "u@x.com", password: "password" })

      expect(res.status).to eq(200)
      call = RecordingAuthHooks::CALLS.find { |c| c[:event] == :after_login }
      expect(call).to be_present
      expect(call[:context][:route_group]).to eq("driver")
      expect(call[:context][:token]).to be_present
      expect(call[:context][:request]).to be_present
    end

    it "rejection revokes the issued token and returns the hook status" do
      configure_with_hooks
      user = make_user
      RecordingAuthHooks.reject!(:after_login, status: 403)

      res = call_action(:login, route_group: "driver", params: { email: "u@x.com", password: "password" })

      expect(res.status).to eq(403)
      expect(res.body["message"]).to eq("rejected by hook")
      # The just-issued token was revoked, so it does not authenticate.
      user.reload
      expect(res.body["token"]).to be_nil
    end

    it "supports custom rejection status codes" do
      configure_with_hooks
      make_user
      RecordingAuthHooks.reject!(:after_login, status: 409, message: "conflict")

      res = call_action(:login, route_group: "driver", params: { email: "u@x.com", password: "password" })
      expect(res.status).to eq(409)
      expect(res.body["message"]).to eq("conflict")
    end

    it "is a no-op for a non-rejecting hook (login succeeds)" do
      configure_with_hooks
      make_user
      res = call_action(:login, route_group: "driver", params: { email: "u@x.com", password: "password" })
      expect(res.status).to eq(200)
      expect(res.body["token"]).to be_present
    end

    it "works for a group with no hooks class (login succeeds, no calls)" do
      configure_with_hooks
      make_user
      res = call_action(:login, route_group: "nohook", params: { email: "u@x.com", password: "password" })
      expect(res.status).to eq(200)
      expect(RecordingAuthHooks::CALLS).to be_empty
    end
  end

  # ==================================================================
  # after_logout
  # ==================================================================

  describe "after_logout" do
    it "fires after logout" do
      configure_with_hooks
      make_user(api_token: "logout-token")

      res = call_action(:logout, route_group: "driver", headers: { "Authorization" => "Bearer logout-token" })
      expect(res.status).to eq(200)
      expect(RecordingAuthHooks::CALLS.map { |c| c[:event] }).to include(:after_logout)
    end

    it "rejection returns the status without re-issuing a token" do
      configure_with_hooks
      make_user(api_token: "logout-token-2")
      RecordingAuthHooks.reject!(:after_logout, status: 403)

      res = call_action(:logout, route_group: "driver", headers: { "Authorization" => "Bearer logout-token-2" })
      expect(res.status).to eq(403)
    end
  end

  # ==================================================================
  # after_password_recover
  # ==================================================================

  describe "after_password_recover" do
    it "fires when a user exists" do
      configure_with_hooks
      make_user

      res = call_action(:recover_password, route_group: "driver", params: { email: "u@x.com" })
      expect(res.status).to eq(200)
      expect(RecordingAuthHooks::CALLS.map { |c| c[:event] }).to include(:after_password_recover)
    end

    it "does NOT fire for a non-existent email (no enumeration), still 200" do
      configure_with_hooks
      res = call_action(:recover_password, route_group: "driver", params: { email: "ghost@x.com" })
      expect(res.status).to eq(200)
      expect(RecordingAuthHooks::CALLS).to be_empty
    end

    it "swallows a hook rejection: returns the uniform 200 response (no enumeration oracle)" do
      configure_with_hooks
      make_user
      RecordingAuthHooks.reject!(:after_password_recover, status: 403)

      res = call_action(:recover_password, route_group: "driver", params: { email: "u@x.com" })

      # The hook rejected, but recover_password must NOT leak that — it returns
      # the same response it gives for a non-existent email (see the test
      # above), so an attacker cannot distinguish real from fake accounts.
      expect(res.status).to eq(200)
      expect(res.body["message"]).to eq("Password recovery email sent.")
      # The hook still ran for its side effects.
      expect(RecordingAuthHooks::CALLS.map { |c| c[:event] }).to include(:after_password_recover)
    end

    it "returns the same 200 response shape whether the email exists or not" do
      configure_with_hooks
      make_user
      RecordingAuthHooks.reject!(:after_password_recover, status: 403)

      existing = call_action(:recover_password, route_group: "driver", params: { email: "u@x.com" })
      missing  = call_action(:recover_password, route_group: "driver", params: { email: "ghost@x.com" })

      expect(existing.status).to eq(missing.status)
      expect(existing.body).to eq(missing.body)
    end
  end

  # ==================================================================
  # after_password_reset
  # ==================================================================

  describe "after_password_reset" do
    it "fires after a successful reset" do
      configure_with_hooks
      make_user(reset_password_token: "rt", reset_password_sent_at: 5.minutes.ago)

      res = call_action(:reset, route_group: "driver", params: {
        token: "rt", email: "u@x.com", password: "newpassword1", password_confirmation: "newpassword1"
      })
      expect(res.status).to eq(200)
      expect(RecordingAuthHooks::CALLS.map { |c| c[:event] }).to include(:after_password_reset)
    end

    it "rejection returns the hook status" do
      configure_with_hooks
      make_user(reset_password_token: "rt2", reset_password_sent_at: 5.minutes.ago)
      RecordingAuthHooks.reject!(:after_password_reset, status: 403)

      res = call_action(:reset, route_group: "driver", params: {
        token: "rt2", email: "u@x.com", password: "newpassword1", password_confirmation: "newpassword1"
      })
      expect(res.status).to eq(403)
    end
  end

  # ==================================================================
  # after_register (invitation accept registration)
  # ==================================================================

  describe "after_register" do
    let!(:org) { Organization.create!(name: "O", slug: "o-#{SecureRandom.hex(4)}") }
    let!(:role) { Role.create!(name: "R", slug: "r-#{SecureRandom.hex(4)}", permissions: []) }

    def make_invitation(route_group:, email: "new@x.com")
      inviter = make_user(email: "admin-#{SecureRandom.hex(4)}@x.com")
      Rhino::OrganizationInvitation.create!(
        organization: org, role: role, invited_by: inviter.id,
        email: email, route_group: route_group
      )
    end

    it "fires with the invitation's group after registration" do
      configure_with_hooks
      invitation = make_invitation(route_group: "driver")

      res = call_action(:register_with_invitation, route_group: "driver", params: {
        token: invitation.token, name: "New", email: "new@x.com",
        password: "password123", password_confirmation: "password123"
      })

      expect(res.status).to eq(201)
      call = RecordingAuthHooks::CALLS.find { |c| c[:event] == :after_register }
      expect(call).to be_present
      expect(call[:context][:route_group]).to eq("driver")
      expect(call[:context][:token]).to be_present
    end

    it "rejection revokes the issued token and returns the status" do
      configure_with_hooks
      invitation = make_invitation(route_group: "driver")
      RecordingAuthHooks.reject!(:after_register, status: 403)

      res = call_action(:register_with_invitation, route_group: "driver", params: {
        token: invitation.token, name: "New", email: "new@x.com",
        password: "password123", password_confirmation: "password123"
      })

      expect(res.status).to eq(403)
      new_user = User.find_by(email: "new@x.com")
      expect(new_user).to be_present
      # Token revoked: the response carries no usable token.
      expect(res.body["token"]).to be_nil
    end
  end
end
