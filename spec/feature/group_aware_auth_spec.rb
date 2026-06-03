# frozen_string_literal: true

require "spec_helper"
require "request_store"
require "rhino/routes"
require "rhino/controllers/auth_controller"

RSpec.describe "Group-aware auth routes" do
  def build_routes
    routes = ActionDispatch::Routing::RouteSet.new
    routes.draw { Rhino::Routes.draw(self) }
    routes
  end

  def recognize(routes, path, host: "example.com", method: :post)
    env = Rack::MockRequest.env_for(path, "HTTP_HOST" => host, "REQUEST_METHOD" => method.to_s.upcase)
    request = ActionDispatch::Request.new(env)
    routes.recognize_path_with_request(request, path, {})
  rescue ActionController::RoutingError => e
    e.message.include?("missing controller") ? :recognized_missing_controller : :not_found
  end

  def recognized?(result)
    result == :recognized_missing_controller || result.is_a?(Hash)
  end

  def dispatch(routes, path, params: {}, host: "example.com", token: nil, method: :post)
    RequestStore.store[:rhino_current_user] = nil
    RequestStore.store[:rhino_organization] = nil
    RequestStore.store[:rhino_route_group] = nil

    env = Rack::MockRequest.env_for(path, "HTTP_HOST" => host, "REQUEST_METHOD" => method.to_s.upcase)
    env["action_dispatch.request.request_parameters"] = params.stringify_keys
    env["CONTENT_TYPE"] = "application/json"
    env["HTTP_ACCEPT"] = "application/json"
    env["HTTP_AUTHORIZATION"] = "Bearer #{token}" if token

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

  # ==================================================================
  # Route recognition
  # ==================================================================

  describe "per-group auth route registration" do
    before do
      Rhino.reset_configuration!
      Rhino.configure do |c|
        c.model :posts, "Post"
        c.route_group :driver, prefix: "driver", auth: true, models: [:posts]
        c.route_group :admin, prefix: "admin", auth: false, models: [:posts]
      end
    end

    it "registers per-group auth routes for auth: true groups" do
      routes = build_routes
      expect(recognized?(recognize(routes, "/api/driver/auth/login"))).to be true
      expect(recognized?(recognize(routes, "/api/driver/auth/logout"))).to be true
      expect(recognized?(recognize(routes, "/api/driver/auth/register"))).to be true
      expect(recognized?(recognize(routes, "/api/driver/auth/password/recover"))).to be true
      expect(recognized?(recognize(routes, "/api/driver/auth/password/reset"))).to be true
    end

    it "does NOT register auth routes for groups without auth: true" do
      routes = build_routes
      expect(recognize(routes, "/api/admin/auth/login")).to eq(:not_found)
    end

    it "keeps the legacy unprefixed auth routes working" do
      routes = build_routes
      expect(recognized?(recognize(routes, "/api/auth/login"))).to be true
      expect(recognized?(recognize(routes, "/api/auth/logout"))).to be true
    end

    it "tags the per-group auth route with the group's route_group default" do
      routes = build_routes
      result = recognize(routes, "/api/driver/auth/login")
      expect(result).to be_a(Hash)
      expect(result[:route_group]).to eq("driver")
    end
  end

  # ==================================================================
  # Group-aware login with membership enforcement
  # ==================================================================

  describe "login resolves the correct group (enforcement ON)" do
    let!(:role) { Role.create!(name: "All", slug: "all-#{SecureRandom.hex(4)}", permissions: ["*"]) }

    before do
      Rhino.reset_configuration!
      Rhino.configure do |c|
        c.model :posts, "Post"
        c.route_group :driver, prefix: "driver", auth: true, models: [:posts]
        c.auth = { enforce_group_membership: true }
      end
    end

    it "allows login on the group route when the user is a member" do
      user = User.create!(name: "D", email: "d@x.com", api_token: "x")
      UserRole.create!(user: user, role: role, organization: nil, route_group: "driver")

      routes = build_routes
      status, body = dispatch(routes, "/api/driver/auth/login",
                              params: { email: "d@x.com", password: "password" })
      expect(status).to eq(200)
      expect(body["token"]).to be_present
    end

    it "denies login (403) on the group route for a non-member (wrong group)" do
      user = User.create!(name: "D", email: "d@x.com", api_token: "x")
      UserRole.create!(user: user, role: role, organization: nil, route_group: "admin")

      routes = build_routes
      status, body = dispatch(routes, "/api/driver/auth/login",
                              params: { email: "d@x.com", password: "password" })
      expect(status).to eq(403)
      expect(body["message"]).to eq("You are not a member of this group")
    end

    it "still rejects invalid credentials with 401 before any membership check" do
      routes = build_routes
      status, _ = dispatch(routes, "/api/driver/auth/login",
                           params: { email: "nobody@x.com", password: "password" })
      expect(status).to eq(401)
    end
  end

  # ==================================================================
  # Domain-based per-group auth
  # ==================================================================

  describe "domain-based group auth" do
    before do
      Rhino.reset_configuration!
      Rhino.configure do |c|
        c.model :posts, "Post"
        c.route_group :admin, prefix: "", domain: "admin.example.com", auth: true, models: [:posts]
      end
    end

    it "registers the auth route on the matching host only" do
      routes = build_routes
      expect(recognized?(recognize(routes, "/api/auth/login", host: "admin.example.com"))).to be true
    end

    it "resolves route_group == 'admin' on the group's domain (not shadowed by legacy)" do
      routes = build_routes
      result = recognize(routes, "/api/auth/login", host: "admin.example.com")
      # The domain-constrained admin auth route is registered BEFORE the legacy
      # unprefixed set, so on the admin host it wins and route_group resolves to
      # "admin" — otherwise hooks/membership would never engage.
      expect(result).to be_a(Hash)
      expect(result[:route_group]).to eq("admin")
    end

    it "still resolves the legacy route_group on a non-admin host" do
      routes = build_routes
      result = recognize(routes, "/api/auth/login", host: "other.example.com")
      expect(result).to be_a(Hash)
      # No :default group configured here, so the legacy route carries nil.
      expect(result[:route_group]).to be_nil
    end
  end
end
