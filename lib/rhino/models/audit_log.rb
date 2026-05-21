# frozen_string_literal: true

module Rhino
  class AuditLog < ActiveRecord::Base
    self.table_name = "audit_logs"

    belongs_to :auditable, polymorphic: true
    belongs_to :user, optional: true

    validates :action, presence: true

    # old_values and new_values are json columns (native serialization).
    # No explicit `serialize` call needed — ActiveRecord handles json
    # columns automatically. If using text columns instead, add
    # `serialize :old_values, coder: JSON` in your app's subclass.
  end
end
