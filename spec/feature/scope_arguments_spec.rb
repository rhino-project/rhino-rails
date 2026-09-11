# frozen_string_literal: true

require "spec_helper"
require "rhino/controllers/resources_controller"
require "ostruct"

# Model bound to the shared `posts` table. Named so HasAutoScope's convention
# lookup finds nothing, keeping these specs focused on ?scope= behavior.
class ArgScopePost < ActiveRecord::Base
  include Rhino::HasRhino
  include Rhino::HasValidation
  include Rhino::HidableColumns
  include Rhino::HasAutoScope
  include Discard::Model

  self.table_name = "posts"

  belongs_to :organization, optional: true
  belongs_to :user, optional: true

  scope :archived, -> { where(status: "archived") }
  scope :titled_like, ->(prefix) { where("title LIKE ?", "#{prefix}%") }
  scope :blog_window, ->(min, max) { where(blog_id: min.to_i..max.to_i) }

  rhino_filters :title, :status
  rhino_sorts :title, :status
  rhino_search :title

  rhino_scopes :archived,
               titled_like: { params: [:prefix] },
               blog_window: { params: %i[min max] },
               published_is: { params: [:flag],
                               with: ->(rel, _user, flag) { rel.where(is_published: flag == true) } },
               owned: { params: %i[status limit_to], optional: [:limit_to],
                        with: lambda { |rel, _user, status, limit_to = nil|
                          rel = rel.where(status: status)
                          limit_to ? rel.limit(limit_to.to_i) : rel
                        } }

  validates :title, length: { maximum: 255 }, allow_nil: true
end

class ArgScopePostPolicy < Rhino::ResourcePolicy
  self.resource_slug = "arg_scope_posts"
end

class RestrictedScopePost < ArgScopePost
  self.table_name = "posts"
end

class RestrictedScopePostPolicy < Rhino::ResourcePolicy
  self.resource_slug = "restricted_scope_posts"

  def permitted_scopes(_user)
    ["archived"]
  end
end

