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
  # §11.1 — single auth-enabled empty-prefix + no-domain group IS the legacy
  # auth: the legacy /api/auth/* set adopts its route_group (no colliding set).
  # ==================================================================

  describe "empty-prefix + no-domain auth group adopts the legacy auth routes (§11.1)" do
    before do
      Rhino.reset_configuration!
      Rhino.configure do |c|
        c.model :posts, "Post"
        # :default has auth: true, empty prefix, no domain — it IS the legacy auth.
        c.route_group :default, prefix: "", auth: true, models: [:posts]
      end
    end

    it "resolves the legacy /api/auth/login to that group's route_group" do
      routes = build_routes
      result = recognize(routes, "/api/auth/login")
      expect(result).to be_a(Hash)
      expect(result[:route_group]).to eq("default")
    end

    it "does NOT register a second colliding /api/auth route set" do
      routes = build_routes
      # Exactly one route should match the unprefixed auth login path.
      matching = routes.routes.select do |r|
        r.path.spec.to_s == "/api/auth/login(.:format)"
      end
      expect(matching.length).to eq(1)
    end

    it "fires the group's hooks at login (no spurious 403, hook context carries the group)" do
      seen = []
      hook_class = Class.new(Rhino::AuthHooks) do
        define_method(:after_login) do |_user, context = {}|
          seen << context[:route_group]
        end
      end

      Rhino.reset_configuration!
      Rhino.configure do |c|
        c.model :posts, "Post"
        c.route_group :default, prefix: "", auth: true, hooks: hook_class, models: [:posts]
      end

      User.create!(name: "D", email: "leg@x.com", api_token: "x")

      routes = build_routes
      status, body = dispatch(routes, "/api/auth/login",
                              params: { email: "leg@x.com", password: "password" })
      expect(status).to eq(200)
      expect(body["token"]).to be_present
      expect(seen).to eq(["default"])
    end
  end

  describe "empty-prefix + no-domain auth group resolves membership at legacy login (enforcement ON)" do
    let!(:role) { Role.create!(name: "All", slug: "all-#{SecureRandom.hex(4)}", permissions: ["*"]) }

    before do
      Rhino.reset_configuration!
      Rhino.configure do |c|
        c.model :posts, "Post"
        c.route_group :default, prefix: "", auth: true, models: [:posts]
        c.auth = { enforce_group_membership: true }
      end
    end

    it "allows legacy login for a member of the default group (no spurious 403)" do
      user = User.create!(name: "D", email: "m@x.com", api_token: "x")
      UserRole.create!(user: user, role: role, organization: nil, route_group: "default")

      routes = build_routes
      status, body = dispatch(routes, "/api/auth/login",
                              params: { email: "m@x.com", password: "password" })
      expect(status).to eq(200)
      expect(body["token"]).to be_present
    end

    it "denies legacy login (403) for a non-member of the default group" do
      user = User.create!(name: "D", email: "nm@x.com", api_token: "x")
      UserRole.create!(user: user, role: role, organization: nil, route_group: "other")

      routes = build_routes
      status, body = dispatch(routes, "/api/auth/login",
                              params: { email: "nm@x.com", password: "password" })
      expect(status).to eq(403)
      expect(body["message"]).to eq("You are not a member of this group")
    end
  end

  describe "prefixed/domain auth groups still get their own routes alongside an empty-prefix legacy group" do
    before do
      Rhino.reset_configuration!
      Rhino.configure do |c|
        c.model :posts, "Post"
        c.route_group :default, prefix: "", auth: true, models: [:posts]
        c.route_group :driver, prefix: "driver", auth: true, models: [:posts]
      end
    end

    it "keeps the prefixed group's own per-group auth route with its route_group" do
      routes = build_routes
      result = recognize(routes, "/api/driver/auth/login")
      expect(result).to be_a(Hash)
      expect(result[:route_group]).to eq("driver")
    end

    it "the legacy route still adopts the empty-prefix group's route_group" do
      routes = build_routes
      result = recognize(routes, "/api/auth/login")
      expect(result[:route_group]).to eq("default")
    end
  end

  describe "no auth-enabled group → legacy auth is unchanged (group-less)" do
    before do
      Rhino.reset_configuration!
      Rhino.configure do |c|
        c.model :posts, "Post"
        c.route_group :driver, prefix: "driver", auth: false, models: [:posts]
      end
    end

    it "the legacy /api/auth/login carries no route_group" do
      routes = build_routes
      result = recognize(routes, "/api/auth/login")
      expect(result).to be_a(Hash)
      expect(result[:route_group]).to be_nil
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
