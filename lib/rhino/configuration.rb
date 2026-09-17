# frozen_string_literal: true

module Rhino
  class Configuration
    attr_accessor :models, :route_groups, :multi_tenant, :invitations, :nested, :test_framework,
                  :client_path, :mobile_path
    # Global default route key: the column matched against the :id URL segment
    # on member endpoints (show/update/destroy/restore/force_delete) for every
    # model that does not declare its own +rhino_route_key+. Default nil =
    # primary key (today's behavior, fully backward compatible).
    attr_accessor :route_key
    # How many client-selectable named scopes one request may combine with the
    # bracket form (?scope[a]=&scope[b][x]=1). Each scope is an arbitrary query
    # fragment that may add joins or subqueries, so the number is capped: a
    # request over the cap is refused with 403 "Too many scopes requested".
    # Default 3 — a base scope, a window, and one more predicate.
    attr_reader :max_scopes_per_request
    attr_reader :auth
    # Explicit per-model request-class registrations, kept OUT of @models so its
    # `slug => "ClassName"` shape (read all over the library) is untouched.
    # Shape: { slug_sym => { store: "ClassName" | nil, update: "ClassName" | nil } }
    attr_reader :model_requests

    def initialize
      @models = {}
      @model_requests = {}
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
      @route_key = nil
      @max_scopes_per_request = 3
    end

    # A non-numeric or non-positive value would lock every scope out of every
    # request, so it falls back to the default instead.
    def max_scopes_per_request=(value)
      value = value.to_i if value.respond_to?(:to_i)
      @max_scopes_per_request = value.is_a?(Integer) && value.positive? ? value : 3
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
    #
    # The optional `store_request:` / `update_request:` keywords override the
    # `{Model}StoreRequest` / `{Model}UpdateRequest` naming convention for that
    # model's POST / PUT action:
    #
    #   config.model :tasks, "Task", store_request: "CreateTask", update_request: "EditTask"
    #
    # Class NAMES (strings) are stored, never constants, so a dev-mode Zeitwerk
    # reload never hands back an unloaded class. A registration that cannot be
    # constantized at request time raises Rhino::ConfigurationError rather than
    # silently skipping validation.
    def model(slug, klass_name, store_request: nil, update_request: nil)
      key = slug.to_sym
      @models[key] = klass_name.to_s

      requests = {
        store: normalize_request_class_name(store_request),
        update: normalize_request_class_name(update_request)
      }

      if requests[:store].nil? && requests[:update].nil?
        @model_requests.delete(key)
      else
        @model_requests[key] = requests
      end
    end

    # The explicitly registered request class NAME for a model slug + action,
    # or nil when the model relies on the naming convention.
    #
    # @param slug [String, Symbol, nil]
    # @param action [String, Symbol] "store" or "update"
    # @return [String, nil]
    def request_class_for(slug, action)
      return nil if slug.nil? || slug.to_s.empty?

      entry = @model_requests[slug.to_sym]
      return nil unless entry

      entry[action.to_s == "update" ? :update : :store]
    end

    # Coerce a request-class registration to a String class name. A Class is
    # accepted for convenience but stored by name (reloader safety); blank
    # values register nothing.
    def normalize_request_class_name(value)
      return nil if value.nil?

      name = value.is_a?(Class) ? value.name.to_s : value.to_s
      name.strip.empty? ? nil : name.strip
    end
    private :normalize_request_class_name

    # Register a route group with its configuration
    # Usage: config.route_group :tenant, prefix: ':organization', middleware: [Rhino::Middleware::ResolveOrganizationFromRoute], models: :all
    #
    # The optional `domain:` keyword constrains the group's routes to a specific
    # host. Two groups can then share the same `prefix:` but live on different
    # domains. A parameterized domain such as "{organization}.example.com"
    # captures the subdomain and feeds organization resolution exactly like the
    # path-prefix ":organization" does. Groups without a domain (nil/blank)
    # match any host (default, fully backward compatible).
    #
    # The optional `tenant:` keyword declares whether the group has a tenant
    # boundary. It defaults to true: Rhino.query inside the group fails closed,
    # raising Rhino::MissingTenantContext when an organization-scopable model is
    # queried with no organization resolved. Pass `tenant: false` for a group
    # that legitimately spans every organization — a back office or admin group
    # whose operators see all tenants' rows.
    def route_group(name, prefix: "", domain: nil, middleware: [], models: :all, auth: false, hooks: nil,
                    tenant: true)
      normalized_domain = domain.to_s.strip
      normalized_domain = nil if normalized_domain.empty?

      @route_groups[name.to_sym] = {
        prefix: prefix.to_s,
        domain: normalized_domain,
        middleware: Array(middleware),
        models: models,
        auth: !!auth,
        hooks: hooks,
        tenant: tenant != false
      }
    end

    # Whether the named route group has a tenant boundary, i.e. whether
    # Rhino.query must fail closed inside it. Only a group that explicitly
    # declares `tenant: false` does not; every other answer — an unknown group,
    # an untagged route, or no group at all (jobs, rake tasks, console) — is
    # true, so the resolver keeps failing closed wherever the group is not
    # provably non-tenant.
    def group_tenant?(name)
      return true if name.nil? || name.to_s.empty?

      group = @route_groups[name.to_sym]
      return true unless group

      group.fetch(:tenant, true) != false
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
