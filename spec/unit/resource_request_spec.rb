# frozen_string_literal: true

require "spec_helper"

# Unit coverage for Rhino::ResourceRequest and the Configuration DSL that
# registers request classes explicitly. The HTTP behavior lives in
# spec/feature/request_class_validation_spec.rb.

class RrBasicRequest < Rhino::ResourceRequest
  attribute :title, :string
  attribute :estimated_hours, :integer
  attribute :published, :boolean
  attribute :status, :string, default: "draft"

  validates :title, presence: true, length: { maximum: 5 }
end

class RrPrepareRequest < Rhino::ResourceRequest
  attribute :title, :string
  attribute :source, :string

  def prepare(input)
    input.merge("title" => input["title"].to_s.strip, "source" => "api", "extra" => "dropped")
  end
end

class RrNilPrepareRequest < Rhino::ResourceRequest
  attribute :title, :string

  def prepare(_input)
    nil
  end
end

class RrStringPrepareRequest < Rhino::ResourceRequest
  attribute :title, :string

  def prepare(_input)
    "not a hash"
  end
end

class RrMutatingPrepareRequest < Rhino::ResourceRequest
  attribute :title, :string

  def prepare(input)
    input["meta"]["owner"] = "mutated"
    input
  end
end

class RrContextRequest < Rhino::ResourceRequest
  attribute :title, :string

  validate :title_must_name_the_route_group

  def authorize?
    route_group != "public"
  end

  private

  def title_must_name_the_route_group
    return if title.to_s.include?(route_group.to_s)

    errors.add(:title, "must mention #{route_group}")
  end
end

class RrEmptyRequest < Rhino::ResourceRequest; end

