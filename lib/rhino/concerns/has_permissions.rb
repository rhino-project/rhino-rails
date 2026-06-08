# frozen_string_literal: true

module Rhino
  # Permission checking concern for the User model.
  # Mirrors the Laravel HasPermissions trait.
  #
  # Usage:
  #   class User < ApplicationRecord
  #     include Rhino::HasPermissions
  #
  #     has_many :user_roles
  #   end
  #
  # Permission format: '{slug}.{action}' (e.g., 'posts.index', 'blogs.store')
  # Wildcard support on every layer:
  #   - '*' grants/denies everything
  #   - 'posts.*' grants/denies all actions on posts
  #
  # ── Layered resolution (organization context) ────────────────────────────
  # The effective decision for an org-scoped check is:
  #
  #     effective = (role ∪ granted) − denied        (deny always wins)
  #
  #   - role    → org_role_permissions[(organization, role)].permissions
  #               The shared "role layer" an org manages once per role.
  #   - granted → user_roles.granted_permissions  (per-user additive delta)
  #   - denied  → user_roles.denied_permissions   (per-user subtractive delta)
  #   - legacy  → user_roles.permissions          (kept in the allow set)
  #
  # Deny is checked first and overrides everything — even a role '*'. This is
  # intentionally deny-overrides (not most-specific-wins).
  #
  # Backward compatibility:
  #   - The global roles.permissions column is preserved as a FALLBACK: it is
  #     consulted only when the primary union (legacy ∪ granted ∪ org role layer)
  #     is empty — exactly the pre-layer "fall back to role.permissions when
  #     user_role.permissions is empty" behavior.
  #   - When org_role_permissions has no row and the granted/denied columns are
  #     absent, resolution reduces to the previous behavior byte-for-byte.
  #
  # Sources:
  #   1. organization provided (tenant route group) → user_roles layers above.
  #   2. no organization (non-tenant route group)   → users.permissions (with
  #      optional user-level granted/denied if those columns exist; deny wins).
  module HasPermissions
    extend ActiveSupport::Concern

    # Check if the user has a specific permission.
    #
    # @param permission [String] Permission string like 'posts.index'
    # @param organization [Object, nil] Organization to check permissions for
    # @param route_group [String, nil] Resolved route group (group enforcement only)
    # @return [Boolean]
    def has_permission?(permission, organization = nil, route_group: nil)
      return false if permission.blank?

      # Group-aware permission resolution (GROUP_AUTH_DESIGN.md §6). Only active
      # when enforce_group_membership is on. Permissions then resolve from the
      # membership row matching (route_group, organization).
      if group_membership_enforced?
        membership = Rhino::GroupMembership.matching_membership(self, route_group, organization)
        return decide_for_record(permission, membership, organization)
      end

      if organization
        # Tenant route group: layered resolution from the user_role for this org.
        return decide_for_record(permission, find_user_role(organization), organization)
      end

      # Non-tenant route group: users.permissions (+ optional user-level deltas).
      deny = parse_permissions(safe_attr(self, :denied_permissions))
      return false if matches_permission?(permission, deny)

      allow = parse_permissions(safe_attr(self, :permissions)) +
              parse_permissions(safe_attr(self, :granted_permissions))
      matches_permission?(permission, allow)
    end

    # Explain a permission decision — returns the deciding layer.
    #
    # @return [Hash] { granted: Boolean, reason: String }
    #   reason ∈ { 'denied', 'role', 'granted', 'legacy', 'user', 'default-deny' }
    def explain_permission(permission, organization = nil, route_group: nil)
      return { granted: false, reason: "default-deny" } if permission.blank?

      if group_membership_enforced?
        membership = Rhino::GroupMembership.matching_membership(self, route_group, organization)
        return decide_for_record(permission, membership, organization, explain: true)
      end

      if organization
        return decide_for_record(permission, find_user_role(organization), organization, explain: true)
      end

      deny = parse_permissions(safe_attr(self, :denied_permissions))
      return { granted: false, reason: "denied" } if matches_permission?(permission, deny)

      user = parse_permissions(safe_attr(self, :permissions))
      granted = parse_permissions(safe_attr(self, :granted_permissions))
      return { granted: true, reason: "granted" } if matches_permission?(permission, granted)
      return { granted: true, reason: "user" } if matches_permission?(permission, user)

      { granted: false, reason: "default-deny" }
    end

    # Get the role slug for validation purposes.
    #
    # @param organization [Object, nil] Organization context
    # @return [String, nil] Role slug or nil
    def role_slug_for_validation(organization = nil)
      user_role = find_user_role(organization)
      return nil unless user_role

      role = user_role.respond_to?(:role) ? user_role.role : nil
      return nil unless role

      role.respond_to?(:slug) ? role.slug : nil
    end

    private

    # Resolve a decision from a single membership/user_role record, applying
    # deny-overrides over the layered allow set.
    def decide_for_record(permission, record, organization, explain: false)
      return explain ? { granted: false, reason: "default-deny" } : false unless record

      # Deny always wins.
      deny = parse_permissions(safe_attr(record, :denied_permissions))
      if matches_permission?(permission, deny)
        return explain ? { granted: false, reason: "denied" } : false
      end

      role_id = record.respond_to?(:role_id) ? record.role_id : nil
      role_layer = org_role_permissions(organization, role_id)
      granted = parse_permissions(safe_attr(record, :granted_permissions))
      legacy = parse_permissions(safe_attr(record, :permissions))

      primary = legacy + granted + role_layer

      if primary.present?
        unless explain
          return matches_permission?(permission, primary)
        end

        return { granted: true, reason: "role" } if matches_permission?(permission, role_layer)
        return { granted: true, reason: "granted" } if matches_permission?(permission, granted)
        return { granted: true, reason: "legacy" } if matches_permission?(permission, legacy)
        return { granted: false, reason: "default-deny" }
      end

      # Legacy fallback: the global roles.permissions column, consulted only when
      # the primary union is empty (preserving pre-layer behavior).
      role = record.respond_to?(:role) ? record.role : nil
      global = role ? parse_permissions(safe_attr(role, :permissions)) : []
      allowed = matches_permission?(permission, global)

      return { granted: allowed, reason: allowed ? "role" : "default-deny" } if explain

      allowed
    end

    # Resolve the shared role-layer permissions for (organization, role) from the
    # org_role_permissions table. Memoized per instance; tolerant of the table not
    # existing (un-migrated apps) so it degrades to "no role layer".
    def org_role_permissions(organization, role_id)
      return [] unless organization && role_id

      org_id = organization.respond_to?(:id) ? organization.id : organization
      return [] if org_id.nil?

      @_org_role_permissions_cache ||= {}
      key = "#{org_id}:#{role_id}"
      return @_org_role_permissions_cache[key] if @_org_role_permissions_cache.key?(key)

      perms =
        begin
          sql = ActiveRecord::Base.sanitize_sql_array(
            ["SELECT permissions FROM org_role_permissions WHERE organization_id = ? AND role_id = ? LIMIT 1",
             org_id, role_id]
          )
          row = ActiveRecord::Base.connection.select_one(sql)
          row ? parse_permissions(row["permissions"]) : []
        rescue ActiveRecord::ActiveRecordError
          # Table absent (app has not run the new migration) → no role layer.
          []
        end

      @_org_role_permissions_cache[key] = perms
    end

    def matches_permission?(permission, granted_permissions)
      return false if permission.blank?
      return true if granted_permissions.include?(permission)
      return true if granted_permissions.include?("*")

      resource = permission.split(".").first
      return true if granted_permissions.include?("#{resource}.*")

      false
    end

    def parse_permissions(perms)
      return [] if perms.blank?

      if perms.is_a?(String)
        begin
          parsed = JSON.parse(perms)
          parsed.is_a?(Array) ? parsed : []
        rescue JSON::ParserError
          []
        end
      elsif perms.is_a?(Array)
        perms
      else
        []
      end
    end

    def safe_attr(obj, name)
      return nil unless obj.respond_to?(name)

      obj.public_send(name)
    end

    def find_user_role(organization)
      return nil unless respond_to?(:user_roles)
      return nil unless organization

      user_roles.find_by(organization_id: organization.id)
    end

    def group_membership_enforced?
      Rhino.config.respond_to?(:enforce_group_membership?) && Rhino.config.enforce_group_membership?
    end
  end
end
