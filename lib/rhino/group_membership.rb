# frozen_string_literal: true

module Rhino
  # Group-membership enforcement (GROUP_AUTH_DESIGN.md §6).
  #
  # A membership is a `user_roles` row keyed by (user, route_group,
  # organization, role). Enforcement is gated entirely by
  # `config.auth[:enforce_group_membership]`:
  #
  #   * Off (default): no check — byte-for-byte today's behavior.
  #   * On: the user must have a matching membership row for the request's
  #     route_group (a NULL `route_group` row is a WILDCARD that matches every
  #     group) and, for tenant groups, the resolved organization.
  #
  # Membership is the COARSE gate (may you enter the group); permissions remain
  # the FINE check (resolved separately). They never merge.
  module GroupMembership
    module_function

    # Returns true when the user is a member of the given group (+ org for
    # tenant groups). Treats a NULL `route_group` row as a wildcard match.
    #
    # @param user [Object] authenticated user (must respond to :user_roles)
    # @param group_name [String, Symbol, nil] resolved route_group
    # @param organization [Object, nil] resolved organization (tenant groups)
    # @return [Boolean]
    def member?(user, group_name, organization = nil)
      return false unless user
      return true unless user.respond_to?(:user_roles)

      scope = user.user_roles

      # Only the user_roles table actually carries the route_group column when
      # the host app has migrated. Guard so unmigrated apps never crash; without
      # the column we cannot scope by group, so any row is treated as a match.
      has_group_column = scope.klass.column_names.include?("route_group")

      tenant = Rhino.config.group_is_tenant?(group_name)

      if has_group_column
        group_value = group_name.nil? ? nil : group_name.to_s
        # NULL route_group is a wildcard: matches the requested group OR is NULL.
        scope =
          if group_value.nil?
            scope
          else
            scope.where(route_group: [group_value, nil])
          end
      end

      if tenant
        return false unless organization

        scope = scope.where(organization_id: organization.id)
      end

      scope.exists?
    end

    # Find the membership row that should be the permission source for this
    # (user, group, org). Prefers an exact route_group match over a wildcard
    # (NULL) row, and (for tenant groups) requires the organization to match.
    # Returns nil when none matches.
    def matching_membership(user, group_name, organization = nil)
      return nil unless user
      return nil unless user.respond_to?(:user_roles)

      scope = user.user_roles
      has_group_column = scope.klass.column_names.include?("route_group")
      tenant = Rhino.config.group_is_tenant?(group_name)

      scope = scope.where(organization_id: organization.id) if tenant && organization

      if has_group_column && !group_name.nil?
        group_value = group_name.to_s
        # Prefer an exact match; fall back to the NULL wildcard row.
        exact = scope.where(route_group: group_value).first
        return exact if exact

        scope.where(route_group: nil).first
      elsif group_name.nil?
        # No resolved group: the permission source is undefined. Returning an
        # arbitrary scope.first could leak permissions from an unrelated
        # membership, so deny by returning nil (empty perms) instead.
        nil
      else
        # Unmigrated app (no route_group column) but a concrete group was
        # requested: fall back to the first membership row.
        scope.first
      end
    end
  end
end
