# frozen_string_literal: true

require "spec_helper"
require "rhino/controllers/resources_controller"
require "rhino/routes"
require "ostruct"

# --------------------------------------------------------------------------
# Models (bound to the shared `posts` table from spec_helper unless stated)
# --------------------------------------------------------------------------

# Mixes every declaration form: legacy callables, legacy literals, and extended
# specs with required, optional and multiple parameters.
class ArgComputedPost < ActiveRecord::Base
  include Rhino::HasRhino
  include Rhino::HasValidation
  include Rhino::HidableColumns
  include Rhino::HasAutoScope
  include Discard::Model

  self.table_name = "posts"

  belongs_to :organization, optional: true
  belongs_to :user, optional: true

  rhino_filters :status

  validates :title, length: { maximum: 255 }, allow_nil: true

  def rhino_record_computed_attributes
    {
      # Legacy: unchanged behavior.
      "shouty_title" => ->(record, _user) { record.title.to_s.upcase },
      "literal_version" => 3,
      "literal_tags" => %w[a b],

      # Extended.
      "label_since" => {
        params: [:since],
        with: ->(record, _user, since) { "#{record.title}@#{since}" }
      },
      "label_window" => {
        params: %i[from to],
        with: ->(_record, _user, from, to) { "#{from}..#{to}" }
      },
      "label_optional" => {
        params: %i[prefix suffix], optional: [:suffix],
        with: ->(_record, _user, prefix, suffix = "!") { "#{prefix}#{suffix}" }
      },
      "label_all_optional" => {
        params: [:tone], optional: [:tone],
        with: ->(_record, _user, tone = "plain") { "tone:#{tone}" }
      },
      "label_flag" => {
        params: [:on],
        with: ->(_record, _user, on) { on.is_a?(TrueClass) || on.is_a?(FalseClass) ? "bool:#{on}" : "string:#{on}" }
      },
      "secret_label" => {
        params: [:since],
        with: ->(_record, _user, since) { "classified-#{since}" }
      }
    }
  end

  def self.rhino_collection_computed_attributes
    {
      "total_count" => ->(scope, _user) { scope.count },
      "literal_version" => 3,

      "status_count" => {
        params: [:status],
        with: ->(scope, _user, status) { scope.where(status: status).count }
      },
      "range_count" => {
        params: %i[min max],
        with: ->(scope, _user, min, max) { scope.where(id: min.to_i..max.to_i).count }
      },
      "optional_count" => {
        params: [:status], optional: [:status],
        with: lambda { |scope, _user, status = nil|
          status.nil? ? scope.count : scope.where(status: status).count
        }
      },
      "flag_echo" => {
        params: [:on],
        with: lambda { |_scope, _user, on|
          on.is_a?(TrueClass) || on.is_a?(FalseClass) ? "bool:#{on}" : "string:#{on}"
        }
      },
      "secret_total" => {
        params: [:status],
        with: ->(scope, _user, _status) { scope.count }
      }
    }
  end
end

# Every declaration is legacy — the backward-compatibility lock.
class LegacyArgComputedPost < ActiveRecord::Base
  include Rhino::HasRhino
  include Rhino::HasValidation
  include Rhino::HidableColumns
  include Rhino::HasAutoScope

  self.table_name = "posts"

  belongs_to :organization, optional: true

  def rhino_record_computed_attributes
    {
      "shouty_title" => ->(record, _user) { record.title.to_s.upcase },
      "version" => 3,
      "tags" => %w[a b],
      "meta" => { "color" => "red" },
      "no_args" => -> { "zero-arity" },
      "one_arg" => ->(record) { record.title }
    }
  end

  def self.rhino_collection_computed_attributes
    {
      "total_count" => ->(scope, _user) { scope.count },
      "version" => 3,
      "tags" => %w[a b],
      "meta" => { "color" => "red" },
      "no_args" => -> { "zero-arity" },
      "one_arg" => ->(scope) { scope.count }
    }
  end
end

# Direct tenancy: an organization_id column of its own.
class TenantArgComputedPost < ActiveRecord::Base
  include Rhino::HasRhino
  include Rhino::HasValidation
  include Rhino::HidableColumns
  include Rhino::HasAutoScope
  include Rhino::BelongsToOrganization

  self.table_name = "posts"

  def rhino_record_computed_attributes
    {
      "label_since" => {
        params: [:since],
        with: ->(record, _user, since) { "#{record.title}@#{since}" }
      }
    }
  end

  def self.rhino_collection_computed_attributes
    {
      # The argument is used as a predicate, which is the realistic shape.
      # Naming another org's row must find nothing: the relation handed over is
      # already organization-scoped.
      "titled_count" => {
        params: [:title],
        with: ->(scope, _user, title) { scope.where(title: title).count }
      },
      # Even an argument that names the tenant column directly cannot reach
      # another org, because the org scope is a separate, already applied
      # constraint on the same relation.
      "org_probe_count" => {
        params: [:organization_id],
        with: ->(scope, _user, org_id) { scope.where(organization_id: org_id).count }
      }
    }
  end
