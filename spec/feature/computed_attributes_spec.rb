# frozen_string_literal: true

require "spec_helper"
require "rhino/controllers/resources_controller"
require "rhino/routes"
require "ostruct"

# --------------------------------------------------------------------------
# Counter — proves laziness (nothing is evaluated unless it was asked for)
# --------------------------------------------------------------------------

module ComputedCallCounter
  module_function

  def calls
    @calls ||= Hash.new(0)
  end

  def hit(name)
    calls[name.to_s] += 1
  end

  def count(name)
    calls[name.to_s]
  end

  def reset!
    @calls = Hash.new(0)
  end
end

# --------------------------------------------------------------------------
# Models (all bound to the shared `posts` table from spec_helper)
# --------------------------------------------------------------------------

# The canonical case: aggregates over a collection, plus opt-in per-row
# attributes and a legacy always-on one.
class ComputedPost < ActiveRecord::Base
  include Rhino::HasRhino
  include Rhino::HasValidation
  include Rhino::HidableColumns
  include Rhino::HasAutoScope
  include Discard::Model

  self.table_name = "posts"

  belongs_to :organization, optional: true
  belongs_to :user, optional: true

  scope :mine, -> { where(user_id: RequestStore.store[:rhino_current_user]&.id) }

  rhino_filters :status, :user_id
  rhino_sorts :title
  rhino_search :title
  rhino_scopes :mine

  validates :title, length: { maximum: 255 }, allow_nil: true

  # Legacy always-on computed attribute — must keep working untouched.
  def rhino_computed_attributes
    { "legacy_label" => "always-here" }
  end

  def rhino_record_computed_attributes
    {
      "title_length" => lambda { |record, _user|
        ComputedCallCounter.hit("title_length")
        record.title.to_s.length
      },
      "expensive_flag" => lambda { |record, _user|
        ComputedCallCounter.hit("expensive_flag")
        record.status == "active"
      },
      "viewer_id" => ->(_record, user) { user&.id },
      "no_args" => -> { "zero-arity" },
      "one_arg" => ->(record) { record.title },
      "secret_note" => ->(_record, _user) { "classified" },
      "literal" => "not-a-callable"
    }
  end

  def self.rhino_collection_computed_attributes
    {
      "active_count" => lambda { |scope, _user|
        ComputedCallCounter.hit("active_count")
        scope.where(status: "active").count
      },
      "blocked_count" => lambda { |scope, _user|
        ComputedCallCounter.hit("blocked_count")
        scope.where(status: "blocked").count
      },
      "total_count" => ->(scope, _user) { scope.count },
      "viewer_id" => ->(_scope, user) { user&.id },
      "no_args" => -> { "zero-arity" },
      "one_arg" => ->(scope) { scope.count },
      "secret_total" => ->(scope, _user) { scope.count }
    }
  end
end

# Declares nothing — proves the feature is entirely opt-in.
class PlainComputedPost < ActiveRecord::Base
  include Rhino::HasRhino
  include Rhino::HasValidation
  include Rhino::HidableColumns
  include Rhino::HasAutoScope

  self.table_name = "posts"

  belongs_to :organization, optional: true
end

# Declares aggregates but opts the action out.
class ExceptedComputedPost < ActiveRecord::Base
  include Rhino::HasRhino
  include Rhino::HasValidation
  include Rhino::HidableColumns
  include Rhino::HasAutoScope

  self.table_name = "posts"

  belongs_to :organization, optional: true

  rhino_except_actions :computed

  def self.rhino_collection_computed_attributes
    { "total_count" => ->(scope, _user) { scope.count } }
  end
end

# Empty declaration must not register the route.
class EmptyComputedPost < ActiveRecord::Base
  include Rhino::HasRhino
  include Rhino::HasValidation
  include Rhino::HidableColumns
  include Rhino::HasAutoScope

  self.table_name = "posts"

  belongs_to :organization, optional: true

  def self.rhino_collection_computed_attributes
    {}
  end
end

