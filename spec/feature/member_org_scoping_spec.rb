# frozen_string_literal: true

require "spec_helper"
require "rhino/controllers/resources_controller"
require "ostruct"

# Cross-tenant isolation on MEMBER endpoints (show / update / destroy /
# restore / force-delete).
#
# Regression suite for the leak where find_record only scoped models with a
# literal organization_id column, so models reaching Organization through an
# indirect belongs_to chain (task -> project -> org, comment -> task ->
# project -> org) could be fetched cross-tenant by id or route key. restore
# and force_delete performed NO org scoping at all, leaking even for
# direct-tenant models. Member lookups now flow through
# Rhino::ScopesToOrganization.scope_to_organization (lenient), matching index.

# --------------------------------------------------------------------------
# Test schema (spec-local, mirrors the TaskFlow example shape)
# --------------------------------------------------------------------------

ActiveRecord::Schema.define do
  create_table :scoping_projects, force: true do |t|
    t.references :organization, null: false, foreign_key: true
    t.string :title
    t.datetime :discarded_at
    t.timestamps
  end

  # Indirect tenant chain (1 hop): task -> project -> organization
  create_table :scoping_tasks, force: true do |t|
    t.references :scoping_project, null: false, foreign_key: true
    t.string :title
    t.datetime :discarded_at
    t.timestamps
  end

  # Indirect tenant chain + configured route key
  create_table :scoping_items, force: true do |t|
    t.references :scoping_project, null: false, foreign_key: true
    t.string :hash_id
    t.string :title
    t.datetime :discarded_at
    t.timestamps
  end
  add_index :scoping_items, :hash_id, unique: true

  # Nested indirect chain (2 hops): comment -> task -> project -> organization
  create_table :scoping_comments, force: true do |t|
    t.references :scoping_task, null: false, foreign_key: true
    t.text :body
    t.timestamps
  end

  # Direct tenant column + custom for_organization scope
  create_table :scoping_org_docs, force: true do |t|
    t.references :organization, null: false, foreign_key: true
    t.string :title
    t.datetime :discarded_at
    t.timestamps
  end

  # No organization mechanism at all
  create_table :scoping_globals, force: true do |t|
    t.string :title
    t.datetime :discarded_at
    t.timestamps
  end
end

# --------------------------------------------------------------------------
# Test models
# --------------------------------------------------------------------------

class ScopingProject < ActiveRecord::Base
  include Rhino::HasRhino
  include Rhino::HasValidation
  include Rhino::HidableColumns
  include Discard::Model

  belongs_to :organization
  has_many :scoping_tasks
end

class ScopingTask < ActiveRecord::Base
  include Rhino::HasRhino
  include Rhino::HasValidation
  include Rhino::HidableColumns
  include Discard::Model

  belongs_to :scoping_project
  has_many :scoping_comments
end

class ScopingItem < ActiveRecord::Base
  include Rhino::HasRhino
  include Rhino::HasValidation
  include Rhino::HidableColumns
  include Discard::Model

  belongs_to :scoping_project

  rhino_route_key :hash_id
end

class ScopingComment < ActiveRecord::Base
  include Rhino::HasRhino
  include Rhino::HasValidation
  include Rhino::HidableColumns

  belongs_to :scoping_task
end

class ScopingOrgDoc < ActiveRecord::Base
  include Rhino::HasRhino
  include Rhino::HasValidation
  include Rhino::HidableColumns
  include Discard::Model

  belongs_to :organization, optional: true

  # Exercises the for_organization branch of scope_to_organization (takes
  # priority over the organization_id column branch).
  def self.for_organization(organization)
    where(organization_id: organization.id)
  end
end

class ScopingGlobal < ActiveRecord::Base
  include Rhino::HasRhino
  include Rhino::HasValidation
  include Rhino::HidableColumns
  include Discard::Model
end

