# frozen_string_literal: true

require "simplecov"
SimpleCov.start do
  add_filter "/spec/"
  add_group "Concerns", "lib/rhino/concerns"
  add_group "Controllers", "lib/rhino/controllers"
  add_group "Models", "lib/rhino/models"
  add_group "Policies", "lib/rhino/policies"
  add_group "Blueprint", "lib/rhino/blueprint"
  add_group "Commands", "lib/rhino/commands"
  track_files "lib/**/*.rb"
end

require "bundler/setup"
require "active_record"
require "active_support/all"
require "action_controller"
require "pundit"
require "discard"
require "request_store"

# Set up in-memory SQLite database
ActiveRecord::Base.establish_connection(
  adapter: "sqlite3",
  database: ":memory:"
)

# Require the gem
require "rhino"
require "rhino/configuration"
require "rhino/auth_rejected"
require "rhino/auth_hooks"
require "rhino/group_membership"
require "rhino/query_builder"
require "rhino/concerns/has_rhino"
require "rhino/concerns/has_validation"
require "rhino/concerns/has_permissions"
require "rhino/concerns/has_audit_trail"
require "rhino/concerns/belongs_to_organization"
require "rhino/concerns/hidable_columns"
require "rhino/concerns/has_uuid"
require "rhino/concerns/has_auto_scope"
require "rhino/resource_scope"
require "rhino/missing_tenant_context"
require "rhino/scopes_to_organization"
require "rhino/context"
require "rhino/query"
require "rhino/policies/resource_policy"
require "rhino/policies/invitation_policy"
require "rhino/models/audit_log"
require "rhino/models/organization_invitation"

# --------------------------------------------------------------------------
# Test Schema
# --------------------------------------------------------------------------

ActiveRecord::Schema.define do
  create_table :organizations, force: true do |t|
    t.string :name, null: false
    t.string :slug, null: false
    t.text :description
    t.timestamps
  end
  add_index :organizations, :slug, unique: true

  create_table :roles, force: true do |t|
    t.string :name, null: false
    t.string :slug, null: false
    t.text :description
    t.json :permissions, default: []
    t.timestamps
  end
  add_index :roles, :slug, unique: true

  create_table :users, force: true do |t|
    t.string :name, null: false
    t.string :email, null: false
    t.string :password_digest
    t.string :api_token
    t.string :reset_password_token
    t.datetime :reset_password_sent_at
    t.datetime :email_verified_at
    t.json :permissions
    # Optional user-level deltas for the non-tenant (no-org) resolution path.
    t.json :granted_permissions
    t.json :denied_permissions
    t.timestamps
  end
  add_index :users, :email, unique: true

  create_table :user_roles, force: true do |t|
    t.references :user, null: false, foreign_key: true
    t.references :organization, null: true, foreign_key: true
    t.references :role, null: false, foreign_key: true
    t.string :route_group
    t.json :permissions, default: []
    # Layered-permission deltas applied on top of the org role layer.
    t.json :granted_permissions, default: []
    t.json :denied_permissions, default: []
    t.timestamps
  end
  # DB-portable expression index: COALESCE collapses NULL org/group so two
  # identical wildcard memberships (NULL org AND NULL group) cannot coexist.
  # Mirrors the migration templates.
  add_index :user_roles,
            "user_id, COALESCE(organization_id, 0), role_id, COALESCE(route_group, '')",
            unique: true, name: "index_user_roles_on_user_org_role_group"

  # Shared "role layer": the permission set a role has within an organization.
  create_table :org_role_permissions, force: true do |t|
    t.references :organization, null: false, foreign_key: true
    t.references :role, null: false, foreign_key: true
    t.json :permissions, default: []
    t.timestamps
  end
  add_index :org_role_permissions, %i[organization_id role_id], unique: true

  create_table :posts, force: true do |t|
    t.references :organization, foreign_key: true
    t.references :user, foreign_key: true
    t.integer :blog_id
    t.string :title, null: false
    t.text :content
    t.boolean :is_published, default: false
    t.string :status
    t.datetime :discarded_at
    t.timestamps
  end
  add_index :posts, :discarded_at

  create_table :blogs, force: true do |t|
    t.references :organization, foreign_key: true
    t.string :title, null: false
    t.timestamps
  end

  create_table :comments, force: true do |t|
    t.references :post, foreign_key: true
    t.references :user, foreign_key: true
    t.text :body
    t.timestamps
  end

  # Dedicated tables for the configurable route key feature (route_key_spec).
  # Kept separate from posts/blogs so existing specs are untouched.
  create_table :jobs, force: true do |t|
    t.references :organization, foreign_key: true
    t.string :hash_id
    t.string :title
    t.string :status
    t.datetime :discarded_at
    t.timestamps
  end
  add_index :jobs, :hash_id, unique: true
  add_index :jobs, :discarded_at

  create_table :tasks, force: true do |t|
    t.references :organization, foreign_key: true
    t.string :hash_id
    t.string :title
    t.datetime :discarded_at
    t.timestamps
  end
  add_index :tasks, :hash_id, unique: true

  create_table :audit_logs, force: true do |t|
    t.string :auditable_type, null: false
    t.bigint :auditable_id, null: false
    t.string :action, null: false
    t.json :old_values
    t.json :new_values
    t.bigint :user_id
    t.string :user_type
    t.string :ip_address
    t.string :user_agent
    t.bigint :organization_id
    t.timestamps
  end
  add_index :audit_logs, [:auditable_type, :auditable_id]

  create_table :organization_invitations, force: true do |t|
    t.references :organization, null: true, foreign_key: true
    t.string :email, null: false
    t.references :role, foreign_key: true
    t.bigint :invited_by
    t.string :route_group
    t.string :token, null: false
    t.string :status, default: "pending"
    t.datetime :expires_at
    t.datetime :accepted_at
    t.timestamps
  end
  add_index :organization_invitations, :token, unique: true
