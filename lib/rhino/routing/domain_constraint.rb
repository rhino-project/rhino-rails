# frozen_string_literal: true

module Rhino
  module Routing
    # Rails route constraint that restricts a route group's routes to a
    # specific host/domain. Mirrors Laravel's Route::domain() behavior.
    #
    # The domain pattern may be:
    #   - A literal host, e.g. "admin.example.com" — matches only that host.
    #   - A parameterized host, e.g. "{organization}.example.com" — matches that
    #     pattern and captures the "{organization}" segment. The captured value
    #     is injected into request.path_parameters so it surfaces as
    #     params[:organization] — exactly like the path-prefix ":organization"
    #     does. The controller's `before_action :resolve_organization` then reads
    #     params[:organization] (after routing has populated path parameters) to
    #     resolve the tenant, enabling subdomain multitenancy.
    #
    # Usage (in routes):
    #   constraints(Rhino::Routing::DomainConstraint.new("{organization}.example.com")) do
    #     # ... routes ...
    #   end
    class DomainConstraint
      # Matches a "{name}" placeholder in the domain pattern.
      PLACEHOLDER = /\{([a-zA-Z_][a-zA-Z0-9_]*)\}/

      attr_reader :pattern, :regexp, :param_names

      def initialize(pattern)
        @pattern = pattern.to_s
        @param_names = []
        @regexp = compile(@pattern)
      end

      # Whether this constraint carries dynamic captures (parameterized domain).
      def parameterized?
        @param_names.any?
      end

      # Rails calls this for each request when the constraint is attached to a
      # scope. Returns true iff the request host matches the compiled pattern.
      # As a side effect, for parameterized domains the captured values are
      # injected into the request's path parameters so the controller's
      # `before_action :resolve_organization` can read them as params[:organization].
      def matches?(request)
        # Hosts are case-insensitive (DNS), so normalize before matching. This
        # ensures captured values (e.g. the "{organization}" subdomain) are
        # lowercased, matching how org slugs are stored — a mixed-case host like
        # "ORG-ONE.example.com" resolves the "org-one" organization.
        host = request.host.to_s.downcase
        match = @regexp.match(host)
        return false unless match

        inject_path_parameters(request, match) if parameterized?

        true
      end

      private

      # Compile the domain pattern into an anchored regular expression.
      # Literal characters are escaped; "{name}" becomes a named capture group
      # that matches a single host label ([^.]+ — no dots).
      def compile(pattern)
        regex_source = +""
        last_index = 0

        pattern.to_s.scan(PLACEHOLDER) do
          match = Regexp.last_match
          # Escape the literal text preceding the placeholder.
          regex_source << Regexp.escape(pattern[last_index...match.begin(0)])

          name = match[1]
          @param_names << name
          regex_source << "(?<#{name}>[^.]+)"

          last_index = match.end(0)
        end

        # Escape any trailing literal text after the last placeholder.
        regex_source << Regexp.escape(pattern[last_index..] || "")

        # Anchor and make host matching case-insensitive (hosts are case-insensitive).
        Regexp.new("\\A#{regex_source}\\z", Regexp::IGNORECASE)
      end

      def inject_path_parameters(request, match)
        captures = {}
        @param_names.each do |name|
          value = match[name]
          captures[name.to_sym] = value unless value.nil?
        end
        return if captures.empty?

        existing = request.path_parameters || {}
        # Path parameters take precedence over domain captures only if already
        # explicitly present; otherwise the domain capture fills them in.
        request.path_parameters = captures.merge(existing)
      end
    end
  end
end
