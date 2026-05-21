# frozen_string_literal: true

require "rhino/commands/base_command"

module Rhino
  module Commands
    # Generate an invitation link for testing — mirrors Laravel `php artisan invitation:link` exactly.
    #
    # Usage: rails invitation:link EMAIL ORG [--role=ROLE] [--create]
    class InvitationLinkCommand < BaseCommand
      attr_accessor :email, :organization_identifier, :options

      def initialize
        super
        @options = { role: nil, create: false }
      end

      def perform(email = @email, organization_identifier = @organization_identifier)
        role_identifier = options[:role]
        should_create = options[:create]

        # Find organization
        identifier_column = Rhino.config.multi_tenant[:organization_identifier_column] || "slug"

        org_class = "Organization".safe_constantize
        unless org_class
          say "Organization model not found.", :red
          return
        end

        organization = org_class.find_by(identifier_column => organization_identifier)

        unless organization
          say "Organization '#{organization_identifier}' not found.", :red
          return
        end

        # Find or create invitation
        invitation = OrganizationInvitation
                       .where(email: email, organization_id: organization.id, status: "pending")
                       .first

        if !invitation && !should_create
          say "No pending invitation found for '#{email}' in organization '#{organization.name}'.", :red
          say "Use --create flag to create a new invitation."
          return
        end

        if !invitation && should_create
          unless role_identifier
            say "Role is required when creating a new invitation. Use --role option.", :red
            return
          end

          role_class = "Role".safe_constantize
          unless role_class
            say "Role model not found.", :red
            return
          end

          role = if role_identifier.match?(/\A\d+\z/)
                   role_class.find_by(id: role_identifier)
                 else
                   role_class.find_by(slug: role_identifier)
                 end

          unless role
            say "Role '#{role_identifier}' not found.", :red
            return
          end

          user_class = "User".safe_constantize
          invited_by = user_class&.first

          unless invited_by
            say "No user found to assign as 'invited_by'. Please create a user first.", :red
            return
          end

          invitation = OrganizationInvitation.create!(
            organization_id: organization.id,
            email: email,
            role_id: role.id,
            invited_by: invited_by.id
          )

          say "Created new invitation for #{email}.", :green
        end

        # Build the invitation URL
        frontend_url = ENV.fetch("FRONTEND_URL", "http://localhost:5173")
        url = "#{frontend_url}/accept-invitation?token=#{invitation.token}"

        say ""
        say "Invitation link for #{email}:", :green
        say url
        say ""
        say "Token: #{invitation.token}"
        say "Organization: #{organization.name} (#{organization.try(:slug) || organization.id})"
        say "Role: #{invitation.role&.name}" if invitation.respond_to?(:role) && invitation.role
        say "Status: #{invitation.status}"
        say "Expires: #{invitation.expires_at&.strftime('%Y-%m-%d %H:%M:%S')}" if invitation.expires_at
        say ""
      end
    end
  end
end
