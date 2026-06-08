# frozen_string_literal: true

class CreateUserRoles < ActiveRecord::Migration[8.0]
  def change
    create_table :user_roles do |t|
      t.references :user, null: false, foreign_key: true
      # Nullable: non-tenant group memberships (e.g. :admin, :driver) have no
      # organization. Tenant-group rows still require an organization.
      t.references :organization, null: true, foreign_key: true
      t.references :role, null: false, foreign_key: true
      # Group membership scope. NULL = wildcard (member of every group), which
      # keeps existing rows valid when enforce_group_membership is enabled.
      t.string :route_group
      # Legacy per-user permission set (full list). Still honored as an allow
      # layer for backward compatibility.
      t.json :permissions, default: []
      # Layered-permission deltas applied on top of the org role layer
      # (org_role_permissions). granted = additive, denied = subtractive.
      # Deny always wins. Leave empty to inherit the role layer as-is.
      t.json :granted_permissions, default: []
      t.json :denied_permissions, default: []

      t.timestamps
    end

    # A membership is keyed by (user, organization, role, route_group). NULLs
    # are distinct under a plain index on SQLite/PostgreSQL, which would let two
    # identical NULL-org / NULL-group wildcard rows coexist. Use a DB-portable
    # expression index with COALESCE so uniqueness holds for those rows too.
    add_index :user_roles,
              "user_id, COALESCE(organization_id, 0), role_id, COALESCE(route_group, '')",
              unique: true, name: "index_user_roles_on_user_org_role_group"
  end
end