RSpec.describe Rhino::ResourceRequest do
  describe "the context readers" do
    it "exposes every context value it was constructed with" do
      user = User.create!(name: "U", email: "rr-#{SecureRandom.uuid}@example.com")
      org = Organization.create!(name: "O", slug: "rr-#{SecureRandom.hex(6)}")
      record = Post.create!(title: "Existing")

      request = RrBasicRequest.new(
        input: { "title" => "Hi" },
        user: user,
        organization: org,
        route_group: :tenant,
        action: :update,
        record: record
      )

      expect(request.user).to eq(user)
      expect(request.organization).to eq(org)
      expect(request.route_group).to eq("tenant") # symbols are stringified
      expect(request.action).to eq("update")
      expect(request.record).to eq(record)
    end

    it "defaults to store / no user / no organization / no record" do
      request = RrBasicRequest.new(input: {})

      expect(request.user).to be_nil
      expect(request.organization).to be_nil
      expect(request.route_group).to be_nil
      expect(request.action).to eq("store")
      expect(request.record).to be_nil
    end

    it "leaves a nil route_group nil rather than turning it into an empty string" do
      expect(RrBasicRequest.new(input: {}, route_group: nil).route_group).to be_nil
    end

    it "makes the context available to validations" do
      ok = RrContextRequest.new(input: { "title" => "tenant only" }, route_group: "tenant")
      bad = RrContextRequest.new(input: { "title" => "tenant only" }, route_group: "admin")

      expect(ok.run[:valid]).to be true
      expect(bad.run[:errors]).to eq("title" => ["must mention admin"])
    end
  end

  describe "input normalization" do
    it "accepts symbol keys" do
      expect(RrBasicRequest.new(input: { title: "Hi" }).input).to eq("title" => "Hi")
    end

    it "accepts a HashWithIndifferentAccess (what ActionController hands over)" do
      params = ActiveSupport::HashWithIndifferentAccess.new(title: "Hi")

      expect(RrBasicRequest.new(input: params).validated).to eq("title" => "Hi")
    end

    it "treats a non-Hash input as empty rather than raising" do
      expect(RrBasicRequest.new(input: nil).input).to eq({})
      expect(RrBasicRequest.new(input: "nope").input).to eq({})
    end

    it "never mutates the caller's hash" do
      original = { "title" => "Hi", "meta" => { "owner" => "client" } }

      RrMutatingPrepareRequest.new(input: original)

      expect(original).to eq("title" => "Hi", "meta" => { "owner" => "client" })
    end
  end

  describe "#prepare" do
    it "is the identity by default" do
      expect(RrBasicRequest.new(input: { "title" => "  padded  " }).input["title"])
        .to eq("  padded  ")
    end

    it "replaces the input for everything that follows" do
      request = RrPrepareRequest.new(input: { "title" => "  Hi  " })

      expect(request.input).to eq("title" => "Hi", "source" => "api", "extra" => "dropped")
    end

    it "only persists what it adds when an attribute declares it" do
      request = RrPrepareRequest.new(input: { "title" => "  Hi  " })

      expect(request.validated).to eq("title" => "Hi", "source" => "api")
      expect(request.validated).not_to have_key("extra")
    end

    it "treats a nil return as no change" do
      expect(RrNilPrepareRequest.new(input: { "title" => "Kept" }).validated)
        .to eq("title" => "Kept")
    end

    it "treats any non-Hash return as no change" do
      expect(RrStringPrepareRequest.new(input: { "title" => "Kept" }).validated)
        .to eq("title" => "Kept")
    end
  end

  describe "#authorize?" do
    it "defaults to true" do
      expect(RrBasicRequest.new(input: {}).authorize?).to be true
    end

    it "can branch on the context" do
      expect(RrContextRequest.new(input: {}, route_group: "public").authorize?).to be false
      expect(RrContextRequest.new(input: {}, route_group: "tenant").authorize?).to be true
    end
  end

  describe "#validated" do
    it "returns declared attributes that are present in the input, cast" do
      request = RrBasicRequest.new(
        input: { "title" => "Hi", "estimated_hours" => "7", "published" => "1" }
      )

      expect(request.validated).to eq(
        "title" => "Hi", "estimated_hours" => 7, "published" => true
      )
    end

    it "drops every undeclared key (Recommendation B, fails closed)" do
      request = RrBasicRequest.new(input: { "title" => "Hi", "secret" => "x", "id" => 99 })

      expect(request.validated).to eq("title" => "Hi")
    end

    it "keeps an explicitly-sent nil so a field can be cleared" do
      request = RrBasicRequest.new(input: { "title" => "Hi", "estimated_hours" => nil })

      expect(request.validated).to eq("title" => "Hi", "estimated_hours" => nil)
    end

    it "omits a declared attribute the input did not mention, even when it has a default" do
      request = RrBasicRequest.new(input: { "title" => "Hi" })

      expect(request.status).to eq("draft")        # the default is readable
      expect(request.validated).not_to have_key("status") # but is not written
    end

    it "returns {} for a request class that declares nothing" do
      expect(RrEmptyRequest.new(input: { "title" => "Hi" }).validated).to eq({})
    end
  end

  describe "#run" do
    it "returns valid/errors/validated on success" do
      expect(RrBasicRequest.new(input: { "title" => "Hi" }).run).to eq(
        valid: true, errors: {}, validated: { "title" => "Hi" }
      )
    end

    it "returns the error hash and still reports the parsed payload on failure" do
      result = RrBasicRequest.new(input: { "title" => "far too long" }).run

      expect(result[:valid]).to be false
      expect(result[:errors]).to eq("title" => ["is too long (maximum is 5 characters)"])
    end

    it "reports an error on an absent field, unlike validate_for_action" do
      # validate_for_action suppresses errors for keys the client did not send;
      # a request class must not, or a `presence: true` rule would be useless.
      expect(RrBasicRequest.new(input: {}).run[:errors]).to eq("title" => ["can't be blank"])
    end

    it "collects multiple messages for one field into an array" do
      # Named, not anonymous: ActiveModel resolves error messages through i18n,
      # which needs a class name.
      stub_const("RrMultiErrorRequest", Class.new(Rhino::ResourceRequest) do
        attribute :title, :string
        validates :title, length: { minimum: 10 }, format: { with: /\Aok/ }
      end)

      errors = RrMultiErrorRequest.new(input: { "title" => "nope" }).run[:errors]

      expect(errors["title"].length).to eq(2)
      expect(errors["title"]).to include("is too short (minimum is 10 characters)")
      expect(errors["title"]).to include("is invalid")
    end

    it "is idempotent — running twice does not double the error messages" do
      request = RrBasicRequest.new(input: { "title" => "" })

      first = request.run
      second = request.run

      expect(second[:errors]).to eq(first[:errors])
      expect(second[:errors]["title"].length).to eq(1)
    end
  end

  describe "Rhino::Configuration request-class registration" do
    before do
      Rhino.reset_configuration!
    end

    it "records store and update class names per slug" do
      Rhino.configure do |c|
        c.model :tasks, "Task", store_request: "TaskStoreRequest", update_request: "TaskUpdateRequest"
      end

      expect(Rhino.config.request_class_for(:tasks, "store")).to eq("TaskStoreRequest")
      expect(Rhino.config.request_class_for("tasks", "update")).to eq("TaskUpdateRequest")
    end

    it "leaves the @models slug => class-name shape untouched" do
      Rhino.configure { |c| c.model :tasks, "Task", store_request: "TaskStoreRequest" }

      expect(Rhino.config.models[:tasks]).to eq("Task")
    end

    it "returns nil for a slug or action with no registration" do
      Rhino.configure { |c| c.model :tasks, "Task", store_request: "TaskStoreRequest" }

      expect(Rhino.config.request_class_for(:tasks, "update")).to be_nil
      expect(Rhino.config.request_class_for(:posts, "store")).to be_nil
      expect(Rhino.config.request_class_for(nil, "store")).to be_nil
      expect(Rhino.config.request_class_for("", "store")).to be_nil
    end

    it "stores a Class by name so a Zeitwerk reload cannot hand back a stale constant" do
      Rhino.configure { |c| c.model :tasks, "Task", store_request: RrBasicRequest }

      expect(Rhino.config.request_class_for(:tasks, "store")).to eq("RrBasicRequest")
    end

    it "ignores a blank registration" do
      Rhino.configure { |c| c.model :tasks, "Task", store_request: "   ", update_request: "" }

      expect(Rhino.config.request_class_for(:tasks, "store")).to be_nil
      expect(Rhino.config.request_class_for(:tasks, "update")).to be_nil
    end

    it "clears a previous registration when the model is re-registered without one" do
      Rhino.configure { |c| c.model :tasks, "Task", store_request: "TaskStoreRequest" }
      Rhino.configure { |c| c.model :tasks, "Task" }

      expect(Rhino.config.request_class_for(:tasks, "store")).to be_nil
    end

    it "treats any action that is not \"update\" as the store slot" do
      Rhino.configure { |c| c.model :tasks, "Task", store_request: "TaskStoreRequest" }

      expect(Rhino.config.request_class_for(:tasks, :store)).to eq("TaskStoreRequest")
      expect(Rhino.config.request_class_for(:tasks, "create")).to eq("TaskStoreRequest")
    end
  end
end
