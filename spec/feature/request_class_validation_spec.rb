# frozen_string_literal: true

require "spec_helper"
require "rhino/controllers/resources_controller"
require "ostruct"

# ==========================================================================
# Request classes (Rhino::ResourceRequest) — full behavioral suite.
#
# Covers PLAN-request-validation.md §9 rows 1-15, 17, 19, 20 for Rails, plus
# the nested legacy/request-class FK asymmetry and the convention
# warn-and-fall-through path. Rows 16 and 18 are Laravel-only / Nest-only.
#
# Everything here lives on spec-local tables and `Rq`-prefixed constants.
# Convention-based discovery is GLOBAL (it constantizes
# "#{Model}StoreRequest"), so a class named PostStoreRequest would silently
# move every other Post spec in the suite onto the request-class path. The
# fixtures below are therefore named after fixtures nothing else uses.
#
# Tenancy shapes exercised:
#   RqProject  — DIRECT   (organization_id column)
#   RqTask     — INDIRECT, 1 hop  (task -> project -> organization)
#   RqComment  — INDIRECT, 2 hops (comment -> task -> project -> organization)
# ==========================================================================

ActiveRecord::Schema.define do
  create_table :rq_projects, force: true do |t|
    t.references :organization, null: true, foreign_key: true
    t.string :title
    t.timestamps
  end

  create_table :rq_tasks, force: true do |t|
    t.references :rq_project, null: true, foreign_key: { to_table: :rq_projects }
    t.string :title
    t.string :status
    t.string :priority
    t.string :source
    t.string :audit_note
    t.integer :estimated_hours
    t.timestamps
  end

  create_table :rq_comments, force: true do |t|
    t.references :rq_task, null: true, foreign_key: { to_table: :rq_tasks }
    t.text :body
    t.timestamps
  end

  # Stays on the legacy model-rules path for the whole file: the backward
  # compatibility control group.
  create_table :rq_notes, force: true do |t|
    t.references :organization, null: true, foreign_key: true
    t.string :title
    t.text :content
    t.timestamps
  end
end

# --------------------------------------------------------------------------
# Models
# --------------------------------------------------------------------------

class RqProject < ActiveRecord::Base
  include Rhino::HasRhino
  include Rhino::HasValidation
  include Rhino::HidableColumns

  belongs_to :organization, optional: true
  has_many :rq_tasks
end

class RqTask < ActiveRecord::Base
  include Rhino::HasRhino
  include Rhino::HasValidation
  include Rhino::HidableColumns

  belongs_to :rq_project, optional: true
  has_many :rq_comments

  # Model-level (legacy, deprecated) rules. They stay declared on purpose so
  # the precedence rows can prove the request class wins.
  validates :status, inclusion: { in: %w[todo doing done] }, allow_nil: true
  validates :priority, inclusion: { in: %w[low high] }, allow_nil: true
end

class RqComment < ActiveRecord::Base
  include Rhino::HasRhino
  include Rhino::HasValidation
  include Rhino::HidableColumns

  belongs_to :rq_task, optional: true
end

# No Rhino::HasValidation on purpose: run_resource_request must not blow up on
# a model that cannot answer rhino_validate_foreign_keys.
class RqBareTask < ActiveRecord::Base
  include Rhino::HasRhino
  include Rhino::HidableColumns

  self.table_name = "rq_tasks"

  belongs_to :rq_project, optional: true
end

class RqNote < ActiveRecord::Base
  include Rhino::HasRhino
  include Rhino::HasValidation
  include Rhino::HidableColumns

  belongs_to :organization, optional: true

  validates :title, length: { maximum: 10 }, allow_nil: true
end

# --------------------------------------------------------------------------
# Policies
#
# "Admin" vs "Member" is decided by User#name rather than by the role plumbing
# so these fixtures assert the request-class behavior and nothing else.
# --------------------------------------------------------------------------

def rq_admin?(user)
  user&.name == "Admin"
end

class RqTaskPolicy < Rhino::ResourcePolicy
  self.resource_slug = "rq_tasks"

  # `status` is deliberately NOT writable by a member: it is what proves the
  # forbidden-field 403 still fires BEFORE the request class runs.
  def permitted_attributes_for_create(user)
    rq_admin?(user) ? ["*"] : %w[title rq_project_id priority estimated_hours]
  end

  # `status` IS writable on update (so the record-dependent rule can be
  # exercised) while `estimated_hours` is permitted by the policy and dropped
  # by the request class — the two halves of Recommendation B.
  def permitted_attributes_for_update(user)
    rq_admin?(user) ? ["*"] : %w[title status estimated_hours]
  end
end

class RqProjectPolicy < Rhino::ResourcePolicy
  self.resource_slug = "rq_projects"
end

class RqCommentPolicy < Rhino::ResourcePolicy
  self.resource_slug = "rq_comments"
end

class RqBareTaskPolicy < Rhino::ResourcePolicy
  self.resource_slug = "rq_bare_tasks"
end

class RqNotePolicy < Rhino::ResourcePolicy
  self.resource_slug = "rq_notes"
end

# --------------------------------------------------------------------------
# Request classes
#
# RqTask* are found by CONVENTION ("RqTask" + "StoreRequest"). Everything else
# is wired up by explicit registration inside the example that needs it.
# --------------------------------------------------------------------------

# Records the context every request class was constructed with, so the specs
# can assert on `user` / `organization` / `route_group` / `action` / `record`
# without reaching into the controller.
RQ_SEEN = [] # rubocop:disable Style/MutableConstant

module RqRecordsContext
  def initialize(**kwargs)
    super
    RQ_SEEN << {
      klass: self.class.name,
      user: user,
      organization: organization,
      route_group: route_group,
      action: action,
      record: record,
      input: input
    }
  end
end

class RqTaskStoreRequest < Rhino::ResourceRequest
  prepend RqRecordsContext

  class << self
    attr_accessor :prepare_calls
  end
  self.prepare_calls = 0

  attribute :title, :string
  attribute :status, :string
  attribute :rq_project_id, :integer
  # Server-authored, added by prepare and covered by a declaration → persisted.
  attribute :source, :string

  validates :title, presence: true, length: { maximum: 40 }
  # Role-dependent rule set out of ONE class (§9 row 9): an admin may open a
  # task straight into "done"; a member may not.
  validates :status,
            inclusion: { in: %w[todo doing done] },
            allow_nil: true,
            if: -> { rq_admin?(user) }
  validates :status,
            inclusion: { in: %w[todo doing] },
            allow_nil: true,
            unless: -> { rq_admin?(user) }
  # Route-group-dependent rule (§9 row 8).
  validates :rq_project_id, presence: true, if: -> { route_group == "tenant" }

  # An `authorize?` that refuses one route group. The 403 it produces must be
  # byte-identical to a policy denial (H-6).
  def authorize?
    route_group != "public"
  end

  def prepare(input)
    self.class.prepare_calls += 1
    input.merge(
      "title" => input["title"].to_s.strip,  # normalized
      "source" => "api",                     # added AND declared  → persisted
      "audit_note" => "server-authored"      # added, NOT declared → dropped
    )
  end
end

