# frozen_string_literal: true

require "spec_helper"
require "rhino/middleware/resolve_organization_from_route"

RSpec.describe Rhino::Middleware::ResolveOrganizationFromRoute do
  let(:app) { ->(env) { [200, { "Content-Type" => "application/json" }, ['{"success":true}']] } }
  let(:middleware) { described_class.new(app) }

  before do
    Rhino.configure do |c|
      c.multi_tenant = { organization_identifier_column: "slug" }
    end
  end

  # ------------------------------------------------------------------
  # Pass-through when no organization parameter
  # ------------------------------------------------------------------

  describe "pass-through" do
    it "passes through when no organization parameter in route" do
      env = Rack::MockRequest.env_for("/api/users", method: "GET")
      env["action_dispatch.request.path_parameters"] = {}

      status, _headers, _body = middleware.call(env)

      expect(status).to eq(200)
      expect(env["rhino.organization"]).to be_nil
    end
  end

  # ------------------------------------------------------------------
  # Organization resolution
  # ------------------------------------------------------------------

  describe "organization resolution" do
    it "returns 404 when organization not found" do
      env = Rack::MockRequest.env_for("/api/nonexistent-org/users", method: "GET")
      env["action_dispatch.request.path_parameters"] = { organization: "nonexistent-org" }

      status, _headers, body = middleware.call(env)

      expect(status).to eq(404)
      response = JSON.parse(body.first)
      expect(response["message"]).to eq("Organization not found")
    end

    it "resolves organization by slug" do
      org = Organization.create!(name: "Test Organization", slug: "test-org-route")

      env = Rack::MockRequest.env_for("/api/test-org-route/users", method: "GET")
      env["action_dispatch.request.path_parameters"] = { organization: "test-org-route" }

      status, _headers, _body = middleware.call(env)

      expect(status).to eq(200)
      expect(env["rhino.organization"]).to be_present
      expect(env["rhino.organization"].id).to eq(org.id)
      expect(env["rhino.organization"].slug).to eq("test-org-route")
    end
  end

  # ------------------------------------------------------------------
  # User membership check
  # ------------------------------------------------------------------

  describe "user membership check" do
    it "allows authenticated user who belongs to organization" do
      org = Organization.create!(name: "Member Org", slug: "member-org-route")
      user = User.create!(name: "Member", email: "member-route@test.com", api_token: "valid-token-route")
      role = Role.create!(name: "Member Role", slug: "member-role-route", permissions: ["*"])
      UserRole.create!(user: user, organization: org, role: role)

      env = Rack::MockRequest.env_for("/api/member-org-route/users", method: "GET")
      env["action_dispatch.request.path_parameters"] = { organization: "member-org-route" }
      env["HTTP_AUTHORIZATION"] = "Bearer valid-token-route"

      status, _headers, _body = middleware.call(env)

      expect(status).to eq(200)
      expect(env["rhino.organization"].id).to eq(org.id)
    end

    it "returns 404 for authenticated user who does not belong to organization" do
      org = Organization.create!(name: "Other Org", slug: "other-org-route")
      user = User.create!(name: "Non-member", email: "nonmember-route@test.com", api_token: "nonmember-token-route")

      env = Rack::MockRequest.env_for("/api/other-org-route/users", method: "GET")
      env["action_dispatch.request.path_parameters"] = { organization: "other-org-route" }
      env["HTTP_AUTHORIZATION"] = "Bearer nonmember-token-route"

      status, _headers, _body = middleware.call(env)

      expect(status).to eq(404)
    end
  end

  # ------------------------------------------------------------------
  # Organization identifier column
  # ------------------------------------------------------------------

  describe "identifier column configuration" do
    it "uses configured identifier column" do
      Rhino.configure do |c|
        c.multi_tenant[:organization_identifier_column] = "slug"
      end

      org = Organization.create!(name: "Slug Org", slug: "slug-org-test")

      env = Rack::MockRequest.env_for("/api/slug-org-test/users", method: "GET")
      env["action_dispatch.request.path_parameters"] = { organization: "slug-org-test" }

      status, _headers, _body = middleware.call(env)

      expect(status).to eq(200)
      expect(env["rhino.organization"].slug).to eq("slug-org-test")
    end
  end
end