RSpec.describe "Member endpoint organization scoping" do
  # ------------------------------------------------------------------
  # Helpers (mirrors resources_controller_spec)
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

  let(:user) { create_user }
  let(:org_a) { create_organization(name: "Org A") }
  let(:org_b) { create_organization(name: "Org B") }
  let(:project_a) { ScopingProject.create!(organization_id: org_a.id, title: "Project A") }
  let(:project_b) { ScopingProject.create!(organization_id: org_b.id, title: "Project B") }
  let(:task_a) { ScopingTask.create!(scoping_project_id: project_a.id, title: "Task A") }
  let(:task_b) { ScopingTask.create!(scoping_project_id: project_b.id, title: "Task B") }

  before do
    Rhino.configure do |c|
      c.model :scoping_projects, "ScopingProject"
      c.model :scoping_tasks, "ScopingTask"
      c.model :scoping_items, "ScopingItem"
      c.model :scoping_comments, "ScopingComment"
      c.model :scoping_org_docs, "ScopingOrgDoc"
      c.model :scoping_globals, "ScopingGlobal"
      c.model :organizations, "Organization"
    end
  end

  # ==================================================================
  # Indirect chain (task -> project -> org), PK routing
  # ==================================================================

  describe "indirect-tenant model by primary key" do
    it "shows a same-org record" do
      response = call_action(:show,
        params: { model_slug: "scoping_tasks", id: task_a.id },
        headers: auth_headers(user),
        env_overrides: { "rhino.organization" => org_a })

      expect(response.status).to eq(200)
      expect(response.body["title"]).to eq("Task A")
    end

    it "raises RecordNotFound showing a cross-org record" do
      expect {
        call_action(:show,
          params: { model_slug: "scoping_tasks", id: task_b.id },
          headers: auth_headers(user),
          env_overrides: { "rhino.organization" => org_a })
      }.to raise_error(ActiveRecord::RecordNotFound)
    end

    it "updates a same-org record" do
      response = call_action(:update,
        params: { model_slug: "scoping_tasks", id: task_a.id, title: "Renamed" },
        headers: auth_headers(user),
        env_overrides: { "rhino.organization" => org_a })

      expect(response.status).to eq(200)
      expect(task_a.reload.title).to eq("Renamed")
    end

    it "raises RecordNotFound updating a cross-org record" do
      expect {
        call_action(:update,
          params: { model_slug: "scoping_tasks", id: task_b.id, title: "Hacked" },
          headers: auth_headers(user),
          env_overrides: { "rhino.organization" => org_a })
      }.to raise_error(ActiveRecord::RecordNotFound)
      expect(task_b.reload.title).to eq("Task B")
    end

    it "destroys a same-org record" do
      response = call_action(:destroy,
        params: { model_slug: "scoping_tasks", id: task_a.id },
        headers: auth_headers(user),
        env_overrides: { "rhino.organization" => org_a })

      expect(response.status).to eq(204)
      expect(task_a.reload.discarded?).to be true
    end

    it "raises RecordNotFound destroying a cross-org record" do
      expect {
        call_action(:destroy,
          params: { model_slug: "scoping_tasks", id: task_b.id },
          headers: auth_headers(user),
          env_overrides: { "rhino.organization" => org_a })
      }.to raise_error(ActiveRecord::RecordNotFound)
      expect(task_b.reload.discarded?).to be false
    end
  end

  # ==================================================================
  # Indirect chain, configured route key
  # ==================================================================

  describe "indirect-tenant model by configured route key" do
    let(:item_a) do
      ScopingItem.create!(scoping_project_id: project_a.id, title: "Item A",
                          hash_id: "h-#{SecureRandom.hex(6)}")
    end
    let(:item_b) do
      ScopingItem.create!(scoping_project_id: project_b.id, title: "Item B",
                          hash_id: "h-#{SecureRandom.hex(6)}")
    end

    it "shows a same-org record by hash_id" do
      response = call_action(:show,
        params: { model_slug: "scoping_items", id: item_a.hash_id },
        headers: auth_headers(user),
        env_overrides: { "rhino.organization" => org_a })

      expect(response.status).to eq(200)
      expect(response.body["title"]).to eq("Item A")
    end

    it "raises RecordNotFound showing a cross-org record by hash_id" do
      expect {
        call_action(:show,
          params: { model_slug: "scoping_items", id: item_b.hash_id },
          headers: auth_headers(user),
          env_overrides: { "rhino.organization" => org_a })
      }.to raise_error(ActiveRecord::RecordNotFound)
    end

    it "raises RecordNotFound updating a cross-org record by hash_id" do
      expect {
        call_action(:update,
          params: { model_slug: "scoping_items", id: item_b.hash_id, title: "Hacked" },
          headers: auth_headers(user),
          env_overrides: { "rhino.organization" => org_a })
      }.to raise_error(ActiveRecord::RecordNotFound)
      expect(item_b.reload.title).to eq("Item B")
    end

    it "raises RecordNotFound destroying a cross-org record by hash_id" do
      expect {
        call_action(:destroy,
          params: { model_slug: "scoping_items", id: item_b.hash_id },
          headers: auth_headers(user),
          env_overrides: { "rhino.organization" => org_a })
      }.to raise_error(ActiveRecord::RecordNotFound)
      expect(item_b.reload.discarded?).to be false
    end
  end

  # ==================================================================
  # Nested indirect chain (comment -> task -> project -> org)
  # ==================================================================

  describe "nested indirect-tenant model" do
    let(:comment_a) { ScopingComment.create!(scoping_task_id: task_a.id, body: "Comment A") }
    let(:comment_b) { ScopingComment.create!(scoping_task_id: task_b.id, body: "Comment B") }

    it "shows a same-org record through the two-hop chain" do
      response = call_action(:show,
        params: { model_slug: "scoping_comments", id: comment_a.id },
        headers: auth_headers(user),
        env_overrides: { "rhino.organization" => org_a })

      expect(response.status).to eq(200)
      expect(response.body["body"]).to eq("Comment A")
    end

    it "raises RecordNotFound showing a cross-org record through the two-hop chain" do
      expect {
        call_action(:show,
          params: { model_slug: "scoping_comments", id: comment_b.id },
          headers: auth_headers(user),
          env_overrides: { "rhino.organization" => org_a })
      }.to raise_error(ActiveRecord::RecordNotFound)
    end

    it "raises RecordNotFound updating a cross-org record through the two-hop chain" do
      expect {
        call_action(:update,
          params: { model_slug: "scoping_comments", id: comment_b.id, body: "Hacked" },
          headers: auth_headers(user),
          env_overrides: { "rhino.organization" => org_a })
      }.to raise_error(ActiveRecord::RecordNotFound)
      expect(comment_b.reload.body).to eq("Comment B")
    end
  end

  # ==================================================================
  # restore / force_delete
  # ==================================================================

  describe "restore" do
    it "restores a same-org discarded record (direct organization_id)" do
      doc = ScopingOrgDoc.create!(organization_id: org_a.id, title: "Doc A")
      doc.discard!

      response = call_action(:restore,
        params: { model_slug: "scoping_org_docs", id: doc.id },
        headers: auth_headers(user),
        env_overrides: { "rhino.organization" => org_a })

      expect(response.status).to eq(200)
      expect(doc.reload.discarded?).to be false
    end

    it "raises RecordNotFound restoring a cross-org record (direct organization_id)" do
      doc_b = ScopingOrgDoc.create!(organization_id: org_b.id, title: "Doc B")
      doc_b.discard!

      expect {
        call_action(:restore,
          params: { model_slug: "scoping_org_docs", id: doc_b.id },
          headers: auth_headers(user),
          env_overrides: { "rhino.organization" => org_a })
      }.to raise_error(ActiveRecord::RecordNotFound)
      expect(doc_b.reload.discarded?).to be true
    end

    it "restores a same-org discarded record (indirect chain)" do
      task_a.discard!

      response = call_action(:restore,
        params: { model_slug: "scoping_tasks", id: task_a.id },
        headers: auth_headers(user),
        env_overrides: { "rhino.organization" => org_a })

      expect(response.status).to eq(200)
      expect(task_a.reload.discarded?).to be false
    end

    it "raises RecordNotFound restoring a cross-org record (indirect chain)" do
      task_b.discard!

      expect {
        call_action(:restore,
          params: { model_slug: "scoping_tasks", id: task_b.id },
          headers: auth_headers(user),
          env_overrides: { "rhino.organization" => org_a })
      }.to raise_error(ActiveRecord::RecordNotFound)
      expect(task_b.reload.discarded?).to be true
    end
  end

  describe "force_delete" do
    it "force-deletes a same-org discarded record (direct organization_id)" do
      doc = ScopingOrgDoc.create!(organization_id: org_a.id, title: "Doc A")
      doc.discard!

      response = call_action(:force_delete,
        params: { model_slug: "scoping_org_docs", id: doc.id },
        headers: auth_headers(user),
        env_overrides: { "rhino.organization" => org_a })

      expect(response.status).to eq(204)
      expect(ScopingOrgDoc.exists?(doc.id)).to be false
    end

    it "raises RecordNotFound force-deleting a cross-org record (direct organization_id)" do
      doc_b = ScopingOrgDoc.create!(organization_id: org_b.id, title: "Doc B")
      doc_b.discard!

      expect {
        call_action(:force_delete,
          params: { model_slug: "scoping_org_docs", id: doc_b.id },
          headers: auth_headers(user),
          env_overrides: { "rhino.organization" => org_a })
      }.to raise_error(ActiveRecord::RecordNotFound)
      expect(ScopingOrgDoc.exists?(doc_b.id)).to be true
    end

    it "raises RecordNotFound force-deleting a cross-org record (indirect chain)" do
      task_b.discard!

      expect {
        call_action(:force_delete,
          params: { model_slug: "scoping_tasks", id: task_b.id },
          headers: auth_headers(user),
          env_overrides: { "rhino.organization" => org_a })
      }.to raise_error(ActiveRecord::RecordNotFound)
      expect(ScopingTask.exists?(task_b.id)).to be true
    end
  end

  # ==================================================================
  # for_organization branch keeps the .discarded scope (CAUTION 1)
  # ==================================================================

  describe "for_organization model on a discarded lookup" do
    it "restore honors both the discarded scope and the org filter" do
      kept = ScopingOrgDoc.create!(organization_id: org_a.id, title: "Kept A")
      discarded = ScopingOrgDoc.create!(organization_id: org_a.id, title: "Discarded A")
      discarded.discard!

      # A kept record must NOT be findable through the discarded lookup —
      # if the for_organization branch replaced the relation instead of
      # merging into it, the .discarded filter would be silently dropped.
      expect {
        call_action(:restore,
          params: { model_slug: "scoping_org_docs", id: kept.id },
          headers: auth_headers(user),
          env_overrides: { "rhino.organization" => org_a })
      }.to raise_error(ActiveRecord::RecordNotFound)

      response = call_action(:restore,
        params: { model_slug: "scoping_org_docs", id: discarded.id },
        headers: auth_headers(user),
        env_overrides: { "rhino.organization" => org_a })
      expect(response.status).to eq(200)
      expect(discarded.reload.discarded?).to be false
    end

    it "scope_to_organization merges instead of replacing the incoming relation" do
      discarded = ScopingOrgDoc.create!(organization_id: org_a.id, title: "Discarded A")
      discarded.discard!
      kept = ScopingOrgDoc.create!(organization_id: org_a.id, title: "Kept A")
      other_org = ScopingOrgDoc.create!(organization_id: org_b.id, title: "Discarded B")
      other_org.discard!

      relation = Rhino::ScopesToOrganization.scope_to_organization(
        ScopingOrgDoc.discarded, ScopingOrgDoc, org_a
      )

      expect(relation.pluck(:id)).to contain_exactly(discarded.id)
      expect(relation.pluck(:id)).not_to include(kept.id, other_org.id)
    end
  end

  # ==================================================================
  # No org mechanism / no org context — unchanged behavior (CAUTION 2)
  # ==================================================================

  describe "model with no organization mechanism" do
    it "remains reachable without an org context" do
      record = ScopingGlobal.create!(title: "Global")

      response = call_action(:show,
        params: { model_slug: "scoping_globals", id: record.id },
        headers: auth_headers(user))

      expect(response.status).to eq(200)
      expect(response.body["title"]).to eq("Global")
    end

    it "remains reachable with an org context (lenient, matches index)" do
      record = ScopingGlobal.create!(title: "Global")

      response = call_action(:show,
        params: { model_slug: "scoping_globals", id: record.id },
        headers: auth_headers(user),
        env_overrides: { "rhino.organization" => org_a })

      expect(response.status).to eq(200)
    end

    it "restore works without an org context" do
      record = ScopingGlobal.create!(title: "Global")
      record.discard!

      response = call_action(:restore,
        params: { model_slug: "scoping_globals", id: record.id },
        headers: auth_headers(user))

      expect(response.status).to eq(200)
      expect(record.reload.discarded?).to be false
    end
  end

  describe "tenant model without an org context (single-tenant / non-tenant route)" do
    it "keeps today's unscoped member lookup" do
      response = call_action(:show,
        params: { model_slug: "scoping_tasks", id: task_b.id },
        headers: auth_headers(user))

      expect(response.status).to eq(200)
      expect(response.body["title"]).to eq("Task B")
    end
  end

  # ==================================================================
  # Organization-is-self member endpoints
  # ==================================================================

  describe "organization-is-self member endpoints" do
    it "shows the current organization itself" do
      response = call_action(:show,
        params: { model_slug: "organizations", id: org_a.id },
        headers: auth_headers(user),
        env_overrides: { "rhino.organization" => org_a })

      expect(response.status).to eq(200)
      expect(response.body["name"]).to eq("Org A")
    end

    it "raises RecordNotFound showing another organization" do
      expect {
        call_action(:show,
          params: { model_slug: "organizations", id: org_b.id },
          headers: auth_headers(user),
          env_overrides: { "rhino.organization" => org_a })
      }.to raise_error(ActiveRecord::RecordNotFound)
    end
  end
end