# Multi-tenant model — aggregates must never cross the org boundary.
class TenantComputedPost < ActiveRecord::Base
  include Rhino::HasRhino
  include Rhino::HasValidation
  include Rhino::HidableColumns
  include Rhino::HasAutoScope
  include Rhino::BelongsToOrganization

  self.table_name = "posts"

  belongs_to :user, optional: true

  rhino_filters :status

  def rhino_record_computed_attributes
    { "shouty_title" => ->(record, _user) { record.title.to_s.upcase } }
  end

  def self.rhino_collection_computed_attributes
    {
      "total_count" => ->(scope, _user) { scope.count },
      "active_count" => ->(scope, _user) { scope.where(status: "active").count }
    }
  end
end

# INDIRECT tenancy: no organization_id of its own — owned through
# ComputedIndirectPost -> ComputedIndirectBlog -> organization. The framework
# must hand the callable a relation already scoped through that chain.
ActiveRecord::Schema.define do
  create_table :computed_indirect_blogs, force: true do |t|
    t.references :organization, foreign_key: true
    t.string :title
    t.timestamps
  end

  create_table :computed_indirect_posts, force: true do |t|
    t.references :computed_indirect_blog, null: false, foreign_key: true
    t.string :title
    t.timestamps
  end

  create_table :computed_indirect_comments, force: true do |t|
    t.references :computed_indirect_post, null: false, foreign_key: true
    t.text :body
    t.string :status, default: "ok"
    t.timestamps
  end
end

class ComputedIndirectBlog < ActiveRecord::Base
  include Rhino::HasRhino
  include Rhino::HasValidation
  include Rhino::HidableColumns

  belongs_to :organization
end

class ComputedIndirectPost < ActiveRecord::Base
  include Rhino::HasRhino
  include Rhino::HasValidation
  include Rhino::HidableColumns

  belongs_to :computed_indirect_blog
end

class ComputedIndirectComment < ActiveRecord::Base
  include Rhino::HasRhino
  include Rhino::HasValidation
  include Rhino::HidableColumns

  belongs_to :computed_indirect_post

  rhino_filters :status

  def rhino_record_computed_attributes
    { "shouty_body" => ->(record, _user) { record.body.to_s.upcase } }
  end

  def self.rhino_collection_computed_attributes
    {
      "total_count" => ->(scope, _user) { scope.count },
      "flagged_count" => ->(scope, _user) { scope.where(status: "flagged").count }
    }
  end
end

# --------------------------------------------------------------------------
# Policies
# --------------------------------------------------------------------------

class ComputedPostPolicy < Rhino::ResourcePolicy
  self.resource_slug = "computed_posts"
end

class BlacklistComputedPolicy < Rhino::ResourcePolicy
  self.resource_slug = "computed_posts"

  def hidden_attributes_for_show(_user)
    %w[secret_note secret_total]
  end
end

class WhitelistComputedPolicy < Rhino::ResourcePolicy
  self.resource_slug = "computed_posts"

  def permitted_attributes_for_show(_user)
    %w[id title status title_length active_count]
  end
end

class DenyIndexComputedPolicy < Rhino::ResourcePolicy
  self.resource_slug = "computed_posts"

  def index?
    false
  end
end

