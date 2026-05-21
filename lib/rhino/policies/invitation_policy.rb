# frozen_string_literal: true

module Rhino
  class InvitationPolicy
    attr_reader :user, :invitation

    def initialize(user, invitation)
      @user = user
      @invitation = invitation
    end

    def index?
      user_belongs_to_organization?
    end

    def create?
      user_belongs_to_organization? && role_allowed?
    end

    def update?
      user_belongs_to_organization? && invitation.pending?
    end

    def destroy?
      user_belongs_to_organization? && invitation.pending?
    end

    private

    def user_belongs_to_organization?
      return false unless user
      return false unless invitation.respond_to?(:organization_id)

      if user.respond_to?(:user_roles)
        user.user_roles.exists?(organization_id: invitation.organization_id)
      else
        true
      end
    end

    def role_allowed?
      allowed_roles = Rhino.config.invitations[:allowed_roles]
      return true if allowed_roles.nil?

      if user.respond_to?(:role_slug_for_validation)
        org = invitation.respond_to?(:organization) ? invitation.organization : nil
        role_slug = user.role_slug_for_validation(org)
        allowed_roles.include?(role_slug)
      else
        true
      end
    end
  end
end
