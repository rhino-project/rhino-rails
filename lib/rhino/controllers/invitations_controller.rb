# frozen_string_literal: true

module Rhino
  # Invitation management controller — mirrors Laravel InvitationController exactly.
  #
  # Endpoints:
  #   GET    /api/{org}/invitations
  #   POST   /api/{org}/invitations
  #   POST   /api/{org}/invitations/:id/resend
  #   DELETE /api/{org}/invitations/:id
  #   POST   /api/invitations/accept   (public)
  class InvitationsController < ActionController::API
    include Pundit::Authorization

    before_action :authenticate_user!, except: [:accept]
    before_action :set_organization, except: [:accept]

    # GET /api/{org}/invitations
    def index
      authorize OrganizationInvitation, :index?, policy_class: InvitationPolicy

      status = params[:status] || "all"

      query = OrganizationInvitation
                .where(organization_id: current_organization.id)
                .includes(:organization, :role, :inviter)

      case status
      when "pending"
        query = query.pending
      when "expired"
        query = query.expired
      when "all"
        # no filter
      else
        query = query.where(status: status)
      end

      render json: query.order(created_at: :desc)
    end

    # POST /api/{org}/invitations
    def create
      authorize OrganizationInvitation, :create?, policy_class: InvitationPolicy

      errors = {}
      errors[:email] = ["The email field is required."] if params[:email].blank?
      errors[:role_id] = ["The role_id field is required."] if params[:role_id].blank?

      unless errors.empty?
        return render json: { errors: errors }, status: :unprocessable_entity
      end

      email = params[:email].to_s.strip
      role_id = params[:role_id]

      # Check if user already exists and is in organization
      user_class = "User".safe_constantize
      if user_class
        existing_user = user_class.find_by(email: email)
        if existing_user&.respond_to?(:organizations)
          if existing_user.organizations.exists?(id: current_organization.id)
            return render json: { message: "User is already a member of this organization" }, status: :unprocessable_entity
          end
        end
      end

      # Check for existing pending invitation
      existing_invitation = OrganizationInvitation
                              .where(email: email, organization_id: current_organization.id, status: "pending")
                              .where("expires_at IS NULL OR expires_at > ?", Time.current)
                              .first

      if existing_invitation
        return render json: { message: "A pending invitation already exists for this email" }, status: :unprocessable_entity
      end

      # Create invitation
      invitation = OrganizationInvitation.create!(
        organization_id: current_organization.id,
        email: email,
        role_id: role_id,
        invited_by: current_user.id
      )

      # Send notification email
      send_invitation_email(invitation)

      render json: invitation.as_json(include: { organization: {}, role: {}, inviter: {} }), status: :created
    end

    # POST /api/{org}/invitations/:id/resend
    def resend
      invitation = OrganizationInvitation
                     .where(id: params[:id], organization_id: current_organization.id)
                     .first!

      authorize invitation, :update?, policy_class: InvitationPolicy

      unless invitation.status == "pending"
        return render json: { message: "Only pending invitations can be resent" }, status: :unprocessable_entity
      end

      # Update expiration
      days = Rhino.config.invitations[:expires_days] || 7
      invitation.update!(expires_at: days.days.from_now)

      # Resend notification email
      send_invitation_email(invitation)

      render json: {
        message: "Invitation resent successfully",
        invitation: invitation.as_json(include: { organization: {}, role: {}, inviter: {} })
      }
    end

    # DELETE /api/{org}/invitations/:id
    def cancel
      invitation = OrganizationInvitation
                     .where(id: params[:id], organization_id: current_organization.id)
                     .first!

      authorize invitation, :destroy?, policy_class: InvitationPolicy

      unless invitation.status == "pending"
        return render json: { message: "Only pending invitations can be cancelled" }, status: :unprocessable_entity
      end

      invitation.update!(status: "cancelled")

      render json: { message: "Invitation cancelled successfully" }
    end

    # POST /api/invitations/accept (public route)
    def accept
      if params[:token].blank?
        return render json: { errors: { token: ["The token field is required."] } }, status: :unprocessable_entity
      end

      invitation = OrganizationInvitation.find_by(token: params[:token], status: "pending")

      unless invitation
        return render json: { message: "Invalid or expired invitation token" }, status: :not_found
      end

      if invitation.expired?
        invitation.update!(status: "expired")
        return render json: { message: "This invitation has expired" }, status: :unprocessable_entity
      end

      # Check if user is authenticated
      user = resolve_current_user

      unless user
        return render json: {
          invitation: invitation.as_json(include: { organization: {}, role: {} }),
          requires_registration: true,
          message: "Please register or login to accept this invitation"
        }, status: :ok
      end

      # User is authenticated, accept invitation
      if invitation.accept!(user)
        render json: {
          message: "Invitation accepted successfully",
          invitation: invitation.as_json(include: { organization: {}, role: {} }),
          organization: invitation.organization
        }, status: :ok
      else
        render json: { message: "Failed to accept invitation" }, status: :internal_server_error
      end
    end

    private

    def authenticate_user!
      unless current_user
        render json: { message: "Unauthenticated." }, status: :unauthorized
      end
    end

    def current_user
      @current_user ||= resolve_current_user
    end

    def resolve_current_user
      token = request.headers["Authorization"]&.sub(/\ABearer /, "")
      return nil unless token

      user_class = "User".safe_constantize
      return nil unless user_class

      if user_class.respond_to?(:find_by_api_token)
        user_class.find_by_api_token(token)
      elsif user_class.column_names.include?("api_token")
        user_class.find_by(api_token: token)
      end
    end

    def set_organization
      # Try from middleware first, then resolve from route params
      @organization = request.env["rhino.organization"]
      return if @organization

      org_identifier = params[:organization]
      return unless org_identifier.present?

      org_class = "Organization".safe_constantize
      return unless org_class

      column = Rhino.config.multi_tenant[:organization_identifier_column] || "id"
      @organization = org_class.find_by(column => org_identifier)

      if @organization
        request.env["rhino.organization"] = @organization
        RequestStore.store[:rhino_organization] = @organization if defined?(RequestStore)
      end
    end

    def current_organization
      @organization
    end

    def send_invitation_email(invitation)
      mailer_class = "Rhino::InvitationMailer".safe_constantize
      mailer_class&.invite(invitation)&.deliver_later
    rescue StandardError => e
      Rails.logger.warn("Failed to send invitation email: #{e.message}")
    end
  end
end