end

# INDIRECT tenancy: owned through ArgIndirectPost -> ArgIndirectBlog -> org.
ActiveRecord::Schema.define do
  create_table :arg_indirect_blogs, force: true do |t|
    t.references :organization, foreign_key: true
    t.string :title
    t.timestamps
  end

  create_table :arg_indirect_posts, force: true do |t|
    t.references :arg_indirect_blog, null: false, foreign_key: true
    t.string :title
    t.timestamps
  end

  create_table :arg_indirect_comments, force: true do |t|
    t.references :arg_indirect_post, null: false, foreign_key: true
    t.text :body
    t.string :status, default: "ok"
    t.timestamps
  end
end

class ArgIndirectBlog < ActiveRecord::Base
  include Rhino::HasRhino
  include Rhino::HasValidation
  include Rhino::HidableColumns

  belongs_to :organization
end

class ArgIndirectPost < ActiveRecord::Base
  include Rhino::HasRhino
  include Rhino::HasValidation
  include Rhino::HidableColumns

  belongs_to :arg_indirect_blog
end

class ArgIndirectComment < ActiveRecord::Base
  include Rhino::HasRhino
  include Rhino::HasValidation
  include Rhino::HidableColumns

  belongs_to :arg_indirect_post

  rhino_filters :status

  def rhino_record_computed_attributes
    {
      "tagged_body" => {
        params: [:tag],
        with: ->(record, _user, tag) { "#{tag}:#{record.body}" }
      }
    }
  end

  def self.rhino_collection_computed_attributes
    {
      "status_count" => {
        params: [:status],
        with: ->(scope, _user, status) { scope.where(status: status).count }
      },
      # Naming a post that belongs to ANOTHER org's blog must count zero.
      "post_probe_count" => {
        params: [:post_id],
        with: ->(scope, _user, post_id) { scope.where(arg_indirect_post_id: post_id).count }
      }
    }
  end
end

# SYMBOL-keyed declarations. A Ruby developer writing a hash literal naturally
# reaches for `{ full_name: ->(...) }`, and the controller's gate has always
# compared stringified names — so before declarations were normalized, a
# symbol-keyed attribute PASSED authorization and was then silently dropped by
# the serializer's `declared.key?("full_name")` lookup: a 200 with the attribute
# missing and no error anywhere. Both halves now agree on the string form.
class SymbolKeyComputedPost < ActiveRecord::Base
  include Rhino::HasRhino
  include Rhino::HasValidation
  include Rhino::HidableColumns
  include Rhino::HasAutoScope

  self.table_name = "posts"

  belongs_to :organization, optional: true

  def rhino_record_computed_attributes
    {
      full_name: ->(record, _user) { "Post: #{record.title}" },
      label_since: {
        params: [:since],
        with: ->(record, _user, since) { "#{record.title}@#{since}" }
      }
    }
  end

  def self.rhino_collection_computed_attributes
    {
      symbol_total: ->(scope, _user) { scope.count },
      symbol_between: {
        params: %i[from to],
        with: ->(_scope, _user, from, to) { "#{from}..#{to}" }
      }
    }
  end
end

# --------------------------------------------------------------------------
# Policies
# --------------------------------------------------------------------------

class ArgComputedPostPolicy < Rhino::ResourcePolicy
  self.resource_slug = "arg_posts"
end

class DenySecretArgPolicy < Rhino::ResourcePolicy
  self.resource_slug = "arg_posts"

  def hidden_attributes_for_show(_user)
    %w[secret_label secret_total]
  end
end

