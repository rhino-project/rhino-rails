# frozen_string_literal: true

module Rhino
  class Configuration
    attr_accessor :models, :route_groups, :multi_tenant, :invitations, :nested, :test_framework,
                  :client_path, :mobile_path
    attr_reader :auth

    def initialize
      @models = {}
      @route_groups = {}
      @multi_tenant = {
        organization_identifier_column: "id"
      }
      @invitations = {
        expires_days: 7,
        allowed_roles: nil
      }
      @nested = {
        path: "nested",
        max_operations: 50,
        allowed_models: nil
      }
      @auth = {
        enforce_group_membership: false
      }
      @test_framework = "rspec"
      @client_path = nil
      @mobile_path = nil
    end

    # Auth configuration accessor. Merges supplied keys over defaults so a host
    # app can set just `enforce_group_membership` without losing future keys.
    def auth=(value)
      @auth = { enforce_group_membership: false }.merge((value || {}).symbolize_keys)
    end

    # Master flag (default off). When off, behavior is byte-for-byte today's:
    # no group-membership enforcement.
    def enforce_group_membership?
      !!@auth[:enforce_group_membership]
    end

    # Register a model with its slug
    # Usage: config.model :posts, 'Post'
    def model(slug, klass_name)
      @models[slug.to_sym] = klass_name.to_s
    end

    # Register a route group with its configuration
    # Usage: config.route_group :tenant, prefix: ':organization', middleware: [Rhino::Middleware::ResolveOrganizationFromRoute], models: :all
    #
    # The optional `domain:` keyword constrains the group's routes to a specific
    # host. Two groups can then share the same `prefix:` but live on different
    # domains. A parameterized domain such as "{organization}.example.com"
    # captures the subdomain and feeds organization resolution exactly like the
    # path-prefix ":organization" does. Groups without a domain (nil/blank)
    # match any host (default, fully backward compatible).
    def route_group(name, prefix: "", domain: nil, middleware: [], models: :all, auth: false, hooks: nil)
      normalized_domain = domain.to_s.strip
      normalized_domain = nil if normalized_domain.empty?

      @route_groups[name.to_sym] = {
        prefix: prefix.to_s,
        domain: normalized_domain,
        middleware: Array(middleware),
        models: models,
        auth: !!auth,
        hooks: hooks
      }
    end

    # Resolve a model class from its slug
    def resolve_model(slug)
      klass_name = @models[slug.to_sym]
      raise ActiveRecord::RecordNotFound, "The #{slug} model does not exist" unless klass_name

      klass = klass_name.constantize
      raise ActiveRecord::RecordNotFound, "The #{slug} model does not exist" unless klass

      klass
    rescue NameError
      raise ActiveRecord::RecordNotFound, "The #{slug} model does not exist"
    end

    # Find the slug for a given model class
    def slug_for(model_class)
      class_name = model_class.is_a?(Class) ? model_class.name : model_class.class.name
      @models.each do |slug, klass_name|
        return slug if klass_name == class_name
      end
      nil
    end

    # Whether a 'tenant' route group is configured
    def has_tenant_group?
      @route_groups.key?(:tenant)
    end

    # Whether a 'public' route group is configured
    def has_public_group?
      @route_groups.key?(:public)
    end

    # Resolve the model slugs for a given route group
    def models_for_group(group_name)
      group = @route_groups[group_name.to_sym]
      return [] unless group

      group_models = group[:models]
      if group_models == :all || group_models == "*"
        @models.keys
      else
        Array(group_models).map(&:to_sym) & @models.keys
      end
    end

    # Check if a model belongs to the 'public' route group
    def public_model?(slug)
      return false unless has_public_group?

      models_for_group(:public).include?(slug.to_sym)
    end

    # Check if a specific slug belongs to a specific group
    def model_in_group?(slug, group_name)
      models_for_group(group_name).include?(slug.to_sym)
    end

    # ------------------------------------------------------------------
    # Group-aware auth helpers (see GROUP_AUTH_DESIGN.md §5/§7)
    # ------------------------------------------------------------------

    # Whether a group has per-group auth routes enabled (`auth: true`).
    # The `public` group is never auth-enabled.
    def group_auth_enabled?(group_name)
      return false if group_name.to_s == "public"

      group = @route_groups[group_name.to_sym]
      !!(group && group[:auth])
    end

    # Names of all groups (except :public) that opted into per-group auth.
    def auth_enabled_groups
      @route_groups.keys.reject { |name| name.to_s == "public" }
                   .select { |name| group_auth_enabled?(name) }
    end

    # Names of auth-enabled groups that have an empty prefix AND no domain, i.e.
    # groups whose auth routes would be byte-for-byte identical to the legacy
    # unprefixed /api/auth/* set (GROUP_AUTH_DESIGN.md §11.1). Such a group IS
    # the default/legacy auth: the legacy routes adopt its route_group/hooks
    # instead of registering a colliding second set. Two or more is a conflict
    # (raised by the route-group validator).
    def auth_enabled_legacy_groups
      auth_enabled_groups.select do |name|
        group = @route_groups[name.to_sym]
        prefix = group[:prefix].to_s
        domain = group[:domain]
        prefix.empty? && (domain.nil? || domain.to_s.strip.empty?)
      end
    end

    # Resolve the configured lifecycle-hooks class for a group, instantiated.
    # Returns nil when the group has no hooks configured. Accepts a class, a
    # class name string, or an instance.
    def hooks_for_group(group_name)
      return nil if group_name.nil?

      group = @route_groups[group_name.to_sym]
      return nil unless group

      hooks = group[:hooks]
      return nil if hooks.nil?

      case hooks
      when String
        klass = hooks.safe_constantize
        klass&.new
      when Class
        hooks.new
      else
        hooks
      end
    end

    # Whether a group is a tenant group (organization-scoped). Only the
    # reserved `:tenant` group is treated as a tenant group, matching
    # has_tenant_group?.
    def group_is_tenant?(group_name)
      group_name.to_s == "tenant"
    end
  end
end
