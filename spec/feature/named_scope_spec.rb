# frozen_string_literal: true

require "spec_helper"
require "rhino/controllers/resources_controller"
require "ostruct"

# --------------------------------------------------------------------------
# Named-scope test scope classes + model (defined against the existing
# `posts` table from spec_helper).
# --------------------------------------------------------------------------

module Scopes
  # ResourceScope subclass: reads the current user via RequestStore (through the
  # ResourceScope#user helper) and fails closed (.none) when there is no user.
  class AvailableForDriversScope < Rhino::ResourceScope
    def apply(relation)
      return relation.none unless user

      relation.where(status: "active", user_id: user.id)
    end
  end
end

# Model bound to the shared `posts` table. Named `NamedScopePost` so HasAutoScope's
# convention lookup (`Scopes::NamedScopePostScope`) finds nothing — no global auto
# scope is applied, keeping these tests focused on ?scope= behavior.
class NamedScopePost < ActiveRecord::Base
  include Rhino::HasRhino
  include Rhino::HasValidation
  include Rhino::HidableColumns
  include Rhino::HasAutoScope
  include Discard::Model

  self.table_name = "posts"

  belongs_to :organization, optional: true
  belongs_to :user, optional: true

  scope :active, -> { where(status: "active") }

  rhino_filters :title, :status, :user_id
  rhino_sorts :title, :created_at, :status
  rhino_search :title, :content
  rhino_includes :user

  rhino_scopes :active, available_for_drivers: Scopes::AvailableForDriversScope
  rhino_default_scope :active

  validates :title, length: { maximum: 255 }, allow_nil: true
end

class NamedScopePostPolicy < Rhino::ResourcePolicy
  self.resource_slug = "named_scope_posts"
end

