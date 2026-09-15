# frozen_string_literal: true

module Rhino
  # Parses a model's computed-attribute declarations
  # (+rhino_record_computed_attributes+ / +rhino_collection_computed_attributes+)
  # and binds the arguments a client sent for <tt>?attributes[name][param]=value</tt>
  # (and <tt>?computed_attributes[name][param]=value</tt>) to the declared
  # parameters.
  #
  # Declaration forms (both may be mixed in one hash):
  #
  #   {
  #     # Legacy: anything that is not an extended spec is used as-is — a
  #     # callable is called, any other value is serialized literally.
  #     'active_users_count' => ->(scope, _user) { scope.count },
  #     'schema_version'     => 3,
  #
  #     # Extended: a hash carrying at least one of params/optional/with.
  #     'revenue' => {
  #       params: %i[from to], optional: [:to],
  #       with: ->(scope, _user, from, to = nil) { ... }
  #     }
  #   }
  #
  # Unlike named scopes, there is deliberately NO symbol or bare-list shorthand:
  # <tt>'version' => 'v3'</tt> and <tt>'tags' => %w[a b]</tt> are valid *literal*
  # value declarations today, and reinterpreting them as parameter lists would
  # silently change what a shipped model returns. A declaration is an extended
  # spec if and only if it is a hash carrying +params+, +optional+ or +with+ —
  # those three keys are reserved inside a computed-attribute declaration.
  module ComputedAttributeSpec
    # The noun every computed-attribute argument error message starts with.
    SUBJECT = "Computed attribute"

    # The keys whose presence marks a declaration hash as an extended spec.
    SPEC_KEYS = %i[params optional with].freeze

    module_function

    # Normalize a raw declaration hash into
    # <tt>name => { params:, optional:, target: }</tt>.
    #
    # +target+ is the callable (or the literal value) that produces the
    # attribute; for a legacy declaration it is the declared value itself.
    def normalize(declared)
      return {} unless declared.is_a?(Hash)

      declared.each_with_object({}) do |(name, value), out|
        out[name.to_s] = normalize_entry(value)
      end
    end

    def normalize_entry(value)
      return { params: [], optional: [], target: value } unless spec?(value)

      spec = value.symbolize_keys

      Rhino::ArgumentBinder
        .normalize_params(spec[:params], spec[:optional])
        .merge(target: spec[:with])
    end

    # Whether a declared value is an extended spec rather than a legacy
    # callable/literal declaration.
    def spec?(value)
      return false unless value.is_a?(Hash)

      SPEC_KEYS.any? { |key| value.key?(key) || value.key?(key.to_s) }
    end

    # The declared attribute names only.
    def names(declared)
      normalize(declared).keys
    end

    # Whether the attribute declares at least one parameter that the client MUST
    # supply. Such attributes are skipped — never 403'd — when no selection was
    # made (a bare <tt>GET /computed</tt>) and when a direct serialization call
    # passes no arguments for them.
    def requires_arguments?(spec)
      (Array(spec[:params]).map(&:to_s) - Array(spec[:optional]).map(&:to_s)).any?
    end

    # Whether an entry is parameterised, and therefore must be called strictly
    # with the bound arguments rather than through the tolerant arity branch a
    # parameterless declaration keeps.
    def parameterised?(spec)
      Array(spec[:params]).any?
    end

    # Bind the raw value a client sent for one attribute to positional
    # arguments, in the order the model declared them.
    #
    # Callers MUST have already checked that the attribute is declared and
    # policy-visible: the messages raised here name the attribute.
    def bind(name, spec, raw)
      Rhino::ArgumentBinder.bind(
        subject: SUBJECT,
        name: name,
        spec: spec,
        raw: raw,
        error_class: Rhino::InvalidComputedAttributeArgumentsError
      )
    end
  end
end
