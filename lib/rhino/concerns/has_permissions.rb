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
  # Wildcard support:
  #   - '*' grants access to everything
  #   - 'posts.*' grants access to all actions on posts
  #
  # Two permission sources:
  #   - users.permissions: used for non-tenant route groups (no organization context).
  #     Stored as a JSON array directly on the user model.
  #   - role.permissions (via user_roles): used for tenant route groups (organization context present).
  #     Resolved per-organization via the user_roles → role association.
  #
  # Resolution:
  #   1. When an organization is provided (tenant route group) → checks role.permissions
  #      for that specific organization via user_roles.
  #   2. When no organization is provided (non-tenant route group) → checks users.permissions
  #      directly on the user model.
  module HasPermissions
    extend ActiveSupport::Concern

    # Check if the user has a specific permission.
    #
    # @param permission [String] Permission string like 'posts.index'
    # @param organization [Object, nil] Organization to check permissions for
    # @return [Boolean]
    def has_permission?(permission, organization = nil)
      return false if permission.blank?

      if organization
        # Tenant route group: check permissions for this organization
        user_role = find_user_role(organization)

        if user_role
          # Check user_role.permissions first (per-user-org permissions on the pivot)
          ur_permissions = parse_permissions(user_role.respond_to?(:permissions) ? user_role.permissions : nil)
          if ur_permissions.present?
            return matches_permission?(permission, ur_permissions)
          end

          # Fallback to role.permissions (shared role-level permissions)
          role = user_role.respond_to?(:role) ? user_role.role : nil
          if role
            role_permissions = parse_permissions(role.respond_to?(:permissions) ? role.permissions : nil)
            return matches_permission?(permission, role_permissions) if role_permissions.present?
          end
        end

        return false
      end

      # Non-tenant route group: check users.permissions directly
      user_perms = parse_permissions(respond_to?(:permissions) ? self.permissions : nil)
      matches_permission?(permission, user_perms)
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

    def matches_permission?(permission, granted_permissions)
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
          JSON.parse(perms)
        rescue JSON::ParserError
          []
        end
      elsif perms.is_a?(Array)
        perms
      else
        []
      end
    end

    def find_user_role(organization)
      return nil unless respond_to?(:user_roles)
      return nil unless organization

      user_roles.find_by(organization_id: organization.id)
    end
  end
end
