# frozen_string_literal: true

require "spec_helper"
require "rhino/controllers/resources_controller"
require "ostruct"

# --------------------------------------------------------------------------
# Smoke coverage for request classes (Rhino::ResourceRequest).
#
# NOTE: these classes are deliberately NOT named PostStoreRequest /
# PostUpdateRequest. Convention-based discovery is global, so a constant with
# the conventional name would silently switch every other Post spec in the suite
# onto the request-class path. Convention discovery is exercised below against a
# throwaway model class instead; the HTTP rows use explicit registration.
# --------------------------------------------------------------------------

class SmokePostStoreRequest < Rhino::ResourceRequest
  attribute :title, :string
  attribute :status, :string

  validates :title, presence: true, length: { maximum: 255 }

  # Normalizes an existing field AND adds a server-authored one. `status` is not
  # in the policy's permitted_attributes_for_create, which is exactly the point:
  # prepare runs after the forbidden-field gate, so what it adds is trusted.
  def prepare(input)
    input.merge(
      "title" => input["title"].to_s.strip,
      "status" => input["status"].presence || "draft"
    )
  end
end

class SmokePostUpdateRequest < Rhino::ResourceRequest
  attribute :title, :string

  validates :title, presence: true
end

class SmokeUnauthorizedPostStoreRequest < Rhino::ResourceRequest
  attribute :title, :string

  def authorize?
    false
  end
end

class SmokeNotAResourceRequest; end

# Throwaway model-shaped class used only for convention-discovery assertions.
class SmokeWidget; end
class SmokeWidgetStoreRequest < Rhino::ResourceRequest; end
class SmokeWidgetUpdateRequest < Rhino::ResourceRequest; end

