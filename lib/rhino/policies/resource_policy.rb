# frozen_string_literal: true

module Rhino
  # Base policy for all Rhino resources.
  # Mirrors the Laravel ResourcePolicy exactly.
  #
  # Permission format: '{slug}.{action}' (e.g., 'posts.index', 'blogs.store')
  # Supports wildcards:
  #   - '*' grants access to everything
  #   - 'posts.*' grants access to all actions on posts
  #
  # Usage:
  #   class PostPolicy < Rhino::ResourcePolicy
  #     # Override for custom logic:
  #     def update?(user, record)
  #       super && record.user_id == user.id
  #     end
  #
  #     # Attribute permissions:
  #     def permitted_attributes_for_show(user)
  #       has_role?(user, 'admin') ? ['*'] : ['id', 'title']
  #     end
  #
  #     def hidden_attributes_for_show(user)
  #       has_role?(user, 'admin') ? [] : ['internal_notes']
  #     end
  #
  #     def permitted_attributes_for_create(user)
  #       has_role?(user, 'admin') ? ['*'] : ['title', 'content']
  #     end
  #
  #     def permitted_attributes_for_update(user)
  #       has_role?(user, 'admin') ? ['*'] : ['title', 'content']
  #     end
  #   end
  class ResourcePolicy
    attr_reader :user, :record

    def initialize(user, record)
      @user = user
      @record = record
    end

    # The resource slug used for permission checks.
    # Override in child policies, or it will be auto-resolved from config.
    def self.resource_slug
      @resource_slug
    end

    def self.resource_slug=(slug)
      @resource_slug = slug
    end

    # ------------------------------------------------------------------
    # Convention-based CRUD authorization
    # ------------------------------------------------------------------

    def index?
      check_permission("index")
    end

    alias_method :view_any?, :index?

    def show?
      check_permission("show")
    end

    alias_method :view?, :show?

    def create?
      check_permission("store")
    end

    def update?
      check_permission("update")
    end

    def destroy?
      check_permission("destroy")
    end

    alias_method :delete?, :destroy?

    # ------------------------------------------------------------------
    # Soft Delete authorization
    # ------------------------------------------------------------------

    def view_trashed?
      check_permission("trashed")
    end

    def restore?
      check_permission("restore")
    end

    def force_delete?
      check_permission("forceDelete")
    end

    # ------------------------------------------------------------------
    # Attribute Permissions
    # ------------------------------------------------------------------

    # Override to whitelist which columns are visible in API responses.
    # Return ['*'] to allow all columns (default).
    #
    # @param user [Object, nil] The authenticated user
    # @return [Array<String>]
    def permitted_attributes_for_show(user)
      ['*']
    end

    # Override to blacklist columns from API responses.
    # These are always hidden, even if listed in permitted_attributes_for_show.
    #
    # @param user [Object, nil] The authenticated user
    # @return [Array<String>]
    def hidden_attributes_for_show(user)
      []
    end

    # Override to whitelist which fields a user can submit on create.
    # Return ['*'] to allow all fields (default).
    #
    # @param user [Object, nil] The authenticated user
    # @return [Array<String>]
    def permitted_attributes_for_create(user)
      ['*']
    end

    # Override to whitelist which fields a user can submit on update.
    # Return ['*'] to allow all fields (default).
    #
    # @param user [Object, nil] The authenticated user
    # @return [Array<String>]
    def permitted_attributes_for_update(user)
      ['*']
    end

    # ------------------------------------------------------------------
    # Helpers
    # ------------------------------------------------------------------

    # Check if the user has a specific role in the current organization.
    # Convenience method for use in child policies.
    #
    # @param user [Object, nil] The authenticated user
    # @param role_slug [String, Symbol] Role slug (e.g. 'admin', 'editor')
    # @return [Boolean]
    def has_role?(user, role_slug)
      return false unless user
      return false unless user.respond_to?(:role_slug_for_validation)

      organization = current_organization
      user.role_slug_for_validation(organization) == role_slug.to_s
    end

    private

    # Check if the user has the given permission for this resource.
    def check_permission(action)
      return false unless user

      slug = resolve_resource_slug
      return false unless slug

      permission = "#{slug}.#{action}"

      if user.respond_to?(:has_permission?)
        organization = current_organization
        user.has_permission?(permission, organization)
      else
        # Fallback: if the user model doesn't implement has_permission?, allow
        true
      end
    end

    def resolve_resource_slug
      # 1. Explicit resource_slug on the policy class
      return self.class.resource_slug if self.class.resource_slug

      # 2. Auto-resolve from Rhino config
      model_class = record.is_a?(Class) ? record : record.class
      slug = Rhino.config.slug_for(model_class)

      # Cache for subsequent calls
      self.class.resource_slug = slug if slug
      slug
    end

    def current_organization
      if defined?(RequestStore)
        RequestStore.store[:rhino_organization]
      end
    end
  end
end
