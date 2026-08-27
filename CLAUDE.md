# Rhino Rails Server — Development Guide

This is **Rhino**, a Rails gem that auto-generates fully-featured REST APIs from model definitions. It is a Ruby library (not an application) — you are editing the framework itself, not a project that uses it.

## Project Structure

```
lib/rhino/
├── blueprint/                  # YAML-to-code generation system
│   ├── blueprint_parser.rb
│   ├── blueprint_validator.rb
│   ├── manifest_manager.rb
│   └── generators/             # policy_generator, test_generator, seeder_generator, factory_generator
├── commands/                   # Rake tasks (install, generate, blueprint, export_postman, invitation_link)
├── concerns/
│   ├── has_rhino.rb           # Query builder DSL (rhino_filters, rhino_sorts, etc.)
│   ├── has_validation.rb       # ActiveModel validation + cross-tenant FK scoping
│   ├── belongs_to_organization.rb # Multi-tenant data isolation via RequestStore
│   ├── has_audit_trail.rb      # Automatic change logging
│   ├── hidable_columns.rb      # Dynamic column visibility
│   ├── has_auto_scope.rb       # Auto-discover scopes by naming convention
│   ├── has_permissions.rb      # Permission checking (User model)
│   └── has_uuid.rb             # Auto-generated UUID primary keys
├── controllers/
│   ├── resources_controller.rb # Main CRUD controller — handles ALL endpoints automatically
│   ├── auth_controller.rb      # Login, logout, password recovery/reset, registration
│   └── invitations_controller.rb # Invitation CRUD + accept
├── middleware/
│   └── resolve_organization_from_route.rb  # Multi-tenant org resolution (Rack middleware)
├── models/
│   ├── rhino_model.rb         # Base model (pre-includes core concerns)
│   ├── audit_log.rb            # Polymorphic audit log
│   └── organization_invitation.rb
├── policies/
│   ├── resource_policy.rb      # Base authorization policy (Pundit)
│   └── invitation_policy.rb    # Invitation-specific authorization
├── mailers/                    # Email notifications
├── templates/                  # Code generation templates (ERB stubs)
├── configuration.rb            # DSL for model/group registration
├── query_builder.rb            # URL parameter → ActiveRecord query translation
├── routes.rb                   # Dynamic route registration
├── engine.rb                   # Rails engine
├── railtie.rb                  # Rails integration
└── version.rb                  # Gem version
spec/
├── feature/                    # HTTP endpoint behavior tests
├── unit/                       # Concern, model, policy unit tests
├── middleware/                  # Middleware tests
└── spec_helper.rb              # Test configuration
```

## Features

This library provides the following features. When modifying or extending any of them, you must understand how they interconnect:

| # | Feature | Key Files |
|---|---------|-----------|
| 1 | **Automatic CRUD Endpoints** (index, show, store, update, destroy) | `resources_controller.rb` |
| 2 | **Authentication** (login, logout, password recovery/reset, invitation registration) | `auth_controller.rb` |
| 3 | **Authorization & Policies** (Pundit, convention-based `{slug}.{action}` permissions, wildcards) | `resource_policy.rb`, `has_permissions.rb` |
| 4 | **Role-Based Access Control** (per-org roles via user_roles pivot) | `has_permissions.rb` |
| 5 | **Attribute-Level Permissions** (read/write field control per role) | `resource_policy.rb`, `hidable_columns.rb` |
| 6 | **Validation** (ActiveModel validations with `allow_nil: true` convention) | `has_validation.rb` |
| 7 | **Cross-Tenant FK Validation** (validates FK references belong to current org via DB introspection, even through indirect FK relationships) | `has_validation.rb` |
| 8 | **Filtering** (`?filter[field]=value`, AND/OR logic, type coercion) | `query_builder.rb` |
| 9 | **Sorting** (`?sort=-created_at,title`) | `query_builder.rb` |
| 10 | **Full-Text Search** (`?search=term`, dot-notation for relationships via joins) | `query_builder.rb` |
| 11 | **Pagination** (Pagy, header-based: X-Current-Page, X-Last-Page, X-Per-Page, X-Total) | `query_builder.rb`, `resources_controller.rb` |
| 12 | **Field Selection** (`?fields[posts]=id,title`) | `query_builder.rb` |
| 13 | **Eager Loading** (`?include=user,comments`, nested, Count/Exists suffixes, auth per include) | `query_builder.rb`, `resources_controller.rb` |
| 14 | **Multi-Tenancy** (org-based data isolation via RequestStore, auto-set org_id, default_scope) | `belongs_to_organization.rb`, `resolve_organization_from_route.rb` |
| 15 | **Nested Ownership Auto-Detection** (walks belongs_to chains to find org) | `resources_controller.rb`, `has_validation.rb` |
| 16 | **Route Groups** (:tenant, :public, custom groups with different middleware/auth; per-group `tenant: false` for back-office groups with no tenant boundary) | `configuration.rb` (`route_group tenant:`, `group_tenant?`), `routes.rb`, `query.rb`, `concerns/route_group_context.rb` |
| 17 | **Soft Deletes** (Discard gem, trash/restore/force-delete endpoints + permissions) | `resources_controller.rb` |
| 18 | **Audit Trail** (logs all CRUD events with old/new values, user, IP, org via RequestStore) | `has_audit_trail.rb`, `audit_log.rb` |
| 19 | **Nested Operations** (POST /nested, atomic transactions, $N.field references) | `resources_controller.rb` |
| 20 | **Invitations** (token-based, create/resend/cancel/accept, configurable expiry) | `invitations_controller.rb`, `organization_invitation.rb` |
| 21 | **Hidden Columns** (base + model-level `rhino_additional_hidden` + policy-level dynamic hiding + `as_rhino_json` for computed attributes) | `hidable_columns.rb` |
| 22 | **Auto-Scope Discovery** (naming convention: `ModelScopes::{Model}Scope`) | `has_auto_scope.rb` |
| 23 | **UUID Primary Keys** | `has_uuid.rb` |
| 24 | **Middleware Support** (global per model `rhino_middleware` + per action `rhino_middleware_actions`) | `resources_controller.rb` |
| 25 | **Action Exclusion** (`rhino_except_actions` to disable specific routes) | `routes.rb` |
| 26 | **Generator CLI** (`rhino:install`, `rhino:generate`, `rhino:blueprint`) | `commands/` |
| 27 | **Postman Export** (auto-generated collection with all endpoints) | `commands/export_postman_command.rb` |
| 28 | **Blueprint System** (YAML-to-code generation for models, policies, factories, tests, seeders) | `blueprint/` |
| 29 | **Named Scopes** (`?scope=availableForDrivers` whitelisted via `rhino_scopes` + `rhino_default_scope`; camelCase→underscored; unknown → 403; `index`/`trashed` only, `show` stays unscoped) | `query_builder.rb`, `concerns/has_rhino.rb`, `resources_controller.rb`, `scope_not_allowed_error.rb` |
| 30 | **Configurable Route Key** (`rhino_route_key :hash_id` per model or global `config.route_key`; resolves model → global → primary key; member-endpoint URL lookup only — payload FKs, nested-operation ids and audit references stay PK-based; route key is always kept in whitelisted/sparse responses) | `concerns/has_rhino.rb`, `configuration.rb`, `resources_controller.rb`, `hidable_columns.rb`, `query_builder.rb` |

