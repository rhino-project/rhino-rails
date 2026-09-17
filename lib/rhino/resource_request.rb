# frozen_string_literal: true

require "active_model"
require "active_support/core_ext/object/deep_dup"

module Rhino
  # Base class for per-model, per-action request classes.
  #
  # A request class owns the entire shape/format contract for ONE action of ONE
  # model. Unlike model-level validations it receives the full request context —
  # the authenticated user, the resolved organization, the matched route group,
  # the action, and (on update) the pre-update record — so a rule can branch on
  # any of them.
  #
  # Discovery is by convention: `{Model}StoreRequest` / `{Model}UpdateRequest`,
  # autoloaded from `app/requests/` (Zeitwerk autoloads every `app/*`
  # directory, so no initializer or eager_load_paths entry is required). An
  # explicit registration overrides the convention:
  #
  #   Rhino.configure do |config|
  #     config.model :tasks, "Task", store_request: "CreateTask", update_request: "EditTask"
  #   end
  #
  # Usage:
  #
  #   # app/requests/task_store_request.rb
  #   class TaskStoreRequest < Rhino::ResourceRequest
  #     attribute :title, :string
  #     attribute :status, :string
  #     attribute :project_id, :integer
  #
  #     validates :title, presence: true, length: { maximum: 255 }
  #     validates :status, inclusion: { in: %w[todo doing] }, unless: -> { user&.admin? }
  #
  #     def authorize?
  #       route_group != "public"
  #     end
  #
  #     def prepare(input)
  #       input.merge("title" => input["title"].to_s.strip)
  #     end
  #   end
  #
  # Rules are ordinary ActiveModel declarations. There is no `rules` method and
  # no `messages` method: dynamic rules use `validate :method_name` or
  # `validates ..., if: -> { ... }` with the context readers in scope, and
  # messages use the standard `message:` option / i18n.
  #
  # THE WRITE PAYLOAD IS `validated`. Only DECLARED attributes that are PRESENT
  # in the prepared input are persisted, with their cast values. A field with no
  # `attribute` declaration is silently dropped — including a field added by
  # `prepare` that no `attribute` covers. This fails closed: when a policy
  # permits `['*']`, the request class is the only field filter left.
  class ResourceRequest
    include ActiveModel::Model
    include ActiveModel::Attributes
    include ActiveModel::Validations

    # The request context. All six values are available to `authorize?`,
    # `prepare` and every validation.
    #
    # @return [Object, nil] the authenticated user, nil when unauthenticated
    attr_reader :user
    # @return [Object, nil] the resolved organization, nil outside a tenant context
    attr_reader :organization
    # @return [String, nil] the matched route's route group ("tenant", "public", ...)
    attr_reader :route_group
    # @return [String] "store" or "update"
    attr_reader :action
    # @return [Object, nil] the PRE-UPDATE record on update, nil on store
    attr_reader :record
    # @return [Hash] the prepared input, string-keyed
    attr_reader :input

    # @param input [Hash] the raw request data, AFTER the policy forbidden-field
    #   gate has run (so `prepare` can never launder a field past the policy)
    # @param user [Object, nil]
    # @param organization [Object, nil]
    # @param route_group [String, nil]
    # @param action [String] "store" or "update"
    # @param record [Object, nil]
    def initialize(input:, user: nil, organization: nil, route_group: nil, action: "store", record: nil)
      @user = user
      @organization = organization
      @route_group = route_group.nil? ? nil : route_group.to_s
      @action = action.to_s
      @record = record

      # ActiveModel::Attributes defaults must exist before anything reads or
      # writes an attribute — including a `prepare` override that touches one.
      super()

      raw = self.class.normalize_input_keys(input)
      prepared = prepare(raw.deep_dup)
      # A `prepare` that returns a non-Hash (or nil) is treated as "no change".
      @input = prepared.is_a?(Hash) ? self.class.normalize_input_keys(prepared) : raw

      assign_declared_attributes
    end

    # Override point: return false to refuse the request with a 403 whose body
    # is byte-identical to a policy denial, so `authorize?` cannot be used to
    # enumerate anything about the model.
    #
    # @return [Boolean]
    def authorize?
      true
    end

    # Override point: normalize the input before validation. Runs BEFORE
    # `authorize?`, so `authorize?` sees normalized input.
    #
    # Fields added here are SERVER-AUTHORED and are not re-checked against the
    # policy's permitted attributes — the forbidden-field gate already ran on
    # exactly what the client sent. Never copy a client value into a different
    # key here; that writes a field the policy denied.
    #
    # A return value that is not a Hash is ignored.
    #
    # @param input [Hash] string-keyed copy of the raw input
    # @return [Hash]
    def prepare(input)
      input
    end

    # Run the validations.
    #
    # @return [Hash] { valid: Boolean, errors: Hash<String, Array<String>>, validated: Hash }
    def run
      ok = valid?

      { valid: ok, errors: error_messages, validated: validated }
    end

    # The write payload: declared attribute names that are present in the
    # prepared input, mapped to their CAST values.
    #
    # @return [Hash<String, Object>]
    def validated
      attributes.select { |name, _| @input.key?(name) }
    end

    # Errors in the shape Rhino renders at 422:
    #   { "title" => ["can't be blank"], ... }
    #
    # Built exactly the way HasValidation#validate_for_action builds it, but
    # WITHOUT its "only report errors on fields the client sent" guard — on a
    # request class an error on an absent-but-required field is the point.
    #
    # @return [Hash<String, Array<String>>]
    def error_messages
      messages = {}
      errors.each do |error|
        field_name = error.attribute.to_s
        messages[field_name] ||= []
        messages[field_name] << error.message
      end
      messages
    end

    # Stringify top-level keys so `input["title"]` works regardless of whether
    # the caller handed us a Hash, a HashWithIndifferentAccess or symbol keys.
    #
    # @api private
    def self.normalize_input_keys(hash)
      return {} unless hash.is_a?(Hash)

      hash.each_with_object({}) { |(key, value), memo| memo[key.to_s] = value }
    end

    private

    # Assign ONLY declared attributes, and only those actually present in the
    # prepared input, so an absent attribute keeps its declared default rather
    # than being overwritten with nil.
    def assign_declared_attributes
      self.class.attribute_names.each do |name|
        next unless @input.key?(name)

        public_send("#{name}=", @input[name])
      end
    end
  end
end
