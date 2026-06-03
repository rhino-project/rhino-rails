# frozen_string_literal: true

module Rhino
  class Configuration
    attr_accessor :models, :route_groups, :multi_tenant, :invitations, :nested, :test_framework,
                  :client_path, :mobile_path

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
      @test_framework = "rspec"
      @client_path = nil
      @mobile_path = nil
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
    def route_group(name, prefix: "", domain: nil, middleware: [], models: :all)
      normalized_domain = domain.to_s.strip
      normalized_domain = nil if normalized_domain.empty?

      @route_groups[name.to_sym] = {
        prefix: prefix.to_s,
        domain: normalized_domain,
        middleware: Array(middleware),
        models: models
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
  end
end
