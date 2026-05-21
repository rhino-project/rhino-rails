# frozen_string_literal: true

require "spec_helper"
require "rails/command"
require "json"
require "rhino/commands/export_postman_command"

RSpec.describe Rhino::Commands::ExportPostmanCommand do
  let(:tmp_dir) { Dir.mktmpdir("rhino_postman_test") }
  let(:tmp_root) { Pathname.new(tmp_dir) }
  let(:command) { described_class.new }

  before do
    Rails.define_singleton_method(:root) { tmp_root } unless Rails.respond_to?(:root)
    allow(Rails).to receive(:root).and_return(tmp_root)
    allow(command).to receive(:say)
  end

  after do
    FileUtils.remove_entry(tmp_dir)
  end

  # Helper: run the command with a given config and return parsed JSON
  def run_export_with_config(models:, route_groups:, project_name: "TestAPI")
    Rhino.reset_configuration!
    Rhino.configure do |c|
      models.each { |slug, klass_name| c.model slug, klass_name }
      route_groups.each do |name, cfg|
        c.route_group name, prefix: cfg[:prefix] || "", middleware: cfg[:middleware] || [], models: cfg[:models] || :all
      end
    end

    output_path = File.join(tmp_dir, "collection_#{SecureRandom.hex(4)}.json")
    command.options = {
      output: output_path,
      base_url: "http://localhost:3000/api",
      project_name: project_name
    }

    command.perform

    expect(File.exist?(output_path)).to be true
    JSON.parse(File.read(output_path))
  end

  # ------------------------------------------------------------------
  # build_collection_variables
  # ------------------------------------------------------------------

  describe "#build_collection_variables" do
    it "returns base variables without org prefix" do
      vars = command.send(:build_collection_variables, "http://localhost:3000/api", false)

      expect(vars.length).to eq(3)
      expect(vars.map { |v| v[:key] }).to contain_exactly("baseUrl", "modelId", "token")
      expect(vars.find { |v| v[:key] == "baseUrl" }[:value]).to eq("http://localhost:3000/api")
    end

    it "includes organization variable with org prefix" do
      vars = command.send(:build_collection_variables, "http://localhost:3000/api", true)

      expect(vars.length).to eq(4)
      expect(vars.map { |v| v[:key] }).to include("organization")
    end
  end

  # ------------------------------------------------------------------
  # any_group_has_org_prefix?
  # ------------------------------------------------------------------

  describe "#any_group_has_org_prefix?" do
    it "returns true when a group has a parameterized prefix" do
      groups = { tenant: { prefix: ":organization" }, public: { prefix: "" } }
      expect(command.send(:any_group_has_org_prefix?, groups)).to be true
    end

    it "returns false when no group has a parameterized prefix" do
      groups = { admin: { prefix: "admin" }, public: { prefix: "" } }
      expect(command.send(:any_group_has_org_prefix?, groups)).to be false
    end

    it "returns false for empty groups" do
      expect(command.send(:any_group_has_org_prefix?, {})).to be false
    end
  end

  # ------------------------------------------------------------------
  # prefix_has_param?
  # ------------------------------------------------------------------

  describe "#prefix_has_param?" do
    it "returns true for prefix with colon param" do
      expect(command.send(:prefix_has_param?, ":organization")).to be true
    end

    it "returns false for literal prefix" do
      expect(command.send(:prefix_has_param?, "admin")).to be false
    end

    it "returns false for empty prefix" do
      expect(command.send(:prefix_has_param?, "")).to be false
    end
  end

  # ------------------------------------------------------------------
  # base_path
  # ------------------------------------------------------------------

  describe "#base_path" do
    it "returns URL without prefix when prefix is empty" do
      result = command.send(:base_path, :posts, "")
      expect(result).to eq("{{baseUrl}}/posts")
    end

    it "converts :param to {{param}} in prefix" do
      result = command.send(:base_path, :posts, ":organization")
      expect(result).to eq("{{baseUrl}}/{{organization}}/posts")
    end

    it "uses literal prefix as-is" do
      result = command.send(:base_path, :posts, "admin")
      expect(result).to eq("{{baseUrl}}/admin/posts")
    end
  end

  # ------------------------------------------------------------------
  # build_auth_folder
  # ------------------------------------------------------------------

  describe "#build_auth_folder" do
    it "returns Authentication folder with correct items" do
      folder = command.send(:build_auth_folder)

      expect(folder[:name]).to eq("Authentication")
      expect(folder[:item].length).to eq(6)

      names = folder[:item].map { |i| i[:name] }
      expect(names).to include("Login", "Logout", "Password recover",
                                "Password reset", "Register (with invitation)",
                                "Accept invitation")
    end

    it "Login request includes test script for token extraction" do
      folder = command.send(:build_auth_folder)
      login_item = folder[:item].find { |i| i[:name] == "Login" }

      expect(login_item[:event]).not_to be_nil
      script_exec = login_item[:event].first[:script][:exec]
      expect(script_exec.join("\n")).to include("pm.collectionVariables.set")
    end

    it "Login request has POST method with JSON body" do
      folder = command.send(:build_auth_folder)
      login_item = folder[:item].find { |i| i[:name] == "Login" }

      expect(login_item[:request][:method]).to eq("POST")
      expect(login_item[:request][:body]).not_to be_nil
      expect(login_item[:request][:body][:mode]).to eq("raw")
    end
  end

  # ------------------------------------------------------------------
  # introspect_model
  # ------------------------------------------------------------------

  describe "#introspect_model" do
    it "extracts metadata from model class" do
      meta = command.send(:introspect_model, Post, :posts)

      expect(meta[:slug]).to eq(:posts)
      expect(meta[:allowed_filters].map(&:to_s)).to include("title", "status")
      expect(meta[:allowed_sorts].map(&:to_s)).to include("title", "created_at")
      expect(meta[:allowed_fields].map(&:to_s)).to include("id", "title")
      expect(meta[:allowed_includes].map(&:to_s)).to include("user", "comments")
      expect(meta[:allowed_search].map(&:to_s)).to include("title", "content")
    end

    it "detects soft deletes" do
      meta = command.send(:introspect_model, Post, :posts)
      # Post includes Discard::Model
      expect(meta[:uses_soft_deletes]).to be true
    end
  end

  # ------------------------------------------------------------------
  # build_action_folders
  # ------------------------------------------------------------------

  describe "#build_action_folders" do
    let(:meta) do
      {
        slug: :posts,
        except_actions: [],
        uses_soft_deletes: false,
        allowed_filters: [:status],
        allowed_sorts: [:created_at],
        allowed_fields: [:id, :title],
        allowed_includes: [:user],
        allowed_search: [:title],
        default_sort: "-created_at"
      }
    end

    it "creates standard CRUD folders" do
      folders = command.send(:build_action_folders, :posts, meta, "")
      folder_names = folders.map { |f| f[:name] }

      expect(folder_names).to include("Index", "Show", "Store", "Update", "Destroy")
    end

    it "includes soft delete folders when model uses soft deletes" do
      meta_with_soft_delete = meta.merge(uses_soft_deletes: true)
      folders = command.send(:build_action_folders, :posts, meta_with_soft_delete, "")
      folder_names = folders.map { |f| f[:name] }

      expect(folder_names).to include("Trashed", "Restore", "Force Delete")
    end

    it "excludes folders listed in except_actions" do
      meta_with_except = meta.merge(except_actions: ["store", "destroy"])
      folders = command.send(:build_action_folders, :posts, meta_with_except, "")
      folder_names = folders.map { |f| f[:name] }

      expect(folder_names).not_to include("Store", "Destroy")
      expect(folder_names).to include("Index", "Show", "Update")
    end

    it "includes org prefix in URLs when needed" do
      folders = command.send(:build_action_folders, :posts, meta, ":organization")
      index_folder = folders.find { |f| f[:name] == "Index" }
      list_item = index_folder[:item].first

      expect(list_item[:request][:url][:raw]).to include("{{organization}}")
    end

    it "uses literal prefix in URLs" do
      folders = command.send(:build_action_folders, :posts, meta, "admin")
      index_folder = folders.find { |f| f[:name] == "Index" }
      list_item = index_folder[:item].first

      expect(list_item[:request][:url][:raw]).to include("{{baseUrl}}/admin/posts")
    end
  end

  # ------------------------------------------------------------------
  # build_index_requests
  # ------------------------------------------------------------------

  describe "#build_index_requests" do
    let(:meta) do
      {
        slug: :posts,
        allowed_filters: [:status, :user_id],
        allowed_sorts: [:created_at, :title],
        allowed_fields: [:id, :title, :status],
        allowed_includes: [:user],
        allowed_search: [:title],
        default_sort: "-created_at"
      }
    end

    it "includes list, filter, sort, include, fields, search, and pagination requests" do
      requests = command.send(:build_index_requests, "{{baseUrl}}/posts", :posts, meta)

      names = requests.map { |r| r[:name] }
      expect(names).to include("List all")
      expect(names).to include("Filter by status")
      expect(names).to include("Sort by created_at (asc)")
      expect(names).to include("Sort by created_at (desc)")
      expect(names).to include("Include user")
      expect(names).to include("Select fields")
      expect(names).to include("Search")
      expect(names).to include("Paginate")
    end
  end

  # ------------------------------------------------------------------
  # request_item
  # ------------------------------------------------------------------

  describe "#request_item" do
    it "builds a GET request" do
      item = command.send(:request_item, "List all", "GET",
                          "{{baseUrl}}/posts", {}, [{ key: "Accept", value: "application/json" }])

      expect(item[:name]).to eq("List all")
      expect(item[:request][:method]).to eq("GET")
      expect(item[:request][:body]).to be_nil
    end

    it "builds a POST request with body" do
      headers = [
        { key: "Accept", value: "application/json" },
        { key: "Content-Type", value: "application/json" }
      ]
      item = command.send(:request_item, "Create", "POST",
                          "{{baseUrl}}/posts", {}, headers,
                          { title: "Example" })

      expect(item[:request][:method]).to eq("POST")
      expect(item[:request][:body]).not_to be_nil
      expect(item[:request][:body][:mode]).to eq("raw")

      body = JSON.parse(item[:request][:body][:raw])
      expect(body["title"]).to eq("Example")
    end

    it "includes query parameters in URL" do
      item = command.send(:request_item, "Filter", "GET",
                          "{{baseUrl}}/posts",
                          { "filter[status]" => "active" },
                          [{ key: "Accept", value: "application/json" }])

      expect(item[:request][:url][:raw]).to include("filter[status]=active")
      expect(item[:request][:url][:query]).not_to be_empty
    end

    it "includes test script when provided" do
      script = "pm.test('ok', function() {});"
      item = command.send(:request_item, "Test", "GET",
                          "{{baseUrl}}/posts", {},
                          [{ key: "Accept", value: "application/json" }],
                          nil, script)

      expect(item[:event]).not_to be_nil
      expect(item[:event].first[:listen]).to eq("test")
      expect(item[:event].first[:script][:exec]).to include(script)
    end
  end

  # ------------------------------------------------------------------
  # default_headers
  # ------------------------------------------------------------------

  describe "#default_headers" do
    it "includes Accept and Authorization headers" do
      headers = command.send(:default_headers)

      expect(headers.length).to eq(2)
      expect(headers.find { |h| h[:key] == "Accept" }[:value]).to eq("application/json")
      expect(headers.find { |h| h[:key] == "Authorization" }[:value]).to eq("Bearer {{token}}")
    end
  end

  # ==================================================================
  # Full collection generation — Single group: non-tenant (no prefix)
  # ==================================================================

  describe "single group: non-tenant (default, no prefix)" do
    it "generates a valid Postman collection JSON file" do
      json = run_export_with_config(
        models: { posts: "Post", blogs: "Blog" },
        route_groups: { default: { prefix: "", models: :all } }
      )

      expect(json["info"]["name"]).to eq("TestAPI")
      expect(json["info"]["schema"]).to include("postman.com")
      expect(json["variable"]).to be_an(Array)
      expect(json["item"]).to be_an(Array)
    end

    it "has flat structure with Authentication and model folders at top level" do
      json = run_export_with_config(
        models: { posts: "Post", blogs: "Blog" },
        route_groups: { default: { prefix: "", models: :all } }
      )

      item_names = json["item"].map { |i| i["name"] }
      expect(item_names).to include("Authentication", "posts", "blogs")
      expect(item_names).not_to include("default")
    end

    it "URLs have no prefix" do
      json = run_export_with_config(
        models: { posts: "Post" },
        route_groups: { default: { prefix: "", models: :all } }
      )

      posts_folder = json["item"].find { |i| i["name"] == "posts" }
      index_folder = posts_folder["item"].find { |i| i["name"] == "Index" }
      raw_url = index_folder["item"][0]["request"]["url"]["raw"]
      expect(raw_url).to include("{{baseUrl}}/posts")
      expect(raw_url).not_to include("{{organization}}")
    end

    it "omits organization variable" do
      json = run_export_with_config(
        models: { posts: "Post" },
        route_groups: { default: { prefix: "", models: :all } }
      )

      var_keys = json["variable"].map { |v| v["key"] }
      expect(var_keys).not_to include("organization")
    end

    it "Authentication folder is first" do
      json = run_export_with_config(
        models: { posts: "Post" },
        route_groups: { default: { prefix: "", models: :all } }
      )

      expect(json["item"][0]["name"]).to eq("Authentication")
    end

    it "model folder has action folders directly" do
      json = run_export_with_config(
        models: { posts: "Post" },
        route_groups: { default: { prefix: "", models: :all } }
      )

      posts_folder = json["item"].find { |i| i["name"] == "posts" }
      action_names = posts_folder["item"].map { |i| i["name"] }
      expect(action_names).to include("Index", "Show", "Store", "Update", "Destroy")
    end

    it "all requests have bearer token header" do
      json = run_export_with_config(
        models: { posts: "Post" },
        route_groups: { default: { prefix: "", models: :all } }
      )

      posts_folder = json["item"].find { |i| i["name"] == "posts" }
      index_folder = posts_folder["item"].find { |i| i["name"] == "Index" }
      list_all_request = index_folder["item"][0]["request"]
      auth_header = list_all_request["header"].find { |h| h["key"] == "Authorization" }
      expect(auth_header).not_to be_nil
      expect(auth_header["value"]).to eq("Bearer {{token}}")
    end
  end

  # ==================================================================
  # Full collection generation — Single group: tenant (with :organization prefix)
  # ==================================================================

  describe "single group: tenant (with :organization prefix)" do
    it "has flat structure (no group-level folder)" do
      json = run_export_with_config(
        models: { posts: "Post" },
        route_groups: { tenant: { prefix: ":organization", models: :all } }
      )

      item_names = json["item"].map { |i| i["name"] }
      expect(item_names).to include("Authentication", "posts")
      expect(item_names).not_to include("tenant")
    end

    it "URLs have organization prefix" do
      json = run_export_with_config(
        models: { posts: "Post" },
        route_groups: { tenant: { prefix: ":organization", models: :all } }
      )

      posts_folder = json["item"].find { |i| i["name"] == "posts" }
      index_folder = posts_folder["item"].find { |i| i["name"] == "Index" }
      raw_url = index_folder["item"][0]["request"]["url"]["raw"]
      expect(raw_url).to include("{{baseUrl}}/{{organization}}/posts")
    end

    it "includes organization variable" do
      json = run_export_with_config(
        models: { posts: "Post" },
        route_groups: { tenant: { prefix: ":organization", models: :all } }
      )

      var_keys = json["variable"].map { |v| v["key"] }
      expect(var_keys).to include("organization")
    end
  end

  # ==================================================================
  # Full collection generation — Single group: literal prefix (e.g. admin)
  # ==================================================================

  describe "single group: literal prefix" do
    it "has flat structure" do
      json = run_export_with_config(
        models: { posts: "Post" },
        route_groups: { admin: { prefix: "admin", models: :all } }
      )

      item_names = json["item"].map { |i| i["name"] }
      expect(item_names).to include("posts")
      expect(item_names).not_to include("admin")
    end

    it "URLs use literal prefix" do
      json = run_export_with_config(
        models: { posts: "Post" },
        route_groups: { admin: { prefix: "admin", models: :all } }
      )

      posts_folder = json["item"].find { |i| i["name"] == "posts" }
      index_folder = posts_folder["item"].find { |i| i["name"] == "Index" }
      raw_url = index_folder["item"][0]["request"]["url"]["raw"]
      expect(raw_url).to include("{{baseUrl}}/admin/posts")
    end

    it "omits organization variable" do
      json = run_export_with_config(
        models: { posts: "Post" },
        route_groups: { admin: { prefix: "admin", models: :all } }
      )

      var_keys = json["variable"].map { |v| v["key"] }
      expect(var_keys).not_to include("organization")
    end
  end

  # ==================================================================
  # Full collection generation — Multiple groups: tenant + public
  # ==================================================================

  describe "multiple groups: tenant + public" do
    let(:json) do
      run_export_with_config(
        models: { posts: "Post", blogs: "Blog" },
        route_groups: {
          tenant: { prefix: ":organization", models: :all },
          public: { prefix: "public", models: [:blogs] }
        }
      )
    end

    it "creates group-level folders" do
      item_names = json["item"].map { |i| i["name"] }
      expect(item_names).to include("Authentication", "tenant", "public")
      expect(item_names).not_to include("posts")
      expect(item_names).not_to include("blogs")
    end

    it "tenant folder contains all models" do
      tenant_folder = json["item"].find { |i| i["name"] == "tenant" }
      model_names = tenant_folder["item"].map { |i| i["name"] }
      expect(model_names).to include("posts", "blogs")
    end

    it "public folder contains only specified models" do
      public_folder = json["item"].find { |i| i["name"] == "public" }
      model_names = public_folder["item"].map { |i| i["name"] }
      expect(model_names).to include("blogs")
      expect(model_names).not_to include("posts")
    end

    it "tenant URLs have organization prefix" do
      tenant_folder = json["item"].find { |i| i["name"] == "tenant" }
      posts_folder = tenant_folder["item"].find { |i| i["name"] == "posts" }
      index_folder = posts_folder["item"].find { |i| i["name"] == "Index" }
      raw_url = index_folder["item"][0]["request"]["url"]["raw"]
      expect(raw_url).to include("{{baseUrl}}/{{organization}}/posts")
    end

    it "public URLs have public prefix" do
      public_folder = json["item"].find { |i| i["name"] == "public" }
      blogs_folder = public_folder["item"].find { |i| i["name"] == "blogs" }
      index_folder = blogs_folder["item"].find { |i| i["name"] == "Index" }
      raw_url = index_folder["item"][0]["request"]["url"]["raw"]
      expect(raw_url).to include("{{baseUrl}}/public/blogs")
    end

    it "includes organization variable when any group has param prefix" do
      var_keys = json["variable"].map { |v| v["key"] }
      expect(var_keys).to include("organization")
    end

    it "Authentication folder is first" do
      expect(json["item"][0]["name"]).to eq("Authentication")
    end

    it "model actions are nested under group then model" do
      tenant_folder = json["item"].find { |i| i["name"] == "tenant" }
      posts_folder = tenant_folder["item"].find { |i| i["name"] == "posts" }
      action_names = posts_folder["item"].map { |i| i["name"] }
      expect(action_names).to include("Index", "Show", "Store", "Update", "Destroy")
    end

    it "soft delete actions appear for models that use soft deletes" do
      tenant_folder = json["item"].find { |i| i["name"] == "tenant" }
      posts_folder = tenant_folder["item"].find { |i| i["name"] == "posts" }
      action_names = posts_folder["item"].map { |i| i["name"] }
      # Post includes Discard::Model
      expect(action_names).to include("Trashed", "Restore", "Force Delete")
    end
  end

  # ==================================================================
  # Full collection generation — Multiple groups: no tenant (admin + public)
  # ==================================================================

  describe "multiple groups: no tenant (admin + public)" do
    let(:json) do
      run_export_with_config(
        models: { posts: "Post", blogs: "Blog" },
        route_groups: {
          admin: { prefix: "admin", models: :all },
          public: { prefix: "", models: [:blogs] }
        }
      )
    end

    it "creates group-level folders" do
      item_names = json["item"].map { |i| i["name"] }
      expect(item_names).to include("admin", "public")
    end

    it "omits organization variable" do
      var_keys = json["variable"].map { |v| v["key"] }
      expect(var_keys).not_to include("organization")
    end

    it "admin group URLs have admin prefix" do
      admin_folder = json["item"].find { |i| i["name"] == "admin" }
      posts_folder = admin_folder["item"].find { |i| i["name"] == "posts" }
      index_folder = posts_folder["item"].find { |i| i["name"] == "Index" }
      raw_url = index_folder["item"][0]["request"]["url"]["raw"]
      expect(raw_url).to include("{{baseUrl}}/admin/posts")
    end

    it "public group with empty prefix has no prefix in URLs" do
      public_folder = json["item"].find { |i| i["name"] == "public" }
      blogs_folder = public_folder["item"].find { |i| i["name"] == "blogs" }
      index_folder = blogs_folder["item"].find { |i| i["name"] == "Index" }
      raw_url = index_folder["item"][0]["request"]["url"]["raw"]
      expect(raw_url).to include("{{baseUrl}}/blogs")
      expect(raw_url).not_to include("admin")
    end
  end

  # ==================================================================
  # Full collection generation — Three groups
  # ==================================================================

  describe "three groups" do
    let(:json) do
      run_export_with_config(
        models: { posts: "Post", blogs: "Blog" },
        route_groups: {
          tenant: { prefix: ":organization", models: :all },
          admin: { prefix: "admin", models: [:posts] },
          public: { prefix: "", models: [:blogs] }
        }
      )
    end

    it "all three groups appear as folders" do
      item_names = json["item"].map { |i| i["name"] }
      expect(item_names).to include("Authentication", "tenant", "admin", "public")
    end

    it "each group has correct models" do
      tenant_folder = json["item"].find { |i| i["name"] == "tenant" }
      tenant_models = tenant_folder["item"].map { |i| i["name"] }
      expect(tenant_models).to include("posts", "blogs")

      admin_folder = json["item"].find { |i| i["name"] == "admin" }
      admin_models = admin_folder["item"].map { |i| i["name"] }
      expect(admin_models).to include("posts")
      expect(admin_models).not_to include("blogs")

      public_folder = json["item"].find { |i| i["name"] == "public" }
      public_models = public_folder["item"].map { |i| i["name"] }
      expect(public_models).to include("blogs")
      expect(public_models).not_to include("posts")
    end

    it "URLs use correct prefix per group" do
      # tenant: :organization prefix
      tenant_folder = json["item"].find { |i| i["name"] == "tenant" }
      posts_folder = tenant_folder["item"].find { |i| i["name"] == "posts" }
      raw_url = posts_folder["item"].find { |i| i["name"] == "Index" }["item"][0]["request"]["url"]["raw"]
      expect(raw_url).to include("{{baseUrl}}/{{organization}}/posts")

      # admin: admin prefix
      admin_folder = json["item"].find { |i| i["name"] == "admin" }
      admin_posts = admin_folder["item"].find { |i| i["name"] == "posts" }
      admin_raw_url = admin_posts["item"].find { |i| i["name"] == "Index" }["item"][0]["request"]["url"]["raw"]
      expect(admin_raw_url).to include("{{baseUrl}}/admin/posts")

      # public: no prefix
      public_folder = json["item"].find { |i| i["name"] == "public" }
      public_blogs = public_folder["item"].find { |i| i["name"] == "blogs" }
      public_raw_url = public_blogs["item"].find { |i| i["name"] == "Index" }["item"][0]["request"]["url"]["raw"]
      expect(public_raw_url).to include("{{baseUrl}}/blogs")
    end

    it "soft deletes respected in group context" do
      # Post has Discard::Model (soft deletes), verify in admin group
      admin_folder = json["item"].find { |i| i["name"] == "admin" }
      posts_folder = admin_folder["item"].find { |i| i["name"] == "posts" }
      action_names = posts_folder["item"].map { |i| i["name"] }
      expect(action_names).to include("Trashed", "Restore", "Force Delete")
    end
  end

  # ==================================================================
  # Edge case: group with no matching models is excluded
  # ==================================================================

  describe "group with no matching models" do
    it "is excluded from the collection" do
      json = run_export_with_config(
        models: { posts: "Post" },
        route_groups: {
          tenant: { prefix: ":organization", models: :all },
          driver: { prefix: "driver", models: [:nonexistent_model] }
        }
      )

      item_names = json["item"].map { |i| i["name"] }
      expect(item_names).to include("tenant")
      expect(item_names).not_to include("driver")
    end
  end

  # ==================================================================
  # Edge case: Authentication folder always first with multiple groups
  # ==================================================================

  describe "authentication folder ordering" do
    it "Authentication is first with multiple groups" do
      json = run_export_with_config(
        models: { posts: "Post", blogs: "Blog" },
        route_groups: {
          tenant: { prefix: ":organization", models: :all },
          public: { prefix: "public", models: [:blogs] }
        }
      )

      expect(json["item"][0]["name"]).to eq("Authentication")
    end
  end

  # ==================================================================
  # Collection variables and base URL
  # ==================================================================

  describe "collection variables" do
    it "includes baseUrl and modelId" do
      json = run_export_with_config(
        models: { posts: "Post" },
        route_groups: { default: { prefix: "", models: :all } }
      )

      vars = json["variable"].each_with_object({}) { |v, h| h[v["key"]] = v["value"] }
      expect(vars["baseUrl"]).to eq("http://localhost:3000/api")
      expect(vars).to have_key("modelId")
      expect(vars).to have_key("token")
    end
  end
end
