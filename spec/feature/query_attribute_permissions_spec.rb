# frozen_string_literal: true

require "spec_helper"
require "rhino/controllers/resources_controller"
require "ostruct"

class GatedPost < ActiveRecord::Base
  include Rhino::HasRhino
  include Rhino::HasValidation
  include Rhino::HidableColumns
  include Rhino::HasAutoScope
  include Discard::Model

  self.table_name = "posts"

  belongs_to :organization, optional: true
  belongs_to :user, optional: true

  rhino_filters :title, :status
  rhino_sorts :title, :status
  rhino_search :title, :content
end

class GatedPostPolicy < Rhino::ResourcePolicy
  self.resource_slug = "gated_posts"

  def hidden_attributes_for_show(_user)
    %w[status content]
  end
end

# Everything searchable is hidden from this user.
class SecretPost < GatedPost
  self.table_name = "posts"

  rhino_search :content
end

class SecretPostPolicy < Rhino::ResourcePolicy
  self.resource_slug = "secret_posts"

  def hidden_attributes_for_show(_user)
    %w[content]
  end
end

# Whitelist form of the same restriction.
class WhitelistPost < GatedPost
  self.table_name = "posts"
end

class WhitelistPostPolicy < Rhino::ResourcePolicy
  self.resource_slug = "whitelist_posts"

  def permitted_attributes_for_show(_user)
    %w[id title]
  end
end

RSpec.describe "Policy-gated filters, sorts and search" do
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

  before do
    Rhino.config.model :gated_posts, "GatedPost"
    Rhino.config.model :secret_posts, "SecretPost"
    Rhino.config.model :whitelist_posts, "WhitelistPost"

    GatedPost.create!(title: "Alpha", status: "archived", content: "needle in here")
    GatedPost.create!(title: "Beta", status: "active", content: "nothing")
  end

  let(:user) { create_user }

  it "still strips a hidden attribute from the response" do
    response = call_index({ model_slug: "gated_posts" }, user)

    expect(response.status).to eq(200)
    expect(response.body["data"].first.keys).not_to include("status", "content")
  end

  it "refuses to filter by a hidden attribute" do
    response = call_index({ model_slug: "gated_posts", filter: { "status" => "archived" } }, user)

    expect(response.status).to eq(403)
    expect(response.body["message"]).to eq("Filter 'status' is not allowed")
  end

  it "refuses to sort by a hidden attribute" do
    response = call_index({ model_slug: "gated_posts", sort: "-status" }, user)

    expect(response.status).to eq(403)
    expect(response.body["message"]).to eq("Sort 'status' is not allowed")
  end

  it "applies the same gate to a whitelist policy" do
    response = call_index({ model_slug: "whitelist_posts", filter: { "status" => "archived" } }, user)

    expect(response.status).to eq(403)
  end

  it "still filters and sorts by a visible attribute" do
    expect(call_index({ model_slug: "gated_posts", filter: { "title" => "Alpha" } }, user).status).to eq(200)
    expect(call_index({ model_slug: "gated_posts", sort: "-title" }, user).status).to eq(200)
  end

  it "ignores a column the model never allowlisted rather than refusing it" do
    response = call_index({ model_slug: "gated_posts", filter: { "content" => "needle" } }, user)

    expect(response.status).to eq(200)
    expect(response.body["data"].length).to eq(2)
  end

  it "searches only the columns this user may see" do
    response = call_index({ model_slug: "gated_posts", search: "needle" }, user)

    expect(response.status).to eq(200)
    expect(response.body["data"]).to eq([])

    visible = call_index({ model_slug: "gated_posts", search: "alpha" }, user)
    expect(visible.body["data"].map { |row| row["title"] }).to eq(["Alpha"])
  end

  it "returns nothing when every searchable column is hidden" do
    response = call_index({ model_slug: "secret_posts", search: "needle" }, user)

    expect(response.status).to eq(200)
    expect(response.body["data"]).to eq([])
  end

  it "does not sort by an undeclared column" do
    # Deny by default: an empty or partial rhino_sorts list no longer lets any
    # column through.
    response = call_index({ model_slug: "gated_posts", sort: "-content" }, user)

    expect(response.status).to eq(200)
    expect(response.body["data"].map { |row| row["title"] }).to eq(%w[Alpha Beta])
  end
end
