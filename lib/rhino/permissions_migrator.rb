# frozen_string_literal: true

require "json"

module Rhino
  # Lift per-user permissions into the shared org role layer.
  #
  # For each (organization, role) group, the literal intersection of every user's
  # `user_roles.permissions` becomes the `org_role_permissions` row (the shared
  # role layer). Each user's row is then reduced to only its delta
  # (`granted_permissions = permissions − roleLayer`) and its legacy `permissions`
  # is cleared. Effective permissions are preserved exactly (the intersection is a
  # subset of every user's set, so nothing is gained or lost).
  #
  # Safe & idempotent:
  #   - Dry-run by default; pass apply: true to write.
  #   - Groups that already have an org_role_permissions row are skipped.
  #   - After a run the legacy permissions are empty, so a second run is a no-op.
  #   - Non-tenant (NULL organization) rows are left untouched.
  class PermissionsMigrator
    Result = Struct.new(:groups_migrated, :rows_reduced, :skipped_existing, :lines, keyword_init: true)

    def self.call(apply: false)
      new.call(apply: apply)
    end

    def call(apply: false)
      conn = ActiveRecord::Base.connection
      unless conn.data_source_exists?("user_roles") && conn.data_source_exists?("org_role_permissions")
        raise "Required tables (user_roles, org_role_permissions) are missing. Run migrations first."
      end

      groups = conn.select_all(
        "SELECT DISTINCT organization_id, role_id FROM user_roles " \
        "WHERE organization_id IS NOT NULL AND role_id IS NOT NULL"
      )

      groups_migrated = 0
      rows_reduced = 0
      skipped_existing = 0
      lines = []

      groups.each do |g|
        org_id = g["organization_id"]
        role_id = g["role_id"]

        rows = conn.select_all(
          ActiveRecord::Base.sanitize_sql_array(
            ["SELECT id, permissions, granted_permissions FROM user_roles " \
             "WHERE organization_id = ? AND role_id = ?", org_id, role_id]
          )
        ).to_a

        with_legacy = rows.select { |r| decode(r["permissions"]).any? }
        next if with_legacy.empty?

        existing = conn.select_value(
          ActiveRecord::Base.sanitize_sql_array(
            ["SELECT 1 FROM org_role_permissions WHERE organization_id = ? AND role_id = ? LIMIT 1",
             org_id, role_id]
          )
        )
        if existing
          skipped_existing += 1
          next
        end

        sets = with_legacy.map { |r| decode(r["permissions"]) }
        role_layer = sets.reduce { |acc, s| acc & s } || []
        lines << "org=#{org_id} role=#{role_id} → role layer [#{role_layer.join(', ')}] (#{with_legacy.size} user rows)"

        if apply
          now = Time.now.utc
          conn.execute(
            ActiveRecord::Base.sanitize_sql_array(
              ["INSERT INTO org_role_permissions (organization_id, role_id, permissions, created_at, updated_at) " \
               "VALUES (?, ?, ?, ?, ?)", org_id, role_id, JSON.generate(role_layer), now, now]
            )
          )

          with_legacy.each do |r|
            legacy = decode(r["permissions"])
            grants = decode(r["granted_permissions"])
            delta = ((legacy - role_layer) + grants).uniq

            conn.execute(
              ActiveRecord::Base.sanitize_sql_array(
                ["UPDATE user_roles SET permissions = ?, granted_permissions = ?, updated_at = ? WHERE id = ?",
                 JSON.generate([]), JSON.generate(delta), now, r["id"]]
              )
            )
          end
        end

        groups_migrated += 1
        rows_reduced += with_legacy.size
      end

      Result.new(
        groups_migrated: groups_migrated,
        rows_reduced: rows_reduced,
        skipped_existing: skipped_existing,
        lines: lines
      )
    end

    private

    def decode(value)
      return value.select { |v| v.is_a?(String) } if value.is_a?(Array)

      if value.is_a?(String) && !value.empty?
        parsed = begin
          JSON.parse(value)
        rescue JSON::ParserError
          []
        end
        return parsed.is_a?(Array) ? parsed.select { |v| v.is_a?(String) } : []
      end

      []
    end
  end
end
