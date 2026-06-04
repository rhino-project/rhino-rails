# frozen_string_literal: true

require "spec_helper"
require "request_store"
require "rhino/routes"
require "rhino/controllers/resources_controller"

# Model used by the membership-enforcement integration tests. Separate class so
# its scoping does not leak into the shared Post specs.
class MembershipPost < ActiveRecord::Base
  self.table_name = "posts"
  include Rhino::HasRhino
  include Rhino::HasValidation
  include Rhino::HidableColumns
  include Rhino::BelongsToOrganization

  rhino_fields :id, :title, :organization_id
end

class MembershipPostPolicy < Rhino::ResourcePolicy
  self.resource_slug = "posts"
end

RSpec.describe "Group membership enforcement" do
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
    body.each { |part| raw << part }
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

  let!(:role_all) { Role.create!(name: "All", slug: "all-#{SecureRandom.hex(4)}", permissions: ["*"]) }

  def make_user(token)
    User.create!(name: "U", email: "u-#{SecureRandom.hex(4)}@x.com", api_token: token, permissions: ["*"])
  end

  # ==================================================================
  # Flag OFF — regression guard (no behavior change)
  # ==================================================================

  describe "flag OFF (default)" do
    before do
      Rhino.reset_configuration!
      Rhino.configure do |c|
        c.model :posts, "MembershipPost"
        c.route_group :driver, prefix: "driver", models: [:posts]
        # enforce_group_membership defaults to false
      end
    end

    it "allows an authenticated user with NO membership row (heuristic preserved)" do
      user = make_user("off-token")
      routes = build_routes
      status, _ = dispatch(routes, "/api/driver/posts", token: user.api_token)
      expect(status).to eq(200)
    end
  end

  # ==================================================================
  # Flag ON — non-tenant group
  # ==================================================================

  describe "flag ON, non-tenant group" do
    before do
      Rhino.reset_configuration!
      Rhino.configure do |c|
        c.model :posts, "MembershipPost"
        c.route_group :driver, prefix: "driver", auth: true, models: [:posts]
        c.auth = { enforce_group_membership: true }
      end
    end

    it "allows a user with a matching route_group membership" do
      user = make_user("driver-token")
      UserRole.create!(user: user, role: role_all, organization: nil, route_group: "driver")

      routes = build_routes
      status, _ = dispatch(routes, "/api/driver/posts", token: user.api_token)
      expect(status).to eq(200)
    end

    it "returns 403 for a user with no matching membership" do
      user = make_user("nomatch-token")
      routes = build_routes
      status, body = dispatch(routes, "/api/driver/posts", token: user.api_token)
      expect(status).to eq(403)
      expect(body["message"]).to eq("You are not a member of this group")
    end

    it "returns 403 for a user whose only membership is for a DIFFERENT group" do
      user = make_user("wrong-group-token")
      UserRole.create!(user: user, role: role_all, organization: nil, route_group: "admin")

      routes = build_routes
      status, _ = dispatch(routes, "/api/driver/posts", token: user.api_token)
      expect(status).to eq(403)
    end

    it "treats a NULL route_group membership as a wildcard (allows any group)" do
      user = make_user("wildcard-token")
      UserRole.create!(user: user, role: role_all, organization: nil, route_group: nil)

      routes = build_routes
      status, _ = dispatch(routes, "/api/driver/posts", token: user.api_token)
      expect(status).to eq(200)
    end

    it "ignores organization for a non-tenant group" do
      user = make_user("ignore-org-token")
      org = Organization.create!(name: "Irrelevant", slug: "irr-#{SecureRandom.hex(4)}")
      # Membership has an org set, but the driver group is non-tenant so org is ignored.
      UserRole.create!(user: user, role: role_all, organization: org, route_group: "driver")

      routes = build_routes
      status, _ = dispatch(routes, "/api/driver/posts", token: user.api_token)
      expect(status).to eq(200)
    end
  end

  # ==================================================================
  # Flag ON — tenant group requires org match
  # ==================================================================

  describe "flag ON, tenant group" do
    let!(:org_a) { Organization.create!(name: "A", slug: "a-#{SecureRandom.hex(4)}") }
    let!(:org_b) { Organization.create!(name: "B", slug: "b-#{SecureRandom.hex(4)}") }

    before do
      Rhino.reset_configuration!
      Rhino.configure do |c|
        c.model :posts, "MembershipPost"
        c.route_group :tenant, prefix: ":organization",
                      middleware: [Rhino::Middleware::ResolveOrganizationFromRoute],
                      auth: true, models: [:posts]
        c.multi_tenant = { organization_identifier_column: "slug" }
        c.auth = { enforce_group_membership: true }
      end
    end

    it "allows the tenant group when the membership org matches" do
      user = make_user("tenant-ok")
      UserRole.create!(user: user, role: role_all, organization: org_a, route_group: "tenant")

      routes = build_routes
      status, _ = dispatch(routes, "/api/#{org_a.slug}/posts", token: user.api_token)
      expect(status).to eq(200)
    end

    it "returns 403 when the membership belongs to a different org" do
      user = make_user("tenant-wrong-org")
      # Member of org_a tenant, but requests org_b. The existing org-membership
      # check would 404; ensure cross-org access is denied either way.
      UserRole.create!(user: user, role: role_all, organization: org_a, route_group: "tenant")

      routes = build_routes
      status, _ = dispatch(routes, "/api/#{org_b.slug}/posts", token: user.api_token)
      expect([403, 404]).to include(status)
    end
  end

  # ==================================================================
  # §11.2 — membership 403 takes precedence over the org-resolution 404
  # ==================================================================

  describe "§11.2 — 403 vs 404 precedence (tenant group)" do
    let!(:org_a) { Organization.create!(name: "A", slug: "a-#{SecureRandom.hex(4)}") }
    let!(:org_b) { Organization.create!(name: "B", slug: "b-#{SecureRandom.hex(4)}") }

    def configure_tenant(enforce:)
      Rhino.reset_configuration!
      Rhino.configure do |c|
        c.model :posts, "MembershipPost"
        c.route_group :tenant, prefix: ":organization",
                      middleware: [Rhino::Middleware::ResolveOrganizationFromRoute],
                      auth: true, models: [:posts]
        c.multi_tenant = { organization_identifier_column: "slug" }
        c.auth = { enforce_group_membership: enforce }
      end
    end

    context "enforcement ON" do
      before { configure_tenant(enforce: true) }

      it "returns 403 (not 404) for an authenticated non-member of the requested org" do
        user = make_user("enforced-cross-org")
        # Member of org_a tenant only, but requests org_b: non-member → 403.
        UserRole.create!(user: user, role: role_all, organization: org_a, route_group: "tenant")

        routes = build_routes
        status, body = dispatch(routes, "/api/#{org_b.slug}/posts", token: user.api_token)
        expect(status).to eq(403)
        expect(body["message"]).to eq("You are not a member of this group")
      end

      it "returns 200 for a member of the requested org" do
        user = make_user("enforced-member")
        UserRole.create!(user: user, role: role_all, organization: org_a, route_group: "tenant")

        routes = build_routes
        status, _ = dispatch(routes, "/api/#{org_a.slug}/posts", token: user.api_token)
        expect(status).to eq(200)
      end

      it "still returns 404 when the org genuinely does not exist" do
        user = make_user("enforced-missing-org")
        UserRole.create!(user: user, role: role_all, organization: org_a, route_group: "tenant")

        routes = build_routes
        status, body = dispatch(routes, "/api/does-not-exist/posts", token: user.api_token)
        expect(status).to eq(404)
        expect(body["message"]).to eq("Organization not found")
      end

      it "returns 401 (unauthenticated) before any org/membership resolution" do
        routes = build_routes
        status, _ = dispatch(routes, "/api/#{org_a.slug}/posts", token: "bogus-token-xyz")
        expect(status).to eq(401)
      end
    end

    context "enforcement OFF (default) — unchanged 404 info-hiding" do
      before { configure_tenant(enforce: false) }

      it "returns 404 for an authenticated user requesting an org they are not in" do
        user = make_user("off-cross-org")
        UserRole.create!(user: user, role: role_all, organization: org_a, route_group: "tenant")

        routes = build_routes
        status, body = dispatch(routes, "/api/#{org_b.slug}/posts", token: user.api_token)
        expect(status).to eq(404)
        expect(body["message"]).to eq("Organization not found")
      end

      it "returns 404 when the org genuinely does not exist" do
        user = make_user("off-missing-org")
        UserRole.create!(user: user, role: role_all, organization: org_a, route_group: "tenant")

        routes = build_routes
        status, _ = dispatch(routes, "/api/nope/posts", token: user.api_token)
        expect(status).to eq(404)
      end
    end
  end

  # ==================================================================
  # Permission source switch (flag ON resolves from the matched row)
  # ==================================================================

  describe "permission source switches to the matched membership row when ON" do
    before do
      Rhino.reset_configuration!
      Rhino.configure do |c|
        c.model :posts, "MembershipPost"
        c.route_group :driver, prefix: "driver", auth: true, models: [:posts]
        c.auth = { enforce_group_membership: true }
      end
    end

    it "denies (403) when the matched membership row lacks the permission" do
      # User has broad users.permissions, but the group membership row's role
      # does NOT grant posts.index — enforcement must use the row, not the user.
      user = User.create!(name: "U", email: "u-#{SecureRandom.hex(4)}@x.com",
                          api_token: "perm-switch", permissions: ["*"])
      narrow_role = Role.create!(name: "Narrow", slug: "narrow-#{SecureRandom.hex(4)}", permissions: ["blogs.index"])
      UserRole.create!(user: user, role: narrow_role, organization: nil, route_group: "driver")

      routes = build_routes
      status, _ = dispatch(routes, "/api/driver/posts", token: user.api_token)
      expect(status).to eq(403)
    end

    it "allows when the matched membership row grants the permission" do
      user = User.create!(name: "U", email: "u-#{SecureRandom.hex(4)}@x.com",
                          api_token: "perm-ok", permissions: [])
      role = Role.create!(name: "Driver", slug: "driver-role-#{SecureRandom.hex(4)}", permissions: ["posts.index"])
      UserRole.create!(user: user, role: role, organization: nil, route_group: "driver")

      routes = build_routes
      status, _ = dispatch(routes, "/api/driver/posts", token: user.api_token)
      expect(status).to eq(200)
    end
  end
end
