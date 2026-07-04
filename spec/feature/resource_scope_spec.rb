# frozen_string_literal: true

require "spec_helper"
require "rhino/controllers/resources_controller"
require "ostruct"

# ---------------------------------------------------------------------------
# Test models for the custom-query resolver (Rhino.query / Rhino.for_user...).
#
# Two shapes, mirroring the two org-scoping mechanisms:
#
#   * ScopedPost  — COLUMN-scoped: bound to the shared `posts` table, includes
#     BelongsToOrganization (organization_id column + org default_scope). Also
#     has a matching Scopes::ScopedPostScope so we can prove the explicit user
#     reaches the auto-scope.
#
#   * ScopedComment — RELATIONSHIP-scoped: bound to the shared `comments` table,
#     no organization_id column. Reaches the org only through
#     comment -> post -> organization_id (auto-detected belongs_to chain).
# ---------------------------------------------------------------------------

module Scopes
  # User-aware auto-scope: when a current user is present, restrict to that user's
  # rows. Reads the user through the ResourceScope#user helper (RequestStore),
  # which the explicit builder installs at BUILD time. Attached (by naming
  # convention) to OwnedPost only.
  class OwnedPostScope < Rhino::ResourceScope
    def apply(relation)
      return relation unless user

      relation.where(user_id: user.id)
    end
  end
end

# Column-scoped model: organization_id column + org default_scope. No user-aware
# auto-scope, so its rows are visible to any user in the org.
class ScopedPost < ActiveRecord::Base
  include Rhino::HasRhino
  include Rhino::HasValidation
  include Rhino::HidableColumns
  include Rhino::BelongsToOrganization

  self.table_name = "posts"

  belongs_to :user, optional: true

  scope :published, -> { where(is_published: true) }

  rhino_filters :title, :status, :user_id
  rhino_sorts :title, :created_at
  rhino_scopes :published
  rhino_search :title

  validates :title, length: { maximum: 255 }, allow_nil: true
end

class ScopedPostPolicy < Rhino::ResourcePolicy
  self.resource_slug = "scoped_posts"
end

# Column-scoped model that ALSO carries a user-aware auto-scope
# (Scopes::OwnedPostScope, found by convention). Used to prove the explicit user
# reaches the auto-scope at BUILD time.
class OwnedPost < ActiveRecord::Base
  include Rhino::HasRhino
  include Rhino::HasValidation
  include Rhino::HidableColumns
  include Rhino::HasAutoScope
  include Rhino::BelongsToOrganization

  self.table_name = "posts"

  belongs_to :user, optional: true

  validates :title, length: { maximum: 255 }, allow_nil: true
end

class OwnedPostPolicy < Rhino::ResourcePolicy
  self.resource_slug = "owned_posts"
end

# Relationship-scoped model: comment -> post -> org (post has organization_id).
class ScopedComment < ActiveRecord::Base
  include Rhino::HasRhino
  include Rhino::HasValidation
  include Rhino::HidableColumns

  self.table_name = "comments"

  belongs_to :post, optional: true
  belongs_to :user, optional: true

  rhino_filters :body
end

class ScopedCommentPolicy < Rhino::ResourcePolicy
  self.resource_slug = "scoped_comments"
end

# Reachable to Organization only by belongs_to name-match, on a table with NO
# organization_id column — so it is classified organization_scoped? but no filter
# can actually be applied. Rhino.query must fail CLOSED on it, never unscoped.
class OrgLinkedRole < ActiveRecord::Base
  self.table_name = "roles"
  belongs_to :organization, optional: true
end