RSpec.describe "Named scopes (?scope=)" do
  # ------------------------------------------------------------------
  # Harness (mirrors resources_controller_spec.rb)
  # ------------------------------------------------------------------

  def call_action(action, params: {}, headers: {}, env_overrides: {})
    controller = Rhino::ResourcesController.new

    method = case action.to_s
             when "index", "show", "trashed" then "GET"
             when "store", "restore", "nested" then "POST"
             when "update" then "PUT"
             when "destroy", "force_delete" then "DELETE"
             else "GET"
             end

    env = Rack::MockRequest.env_for("/api/named_scope_posts", method: method)
    env["action_dispatch.request.request_parameters"] = params.stringify_keys
    env["action_dispatch.request.path_parameters"] = {
      controller: "rhino/resources",
      action: action.to_s,
      model_slug: "named_scope_posts"
    }.merge(params.slice(:id, :model_slug).transform_keys(&:to_s).transform_keys(&:to_sym))

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
    Role.create!({ name: "Admin", slug: "admin-#{SecureRandom.uuid}", permissions: ["*"] }.merge(attrs))
  end

  def create_user_in_org(org, role, user_attrs = {})
    user = create_user(user_attrs)
    UserRole.create!(user: user, organization: org, role: role)
    user
  end

  def create_named_post(attrs = {})
    NamedScopePost.create!({ title: "Post", status: "active" }.merge(attrs))
  end

  # Register the `named_scope_posts` slug on top of the base config the spec_helper
  # before(:each) installs.
  before do
    Rhino.config.model :named_scope_posts, "NamedScopePost"
    # Register `users` so the ?include=user auth path (Rhino::ResourcePolicy#index?
    # for User) can resolve a slug and pass for a "*"-permissioned user.
    Rhino.config.model :users, "User"
  end

  # ==================================================================
  # 1. Default scope applied when no ?scope
  # ==================================================================

  describe "default scope (no ?scope param)" do
    it "applies the declared default scope automatically" do
      user = create_user
      create_named_post(title: "Active", status: "active")
      create_named_post(title: "Draft", status: "draft")

      response = call_action(:index,
        params: { model_slug: "named_scope_posts" },
        headers: auth_headers(user))

      expect(response.status).to eq(200)
      titles = response.body["data"].map { |p| p["title"] }
      expect(titles).to eq(["Active"])
    end
  end

  # ==================================================================
  # 2. Explicit ?scope=availableForDrivers → acting user's active rows
  # ==================================================================

  describe "explicit ?scope=availableForDrivers" do
    it "returns only the acting user's active rows" do
      user = create_user
      other = create_user
      mine   = create_named_post(title: "Mine",   status: "active", user_id: user.id)
      _other = create_named_post(title: "Theirs", status: "active", user_id: other.id)
      _draft = create_named_post(title: "MineDraft", status: "draft", user_id: user.id)

      response = call_action(:index,
        params: { model_slug: "named_scope_posts", scope: "availableForDrivers" },
        headers: auth_headers(user))

      expect(response.status).to eq(200)
      titles = response.body["data"].map { |p| p["title"] }
      expect(titles).to eq(["Mine"])
    end
  end

  # ==================================================================
  # 3. Default scope requestable by name even when not in rhino_scopes list
  # ==================================================================

  describe "default scope requestable by name when not whitelisted" do
    # A model that declares a default scope but does NOT list it in rhino_scopes.
    before do
      stub_const("DefaultOnlyPost", Class.new(ActiveRecord::Base) do
        include Rhino::HasRhino
        include Rhino::HasValidation
        include Rhino::HidableColumns
        include Rhino::HasAutoScope
        self.table_name = "posts"
        belongs_to :user, optional: true
        scope :active, -> { where(status: "active") }
        rhino_default_scope :active
        # note: :active intentionally omitted from rhino_scopes
      end)
      Rhino.config.model :default_only_posts, "DefaultOnlyPost"
    end

    it "returns 200 filtered when ?scope=active names the default" do
      user = create_user
      DefaultOnlyPost.create!(title: "Active", status: "active")
      DefaultOnlyPost.create!(title: "Draft", status: "draft")

      response = call_action(:index,
        params: { model_slug: "default_only_posts", scope: "active" },
        headers: auth_headers(user))

      expect(response.status).to eq(200)
      titles = response.body["data"].map { |p| p["title"] }
      expect(titles).to eq(["Active"])
    end
  end

  # ==================================================================
  # 4. Non-whitelisted scope → 403
  # ==================================================================

  describe "non-whitelisted scope" do
    it "returns 403 with the exact message" do
      user = create_user
      create_named_post(status: "active")

      response = call_action(:index,
        params: { model_slug: "named_scope_posts", scope: "secret" },
        headers: auth_headers(user))

      expect(response.status).to eq(403)
      expect(response.body["message"]).to eq("Scope 'secret' is not allowed")
    end
  end

  # ==================================================================
  # 5. camelCase underscored; 403 echoes the original wire name
  # ==================================================================

  describe "camelCase wire name handling" do
    it "underscores availableForDrivers → available_for_drivers and resolves it" do
      user = create_user
      create_named_post(title: "Mine", status: "active", user_id: user.id)

      response = call_action(:index,
        params: { model_slug: "named_scope_posts", scope: "availableForDrivers" },
        headers: auth_headers(user))

      expect(response.status).to eq(200)
      expect(response.body["data"].map { |p| p["title"] }).to eq(["Mine"])
    end

    it "echoes the original camelCase wire name in the 403 for an unknown scope" do
      user = create_user

      response = call_action(:index,
        params: { model_slug: "named_scope_posts", scope: "notAThing" },
        headers: auth_headers(user))

      expect(response.status).to eq(403)
      expect(response.body["message"]).to eq("Scope 'notAThing' is not allowed")
    end
  end

  # ==================================================================
  # 6. Composes with filter
  # ==================================================================

  describe "composition with filter" do
    it "scope + ?filter[title]= narrows within the scope" do
      user = create_user
      create_named_post(title: "Keep", status: "active")
      create_named_post(title: "Drop", status: "active")
      create_named_post(title: "Keep", status: "draft")

      response = call_action(:index,
        params: { model_slug: "named_scope_posts", scope: "active", filter: { title: "Keep" } },
        headers: auth_headers(user))

      expect(response.status).to eq(200)
      titles = response.body["data"].map { |p| p["title"] }
      expect(titles).to eq(["Keep"])
    end
  end

  # ==================================================================
  # 7. Composes with sort
  # ==================================================================

  describe "composition with sort" do
    it "scope + ?sort orders the scoped rows" do
      user = create_user
      create_named_post(title: "B", status: "active")
      create_named_post(title: "A", status: "active")
      create_named_post(title: "Z", status: "draft")

      response = call_action(:index,
        params: { model_slug: "named_scope_posts", scope: "active", sort: "title" },
        headers: auth_headers(user))

      expect(response.status).to eq(200)
      expect(response.body["data"].map { |p| p["title"] }).to eq(["A", "B"])
    end
  end

  # ==================================================================
  # 8. Composes with search
  # ==================================================================

  describe "composition with search" do
    it "scope + ?search restricts to the scoped rows matching the term" do
      user = create_user
      create_named_post(title: "Rails Guide", status: "active")
      create_named_post(title: "Ruby Guide", status: "active")
      create_named_post(title: "Rails Guide", status: "draft")

      response = call_action(:index,
        params: { model_slug: "named_scope_posts", scope: "active", search: "rails" },
        headers: auth_headers(user))

      expect(response.status).to eq(200)
      titles = response.body["data"].map { |p| p["title"] }
      expect(titles).to eq(["Rails Guide"])
    end
  end

  # ==================================================================
  # 9. Composes with pagination — total is the SCOPED count
  # ==================================================================

  describe "composition with pagination" do
    it "paginates over the scoped set and reports the scoped total" do
      user = create_user
      5.times { |i| create_named_post(title: "Active #{i}", status: "active") }
      3.times { |i| create_named_post(title: "Draft #{i}", status: "draft") }

      response = call_action(:index,
        params: { model_slug: "named_scope_posts", scope: "active", per_page: "2" },
        headers: auth_headers(user))

      expect(response.status).to eq(200)
      expect(response.body["data"].length).to eq(2)
      expect(response.headers["X-Total"]).to eq("5")
      expect(response.headers["X-Per-Page"]).to eq("2")
      expect(response.headers["X-Last-Page"]).to eq("3")
    end
  end

  # ==================================================================
  # 10. Org isolation
  # ==================================================================

  describe "organization isolation" do
    it "never returns another org's rows through ?scope=availableForDrivers" do
      org_a = create_organization
      org_b = create_organization
      user = create_user

      mine_a = create_named_post(title: "OrgA Mine",  status: "active", user_id: user.id, organization_id: org_a.id)
      _mine_b = create_named_post(title: "OrgB Mine", status: "active", user_id: user.id, organization_id: org_b.id)

      response = call_action(:index,
        params: { model_slug: "named_scope_posts", scope: "availableForDrivers" },
        headers: auth_headers(user),
        env_overrides: { "rhino.organization" => org_a })

      expect(response.status).to eq(200)
      titles = response.body["data"].map { |p| p["title"] }
      expect(titles).to eq(["OrgA Mine"])
      expect(titles).not_to include("OrgB Mine")
    end
  end

  # ==================================================================
  # 11. Current user injected — different users, different results
  # ==================================================================

  describe "current user injection" do
    it "returns different result sets for different users" do
      user1 = create_user
      user2 = create_user
      p1 = create_named_post(title: "U1", status: "active", user_id: user1.id)
      p2 = create_named_post(title: "U2", status: "active", user_id: user2.id)

      resp1 = call_action(:index,
        params: { model_slug: "named_scope_posts", scope: "availableForDrivers" },
        headers: auth_headers(user1))
      resp2 = call_action(:index,
        params: { model_slug: "named_scope_posts", scope: "availableForDrivers" },
        headers: auth_headers(user2))

      expect(resp1.body["data"].map { |p| p["title"] }).to eq(["U1"])
      expect(resp2.body["data"].map { |p| p["title"] }).to eq(["U2"])
    end
  end

  # ==================================================================
  # 12. Fail-closed when user is nil
  # ==================================================================

  describe "fail-closed when no current user" do
    it "the ResourceScope returns .none when RequestStore has no user" do
      RequestStore.store[:rhino_current_user] = nil
      create_named_post(title: "Orphan", status: "active")

      result = Scopes::AvailableForDriversScope.new.apply(NamedScopePost.all)

      expect(result.to_a).to eq([])
    end
  end

  # ==================================================================
  # 13. show is NOT scoped (default + include build path)
  # ==================================================================

  describe "show is never scoped" do
    it "returns a record excluded by the default scope" do
      user = create_user
      post = create_named_post(title: "Draft Show", status: "draft")

      response = call_action(:show,
        params: { model_slug: "named_scope_posts", id: post.id },
        headers: auth_headers(user))

      expect(response.status).to eq(200)
      expect(response.body["title"]).to eq("Draft Show")
    end

    it "returns a non-active record even through the ?include= build path" do
      user = create_user
      # A draft (excluded by the default `active` scope) OWNED by the acting user,
      # with a non-blank, resolving include so `show` runs the QueryBuilder.build
      # path: model_class.where(id:) → build → to_scope.first!. If that builder were
      # ever gated with named_scopes: true, the default active scope would exclude
      # this draft and first! would raise RecordNotFound → not 200. This asserts the
      # regression guard: show must stay unscoped through the include build path.
      draft = create_named_post(title: "Draft Include", status: "draft", user_id: user.id)

      response = call_action(:show,
        params: { model_slug: "named_scope_posts", id: draft.id, include: "user" },
        headers: auth_headers(user))

      expect(response.status).to eq(200)
      expect(response.body["title"]).to eq("Draft Include")
    end
  end

  # ==================================================================
  # 14. ?scope on show is ignored (not 403)
  # ==================================================================

  describe "?scope on show is ignored" do
    it "does not 403 on an unknown scope; returns the record" do
      user = create_user
      post = create_named_post(title: "Show Bogus", status: "draft")

      response = call_action(:show,
        params: { model_slug: "named_scope_posts", id: post.id, scope: "bogus" },
        headers: auth_headers(user))

      expect(response.status).to eq(200)
      expect(response.body["title"]).to eq("Show Bogus")
    end
  end

  # ==================================================================
  # 14b. store strips ?scope from the written params
  # ==================================================================

  describe "store ignores ?scope" do
    it "creates the record and never writes a scope attribute" do
      user = create_user

      response = call_action(:store,
        params: { model_slug: "named_scope_posts", title: "Created", status: "active", scope: "active" },
        headers: auth_headers(user))

      # 2xx (created) with no ActiveModel::UnknownAttributeError from a stray :scope.
      expect(response.status).to eq(201)
      expect(response.body["title"]).to eq("Created")

      record = NamedScopePost.find(response.body["id"])
      expect(record.title).to eq("Created")
      expect(record.attributes).not_to have_key("scope")
    end
  end

  # ==================================================================
  # 15. trashed honors scope
  # ==================================================================

  describe "trashed honors scope" do
    it "returns only discarded + active rows for ?scope=active" do
      user = create_user
      p1 = create_named_post(title: "Trashed Active", status: "active"); p1.discard!
      p2 = create_named_post(title: "Trashed Draft",  status: "draft");  p2.discard!
      _p3 = create_named_post(title: "Live Active",   status: "active")

      response = call_action(:trashed,
        params: { model_slug: "named_scope_posts", scope: "active" },
        headers: auth_headers(user))

      expect(response.status).to eq(200)
      titles = response.body["data"].map { |p| p["title"] }
      expect(titles).to eq(["Trashed Active"])
    end
  end

  # ==================================================================
  # 16. Symbol-scope path preserves org scoping
  # ==================================================================

  describe "symbol scope preserves org scoping" do
    it "merges the AR scope without dropping the org filter" do
      org_a = create_organization
      org_b = create_organization
      user = create_user

      _a = create_named_post(title: "OrgA Active", status: "active", organization_id: org_a.id)
      _b = create_named_post(title: "OrgB Active", status: "active", organization_id: org_b.id)

      response = call_action(:index,
        params: { model_slug: "named_scope_posts", scope: "active" },
        headers: auth_headers(user),
        env_overrides: { "rhino.organization" => org_a })

      expect(response.status).to eq(200)
      titles = response.body["data"].map { |p| p["title"] }
      expect(titles).to eq(["OrgA Active"])
      expect(titles).not_to include("OrgB Active")
    end
  end

  # ==================================================================
  # 17. ResourceScope-class path receives the user
  # ==================================================================

  describe "ResourceScope class receives the current user" do
    it "different users get different results via the scope class" do
      user1 = create_user
      user2 = create_user
      create_named_post(title: "For U1", status: "active", user_id: user1.id)
      create_named_post(title: "For U2", status: "active", user_id: user2.id)

      r1 = call_action(:index,
        params: { model_slug: "named_scope_posts", scope: "availableForDrivers" },
        headers: auth_headers(user1))
      r2 = call_action(:index,
        params: { model_slug: "named_scope_posts", scope: "availableForDrivers" },
        headers: auth_headers(user2))

      expect(r1.body["data"].map { |p| p["title"] }).to eq(["For U1"])
      expect(r2.body["data"].map { |p| p["title"] }).to eq(["For U2"])
    end
  end

  # ==================================================================
  # 18. Boot safety — error class is required
  # ==================================================================

  describe "boot safety" do
    it "Rhino::ScopeNotAllowedError is defined (required at load)" do
      expect { Rhino::ScopeNotAllowedError }.not_to raise_error
      expect(Rhino::ScopeNotAllowedError.ancestors).to include(StandardError)
    end
  end

  # ==================================================================
  # Direct builder assertions (must pass named_scopes: true explicitly)
  # ==================================================================

  describe "QueryBuilder gate" do
    it "does NOT apply the scope unless named_scopes: true" do
      create_named_post(title: "Active", status: "active")
      create_named_post(title: "Draft", status: "draft")

      builder = Rhino::QueryBuilder.new(NamedScopePost, params: {}).build
      expect(builder.to_scope.count).to eq(2)
    end

    it "applies the default scope when named_scopes: true" do
      create_named_post(title: "Active", status: "active")
      create_named_post(title: "Draft", status: "draft")

      builder = Rhino::QueryBuilder.new(NamedScopePost, params: {}, named_scopes: true).build
      expect(builder.to_scope.map(&:title)).to eq(["Active"])
    end

    it "raises ScopeNotAllowedError for an unknown scope when named_scopes: true" do
      expect do
        Rhino::QueryBuilder.new(NamedScopePost, params: { scope: "nope" }, named_scopes: true).build
      end.to raise_error(Rhino::ScopeNotAllowedError, "nope")
    end
  end
end
