# frozen_string_literal: true

require "spec_helper"
require "request_store"
require "rhino/routes"
require "rhino/controllers/resources_controller"

# Multi-tenant aware model used by the domain integration tests. It is a
# separate class from the shared `Post` so its org `default_scope` does not
# leak into other specs.
class DomainPost < ActiveRecord::Base
  self.table_name = "posts"
  include Rhino::HasRhino
  include Rhino::HasValidation
  include Rhino::HidableColumns
  include Rhino::BelongsToOrganization

  rhino_fields :id, :title, :organization_id
end

class DomainPostPolicy < Rhino::ResourcePolicy
  self.resource_slug = "posts"
end

RSpec.describe "Domain-aware route groups" do
  # ------------------------------------------------------------------
  # Helpers
  # ------------------------------------------------------------------

  # Build a fresh RouteSet from the current Rhino configuration.
  def build_routes
    routes = ActionDispatch::Routing::RouteSet.new
    routes.draw { Rhino::Routes.draw(self) }
    routes
  end

  # Attempt to recognize a path on a given host. Returns the recognized
  # path_parameters hash on success, or :not_found when no route matches.
  # When the route matches but the controller cannot be loaded in the bare
  # RouteSet, that still counts as "recognized" (the host/path matched).
  def recognize(routes, path, host, method: :get)
    env = Rack::MockRequest.env_for(path, "HTTP_HOST" => host, "REQUEST_METHOD" => method.to_s.upcase)
    request = ActionDispatch::Request.new(env)
    routes.recognize_path_with_request(request, path, {})
  rescue ActionController::RoutingError => e
    e.message.include?("missing controller") ? :recognized_missing_controller : :not_found
  end

  def recognized?(result)
    result == :recognized_missing_controller || result.is_a?(Hash)
  end

  # Dispatch a full request through the RouteSet to the real controller.
  def dispatch(routes, host, path, token: nil, method: :get)
    RequestStore.store[:rhino_current_user] = nil
    RequestStore.store[:rhino_organization] = nil

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
  end

  # ==================================================================
  # Literal-domain host constraints (route recognition)
  # ==================================================================

  describe "literal domain host constraint" do
    before do
      Rhino.reset_configuration!
      Rhino.configure do |c|
        c.model :posts, "Post"
        c.route_group :admin, prefix: "admin", domain: "admin.example.com", models: [:posts]
      end
    end

    it "recognizes the route on the matching host" do
      routes = build_routes
      result = recognize(routes, "/api/admin/posts", "admin.example.com")
      expect(recognized?(result)).to be true
    end

    it "does not recognize the route on a non-matching host (404)" do
      routes = build_routes
      result = recognize(routes, "/api/admin/posts", "other.example.com")
      expect(result).to eq(:not_found)
    end

    it "does not recognize the route on a bare/wrong host" do
      routes = build_routes
      expect(recognize(routes, "/api/admin/posts", "example.com")).to eq(:not_found)
      expect(recognize(routes, "/api/admin/posts", "evil.com")).to eq(:not_found)
    end
  end

  # ==================================================================
  # Two groups, same prefix, different domains
  # ==================================================================

  describe "two groups sharing a prefix on different domains" do
    before do
      Rhino.reset_configuration!
      Rhino.configure do |c|
        c.model :posts, "Post"
        c.route_group :admin, prefix: "panel", domain: "admin.example.com", models: [:posts]
        c.route_group :staff, prefix: "panel", domain: "staff.example.com", models: [:posts]
      end
    end

    it "registers both groups" do
      expect(Rhino.config.route_groups.keys).to contain_exactly(:admin, :staff)
    end

    it "routes /api/panel/posts only on the admin host for the admin group" do
      routes = build_routes
      expect(recognized?(recognize(routes, "/api/panel/posts", "admin.example.com"))).to be true
    end

    it "routes /api/panel/posts only on the staff host for the staff group" do
      routes = build_routes
      expect(recognized?(recognize(routes, "/api/panel/posts", "staff.example.com"))).to be true
    end

    it "does not route /api/panel/posts on an unrelated host" do
      routes = build_routes
      expect(recognize(routes, "/api/panel/posts", "public.example.com")).to eq(:not_found)
    end
  end

  # ==================================================================
  # domain + prefix combined
  # ==================================================================

  describe "domain combined with prefix" do
    before do
      Rhino.reset_configuration!
      Rhino.configure do |c|
        c.model :posts, "Post"
        c.route_group :admin, prefix: "backoffice", domain: "admin.example.com", models: [:posts]
      end
    end

    it "matches the correct host and path" do
      routes = build_routes
      expect(recognized?(recognize(routes, "/api/backoffice/posts", "admin.example.com"))).to be true
    end

    it "does not match the right host with the wrong path" do
      routes = build_routes
      expect(recognize(routes, "/api/posts", "admin.example.com")).to eq(:not_found)
    end

    it "does not match the right path on the wrong host" do
      routes = build_routes
      expect(recognize(routes, "/api/backoffice/posts", "other.example.com")).to eq(:not_found)
    end
  end

  # ==================================================================
  # Parameterized domain — subdomain multitenancy (full dispatch)
  # ==================================================================

  describe "parameterized domain subdomain multitenancy" do
    let!(:org_one) { Organization.create!(name: "Org One", slug: "org-one") }
    let!(:org_two) { Organization.create!(name: "Org Two", slug: "org-two") }
    let!(:role) { Role.create!(name: "Admin", slug: "admin-#{SecureRandom.hex(4)}", permissions: ["*"]) }

    # A user that is a member of BOTH organizations (cross-tenant isolation
    # must still hold based purely on the requesting subdomain).
    let!(:user) do
      u = User.create!(name: "Member", email: "member-#{SecureRandom.hex(4)}@test.com",
                       api_token: "domain-token-#{SecureRandom.hex(6)}", permissions: ["*"])
      UserRole.create!(user: u, organization: org_one, role: role)
      UserRole.create!(user: u, organization: org_two, role: role)
      u
    end

    let!(:post_one) { DomainPost.create!(title: "Org One Post", organization_id: org_one.id) }
    let!(:post_two) { DomainPost.create!(title: "Org Two Post", organization_id: org_two.id) }

    before do
      Rhino.reset_configuration!
      Rhino.configure do |c|
        c.model :posts, "DomainPost"
        c.route_group :tenant, prefix: "", domain: "{organization}.example.com", models: [:posts]
        c.multi_tenant = { organization_identifier_column: "slug" }
      end
    end

    it "scopes data to org-one when requested via org-one.example.com" do
      routes = build_routes
      status, body = dispatch(routes, "org-one.example.com", "/api/posts", token: user.api_token)

      expect(status).to eq(200)
      titles = body["data"].map { |p| p["title"] }
      expect(titles).to contain_exactly("Org One Post")
    end

    it "resolves the org from a mixed-case host (DNS is case-insensitive)" do
      routes = build_routes
      status, body = dispatch(routes, "ORG-ONE.example.com", "/api/posts", token: user.api_token)

      expect(status).to eq(200)
      titles = body["data"].map { |p| p["title"] }
      expect(titles).to contain_exactly("Org One Post")
    end

    it "scopes data to org-two when requested via org-two.example.com" do
      routes = build_routes
      status, body = dispatch(routes, "org-two.example.com", "/api/posts", token: user.api_token)

      expect(status).to eq(200)
      titles = body["data"].map { |p| p["title"] }
      expect(titles).to contain_exactly("Org Two Post")
    end

    it "isolates tenants: org-one's request never returns org-two's data" do
      routes = build_routes
      _status, body = dispatch(routes, "org-one.example.com", "/api/posts", token: user.api_token)
      org_ids = body["data"].map { |p| p["organization_id"] }
      expect(org_ids).to all(eq(org_one.id))
    end

    it "returns 404 for an unknown subdomain (no matching organization)" do
      routes = build_routes
      status, body = dispatch(routes, "ghost.example.com", "/api/posts", token: user.api_token)

      expect(status).to eq(404)
      expect(body["message"]).to eq("Organization not found")
    end

    it "returns 404 for a subdomain the authenticated user is not a member of" do
      non_member = User.create!(name: "Outsider", email: "out-#{SecureRandom.hex(4)}@test.com",
                                api_token: "out-token-#{SecureRandom.hex(6)}", permissions: ["*"])
      routes = build_routes
      status, body = dispatch(routes, "org-one.example.com", "/api/posts", token: non_member.api_token)

      expect(status).to eq(404)
      expect(body["message"]).to eq("Organization not found")
    end

    it "does not match a multi-label or bare host on the parameterized domain" do
      routes = build_routes
      expect(recognize(routes, "/api/posts", "example.com")).to eq(:not_found)
      expect(recognize(routes, "/api/posts", "a.b.example.com")).to eq(:not_found)
    end
  end

  # ==================================================================
  # Tenant invitation + nested routes inherit the tenant domain
  # ==================================================================

  describe "tenant invitation and nested routes inherit the tenant domain" do
    before do
      Rhino.reset_configuration!
      Rhino.configure do |c|
        c.model :posts, "Post"
        c.route_group :tenant, prefix: "", domain: "{organization}.example.com", models: [:posts]
        c.multi_tenant = { organization_identifier_column: "slug" }
      end
    end

    it "recognizes invitation routes only on the tenant domain" do
      routes = build_routes
      expect(recognized?(recognize(routes, "/api/invitations", "org-one.example.com"))).to be true
      expect(recognize(routes, "/api/invitations", "example.com")).to eq(:not_found)
      expect(recognize(routes, "/api/invitations", "other.com")).to eq(:not_found)
    end

    it "recognizes the nested route only on the tenant domain" do
      routes = build_routes
      expect(recognized?(recognize(routes, "/api/nested", "org-one.example.com", method: :post))).to be true
      expect(recognize(routes, "/api/nested", "example.com", method: :post)).to eq(:not_found)
    end

    it "still recognizes the always-public invitation accept route on any host" do
      routes = build_routes
      expect(recognized?(recognize(routes, "/api/invitations/accept", "anything.com", method: :post))).to be true
    end
  end

  # ==================================================================
  # Backward compatibility: no domain matches any host
  # ==================================================================

  describe "backward compatibility (no domain)" do
    before do
      Rhino.reset_configuration!
      Rhino.configure do |c|
        c.model :posts, "Post"
        c.route_group :default, prefix: "", models: :all
      end
    end

    it "registers routes that match on any host" do
      routes = build_routes
      expect(recognized?(recognize(routes, "/api/posts", "anything.example.com"))).to be true
      expect(recognized?(recognize(routes, "/api/posts", "literally.any.host"))).to be true
    end
  end
end
