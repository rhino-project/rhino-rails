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
