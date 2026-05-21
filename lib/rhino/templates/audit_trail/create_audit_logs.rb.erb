# frozen_string_literal: true

class CreateAuditLogs < ActiveRecord::Migration[8.0]
  def change
    create_table :audit_logs do |t|
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
    add_index :audit_logs, :user_id
    add_index :audit_logs, :organization_id
    add_index :audit_logs, :action
    add_index :audit_logs, :created_at
  end
end
