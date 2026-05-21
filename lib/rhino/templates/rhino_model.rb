# frozen_string_literal: true

# Application-level RhinoModel base class.
#
# This file was published from the rhino gem. You can customise it
# to add concerns or configuration that apply to ALL your Rhino models.
#
# Published with:  rails rhino:install --publish-model
#
# To use:
#   class Post < RhinoModel
#     # ...
#   end
#
# The parent class already includes:
#   - Rhino::HasRhino, Rhino::HasValidation,
#     Rhino::HidableColumns, Rhino::HasAutoScope
#
# Add your own concerns or override defaults below.
class RhinoModel < Rhino::RhinoModel
  self.abstract_class = true

  #
  # Add application-wide concerns here. For example:
  #
  # include Rhino::HasAuditTrail
  # include Rhino::HasUuid
  # include Rhino::BelongsToOrganization

  # -----------------------------------------------------------------
  # Validation
  # -----------------------------------------------------------------
  #
  # Use standard ActiveModel validations for type/format constraints.
  # All validators should use `allow_nil: true` — presence is controlled
  # by store/update rules below.
  #
  # validates :title, length: { maximum: 255 }, allow_nil: true
  # validates :content, length: { maximum: 10_000 }, allow_nil: true
  # validates :status, inclusion: { in: %w[draft published archived] }, allow_nil: true
  #
  # -----------------------------------------------------------------
  # Store / Update rules (field allowlist + presence modifiers)
  # -----------------------------------------------------------------
  #
  # Field permissions (which fields each role can create/update) are
  # controlled by the policy, not the model. See:
  #   app/policies/<model_name>_policy.rb
  #
  # Example policy methods:
  #   def permitted_attributes_for_create(user)
  #     has_role?(user, 'admin') ? ['*'] : ['title', 'content']
  #   end
  #   def permitted_attributes_for_update(user)
  #     has_role?(user, 'admin') ? ['*'] : ['title', 'content']
  #   end

  # -----------------------------------------------------------------
  # Query Builder — Filtering, Sorting, Search, Includes, Fields
  # -----------------------------------------------------------------
  #
  # rhino_filters :status, :user_id, :category_id
  # rhino_sorts   :created_at, :title, :updated_at
  # self.default_sort_field = '-created_at'
  # rhino_fields  :id, :title, :status, :created_at
  # rhino_includes :user, :comments, :tags
  # rhino_search  :title, :content, :excerpt

  # -----------------------------------------------------------------
  # Pagination
  # -----------------------------------------------------------------
  #
  # self.pagination_enabled = true
  # self.rhino_per_page_count = 25

  # -----------------------------------------------------------------
  # Middleware
  # -----------------------------------------------------------------
  #
  # self.rhino_model_middleware = ['throttle:60,1']
  #
  # self.rhino_middleware_actions_map = {
  #   'store'   => ['verified'],
  #   'update'  => ['verified'],
  #   'destroy' => ['admin'],
  # }

  # -----------------------------------------------------------------
  # Route Exclusion
  # -----------------------------------------------------------------
  #
  # # Disable delete endpoints entirely:
  # self.rhino_except_actions_list = ['destroy', 'force_delete']
  #
  # # Read-only API:
  # self.rhino_except_actions_list = ['store', 'update', 'destroy']

  # -----------------------------------------------------------------
  # Hidden Columns
  # -----------------------------------------------------------------
  #
  # self.additional_hidden_columns = ['api_token', 'stripe_id', 'internal_notes']

end
