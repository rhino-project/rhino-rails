# frozen_string_literal: true

module Rhino
  # Raised at route-registration (boot) time when two route groups would resolve
  # to the same routes and silently shadow one another.
  class RouteGroupConflictError < StandardError; end

  module Routing
    # Validates the configured route groups before any routes are drawn and
    # raises Rhino::RouteGroupConflictError when two groups would silently shadow
    # each other.
    #
    # A route group's routing identity is the pair (host-set, prefix), per model.
    # Two groups conflict when ALL of the following hold:
    #
    #   1. Their host-sets intersect. A group with no `domain:` (nil/blank)
    #      matches EVERY host (a wildcard), so it intersects with anything. Two
    #      groups with an identical, non-empty domain pattern also intersect.
    #      Two groups with different non-empty domain patterns are disjoint.
    #   2. They share the same effective prefix (nil and "" are the same root).
    #   3. Their model sets overlap (`:all`/`"*"` expands to every registered
    #      model; explicit slug lists overlap on intersection).
    #
    # This encodes the rule: with a distinguishing domain, the prefix is optional
    # (root is fine — the host disambiguates); without a domain, the prefix is
    # the only disambiguator, so two or more overlapping groups must use distinct
    # prefixes.
    #
    # Note: this is a conservative, static check. Exotic cross-pattern overlaps
    # (e.g. a literal host that also satisfies another group's
    # "{param}.example.com") are not statically detected.
    module RouteGroupValidator
      class << self
        def validate(config)
          groups = config.route_groups
          names = groups.keys

          validate_legacy_auth_collision!(config)

          names.combination(2).each do |a_name, b_name|
            a = groups[a_name]
            b = groups[b_name]

            next unless host_sets_intersect?(a, b)
            next unless normalize_prefix(a) == normalize_prefix(b)

            shared = config.models_for_group(a_name) & config.models_for_group(b_name)
            next if shared.empty?

            raise RouteGroupConflictError, message(a_name, b_name, a, b, shared)
          end
        end

        private

        # GROUP_AUTH_DESIGN.md §11.1: at most ONE auth-enabled group may have an
        # empty prefix AND no domain — that group becomes the legacy /api/auth/*
        # set. Two or more are genuinely indistinguishable for auth routing (they
        # would all collide on the same unprefixed auth paths), so raise.
        def validate_legacy_auth_collision!(config)
          return unless config.respond_to?(:auth_enabled_legacy_groups)

          legacy = config.auth_enabled_legacy_groups
          return if legacy.length < 2

          names = legacy.map { |n| ":#{n}" }.join(", ")
          raise RouteGroupConflictError,
                "Route groups #{names} all declare auth: true with an empty prefix " \
                "and no domain, so their auth routes would be identical to the legacy " \
                "/api/auth/* set and to each other — there is no way to tell which " \
                "group an unprefixed auth request belongs to. Give all but one of " \
                "them a distinct prefix: or a domain: to disambiguate their auth routes."
        end

        def normalize_prefix(group)
          group[:prefix].to_s
        end

        # nil/blank domain means "any host".
        def normalize_domain(group)
          domain = group[:domain]
          return nil if domain.nil? || domain.to_s.strip.empty?

          domain.to_s
        end

        def host_sets_intersect?(a, b)
          da = normalize_domain(a)
          db = normalize_domain(b)

          # A wildcard host (no domain) intersects with any other host-set.
          return true if da.nil? || db.nil?

          # Two explicit domain patterns intersect only when identical.
          da == db
        end

        def message(a_name, b_name, a, b, shared)
          prefix = normalize_prefix(a)
          prefix_label = prefix.empty? ? "(root)" : "'#{prefix}'"

          da = normalize_domain(a)
          db = normalize_domain(b)
          domain_label =
            if da.nil? && db.nil?
              "no domain"
            else
              "domains [#{da || 'any'}, #{db || 'any'}]"
            end

          models = shared.map(&:to_s).join(", ")

          "Route groups :#{a_name} and :#{b_name} conflict: they share prefix " \
            "#{prefix_label} with #{domain_label} and overlapping models (#{models}), " \
            "so one would silently shadow the other. Give them distinct prefixes, or " \
            "distinguish them with different domain: values, or make their models disjoint."
        end
      end
    end
  end
end
