# frozen_string_literal: true

class CreateOrgRolePermissions < ActiveRecord::Migration[8.0]
  # The shared "role layer": the permission set a role has within a given
  # organization. Defining permissions here (once per org+role) means user_roles
  # rows only need to carry per-user deltas (granted_permissions /
  # denied_permissions) instead of the full permission set.
  def change
    create_table :org_role_permissions do |t|
      t.references :organization, null: false, foreign_key: true
      t.references :role, null: false, foreign_key: true
      t.json :permissions, default: []

      t.timestamps
    end

    # One row per (organization, role).
    add_index :org_role_permissions, %i[organization_id role_id], unique: true,
              name: "index_org_role_permissions_on_org_role"
  end
end