RSpec.describe "Named scope arguments (?scope[name][param]=)" do
  def call_index(params, user)
    controller = Rhino::ResourcesController.new
    slug = params[:model_slug]

    env = Rack::MockRequest.env_for("/api/#{slug}", method: "GET")
    env["action_dispatch.request.request_parameters"] = params.stringify_keys
    env["action_dispatch.request.path_parameters"] = {
      controller: "rhino/resources",
      action: "index",
      model_slug: slug
    }
    env["HTTP_AUTHORIZATION"] = "Bearer #{user.api_token}"

    request = ActionDispatch::Request.new(env)
    response = ActionDispatch::Response.new
    controller.dispatch(:index, request, response)

    body = begin
      JSON.parse(response.body)
    rescue JSON::ParserError
      {}
    end

    OpenStruct.new(status: response.status, body: body)
  end

  def create_user(attrs = {})
    User.create!({
      name: "Test User",
      email: "user-#{SecureRandom.uuid}@example.com",
      permissions: ["*"],
      api_token: SecureRandom.hex(20)
    }.merge(attrs))
  end

  def titles(response)
    response.body["data"].map { |row| row["title"] }
  end

  before do
    Rhino.config.model :arg_scope_posts, "ArgScopePost"
    Rhino.config.model :restricted_scope_posts, "RestrictedScopePost"

    ArgScopePost.create!(title: "Alpha", status: "archived", blog_id: 1, is_published: true)
    ArgScopePost.create!(title: "Beta",  status: "active",   blog_id: 5, is_published: false)
    ArgScopePost.create!(title: "Gamma", status: "active",   blog_id: 9, is_published: false)
  end

  let(:user) { create_user }

  # A real query string, parsed by Rack, rather than pre-built params: proves the
  # bracket form survives the wire.
  def call_index_with_query(slug, query_string, user)
    controller = Rhino::ResourcesController.new

    env = Rack::MockRequest.env_for("/api/#{slug}?#{query_string}", method: "GET")
    env["action_dispatch.request.path_parameters"] = {
      controller: "rhino/resources",
      action: "index",
      model_slug: slug
    }
    env["HTTP_AUTHORIZATION"] = "Bearer #{user.api_token}"

    request = ActionDispatch::Request.new(env)
    response = ActionDispatch::Response.new
    controller.dispatch(:index, request, response)

    body = begin
      JSON.parse(response.body)
    rescue JSON::ParserError
      {}
    end

    OpenStruct.new(status: response.status, body: body)
  end

  describe "over a real query string" do
    it "parses the bracket form with named arguments" do
      response = call_index_with_query(
        "arg_scope_posts", "scope[blogWindow][min]=4&scope[blogWindow][max]=6", user
      )

      expect(response.status).to eq(200)
      expect(titles(response)).to eq(["Beta"])
    end

    it "parses an empty value as a no-argument scope alongside one with arguments" do
      response = call_index_with_query(
        "arg_scope_posts", "scope[archived]=&scope[titledLike]=Al", user
      )

      expect(response.status).to eq(200)
      expect(titles(response)).to eq(["Alpha"])
    end

    it "still parses the legacy form" do
      response = call_index_with_query("arg_scope_posts", "scope=archived", user)

      expect(response.status).to eq(200)
      expect(titles(response)).to eq(["Alpha"])
    end
  end

  describe "backward compatibility" do
    it "still accepts the legacy ?scope=name form" do
      response = call_index({ model_slug: "arg_scope_posts", scope: "archived" }, user)

      expect(response.status).to eq(200)
      expect(titles(response)).to eq(["Alpha"])
    end

    it "accepts the bracket form with an empty value for a no-argument scope" do
      response = call_index({ model_slug: "arg_scope_posts", scope: { "archived" => "" } }, user)

      expect(response.status).to eq(200)
      expect(titles(response)).to eq(["Alpha"])
    end
  end

  describe "arguments" do
    it "binds a bare value to the single declared parameter" do
      response = call_index({ model_slug: "arg_scope_posts", scope: { "titledLike" => "Ga" } }, user)

      expect(response.status).to eq(200)
      expect(titles(response)).to eq(["Gamma"])
    end

    it "binds named arguments in declared order, whatever order they arrive in" do
      response = call_index(
        { model_slug: "arg_scope_posts", scope: { "blogWindow" => { "max" => "6", "min" => "4" } } }, user
      )

      expect(response.status).to eq(200)
      expect(titles(response)).to eq(["Beta"])
    end

    it "allows an optional parameter to be omitted" do
      response = call_index(
        { model_slug: "arg_scope_posts", scope: { "owned" => { "status" => "active" } } }, user
      )

      expect(response.status).to eq(200)
      expect(titles(response)).to eq(%w[Beta Gamma])
    end

    it "uses an optional parameter when it is sent" do
      response = call_index(
        { model_slug: "arg_scope_posts",
          scope: { "owned" => { "status" => "active", "limitTo" => "1" } } }, user
      )

      expect(response.status).to eq(200)
      expect(titles(response)).to eq(["Beta"])
    end

    it "hands the scope a real boolean, not the string 'false'" do
      response = call_index({ model_slug: "arg_scope_posts", scope: { "publishedIs" => "false" } }, user)

      expect(response.status).to eq(200)
      expect(titles(response)).to eq(%w[Beta Gamma])
    end
  end

  describe "argument errors" do
    it "rejects an unknown parameter" do
      response = call_index(
        { model_slug: "arg_scope_posts", scope: { "blogWindow" => { "min" => "1", "nope" => "2" } } }, user
      )

      expect(response.status).to eq(403)
      expect(response.body["message"]).to eq("Scope 'blogWindow' does not accept parameter 'nope'")
    end

    it "rejects a missing required parameter" do
      response = call_index(
        { model_slug: "arg_scope_posts", scope: { "blogWindow" => { "min" => "1" } } }, user
      )

      expect(response.status).to eq(403)
      expect(response.body["message"]).to eq("Scope 'blogWindow' requires parameter 'max'")
    end

    it "rejects a bare value for a multi-parameter scope" do
      response = call_index({ model_slug: "arg_scope_posts", scope: { "blogWindow" => "1,9" } }, user)

      expect(response.status).to eq(403)
      expect(response.body["message"]).to eq("Scope 'blogWindow' requires named parameters")
    end

    it "rejects a positional list" do
      response = call_index({ model_slug: "arg_scope_posts", scope: { "blogWindow" => %w[1 9] } }, user)

      expect(response.status).to eq(403)
      expect(response.body["message"]).to eq("Scope 'blogWindow' requires named parameters")
    end

    it "rejects arguments to a scope that declares none" do
      response = call_index({ model_slug: "arg_scope_posts", scope: { "archived" => "yesterday" } }, user)

      expect(response.status).to eq(403)
      expect(response.body["message"]).to eq("Scope 'archived' does not accept arguments")
    end

    it "rejects the legacy form for a scope with required parameters" do
      response = call_index({ model_slug: "arg_scope_posts", scope: "blogWindow" }, user)

      expect(response.status).to eq(403)
      expect(response.body["message"]).to eq("Scope 'blogWindow' requires parameter 'min'")
    end
  end

  describe "composition" do
    it "applies several scopes in the order the URL lists them" do
      response = call_index(
        { model_slug: "arg_scope_posts",
          scope: { "archived" => "", "titledLike" => "Al" } }, user
      )

      expect(response.status).to eq(200)
      expect(titles(response)).to eq(["Alpha"])
    end

    it "refuses more than three scopes" do
      response = call_index(
        { model_slug: "arg_scope_posts",
          scope: { "archived" => "", "titledLike" => "A", "publishedIs" => "true",
                   "blogWindow" => { "min" => "1", "max" => "9" } } }, user
      )

      expect(response.status).to eq(403)
      expect(response.body["message"]).to eq("Too many scopes requested")
    end
  end

  describe "the scope cap" do
    after { Rhino.config.max_scopes_per_request = 3 }

    it "is configurable" do
      Rhino.config.max_scopes_per_request = 2

      ok = call_index(
        { model_slug: "arg_scope_posts", scope: { "archived" => "", "titledLike" => "Al" } }, user
      )
      expect(ok.status).to eq(200)

      over = call_index(
        { model_slug: "arg_scope_posts",
          scope: { "archived" => "", "titledLike" => "A", "publishedIs" => "true" } }, user
      )
      expect(over.status).to eq(403)
      expect(over.body["message"]).to eq("Too many scopes requested")
    end

    it "falls back to the default when the value is nonsense" do
      Rhino.config.max_scopes_per_request = 0

      response = call_index(
        { model_slug: "arg_scope_posts",
          scope: { "archived" => "", "titledLike" => "A", "publishedIs" => "true" } }, user
      )

      expect(response.status).to eq(200)
    end
  end

  describe "permitted_scopes" do
    it "refuses a declared scope the policy does not permit" do
      response = call_index({ model_slug: "restricted_scope_posts", scope: { "titledLike" => "A" } }, user)

      expect(response.status).to eq(403)
      expect(response.body["message"]).to eq("Scope 'titledLike' is not allowed")
    end

    it "still runs a scope the policy permits" do
      response = call_index({ model_slug: "restricted_scope_posts", scope: "archived" }, user)

      expect(response.status).to eq(200)
      expect(titles(response)).to eq(["Alpha"])
    end

    it "allows every declared scope when the policy does not restrict them" do
      response = call_index({ model_slug: "arg_scope_posts", scope: { "titledLike" => "A" } }, user)

      expect(response.status).to eq(200)
    end

    it "still refuses an undeclared scope" do
      response = call_index({ model_slug: "arg_scope_posts", scope: { "secret" => "" } }, user)

      expect(response.status).to eq(403)
      expect(response.body["message"]).to eq("Scope 'secret' is not allowed")
    end
  end
end
