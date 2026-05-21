# frozen_string_literal: true

module Rhino
  # ActionMailer for invitation emails — mirrors Laravel InvitationNotification.
  class InvitationMailer < ActionMailer::Base
    def invite(invitation)
      @invitation = invitation
      @organization = invitation.organization
      @role = invitation.role
      @invited_by = invitation.inviter

      frontend_url = ENV.fetch("FRONTEND_URL", "http://localhost:5173")
      @url = "#{frontend_url}/accept-invitation?token=#{invitation.token}"
      @expires_at = invitation.expires_at

      mail(
        to: invitation.email,
        subject: "You've been invited to join #{@organization&.name}"
      )
    end
  end
end
