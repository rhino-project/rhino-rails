# frozen_string_literal: true

# The shared "role layer" for permissions: what a role can do within a given
# organization. One row per (organization, role).
#
# Resolution (see Rhino::HasPermissions):
#   effective = (org_role_permissions ∪ user_roles.granted_permissions)
#               − user_roles.denied_permissions     (deny always wins)
class OrgRolePermission < ApplicationRecord
  belongs_to :organization
  belongs_to :role

  validates :role_id, uniqueness: { scope: :organization_id }
end
