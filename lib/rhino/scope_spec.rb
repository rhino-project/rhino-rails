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
        params = Array(spec[:params]).map(&:to_s)
        optional = Array(spec[:optional]).map(&:to_s) & params

        { target: spec[:with] || name.to_sym, params: params, optional: optional }
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
      params = spec[:params]
      given = normalize_raw_arguments(name, params, raw)

      given.each_key do |key|
        unless params.include?(key)
          raise Rhino::InvalidScopeArgumentsError, "Scope '#{name}' does not accept parameter '#{key}'"
        end
      end

      args = params.map do |param|
        if given.key?(param)
          coerce(given[param])
        elsif spec[:optional].include?(param)
          nil
        else
          raise Rhino::InvalidScopeArgumentsError, "Scope '#{name}' requires parameter '#{param}'"
        end
      end

      # Drop trailing nils so an omitted optional parameter falls back to the
      # default in the scope's own signature.
      args.pop while args.any? && args.last.nil?
      args
    end

    def normalize_raw_arguments(name, params, raw)
      # ?scope[archived]= (or a bare ?scope[archived]): no arguments. A scope
      # with required parameters still fails, in bind, naming them.
      return {} if raw.nil? || raw == ""

      raw = raw.to_unsafe_h if raw.respond_to?(:to_unsafe_h)

      if raw.is_a?(Array)
        # A positional list (scope[between][]=a) names nothing.
        raise Rhino::InvalidScopeArgumentsError, "Scope '#{name}' requires named parameters"
      end

      unless raw.is_a?(Hash)
        raise Rhino::InvalidScopeArgumentsError, "Scope '#{name}' does not accept arguments" if params.empty?

        # A bare value binds to the single declared parameter. Two parameters can
        # never be guessed at from one value.
        if params.length > 1
          raise Rhino::InvalidScopeArgumentsError, "Scope '#{name}' requires named parameters"
        end

        return { params.first => raw }
      end

      raise Rhino::InvalidScopeArgumentsError, "Scope '#{name}' does not accept arguments" if params.empty?

      raw.each_with_object({}) do |(key, value), out|
        unless value.is_a?(String) || value.is_a?(Numeric) || value.is_a?(TrueClass) ||
               value.is_a?(FalseClass) || value.nil?
          raise Rhino::InvalidScopeArgumentsError, "Scope '#{name}' requires named parameters"
        end

        out[key.to_s.underscore] = value
      end
    end

    # Query-string values always arrive as strings; hand scope bodies real
    # booleans so a check cannot be fooled by the string "false".
    def coerce(value)
      return value unless value.is_a?(String)

      case value.downcase
      when "true" then true
      when "false" then false
      else value
      end
    end
  end
end
