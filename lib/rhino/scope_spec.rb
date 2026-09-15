# frozen_string_literal: true

module Rhino
  # Parses the +rhino_scopes+ declaration and binds the arguments a client sent
  # for <tt>?scope[name][param]=value</tt> to the scope's parameters.
  #
  # Declaration forms (all may be mixed in one call):
  #
  #   rhino_scopes :archived,                                   # no parameters
  #                since: { params: [:date] },                  # one parameter
  #                window: { params: %i[min max] },             # two, both required
  #                titled: { params: %i[title status], optional: [:status] },
  #                mine:   ->(relation, user) { ... },          # legacy proc
  #                fresh:  Scopes::FreshScope                    # legacy scope class
  #
  # A scope with no declared parameters never receives arguments: sending any
  # is a 403, so a scope written without client input can never be handed some.
  module ScopeSpec
    # The noun every scope-argument error message starts with. The binding
    # algorithm itself lives in Rhino::ArgumentBinder and is shared with
    # computed attributes; this constant is what keeps the scope wording its own.
    SUBJECT = "Scope"

    module_function

    # Normalize a raw +allowed_scopes+ hash into
    # <tt>name => { target:, params:, optional: }</tt>.
    def normalize(declared)
      (declared || {}).each_with_object({}) do |(name, value), out|
        key = name.to_s
        out[key] = normalize_entry(key, value)
      end
    end

    def normalize_entry(name, value)
      if value.is_a?(Hash) || value.is_a?(ActiveSupport::HashWithIndifferentAccess)
        spec = value.symbolize_keys

        Rhino::ArgumentBinder
          .normalize_params(spec[:params], spec[:optional])
          .merge(target: spec[:with] || name.to_sym)
      else
        { target: value, params: [], optional: [] }
      end
    end

    # Bind the raw value a client sent for one scope to positional arguments,
    # in the order the model declared them.
    #
    # +raw+ is whatever the query string produced for <tt>scope[<name>]</tt>:
    # nil or "" (no arguments), a scalar (the single parameter), or a hash of
    # parameter name => value.
    #
    # Raises Rhino::InvalidScopeArgumentsError.
    def bind(name, spec, raw)
      Rhino::ArgumentBinder.bind(
        subject: SUBJECT,
        name: name,
        spec: spec,
        raw: raw,
        error_class: Rhino::InvalidScopeArgumentsError,
        # Scope wire names are underscored (?scope[availableForDrivers]), and so
        # are their parameter names.
        underscore_keys: true
      )
    end

    def normalize_raw_arguments(name, params, raw)
      Rhino::ArgumentBinder.normalize_raw_arguments(
        subject: SUBJECT,
        name: name,
        params: params,
        raw: raw,
        error_class: Rhino::InvalidScopeArgumentsError,
        underscore_keys: true
      )
    end

    # Query-string values always arrive as strings; hand scope bodies real
    # booleans so a check cannot be fooled by the string "false".
    def coerce(value)
      Rhino::ArgumentBinder.coerce(value)
    end
  end
end
