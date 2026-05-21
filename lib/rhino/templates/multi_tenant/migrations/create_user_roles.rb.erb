# frozen_string_literal: true

class CreateUserRoles < ActiveRecord::Migration[8.0]
  def change
    create_table :user_roles do |t|
      t.references :user, null: false, foreign_key: true
      t.references :organization, null: false, foreign_key: true
      t.references :role, null: false, foreign_key: true
      t.json :permissions, default: []

      t.timestamps
    end

    add_index :user_roles, [:user_id, :organization_id], unique: true
  end
end
