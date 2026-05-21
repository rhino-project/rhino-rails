# frozen_string_literal: true

module Rhino
  # Automatic change logging concern.
  # Mirrors the Laravel HasAuditTrail trait.
  #
  # Tracks: created, updated, deleted, force_deleted, restored
  # Records: old/new values, user_id, organization_id, ip_address, user_agent
  #
  # Usage:
  #   class Post < ApplicationRecord
  #     include Rhino::HasAuditTrail
  #
  #     # Optional: exclude sensitive fields from audit logging
  #     rhino_audit_exclude :password, :remember_token
  #   end
  module HasAuditTrail
    extend ActiveSupport::Concern

    included do
      class_attribute :audit_exclude_fields, default: %w[password remember_token]

      has_many :audit_logs, -> { order(created_at: :desc) },
               as: :auditable,
               class_name: "Rhino::AuditLog",
               dependent: :destroy

      after_create :log_audit_created
      after_update :log_audit_updated
      after_destroy :log_audit_deleted

      # For soft deletes restoration
      if respond_to?(:after_undiscard)
        after_undiscard :log_audit_restored
      end
    end

    class_methods do
      def rhino_audit_exclude(*fields)
        self.audit_exclude_fields = fields.map(&:to_s)
      end
    end

    private

    def log_audit_created
      log_audit("created", nil, auditable_attributes)
    end

    def log_audit_updated
      changes = saved_changes.except("updated_at")
      return if changes.blank?

      old_values = {}
      new_values = {}

      changes.each do |field, (old_val, new_val)|
        next if audit_exclude_fields.include?(field)
        old_values[field] = old_val
        new_values[field] = new_val
      end

      return if new_values.blank?

      log_audit("updated", old_values, new_values)
    end

    def log_audit_deleted
      action = respond_to?(:discarded?) && discarded? ? "deleted" : "force_deleted"
      log_audit(action, auditable_attributes, nil)
    end

    def log_audit_restored
      log_audit("restored", nil, auditable_attributes)
    end

    def log_audit(action, old_values, new_values)
      return unless audit_log_table_exists?

      attributes = {
        auditable: self,
        action: action,
        old_values: old_values,
        new_values: new_values,
        user_id: current_audit_user_id,
        ip_address: current_audit_ip_address,
        user_agent: current_audit_user_agent
      }

      # Add organization_id if available
      org = current_audit_organization
      attributes[:organization_id] = org.id if org

      Rhino::AuditLog.create!(attributes)
    rescue StandardError => e
      Rails.logger.warn("Rhino::HasAuditTrail: Failed to log audit: #{e.message}")
    end

    def auditable_attributes
      attributes.except(*audit_exclude_fields)
    end

    def current_audit_user_id
      RequestStore.store[:rhino_current_user]&.id if defined?(RequestStore)
    end

    def current_audit_ip_address
      RequestStore.store[:rhino_ip_address] if defined?(RequestStore)
    end

    def current_audit_user_agent
      RequestStore.store[:rhino_user_agent] if defined?(RequestStore)
    end

    def current_audit_organization
      RequestStore.store[:rhino_organization] if defined?(RequestStore)
    end

    def audit_log_table_exists?
      @_audit_log_table_exists ||= ActiveRecord::Base.connection.table_exists?("audit_logs")
    rescue StandardError
      false
    end
  end
end
