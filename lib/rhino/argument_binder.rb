# frozen_string_literal: true

module Rhino
  # Binds the arguments a client sent in the bracket query form
  # (<tt>?scope[name][param]=value</tt>, <tt>?attributes[name][param]=value</tt>)
  # to the parameters a model declared, in declared order.
  #
  # The algorithm is shared by named scopes and computed attributes so the two
  # features cannot drift. Everything that differs between them is passed in:
  #
  # * +subject+ is the noun used in every error message ("Scope",
  #   "Computed attribute"), so each feature keeps its own wording;
  # * +error_class+ is the exception raised, so each feature keeps its own
  #   controller +rescue_from+;
  # * +underscore_keys+ reproduces the scope binder's wire-name translation.
  #   Computed attributes match parameter names verbatim, exactly as Laravel and
  #   NestJS do, so they leave it off.
  #
  # Nothing here decides whether a name may be used: callers MUST run the
  # declared-check and the policy-check BEFORE binding, so an argument error can
  # only ever be seen for a name the caller was already allowed to use.
  module ArgumentBinder
    module_function

    # Clean a declared parameter list: stringify the names, and drop any
    # +optional+ entry that is not actually a declared parameter.
    def normalize_params(params, optional = [])
      params = Array(params).map(&:to_s)

      { params: params, optional: Array(optional).map(&:to_s) & params }
    end

    # Bind the raw value a client sent for one name to positional arguments,
    # in the order the model declared them.
    #
    # +raw+ is whatever the query string produced for the bracket key: nil or ""
    # (no arguments), a scalar (the single parameter), or a hash of parameter
    # name => value.
    def bind(subject:, name:, spec:, raw:, error_class:, underscore_keys: false)
      params = Array(spec[:params]).map(&:to_s)
      optional = Array(spec[:optional]).map(&:to_s)

      given = normalize_raw_arguments(
        subject: subject, name: name, params: params, raw: raw,
        error_class: error_class, underscore_keys: underscore_keys
      )

      given.each_key do |key|
        unless params.include?(key)
          raise error_class, "#{subject} '#{name}' does not accept parameter '#{key}'"
        end
      end

      args = params.map do |param|
        if given.key?(param)
          coerce(given[param])
        elsif optional.include?(param)
          nil
        else
          raise error_class, "#{subject} '#{name}' requires parameter '#{param}'"
        end
      end

      # Drop trailing nils so an omitted optional parameter falls back to the
      # default in the callable's own signature.
      #
      # NOTE: `args.empty?` rather than `args.any?` — Array#any? without a block
      # is false for [nil], so the old form skipped the drop entirely when EVERY
      # argument was nil (an all-optional declaration with nothing sent), passing
      # [nil] where Laravel and NestJS pass []. Every other case is unchanged.
      args.pop until args.empty? || !args.last.nil?
      args
    end

    # Turn the raw query-string value into a parameter name => value hash.
    def normalize_raw_arguments(subject:, name:, params:, raw:, error_class:, underscore_keys: false)
      # ?scope[archived]= (or a bare ?scope[archived]): no arguments. A name
      # with required parameters still fails, in bind, naming them.
      return {} if raw.nil? || raw == ""

      raw = raw.to_unsafe_h if raw.respond_to?(:to_unsafe_h)

      if raw.is_a?(Array)
        # A positional list (scope[between][]=a) names nothing.
        raise error_class, "#{subject} '#{name}' requires named parameters"
      end

      unless raw.is_a?(Hash)
        raise error_class, "#{subject} '#{name}' does not accept arguments" if params.empty?

        # A bare value binds to the single declared parameter. Two parameters can
        # never be guessed at from one value.
        if params.length > 1
          raise error_class, "#{subject} '#{name}' requires named parameters"
        end

        return { params.first => raw }
      end

      raise error_class, "#{subject} '#{name}' does not accept arguments" if params.empty?

      raw.each_with_object({}) do |(key, value), out|
        unless value.is_a?(String) || value.is_a?(Numeric) || value.is_a?(TrueClass) ||
               value.is_a?(FalseClass) || value.nil?
          raise error_class, "#{subject} '#{name}' requires named parameters"
        end

        key = key.to_s
        out[underscore_keys ? key.underscore : key] = value
      end
    end

    # Query-string values always arrive as strings; hand callables real booleans
    # so a check cannot be fooled by the string "false".
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
