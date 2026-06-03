# frozen_string_literal: true

# Additive, reversible migration for group-aware auth & membership
# (GROUP_AUTH_DESIGN.md §3). Adds the nullable `route_group` column to
# user_roles (and organization_invitations when present), makes
# organization_id nullable for non-tenant group memberships, and replaces the
# user_roles unique index with one that includes route_group.
#
# Existing rows keep route_group = NULL, which is a WILDCARD (member of every
# group), so enabling enforce_group_membership never locks out existing users.
class AddGroupMembership < ActiveRecord::Migration[8.0]
  def up
    # --- user_roles -------------------------------------------------------
    add_column :user_roles, :route_group, :string unless column_exists?(:user_roles, :route_group)

    # organization_id becomes nullable (non-tenant groups have no org).
    change_column_null :user_roles, :organization_id, true

    # Replace the (user_id, organization_id) unique index with one that
    # includes role_id and route_group.
    if index_exists?(:user_roles, [:user_id, :organization_id], unique: true)
      remove_index :user_roles, column: [:user_id, :organization_id]
    end

    # A plain column index treats NULLs as distinct on SQLite/PostgreSQL, so two
    # identical wildcard memberships (NULL organization_id AND NULL route_group)
    # could coexist. Use a DB-portable expression index over
    # (user_id, COALESCE(organization_id, 0), role_id, COALESCE(route_group, ''))
    # so uniqueness holds for NULL-org / NULL-group rows too.
    unless index_exists?(:user_roles, nil, name: "index_user_roles_on_user_org_role_group")
      add_index :user_roles,
                "user_id, COALESCE(organization_id, 0), role_id, COALESCE(route_group, '')",
                unique: true, name: "index_user_roles_on_user_org_role_group"
    end

    # --- organization_invitations ----------------------------------------
    if table_exists?(:organization_invitations)
      unless column_exists?(:organization_invitations, :route_group)
        add_column :organization_invitations, :route_group, :string
      end

      change_column_null :organization_invitations, :organization_id, true
    end
  end

  def down
    if table_exists?(:organization_invitations)
      remove_column :organization_invitations, :route_group if column_exists?(:organization_invitations, :route_group)
    end

    if index_exists?(:user_roles, nil, name: "index_user_roles_on_user_org_role_group")
      remove_index :user_roles, name: "index_user_roles_on_user_org_role_group"
    end

    add_index :user_roles, [:user_id, :organization_id], unique: true unless index_exists?(:user_roles, [:user_id, :organization_id], unique: true)

    remove_column :user_roles, :route_group if column_exists?(:user_roles, :route_group)
  end
end
