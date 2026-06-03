# frozen_string_literal: true

# Rhino Configuration
# This file is used to configure Rhino for your Rails application.
# See: https://github.com/startsoft/rhino

Rhino.configure do |config|
  # ---------------------------------------------------------------
  # Models
  # ---------------------------------------------------------------
  # Register your models here. Each model gets automatic CRUD endpoints.
  #
  # config.model :posts, 'Post'
  # config.model :comments, 'Comment'
  # config.model :users, 'User'

  # ---------------------------------------------------------------
  # Route Groups (required)
  # ---------------------------------------------------------------
  # Define how models are exposed via different URL prefixes.
  # Each group can have its own prefix, middleware, and model list.
  #
  # Reserved group names:
  #   :tenant  — enables organization scoping (invitations + nested registered here)
  #   :public  — skips authentication for routes in this group
  #
  # Models can be :all (all registered models) or an array of slugs.
  #
  # Simple non-tenant app:
  # config.route_group :default, prefix: '', middleware: [], models: :all
  #
  # Simple multi-tenant app:
  # config.route_group :tenant, prefix: ':organization', middleware: [Rhino::Middleware::ResolveOrganizationFromRoute], models: :all
  #
  # Hybrid platform (customer + driver + admin + public):
  # config.route_group :tenant, prefix: ':organization', middleware: [Rhino::Middleware::ResolveOrganizationFromRoute], models: :all
  # config.route_group :driver, prefix: 'driver', middleware: [], models: [:trips, :trucks]
  # config.route_group :admin, prefix: 'admin', middleware: [], models: :all
  # config.route_group :public, prefix: 'public', middleware: [], models: [:materials]
  #
  # The optional `domain:` keyword constrains a group to a specific host, so two
  # groups can share a prefix but live on different domains. A parameterized
  # domain captures the subdomain and feeds organization resolution just like
  # the path prefix ':organization' does. Groups without a domain match any host.
  # config.route_group :admin, prefix: '', domain: 'admin.example.com', models: :all
  # config.route_group :tenant, prefix: '', domain: '{organization}.example.com', models: :all

  # config.route_group :default, prefix: '', middleware: [], models: :all

  # ---------------------------------------------------------------
  # Multi-tenant
  # ---------------------------------------------------------------
  # config.multi_tenant = {
  #   organization_identifier_column: 'id'  # Options: 'id', 'slug', or any column
  # }

  # ---------------------------------------------------------------
  # Group-aware auth, membership & lifecycle hooks (opt-in)
  # ---------------------------------------------------------------
  # A route group may opt into group-aware auth by passing `auth: true`. The
  # full auth route set (login, logout, password/recover, password/reset,
  # register) is then registered under the group's prefix/domain, tagged with
  # the group's route_group. The legacy unprefixed /api/auth/* set always
  # remains for the default/no-group case.
  #
  # A group may also declare an optional `hooks:` class — a class responding to
  # after_login / after_logout / after_register / after_password_recover /
  # after_password_reset (subclass Rhino::AuthHooks for no-op defaults). Each
  # runs after its action succeeds and may reject by raising
  # Rhino::AuthRejected.new(message, status: 403); a rejection on a
  # token-issuing action (login/register) revokes the just-issued token.
  #
  # config.route_group :driver, prefix: 'driver', auth: true, hooks: DriverAuthHooks, models: [:trips]
  #
  # The master flag (default OFF) turns on group-membership enforcement. When
  # ON, an authenticated user must have a `user_roles` row matching the
  # request's route_group (a NULL route_group row is a wildcard matching every
  # group) and, for tenant groups, the resolved organization — otherwise 403.
  # Permissions then resolve from that matching membership row.
  # config.auth = { enforce_group_membership: false }

  # ---------------------------------------------------------------
  # Invitations
  # ---------------------------------------------------------------
  # config.invitations = {
  #   expires_days: 7,
  #   allowed_roles: nil  # nil means all roles can invite
  # }

  # ---------------------------------------------------------------
  # Nested Operations
  # ---------------------------------------------------------------
  # config.nested = {
  #   path: 'nested',
  #   max_operations: 50,
  #   allowed_models: nil  # nil = all registered models
  # }

  # ---------------------------------------------------------------
  # Test Framework
  # ---------------------------------------------------------------
  # config.test_framework = 'rspec'  # Options: 'rspec', 'minitest'
end