## Running Tests

```bash
# Run all tests
bundle exec rspec

# Run specific test file
bundle exec rspec spec/feature/crud_spec.rb

# Run specific test by line number
bundle exec rspec spec/feature/crud_spec.rb:42

# Run only unit tests
bundle exec rspec spec/unit/

# Run only feature tests
bundle exec rspec spec/feature/

# Run with verbose output
bundle exec rspec --format documentation
```

**All tests MUST pass before any change is considered complete.**

## Development Rules

### 1. Tests Are Mandatory — No Exceptions

Every change to this library MUST include RSpec tests:

- **New feature**: Write feature tests (HTTP endpoint behavior) AND unit tests (individual concern/class logic). Cover ALL scenarios:
  - Happy path (200, 201)
  - Authorization denied (403)
  - Not found (404)
  - Validation errors (422)
  - Role-based access for EVERY permission level
  - Multi-tenant isolation (org A data must not leak to org B)
  - Edge cases (empty data, nil values, max limits)

- **Bug fix**: Write a test that reproduces the bug FIRST (it should fail), then fix the code (test should pass). This prevents regressions.

- **Refactor**: All existing tests must continue to pass. Add tests for any edge cases discovered during refactoring.

**Test coverage goal: maximum. Every public method, every endpoint, every permission boundary.**

### 2. All Existing Tests Must Pass

Before finishing any change, run the full test suite:

```bash
bundle exec rspec
```

If any test fails, fix it. Do NOT skip or disable tests. If a test is genuinely wrong (not your code), fix the test.

### 3. Update Documentation for Every Feature Change

When you add or modify a feature in this library, you MUST also update:

1. **Rhino Docs** — The Docusaurus documentation site at `../rhino-docs/docs/rails/`:
   - Find the relevant doc page and update it
   - If adding a new feature, create a new doc page or add to the appropriate existing page

2. **Rhino Skill File** — The AI reference file at `../rhino-docs/static/skills/rails/SKILL.md`:
   - Update the Feature Summary table if adding a new feature
   - Update the relevant section with new/changed behavior
   - Add Q&A entries for common questions about the change
   - Update code examples if the API changed

**The docs and skill file are the source of truth for users and AI assistants. If they're outdated, users will get wrong information.**

### 4. Maintain Consistency Across Stacks

Rhino exists in three stacks (Laravel, AdonisJS, Rails). When adding a feature to this Rails version:

- Check if the same feature should be added to `../rhino-server/` (Laravel) and `../rhino-adonis-server/` (AdonisJS)
- Keep the API surface (URL patterns, query parameters, response format, behavior) identical across stacks
- Keep the YAML blueprint format identical across stacks

### 5. Code Conventions

- Follow Ruby community conventions and RuboCop defaults
- Use `frozen_string_literal: true` in all Ruby files
- Use concerns (modules) for shared model behavior — not inheritance
- Use `allow_nil: true` on all ActiveModel validations (field presence is controlled by the policy, not the model)
- Keep `resources_controller.rb` as the single CRUD handler — do NOT create per-model controllers
- New concerns go in `lib/rhino/concerns/`, new commands in `lib/rhino/commands/`
- Configuration uses DSL methods on `Rhino.configure` block
- Use Discard gem for soft deletes (not ActiveRecord `acts_as_paranoid`)
- Use RequestStore for per-request context (current_user, organization, IP, user_agent)

### 6. Multi-Tenancy Safety

When modifying any code that touches data:
- NEVER trust client-supplied `organization_id`
- Always use the org from `RequestStore[:rhino_organization]` (set by middleware), never from params
- Test cross-tenant isolation: create data in org A, request from org B, verify 404/empty
- FK validation must scope to current org (direct or via chain)

### 7. Backward Compatibility

This is a published gem. Breaking changes require:
- Major version bump
- Migration guide in docs
- Deprecation warnings in the previous minor version when possible