RSpec.describe "Rhino resource-scope resolver (Rhino.query / for_user)" do
  # ------------------------------------------------------------------
  # Harness (mirrors resources_controller_spec.rb / tenant_security_spec.rb)
  # ------------------------------------------------------------------

  def call_action(action, slug:, params: {}, headers: {}, env_overrides: {})
    controller = Rhino::ResourcesController.new

    method = case action.to_s
             when "index", "show", "trashed" then "GET"
             when "store", "restore", "nested" then "POST"
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
    }.merge(params.slice(:id, :model_slug).transform_keys(&:to_s).transform_keys(&:to_sym))

    headers.each { |key, value| env["HTTP_#{key.upcase.tr('-', '_')}"] = value }
    env_overrides.each { |k, v| env[k] = v }

    request = ActionDispatch::Request.new(env)
    response = ActionDispatch::Response.new

    begin
      controller.dispatch(action.to_sym, request, response)
    rescue Pundit::NotAuthorizedError
      response.status = 403
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

  let(:org_a) { Organization.create!(name: "Org A", slug: "org-a-#{SecureRandom.uuid}") }
  let(:org_b) { Organization.create!(name: "Org B", slug: "org-b-#{SecureRandom.uuid}") }

  # A ScopedPost carrying an explicit organization_id (bypasses set_organization_from_context
  # by supplying organization_id directly). Uses .new/.save to avoid the org default_scope
  # interfering during creation.
  def create_scoped_post(org, attrs = {})
    without_request_org do
      ScopedPost.create!({ title: "Post", organization_id: org.id }.merge(attrs))
    end
  end

  def create_scoped_comment(post, attrs = {})
    ScopedComment.create!({ body: "Comment", post_id: post.id }.merge(attrs))
  end

  # Run a block with RequestStore org/user cleared, restoring afterward. Used both
  # for seeding (so the org default_scope does not hide freshly-created rows) and
  # to simulate the "no request context" (job/rake) environment.
  def without_request_org
    prev_org = RequestStore.store[:rhino_organization]
    prev_user = RequestStore.store[:rhino_current_user]
    RequestStore.store[:rhino_organization] = nil
    RequestStore.store[:rhino_current_user] = nil
    yield
  ensure
    RequestStore.store[:rhino_organization] = prev_org
    RequestStore.store[:rhino_current_user] = prev_user
  end

  before do
    Rhino.config.model :scoped_posts, "ScopedPost"
    Rhino.config.model :owned_posts, "OwnedPost"
    Rhino.config.model :scoped_comments, "ScopedComment"
    Rhino.config.model :users, "User"
  end

  # ------------------------------------------------------------------
  # Fail-closed hardening: the resolver must NEVER return an unscoped
  # relation for a model it classified as organization-scoped.
  # ------------------------------------------------------------------
  describe "fail-closed hardening" do
    it "classifies a model as org-scoped (fail closed) when classification itself raises" do
      boom = Class.new do
        def self.column_names
          raise "columns unavailable"
        end

        def self.name
          "BoomModel"
        end
      end

      expect(Rhino::ScopesToOrganization.organization_scoped?(boom)).to be(true)
    end

    it "raises MissingTenantContext when an org-classified model has an unfilterable relationship path" do
      RequestStore.store[:rhino_organization] = org_a

      expect { Rhino.query(OrgLinkedRole) }
        .to raise_error(Rhino::MissingTenantContext, /OrgLinkedRole/)
    ensure
      RequestStore.store[:rhino_organization] = nil
    end
  end

  # ==================================================================
  # 1. Direct — column model isolates org A from org B
  # ==================================================================

  describe "direct query — column-scoped model" do
    it "returns only org A rows and excludes org B" do
      create_scoped_post(org_a, title: "A1")
      create_scoped_post(org_a, title: "A2")
      create_scoped_post(org_b, title: "B1")

      RequestStore.store[:rhino_organization] = org_a
      expect(Rhino.query(ScopedPost).count).to eq(2)
      titles = Rhino.query(ScopedPost).pluck(:title)
      expect(titles).to match_array(%w[A1 A2])
      expect(titles).not_to include("B1")
    end
  end

  # ==================================================================
  # 2. Direct — relationship model (comment -> post -> org). KEY leak case.
  # ==================================================================

  describe "direct query — relationship-scoped model" do
    it "returns only org A rows through the belongs_to chain" do
      post_a = create_scoped_post(org_a, title: "PA")
      post_b = create_scoped_post(org_b, title: "PB")
      create_scoped_comment(post_a, body: "CA1")
      create_scoped_comment(post_a, body: "CA2")
      create_scoped_comment(post_b, body: "CB1")

      RequestStore.store[:rhino_organization] = org_a
      bodies = Rhino.query(ScopedComment).pluck(:body)
      expect(bodies).to match_array(%w[CA1 CA2])
      expect(bodies).not_to include("CB1")
    end
  end

  # ==================================================================
  # 3. Direct — aggregates respect the scope
  # ==================================================================

  describe "direct query — aggregates" do
    it "count / sum / group all respect the org scope" do
      create_scoped_post(org_a, title: "A", blog_id: 10)
      create_scoped_post(org_a, title: "A", blog_id: 20)
      create_scoped_post(org_b, title: "B", blog_id: 999)

      RequestStore.store[:rhino_organization] = org_a
      expect(Rhino.query(ScopedPost).count).to eq(2)
      expect(Rhino.query(ScopedPost).sum(:blog_id)).to eq(30)
      grouped = Rhino.query(ScopedPost).group(:title).count
      expect(grouped).to eq({ "A" => 2 })
    end
  end

  # ==================================================================
  # 4. Direct — global model (no org mechanism) returns all, never raises
  # ==================================================================

  describe "direct query — global (non-org) model" do
    it "returns all rows and does not raise even with no org context" do
      # Role has no organization_id, no for_organization, no belongs_to->org chain.
      Role.create!(name: "R1", slug: "r1-#{SecureRandom.uuid}")
      Role.create!(name: "R2", slug: "r2-#{SecureRandom.uuid}")

      RequestStore.store[:rhino_organization] = nil
      expect { Rhino.query(Role) }.not_to raise_error
      expect(Rhino.query(Role).count).to eq(Role.count)
    end
  end

  # ==================================================================
  # 5. Direct — fail closed on org-scopable model with no org context
  # ==================================================================

  describe "direct query — fail closed" do
    it "raises MissingTenantContext for a column model with no org context" do
      create_scoped_post(org_a, title: "A")
      RequestStore.store[:rhino_organization] = nil

      expect { Rhino.query(ScopedPost) }
        .to raise_error(Rhino::MissingTenantContext, /ScopedPost/)
    end

    it "raises MissingTenantContext for a relationship model with no org context" do
      RequestStore.store[:rhino_organization] = nil

      expect { Rhino.query(ScopedComment) }
        .to raise_error(Rhino::MissingTenantContext, /ScopedComment/)
    end
  end

  # ==================================================================
  # 6. Explicit — org isolation with NO RequestStore org (simulate job)
  # ==================================================================

  describe "explicit query — org isolation without a request" do
    it "isolates org A from org B using the passed org, not the request" do
      create_scoped_post(org_a, title: "A1")
      create_scoped_post(org_a, title: "A2")
      create_scoped_post(org_b, title: "B1")
      user = create_user

      without_request_org do
        expect(RequestStore.store[:rhino_organization]).to be_nil

        count = Rhino.for_user(user).in_organization(org_a).query(ScopedPost).count
        expect(count).to eq(2)

        bodies = Rhino.for_user(user).in_organization(org_a).query(ScopedPost).pluck(:title)
        expect(bodies).not_to include("B1")
      end
    end
  end

  # ==================================================================
  # 7. Explicit — relationship model without a request scopes by passed org
  # ==================================================================

  describe "explicit query — relationship model without a request" do
    it "scopes the belongs_to chain by the passed org" do
      post_a = create_scoped_post(org_a, title: "PA")
      post_b = create_scoped_post(org_b, title: "PB")
      create_scoped_comment(post_a, body: "CA")
      create_scoped_comment(post_b, body: "CB")
      user = create_user

      without_request_org do
        bodies = Rhino.for_user(user).in_organization(org_a).query(ScopedComment).pluck(:body)
        expect(bodies).to eq(["CA"])
      end
    end
  end

  # ==================================================================
  # 8. Explicit — user-aware auto-scope reached via the explicit user
  # ==================================================================

  describe "explicit query — user-aware auto-scope" do
    it "different explicit users (same org) yield different rows" do
      user_a = create_user
      user_b = create_user
      without_request_org do
        OwnedPost.create!(title: "MineA", organization_id: org_a.id, user_id: user_a.id)
        OwnedPost.create!(title: "MineB", organization_id: org_a.id, user_id: user_b.id)

        rows_a = Rhino.for_user(user_a).in_organization(org_a).query(OwnedPost).pluck(:title)
        rows_b = Rhino.for_user(user_b).in_organization(org_a).query(OwnedPost).pluck(:title)

        expect(rows_a).to eq(["MineA"])
        expect(rows_b).to eq(["MineB"])
      end
    end
  end

  # ==================================================================
  # 9. Explicit — run { } restores RequestStore user + org afterward
  # ==================================================================

  describe "explicit run — restores RequestStore" do
    it "restores an existing user+org after the block" do
      user = create_user
      other = create_user
      RequestStore.store[:rhino_current_user] = other
      RequestStore.store[:rhino_organization] = org_b

      before_user = RequestStore.store[:rhino_current_user]
      before_org  = RequestStore.store[:rhino_organization]

      Rhino.for_user(user).in_organization(org_a).run { :ok }

      expect(RequestStore.store[:rhino_current_user]).to eq(before_user)
      expect(RequestStore.store[:rhino_organization]).to eq(before_org)
    end

    it "restores the absent (nil) case after the block" do
      user = create_user
      RequestStore.store[:rhino_current_user] = nil
      RequestStore.store[:rhino_organization] = nil

      Rhino.for_user(user).in_organization(org_a).run { :ok }

      expect(RequestStore.store[:rhino_current_user]).to be_nil
      expect(RequestStore.store[:rhino_organization]).to be_nil
    end

    it "restores even when the block raises" do
      user = create_user
      RequestStore.store[:rhino_organization] = org_b
      before_org = RequestStore.store[:rhino_organization]

      expect do
        Rhino.for_user(user).in_organization(org_a).run { raise "boom" }
      end.to raise_error("boom")

      expect(RequestStore.store[:rhino_organization]).to eq(before_org)
    end
  end

  # ==================================================================
  # 10. Explicit — run returns the block value
  # ==================================================================

  describe "explicit run — return value" do
    it "returns the value produced by the block" do
      user = create_user
      create_scoped_post(org_a, title: "A1")
      create_scoped_post(org_a, title: "A2")
      create_scoped_post(org_b, title: "B1")

      result = Rhino.for_user(user).in_organization(org_a).run do
        Rhino.query(ScopedPost).count
      end

      expect(result).to eq(2)
    end
  end

  # ==================================================================
  # 11. Explicit builder isolation — no stale RequestStore afterward
  # ==================================================================

  describe "explicit builder isolation" do
    it "leaves no stale context: a later Rhino.query fails closed" do
      create_scoped_post(org_a, title: "A1")
      user = create_user

      without_request_org do
        Rhino.for_user(user).in_organization(org_a).query(ScopedPost)

        # No context now — the org-scopable model must fail closed.
        expect { Rhino.query(ScopedPost) }
          .to raise_error(Rhino::MissingTenantContext)
      end
    end
  end

  # ==================================================================
  # 12. scoped_query + named scope applies BOTH the scope and the org filter
  # ==================================================================

  describe "scoped_query — named scope + org scope" do
    it "applies the whitelisted ?scope= AND the org filter" do
      create_scoped_post(org_a, title: "APub", is_published: true)
      create_scoped_post(org_a, title: "ADraft", is_published: false)
      create_scoped_post(org_b, title: "BPub", is_published: true)

      RequestStore.store[:rhino_organization] = org_a
      titles = Rhino.scoped_query(ScopedPost, "published").pluck(:title)
      expect(titles).to eq(["APub"])
      expect(titles).not_to include("BPub")
      expect(titles).not_to include("ADraft")
    end

    it "explicit scoped_query applies the named scope + passed org without a request" do
      create_scoped_post(org_a, title: "APub", is_published: true)
      create_scoped_post(org_a, title: "ADraft", is_published: false)
      create_scoped_post(org_b, title: "BPub", is_published: true)
      user = create_user

      without_request_org do
        titles = Rhino.for_user(user).in_organization(org_a)
                      .scoped_query(ScopedPost, "published").pluck(:title)
        expect(titles).to eq(["APub"])
      end
    end
  end

  # ==================================================================
  # 13. CRUD parity — Rhino.query count == index-action count
  # ==================================================================

  describe "CRUD parity with the index action" do
    it "column model: Rhino.query count matches the index count" do
      user = create_user
      create_scoped_post(org_a, title: "A1")
      create_scoped_post(org_a, title: "A2")
      create_scoped_post(org_b, title: "B1")

      response = call_action(:index,
        slug: "scoped_posts",
        params: { model_slug: "scoped_posts" },
        headers: auth_headers(user),
        env_overrides: { "rhino.organization" => org_a })

      RequestStore.store[:rhino_organization] = org_a
      expect(response.status).to eq(200)
      expect(Rhino.query(ScopedPost).count).to eq(response.body["data"].length)
    end

    it "relationship model: Rhino.query count matches the index count" do
      user = create_user
      post_a = create_scoped_post(org_a, title: "PA")
      post_b = create_scoped_post(org_b, title: "PB")
      create_scoped_comment(post_a, body: "CA1")
      create_scoped_comment(post_a, body: "CA2")
      create_scoped_comment(post_b, body: "CB1")

      response = call_action(:index,
        slug: "scoped_comments",
        params: { model_slug: "scoped_comments" },
        headers: auth_headers(user),
        env_overrides: { "rhino.organization" => org_a })

      RequestStore.store[:rhino_organization] = org_a
      expect(response.status).to eq(200)
      expect(Rhino.query(ScopedComment).count).to eq(response.body["data"].length)
    end
  end

  # ==================================================================
  # 14. Console-leak contrast: Model.all leaks, resolver does not
  # ==================================================================

  describe "console-leak contrast" do
    it "Model.all returns ALL orgs while the resolver returns only org A" do
      create_scoped_post(org_a, title: "A1")
      create_scoped_post(org_b, title: "B1")
      user = create_user

      without_request_org do
        # Simulates a console / job with no request org: the org default_scope is
        # inert, so a raw Model.all leaks across tenants.
        expect(ScopedPost.count).to eq(2)

        scoped = Rhino.for_user(user).in_organization(org_a).query(ScopedPost).count
        expect(scoped).to eq(1)
      end
    end
  end

  # ==================================================================
  # 15. Rhino::Context unit — fallback + with sets/restores
  # ==================================================================

  describe "Rhino::Context" do
    it "user/organization fall back to RequestStore" do
      user = create_user
      RequestStore.store[:rhino_current_user] = user
      RequestStore.store[:rhino_organization] = org_a

      expect(Rhino::Context.user).to eq(user)
      expect(Rhino::Context.organization).to eq(org_a)
    end

    it "with sets the context inside the block and restores it after" do
      outer_user = create_user
      inner_user = create_user
      RequestStore.store[:rhino_current_user] = outer_user
      RequestStore.store[:rhino_organization] = org_b

      seen_user = nil
      seen_org = nil
      returned = Rhino::Context.with(user: inner_user, organization: org_a) do
        seen_user = Rhino::Context.user
        seen_org = Rhino::Context.organization
        :value
      end

      expect(returned).to eq(:value)
      expect(seen_user).to eq(inner_user)
      expect(seen_org).to eq(org_a)
      expect(Rhino::Context.user).to eq(outer_user)
      expect(Rhino::Context.organization).to eq(org_b)
    end

    it "Rhino.context returns Rhino::Context" do
      expect(Rhino.context).to eq(Rhino::Context)
    end
  end
end
