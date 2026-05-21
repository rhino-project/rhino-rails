# frozen_string_literal: true

module Rhino
  # Base class for auto-discovered model scopes.
  #
  # Provides access to the current user and organization from RequestStore,
  # so scopes can implement role-based or user-specific filtering.
  #
  # Usage:
  #   # app/models/scopes/project_scope.rb
  #   module Scopes
  #     class ProjectScope < Rhino::ResourceScope
  #       def apply(relation)
  #         if role == "viewer"
  #           relation.where(status: "active")
  #         else
  #           relation
  #         end
  #       end
  #     end
  #   end
  #
  # Available methods inside +apply+:
  #   - +user+          — the current authenticated user (or nil)
  #   - +organization+  — the current organization (or nil)
  #   - +role+          — shortcut for the user's role slug in the current org (or nil)
  #
  class ResourceScope
    # The current authenticated user, if any.
    # @return [User, nil]
    def user
      RequestStore.store[:rhino_current_user] if defined?(RequestStore)
    end

    # The current organization, if any.
    # @return [Organization, nil]
    def organization
      RequestStore.store[:rhino_organization] if defined?(RequestStore)
    end

    # Shortcut: the user's role slug in the current organization.
    # @return [String, nil]
    def role
      return nil unless user && organization

      if user.respond_to?(:role_slug_for_validation)
        user.role_slug_for_validation(organization)
      end
    end

    # Subclasses must implement this method.
    #
    # @param relation [ActiveRecord::Relation] the current query scope
    # @return [ActiveRecord::Relation] the modified scope
    def apply(relation)
      raise NotImplementedError, "#{self.class.name} must implement #apply(relation)"
    end
  end
end
