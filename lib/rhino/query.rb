# frozen_string_literal: true

module Rhino
  # Reusable tenant-safe query resolver for custom controllers (dashboards,
  # reports, anything beyond CRUD). Mirrors the Laravel Rhino::query feature.
  #
  # Two ways to use it:
  #
  #   # Direct / ambient — org + user from the request context (RequestStore)
  #   Rhino.query(Task)
  #
  #   # Explicit — works in jobs/rake/tests with NO route; org scope comes from
  #   # the passed org, not the request:
  #   Rhino.for_user(user).in_organization(org).query(Task)
  #   Rhino.for_user(user).in_organization(org).run { ... }
  class << self
    # Build a tenant-scoped relation for +model_class+ using the ambient context.
    #
    # Applies the same org scoping as CRUD plus the model's default_scopes
    # (BelongsToOrganization / HasAutoScope read RequestStore at BUILD time).
    #
    # Fail closed: an org-scopable model with no org context RAISES
    # Rhino::MissingTenantContext rather than returning an unscoped relation.
    def query(model_class)
      org = Rhino::Context.organization

      # default_scope (org via RequestStore) + auto-scope are baked here at build.
      relation = model_class.all

      if Rhino::ScopesToOrganization.organization_scoped?(model_class)
        raise Rhino::MissingTenantContext, model_class.name unless org

        relation = Rhino::ScopesToOrganization.scope_to_organization(relation, model_class, org, strict: true)
      end

      relation
    end

    # Build a tenant-scoped relation and apply a whitelisted ?scope= named scope
    # on top of it. +scope_name+ is the wire name (camelCase accepted); nil falls
    # back to the model's rhino_default_scope.
    def scoped_query(model_class, scope_name = nil)
      apply_named_scope(query(model_class), model_class, scope_name)
    end

    # Begin the fluent explicit builder for +user+.
    def for_user(user)
      Rhino::PendingScopedContext.new(user: user)
    end

    # The ambient context resolver.
    def context
      Rhino::Context
    end

    # Apply a whitelisted named scope to +relation+ for +model_class+.
    # Shared by Rhino.scoped_query and PendingScopedContext#scoped_query. Uses the
    # same allowed_scopes / default_rhino_scope mechanism as the QueryBuilder.
    # @api private
    def apply_named_scope(relation, model_class, scope_name = nil)
      requested = scope_name.to_s.presence
      name = requested ? requested.underscore : model_class.try(:default_rhino_scope)
      return relation unless name

      allowed = model_class.try(:allowed_scopes) || {}
      entry = allowed[name]
      entry ||= name.to_sym if name == model_class.try(:default_rhino_scope)

      raise Rhino::ScopeNotAllowedError, (requested || name) if entry.nil?

      user = defined?(RequestStore) ? RequestStore.store[:rhino_current_user] : nil

      case entry
      when Symbol
        relation.merge(model_class.public_send(entry))
      when Proc
        entry.call(relation, user)
      else
        entry.new.apply(relation)
      end
    end
  end

  # Fluent explicit-context builder. Holds a user (and, once chained, an org) and
  # resolves queries with that context installed into RequestStore at build time.
  class PendingScopedContext
    def initialize(user:, organization: nil)
      @user = user
      @organization = organization
    end

    def in_organization(organization)
      @organization = organization
      self
    end

    # Build a fully-baked relation for +model_class+ under this explicit context.
    #
    # Because Rails default_scopes bake at BUILD time, we install the user+org into
    # RequestStore, build the relation via Rhino.query, then restore RequestStore.
    # The org+user are baked into the returned relation — no stickiness, fully
    # isolated: a later Rhino.query with no context still fails closed.
    def query(model_class)
      Rhino::Context.with(user: @user, organization: @organization) do
        Rhino.query(model_class)
      end
    end

    # Build a fully-baked, named-scoped relation under this explicit context.
    def scoped_query(model_class, scope_name = nil)
      Rhino::Context.with(user: @user, organization: @organization) do
        Rhino.scoped_query(model_class, scope_name)
      end
    end

    # Run +block+ with the explicit context installed into RequestStore. Queries
    # inside the block see the context; RequestStore is restored afterward.
    # Returns the block's value.
    def run(&block)
      Rhino::Context.with(user: @user, organization: @organization, &block)
    end
  end
end