class RqTaskUpdateRequest < Rhino::ResourceRequest
  prepend RqRecordsContext

  attribute :title, :string
  attribute :status, :string
  # `estimated_hours` is deliberately absent: the policy permits it, the
  # request class does not declare it, so it must never be written (§9 row 2).

  # No automatic partial-update relaxation: the class declares what it wants.
  validates :title, presence: true
  validate :may_not_reopen_a_finished_task

  private

  # Record-dependent rule (§9 row 7). `record` is the PRE-UPDATE row, loaded
  # organization-scoped by the controller.
  def may_not_reopen_a_finished_task
    return unless record.respond_to?(:status)
    return unless record&.status == "done"
    return if status.nil? || status == "done"
    return if rq_admin?(user)

    errors.add(:status, "cannot be reopened once the task is done")
  end
end

# Explicitly registered classes ------------------------------------------

class RqAlwaysDeniedStoreRequest < Rhino::ResourceRequest
  attribute :title, :string

  def authorize?
    false
  end
end

class RqEmptyStoreRequest < Rhino::ResourceRequest
  # No attributes and no validations at all: everything is dropped and only
  # framework-managed fields survive (§4.6, "fails closed").
end

class RqNilPrepareStoreRequest < Rhino::ResourceRequest
  attribute :title, :string

  def prepare(_input)
    nil # non-Hash → treated as "no change"
  end
end

class RqOrgSmugglingStoreRequest < Rhino::ResourceRequest
  class << self
    attr_accessor :forced_organization_id
  end

  attribute :title, :string
  attribute :organization_id, :integer

  def prepare(input)
    input.merge("organization_id" => self.class.forced_organization_id)
  end
end

class RqCommentStoreRequest2 < Rhino::ResourceRequest
  attribute :body, :string
  attribute :rq_task_id, :integer

  validates :body, presence: true
end

class RqBareTaskStoreRequest2 < Rhino::ResourceRequest
  attribute :title, :string
  attribute :rq_project_id, :integer
end

class RqProjectUpdateRequest2 < Rhino::ResourceRequest
  attribute :title, :string

  validates :title, presence: true
end

class RqNotAResourceRequest; end