RSpec.describe "Computed attribute arguments" do
  # ------------------------------------------------------------------
  # Harness (mirrors computed_attributes_spec.rb)
  # ------------------------------------------------------------------

  def call_action(action, slug: "arg_posts", params: {}, headers: {})
    controller = Rhino::ResourcesController.new

    method = case action.to_s
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

  def seed_posts
    ArgComputedPost.create!(title: "Alpha", status: "active")
    ArgComputedPost.create!(title: "Beta", status: "active")
    ArgComputedPost.create!(title: "Gamma", status: "blocked")
    ArgComputedPost.create!(title: "Delta", status: "pending")
  end

  before do
    Rhino.config.model :arg_posts, "ArgComputedPost"
    Rhino.config.model :legacy_arg_posts, "LegacyArgComputedPost"
    Rhino.config.model :tenant_arg_posts, "TenantArgComputedPost"
    Rhino.config.model :arg_icomments, "ArgIndirectComment"
    Rhino.config.model :symbol_posts, "SymbolKeyComputedPost"
  end

  # ==================================================================
  # /computed — the four wire forms
  # ==================================================================

  describe "GET /computed wire forms" do
    it "form A: the legacy comma list is unchanged" do
      user = create_user
      seed_posts

      response = call_action(:computed,
        params: { attributes: "total_count,literal_version" }, headers: auth_headers(user))

      expect(response.status).to eq(200)
      expect(response.body["data"]).to eq("total_count" => 4, "literal_version" => 3)
    end

    it "form B: a bracket key with no arguments" do
      user = create_user
      seed_posts

      response = call_action(:computed,
        params: { attributes: { "total_count" => "" } }, headers: auth_headers(user))

      expect(response.status).to eq(200)
      expect(response.body["data"]).to eq("total_count" => 4)
    end

    it "form C: a bare value binds the single declared parameter" do
      user = create_user
      seed_posts

      response = call_action(:computed,
        params: { attributes: { "status_count" => "active" } }, headers: auth_headers(user))

      expect(response.status).to eq(200)
      expect(response.body["data"]).to eq("status_count" => 2)
    end

    it "form D: named arguments" do
      user = create_user
      seed_posts
      ids = ArgComputedPost.order(:id).pluck(:id)

      response = call_action(:computed,
        params: { attributes: { "range_count" => { "min" => ids.first.to_s, "max" => ids[1].to_s } } },
        headers: auth_headers(user))

      expect(response.status).to eq(200)
      expect(response.body["data"]).to eq("range_count" => 2)
    end

    it "binds named arguments by name, not by position" do
      user = create_user
      seed_posts
      ids = ArgComputedPost.order(:id).pluck(:id)

      response = call_action(:computed,
        params: { attributes: { "range_count" => { "max" => ids[1].to_s, "min" => ids.first.to_s } } },
        headers: auth_headers(user))

      expect(response.body["data"]).to eq("range_count" => 2)
    end

    it "combines forms B, C and D in one request" do
      user = create_user
      seed_posts

      response = call_action(:computed,
        params: {
          attributes: {
            "total_count" => "",
            "status_count" => "blocked",
            "optional_count" => { "status" => "active" }
          }
        },
        headers: auth_headers(user))

      expect(response.status).to eq(200)
      expect(response.body["data"]).to eq(
        "total_count" => 4, "status_count" => 1, "optional_count" => 2
      )
    end

    it "lets an optional parameter be omitted" do
      user = create_user
      seed_posts

      omitted = call_action(:computed,
        params: { attributes: { "optional_count" => "" } }, headers: auth_headers(user))
      given = call_action(:computed,
        params: { attributes: { "optional_count" => "active" } }, headers: auth_headers(user))

      expect(omitted.body["data"]).to eq("optional_count" => 4)
      expect(given.body["data"]).to eq("optional_count" => 2)
    end

    it "hands the callable real booleans for 'true' and 'false'" do
      user = create_user

      expect(
        call_action(:computed, params: { attributes: { "flag_echo" => "true" } },
                               headers: auth_headers(user)).body["data"]
      ).to eq("flag_echo" => "bool:true")

      expect(
        call_action(:computed, params: { attributes: { "flag_echo" => "FALSE" } },
                               headers: auth_headers(user)).body["data"]
      ).to eq("flag_echo" => "bool:false")

      expect(
        call_action(:computed, params: { attributes: { "flag_echo" => "yes" } },
                               headers: auth_headers(user)).body["data"]
      ).to eq("flag_echo" => "string:yes")
    end

    it "gives each parameterised callable the unconstrained base relation" do
      user = create_user
      seed_posts

      response = call_action(:computed,
        params: { attributes: { "status_count" => "active", "total_count" => "" } },
        headers: auth_headers(user))

      expect(response.body["data"]).to eq("status_count" => 2, "total_count" => 4)
    end
  end

  # ==================================================================
  # /computed — the 403 contract, verbatim
  # ==================================================================

  describe "GET /computed 403 contract" do
    def denied(params, user)
      call_action(:computed, params: params, headers: auth_headers(user))
    end

    it "refuses an undeclared attribute named in the bracket form" do
      user = create_user

      response = denied({ attributes: { "nope" => { "x" => "1" } } }, user)

      expect(response.status).to eq(403)
      expect(response.body).to eq("message" => "Computed attribute 'nope' is not allowed")
    end

    it "gives a policy-denied attribute the same string as an undeclared one" do
      stub_const("ArgComputedPostPolicy", DenySecretArgPolicy)
      user = create_user

      denied_response = denied({ attributes: { "secret_total" => "active" } }, user)
      undeclared = denied({ attributes: { "ghost_total" => "active" } }, user)

      expect(denied_response.status).to eq(403)
      expect(denied_response.body).to eq("message" => "Computed attribute 'secret_total' is not allowed")
      expect(undeclared.body).to eq("message" => "Computed attribute 'ghost_total' is not allowed")
    end

    it "runs the gate BEFORE argument binding" do
      stub_const("ArgComputedPostPolicy", DenySecretArgPolicy)
      user = create_user

      # A denied attribute given a BAD argument must still return the gate
      # message: the specific argument errors must leak nothing.
      response = denied({ attributes: { "secret_total" => { "bogus" => "1" } } }, user)

      expect(response.status).to eq(403)
      expect(response.body).to eq("message" => "Computed attribute 'secret_total' is not allowed")
    end

    it "names a missing required parameter" do
      user = create_user

      response = denied({ attributes: { "range_count" => { "min" => "1" } } }, user)

      expect(response.status).to eq(403)
      expect(response.body).to eq("message" => "Computed attribute 'range_count' requires parameter 'max'")
    end

    it "names a required parameter left out of the bracket form entirely" do
      user = create_user

      response = denied({ attributes: { "status_count" => "" } }, user)

      expect(response.status).to eq(403)
      expect(response.body).to eq("message" => "Computed attribute 'status_count' requires parameter 'status'")
    end

    it "names a required parameter left out of the legacy list form" do
      user = create_user

      response = denied({ attributes: "status_count" }, user)

      expect(response.status).to eq(403)
      expect(response.body).to eq("message" => "Computed attribute 'status_count' requires parameter 'status'")
    end

    it "names an unknown parameter" do
      user = create_user

      response = denied({ attributes: { "status_count" => { "nope" => "1" } } }, user)

      expect(response.status).to eq(403)
      expect(response.body).to eq("message" => "Computed attribute 'status_count' does not accept parameter 'nope'")
    end

    it "refuses a bare value for a multi-parameter attribute" do
      user = create_user

      response = denied({ attributes: { "range_count" => "1" } }, user)

      expect(response.status).to eq(403)
      expect(response.body).to eq("message" => "Computed attribute 'range_count' requires named parameters")
    end

    it "refuses a positional argument list" do
      user = create_user

      response = denied({ attributes: { "range_count" => ["1"] } }, user)

      expect(response.status).to eq(403)
      expect(response.body).to eq("message" => "Computed attribute 'range_count' requires named parameters")
    end

    it "refuses a nested argument value" do
      user = create_user

      response = denied({ attributes: { "range_count" => { "min" => { "deep" => "1" } } } }, user)

      expect(response.status).to eq(403)
      expect(response.body).to eq("message" => "Computed attribute 'range_count' requires named parameters")
    end

    it "refuses any argument sent to a parameterless attribute" do
      user = create_user

      bare = denied({ attributes: { "total_count" => "5" } }, user)
      named = denied({ attributes: { "total_count" => { "x" => "5" } } }, user)

      expect(bare.status).to eq(403)
      expect(bare.body).to eq("message" => "Computed attribute 'total_count' does not accept arguments")
      expect(named.body).to eq("message" => "Computed attribute 'total_count' does not accept arguments")
    end

    it "refuses a positional attribute list structurally" do
      user = create_user

      response = denied({ attributes: ["total_count"] }, user)

      expect(response.status).to eq(403)
      expect(response.body).to eq("message" => "Computed attributes are not allowed")
    end

    it "refuses a blank attribute key structurally" do
      user = create_user

      response = denied({ attributes: { "" => "1" } }, user)

      expect(response.status).to eq(403)
      expect(response.body).to eq("message" => "Computed attributes are not allowed")
    end
  end

  # ==================================================================
  # /computed — the bare-call skip rule
  # ==================================================================

  describe "a bare GET /computed" do
    it "skips required-parameter attributes instead of 403ing" do
      stub_const("ArgComputedPostPolicy", DenySecretArgPolicy)
      user = create_user
      seed_posts

      response = call_action(:computed, headers: auth_headers(user))

      expect(response.status).to eq(200)
      # total_count and literal_version take nothing; optional_count's only
      # parameter is optional. status_count / range_count / flag_echo declare a
      # required parameter and are skipped. secret_total is policy-hidden.
      expect(response.body["data"].keys).to eq(%w[total_count literal_version optional_count])
      expect(response.body["data"]["optional_count"]).to eq(4)
    end

    it "treats a blank ?attributes the same way" do
      user = create_user
      seed_posts

      response = call_action(:computed, params: { attributes: "" }, headers: auth_headers(user))

      expect(response.status).to eq(200)
      expect(response.body["data"].keys).to include("total_count", "optional_count")
      expect(response.body["data"].keys).not_to include("status_count", "range_count", "flag_echo")
    end
  end

  # ==================================================================
  # index / show / trashed — ?computed_attributes=
  # ==================================================================

  describe "record-level attributes" do
    it "accepts a bare bracket argument on index" do
      user = create_user
      seed_posts

      response = call_action(:index,
        params: { computed_attributes: { "label_since" => "2026-01-01" } },
        headers: auth_headers(user))

      expect(response.status).to eq(200)
      expect(response.body["data"].first["label_since"]).to eq("Alpha@2026-01-01")
    end

    it "accepts named arguments on index" do
      user = create_user
      seed_posts

      response = call_action(:index,
        params: { computed_attributes: { "label_window" => { "from" => "a", "to" => "b" } } },
        headers: auth_headers(user))

      expect(response.status).to eq(200)
      expect(response.body["data"].first["label_window"]).to eq("a..b")
    end

    it "combines legacy and parameterised attributes in one request" do
      user = create_user
      seed_posts

      response = call_action(:index,
        params: { computed_attributes: { "shouty_title" => "", "label_since" => "2026-01-01" } },
        headers: auth_headers(user))

      expect(response.status).to eq(200)
      expect(response.body["data"].first["shouty_title"]).to eq("ALPHA")
      expect(response.body["data"].first["label_since"]).to eq("Alpha@2026-01-01")
    end

    it "drops an omitted trailing optional to the callable default" do
      user = create_user
      seed_posts

      response = call_action(:index,
        params: { computed_attributes: { "label_optional" => { "prefix" => "hi" } } },
        headers: auth_headers(user))

      expect(response.body["data"].first["label_optional"]).to eq("hi!")
    end

    it "binds a given optional argument" do
      user = create_user
      seed_posts

      response = call_action(:index,
        params: { computed_attributes: { "label_optional" => { "prefix" => "hi", "suffix" => "?" } } },
        headers: auth_headers(user))

      expect(response.body["data"].first["label_optional"]).to eq("hi?")
    end

    it "evaluates an all-optional attribute named in the legacy list form" do
      user = create_user
      seed_posts

      response = call_action(:index,
        params: { computed_attributes: "label_all_optional" }, headers: auth_headers(user))

      expect(response.status).to eq(200)
      expect(response.body["data"].first["label_all_optional"]).to eq("tone:plain")
    end

    it "coerces booleans" do
      user = create_user
      seed_posts

      response = call_action(:index,
        params: { computed_attributes: { "label_flag" => "TRUE" } }, headers: auth_headers(user))

      expect(response.body["data"].first["label_flag"]).to eq("bool:true")
    end

    it "accepts bracket arguments on show" do
      user = create_user
      seed_posts
      record = ArgComputedPost.find_by(title: "Beta")

      response = call_action(:show,
        params: { id: record.id.to_s, computed_attributes: { "label_since" => "2026-02-02" } },
        headers: auth_headers(user))

      expect(response.status).to eq(200)
      expect(response.body["label_since"]).to eq("Beta@2026-02-02")
    end

    it "accepts bracket arguments on trashed" do
      user = create_user
      seed_posts
      ArgComputedPost.find_by(title: "Gamma").discard!

      response = call_action(:trashed,
        params: { computed_attributes: { "label_since" => "2026-03-03" } },
        headers: auth_headers(user))

      expect(response.status).to eq(200)
      expect(response.body["data"].length).to eq(1)
      expect(response.body["data"].first["label_since"]).to eq("Gamma@2026-03-03")
    end

    it "runs the gate before argument binding on index" do
      stub_const("ArgComputedPostPolicy", DenySecretArgPolicy)
      user = create_user
      seed_posts

      response = call_action(:index,
        params: { computed_attributes: { "secret_label" => { "bogus" => "1" } } },
        headers: auth_headers(user))

      expect(response.status).to eq(403)
      expect(response.body).to eq("message" => "Computed attribute 'secret_label' is not allowed")
    end

    it "reports a missing required argument on index" do
      user = create_user
      seed_posts

      response = call_action(:index,
        params: { computed_attributes: "label_window" }, headers: auth_headers(user))

      expect(response.status).to eq(403)
      expect(response.body).to eq("message" => "Computed attribute 'label_window' requires parameter 'from'")
    end

    it "refuses a positional attribute list on index" do
      user = create_user
      seed_posts

      response = call_action(:index,
        params: { computed_attributes: ["shouty_title"] }, headers: auth_headers(user))

      expect(response.status).to eq(403)
      expect(response.body).to eq("message" => "Computed attributes are not allowed")
    end

    it "refuses an unknown parameter on show" do
      user = create_user
      seed_posts
      record = ArgComputedPost.first

      response = call_action(:show,
        params: { id: record.id.to_s, computed_attributes: { "label_since" => { "nope" => "x" } } },
        headers: auth_headers(user))

      expect(response.status).to eq(403)
      expect(response.body).to eq("message" => "Computed attribute 'label_since' does not accept parameter 'nope'")
    end
  end

  # ==================================================================
  # Backward-compatibility lock — an all-legacy model
  # ==================================================================

  describe "an all-legacy model" do
    it "returns byte-identical aggregates bare and by name" do
      user = create_user
      seed_posts

      bare = call_action(:computed, slug: "legacy_arg_posts", headers: auth_headers(user))
      named = call_action(:computed, slug: "legacy_arg_posts",
        params: { attributes: "total_count,version,tags,meta,no_args,one_arg" },
        headers: auth_headers(user))

      expected = {
        "total_count" => 4,
        "version" => 3,
        "tags" => %w[a b],
        "meta" => { "color" => "red" },
        "no_args" => "zero-arity",
        "one_arg" => 4
      }

      expect(bare.status).to eq(200)
      expect(bare.body["data"]).to eq(expected)
      expect(named.body["data"]).to eq(expected)
    end

    it "keeps the tolerant arity branch for parameterless record callables" do
      user = create_user
      seed_posts

      response = call_action(:index, slug: "legacy_arg_posts",
        params: { computed_attributes: "shouty_title,version,tags,meta,no_args,one_arg" },
        headers: auth_headers(user))

      expect(response.status).to eq(200)
      row = response.body["data"].first
      expect(row["shouty_title"]).to eq("ALPHA")
      expect(row["version"]).to eq(3)
      expect(row["tags"]).to eq(%w[a b])
      expect(row["meta"]).to eq("color" => "red")
      expect(row["no_args"]).to eq("zero-arity")
      expect(row["one_arg"]).to eq("Alpha")
    end

    it "evaluates nothing when the parameter is absent" do
      user = create_user
      seed_posts

      response = call_action(:index, slug: "legacy_arg_posts", headers: auth_headers(user))

      expect(response.status).to eq(200)
      expect(response.body["data"].first).not_to have_key("shouty_title")
      expect(response.body["data"].first).not_to have_key("version")
    end
  end

  # ==================================================================
  # Direct-call safety — as_rhino_json with names only
  # ==================================================================

  describe "direct as_rhino_json calls" do
    it "skips required-parameter attributes rather than raising ArgumentError" do
      seed_posts
      record = ArgComputedPost.first

      json = record.as_rhino_json(
        computed_attributes: %w[shouty_title label_since label_optional label_all_optional]
      )

      expect(json["shouty_title"]).to eq("ALPHA")
      expect(json).not_to have_key("label_since")
      expect(json).not_to have_key("label_optional")
      expect(json["label_all_optional"]).to eq("tone:plain")
    end

    it "accepts an arguments channel" do
      seed_posts
      record = ArgComputedPost.first

      json = record.as_rhino_json(
        computed_attributes: %w[label_since],
        computed_arguments: { "label_since" => ["2026-01-01"] }
      )

      expect(json["label_since"]).to eq("Alpha@2026-01-01")
    end
  end

  # ==================================================================
  # Multi-tenancy — direct and indirect ownership
  # ==================================================================

  describe "multi-tenancy" do
    it "scopes a parameterised aggregate to the current org (direct)" do
      org = create_organization
      other = create_organization
      user = create_user_in_org(org)
      RequestStore.store[:rhino_organization] = org

      TenantArgComputedPost.create!(title: "Mine", status: "active", organization_id: org.id)
      TenantArgComputedPost.create!(title: "Theirs", status: "active", organization_id: other.id)
      TenantArgComputedPost.create!(title: "Theirs", status: "active", organization_id: other.id)

      mine = call_action(:computed, slug: "tenant_arg_posts",
        params: { attributes: { "titled_count" => "Mine" } }, headers: auth_headers(user))
      theirs = call_action(:computed, slug: "tenant_arg_posts",
        params: { attributes: { "titled_count" => "Theirs" } }, headers: auth_headers(user))

      expect(mine.body["data"]).to eq("titled_count" => 1)
      expect(theirs.body["data"]).to eq("titled_count" => 0)
    ensure
      RequestStore.store[:rhino_organization] = nil
    end

    it "reaches nothing when the client supplies another org's id as an argument" do
      org = create_organization
      other = create_organization
      user = create_user_in_org(org)
      RequestStore.store[:rhino_organization] = org

      TenantArgComputedPost.create!(title: "Mine", status: "active", organization_id: org.id)
      TenantArgComputedPost.create!(title: "Theirs", status: "active", organization_id: other.id)

      response = call_action(:computed, slug: "tenant_arg_posts",
        params: { attributes: { "org_probe_count" => other.id.to_s } },
        headers: auth_headers(user))

      expect(response.status).to eq(200)
      expect(response.body["data"]).to eq("org_probe_count" => 0)
    ensure
      RequestStore.store[:rhino_organization] = nil
    end

    it "never leaks another org through a parameterised record attribute" do
      org = create_organization
      other = create_organization
      user = create_user_in_org(org)
      RequestStore.store[:rhino_organization] = org

      TenantArgComputedPost.create!(title: "Mine", status: "active", organization_id: org.id)
      TenantArgComputedPost.create!(title: "Theirs", status: "active", organization_id: other.id)

      response = call_action(:index, slug: "tenant_arg_posts",
        params: { computed_attributes: { "label_since" => "2026-01-01" } },
        headers: auth_headers(user))

      expect(response.status).to eq(200)
      expect(response.body["data"].map { |r| r["label_since"] }).to eq(["Mine@2026-01-01"])
    ensure
      RequestStore.store[:rhino_organization] = nil
    end
  end

  describe "indirect (owner-chain) tenancy" do
    # 2 comments reachable from org A (1 flagged), 3 from org B (2 flagged).
    def seed_indirect(org_a, org_b)
      blog_a = ArgIndirectBlog.create!(organization: org_a, title: "Mine")
      blog_b = ArgIndirectBlog.create!(organization: org_b, title: "Theirs")
      post_a = ArgIndirectPost.create!(arg_indirect_blog: blog_a, title: "Mine")
      post_b = ArgIndirectPost.create!(arg_indirect_blog: blog_b, title: "Theirs")

      ArgIndirectComment.create!(arg_indirect_post: post_a, body: "mine a", status: "ok")
      ArgIndirectComment.create!(arg_indirect_post: post_a, body: "mine b", status: "flagged")
      ArgIndirectComment.create!(arg_indirect_post: post_b, body: "theirs a", status: "flagged")
      ArgIndirectComment.create!(arg_indirect_post: post_b, body: "theirs b", status: "flagged")
      ArgIndirectComment.create!(arg_indirect_post: post_b, body: "theirs c", status: "ok")

      [post_a, post_b]
    end

    it "scopes a parameterised aggregate through the ownership chain" do
      org_a = create_organization
      org_b = create_organization
      user = create_user_in_org(org_a)
      seed_indirect(org_a, org_b)

      response = call_action(:computed, slug: "arg_icomments",
        params: { organization: org_a.id.to_s, attributes: { "status_count" => "flagged" } },
        headers: auth_headers(user))

      expect(response.status).to eq(200)
      # 3 flagged rows exist; only the 1 reachable through org A's blog counts.
      expect(response.body["data"]).to eq("status_count" => 1)
    end

    it "reaches nothing when an argument names another org's parent row" do
      org_a = create_organization
      org_b = create_organization
      user = create_user_in_org(org_a)
      post_a, post_b = seed_indirect(org_a, org_b)

      mine = call_action(:computed, slug: "arg_icomments",
        params: { organization: org_a.id.to_s, attributes: { "post_probe_count" => post_a.id.to_s } },
        headers: auth_headers(user))
      theirs = call_action(:computed, slug: "arg_icomments",
        params: { organization: org_a.id.to_s, attributes: { "post_probe_count" => post_b.id.to_s } },
        headers: auth_headers(user))

      expect(mine.body["data"]).to eq("post_probe_count" => 2)
      expect(theirs.body["data"]).to eq("post_probe_count" => 0)
    end

    it "scopes a parameterised record attribute through the ownership chain" do
      org_a = create_organization
      org_b = create_organization
      user = create_user_in_org(org_a)
      seed_indirect(org_a, org_b)

      response = call_action(:index, slug: "arg_icomments",
        params: { organization: org_a.id.to_s, computed_attributes: { "tagged_body" => "x" } },
        headers: auth_headers(user))

      expect(response.status).to eq(200)
      expect(response.body["data"].map { |r| r["tagged_body"] }.sort).to eq(["x:mine a", "x:mine b"])
    end

    it "does not change which rows index returns" do
      org_a = create_organization
      org_b = create_organization
      user = create_user_in_org(org_a)
      seed_indirect(org_a, org_b)

      plain = call_action(:index, slug: "arg_icomments",
        params: { organization: org_a.id.to_s }, headers: auth_headers(user))
      with_args = call_action(:index, slug: "arg_icomments",
        params: { organization: org_a.id.to_s, computed_attributes: { "tagged_body" => "x" } },
        headers: auth_headers(user))

      expect(with_args.body["data"].length).to eq(plain.body["data"].length)
    end
  end

  # ==================================================================
  # SYMBOL-KEYED DECLARATIONS
  #
  # The gate compares stringified names, so a symbol-keyed attribute has
  # always been authorizable; only the serializer's string lookup dropped it.
  # These lock both halves together — a regression here is a silent 200 with
  # the attribute simply missing, which no status assertion would catch.
  # ==================================================================

  describe "symbol-keyed declarations" do
    it "serializes a symbol-keyed record attribute on index when requested" do
      user = create_user
      SymbolKeyComputedPost.create!(title: "Alpha", status: "active")

      response = call_action(:index, slug: "symbol_posts",
        params: { computed_attributes: "full_name" },
        headers: auth_headers(user))

      expect(response.status).to eq(200)
      expect(response.body["data"].first).to have_key("full_name")
      expect(response.body["data"].first["full_name"]).to eq("Post: Alpha")
    end

    it "serializes a symbol-keyed record attribute on show when requested" do
      user = create_user
      post = SymbolKeyComputedPost.create!(title: "Alpha", status: "active")

      response = call_action(:show, slug: "symbol_posts",
        params: { id: post.id.to_s, computed_attributes: "full_name" },
        headers: auth_headers(user))

      expect(response.status).to eq(200)
      expect(response.body).to have_key("full_name")
      expect(response.body["full_name"]).to eq("Post: Alpha")
    end

    it "does not evaluate a symbol-keyed record attribute that was not requested" do
      user = create_user
      SymbolKeyComputedPost.create!(title: "Alpha", status: "active")

      response = call_action(:index, slug: "symbol_posts", headers: auth_headers(user))

      expect(response.status).to eq(200)
      expect(response.body["data"].first).not_to have_key("full_name")
    end

    it "binds arguments for a symbol-keyed parameterised record attribute" do
      user = create_user
      SymbolKeyComputedPost.create!(title: "Alpha", status: "active")

      response = call_action(:index, slug: "symbol_posts",
        params: { computed_attributes: { "label_since" => "2026-01-01" } },
        headers: auth_headers(user))

      expect(response.status).to eq(200)
      expect(response.body["data"].first["label_since"]).to eq("Alpha@2026-01-01")
    end

    it "serializes a symbol-keyed collection attribute on /computed" do
      user = create_user
      SymbolKeyComputedPost.create!(title: "Alpha", status: "active")
      SymbolKeyComputedPost.create!(title: "Beta", status: "active")

      response = call_action(:computed, slug: "symbol_posts",
        params: { attributes: "symbol_total" },
        headers: auth_headers(user))

      expect(response.status).to eq(200)
      expect(response.body["data"]).to eq({ "symbol_total" => 2 })
    end

    it "binds arguments for a symbol-keyed parameterised collection attribute" do
      user = create_user

      response = call_action(:computed, slug: "symbol_posts",
        params: { attributes: { "symbol_between" => { "from" => "a", "to" => "b" } } },
        headers: auth_headers(user))

      expect(response.status).to eq(200)
      expect(response.body["data"]).to eq({ "symbol_between" => "a..b" })
    end

    it "skips the symbol-keyed required-parameter attribute on a bare /computed" do
      user = create_user
      SymbolKeyComputedPost.create!(title: "Alpha", status: "active")

      response = call_action(:computed, slug: "symbol_posts", headers: auth_headers(user))

      expect(response.status).to eq(200)
      expect(response.body["data"]).to eq({ "symbol_total" => 1 })
    end
  end

  # ==================================================================
  # EMPTY CONTAINER vs ABSENT
  #
  # Absent/blank means "no selection" (everything the policy allows); an empty
  # CONTAINER means the client made a selection that happened to name nothing,
  # and gets nothing. All three stacks agree on this.
  #
  # Rack cannot produce an empty hash for `attributes` from a query string —
  # verified directly: `attributes[]` parses to `[nil]`, `attributes[]=` to
  # `[""]`, `attributes[__proto__]=` to `{"__proto__" => ""}` (Ruby has no
  # prototype keys to strip). It IS reachable over HTTP on NestJS, where
  # Express's extended parser (qs with allowPrototypes) turns
  # `?attributes[__proto__]=` into an empty object; that request returns
  # `{"data": {}}` there, matching what these specs pin here.
  # ==================================================================

  describe "an empty attributes container" do
    it "returns no aggregates for an empty ?attributes hash" do
      user = create_user
      seed_posts

      response = call_action(:computed, params: { attributes: {} }, headers: auth_headers(user))

      expect(response.status).to eq(200)
      expect(response.body["data"]).to eq({})
    end

    it "still returns everything when ?attributes is absent" do
      user = create_user
      seed_posts

      response = call_action(:computed, headers: auth_headers(user))

      expect(response.status).to eq(200)
      expect(response.body["data"]).not_to be_empty
    end

    it "returns no record attributes for an empty ?computed_attributes hash" do
      user = create_user
      seed_posts

      response = call_action(:index, params: { computed_attributes: {} }, headers: auth_headers(user))

      expect(response.status).to eq(200)
      expect(response.body["data"].first).not_to have_key("shouty_title")
    end
  end
end
