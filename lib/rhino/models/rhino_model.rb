# frozen_string_literal: true

module Rhino
  # RhinoModel -- Pre-composed base class for Rhino-powered ActiveRecord models.
  #
  # Extends +ApplicationRecord+ and includes the most commonly needed concerns
  # for Rhino's automatic REST API generation. Subclass this instead of
  # +ApplicationRecord+ to get query building, validation, column hiding,
  # and auto-scopes out of the box.
  #
  # == Quick Start
  #
  #   class Post < Rhino::RhinoModel
  #     rhino_filters :status, :user_id
  #     rhino_sorts :created_at, :title
  #     rhino_default_sort '-created_at'
  #     rhino_includes :user, :comments
  #     rhino_search :title, :content
  #
  #     # Standard Rails validations for type/format (NOT presence — use allow_nil: true)
  #     validates :title, length: { maximum: 255 }, allow_nil: true
  #     validates :status, inclusion: { in: %w[draft published] }, allow_nil: true
  #
  #     # Field permissions are controlled by the policy (PostPolicy).
  #     # See: permitted_attributes_for_create / permitted_attributes_for_update
  #
  #     belongs_to :user
  #     has_many :comments
  #   end
  #
  # == Included Concerns
  #
  #   Concern           | Purpose
  #   ------------------|-----------------------------------------------------------
  #   HasRhino         | Query builder DSL (filters, sorts, includes, etc.)
  #   HasValidation     | Format validation for request data
  #   HidableColumns    | Dynamic column hiding from API responses
  #   HasAutoScope      | Auto-discovery of ModelScopes::{Model}Scope classes
  #
  # == Optional Concerns (add manually when needed)
  #
  # These concerns are NOT included in RhinoModel because they require
  # additional database columns, gems, or relationships. Include them in
  # your model subclass as needed:
  #
  #   Concern                     | Purpose
  #   ----------------------------|---------------------------------------------------
  #   Rhino::HasAuditTrail       | Automatic change logging to +audit_logs+ table
  #   Rhino::HasUuid             | Auto-generated UUID on creation
  #   Rhino::BelongsToOrganization | Multi-tenant organization scoping
  #   Rhino::HasPermissions      | Permission checking (User model only)
  #   Discard::Model              | Soft deletes via the Discard gem
  #
  #   class Invoice < Rhino::RhinoModel
  #     include Rhino::HasAuditTrail
  #     include Rhino::BelongsToOrganization
  #     include Discard::Model
  #
  #     rhino_filters :status, :client_id
  #     rhino_sorts :created_at, :amount
  #
  #     validates :amount, numericality: { greater_than_or_equal_to: 0 }, allow_nil: true
  #     validates :client_id, numericality: { only_integer: true }, allow_nil: true
  #
  #   end
  #
  # @see Rhino::HasRhino       Query builder configuration
  # @see Rhino::HasValidation   Format validation
  # @see Rhino::HidableColumns  Column visibility control
  # @see Rhino::HasAutoScope    Automatic scope discovery
  #
  class RhinoModel < ::ActiveRecord::Base
    self.abstract_class = true

    include Rhino::HasRhino
    include Rhino::HasValidation
    include Rhino::HidableColumns
    include Rhino::HasAutoScope

    # =========================================================================
    # QUERY BUILDER -- Filtering, Sorting, Search, Includes, Fields
    # =========================================================================
    # Provided by: Rhino::HasRhino
    #
    # All class_attributes below are set via DSL methods. You can also
    # override them directly using +self.attribute_name = value+ in the
    # class body if you prefer a declarative style.
    # =========================================================================

    # @!attribute [rw] allowed_filters
    #   Filterable columns.
    #
    #   Controls which fields can be filtered via +?filter[field]=value+.
    #   Only whitelisted fields are accepted -- unlisted fields are silently ignored.
    #
    #   Set via DSL: +rhino_filters :status, :user_id, :category_id+
    #
    #   Query: +GET /api/posts?filter[status]=published&filter[user_id]=5+
    #
    #   @return [Array<String>]
    #   @example
    #     rhino_filters :status, :user_id, :category_id, :is_published
    #   @example Direct assignment
    #     self.allowed_filters = %w[status user_id category_id]
    self.allowed_filters = []

    # @!attribute [rw] allowed_scopes
    #   Client-selectable named scopes (whitelist for +?scope=+).
    #
    #   Controls which named scopes can be requested via +?scope=name+
    #   (camelCase on the wire, underscored internally). Only whitelisted
    #   scopes are accepted — unknown/unlisted names return 403.
    #
    #   Set via DSL: +rhino_scopes :active, available_for_drivers: Scopes::AvailableForDriversScope+
    #
    #   Query: +GET /api/posts?scope=availableForDrivers+
    #
    #   @return [Hash{String => Symbol, Proc, Class}]
    #   @example
    #     rhino_scopes :active, available_for_drivers: Scopes::AvailableForDriversScope
    self.allowed_scopes = {}

    # @!attribute [rw] default_rhino_scope
    #   Named scope applied automatically when no +?scope+ param is sent.
    #
    #   This is a listing convenience, not a security boundary. The default
    #   scope is always requestable by name even if it is not otherwise
    #   whitelisted via +rhino_scopes+.
    #
    #   Set via DSL: +rhino_default_scope :active+
    #
    #   @return [String, nil]
    #   @example
    #     rhino_default_scope :active
    self.default_rhino_scope = nil

    # @!attribute [rw] allowed_sorts
    #   Sortable columns.
    #
    #   Controls which fields can be used for sorting via +?sort=field+.
    #   Prefix with +-+ for descending order.
    #
    #   Set via DSL: +rhino_sorts :created_at, :title, :status+
    #
    #   Query: +GET /api/posts?sort=-created_at+ or +GET /api/posts?sort=title+
    #
    #   @return [Array<String>]
    #   @example
    #     rhino_sorts :created_at, :title, :status, :updated_at
    self.allowed_sorts = []

    # @!attribute [rw] default_sort_field
    #   Default sort expression applied when no explicit +?sort+ is given.
    #   Prefix with +-+ for descending. Set to +nil+ for database insertion order.
    #
    #   Set via DSL: +rhino_default_sort '-created_at'+
    #
    #   @return [String, nil]
    #   @example
    #     rhino_default_sort '-created_at'   # newest first
    #     rhino_default_sort 'title'          # alphabetical ascending
    self.default_sort_field = nil

    # @!attribute [rw] allowed_fields
    #   Selectable columns (sparse fieldsets).
    #
    #   Controls which columns can be selected via +?fields[model]=field1,field2+.
    #   Limits the payload size by returning only requested columns.
    #
    #   Set via DSL: +rhino_fields :id, :title, :status, :created_at+
    #
    #   Query: +GET /api/posts?fields[posts]=id,title,status+
    #
    #   @return [Array<String>]
    #   @example
    #     rhino_fields :id, :title, :status, :created_at, :user_id
    self.allowed_fields = []

    # @!attribute [rw] allowed_includes
    #   Eager-loadable relationships.
    #
    #   Controls which relationships can be included via +?include=relation+.
    #   Must correspond to defined ActiveRecord associations on the model.
    #   Supports nested includes: +'comments.user'+.
    #
    #   Set via DSL: +rhino_includes :user, :comments, :tags+
    #
    #   Query: +GET /api/posts?include=user,comments+
    #
    #   @return [Array<String>]
    #   @example
    #     rhino_includes :user, :comments, :tags, 'comments.user'
    self.allowed_includes = []

    # @!attribute [rw] allowed_search
    #   Searchable columns (full-text search across multiple fields).
    #
    #   When +?search=term+ is used, Rhino performs a case-insensitive LIKE
    #   search across all listed fields. Supports dot notation for relationships.
    #
    #   Set via DSL: +rhino_search :title, :content, 'user.name'+
    #
    #   Query: +GET /api/posts?search=rails+
    #
    #   @return [Array<String>]
    #   @example
    #     rhino_search :title, :content, :excerpt, 'user.name'
    self.allowed_search = []

    # =========================================================================
    # PAGINATION
    # =========================================================================

    # @!attribute [rw] pagination_enabled
    #   Whether pagination is enabled for the index endpoint.
    #
    #   When +true+, responses include X-* pagination headers:
    #   +X-Current-Page+, +X-Last-Page+, +X-Per-Page+, +X-Total+.
    #
    #   When +false+, the API returns all records. Clients can still
    #   request pagination via +?per_page=N+.
    #
    #   Set via DSL: +rhino_pagination_enabled true+
    #
    #   @return [Boolean]
    #   @example
    #     rhino_pagination_enabled true
    #     rhino_pagination_enabled false  # disable to return all records
    self.pagination_enabled = false

    # @!attribute [rw] rhino_per_page_count
    #   Default number of records per page.
    #
    #   Override on your model to change the default. The +?per_page+ query
    #   parameter overrides this value per-request (clamped 1-100).
    #
    #   Set via DSL: +rhino_per_page 25+
    #
    #   @return [Integer]
    #   @example
    #     rhino_per_page 25
    #     rhino_per_page 50
    self.rhino_per_page_count = 25

    # =========================================================================
    # MIDDLEWARE
    # =========================================================================

    # @!attribute [rw] rhino_model_middleware
    #   Middleware names applied to every action on this model.
    #
    #   Set via DSL: +rhino_middleware 'throttle:60,1', 'auth'+
    #
    #   @return [Array<String>]
    #   @example
    #     rhino_middleware 'throttle:60,1', 'auth'
    self.rhino_model_middleware = []

    # @!attribute [rw] rhino_middleware_actions_map
    #   Per-action middleware.
    #
    #   Keys are action names: +'index'+, +'show'+, +'store'+, +'update'+,
    #   +'destroy'+, +'trashed'+, +'restore'+, +'force_delete'+.
    #
    #   Set via DSL: +rhino_middleware_actions store: ['verified']+
    #
    #   @return [Hash{String => Array<String>}]
    #   @example
    #     rhino_middleware_actions(
    #       store: ['verified'],
    #       update: ['verified'],
    #       destroy: ['admin']
    #     )
    self.rhino_middleware_actions_map = {}

    # =========================================================================
    # ROUTE EXCLUSION
    # =========================================================================

    # @!attribute [rw] rhino_except_actions_list
    #   Actions to exclude from route registration.
    #
    #   Available actions: +'index'+, +'show'+, +'store'+, +'update'+,
    #   +'destroy'+, +'trashed'+, +'restore'+, +'force_delete'+.
    #
    #   Set via DSL: +rhino_except_actions :destroy, :force_delete+
    #
    #   @return [Array<String>]
    #   @example
    #     # Disable delete endpoints entirely
    #     rhino_except_actions :destroy, :force_delete
    #   @example Read-only API
    #     rhino_except_actions :store, :update, :destroy
    self.rhino_except_actions_list = []

    # =========================================================================
    # OWNERSHIP / MULTI-TENANCY
    # =========================================================================

    # @internal Auto-detected from belongs_to associations.
    self.rhino_owner_path = nil

    # =========================================================================
    # VALIDATION (provided by Rhino::HasValidation)
    # =========================================================================
    # Format validation uses standard ActiveModel +validates+ declarations
    # on your model (always with +allow_nil: true+).
    #
    #   validates :title, length: { maximum: 255 }, allow_nil: true
    #   validates :status, inclusion: { in: %w[draft published] }, allow_nil: true
    #
    # Field permissions (which attributes are accepted on create/update)
    # are controlled by the policy. See +permitted_attributes_for_create+
    # and +permitted_attributes_for_update+ on your policy class.
    # =========================================================================

    # Field permissions (which attributes are accepted on create/update) are
    # controlled by the policy, not the model. Implement
    # +permitted_attributes_for_create+ and +permitted_attributes_for_update+
    # on your policy class.

    # =========================================================================
    # HIDDEN COLUMNS (provided by Rhino::HidableColumns)
    # =========================================================================

    # @!attribute [rw] additional_hidden_columns
    #   Additional columns to hide from API responses (on top of base defaults).
    #
    #   Base hidden columns (always hidden): +password+, +password_digest+,
    #   +remember_token+, +created_at+, +updated_at+, +deleted_at+,
    #   +discarded_at+, +email_verified_at+.
    #
    #   For per-user column hiding, implement +hidden_attributes_for_show+ /
    #   +permitted_attributes_for_show+ on your Policy.
    #
    #   Set via DSL: +rhino_additional_hidden :api_token, :stripe_id+
    #
    #   @return [Array<String>]
    #   @example
    #     rhino_additional_hidden :api_token, :stripe_id, :internal_notes
    self.additional_hidden_columns = []

    # =========================================================================
    # SOFT DELETES (requires Discard gem)
    # =========================================================================
    # Add +include Discard::Model+ to enable soft deletes.
    # Requires a +discarded_at+ datetime column in your migration.
    #
    # When enabled, unlocks trash/restore/force-delete API endpoints.
    #
    #   class Post < Rhino::RhinoModel
    #     include Discard::Model
    #   end
    # =========================================================================

    # =========================================================================
    # AUDIT TRAIL (requires Rhino::HasAuditTrail concern)
    # =========================================================================
    # When including +Rhino::HasAuditTrail+, every create/update/delete
    # is logged to the +audit_logs+ table via ActiveRecord callbacks.
    #
    # Exclude sensitive fields from audit snapshots:
    #   rhino_audit_exclude :password, :remember_token, :api_key
    #
    # Access audit logs:
    #   post.audit_logs.order(created_at: :desc)
    #
    #   class Post < Rhino::RhinoModel
    #     include Rhino::HasAuditTrail
    #     rhino_audit_exclude :password, :secret_token
    #   end
    # =========================================================================

    # =========================================================================
    # MULTI-TENANCY (requires Rhino::BelongsToOrganization concern)
    # =========================================================================
    # When including +Rhino::BelongsToOrganization+:
    # - +organization_id+ is auto-set from the request on create
    # - A default scope filters queries by the current organization
    # - +belongs_to :organization+ is set up automatically
    #
    #   class Project < Rhino::RhinoModel
    #     include Rhino::BelongsToOrganization
    #   end
    #
    # For nested ownership (e.g. Task -> Project -> Organization),
    # the path is auto-detected from belongs_to associations.
    # =========================================================================

    # =========================================================================
    # UUID (requires Rhino::HasUuid concern)
    # =========================================================================
    # When including +Rhino::HasUuid+, a UUID is auto-generated on
    # creation if the model has a +uuid+ column.
    #
    #   class Post < Rhino::RhinoModel
    #     include Rhino::HasUuid
    #   end
    # =========================================================================

    # =========================================================================
    # PERMISSIONS (requires Rhino::HasPermissions -- User model only)
    # =========================================================================
    # When including +Rhino::HasPermissions+:
    # - +has_permission?(permission, organization)+ checks permissions
    # - +role_slug_for_validation(organization)+ resolves the role slug
    #
    # Permission format: +{slug}.{action}+ e.g. +'posts.index'+
    # Wildcards: +'*'+ (all) or +'posts.*'+ (all actions on posts)
    #
    #   class User < Rhino::RhinoModel
    #     include Rhino::HasPermissions
    #     has_many :user_roles
    #   end
    # =========================================================================
  end
end
