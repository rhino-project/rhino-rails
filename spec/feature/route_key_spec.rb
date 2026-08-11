# frozen_string_literal: true

require "spec_helper"
require "rhino/controllers/resources_controller"
require "ostruct"

# Configurable route key: member endpoints (show/update/destroy/restore/
# force_delete) match the :id URL segment against the model's configured
# route key column instead of the primary key.
RSpec.describe "Configurable route key" do
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

    env = Rack::MockRequest.env_for("/api/#{params[:model_slug] || 'jobs'}", method: method)
    env["action_dispatch.request.request_parameters"] = params.stringify_keys
    env["action_dispatch.request.path_parameters"] = {
      controller: "rhino/resources",
      action: action.to_s,
      model_slug: "jobs"
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

  def create_job(attrs = {})
    Job.create!({ title: "Test Job", status: "open", hash_id: "h-#{SecureRandom.hex(6)}" }.merge(attrs))
  end

  def create_task(attrs = {})
    Task.create!({ title: "Test Task", hash_id: "t-#{SecureRandom.hex(6)}" }.merge(attrs))
  end

  before do
    Rhino.configure do |c|
      c.model :jobs, "Job"
      c.model :tasks, "Task"
    end
  end

  # ==================================================================
  # Member endpoints via the route key
  # ==================================================================

  describe "member endpoints via hash_id" do
    it "shows a record by hash_id" do
      user = create_user
      job = create_job(title: "Show Me")

      response = call_action(:show,
        params: { model_slug: "jobs", id: job.hash_id },
        headers: auth_headers(user))

      expect(response.status).to eq(200)
      expect(response.body["title"]).to eq("Show Me")
      expect(response.body["id"]).to eq(job.id)
      expect(response.body["hash_id"]).to eq(job.hash_id)
    end

    it "shows a record by hash_id when the include re-query path runs" do
      user = create_user
      job = create_job(title: "With Include")

      # ?include= triggers show's re-query, which must re-find the already
      # resolved record by primary key.
      response = call_action(:show,
        params: { model_slug: "jobs", id: job.hash_id, include: "organization" },
        headers: auth_headers(user))

      expect(response.status).to eq(200)
      expect(response.body["title"]).to eq("With Include")
    end

    it "updates a record by hash_id" do
      user = create_user
      job = create_job(title: "Old Title")

      response = call_action(:update,
        params: { model_slug: "jobs", id: job.hash_id, title: "New Title" },
        headers: auth_headers(user))

      expect(response.status).to eq(200)
      expect(response.body["title"]).to eq("New Title")
      expect(job.reload.title).to eq("New Title")
    end

    it "destroys (soft-deletes) a record by hash_id" do
      user = create_user
      job = create_job

      response = call_action(:destroy,
        params: { model_slug: "jobs", id: job.hash_id },
        headers: auth_headers(user))

      expect(response.status).to eq(204)
      expect(job.reload.discarded?).to be true
    end

    it "restores a discarded record by hash_id" do
      user = create_user
      job = create_job
      job.discard!

      response = call_action(:restore,
        params: { model_slug: "jobs", id: job.hash_id },
        headers: auth_headers(user))

      expect(response.status).to eq(200)
      expect(job.reload.discarded?).to be false
    end

    it "force-deletes a discarded record by hash_id" do
      user = create_user
      job = create_job
      job.discard!
      job_id = job.id

      response = call_action(:force_delete,
        params: { model_slug: "jobs", id: job.hash_id },
        headers: auth_headers(user))

      expect(response.status).to eq(204)
      expect(Job.unscoped.exists?(job_id)).to be false
    end
  end

  # ==================================================================
  # Primary key must NOT match once a route key is set
  # ==================================================================

  describe "primary key lookups when a route key is configured" do
    it "raises RecordNotFound for show by numeric primary key" do
      user = create_user
      job = create_job

      expect {
        call_action(:show,
          params: { model_slug: "jobs", id: job.id },
          headers: auth_headers(user))
      }.to raise_error(ActiveRecord::RecordNotFound)
    end

    it "raises RecordNotFound for update by numeric primary key" do
      user = create_user
      job = create_job

      expect {
        call_action(:update,
          params: { model_slug: "jobs", id: job.id, title: "Nope" },
          headers: auth_headers(user))
      }.to raise_error(ActiveRecord::RecordNotFound)
    end

    it "raises RecordNotFound for restore by numeric primary key" do
      user = create_user
      job = create_job
      job.discard!

      expect {
        call_action(:restore,
          params: { model_slug: "jobs", id: job.id },
          headers: auth_headers(user))
      }.to raise_error(ActiveRecord::RecordNotFound)
    end
  end

  # ==================================================================
  # Unknown hash
  # ==================================================================

  describe "unknown route key values" do
    it "raises RecordNotFound for an unknown hash" do
      user = create_user
      create_job

      expect {
        call_action(:show,
          params: { model_slug: "jobs", id: "no-such-hash" },
          headers: auth_headers(user))
      }.to raise_error(ActiveRecord::RecordNotFound)
    end
  end

  # ==================================================================
  # Cross-tenant isolation
  # ==================================================================

  describe "cross-tenant isolation" do
    it "raises RecordNotFound for a correct hash belonging to another organization" do
      user = create_user
      org_a = create_organization
      org_b = create_organization
      job = create_job(organization_id: org_a.id)

      expect {
        call_action(:show,
          params: { model_slug: "jobs", id: job.hash_id },
          headers: auth_headers(user),
          env_overrides: { "rhino.organization" => org_b })
      }.to raise_error(ActiveRecord::RecordNotFound)
    end

    it "finds the record when the organization matches" do
      user = create_user
      org = create_organization
      job = create_job(organization_id: org.id)

      response = call_action(:show,
        params: { model_slug: "jobs", id: job.hash_id },
        headers: auth_headers(user),
        env_overrides: { "rhino.organization" => org })

      expect(response.status).to eq(200)
      expect(response.body["hash_id"]).to eq(job.hash_id)
    end
  end

  # ==================================================================
  # Sparse fieldsets keep the route key
  # ==================================================================

  describe "sparse fieldsets" do
    it "returns hash_id even when ?fields does not request it" do
      user = create_user
      job = create_job(title: "Sparse")

      response = call_action(:index,
        params: { model_slug: "jobs", "fields" => { "jobs" => "title" } },
        headers: auth_headers(user))

      expect(response.status).to eq(200)
      record = response.body["data"].find { |j| j["title"] == "Sparse" }
      expect(record).not_to be_nil
      expect(record["hash_id"]).to eq(job.hash_id)
      expect(record["id"]).to eq(job.id)
      expect(record).not_to have_key("status")
    end
  end

  # ==================================================================
  # Precedence chain
  # ==================================================================

  describe "resolution precedence" do
    it "model-level rhino_route_key beats the global config" do
      Rhino.config.route_key = "title"
      user = create_user
      job = create_job(title: "unique-title-#{SecureRandom.hex(4)}")

      response = call_action(:show,
        params: { model_slug: "jobs", id: job.hash_id },
        headers: auth_headers(user))

      expect(response.status).to eq(200)
      expect(response.body["id"]).to eq(job.id)
    end

    it "global config applies when the model is silent" do
      Rhino.config.route_key = "hash_id"
      user = create_user
      task = create_task(title: "Global Keyed")

      response = call_action(:show,
        params: { model_slug: "tasks", id: task.hash_id },
        headers: auth_headers(user))

      expect(response.status).to eq(200)
      expect(response.body["title"]).to eq("Global Keyed")
    end

    it "global config makes primary key lookups miss on silent models" do
      Rhino.config.route_key = "hash_id"
      user = create_user
      task = create_task

      expect {
        call_action(:show,
          params: { model_slug: "tasks", id: task.id },
          headers: auth_headers(user))
      }.to raise_error(ActiveRecord::RecordNotFound)
    end

    it "keeps exactly the current primary-key behavior when nothing is configured" do
      user = create_user
      task = create_task(title: "Default Path")

      response = call_action(:show,
        params: { model_slug: "tasks", id: task.id },
        headers: auth_headers(user))

      expect(response.status).to eq(200)
      expect(response.body["title"]).to eq("Default Path")
    end
  end

  # ==================================================================
  # Misconfiguration
  # ==================================================================

  describe "misconfigured route key" do
    it "raises a clear ArgumentError when the column does not exist" do
      Rhino.config.route_key = "nonexistent_column"
      user = create_user
      task = create_task

      expect {
        call_action(:show,
          params: { model_slug: "tasks", id: task.id },
          headers: auth_headers(user))
      }.to raise_error(ArgumentError, /nonexistent_column/)
    end
  end

  # ==================================================================
  # Nested operations stay primary-key based
  # ==================================================================

  describe "nested operations" do
    it "updates a route-keyed model by primary key in nested operations" do
      user = create_user
      job = create_job(title: "Original")

      response = call_action(:nested,
        params: {
          operations: [
            { model: "jobs", action: "update", id: job.id, data: { title: "Updated" } }
          ]
        },
        headers: auth_headers(user))

      expect(response.status).to eq(200)
      expect(response.body["results"][0]["action"]).to eq("update")
      expect(job.reload.title).to eq("Updated")
    end

    it "does not accept the hash_id in nested operation ids" do
      user = create_user
      job = create_job

      expect {
        call_action(:nested,
          params: {
            operations: [
              { model: "jobs", action: "update", id: job.hash_id, data: { title: "Nope" } }
            ]
          },
          headers: auth_headers(user))
      }.to raise_error(ActiveRecord::RecordNotFound)
    end
  end
end
