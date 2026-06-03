# frozen_string_literal: true

require "spec_helper"
require "rhino/controllers/invitations_controller"
require "ostruct"

unless Rhino::OrganizationInvitation.instance_methods.include?(:ensure_token_for_inv_group_test)
  Rhino::OrganizationInvitation.class_eval do
    before_validation :ensure_token_for_inv_group_test, on: :create

    private

    def ensure_token_for_inv_group_test
      self.token ||= SecureRandom.hex(32)
    end
  end
end

RSpec.describe "Invitations carry the group" do
  def call_create(params:, headers:, organization:)
    controller = Rhino::InvitationsController.new
    allow(controller).to receive(:authorize).and_return(true)

    env = Rack::MockRequest.env_for("/api/invitations", method: "POST")
    env["action_dispatch.request.request_parameters"] = params.stringify_keys
    env["action_dispatch.request.path_parameters"] = { controller: "rhino/invitations", action: "create" }
    env["rhino.organization"] = organization
    headers.each { |k, v| env["HTTP_#{k.upcase.tr('-', '_')}"] = v }

    request = ActionDispatch::Request.new(env)
    response = ActionDispatch::Response.new
    controller.dispatch(:create, request, response)

    body = begin
      JSON.parse(response.body)
    rescue JSON::ParserError
      {}
    end
    OpenStruct.new(status: response.status, body: body)
  end

  let!(:org) { Organization.create!(name: "Org", slug: "org-#{SecureRandom.hex(4)}") }
  let!(:role) { Role.create!(name: "R", slug: "r-#{SecureRandom.hex(4)}", permissions: []) }
  let!(:inviter) do
    User.create!(name: "Admin", email: "admin-#{SecureRandom.hex(4)}@x.com",
                 permissions: ["*"], api_token: SecureRandom.hex(16))
  end

  before do
    Rhino.reset_configuration!
    Rhino.configure do |c|
      c.model :posts, "Post"
      c.route_group :tenant, prefix: ":organization", auth: true, models: [:posts]
      c.route_group :driver, prefix: "driver", auth: true, models: [:posts]
      c.route_group :public, prefix: "public", models: [:posts]
    end
  end

  # ==================================================================
  # Invite stores the group
  # ==================================================================

  it "stores the route_group on the created invitation" do
    res = call_create(
      params: { email: "new@x.com", role_id: role.id, route_group: "driver" },
      headers: { "Authorization" => "Bearer #{inviter.api_token}" },
      organization: org
    )

    expect(res.status).to eq(201)
    invitation = Rhino::OrganizationInvitation.find_by(email: "new@x.com")
    expect(invitation.route_group).to eq("driver")
  end

  it "leaves route_group nil when not supplied (legacy behavior)" do
    res = call_create(
      params: { email: "legacy@x.com", role_id: role.id },
      headers: { "Authorization" => "Bearer #{inviter.api_token}" },
      organization: org
    )
    expect(res.status).to eq(201)
    invitation = Rhino::OrganizationInvitation.find_by(email: "legacy@x.com")
    expect(invitation.route_group).to be_nil
  end

  it "stores organization_id = nil for a non-tenant group invite (via the API)" do
    res = call_create(
      params: { email: "driver-inv@x.com", role_id: role.id, route_group: "driver" },
      headers: { "Authorization" => "Bearer #{inviter.api_token}" },
      organization: org
    )

    expect(res.status).to eq(201)
    invitation = Rhino::OrganizationInvitation.find_by(email: "driver-inv@x.com")
    expect(invitation.route_group).to eq("driver")
    # The driver group is non-tenant: the invite must NOT carry the current org.
    expect(invitation.organization_id).to be_nil
  end

  it "stores the current organization for a tenant group invite" do
    res = call_create(
      params: { email: "tenant-inv@x.com", role_id: role.id, route_group: "tenant" },
      headers: { "Authorization" => "Bearer #{inviter.api_token}" },
      organization: org
    )

    expect(res.status).to eq(201)
    invitation = Rhino::OrganizationInvitation.find_by(email: "tenant-inv@x.com")
    expect(invitation.organization_id).to eq(org.id)
  end

  it "stores the current organization for a legacy (no group) invite" do
    res = call_create(
      params: { email: "legacy-org@x.com", role_id: role.id },
      headers: { "Authorization" => "Bearer #{inviter.api_token}" },
      organization: org
    )

    expect(res.status).to eq(201)
    invitation = Rhino::OrganizationInvitation.find_by(email: "legacy-org@x.com")
    expect(invitation.organization_id).to eq(org.id)
  end

  it "cannot invite into the public group" do
    res = call_create(
      params: { email: "pub@x.com", role_id: role.id, route_group: "public" },
      headers: { "Authorization" => "Bearer #{inviter.api_token}" },
      organization: org
    )
    expect(res.status).to eq(422)
    expect(res.body["message"]).to eq("Cannot invite into the public group")
  end

  # ==================================================================
  # Inviter-must-be-member (enforcement ON)
  # ==================================================================

  describe "inviter-must-be-member (enforcement ON)" do
    before { Rhino.config.auth = { enforce_group_membership: true } }

    it "allows when the inviter is a member of the target group" do
      UserRole.create!(user: inviter, role: role, organization: org, route_group: "driver")

      res = call_create(
        params: { email: "ok@x.com", role_id: role.id, route_group: "driver" },
        headers: { "Authorization" => "Bearer #{inviter.api_token}" },
        organization: org
      )
      expect(res.status).to eq(201)
    end

    it "returns 403 when the inviter is not a member of the target group" do
      res = call_create(
        params: { email: "bad@x.com", role_id: role.id, route_group: "driver" },
        headers: { "Authorization" => "Bearer #{inviter.api_token}" },
        organization: org
      )
      expect(res.status).to eq(403)
      expect(res.body["message"]).to eq("You are not a member of this group")
    end
  end

  # ==================================================================
  # Accept populates the membership with the group
  # ==================================================================

  describe "accept populates the membership" do
    it "creates a user_roles row carrying the invitation's route_group (tenant)" do
      invitation = Rhino::OrganizationInvitation.create!(
        organization: org, role: role, invited_by: inviter.id,
        email: "tenant-join@x.com", route_group: "tenant"
      )
      user = User.create!(name: "Joiner", email: "tenant-join@x.com")

      invitation.accept!(user)

      membership = UserRole.find_by(user_id: user.id, organization_id: org.id, role_id: role.id)
      expect(membership).to be_present
      expect(membership.route_group).to eq("tenant")
    end

    it "creates a membership with a NULL organization for a non-tenant group invite" do
      invitation = Rhino::OrganizationInvitation.create!(
        organization: nil, role: role, invited_by: inviter.id,
        email: "driver-join@x.com", route_group: "driver"
      )
      user = User.create!(name: "Driver", email: "driver-join@x.com")

      invitation.accept!(user)

      membership = UserRole.find_by(user_id: user.id, role_id: role.id, route_group: "driver")
      expect(membership).to be_present
      expect(membership.organization_id).to be_nil
    end
  end
end
