# frozen_string_literal: true

module Rhino
  class OrganizationInvitation < ActiveRecord::Base
    self.table_name = "organization_invitations"

    belongs_to :organization
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

      # Add user to organization via pivot table
      if defined?(UserRole)
        UserRole.find_or_create_by!(
          user_id: user.id,
          organization_id: organization_id,
          role_id: role_id
        )
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