end

# --------------------------------------------------------------------------
# Test Models
# --------------------------------------------------------------------------

class Organization < ActiveRecord::Base
  has_many :user_roles, dependent: :destroy
  has_many :users, through: :user_roles
end

class Role < ActiveRecord::Base
  has_many :user_roles, dependent: :destroy
  has_many :users, through: :user_roles

  # permissions stored as JSON array on the role
  # In test: used via user_role.role.permissions
end

class UserRole < ActiveRecord::Base
  belongs_to :user
  belongs_to :organization, optional: true
  belongs_to :role
end

class OrgRolePermission < ActiveRecord::Base
  belongs_to :organization
  belongs_to :role
end

class User < ActiveRecord::Base
  include Rhino::HasPermissions

  has_secure_password validations: false

  has_many :user_roles, dependent: :destroy
  has_many :organizations, through: :user_roles
  has_many :posts

  def authenticate(password)
    password == "password" # simplified for testing
  end
end

class Post < ActiveRecord::Base
  include Rhino::HasRhino
  include Rhino::HasValidation
  include Rhino::HidableColumns
  include Rhino::HasAutoScope
  include Discard::Model

  belongs_to :organization, optional: true
  belongs_to :user, optional: true
  belongs_to :blog, optional: true
  has_many :comments

  rhino_filters :title, :status, :is_published, :user_id
  rhino_sorts :title, :created_at, :status
  rhino_default_sort "-created_at"
  rhino_fields :id, :title, :content, :status, :is_published, :created_at
  rhino_includes :user, :comments
  rhino_search :title, :content

  validates :title, length: { maximum: 255 }, allow_nil: true
  validates :status, length: { maximum: 50 }, allow_nil: true
  validates :is_published, inclusion: { in: [true, false] }, allow_nil: true
end

class Blog < ActiveRecord::Base
  include Rhino::HasRhino
  include Rhino::HasValidation
  include Rhino::HidableColumns

  belongs_to :organization, optional: true
  has_many :posts

  rhino_search :title
end

class Comment < ActiveRecord::Base
  belongs_to :post
  belongs_to :user, optional: true
end

# Route-keyed model: member endpoints match :id against hash_id.
class Job < ActiveRecord::Base
  include Rhino::HasRhino
  include Rhino::HasValidation
  include Rhino::HidableColumns
  include Rhino::HasAutoScope
  include Discard::Model

  belongs_to :organization, optional: true

  rhino_route_key :hash_id
  rhino_filters :status
  rhino_sorts :title, :created_at
  rhino_fields :id, :title, :status
  rhino_search :title

  validates :title, length: { maximum: 255 }, allow_nil: true
end

# No model-level route key: used to exercise the global Rhino.config.route_key
# fallback and the untouched default (primary key) path.
class Task < ActiveRecord::Base
  include Rhino::HasRhino
  include Rhino::HasValidation
  include Rhino::HidableColumns
  include Discard::Model

  belongs_to :organization, optional: true

  rhino_fields :id, :title
end

# --------------------------------------------------------------------------
# Test Policies
# --------------------------------------------------------------------------

class PostPolicy < Rhino::ResourcePolicy
  self.resource_slug = "posts"

  def permitted_attributes_for_create(user)
    if has_role?(user, 'admin')
      ['*']
    else
      ['title', 'content']
    end
  end

  def permitted_attributes_for_update(user)
    if has_role?(user, 'admin')
      ['*']
    else
      ['title', 'content']
    end
  end
end

class BlogPolicy < Rhino::ResourcePolicy
  self.resource_slug = "blogs"
end

# --------------------------------------------------------------------------
# RSpec Config
# --------------------------------------------------------------------------

# Ensure Rails.logger is available for tests that need it
unless defined?(Rails) && Rails.respond_to?(:logger)
  unless defined?(Rails)
    module Rails; end
  end
  require "logger"
  Rails.define_singleton_method(:logger) { Logger.new(File::NULL) } unless Rails.respond_to?(:logger)
end

RSpec.configure do |config|
  config.expect_with :rspec do |expectations|
    expectations.include_chain_clauses_in_custom_matcher_descriptions = true
  end

  config.mock_with :rspec do |mocks|
    mocks.verify_partial_doubles = true
  end

  config.shared_context_metadata_behavior = :apply_to_host_groups
  config.order = :random

  # Reset Rhino configuration and RequestStore between tests
  config.before(:each) do
    if defined?(RequestStore)
      RequestStore.store[:rhino_current_user] = nil
      RequestStore.store[:rhino_organization] = nil
      RequestStore.store[:rhino_route_group] = nil
    end

    Rhino.reset_configuration!
    Rhino.configure do |c|
      c.model :posts, "Post"
      c.model :blogs, "Blog"
      c.route_group :default, prefix: "", middleware: [], models: :all
    end
  end

  # Clean up database between tests
  config.around(:each) do |example|
    ActiveRecord::Base.transaction do
      example.run
      raise ActiveRecord::Rollback
    end
  end
end
