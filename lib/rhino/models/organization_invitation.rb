# frozen_string_literal: true

module Rhino
  class OrganizationInvitation < ActiveRecord::Base
    self.table_name = "organization_invitations"

    # organization is optional: non-tenant group invites (e.g. :admin/:driver)
    # have no organization (GROUP_AUTH_DESIGN.md §8).
    belongs_to :organization, optional: true
    belongs_to :role, optional: true
    belongs_to :inviter, class_name: "User", foreign_key: "invited_by", optional: true

    validates :email, presence: true
    validates :token, presence: true, uniqueness: true

    before_create :generate_token
    before_create :set_expiration

    scope :pending, -> { where(status: "pending").where("expires_at > ?", Time.current) }
    scope :expired, -> { where(status: "pending").where("expires_at <= ?", Time.current) }

    STATUSES = %w[pending accepted expired cancelled].freeze

    def expired?
      status == "pending" && expires_at.present? && expires_at <= Time.current
    end

    def pending?
      status == "pending" && !expired?
    end

    def accept!(user)
      update!(
        status: "accepted",
        accepted_at: Time.current
      )

      # Add user to the group (and organization, for tenant groups) via the
      # user_roles pivot. The membership carries the invitation's route_group
      # so group-membership enforcement (GROUP_AUTH_DESIGN.md §6/§8) can match.
      if defined?(UserRole)
        attrs = {
          user_id: user.id,
          organization_id: organization_id,
          role_id: role_id
        }

        invite_group = respond_to?(:route_group) ? route_group : nil
        if invite_group.present? && UserRole.column_names.include?("route_group")
          attrs[:route_group] = invite_group
        end

        UserRole.find_or_create_by!(attrs)
      end
    end

    private

    def generate_token
      self.token ||= SecureRandom.hex(32) # 64-char token
    end

    def set_expiration
      expires_days = Rhino.config.invitations[:expires_days] || 7
      self.expires_at ||= expires_days.days.from_now
    end
  end
end
