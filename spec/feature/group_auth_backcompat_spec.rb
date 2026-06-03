# frozen_string_literal: true

require "spec_helper"
require "request_store"
require "rhino/routes"
require "rhino/controllers/resources_controller"

# Backward-compatibility regression guards (GROUP_AUTH_DESIGN.md §10). With the
# flag off and no auth/hooks configured, behavior must be byte-for-byte today's.
class BackcompatPost < ActiveRecord::Base
  self.table_name = "posts"
  include Rhino::HasRhino
  include Rhino::HasValidation
  include Rhino::HidableColumns
  include Rhino::BelongsToOrganization

  rhino_fields :id, :title, :organization_id
end

class BackcompatPostPolicy < Rhino::ResourcePolicy
  self.resource_slug = "posts"
end

RSpec.describe "Group-auth backward compatibility" do
  def build_routes
    routes = ActionDispatch::Routing::RouteSet.new
    routes.draw { Rhino::Routes.draw(self) }
    routes
  end

  def dispatch(routes, path, token: nil, host: "example.com", method: :get)
    RequestStore.store[:rhino_current_user] = nil
    RequestStore.store[:rhino_organization] = nil
    RequestStore.store[:rhino_route_group] = nil

    env = Rack::MockRequest.env_for(path, "HTTP_HOST" => host, "REQUEST_METHOD" => method.to_s.upcase)
    env["HTTP_AUTHORIZATION"] = "Bearer #{token}" if token
    env["HTTP_ACCEPT"] = "application/json"

    status, _headers, body = routes.call(env)
    raw = +""
    body.each { |p| raw << p }
    parsed = begin
      JSON.parse(raw)
    rescue JSON::ParserError
      {}
    end
    [status, parsed]
  ensure
    RequestStore.store[:rhino_current_user] = nil
    RequestStore.store[:rhino_organization] = nil
    RequestStore.store[:rhino_route_group] = nil
  end

  let!(:role) { Role.create!(name: "All", slug: "all-#{SecureRandom.hex(4)}", permissions: ["*"]) }

  describe "flag off: no membership enforcement, heuristic permissions" do
    before do
      Rhino.reset_configuration!
      Rhino.configure do |c|
        c.model :posts, "BackcompatPost"
        c.route_group :default, prefix: "", models: [:posts]
      end
    end

    it "authenticated user with users.permissions can access (no membership row)" do
      user = User.create!(name: "U", email: "u-#{SecureRandom.hex(4)}@x.com",
                          api_token: "bc-token", permissions: ["*"])
      routes = build_routes
      status, _ = dispatch(routes, "/api/posts", token: user.api_token)
      expect(status).to eq(200)
    end

    it "does not register per-group auth routes when nothing opts in" do
      expect(Rhino.config.auth_enabled_groups).to be_empty
    end

    it "enforce_group_membership? is false by default" do
      expect(Rhino.config.enforce_group_membership?).to be false
    end
  end

  describe "cross-tenant isolation still holds with flag on" do
    let!(:org_a) { Organization.create!(name: "A", slug: "a-#{SecureRandom.hex(4)}") }
    let!(:org_b) { Organization.create!(name: "B", slug: "b-#{SecureRandom.hex(4)}") }

    before do
      Rhino.reset_configuration!
      Rhino.configure do |c|
        c.model :posts, "BackcompatPost"
        c.route_group :tenant, prefix: ":organization",
                      middleware: [Rhino::Middleware::ResolveOrganizationFromRoute],
                      auth: true, models: [:posts]
        c.multi_tenant = { organization_identifier_column: "slug" }
        c.auth = { enforce_group_membership: true }
      end
    end

    it "a member of org A cannot reach org B's tenant routes" do
      user = User.create!(name: "U", email: "u-#{SecureRandom.hex(4)}@x.com",
                          api_token: "iso-token", permissions: ["*"])
      UserRole.create!(user: user, role: role, organization: org_a, route_group: "tenant")

      routes = build_routes
      status, _ = dispatch(routes, "/api/#{org_b.slug}/posts", token: user.api_token)
      expect([403, 404]).to include(status)
    end
  end
end
