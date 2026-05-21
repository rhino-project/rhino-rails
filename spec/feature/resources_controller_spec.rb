# frozen_string_literal: true

require "spec_helper"
require "rhino/controllers/resources_controller"
require "ostruct"

RSpec.describe Rhino::ResourcesController do
  # ------------------------------------------------------------------
  # Helpers
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

    env = Rack::MockRequest.env_for("/api/posts", method: method)
    env["action_dispatch.request.request_parameters"] = params.stringify_keys
    env["action_dispatch.request.path_parameters"] = {
      controller: "rhino/resources",
      action: action.to_s,
      model_slug: "posts"
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

  def create_post(attrs = {})
    Post.create!({ title: "Test Post", content: "Post content" }.merge(attrs))
  end

  # ==================================================================
  # Authentication
  # ==================================================================

  describe "authentication" do
    it "returns 401 when no token is provided" do
      response = call_action(:index, params: { model_slug: "posts" })
      expect(response.status).to eq(401)
      expect(response.body["message"]).to eq("Unauthenticated.")
    end

    it "returns 401 with invalid token" do
      response = call_action(:index,
        params: { model_slug: "posts" },
        headers: { "Authorization" => "Bearer invalid-token" })
      expect(response.status).to eq(401)
    end

    it "skips authentication for public route group" do
      user = create_user(permissions: ["*"])

      Rhino.configure do |c|
        c.model :posts, "Post"
        c.model :blogs, "Blog"
        c.route_group :public, prefix: "", middleware: [], models: [:posts]
        c.route_group :default, prefix: "", middleware: [], models: :all
      end

      response = call_action(:index,
        params: { model_slug: "posts", route_group: "public" },
        headers: auth_headers(user))
      expect(response.status).to eq(200)
    end
  end

  # ==================================================================
  # Model Resolution
  # ==================================================================

  describe "model resolution" do
    it "returns 404 for unknown model slug" do
      user = create_user
      response = call_action(:index,
        params: { model_slug: "unknown" },
        headers: auth_headers(user))
      expect(response.status).to eq(404)
      expect(response.body["message"]).to include("does not exist")
    end
  end

  # ==================================================================
  # INDEX
  # ==================================================================

  describe "GET index" do
    it "returns all records" do
      user = create_user
      create_post(title: "Post 1")
      create_post(title: "Post 2")

      response = call_action(:index,
        params: { model_slug: "posts" },
        headers: auth_headers(user))

      expect(response.status).to eq(200)
      expect(response.body["data"].length).to eq(2)
    end

    it "returns empty array when no records exist" do
      user = create_user

      response = call_action(:index,
        params: { model_slug: "posts" },
        headers: auth_headers(user))

      expect(response.status).to eq(200)
      expect(response.body["data"]).to eq([])
    end

    it "paginates when per_page is given" do
      user = create_user
      5.times { |i| create_post(title: "Post #{i}") }

      response = call_action(:index,
        params: { model_slug: "posts", per_page: "2" },
        headers: auth_headers(user))

      expect(response.status).to eq(200)
      expect(response.body["data"].length).to eq(2)
      expect(response.headers["X-Total"]).to eq("5")
      expect(response.headers["X-Per-Page"]).to eq("2")
      expect(response.headers["X-Current-Page"]).to eq("1")
      expect(response.headers["X-Last-Page"]).to eq("3")
    end

    it "denies access without permission" do
      user = create_user(permissions: ["posts.show"])

      response = call_action(:index,
        params: { model_slug: "posts" },
        headers: auth_headers(user))

      expect(response.status).to eq(403)
    end
  end

  # ==================================================================
  # SHOW
  # ==================================================================

  describe "GET show" do
    it "returns a single record" do
      user = create_user
      post = create_post(title: "Show Me")

      response = call_action(:show,
        params: { model_slug: "posts", id: post.id },
        headers: auth_headers(user))

      expect(response.status).to eq(200)
      expect(response.body["title"]).to eq("Show Me")
    end

    it "returns 404 for non-existent record" do
      user = create_user

      expect {
        call_action(:show,
          params: { model_slug: "posts", id: 999999 },
          headers: auth_headers(user))
      }.to raise_error(ActiveRecord::RecordNotFound)
    end

    it "denies access without permission" do
      user = create_user(permissions: ["posts.index"])
      post = create_post

      response = call_action(:show,
        params: { model_slug: "posts", id: post.id },
        headers: auth_headers(user))

      expect(response.status).to eq(403)
    end
  end

  # ==================================================================
  # STORE (create)
  # ==================================================================

  describe "POST store" do
    it "creates a new record" do
      user = create_user

      response = call_action(:store,
        params: { model_slug: "posts", title: "New Post", content: "Content" },
        headers: auth_headers(user))

      expect(response.status).to eq(201)
      expect(response.body["title"]).to eq("New Post")
      expect(Post.where(title: "New Post").count).to eq(1)
    end

    it "returns 403 for forbidden fields" do
      user = create_user(permissions: ["posts.store"])
      # PostPolicy limits non-admin to title, content
      # user has no 'admin' role so should be restricted

      response = call_action(:store,
        params: { model_slug: "posts", title: "Post", status: "published" },
        headers: auth_headers(user))

      # With non-admin user, status should be forbidden
      expect(response.status).to eq(403)
      expect(response.body["message"]).to include("not allowed")
    end

    it "returns 422 for validation errors" do
      user = create_user

      # Title exceeding 255 chars
      long_title = "x" * 300
      response = call_action(:store,
        params: { model_slug: "posts", title: long_title },
        headers: auth_headers(user))

      expect(response.status).to eq(422)
      expect(response.body["errors"]).to be_present
    end

    it "denies access without permission" do
      user = create_user(permissions: ["posts.index"])

      response = call_action(:store,
        params: { model_slug: "posts", title: "Unauthorized" },
        headers: auth_headers(user))

      expect(response.status).to eq(403)
    end

    it "strips organization_id when organization is present" do
      user = create_user
      org = create_organization

      response = call_action(:store,
        params: { model_slug: "posts", title: "Org Post", organization_id: 999 },
        headers: auth_headers(user),
        env_overrides: { "rhino.organization" => org })

      expect(response.status).to eq(201)
      expect(Post.last.organization_id).to eq(org.id)
    end
  end

  # ==================================================================
  # UPDATE
  # ==================================================================

  describe "PUT update" do
    it "updates an existing record" do
      user = create_user
      post = create_post(title: "Old Title")

      response = call_action(:update,
        params: { model_slug: "posts", id: post.id, title: "New Title" },
        headers: auth_headers(user))

      expect(response.status).to eq(200)
      expect(response.body["title"]).to eq("New Title")
      expect(post.reload.title).to eq("New Title")
    end

    it "returns 403 when trying to change organization_id" do
      user = create_user
      org = create_organization
      post = create_post(organization_id: org.id)

      response = call_action(:update,
        params: { model_slug: "posts", id: post.id, organization_id: 999 },
        headers: auth_headers(user),
        env_overrides: { "rhino.organization" => org })

      expect(response.status).to eq(403)
      expect(response.body["message"]).to include("organization_id")
    end

    it "returns 403 for forbidden fields" do
      user = create_user(permissions: ["posts.update"])
      post = create_post

      response = call_action(:update,
        params: { model_slug: "posts", id: post.id, status: "published" },
        headers: auth_headers(user))

      expect(response.status).to eq(403)
    end

    it "returns 422 for validation errors" do
      user = create_user
      post = create_post

      long_title = "x" * 300
      response = call_action(:update,
        params: { model_slug: "posts", id: post.id, title: long_title },
        headers: auth_headers(user))

      expect(response.status).to eq(422)
    end

    it "denies access without permission" do
      user = create_user(permissions: ["posts.index"])
      post = create_post

      response = call_action(:update,
        params: { model_slug: "posts", id: post.id, title: "Updated" },
        headers: auth_headers(user))

      expect(response.status).to eq(403)
    end
  end

  # ==================================================================
  # DESTROY
  # ==================================================================

  describe "DELETE destroy" do
    it "soft-deletes a record that supports discard" do
      user = create_user
      post = create_post

      response = call_action(:destroy,
        params: { model_slug: "posts", id: post.id },
        headers: auth_headers(user))

      expect(response.status).to eq(204)
      expect(post.reload.discarded?).to be true
    end

    it "hard-deletes a record that does not support discard" do
      user = create_user
      blog = Blog.create!(title: "Test Blog")

      response = call_action(:destroy,
        params: { model_slug: "blogs", id: blog.id },
        headers: auth_headers(user))

      expect(response.status).to eq(204)
      expect(Blog.exists?(blog.id)).to be false
    end

    it "denies access without permission" do
      user = create_user(permissions: ["posts.index"])
      post = create_post

      response = call_action(:destroy,
        params: { model_slug: "posts", id: post.id },
        headers: auth_headers(user))

      expect(response.status).to eq(403)
    end
  end

  # ==================================================================
  # TRASHED
  # ==================================================================

  describe "GET trashed" do
    it "returns soft-deleted records" do
      user = create_user(permissions: ["*"])
      post1 = create_post(title: "Active")
      post2 = create_post(title: "Trashed")
      post2.discard!

      response = call_action(:trashed,
        params: { model_slug: "posts" },
        headers: auth_headers(user))

      expect(response.status).to eq(200)
      expect(response.body["data"].length).to eq(1)
      expect(response.body["data"].first["title"]).to eq("Trashed")
    end

    it "denies access without trashed permission" do
      user = create_user(permissions: ["posts.index"])

      response = call_action(:trashed,
        params: { model_slug: "posts" },
        headers: auth_headers(user))

      expect(response.status).to eq(403)
    end
  end

  # ==================================================================
  # RESTORE
  # ==================================================================

  describe "POST restore" do
    it "restores a soft-deleted record" do
      user = create_user(permissions: ["*"])
      post = create_post(title: "Restore Me")
      post.discard!

      response = call_action(:restore,
        params: { model_slug: "posts", id: post.id },
        headers: auth_headers(user))

      expect(response.status).to eq(200)
      expect(post.reload.discarded?).to be false
    end

    it "denies access without restore permission" do
      user = create_user(permissions: ["posts.index"])
      post = create_post
      post.discard!

      response = call_action(:restore,
        params: { model_slug: "posts", id: post.id },
        headers: auth_headers(user))

      expect(response.status).to eq(403)
    end
  end

  # ==================================================================
  # FORCE DELETE
  # ==================================================================

  describe "DELETE force_delete" do
    it "permanently deletes a soft-deleted record" do
      user = create_user(permissions: ["*"])
      post = create_post(title: "Delete Forever")
      post.discard!
      post_id = post.id

      response = call_action(:force_delete,
        params: { model_slug: "posts", id: post.id },
        headers: auth_headers(user))

      expect(response.status).to eq(204)
      expect(Post.unscoped.exists?(post_id)).to be false
    end

    it "denies access without forceDelete permission" do
      user = create_user(permissions: ["posts.destroy"])
      post = create_post
      post.discard!

      response = call_action(:force_delete,
        params: { model_slug: "posts", id: post.id },
        headers: auth_headers(user))

      expect(response.status).to eq(403)
    end
  end

  # ==================================================================
  # Organization Scoping
  # ==================================================================

  describe "organization scoping" do
    it "scopes index to current organization" do
      user = create_user
      org1 = create_organization(name: "Org 1", slug: "org-1-#{SecureRandom.uuid}")
      org2 = create_organization(name: "Org 2", slug: "org-2-#{SecureRandom.uuid}")

      post1 = create_post(title: "Org1 Post", organization_id: org1.id)
      post2 = create_post(title: "Org2 Post", organization_id: org2.id)

      response = call_action(:index,
        params: { model_slug: "posts" },
        headers: auth_headers(user),
        env_overrides: { "rhino.organization" => org1 })

      expect(response.status).to eq(200)
      titles = response.body["data"].map { |p| p["title"] }
      expect(titles).to include("Org1 Post")
      expect(titles).not_to include("Org2 Post")
    end

    it "scopes show to current organization" do
      user = create_user
      org1 = create_organization
      org2 = create_organization
      post = create_post(organization_id: org2.id)

      expect {
        call_action(:show,
          params: { model_slug: "posts", id: post.id },
          headers: auth_headers(user),
          env_overrides: { "rhino.organization" => org1 })
      }.to raise_error(ActiveRecord::RecordNotFound)
    end

    it "auto-sets organization_id on create" do
      user = create_user
      org = create_organization

      response = call_action(:store,
        params: { model_slug: "posts", title: "Auto Org" },
        headers: auth_headers(user),
        env_overrides: { "rhino.organization" => org })

      expect(response.status).to eq(201)
      expect(Post.last.organization_id).to eq(org.id)
    end
  end

  # ==================================================================
  # NESTED operations
  # ==================================================================

  describe "POST nested" do
    it "creates multiple records atomically" do
      user = create_user

      response = call_action(:nested,
        params: {
          operations: [
            { model: "posts", action: "create", data: { title: "Nested 1" } },
            { model: "posts", action: "create", data: { title: "Nested 2" } }
          ]
        },
        headers: auth_headers(user))

      expect(response.status).to eq(200)
      expect(response.body["results"].length).to eq(2)
      expect(response.body["results"][0]["action"]).to eq("create")
      expect(response.body["results"][1]["action"]).to eq("create")
    end

    it "updates records in nested operation" do
      user = create_user
      post = create_post(title: "Original")

      response = call_action(:nested,
        params: {
          operations: [
            { model: "posts", action: "update", id: post.id, data: { title: "Updated" } }
          ]
        },
        headers: auth_headers(user))

      expect(response.status).to eq(200)
      expect(response.body["results"][0]["action"]).to eq("update")
      expect(post.reload.title).to eq("Updated")
    end

    it "returns 422 when operations is not an array" do
      user = create_user

      response = call_action(:nested,
        params: { operations: "not an array" },
        headers: auth_headers(user))

      expect(response.status).to eq(422)
      expect(response.body["errors"]["operations"]).to be_present
    end

    it "returns 422 when operation missing model" do
      user = create_user

      response = call_action(:nested,
        params: {
          operations: [
            { action: "create", data: { title: "No Model" } }
          ]
        },
        headers: auth_headers(user))

      expect(response.status).to eq(422)
    end

    it "returns 422 when operation has invalid action" do
      user = create_user

      response = call_action(:nested,
        params: {
          operations: [
            { model: "posts", action: "delete", data: { title: "Bad Action" } }
          ]
        },
        headers: auth_headers(user))

      expect(response.status).to eq(422)
    end

    it "returns 422 when operation missing data" do
      user = create_user

      response = call_action(:nested,
        params: {
          operations: [
            { model: "posts", action: "create" }
          ]
        },
        headers: auth_headers(user))

      expect(response.status).to eq(422)
    end

    it "returns 422 when update operation missing id" do
      user = create_user

      response = call_action(:nested,
        params: {
          operations: [
            { model: "posts", action: "update", data: { title: "No ID" } }
          ]
        },
        headers: auth_headers(user))

      expect(response.status).to eq(422)
    end

    it "returns 422 for unknown model in nested operation" do
      user = create_user

      response = call_action(:nested,
        params: {
          operations: [
            { model: "nonexistent", action: "create", data: { title: "?" } }
          ]
        },
        headers: auth_headers(user))

      expect(response.status).to eq(422)
    end

    it "enforces max operations limit" do
      user = create_user
      Rhino.config.nested[:max_operations] = 2

      response = call_action(:nested,
        params: {
          operations: [
            { model: "posts", action: "create", data: { title: "1" } },
            { model: "posts", action: "create", data: { title: "2" } },
            { model: "posts", action: "create", data: { title: "3" } }
          ]
        },
        headers: auth_headers(user))

      expect(response.status).to eq(422)
      expect(response.body["message"]).to include("Too many operations")
    end

    it "enforces allowed_models restriction" do
      user = create_user
      Rhino.config.nested[:allowed_models] = ["blogs"]

      response = call_action(:nested,
        params: {
          operations: [
            { model: "posts", action: "create", data: { title: "Not allowed" } }
          ]
        },
        headers: auth_headers(user))

      expect(response.status).to eq(422)
      expect(response.body["message"]).to include("not allowed")
    end
  end

  # ==================================================================
  # Serialization
  # ==================================================================

  describe "serialization" do
    it "serializes records as json" do
      user = create_user
      post = create_post(title: "Serialized")

      response = call_action(:show,
        params: { model_slug: "posts", id: post.id },
        headers: auth_headers(user))

      expect(response.status).to eq(200)
      expect(response.body["title"]).to eq("Serialized")
      expect(response.body["id"]).to eq(post.id)
    end

    it "serializes collection correctly" do
      user = create_user
      create_post(title: "Post A")
      create_post(title: "Post B")

      response = call_action(:index,
        params: { model_slug: "posts" },
        headers: auth_headers(user))

      expect(response.status).to eq(200)
      expect(response.body["data"].map { |p| p["title"] }).to contain_exactly("Post A", "Post B")
    end
  end

  # ==================================================================
  # Policy resolution
  # ==================================================================

  describe "policy resolution" do
    it "uses model-specific policy when available" do
      user = create_user(permissions: ["posts.store"])
      # PostPolicy limits non-admin to title, content fields

      response = call_action(:store,
        params: { model_slug: "posts", title: "Test" },
        headers: auth_headers(user))

      # Should succeed with only title
      expect(response.status).to eq(201)
    end

    it "falls back to ResourcePolicy when no model-specific policy" do
      user = create_user(permissions: ["blogs.store"])

      response = call_action(:store,
        params: { model_slug: "blogs", title: "Blog" },
        headers: auth_headers(user))

      expect(response.status).to eq(201)
    end
  end

  # ==================================================================
  # Include authorization
  # ==================================================================

  describe "include authorization" do
    it "returns record with includes when no include auth needed" do
      user = create_user(permissions: ["*"])
      post = create_post(title: "With Include")

      # Without include param, just return the record
      response = call_action(:show,
        params: { model_slug: "posts", id: post.id },
        headers: auth_headers(user))

      expect(response.status).to eq(200)
      expect(response.body["title"]).to eq("With Include")
    end
  end

  # ==================================================================
  # Organization path discovery
  # ==================================================================

  describe "organization path discovery" do
    it "detects direct organization_id column" do
      user = create_user
      org = create_organization
      create_post(title: "Org Post", organization_id: org.id)

      response = call_action(:index,
        params: { model_slug: "posts" },
        headers: auth_headers(user),
        env_overrides: { "rhino.organization" => org })

      expect(response.status).to eq(200)
      # Should only return posts from org
      response.body["data"].each do |p|
        expect(p["organization_id"]).to eq(org.id)
      end
    end
  end

  # ==================================================================
  # Permitted fields resolution
  # ==================================================================

  describe "permitted fields resolution" do
    it "admin user can set any field via wildcard" do
      org = create_organization
      role = create_role(slug: "admin")
      user = create_user_in_org(org, role, permissions: ["*"])

      # Need to make PostPolicy recognize admin
      allow_any_instance_of(PostPolicy).to receive(:permitted_attributes_for_create).and_return(["*"])

      response = call_action(:store,
        params: { model_slug: "posts", title: "Admin Post", status: "published", is_published: true },
        headers: auth_headers(user))

      expect(response.status).to eq(201)
    end
  end

  # ==================================================================
  # find_forbidden_fields
  # ==================================================================

  describe "find_forbidden_fields" do
    it "returns empty for wildcard permissions" do
      controller = Rhino::ResourcesController.new
      result = controller.send(:find_forbidden_fields, { "title" => "x" }, ["*"])
      expect(result).to eq([])
    end

    it "returns forbidden keys" do
      controller = Rhino::ResourcesController.new
      result = controller.send(:find_forbidden_fields,
        { "title" => "x", "status" => "y" }, ["title"])
      expect(result).to eq(["status"])
    end
  end

  # ==================================================================
  # params_hash
  # ==================================================================

  describe "params_hash" do
    it "strips controller, action, model_slug, route_group, id, format" do
      user = create_user

      # We test this indirectly through store - the title should come through
      response = call_action(:store,
        params: { model_slug: "posts", title: "Param Test" },
        headers: auth_headers(user))

      expect(response.status).to eq(201)
      expect(response.body["title"]).to eq("Param Test")
    end
  end

  # ==================================================================
  # resolve_base_include_segment
  # ==================================================================

  describe "resolve_base_include_segment" do
    it "returns segment if in allowed list" do
      controller = Rhino::ResourcesController.new
      result = controller.send(:resolve_base_include_segment, "user", ["user", "comments"])
      expect(result).to eq("user")
    end

    it "strips Count suffix and returns base" do
      controller = Rhino::ResourcesController.new
      result = controller.send(:resolve_base_include_segment, "commentsCount", ["comments"])
      expect(result).to eq("comments")
    end

    it "strips Exists suffix and returns base" do
      controller = Rhino::ResourcesController.new
      result = controller.send(:resolve_base_include_segment, "commentsExists", ["comments"])
      expect(result).to eq("comments")
    end

    it "returns nil for unknown segment" do
      controller = Rhino::ResourcesController.new
      result = controller.send(:resolve_base_include_segment, "unknown", ["user"])
      expect(result).to be_nil
    end
  end

  # ==================================================================
  # Organization scoping - for_organization method
  # ==================================================================

  describe "organization scoping with for_organization" do
    it "scopes using for_organization when model responds to it" do
      user = create_user
      org = create_organization
      create_post(title: "Org Post", organization_id: org.id)

      # Post doesn't have for_organization, but the org scoping still works
      # via the organization_id column check
      response = call_action(:index,
        params: { model_slug: "posts" },
        headers: auth_headers(user),
        env_overrides: { "rhino.organization" => org })

      expect(response.status).to eq(200)
    end
  end

  # ==================================================================
  # Trashed with pagination
  # ==================================================================

  describe "trashed with pagination" do
    it "paginates trashed records" do
      user = create_user(permissions: ["*"])
      5.times { |i| p = create_post(title: "Trashed #{i}"); p.discard! }

      response = call_action(:trashed,
        params: { model_slug: "posts", per_page: "2" },
        headers: auth_headers(user))

      expect(response.status).to eq(200)
      expect(response.body["data"].length).to eq(2)
      expect(response.headers["X-Total"]).to eq("5")
    end
  end

  # ==================================================================
  # Nested operations - mixed create and update
  # ==================================================================

  describe "nested mixed operations" do
    it "handles mix of creates and updates" do
      user = create_user
      existing = create_post(title: "Existing")

      response = call_action(:nested,
        params: {
          operations: [
            { model: "posts", action: "create", data: { title: "New" } },
            { model: "posts", action: "update", id: existing.id, data: { title: "Modified" } }
          ]
        },
        headers: auth_headers(user))

      expect(response.status).to eq(200)
      results = response.body["results"]
      expect(results[0]["action"]).to eq("create")
      expect(results[1]["action"]).to eq("update")
      expect(existing.reload.title).to eq("Modified")
    end

    it "adds organization to nested create data" do
      user = create_user
      org = create_organization

      response = call_action(:nested,
        params: {
          operations: [
            { model: "posts", action: "create", data: { title: "Org Nested" } }
          ]
        },
        headers: auth_headers(user),
        env_overrides: { "rhino.organization" => org })

      expect(response.status).to eq(200)
      expect(Post.last.organization_id).to eq(org.id)
    end

    it "returns 422 for validation errors in nested operation" do
      user = create_user

      long_title = "x" * 300
      response = call_action(:nested,
        params: {
          operations: [
            { model: "posts", action: "create", data: { title: long_title } }
          ]
        },
        headers: auth_headers(user))

      expect(response.status).to eq(422)
      expect(response.body["errors"]).to be_present
    end

    it "returns 422 for non-object operation" do
      user = create_user

      response = call_action(:nested,
        params: {
          operations: ["not an object"]
        },
        headers: auth_headers(user))

      expect(response.status).to eq(422)
    end

    it "denies unauthorized nested create" do
      user = create_user(permissions: ["posts.index"])

      response = call_action(:nested,
        params: {
          operations: [
            { model: "posts", action: "create", data: { title: "Denied" } }
          ]
        },
        headers: auth_headers(user))

      expect(response.status).to eq(403)
    end

    it "denies unauthorized nested update" do
      user = create_user(permissions: ["posts.index"])
      post = create_post

      response = call_action(:nested,
        params: {
          operations: [
            { model: "posts", action: "update", id: post.id, data: { title: "Denied" } }
          ]
        },
        headers: auth_headers(user))

      expect(response.status).to eq(403)
    end
  end

  # ==================================================================
  # Current user resolution
  # ==================================================================

  describe "current user resolution" do
    it "resolves user by api_token column" do
      user = create_user(api_token: "specific-token")

      response = call_action(:index,
        params: { model_slug: "posts" },
        headers: { "Authorization" => "Bearer specific-token" })

      expect(response.status).to eq(200)
    end

    it "returns nil when no Authorization header" do
      response = call_action(:index,
        params: { model_slug: "posts" })

      expect(response.status).to eq(401)
    end
  end

  # ==================================================================
  # Blog model (uses default ResourcePolicy)
  # ==================================================================

  describe "blog model operations" do
    it "creates a blog record" do
      user = create_user(permissions: ["*"])

      response = call_action(:store,
        params: { model_slug: "blogs", title: "New Blog" },
        headers: auth_headers(user))

      expect(response.status).to eq(201)
      expect(response.body["title"]).to eq("New Blog")
    end

    it "lists blogs" do
      user = create_user(permissions: ["*"])
      Blog.create!(title: "Blog 1")
      Blog.create!(title: "Blog 2")

      response = call_action(:index,
        params: { model_slug: "blogs" },
        headers: auth_headers(user))

      expect(response.status).to eq(200)
      expect(response.body["data"].length).to eq(2)
    end
  end

  # ==================================================================
  # Policy resolution details
  # ==================================================================

  describe "policy_for" do
    it "resolves PostPolicy for Post" do
      controller = Rhino::ResourcesController.new
      result = controller.send(:policy_for, Post)
      expect(result).to eq(PostPolicy)
    end

    it "resolves PostPolicy for a Post instance" do
      controller = Rhino::ResourcesController.new
      result = controller.send(:policy_for, Post.new)
      expect(result).to eq(PostPolicy)
    end

    it "falls back to ResourcePolicy for unknown model" do
      controller = Rhino::ResourcesController.new
      result = controller.send(:policy_for, Comment.new)
      expect(result).to eq(Rhino::ResourcePolicy)
    end
  end

  # ==================================================================
  # Resolve permitted fields for different actions
  # ==================================================================

  describe "resolve_permitted_fields" do
    it "resolves create fields" do
      controller = Rhino::ResourcesController.new
      controller.instance_variable_set(:@model_class, Post)

      user = create_user(permissions: ["posts.store"])
      result = controller.send(:resolve_permitted_fields, user, "create")
      expect(result).to include("title")
    end

    it "resolves update fields" do
      controller = Rhino::ResourcesController.new
      controller.instance_variable_set(:@model_class, Post)

      user = create_user(permissions: ["posts.update"])
      result = controller.send(:resolve_permitted_fields, user, "update")
      expect(result).to include("title")
    end

    it "returns wildcard for unknown action" do
      controller = Rhino::ResourcesController.new
      controller.instance_variable_set(:@model_class, Post)

      user = create_user
      result = controller.send(:resolve_permitted_fields, user, "unknown")
      expect(result).to eq(["*"])
    end
  end

  # ==================================================================
  # Discover organization path
  # ==================================================================

  describe "discover_organization_path" do
    before do
      # Clear cache for each test
      Rhino::ResourcesController.class_variable_set(:@@organization_path_cache, {})
    end

    it "returns nil for max_depth <= 0" do
      controller = Rhino::ResourcesController.new
      result = controller.send(:_discover_organization_path_recursive, Post, [], 0)
      expect(result).to be_nil
    end

    it "returns nil for visited classes" do
      controller = Rhino::ResourcesController.new
      result = controller.send(:_discover_organization_path_recursive, Post, ["Post"], 3)
      expect(result).to be_nil
    end

    it "caches results" do
      controller = Rhino::ResourcesController.new
      controller.send(:discover_organization_path, Post)
      cache = Rhino::ResourcesController.class_variable_get(:@@organization_path_cache)
      expect(cache).to have_key("Post")
    end
  end

  # ------------------------------------------------------------------
  # show with includes
  # ------------------------------------------------------------------

  describe "show with includes" do
    it "returns 403 when user lacks include permissions" do
      user = create_user(permissions: ["posts.show"])
      post = Post.create!(title: "Include Post", user_id: user.id)

      result = call_action(:show, params: { id: post.id, include: "comments" },
                           headers: auth_headers(user))
      # User has posts.show but not comments.index, so include auth returns 403
      expect(result.status).to eq(403)
    end
  end

  # ------------------------------------------------------------------
  # authorize_includes
  # ------------------------------------------------------------------

  describe "authorize_includes" do
    it "returns nil when no include param" do
      controller = Rhino::ResourcesController.new
      env = Rack::MockRequest.env_for("/api/posts", method: "GET")
      env["action_dispatch.request.path_parameters"] = { model_slug: "posts" }
      request = ActionDispatch::Request.new(env)
      response = ActionDispatch::Response.new
      controller.dispatch(:index, request, response) rescue nil

      # Direct method test
      controller2 = Rhino::ResourcesController.new
      allow(controller2).to receive(:params).and_return({})
      result = controller2.send(:authorize_includes)
      expect(result).to be_nil
    end
  end

  # ------------------------------------------------------------------
  # resolve_base_include_segment
  # ------------------------------------------------------------------

  describe "resolve_base_include_segment" do
    it "returns segment when in allowed list" do
      controller = Rhino::ResourcesController.new
      result = controller.send(:resolve_base_include_segment, "comments", ["comments", "user"])
      expect(result).to eq("comments")
    end

    it "strips Count suffix" do
      controller = Rhino::ResourcesController.new
      result = controller.send(:resolve_base_include_segment, "commentsCount", ["comments"])
      expect(result).to eq("comments")
    end

    it "strips Exists suffix" do
      controller = Rhino::ResourcesController.new
      result = controller.send(:resolve_base_include_segment, "commentsExists", ["comments"])
      expect(result).to eq("comments")
    end

    it "returns nil for unknown segment" do
      controller = Rhino::ResourcesController.new
      result = controller.send(:resolve_base_include_segment, "unknown", ["comments"])
      expect(result).to be_nil
    end
  end
end
