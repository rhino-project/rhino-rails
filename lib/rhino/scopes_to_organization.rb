# frozen_string_literal: true

module Rhino
  # Pure organization-scoping logic, extracted from ResourcesController so it can
  # be reused by the custom-query resolver (Rhino.query / Rhino.for_user...).
  #
  # Every method takes a RELATION and RETURNS a scoped relation — it never mutates
  # a QueryBuilder's @scope. The scoping order MUST match the controller exactly:
  #   1. Organization-is-self (the model IS the Organization)
  #   2. for_organization (scopeForOrganization)
  #   3. organization_id column
  #   4. auto-detected belongs_to relationship path (incl. nested, e.g. post.blog)
  module ScopesToOrganization
    # Cache for auto-detected organization paths (survives across calls, keyed by
    # model class name). Mirrors the controller's @@organization_path_cache.
    @organization_path_cache = {}

    module_function

    # Apply organization scoping to +relation+ for +model_class+, returning the
    # scoped relation. Behavior-equivalent to the controller's
    # apply_organization_scope, but returning instead of mutating a builder.
    def scope_to_organization(relation, model_class, organization, strict: false)
      return relation unless organization

      # When the resource IS the Organization model
      if organization.class == model_class
        return relation.where(
          model_class.primary_key => organization.send(model_class.primary_key)
        )
      end

      # Check for scopeForOrganization
      if model_class.respond_to?(:for_organization)
        return model_class.for_organization(organization)
      end

      # Check for organization_id column
      if model_class.column_names.include?("organization_id")
        return relation.where(organization_id: organization.id)
      end

      # Auto-detect from belongs_to relationships
      detected_path = discover_organization_path(model_class)
      if detected_path.present?
        return scope_through_relationship(relation, model_class, organization, detected_path, strict: strict)
      end

      # No mechanism could be applied. In strict mode (the resolver) a model that
      # reached here after being classified organization_scoped? must NOT return
      # unscoped — fail closed instead of leaking across tenants.
      raise Rhino::MissingTenantContext, model_class.name if strict && organization_scoped?(model_class)

      relation
    end

    # Whether +model_class+ has any organization-scoping mechanism at all. Used by
    # the resolver to decide whether missing org context must fail closed. On an
    # unexpected classification error we fail CLOSED (treat as scopable) so the
    # resolver raises rather than silently returning unscoped rows.
    def organization_scoped?(model_class)
      return true if model_class.respond_to?(:for_organization)
      return true if model_class.column_names.include?("organization_id")

      discover_organization_path(model_class).present?
    rescue StandardError
      true
    end

    def scope_through_relationship(relation, model_class, organization, relationship_path, strict: false)
      if relationship_path.include?(".")
        # Nested path: 'post.blog' -> joins(post: :blog).where(organizations: { id: org.id })
        parts = relationship_path.split(".")
        join_chain = parts.reverse.inject(:organization) { |inner, outer| { outer.to_sym => inner } }

        relation.joins(join_chain.is_a?(Symbol) ? join_chain : parts.first.to_sym => join_chain)
                .where(organizations: { id: organization.id })
      else
        # Single relationship
        assoc = model_class.reflect_on_association(relationship_path.to_sym)
        if assoc.nil?
          # Classified scopable but the association vanished — fail closed for the
          # resolver; stay lenient for the controller's legacy path.
          raise Rhino::MissingTenantContext, model_class.name if strict

          return relation
        end

        if assoc.klass.column_names.include?("organization_id")
          relation.joins(relationship_path.to_sym)
                  .where(assoc.klass.table_name => { organization_id: organization.id })
        elsif strict
          # Path leads somewhere without an organization_id column, so no filter
          # can be applied — fail closed rather than return every tenant's rows.
          raise Rhino::MissingTenantContext, model_class.name
        else
          relation
        end
      end
    end

    # Recursively discover the relationship path from a model to Organization by
    # introspecting BelongsTo associations. Returns dot-notation path or nil.
    # Results are cached per model class to avoid repeated reflection.
    def discover_organization_path(klass, visited = [], max_depth = 3)
      if @organization_path_cache.key?(klass.name)
        return @organization_path_cache[klass.name]
      end

      result = _discover_organization_path_recursive(klass, visited, max_depth)
      # Only cache a positive result. Caching a transient nil (associations/tables
      # not yet resolvable under Zeitwerk lazy-loading) would permanently
      # misclassify a genuinely org-scoped model as global — a fail-open leak.
      # Mirrors HasAutoScope's non-nil caching.
      @organization_path_cache[klass.name] = result if result
      result
    end

    def _discover_organization_path_recursive(klass, visited, max_depth)
      return nil if max_depth <= 0 || visited.include?(klass.name)

      visited = visited + [klass.name]

      begin
        associations = klass.reflect_on_all_associations(:belongs_to)
      rescue StandardError
        return nil
      end

      matching_paths = []

      associations.each do |assoc|
        begin
          related_class = assoc.klass
        rescue StandardError
          next
        end

        # Direct match: related model IS Organization
        if related_class.name == "Organization"
          matching_paths << assoc.name.to_s
          next
        end

        # Related model has organization_id column
        begin
          if related_class.column_names.include?("organization_id")
            matching_paths << assoc.name.to_s
            next
          end
        rescue StandardError
          # Table may not exist yet
        end

        # Related model includes BelongsToOrganization concern
        if defined?(Rhino::BelongsToOrganization) && related_class.include?(Rhino::BelongsToOrganization)
          matching_paths << assoc.name.to_s
          next
        end

        # Recurse into related model's BelongsTo associations
        sub_path = _discover_organization_path_recursive(related_class, visited, max_depth - 1)
        if sub_path.present?
          matching_paths << "#{assoc.name}.#{sub_path}"
        end
      end

      return nil if matching_paths.empty?

      if matching_paths.length > 1
        Rails.logger&.debug(
          "Rhino: Model #{klass.name} has multiple BelongsTo paths to Organization. " \
          "Using '#{matching_paths[0]}'. " \
          "Paths found: #{matching_paths.inspect}"
        )
      end

      matching_paths[0]
    end
  end
end