RSpec.describe "Computed attributes" do
  # ------------------------------------------------------------------
  # Harness (mirrors named_scope_spec.rb)
  # ------------------------------------------------------------------

  def call_action(action, slug: "computed_posts", params: {}, headers: {})
    controller = Rhino::ResourcesController.new

    method = case action.to_s
             when "index", "show", "trashed", "computed" then "GET"
             when "store", "restore" then "POST"
             when "update" then "PUT"
             when "destroy", "force_delete" then "DELETE"
             else "GET"
             end

    env = Rack::MockRequest.env_for("/api/#{slug}", method: method)
    env["action_dispatch.request.request_parameters"] = params.stringify_keys
    env["action_dispatch.request.path_parameters"] = {
      controller: "rhino/resources",
      action: action.to_s,
      model_slug: slug
    }.merge(params.slice(:id).transform_keys(&:to_sym))

    headers.each do |key, value|
      env["HTTP_#{key.upcase.tr('-', '_')}"] = value
    end

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

  def create_user_in_org(org, user_attrs = {})
    user = create_user(user_attrs)
    UserRole.create!(user: user, organization: org, role: create_role)
    user
  end

  def seed_posts(user: nil)
    ComputedPost.create!(title: "Alpha", status: "active", user_id: user&.id)
    ComputedPost.create!(title: "Beta", status: "active", user_id: user&.id)
    ComputedPost.create!(title: "Gamma", status: "active")
    ComputedPost.create!(title: "Delta", status: "blocked")
    ComputedPost.create!(title: "Epsilon", status: "pending")
  end

  before do
    ComputedCallCounter.reset!
    Rhino.config.model :computed_posts, "ComputedPost"
    Rhino.config.model :plain_posts, "PlainComputedPost"
    Rhino.config.model :excepted_posts, "ExceptedComputedPost"
    Rhino.config.model :empty_posts, "EmptyComputedPost"
    Rhino.config.model :tenant_posts, "TenantComputedPost"
    Rhino.config.model :icomments, "ComputedIndirectComment"
  end

  # ==================================================================
  # COLLECTION-LEVEL: GET /api/{slug}/computed?attributes=
  # ==================================================================

  describe "GET /computed" do
    it "returns the selected aggregates" do
      user = create_user
      seed_posts

      response = call_action(:computed,
        params: { attributes: "active_count,blocked_count" },
        headers: auth_headers(user))

      expect(response.status).to eq(200)
      expect(response.body["data"]).to eq({ "active_count" => 3, "blocked_count" => 1 })
    end

    it "evaluates each attribute exactly once for the whole collection" do
      user = create_user
      seed_posts

      call_action(:computed, params: { attributes: "active_count" }, headers: auth_headers(user))

      expect(ComputedCallCounter.count("active_count")).to eq(1)
      expect(ComputedCallCounter.count("blocked_count")).to eq(0)
    end

    it "returns every permitted attribute when ?attributes is omitted" do
      user = create_user
      seed_posts

      response = call_action(:computed, headers: auth_headers(user))

      expect(response.status).to eq(200)
      expect(response.body["data"].keys).to eq(
        %w[active_count blocked_count total_count viewer_id no_args one_arg secret_total]
      )
    end

    it "treats a blank ?attributes as omitted" do
      user = create_user
      seed_posts

      response = call_action(:computed, params: { attributes: "" }, headers: auth_headers(user))

      expect(response.status).to eq(200)
      expect(response.body["data"].size).to eq(7)
    end

    it "isolates each callable from the others" do
      user = create_user
      seed_posts

      response = call_action(:computed,
        params: { attributes: "active_count,blocked_count,total_count" },
        headers: auth_headers(user))

      expect(response.body["data"]).to eq(
        { "active_count" => 3, "blocked_count" => 1, "total_count" => 5 }
      )
    end

    it "passes the current user to the callable" do
      user = create_user

      response = call_action(:computed, params: { attributes: "viewer_id" }, headers: auth_headers(user))

      expect(response.body["data"]["viewer_id"]).to eq(user.id)
    end

    it "supports zero-arity and single-arity lambdas" do
      user = create_user
      seed_posts

      response = call_action(:computed, params: { attributes: "no_args,one_arg" }, headers: auth_headers(user))

      expect(response.body["data"]).to eq({ "no_args" => "zero-arity", "one_arg" => 5 })
    end

    it "rejects an undeclared attribute with 403" do
      user = create_user

      response = call_action(:computed,
        params: { attributes: "active_count,nope_count" },
        headers: auth_headers(user))

      expect(response.status).to eq(403)
      expect(response.body["message"]).to eq("Computed attribute 'nope_count' is not allowed")
    end

    it "rejects a non-scalar ?attributes param" do
      user = create_user

      response = call_action(:computed, params: { attributes: %w[active_count] }, headers: auth_headers(user))

      expect(response.status).to eq(403)
      expect(response.body["message"]).to eq("Computed attributes are not allowed")
    end

    it "ignores blank segments and duplicates" do
      user = create_user
      seed_posts

      response = call_action(:computed,
        params: { attributes: " active_count , ,active_count " },
        headers: auth_headers(user))

      expect(response.status).to eq(200)
      expect(response.body["data"]).to eq({ "active_count" => 3 })
      expect(ComputedCallCounter.count("active_count")).to eq(1)
    end

    it "respects ?filter[]" do
      user = create_user
      seed_posts

      response = call_action(:computed,
        params: { attributes: "total_count", filter: { "status" => "active" } },
        headers: auth_headers(user))

      expect(response.status).to eq(200)
      expect(response.body["data"]["total_count"]).to eq(3)
    end

    it "respects ?search" do
      user = create_user
      seed_posts

      response = call_action(:computed,
        params: { attributes: "total_count", search: "Alpha" },
        headers: auth_headers(user))

      expect(response.body["data"]["total_count"]).to eq(1)
    end

    it "respects ?scope" do
      user = create_user
      seed_posts(user: user)

      scoped = call_action(:computed,
        params: { attributes: "total_count", scope: "mine" },
        headers: auth_headers(user))
      unscoped = call_action(:computed, params: { attributes: "total_count" }, headers: auth_headers(user))

      expect(scoped.body["data"]["total_count"]).to eq(2)
      expect(unscoped.body["data"]["total_count"]).to eq(5)
    end

    it "rejects a scope that is not whitelisted" do
      user = create_user

      response = call_action(:computed,
        params: { attributes: "total_count", scope: "nope" },
        headers: auth_headers(user))

      expect(response.status).to eq(403)
      expect(response.body["message"]).to eq("Scope 'nope' is not allowed")
    end

    it "counts exactly the set index would list, discarded rows included" do
      # Discard adds no default scope in Rhino, so index still lists discarded
      # rows. /computed must agree with index rather than invent its own rule.
      user = create_user
      seed_posts
      ComputedPost.find_by(title: "Alpha").discard!

      computed = call_action(:computed, params: { attributes: "total_count" }, headers: auth_headers(user))
      index = call_action(:index, headers: auth_headers(user))

      expect(computed.body["data"]["total_count"]).to eq(index.body["data"].size)
      expect(computed.body["data"]["total_count"]).to eq(5)
    end

    it "counts only kept rows when the model scopes them away" do
      user = create_user
      seed_posts
      ComputedPost.find_by(title: "Alpha").discard!

      response = call_action(:computed,
        params: { attributes: "total_count", scope: "mine" },
        headers: auth_headers(user))

      # ?scope= composes with the aggregate exactly as it does with index.
      expect(response.status).to eq(200)
      expect(response.body["data"]["total_count"]).to eq(0)
    end

    it "is gated by the index? policy" do
      user = create_user
      allow(Rhino::ResourcesController).to receive(:name).and_call_original
      stub_const("ComputedPostPolicy", DenyIndexComputedPolicy)

      response = call_action(:computed, params: { attributes: "total_count" }, headers: auth_headers(user))

      expect(response.status).to eq(403)
    end

    it "requires authentication" do
      seed_posts

      response = call_action(:computed, params: { attributes: "total_count" })

      expect(response.status).to eq(401)
    end
  end

  # ==================================================================
  # COLLECTION-LEVEL: policy gating
  # ==================================================================

  describe "GET /computed policy gating" do
    it "rejects a blacklisted attribute" do
      stub_const("ComputedPostPolicy", BlacklistComputedPolicy)
      user = create_user

      response = call_action(:computed, params: { attributes: "secret_total" }, headers: auth_headers(user))

      expect(response.status).to eq(403)
      expect(response.body["message"]).to eq("Computed attribute 'secret_total' is not allowed")
    end

    it "omits a blacklisted attribute when ?attributes is omitted" do
      stub_const("ComputedPostPolicy", BlacklistComputedPolicy)
      user = create_user
      seed_posts

      response = call_action(:computed, headers: auth_headers(user))

      expect(response.status).to eq(200)
      expect(response.body["data"]).not_to have_key("secret_total")
      expect(response.body["data"]).to have_key("active_count")
    end

    it "rejects an attribute outside the whitelist" do
      stub_const("ComputedPostPolicy", WhitelistComputedPolicy)
      user = create_user
      seed_posts

      allowed = call_action(:computed, params: { attributes: "active_count" }, headers: auth_headers(user))
      denied = call_action(:computed, params: { attributes: "blocked_count" }, headers: auth_headers(user))

      expect(allowed.status).to eq(200)
      expect(denied.status).to eq(403)
    end

    it "returns only whitelisted attributes when ?attributes is omitted" do
      stub_const("ComputedPostPolicy", WhitelistComputedPolicy)
      user = create_user
      seed_posts

      response = call_action(:computed, headers: auth_headers(user))

      expect(response.body["data"]).to eq({ "active_count" => 3 })
    end

    it "gives the same error for unknown and denied names" do
      stub_const("ComputedPostPolicy", WhitelistComputedPolicy)
      user = create_user

      denied = call_action(:computed, params: { attributes: "blocked_count" }, headers: auth_headers(user))
      unknown = call_action(:computed, params: { attributes: "blocked_count_typo" }, headers: auth_headers(user))

      expect(denied.status).to eq(403)
      expect(unknown.status).to eq(403)
      expect(denied.body["message"]).to include("is not allowed")
      expect(unknown.body["message"]).to include("is not allowed")
    end
  end

  # ==================================================================
  # RECORD-LEVEL: ?computed_attributes= on index / show / trashed
  # ==================================================================

  describe "?computed_attributes= on index" do
    it "omits opt-in attributes by default" do
      user = create_user
      seed_posts

      response = call_action(:index, headers: auth_headers(user))

      expect(response.status).to eq(200)
      row = response.body["data"].first
      expect(row).not_to have_key("title_length")
      expect(row).not_to have_key("expensive_flag")
      # Legacy always-on attribute untouched.
      expect(row["legacy_label"]).to eq("always-here")
    end

    it "never evaluates opt-in attributes by default" do
      user = create_user
      seed_posts

      call_action(:index, headers: auth_headers(user))

      expect(ComputedCallCounter.count("title_length")).to eq(0)
      expect(ComputedCallCounter.count("expensive_flag")).to eq(0)
    end

    it "includes only the requested attributes" do
      user = create_user
      seed_posts

      response = call_action(:index,
        params: { computed_attributes: "title_length" },
        headers: auth_headers(user))

      expect(response.status).to eq(200)
      row = response.body["data"].first
      expect(row["title_length"]).to eq(5)
      expect(row).not_to have_key("expensive_flag")
      expect(ComputedCallCounter.count("title_length")).to eq(5)
      expect(ComputedCallCounter.count("expensive_flag")).to eq(0)
    end

    it "supports multiple attributes" do
      user = create_user
      seed_posts

      response = call_action(:index,
        params: { computed_attributes: "title_length,expensive_flag" },
        headers: auth_headers(user))

      row = response.body["data"].first
      expect(row["title_length"]).to eq(5)
      expect(row["expensive_flag"]).to be(true)
    end

    it "passes the current user to the callable" do
      user = create_user
      seed_posts

      response = call_action(:index,
        params: { computed_attributes: "viewer_id" },
        headers: auth_headers(user))

      expect(response.body["data"].first["viewer_id"]).to eq(user.id)
    end

    it "supports zero-arity and single-arity lambdas" do
      user = create_user
      seed_posts

      response = call_action(:index,
        params: { computed_attributes: "no_args,one_arg" },
        headers: auth_headers(user))

      row = response.body["data"].first
      expect(row["no_args"]).to eq("zero-arity")
      expect(row["one_arg"]).to eq("Alpha")
    end

    it "returns non-callable declarations verbatim" do
      user = create_user
      seed_posts

      response = call_action(:index, params: { computed_attributes: "literal" }, headers: auth_headers(user))

      expect(response.body["data"].first["literal"]).to eq("not-a-callable")
    end

    it "rejects an undeclared attribute with 403" do
      user = create_user

      response = call_action(:index,
        params: { computed_attributes: "title_length,made_up" },
        headers: auth_headers(user))

      expect(response.status).to eq(403)
      expect(response.body["message"]).to eq("Computed attribute 'made_up' is not allowed")
    end

    it "rejects a non-scalar param" do
      user = create_user

      response = call_action(:index,
        params: { computed_attributes: %w[title_length] },
        headers: auth_headers(user))

      expect(response.status).to eq(403)
      expect(response.body["message"]).to eq("Computed attributes are not allowed")
    end

    it "treats a blank param as none" do
      user = create_user
      seed_posts

      response = call_action(:index, params: { computed_attributes: "" }, headers: auth_headers(user))

      expect(response.status).to eq(200)
      expect(response.body["data"].first).not_to have_key("title_length")
    end

    it "rejects any selection on a model that declares nothing" do
      user = create_user
      seed_posts

      ok = call_action(:index, slug: "plain_posts", headers: auth_headers(user))
      denied = call_action(:index, slug: "plain_posts",
        params: { computed_attributes: "title_length" },
        headers: auth_headers(user))

      expect(ok.status).to eq(200)
      expect(denied.status).to eq(403)
    end

    it "survives pagination and only evaluates the returned rows" do
      user = create_user
      seed_posts

      response = call_action(:index,
        params: { computed_attributes: "title_length", per_page: 2 },
        headers: auth_headers(user))

      expect(response.status).to eq(200)
      expect(response.body["data"].size).to eq(2)
      expect(response.body["data"].first["title_length"]).to eq(5)
      expect(ComputedCallCounter.count("title_length")).to eq(2)
    end

    it "combines with filters" do
      user = create_user
      seed_posts

      response = call_action(:index,
        params: { computed_attributes: "title_length", filter: { "status" => "blocked" } },
        headers: auth_headers(user))

      expect(response.body["data"].size).to eq(1)
      expect(response.body["data"].first["title_length"]).to eq(5)
    end

    it "combines with a named scope" do
      user = create_user
      seed_posts(user: user)

      response = call_action(:index,
        params: { computed_attributes: "title_length", scope: "mine" },
        headers: auth_headers(user))

      expect(response.body["data"].size).to eq(2)
      expect(response.body["data"].first).to have_key("title_length")
    end
  end

  describe "?computed_attributes= on show" do
    it "includes the requested attribute" do
      user = create_user
      seed_posts
      post = ComputedPost.find_by(title: "Alpha")

      response = call_action(:show,
        params: { id: post.id.to_s, computed_attributes: "title_length" },
        headers: auth_headers(user))

      expect(response.status).to eq(200)
      expect(response.body["title_length"]).to eq(5)
    end

    it "omits opt-in attributes by default" do
      user = create_user
      seed_posts
      post = ComputedPost.find_by(title: "Alpha")

      response = call_action(:show, params: { id: post.id.to_s }, headers: auth_headers(user))

      expect(response.status).to eq(200)
      expect(response.body).not_to have_key("title_length")
    end

    it "rejects an undeclared attribute with 403" do
      user = create_user
      seed_posts
      post = ComputedPost.find_by(title: "Alpha")

      response = call_action(:show,
        params: { id: post.id.to_s, computed_attributes: "made_up" },
        headers: auth_headers(user))

      expect(response.status).to eq(403)
    end
  end

  describe "?computed_attributes= on trashed" do
    it "includes the requested attribute" do
      user = create_user
      seed_posts
      ComputedPost.find_by(title: "Alpha").discard!

      response = call_action(:trashed,
        params: { computed_attributes: "title_length" },
        headers: auth_headers(user))

      expect(response.status).to eq(200)
      expect(response.body["data"].first["title_length"]).to eq(5)
    end

    it "rejects an undeclared attribute with 403" do
      user = create_user

      response = call_action(:trashed,
        params: { computed_attributes: "made_up" },
        headers: auth_headers(user))

      expect(response.status).to eq(403)
    end
  end

  # ==================================================================
  # RECORD-LEVEL: policy gating
  # ==================================================================

  describe "?computed_attributes= policy gating" do
    it "rejects a blacklisted attribute" do
      stub_const("ComputedPostPolicy", BlacklistComputedPolicy)
      user = create_user

      response = call_action(:index,
        params: { computed_attributes: "secret_note" },
        headers: auth_headers(user))

      expect(response.status).to eq(403)
      expect(response.body["message"]).to eq("Computed attribute 'secret_note' is not allowed")
    end

    it "allows a non-blacklisted attribute" do
      stub_const("ComputedPostPolicy", BlacklistComputedPolicy)
      user = create_user
      seed_posts

      response = call_action(:index,
        params: { computed_attributes: "title_length" },
        headers: auth_headers(user))

      expect(response.status).to eq(200)
      expect(response.body["data"].first["title_length"]).to eq(5)
    end

    it "rejects an attribute outside the whitelist" do
      stub_const("ComputedPostPolicy", WhitelistComputedPolicy)
      user = create_user

      response = call_action(:index,
        params: { computed_attributes: "expensive_flag" },
        headers: auth_headers(user))

      expect(response.status).to eq(403)
    end

    it "keeps a whitelisted attribute through serialization" do
      stub_const("ComputedPostPolicy", WhitelistComputedPolicy)
      user = create_user
      seed_posts

      response = call_action(:index,
        params: { computed_attributes: "title_length" },
        headers: auth_headers(user))

      expect(response.status).to eq(200)
      row = response.body["data"].first
      expect(row["title_length"]).to eq(5)
      # The whitelist still strips everything it does not name.
      expect(row).not_to have_key("legacy_label")
      expect(row).not_to have_key("content")
    end
  end

  # ==================================================================
  # MULTI-TENANCY
  # ==================================================================

  describe "multi-tenancy" do
    it "scopes aggregates to the current organization" do
      org = create_organization
      other = create_organization
      user = create_user_in_org(org)
      RequestStore.store[:rhino_organization] = org

      TenantComputedPost.create!(title: "Mine", status: "active", organization_id: org.id)
      TenantComputedPost.create!(title: "Mine2", status: "blocked", organization_id: org.id)
      TenantComputedPost.create!(title: "Theirs", status: "active", organization_id: other.id)
      TenantComputedPost.create!(title: "Theirs2", status: "active", organization_id: other.id)

      response = call_action(:computed, slug: "tenant_posts",
        params: { attributes: "total_count,active_count" },
        headers: auth_headers(user))

      expect(response.status).to eq(200)
      expect(response.body["data"]).to eq({ "total_count" => 2, "active_count" => 1 })
    ensure
      RequestStore.store[:rhino_organization] = nil
    end

    it "applies opt-in attributes under a tenant scope" do
      org = create_organization
      user = create_user_in_org(org)
      RequestStore.store[:rhino_organization] = org

      TenantComputedPost.create!(title: "Mine", status: "active", organization_id: org.id)

      response = call_action(:index, slug: "tenant_posts",
        params: { computed_attributes: "shouty_title" },
        headers: auth_headers(user))

      expect(response.status).to eq(200)
      expect(response.body["data"].first["shouty_title"]).to eq("MINE")
    ensure
      RequestStore.store[:rhino_organization] = nil
    end
  end

  # ==================================================================
  # INDIRECT TENANCY — the leak class fixed in 4.6.1. The framework must
  # hand the callable a relation already scoped through the owner chain.
  # ==================================================================

  describe "indirect (owner-chain) tenancy" do
    # 2 comments reachable from org A (1 flagged), 3 from org B (2 flagged).
    def seed_indirect(org_a, org_b)
      blog_a = ComputedIndirectBlog.create!(organization: org_a, title: "Mine")
      blog_b = ComputedIndirectBlog.create!(organization: org_b, title: "Theirs")
      post_a = ComputedIndirectPost.create!(computed_indirect_blog: blog_a, title: "Mine")
      post_b = ComputedIndirectPost.create!(computed_indirect_blog: blog_b, title: "Theirs")

      ComputedIndirectComment.create!(computed_indirect_post: post_a, body: "mine a", status: "ok")
      ComputedIndirectComment.create!(computed_indirect_post: post_a, body: "mine b", status: "flagged")
      ComputedIndirectComment.create!(computed_indirect_post: post_b, body: "theirs a", status: "flagged")
      ComputedIndirectComment.create!(computed_indirect_post: post_b, body: "theirs b", status: "flagged")
      ComputedIndirectComment.create!(computed_indirect_post: post_b, body: "theirs c", status: "ok")
    end

    it "scopes aggregates through the ownership chain" do
      org_a = create_organization
      org_b = create_organization
      user = create_user_in_org(org_a)
      seed_indirect(org_a, org_b)

      response = call_action(:computed, slug: "icomments",
        params: { organization: org_a.id.to_s, attributes: "total_count,flagged_count" },
        headers: auth_headers(user))

      expect(response.status).to eq(200)
      # 5 rows exist; only the 2 reachable through org A's blog may be counted.
      expect(response.body["data"]).to eq({ "total_count" => 2, "flagged_count" => 1 })
    ensure
      RequestStore.store[:rhino_organization] = nil
    end

    it "matches what index returns for the same org" do
      org_a = create_organization
      org_b = create_organization
      user = create_user_in_org(org_a)
      seed_indirect(org_a, org_b)

      index = call_action(:index, slug: "icomments",
        params: { organization: org_a.id.to_s }, headers: auth_headers(user))
      computed = call_action(:computed, slug: "icomments",
        params: { organization: org_a.id.to_s, attributes: "total_count" }, headers: auth_headers(user))

      expect(computed.body["data"]["total_count"]).to eq(index.body["data"].size)
    ensure
      RequestStore.store[:rhino_organization] = nil
    end

    it "never exposes another org rows through ?computed_attributes=" do
      org_a = create_organization
      org_b = create_organization
      user = create_user_in_org(org_a)
      seed_indirect(org_a, org_b)

      response = call_action(:index, slug: "icomments",
        params: { organization: org_a.id.to_s, computed_attributes: "shouty_body" },
        headers: auth_headers(user))

      expect(response.status).to eq(200)
      expect(response.body["data"].map { |c| c["shouty_body"] }.sort).to eq(["MINE A", "MINE B"])
    ensure
      RequestStore.store[:rhino_organization] = nil
    end

    it "produces disjoint aggregates for two orgs" do
      org_a = create_organization
      org_b = create_organization
      user_a = create_user_in_org(org_a)
      user_b = create_user_in_org(org_b)
      seed_indirect(org_a, org_b)

      mine = call_action(:computed, slug: "icomments",
        params: { organization: org_a.id.to_s, attributes: "total_count" }, headers: auth_headers(user_a))

      theirs = call_action(:computed, slug: "icomments",
        params: { organization: org_b.id.to_s, attributes: "total_count" }, headers: auth_headers(user_b))

      expect(mine.body["data"]["total_count"]).to eq(2)
      expect(theirs.body["data"]["total_count"]).to eq(3)
    ensure
      RequestStore.store[:rhino_organization] = nil
    end
  end

  # ==================================================================
  # ROUTE REGISTRATION
  # ==================================================================

  describe "route registration" do
    def drawn_paths(models)
      Rhino.reset_configuration!
      Rhino.configure do |c|
        models.each { |slug, klass| c.model slug, klass }
        c.route_group :default, prefix: "", middleware: [], models: :all
      end

      router = ActionDispatch::Routing::RouteSet.new
      router.draw { Rhino::Routes.draw(self) }
      router.routes.map { |r| r.path.spec.to_s }
    end

    it "registers /computed for a declaring model" do
      paths = drawn_paths(computed_posts: "ComputedPost")

      expect(paths).to include("/api/computed_posts/computed(.:format)")
    end

    it "registers /computed BEFORE the :id route" do
      paths = drawn_paths(computed_posts: "ComputedPost")

      computed_index = paths.index("/api/computed_posts/computed(.:format)")
      id_index = paths.index("/api/computed_posts/:id(.:format)")

      expect(computed_index).to be < id_index
    end

    it "does not register /computed without a declaration" do
      paths = drawn_paths(plain_posts: "PlainComputedPost")

      expect(paths).not_to include("/api/plain_posts/computed(.:format)")
    end

    it "does not register /computed for an empty declaration" do
      paths = drawn_paths(empty_posts: "EmptyComputedPost")

      expect(paths).not_to include("/api/empty_posts/computed(.:format)")
    end

    it "honours rhino_except_actions :computed" do
      paths = drawn_paths(excepted_posts: "ExceptedComputedPost")

      expect(paths).not_to include("/api/excepted_posts/computed(.:format)")
      expect(paths).to include("/api/excepted_posts(.:format)")
    end
  end
end