RSpec.describe "Request classes" do
  def call_action(action, params: {}, headers: {})
    controller = Rhino::ResourcesController.new

    method = action.to_s == "update" ? "PUT" : "POST"
    env = Rack::MockRequest.env_for("/api/posts", method: method)
    env["action_dispatch.request.request_parameters"] = params.stringify_keys
    env["action_dispatch.request.path_parameters"] = {
      controller: "rhino/resources",
      action: action.to_s,
      model_slug: "posts"
    }.merge(params.slice(:id).transform_keys(&:to_sym))

    headers.each { |key, value| env["HTTP_#{key.upcase.tr('-', '_')}"] = value }

    request = ActionDispatch::Request.new(env)
    response = ActionDispatch::Response.new

    begin
      controller.dispatch(action.to_sym, request, response)
    rescue Pundit::NotAuthorizedError
      response.status = 403
      response.body = { message: "This action is unauthorized." }.to_json
    end

    body = begin
      JSON.parse(response.body)
    rescue JSON::ParserError
      {}
    end

    OpenStruct.new(status: response.status, body: body)
  end

  let(:user) do
    User.create!(
      name: "Smoke User",
      email: "smoke-#{SecureRandom.uuid}@example.com",
      permissions: ["*"],
      api_token: SecureRandom.hex(20)
    )
  end

  def auth_headers
    { "Authorization" => "Bearer #{user.api_token}" }
  end

  def register(store: nil, update: nil)
    Rhino.configure do |c|
      c.model :posts, "Post", store_request: store, update_request: update
    end
  end

  # ------------------------------------------------------------------
  # Discovery
  # ------------------------------------------------------------------

  describe "discovery" do
    let(:controller) { Rhino::ResourcesController.new }

    it "falls back to the {Model}StoreRequest / {Model}UpdateRequest convention" do
      expect(controller.send(:request_class_for, "store", SmokeWidget, "smoke_widgets"))
        .to eq(SmokeWidgetStoreRequest)
      expect(controller.send(:request_class_for, "update", SmokeWidget, "smoke_widgets"))
        .to eq(SmokeWidgetUpdateRequest)
    end

    it "returns nil when neither an explicit registration nor a conventional class exists" do
      expect(controller.send(:request_class_for, "store", Post, "posts")).to be_nil
    end

    it "prefers an explicit registration over the convention" do
      register(store: "SmokePostStoreRequest")

      expect(controller.send(:request_class_for, "store", Post, "posts"))
        .to eq(SmokePostStoreRequest)
    end

    it "resolves per request and never memoizes the constant (Zeitwerk reloading)" do
      first = controller.send(:request_class_for, "store", SmokeWidget, "smoke_widgets")

      original = SmokeWidgetStoreRequest
      Object.send(:remove_const, :SmokeWidgetStoreRequest)
      Object.const_set(:SmokeWidgetStoreRequest, Class.new(Rhino::ResourceRequest))

      begin
        second = controller.send(:request_class_for, "store", SmokeWidget, "smoke_widgets")
        expect(second).not_to equal(first)
        expect(second).to equal(SmokeWidgetStoreRequest)
      ensure
        Object.send(:remove_const, :SmokeWidgetStoreRequest)
        Object.const_set(:SmokeWidgetStoreRequest, original)
      end
    end

    it "raises ConfigurationError for an explicit registration that cannot be resolved" do
      register(store: "NoSuchRequestClassAnywhere")

      expect { controller.send(:request_class_for, "store", Post, "posts") }
        .to raise_error(
          Rhino::ConfigurationError,
          "Rhino: request class [NoSuchRequestClassAnywhere] configured for [posts.store] does not exist."
        )
    end

    it "raises ConfigurationError for an EXPLICIT registration that is not a ResourceRequest" do
      register(store: "SmokeNotAResourceRequest")

      expect { controller.send(:request_class_for, "store", Post, "posts") }
        .to raise_error(
          Rhino::ConfigurationError,
          "Rhino: request class [SmokeNotAResourceRequest] configured for [posts.store] does not exist."
        )
    end

    it "warns and falls through when a CONVENTION hit is not a ResourceRequest" do
      # An app upgrading from 4.9.0 may already own an unrelated top-level
      # class with the conventional name. It must keep working on the legacy
      # path, not start returning 500s.
      stub_const("SmokeLegacyStoreRequest", Class.new)
      stub_const("SmokeLegacy", Class.new)

      logger = instance_double(Logger)
      allow(Rails).to receive(:logger).and_return(logger)
      expect(logger).to receive(:warn).with(
        "Rhino: ignoring SmokeLegacyStoreRequest for [smoke_legacies.store]: " \
        "it does not inherit from Rhino::ResourceRequest"
      )

      expect(controller.send(:request_class_for, "store", SmokeLegacy, "smoke_legacies")).to be_nil
    end
  end

  # ------------------------------------------------------------------
  # HTTP behavior
  # ------------------------------------------------------------------

  describe "POST /posts" do
    it "persists only declared attributes, dropping a policy-permitted field the class omits" do
      register(store: "SmokePostStoreRequest")

      response = call_action(
        :store,
        params: { "title" => "  Hello  ", "content" => "dropped" },
        headers: auth_headers
      )

      expect(response.status).to eq(201)
      post = Post.order(:id).last
      expect(post.title).to eq("Hello")          # normalized by prepare
      expect(post.status).to eq("draft")         # added by prepare, covered by a rule
      expect(post.content).to be_nil             # permitted by the policy, undeclared here
    end

    it "returns 422 with the standard envelope when a rule fails" do
      register(store: "SmokePostStoreRequest")

      response = call_action(:store, params: { "content" => "no title" }, headers: auth_headers)

      expect(response.status).to eq(422)
      expect(response.body["errors"]).to eq("title" => ["can't be blank"])
    end

    it "returns the policy-denial 403 body when authorize? is false" do
      register(store: "SmokeUnauthorizedPostStoreRequest")

      response = call_action(:store, params: { "title" => "Hello" }, headers: auth_headers)

      expect(response.status).to eq(403)
      expect(response.body).to eq("message" => "This action is unauthorized.")
      expect(Post.count).to eq(0)
    end
  end

  describe "PUT /posts/:id" do
    it "writes only the declared attributes and leaves everything else untouched" do
      register(update: "SmokePostUpdateRequest")
      post = Post.create!(title: "Before", content: "keep me", status: "draft")

      response = call_action(
        :update,
        params: { "id" => post.id, "title" => "After", "content" => "ignored" },
        headers: auth_headers
      )

      expect(response.status).to eq(200)
      post.reload
      expect(post.title).to eq("After")
      expect(post.content).to eq("keep me")
    end

    it "returns 422 when a rule fails" do
      register(update: "SmokePostUpdateRequest")
      post = Post.create!(title: "Before")

      response = call_action(
        :update,
        params: { "id" => post.id, "title" => "" },
        headers: auth_headers
      )

      expect(response.status).to eq(422)
      expect(response.body["errors"]).to eq("title" => ["can't be blank"])
    end
  end

  # ------------------------------------------------------------------
  # Rhino::ResourceRequest unit behavior
  # ------------------------------------------------------------------

  describe Rhino::ResourceRequest do
    it "exposes the full context and the prepared input" do
      request = SmokePostStoreRequest.new(
        input: { title: "  Hi  " },
        user: user,
        organization: nil,
        route_group: :tenant,
        action: "store",
        record: nil
      )

      expect(request.user).to eq(user)
      expect(request.route_group).to eq("tenant")
      expect(request.action).to eq("store")
      expect(request.record).to be_nil
      expect(request.input).to eq("title" => "Hi", "status" => "draft")
    end

    it "treats a non-Hash return from prepare as no change" do
      klass = Class.new(Rhino::ResourceRequest) do
        attribute :title, :string
        def prepare(_input) = nil
      end

      expect(klass.new(input: { "title" => "Kept" }).validated).to eq("title" => "Kept")
    end

    it "drops undeclared keys and keeps absent declared attributes out of the payload" do
      request = SmokePostStoreRequest.new(input: { "title" => "Hi", "content" => "nope" })

      expect(request.run).to eq(
        valid: true, errors: {}, validated: { "title" => "Hi", "status" => "draft" }
      )
    end
  end
end