RSpec.describe "Request classes (Rhino::ResourceRequest)" do
  # ------------------------------------------------------------------
  # Harness — mirrors spec/feature/member_org_scoping_spec.rb, extended with
  # route_group / organization path parameters.
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

    env = Rack::MockRequest.env_for("/api/#{params[:model_slug]}", method: method)
    env["action_dispatch.request.request_parameters"] = params.stringify_keys
    env["action_dispatch.request.path_parameters"] = {
      controller: "rhino/resources",
      action: action.to_s
    }.merge(
      params.slice(:id, :model_slug, :route_group, :organization)
            .transform_keys(&:to_s).transform_keys(&:to_sym)
    )

    headers.each { |key, value| env["HTTP_#{key.upcase.tr('-', '_')}"] = value }
    env_overrides.each { |key, value| env[key] = value }

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

  def create_user(name: "Member", permissions: ["*"])
    User.create!(
      name: name,
      email: "rq-#{SecureRandom.uuid}@example.com",
      permissions: permissions,
      api_token: SecureRandom.hex(20)
    )
  end

  def create_organization(name)
    Organization.create!(name: name, slug: "rq-#{SecureRandom.hex(6)}")
  end

  # resolve_organization 404s unless the acting user has a UserRole in the org,
  # so every membership the specs rely on is created explicitly.
  def join(user, organization)
    role = Role.create!(name: "Rq Role", slug: "rq-role-#{SecureRandom.hex(6)}", permissions: ["*"])
    UserRole.create!(user: user, organization: organization, role: role, permissions: ["*"])
  end

  def auth_headers(user)
    { "Authorization" => "Bearer #{user.api_token}" }
  end

  let(:org_a) { create_organization("Acme") }
  let(:org_b) { create_organization("Globex") }

  let(:member) { create_user(name: "Member") }
  let(:admin) { create_user(name: "Admin") }

  let(:project_a) { RqProject.create!(organization_id: org_a.id, title: "Project A") }
  let(:project_b) { RqProject.create!(organization_id: org_b.id, title: "Project B") }

  before do
    RQ_SEEN.clear
    RqTaskStoreRequest.prepare_calls = 0

    Rhino.configure do |c|
      c.model :rq_projects, "RqProject"
      c.model :rq_tasks, "RqTask"
      c.model :rq_comments, "RqComment"
      c.model :rq_bare_tasks, "RqBareTask"
      c.model :rq_notes, "RqNote"
      c.route_group :default, prefix: "", middleware: [], models: :all
      c.route_group :tenant, prefix: ":organization", middleware: [], models: :all
      c.route_group :public, prefix: "public", middleware: [], models: :all
    end
  end

  def tenant_params(org, extra = {})
    { model_slug: "rq_tasks", route_group: "tenant", organization: org.id.to_s }.merge(extra)
  end

  # ==================================================================
  # §9 row 1 — store happy path
  # ==================================================================

  describe "POST /{slug} with a request class" do
    it "returns 201 and persists only the fields the request class declares" do
      member_joined = member
      join(member_joined, org_a)

      response = call_action(
        :store,
        params: tenant_params(org_a,
          title: "  Ship it  ",
          rq_project_id: project_a.id,
          priority: "high",        # policy-permitted, NOT declared → dropped
          estimated_hours: 8),     # policy-permitted, NOT declared → dropped
        headers: auth_headers(member_joined)
      )

      expect(response.status).to eq(201)

      task = RqTask.order(:id).last
      expect(task.title).to eq("Ship it")          # normalized by prepare
      expect(task.rq_project_id).to eq(project_a.id)
      expect(task.source).to eq("api")             # added by prepare, declared
      expect(task.audit_note).to be_nil            # added by prepare, undeclared
      expect(task.priority).to be_nil              # Recommendation B: dropped
      expect(task.estimated_hours).to be_nil       # Recommendation B: dropped
    end

    it "returns the serialized record in the bare (non-enveloped) store shape" do
      join(member, org_a)

      response = call_action(
        :store,
        params: tenant_params(org_a, title: "Enveloped?", rq_project_id: project_a.id),
        headers: auth_headers(member)
      )

      expect(response.status).to eq(201)
      expect(response.body).not_to have_key("data")
      expect(response.body["title"]).to eq("Enveloped?")
      expect(response.body["id"]).to eq(RqTask.order(:id).last.id)
    end

    # §9 row 4
    it "returns 422 {errors:{field:[msg]}} when a rule fails" do
      join(member, org_a)

      response = call_action(
        :store,
        params: tenant_params(org_a, title: "   ", rq_project_id: project_a.id),
        headers: auth_headers(member)
      )

      expect(response.status).to eq(422)
      expect(response.body).to eq("errors" => { "title" => ["can't be blank"] })
      expect(RqTask.count).to eq(0)
    end

    it "reports an error on an absent required field, which the legacy path would swallow" do
      # validate_for_action only reports errors for keys the client actually
      # sent; a request class deliberately does not, because "you forgot the
      # title" is the whole point of a required rule.
      join(member, org_a)

      response = call_action(
        :store,
        params: tenant_params(org_a, rq_project_id: project_a.id),
        headers: auth_headers(member)
      )

      expect(response.status).to eq(422)
      expect(response.body["errors"]).to eq("title" => ["can't be blank"])
    end

    it "reports every failing rule for a field as an array of messages" do
      join(member, org_a)

      response = call_action(
        :store,
        params: tenant_params(org_a,
          title: "x" * 41,
          status: "bogus",
          rq_project_id: project_a.id),
        headers: auth_headers(admin_in(org_a))
      )

      expect(response.status).to eq(422)
      expect(response.body["errors"]["title"]).to eq(["is too long (maximum is 40 characters)"])
      expect(response.body["errors"]["status"]).to eq(["is not included in the list"])
    end
  end

  def admin_in(org)
    admin.tap { |u| join(u, org) }
  end

  # ==================================================================
  # §9 row 3 — authorize? ⇒ 403, indistinguishable from a policy denial
  # ==================================================================

  describe "authorize? returning false" do
    it "returns 403 with the exact policy-denial body and persists nothing" do
      # The "public" route group is the one RqTaskStoreRequest#authorize? refuses.
      response = call_action(
        :store,
        params: { model_slug: "rq_tasks", route_group: "public", title: "Nope" },
        headers: auth_headers(member)
      )

      expect(response.status).to eq(403)
      expect(response.body).to eq("message" => "This action is unauthorized.")
      expect(RqTask.count).to eq(0)
    end

    it "is byte-identical to a policy denial on the same endpoint (information leak guard)" do
      denied_by_request_class = call_action(
        :store,
        params: { model_slug: "rq_tasks", route_group: "public", title: "Nope" },
        headers: auth_headers(member)
      )

      # A user with no permissions fails the Pundit create? gate instead.
      powerless = create_user(name: "Member", permissions: [])
      denied_by_policy = call_action(
        :store,
        params: { model_slug: "rq_tasks", title: "Nope" },
        headers: auth_headers(powerless)
      )

      expect(denied_by_policy.status).to eq(denied_by_request_class.status)
      expect(denied_by_policy.body).to eq(denied_by_request_class.body)
    end

    it "runs prepare BEFORE authorize?, so authorize? sees normalized input" do
      # §4.2: prepare is step 5a, authorize? is 5b.
      call_action(
        :store,
        params: { model_slug: "rq_tasks", route_group: "public", title: "  padded  " },
        headers: auth_headers(member)
      )

      expect(RqTaskStoreRequest.prepare_calls).to eq(1)
      expect(RQ_SEEN.last[:input]["title"]).to eq("padded")
    end

    it "returns 403 from an explicitly registered class whose authorize? is always false" do
      Rhino.configure { |c| c.model :rq_projects, "RqProject", store_request: "RqAlwaysDeniedStoreRequest" }

      response = call_action(
        :store,
        params: { model_slug: "rq_projects", title: "Nope" },
        headers: auth_headers(member)
      )

      expect(response.status).to eq(403)
      expect(response.body).to eq("message" => "This action is unauthorized.")
      expect(RqProject.count).to eq(0)
    end
  end

  # ==================================================================
  # §9 row 6 — prepare cannot launder a field past the policy
  # ==================================================================

  describe "the forbidden-field gate relative to the request class" do
    it "returns 403 and never constructs the request class when the client sends a denied field" do
      join(member, org_a)

      response = call_action(
        :store,
        params: tenant_params(org_a,
          title: "Sneaky",
          status: "done",           # not in permitted_attributes_for_create for a member
          rq_project_id: project_a.id),
        headers: auth_headers(member)
      )

      expect(response.status).to eq(403)
      expect(response.body).to eq(
        "message" => "You are not allowed to set the following field(s): status"
      )
      # The gate is step 4 and the request class is step 5: prepare must not have run.
      expect(RqTaskStoreRequest.prepare_calls).to eq(0)
      expect(RQ_SEEN).to be_empty
      expect(RqTask.count).to eq(0)
    end

    it "lets a field the request class adds through even though the policy denies it" do
      # H-12: prepare output is server-authored and is NOT re-checked against
      # permitted_attributes_*. `source` is not in the member's permitted list,
      # and it is still persisted because the request class authored it.
      join(member, org_a)

      expect(RqTaskPolicy.new(member, RqTask).permitted_attributes_for_create(member))
        .not_to include("source")

      call_action(
        :store,
        params: tenant_params(org_a, title: "Ok", rq_project_id: project_a.id),
        headers: auth_headers(member)
      )

      expect(RqTask.order(:id).last.source).to eq("api")
    end

    it "does not narrow the request class's rules to the policy's permitted fields" do
      # §4.3 "no automatic narrowing": the member cannot send rq_project_id?
      # It can — but in the tenant group the class REQUIRES it, and Rhino will
      # not relax that requirement because of the policy. A member that omits
      # the field gets a 422, not a silently narrowed rule set.
      join(member, org_a)

      response = call_action(
        :store,
        params: tenant_params(org_a, title: "No project"),
        headers: auth_headers(member)
      )

      expect(response.status).to eq(422)
      expect(response.body["errors"]).to eq("rq_project_id" => ["can't be blank"])
    end

    it "does not blow up when prepare receives a non-String value" do
      # prepare runs BEFORE the validations (§4.2 step 5a), so it sees RAW
      # client input: {"title": ["x"]} reaches it as an Array. An unguarded
      # `.strip` would be a NoMethodError -> 500, and an unguarded `.to_s.strip`
      # would silently turn it into the string '["x"]' and let it through.
      # A guarded prepare leaves it alone for a validation to reject with 422.
      stub_const("RqShapeNote", Class.new(RqNote) do
        def self.name = "RqShapeNote"
      end)
      stub_const("RqShapeNoteStoreRequest", Class.new(Rhino::ResourceRequest) do
        attribute :title, :string

        validates :title, presence: true
        validate :title_must_be_text

        def prepare(input)
          title = input["title"]
          input.merge("title" => title.is_a?(String) ? title.strip : title)
        end

        private

        # `attribute :title, :string` casts ["x"] to '["x"]', so the shape has
        # to be checked against the RAW input, not the cast value.
        def title_must_be_text
          return if input["title"].nil? || input["title"].is_a?(String)

          errors.add(:title, "must be a string")
        end
      end)
      stub_const("RqShapeNotePolicy", Class.new(Rhino::ResourcePolicy) do
        self.resource_slug = "rq_shape_notes"
      end)
      Rhino.configure { |c| c.model :rq_shape_notes, "RqShapeNote" }

      response = call_action(
        :store,
        params: { model_slug: "rq_shape_notes", title: ["x"] },
        headers: auth_headers(member)
      )

      expect(response.status).to eq(422)
      expect(response.body["errors"]).to eq("title" => ["must be a string"])
      expect(RqShapeNote.count).to eq(0)
    end
  end

  # ==================================================================
  # §9 rows 2, 7 — update
  # ==================================================================

  describe "PUT /{slug}/:id with a request class" do
    let!(:task) do
      RqTask.create!(rq_project_id: project_a.id, title: "Before", status: "todo",
                     priority: "low", estimated_hours: 5)
    end

    it "returns 200 and writes only the declared attributes" do
      join(member, org_a)

      response = call_action(
        :update,
        params: tenant_params(org_a, id: task.id, title: "After", estimated_hours: 99),
        headers: auth_headers(member)
      )

      expect(response.status).to eq(200)
      task.reload
      expect(task.title).to eq("After")
      # Policy permits estimated_hours; RqTaskUpdateRequest declares no attribute
      # for it, so Recommendation B drops it. THIS is the backward-incompatible
      # surprise the plan calls out in H-13, asserted so it cannot drift.
      expect(task.estimated_hours).to eq(5)
      expect(task.priority).to eq("low")
    end

    it "returns 422 when a rule fails, leaving the record untouched" do
      join(member, org_a)

      response = call_action(
        :update,
        params: tenant_params(org_a, id: task.id, title: ""),
        headers: auth_headers(member)
      )

      expect(response.status).to eq(422)
      expect(response.body).to eq("errors" => { "title" => ["can't be blank"] })
      expect(task.reload.title).to eq("Before")
    end

    it "does not relax a required rule just because the key is absent (no partial-update relaxation)" do
      join(member, org_a)

      response = call_action(
        :update,
        params: tenant_params(org_a, id: task.id, estimated_hours: 3),
        headers: auth_headers(member)
      )

      expect(response.status).to eq(422)
      expect(response.body["errors"]).to eq("title" => ["can't be blank"])
    end

    it "receives the PRE-UPDATE record and can reject a transition based on it" do
      task.update!(status: "done")
      join(member, org_a)

      response = call_action(
        :update,
        params: tenant_params(org_a, id: task.id, title: "Reopen me", status: "todo"),
        headers: auth_headers(member)
      )

      expect(response.status).to eq(422)
      expect(response.body["errors"]).to eq(
        "status" => ["cannot be reopened once the task is done"]
      )
      expect(RQ_SEEN.last[:record]).to eq(task)
      expect(RQ_SEEN.last[:record].status).to eq("done") # pre-update state
      expect(task.reload.title).to eq("Before")
    end

    it "lets the same record-dependent rule pass for a user it exempts" do
      task.update!(status: "done")
      acting = admin
      join(acting, org_a)

      response = call_action(
        :update,
        params: tenant_params(org_a, id: task.id, title: "Reopened", status: "todo"),
        headers: auth_headers(acting)
      )

      expect(response.status).to eq(200)
      expect(task.reload.status).to eq("todo")
    end

    it "sets action to \"update\" and record to nil-free context on the update path" do
      join(member, org_a)

      call_action(
        :update,
        params: tenant_params(org_a, id: task.id, title: "Ctx"),
        headers: auth_headers(member)
      )

      seen = RQ_SEEN.last
      expect(seen[:klass]).to eq("RqTaskUpdateRequest")
      expect(seen[:action]).to eq("update")
      expect(seen[:record]).to eq(task)
      expect(seen[:user]).to eq(member)
    end
  end

  # ==================================================================
  # §9 rows 8, 9, 10 — the request context
  # ==================================================================

  describe "the request context" do
    it "carries action=store, record=nil and the authenticated user on store" do
      join(member, org_a)

      call_action(
        :store,
        params: tenant_params(org_a, title: "Ctx", rq_project_id: project_a.id),
        headers: auth_headers(member)
      )

      seen = RQ_SEEN.last
      expect(seen[:klass]).to eq("RqTaskStoreRequest")
      expect(seen[:action]).to eq("store")
      expect(seen[:record]).to be_nil
      expect(seen[:user]).to eq(member)
    end

    it "carries the matched route group" do
      join(member, org_a)

      call_action(
        :store,
        params: tenant_params(org_a, title: "Ctx", rq_project_id: project_a.id),
        headers: auth_headers(member)
      )
      expect(RQ_SEEN.last[:route_group]).to eq("tenant")

      call_action(
        :store,
        params: { model_slug: "rq_tasks", route_group: "public", title: "Ctx" },
        headers: auth_headers(member)
      )
      expect(RQ_SEEN.last[:route_group]).to eq("public")
    end

    it "applies a route-group-dependent rule only in the group that declares it" do
      join(member, org_a)

      # tenant: rq_project_id is required
      tenant = call_action(
        :store,
        params: tenant_params(org_a, title: "Grouped"),
        headers: auth_headers(member)
      )
      expect(tenant.status).to eq(422)
      expect(tenant.body["errors"]).to have_key("rq_project_id")

      # default (no group): the same class imposes no such rule
      default = call_action(
        :store,
        params: { model_slug: "rq_tasks", title: "Grouped" },
        headers: auth_headers(member)
      )
      expect(default.status).to eq(201)
      expect(RqTask.order(:id).last.rq_project_id).to be_nil
    end

    it "carries the resolved organization inside a tenant group" do
      join(member, org_a)

      call_action(
        :store,
        params: tenant_params(org_a, title: "Org", rq_project_id: project_a.id),
        headers: auth_headers(member)
      )

      expect(RQ_SEEN.last[:organization]).to eq(org_a)
    end

    it "carries a nil organization outside a tenant group (single-tenant shape)" do
      call_action(
        :store,
        params: { model_slug: "rq_tasks", title: "No org" },
        headers: auth_headers(member)
      )

      expect(RQ_SEEN.last[:organization]).to be_nil
    end

    it "gives an admin and a member different rule sets from ONE class" do
      acting_admin = admin
      join(acting_admin, org_a)
      join(member, org_a)

      # Admin may open a task directly as "done".
      as_admin = call_action(
        :store,
        params: tenant_params(org_a, title: "Admin", status: "done", rq_project_id: project_a.id),
        headers: auth_headers(acting_admin)
      )
      expect(as_admin.status).to eq(201)
      expect(RqTask.order(:id).last.status).to eq("done")

      # A member may not — but the policy denies the field outright first, so
      # the role split is asserted at the validation layer through the admin's
      # own request (above) plus the member's 403 (below).
      as_member = call_action(
        :store,
        params: tenant_params(org_a, title: "Member", status: "done", rq_project_id: project_a.id),
        headers: auth_headers(member)
      )
      expect(as_member.status).to eq(403)
    end

    it "applies the member's narrower inclusion rule when the policy does permit the field" do
      # Admin policy permits everything, so send "done" as an admin (allowed)
      # and the same value as an admin-named user whose *request-class* branch
      # is the member one, proving the branch is the user's, not the policy's.
      acting = create_user(name: "Member", permissions: ["*"])
      join(acting, org_a)

      # Temporarily widen the policy so the field reaches the request class.
      allow_any_instance_of(RqTaskPolicy).to receive(:permitted_attributes_for_create).and_return(["*"])

      response = call_action(
        :store,
        params: tenant_params(org_a, title: "Member", status: "done", rq_project_id: project_a.id),
        headers: auth_headers(acting)
      )

      expect(response.status).to eq(422)
      expect(response.body["errors"]).to eq("status" => ["is not included in the list"])
    end
  end

  # ==================================================================
  # §9 row 11 — cross-tenant foreign keys on the request-class path
  # ==================================================================

  describe "cross-tenant FK scoping on the request-class path" do
    it "accepts a DIRECT-tenancy FK that belongs to the current organization" do
      join(member, org_a)

      response = call_action(
        :store,
        params: tenant_params(org_a, title: "Mine", rq_project_id: project_a.id),
        headers: auth_headers(member)
      )

      expect(response.status).to eq(201)
      expect(RqTask.order(:id).last.rq_project_id).to eq(project_a.id)
    end

    it "rejects a DIRECT-tenancy FK owned by another organization" do
      # rq_projects has an organization_id column, so this is the direct branch
      # of validate_foreign_keys_for_organization.
      join(member, org_a)
      other = project_b

      response = call_action(
        :store,
        params: tenant_params(org_a, title: "Yours", rq_project_id: other.id),
        headers: auth_headers(member)
      )

      expect(response.status).to eq(422)
      expect(response.body).to eq(
        "errors" => { "rq_project_id" => ["does not belong to your organization"] }
      )
      expect(RqTask.count).to eq(0)
    end

    it "rejects an INDIRECT (2-hop) FK owned by another organization" do
      # rq_comments -> rq_tasks -> rq_projects -> organizations. rq_tasks has NO
      # organization_id column, so this can only pass through the FK-chain walk.
      # This is the shape that has leaked historically.
      Rhino.configure { |c| c.model :rq_comments, "RqComment", store_request: "RqCommentStoreRequest2" }
      join(member, org_a)

      foreign_task = RqTask.create!(rq_project_id: project_b.id, title: "Theirs")

      response = call_action(
        :store,
        params: { model_slug: "rq_comments", route_group: "tenant", organization: org_a.id.to_s,
                  body: "Hi", rq_task_id: foreign_task.id },
        headers: auth_headers(member)
      )

      expect(response.status).to eq(422)
      expect(response.body).to eq(
        "errors" => { "rq_task_id" => ["does not belong to your organization"] }
      )
      expect(RqComment.count).to eq(0)
    end

    it "accepts an INDIRECT (2-hop) FK owned by the current organization" do
      Rhino.configure { |c| c.model :rq_comments, "RqComment", store_request: "RqCommentStoreRequest2" }
      join(member, org_a)

      own_task = RqTask.create!(rq_project_id: project_a.id, title: "Mine")

      response = call_action(
        :store,
        params: { model_slug: "rq_comments", route_group: "tenant", organization: org_a.id.to_s,
                  body: "Hi", rq_task_id: own_task.id },
        headers: auth_headers(member)
      )

      expect(response.status).to eq(201)
      expect(RqComment.order(:id).last.rq_task_id).to eq(own_task.id)
    end

    it "merges FK errors with the request class's own rule errors in one 422 body" do
      Rhino.configure { |c| c.model :rq_comments, "RqComment", store_request: "RqCommentStoreRequest2" }
      join(member, org_a)

      foreign_task = RqTask.create!(rq_project_id: project_b.id, title: "Theirs")

      response = call_action(
        :store,
        params: { model_slug: "rq_comments", route_group: "tenant", organization: org_a.id.to_s,
                  body: "", rq_task_id: foreign_task.id },
        headers: auth_headers(member)
      )

      expect(response.status).to eq(422)
      expect(response.body["errors"]).to eq(
        "body" => ["can't be blank"],
        "rq_task_id" => ["does not belong to your organization"]
      )
    end

    it "runs no FK check at all outside a tenant context" do
      Rhino.configure { |c| c.model :rq_comments, "RqComment", store_request: "RqCommentStoreRequest2" }
      foreign_task = RqTask.create!(rq_project_id: project_b.id, title: "Theirs")

      response = call_action(
        :store,
        params: { model_slug: "rq_comments", body: "Hi", rq_task_id: foreign_task.id },
        headers: auth_headers(member)
      )

      expect(response.status).to eq(201)
    end

    it "does not blow up for a model that does not include Rhino::HasValidation" do
      Rhino.configure { |c| c.model :rq_bare_tasks, "RqBareTask", store_request: "RqBareTaskStoreRequest2" }
      join(member, org_a)

      response = call_action(
        :store,
        params: { model_slug: "rq_bare_tasks", route_group: "tenant", organization: org_a.id.to_s,
                  title: "Bare", rq_project_id: project_a.id },
        headers: auth_headers(member)
      )

      expect(response.status).to eq(201)
    end

    it "strips a client-sent organization_id before the request class ever sees it" do
      Rhino.configure { |c| c.model :rq_projects, "RqProject", store_request: "RqOrgSmugglingStoreRequest" }
      RqOrgSmugglingStoreRequest.forced_organization_id = nil
      join(member, org_a)

      response = call_action(
        :store,
        params: { model_slug: "rq_projects", route_group: "tenant", organization: org_a.id.to_s,
                  title: "Mine", organization_id: org_b.id },
        headers: auth_headers(member)
      )

      expect(response.status).to eq(201)
      expect(RqProject.order(:id).last.organization_id).to eq(org_a.id)
    end

    it "overwrites an organization_id that prepare tries to force (framework wins last)" do
      # §4.2 step 7: framework-managed fields are applied LAST and unconditionally.
      Rhino.configure { |c| c.model :rq_projects, "RqProject", store_request: "RqOrgSmugglingStoreRequest" }
      join(member, org_a)
      RqOrgSmugglingStoreRequest.forced_organization_id = org_b.id

      response = call_action(
        :store,
        params: { model_slug: "rq_projects", route_group: "tenant", organization: org_a.id.to_s,
                  title: "Mine" },
        headers: auth_headers(member)
      )

      expect(response.status).to eq(201)
      expect(RqProject.order(:id).last.organization_id).to eq(org_a.id)
    ensure
      RqOrgSmugglingStoreRequest.forced_organization_id = nil
    end
  end

  # ==================================================================
  # §9 row 20 — cross-tenant isolation end to end, on the new path
  # ==================================================================

  describe "cross-tenant isolation for records created through a request class" do
    it "keeps a record created by org A invisible and unwritable to org B" do
      # NON-VACUOUS: both organizations own rows, with different counts.
      alice = create_user(name: "Member")
      eve = create_user(name: "Member")
      join(alice, org_a)
      join(eve, org_b)

      2.times do |i|
        call_action(:store,
                    params: tenant_params(org_a, title: "A#{i}", rq_project_id: project_a.id),
                    headers: auth_headers(alice))
      end
      3.times do |i|
        call_action(:store,
                    params: tenant_params(org_b, title: "B#{i}", rq_project_id: project_b.id),
                    headers: auth_headers(eve))
      end
      expect(RqTask.count).to eq(5)

      a_index = call_action(:index, params: tenant_params(org_a), headers: auth_headers(alice))
      b_index = call_action(:index, params: tenant_params(org_b), headers: auth_headers(eve))

      expect(a_index.body["data"].length).to eq(2)
      expect(b_index.body["data"].length).to eq(3)
      expect(a_index.body["data"].map { |r| r["title"] }).to match_array(%w[A0 A1])
      expect(b_index.body["data"].map { |r| r["title"] }).to match_array(%w[B0 B1 B2])

      a_task = RqTask.find_by(title: "A0")

      expect {
        call_action(:show, params: tenant_params(org_b, id: a_task.id), headers: auth_headers(eve))
      }.to raise_error(ActiveRecord::RecordNotFound)

      expect {
        call_action(:update,
                    params: tenant_params(org_b, id: a_task.id, title: "Hacked"),
                    headers: auth_headers(eve))
      }.to raise_error(ActiveRecord::RecordNotFound)

      expect(a_task.reload.title).to eq("A0")
    end
  end

  # ==================================================================
  # §9 rows 13, 14, 15 — precedence and the legacy path
  # ==================================================================

  describe "precedence over legacy model-level rules" do
    it "applies the request class's stricter rule instead of the model's looser one" do
      # RqTask allows status in todo/doing/done; RqTaskStoreRequest allows only
      # todo/doing for a member. The request class wins.
      acting = create_user(name: "Member", permissions: ["*"])
      join(acting, org_a)
      allow_any_instance_of(RqTaskPolicy).to receive(:permitted_attributes_for_create).and_return(["*"])

      response = call_action(
        :store,
        params: tenant_params(org_a, title: "T", status: "done", rq_project_id: project_a.id),
        headers: auth_headers(acting)
      )

      expect(response.status).to eq(422)
      expect(response.body["errors"]).to eq("status" => ["is not included in the list"])
    end

    it "never runs a model rule for a field the request class does not declare" do
      # `priority` has a model-level inclusion rule that the legacy path WOULD
      # apply (and fail on). The request class declares no `priority`, so the
      # field is dropped before it can reach any validation at all.
      join(member, org_a)

      response = call_action(
        :store,
        params: tenant_params(org_a, title: "T", priority: "bogus", rq_project_id: project_a.id),
        headers: auth_headers(member)
      )

      expect(response.status).to eq(201)
      expect(RqTask.order(:id).last.priority).to be_nil

      # Control: the same payload on the legacy path (a model with no request
      # class) does surface its model rule.
      legacy = RqTask.new.validate_for_action({ "priority" => "bogus" }, permitted_fields: ["*"])
      expect(legacy[:valid]).to be false
      expect(legacy[:errors]).to eq("priority" => ["is not included in the list"])
    end

    # A model rule STRICTER than the request class is not consulted for the
    # rules 422 (the request class owns the shape contract), but it still runs
    # inside create!/update!. It must surface as the SAME 422 envelope rather
    # than escaping as ActiveRecord::RecordInvalid — a 500. The legacy path
    # never reaches this rescue: validate_for_action ran those very rules first.
    describe "a model rule stricter than the request class" do
      before do
        stub_const("RqStrictNote", Class.new(RqNote) do
          def self.name = "RqStrictNote"
          validates :title, length: { maximum: 3 }, allow_nil: true
        end)
        stub_const("RqStrictNoteStoreRequest", Class.new(Rhino::ResourceRequest) do
          attribute :title, :string
          validates :title, presence: true # looser than the model rule
        end)
        stub_const("RqStrictNoteUpdateRequest", Class.new(Rhino::ResourceRequest) do
          attribute :title, :string
          validates :title, presence: true # looser than the model rule
        end)
        stub_const("RqStrictNotePolicy", Class.new(Rhino::ResourcePolicy) do
          self.resource_slug = "rq_strict_notes"
        end)
        Rhino.configure { |c| c.model :rq_strict_notes, "RqStrictNote" }
      end

      it "returns 422 instead of raising on store" do
        response = call_action(
          :store,
          params: { model_slug: "rq_strict_notes", title: "abcde" },
          headers: auth_headers(member)
        )

        expect(response.status).to eq(422)
        expect(response.body["errors"]).to eq(
          "title" => ["is too long (maximum is 3 characters)"]
        )
        expect(RqStrictNote.count).to eq(0)
      end

      it "returns 422 instead of raising on update, leaving the row untouched" do
        note = RqStrictNote.create!(title: "ok")

        response = call_action(
          :update,
          params: { model_slug: "rq_strict_notes", id: note.id, title: "abcde" },
          headers: auth_headers(member)
        )

        expect(response.status).to eq(422)
        expect(response.body["errors"]).to eq(
          "title" => ["is too long (maximum is 3 characters)"]
        )
        expect(note.reload.title).to eq("ok")
      end

      # Runs outside the suite's wrapping transaction: the controller's own
      # transaction would otherwise just join it, making its ActiveRecord::
      # Rollback a no-op and the rollback unassertable. Cleans up after itself.
      it "returns the nested envelope and rolls the whole transaction back", :no_db_transaction do
        response = call_action(
          :nested,
          params: {
            model_slug: "rq_strict_notes",
            operations: [
              { model: "rq_strict_notes", action: "create", data: { title: "ok" } },
              { model: "rq_strict_notes", action: "create", data: { title: "abcde" } }
            ]
          },
          headers: auth_headers(member)
        )

        expect(response.status).to eq(422)
        expect(response.body).to eq(
          "message" => "Validation failed.",
          "errors" => {
            "operations.1.data.title" => ["is too long (maximum is 3 characters)"]
          }
        )
        # Operation 0 saved successfully before operation 1 failed; the
        # transaction must have rolled it back.
        expect(RqStrictNote.count).to eq(0)
      ensure
        RqNote.delete_all
        UserRole.delete_all
        Role.delete_all
        Organization.delete_all
        User.delete_all
      end

      it "still raises on the legacy path, which validated up front" do
        # RqNote has no request class: validate_for_action already ran the
        # model rules, so a RecordInvalid here would be a genuine bug, and the
        # rescue must not swallow it.
        expect(Rhino::ResourcesController.new.respond_to?(:record_validation_errors, true)).to be true

        response = call_action(
          :store,
          params: { model_slug: "rq_notes", title: "way way too long" },
          headers: auth_headers(member)
        )

        expect(response.status).to eq(422)
        expect(response.body["errors"]).to eq(
          "title" => ["is too long (maximum is 10 characters)"]
        )
      end
    end

    it "keeps update on the legacy path when only a StoreRequest is declared" do
      # RqProject has no conventional request classes; give it a store one only.
      Rhino.configure { |c| c.model :rq_projects, "RqProject", store_request: "RqEmptyStoreRequest" }

      project = RqProject.create!(title: "Legacy", organization_id: nil)

      response = call_action(
        :update,
        params: { model_slug: "rq_projects", id: project.id, title: "Legacy updated" },
        headers: auth_headers(member)
      )

      expect(response.status).to eq(200)
      expect(project.reload.title).to eq("Legacy updated")
      # Nothing was constructed: no update request class exists.
      expect(RQ_SEEN).to be_empty
    end
  end

  describe "the legacy path with no request class (backward compatibility)" do
    it "returns the 4.9.0 422 body for a model-level rule failure" do
      response = call_action(
        :store,
        params: { model_slug: "rq_notes", title: "way too long a title" },
        headers: auth_headers(member)
      )

      expect(response.status).to eq(422)
      expect(response.body).to eq(
        "errors" => { "title" => ["is too long (maximum is 10 characters)"] }
      )
    end

    it "still persists every policy-permitted field it was sent" do
      response = call_action(
        :store,
        params: { model_slug: "rq_notes", title: "Short", content: "Kept" },
        headers: auth_headers(member)
      )

      expect(response.status).to eq(201)
      note = RqNote.order(:id).last
      expect(note.title).to eq("Short")
      # The legacy path does NOT drop undeclared fields — Recommendation B is
      # scoped to the request-class path only.
      expect(note.content).to eq("Kept")
    end

    it "is byte-identical when a conventional constant exists but is not a ResourceRequest" do
      baseline = call_action(
        :store,
        params: { model_slug: "rq_notes", title: "way too long a title" },
        headers: auth_headers(member)
      )

      stub_const("RqNoteStoreRequest", Class.new)
      # spec_helper's Rails.logger builds a NEW Logger on every call, so the
      # logger itself has to be stubbed at the Rails.logger seam.
      logger = double("Logger").as_null_object
      allow(Rails).to receive(:logger).and_return(logger)

      with_impostor = call_action(
        :store,
        params: { model_slug: "rq_notes", title: "way too long a title" },
        headers: auth_headers(member)
      )

      expect(with_impostor.status).to eq(baseline.status)
      expect(with_impostor.body).to eq(baseline.body)
      expect(logger).to have_received(:warn).with(
        "Rhino: ignoring RqNoteStoreRequest for [rq_notes.store]: " \
        "it does not inherit from Rhino::ResourceRequest"
      )
    end
  end

  # ==================================================================
  # §9 row 17 — explicit registration
  # ==================================================================

  describe "explicit registration" do
    it "uses the explicitly registered class for store" do
      Rhino.configure { |c| c.model :rq_projects, "RqProject", store_request: "RqEmptyStoreRequest" }

      response = call_action(
        :store,
        params: { model_slug: "rq_projects", title: "Dropped" },
        headers: auth_headers(member)
      )

      # An empty request class declares nothing, so EVERYTHING is dropped.
      expect(response.status).to eq(201)
      expect(RqProject.order(:id).last.title).to be_nil
    end

    it "beats the naming convention" do
      Rhino.configure { |c| c.model :rq_tasks, "RqTask", store_request: "RqNilPrepareStoreRequest" }

      response = call_action(
        :store,
        params: { model_slug: "rq_tasks", title: "Explicit wins" },
        headers: auth_headers(member)
      )

      expect(response.status).to eq(201)
      # RqTaskStoreRequest would have set source="api"; the explicit class does not.
      expect(RqTask.order(:id).last.source).to be_nil
      expect(RqTask.order(:id).last.title).to eq("Explicit wins")
    end

    it "raises Rhino::ConfigurationError for a class name that cannot be constantized" do
      Rhino.configure { |c| c.model :rq_projects, "RqProject", store_request: "NoSuchRqRequestClass" }

      expect {
        call_action(:store, params: { model_slug: "rq_projects", title: "x" },
                            headers: auth_headers(member))
      }.to raise_error(
        Rhino::ConfigurationError,
        "Rhino: request class [NoSuchRqRequestClass] configured for [rq_projects.store] does not exist."
      )
      expect(RqProject.count).to eq(0)
    end

    it "raises Rhino::ConfigurationError for a class that is not a Rhino::ResourceRequest" do
      Rhino.configure { |c| c.model :rq_projects, "RqProject", update_request: "RqNotAResourceRequest" }
      project = RqProject.create!(title: "x")

      expect {
        call_action(:update, params: { model_slug: "rq_projects", id: project.id, title: "y" },
                             headers: auth_headers(member))
      }.to raise_error(
        Rhino::ConfigurationError,
        "Rhino: request class [RqNotAResourceRequest] configured for [rq_projects.update] does not exist."
      )
    end
  end

  # ==================================================================
  # §9 row 12 — nested operations
  # ==================================================================

  describe "POST /nested" do
    it "validates a create operation through the store request class" do
      join(member, org_a)

      response = call_action(
        :nested,
        params: {
          model_slug: "rq_tasks", route_group: "tenant", organization: org_a.id.to_s,
          operations: [
            { model: "rq_tasks", action: "create",
              data: { title: "  Nested  ", rq_project_id: project_a.id, priority: "high" } }
          ]
        },
        headers: auth_headers(member)
      )

      expect(response.status).to eq(200)
      task = RqTask.order(:id).last
      expect(task.title).to eq("Nested")     # prepare ran
      expect(task.source).to eq("api")       # declared field prepare added
      expect(task.priority).to be_nil        # undeclared → dropped
      expect(RQ_SEEN.last[:klass]).to eq("RqTaskStoreRequest")
      expect(RQ_SEEN.last[:route_group]).to eq("tenant")
    end

    it "validates an update operation through the update request class with the record populated" do
      join(member, org_a)
      task = RqTask.create!(rq_project_id: project_a.id, title: "Before", status: "todo")

      response = call_action(
        :nested,
        params: {
          model_slug: "rq_tasks", route_group: "tenant", organization: org_a.id.to_s,
          operations: [
            { model: "rq_tasks", action: "update", id: task.id, data: { title: "After" } }
          ]
        },
        headers: auth_headers(member)
      )

      expect(response.status).to eq(200)
      expect(task.reload.title).to eq("After")

      seen = RQ_SEEN.last
      expect(seen[:klass]).to eq("RqTaskUpdateRequest")
      expect(seen[:action]).to eq("update")
      expect(seen[:record]).to eq(task)
    end

    it "applies a record-dependent rule inside a nested update" do
      join(member, org_a)
      task = RqTask.create!(rq_project_id: project_a.id, title: "Done one", status: "done")

      response = call_action(
        :nested,
        params: {
          model_slug: "rq_tasks", route_group: "tenant", organization: org_a.id.to_s,
          operations: [
            { model: "rq_tasks", action: "update", id: task.id,
              data: { title: "Reopen", status: "todo" } }
          ]
        },
        headers: auth_headers(member)
      )

      expect(response.status).to eq(422)
      expect(response.body).to eq(
        "message" => "Validation failed.",
        "errors" => {
          "operations.0.data.status" => ["cannot be reopened once the task is done"]
        }
      )
      expect(task.reload.title).to eq("Done one")
    end

    it "returns today's nested envelope for a request-class rule failure and executes nothing" do
      join(member, org_a)

      response = call_action(
        :nested,
        params: {
          model_slug: "rq_tasks", route_group: "tenant", organization: org_a.id.to_s,
          operations: [
            { model: "rq_tasks", action: "create",
              data: { title: "Fine", rq_project_id: project_a.id } },
            { model: "rq_tasks", action: "create",
              data: { title: "", rq_project_id: project_a.id } }
          ]
        },
        headers: auth_headers(member)
      )

      expect(response.status).to eq(422)
      expect(response.body).to eq(
        "message" => "Validation failed.",
        "errors" => { "operations.1.data.title" => ["can't be blank"] }
      )
      # Operation 0 was valid; nothing may be written when a later one fails.
      expect(RqTask.count).to eq(0)
    end

    it "returns the standard 403 when a nested operation's authorize? refuses" do
      response = call_action(
        :nested,
        params: {
          model_slug: "rq_tasks", route_group: "public",
          operations: [
            { model: "rq_tasks", action: "create", data: { title: "Nope" } }
          ]
        },
        headers: auth_headers(member)
      )

      expect(response.status).to eq(403)
      expect(response.body).to eq("message" => "This action is unauthorized.")
      expect(RqTask.count).to eq(0)
    end

    it "keeps the forbidden-field 403 ahead of the request class in nested too" do
      join(member, org_a)

      response = call_action(
        :nested,
        params: {
          model_slug: "rq_tasks", route_group: "tenant", organization: org_a.id.to_s,
          operations: [
            { model: "rq_tasks", action: "create", data: { title: "x", status: "done" } }
          ]
        },
        headers: auth_headers(member)
      )

      expect(response.status).to eq(403)
      expect(response.body).to eq(
        "message" => "You are not allowed to set the following field(s): status"
      )
      expect(RqTaskStoreRequest.prepare_calls).to eq(0)
    end

    # ---- the deliberate nested FK asymmetry ------------------------
    #
    # validate_nested_operation's LEGACY branch calls validate_for_action
    # WITHOUT an organization, so it performs no cross-tenant FK check. The
    # request-class branch does perform one. Both halves are asserted so the
    # asymmetry is a recorded decision rather than an accident.

    it "does NOT run the cross-tenant FK check on the legacy nested path" do
      join(member, org_a)
      foreign_task = RqTask.create!(rq_project_id: project_b.id, title: "Theirs")

      response = call_action(
        :nested,
        params: {
          model_slug: "rq_comments", route_group: "tenant", organization: org_a.id.to_s,
          operations: [
            { model: "rq_comments", action: "create",
              data: { body: "Leaks", rq_task_id: foreign_task.id } }
          ]
        },
        headers: auth_headers(member)
      )

      expect(response.status).to eq(200)
      expect(RqComment.order(:id).last.rq_task_id).to eq(foreign_task.id)
    end

    it "DOES run the cross-tenant FK check on the request-class nested path" do
      Rhino.configure { |c| c.model :rq_comments, "RqComment", store_request: "RqCommentStoreRequest2" }
      join(member, org_a)
      foreign_task = RqTask.create!(rq_project_id: project_b.id, title: "Theirs")

      response = call_action(
        :nested,
        params: {
          model_slug: "rq_comments", route_group: "tenant", organization: org_a.id.to_s,
          operations: [
            { model: "rq_comments", action: "create",
              data: { body: "Leaks", rq_task_id: foreign_task.id } }
          ]
        },
        headers: auth_headers(member)
      )

      expect(response.status).to eq(422)
      expect(response.body).to eq(
        "message" => "Validation failed.",
        "errors" => {
          "operations.0.data.rq_task_id" => ["does not belong to your organization"]
        }
      )
      expect(RqComment.count).to eq(0)
    end

    # ---- cross-tenant writes through nested ------------------------
    #
    # The request-class branch resolves `record` with an org-scoped,
    # NON-failing lookup, so a cross-org id must still be stopped by
    # authorize_nested_operation's own org-scoped lookup and produce today's
    # RecordNotFound — the validation step must not turn it into a 422, and
    # the row must not be written. See the matching legacy-path suite in
    # spec/feature/member_org_scoping_spec.rb.

    it "refuses a nested update of another org's INDIRECTLY owned row" do
      join(member, org_a)
      foreign = RqTask.create!(rq_project_id: project_b.id, title: "Theirs", status: "todo")

      expect {
        call_action(
          :nested,
          params: {
            model_slug: "rq_tasks", route_group: "tenant", organization: org_a.id.to_s,
            operations: [
              { model: "rq_tasks", action: "update", id: foreign.id, data: { title: "Hacked" } }
            ]
          },
          headers: auth_headers(member)
        )
      }.to raise_error(ActiveRecord::RecordNotFound)

      expect(foreign.reload.title).to eq("Theirs")
      # The request class still ran first (ordering is unchanged), but with no
      # record: the org-scoped lookup found nothing to hand it.
      expect(RQ_SEEN.last[:klass]).to eq("RqTaskUpdateRequest")
      expect(RQ_SEEN.last[:record]).to be_nil
    end

    it "refuses a nested update of another org's DIRECTLY owned row" do
      Rhino.configure { |c| c.model :rq_projects, "RqProject", update_request: "RqProjectUpdateRequest2" }
      join(member, org_a)

      expect {
        call_action(
          :nested,
          params: {
            model_slug: "rq_projects", route_group: "tenant", organization: org_a.id.to_s,
            operations: [
              { model: "rq_projects", action: "update", id: project_b.id, data: { title: "Hacked" } }
            ]
          },
          headers: auth_headers(member)
        )
      }.to raise_error(ActiveRecord::RecordNotFound)

      expect(project_b.reload.title).to eq("Project B")
    end

    it "still allows a nested update of the acting org's own row" do
      Rhino.configure { |c| c.model :rq_projects, "RqProject", update_request: "RqProjectUpdateRequest2" }
      join(member, org_a)

      response = call_action(
        :nested,
        params: {
          model_slug: "rq_projects", route_group: "tenant", organization: org_a.id.to_s,
          operations: [
            { model: "rq_projects", action: "update", id: project_a.id, data: { title: "Renamed" } }
          ]
        },
        headers: auth_headers(member)
      )

      expect(response.status).to eq(200)
      expect(project_a.reload.title).to eq("Renamed")
    end

    it "leaves an operation on a model with no request class entirely on the legacy path" do
      response = call_action(
        :nested,
        params: {
          model_slug: "rq_notes",
          operations: [
            { model: "rq_notes", action: "create", data: { title: "way too long a title" } }
          ]
        },
        headers: auth_headers(member)
      )

      expect(response.status).to eq(422)
      expect(response.body).to eq(
        "message" => "Validation failed.",
        "errors" => { "operations.0.data.title" => ["is too long (maximum is 10 characters)"] }
      )
    end

    it "mixes a request-class model and a legacy model in one nested payload" do
      join(member, org_a)

      response = call_action(
        :nested,
        params: {
          model_slug: "rq_tasks", route_group: "tenant", organization: org_a.id.to_s,
          operations: [
            { model: "rq_tasks", action: "create",
              data: { title: "Via request class", rq_project_id: project_a.id } },
            { model: "rq_notes", action: "create", data: { title: "Legacy", content: "Kept" } }
          ]
        },
        headers: auth_headers(member)
      )

      expect(response.status).to eq(200)
      expect(RqTask.order(:id).last.source).to eq("api")   # request-class path
      expect(RqNote.order(:id).last.content).to eq("Kept") # legacy path keeps undeclared fields
    end
  end

  # ==================================================================
  # §9 row 19 + discovery details — request_class_for
  # ==================================================================

  describe "#request_class_for" do
    let(:controller) { Rhino::ResourcesController.new }

    def resolve(action, klass, slug)
      controller.send(:request_class_for, action, klass, slug)
    end

    it "finds the conventional store and update classes" do
      expect(resolve("store", RqTask, "rq_tasks")).to eq(RqTaskStoreRequest)
      expect(resolve("update", RqTask, "rq_tasks")).to eq(RqTaskUpdateRequest)
    end

    it "returns nil when no conventional class exists" do
      expect(resolve("store", RqNote, "rq_notes")).to be_nil
      expect(resolve("update", RqNote, "rq_notes")).to be_nil
    end

    it "resolves per call and never memoizes the constant (Zeitwerk reloading, H-8)" do
      first = resolve("store", RqTask, "rq_tasks")

      original = RqTaskStoreRequest
      Object.send(:remove_const, :RqTaskStoreRequest)
      Object.const_set(:RqTaskStoreRequest, Class.new(Rhino::ResourceRequest))

      begin
        second = resolve("store", RqTask, "rq_tasks")
        expect(second).not_to equal(first)
        expect(second).to equal(RqTaskStoreRequest)
      ensure
        Object.send(:remove_const, :RqTaskStoreRequest)
        Object.const_set(:RqTaskStoreRequest, original)
      end
    end

    it "prefers an explicit registration over the convention" do
      Rhino.configure { |c| c.model :rq_tasks, "RqTask", store_request: "RqEmptyStoreRequest" }

      expect(resolve("store", RqTask, "rq_tasks")).to eq(RqEmptyStoreRequest)
      # update is resolved independently and still falls back to the convention
      expect(resolve("update", RqTask, "rq_tasks")).to eq(RqTaskUpdateRequest)
    end

    it "accepts a Class (not just a String) in an explicit registration" do
      Rhino.configure { |c| c.model :rq_tasks, "RqTask", store_request: RqEmptyStoreRequest }

      expect(resolve("store", RqTask, "rq_tasks")).to eq(RqEmptyStoreRequest)
    end

    it "treats a blank explicit registration as no registration" do
      Rhino.configure { |c| c.model :rq_tasks, "RqTask", store_request: "   " }

      expect(resolve("store", RqTask, "rq_tasks")).to eq(RqTaskStoreRequest)
    end
  end
end
