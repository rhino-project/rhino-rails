# frozen_string_literal: true

module Rhino
  # Authentication controller — mirrors Laravel AuthController exactly.
  #
  # Endpoints:
  #   POST /api/auth/login
  #   POST /api/auth/logout
  #   POST /api/auth/password/recover
  #   POST /api/auth/password/reset
  #   POST /api/auth/register
  class AuthController < ActionController::API
    before_action :authenticate_user!, only: [:logout]

    # POST /api/auth/login
    def login
      email = params[:email].to_s.strip
      password = params[:password].to_s

      if email.blank? || password.blank?
        return render json: { message: "Invalid credentials" }, status: :unauthorized
      end

      user_class = "User".safe_constantize
      return render json: { message: "Invalid credentials" }, status: :unauthorized unless user_class

      user = user_class.find_by(email: email)

      unless user&.authenticate(password)
        return render json: { message: "Invalid credentials" }, status: :unauthorized
      end

      # Group membership is a coarse access gate (GROUP_AUTH_DESIGN.md §6).
      # Gated entirely by the enforce_group_membership flag; off = unchanged.
      if membership_enforced? && !group_member?(user)
        return render json: { message: "You are not a member of this group" }, status: :forbidden
      end

      token = generate_api_token(user)

      # Get the first organization the user belongs to
      organization_slug = nil
      if user.respond_to?(:organizations)
        first_org = user.organizations.first
        organization_slug = first_org&.slug
      end

      # Lifecycle hook (GROUP_AUTH_DESIGN.md §7). A reject revokes the token.
      hook_response = run_hook(:after_login, user, token: token, revoke_on_reject: true)
      return if hook_response

      render json: {
        token: token,
        organization_slug: organization_slug
      }, status: :ok
    end

    # POST /api/auth/logout
    def logout
      user = current_user

      if user.respond_to?(:regenerate_api_token)
        user.regenerate_api_token
      elsif user.respond_to?(:update_column) && user.class.column_names.include?("api_token")
        user.update_column(:api_token, SecureRandom.hex(32))
      end

      # Token is already gone; a rejecting hook only changes the status code.
      hook_response = run_hook(:after_logout, user, revoke_on_reject: false)
      return if hook_response

      render json: { message: "Logged out successfully" }, status: :ok
    end

    # POST /api/auth/password/recover
    def recover_password
      email = params[:email].to_s.strip

      if email.blank?
        return render json: { errors: { email: ["The email field is required."] } }, status: :unprocessable_entity
      end

      user_class = "User".safe_constantize
      user = user_class&.find_by(email: email)

      if user
        token = SecureRandom.hex(32)

        # Store reset token
        if user.respond_to?(:update_columns)
          user.update_columns(
            reset_password_token: token,
            reset_password_sent_at: Time.current
          )
        end

        # Send email via mailer if available
        mailer_class = "Rhino::PasswordRecoveryMailer".safe_constantize
        mailer_class&.recover(user, token)&.deliver_later

        # Lifecycle hook fires only when a user actually exists, and its
        # rejection is SWALLOWED here. recover_password must be an enumeration
        # oracle-free endpoint: a rejecting hook would otherwise return a 403
        # only for existing emails, letting a caller distinguish real accounts
        # from fake ones. The hook still runs for its side effects (e.g.
        # auditing, throttling), but its reject never changes the response.
        run_hook(:after_password_recover, user, revoke_on_reject: false, swallow_reject: true)
      end

      # Always return the same response (existing OR non-existing email) to
      # prevent email enumeration — this is the documented contract.
      render json: { message: "Password recovery email sent." }, status: :ok
    end

    # POST /api/auth/password/reset
    def reset
      errors = {}
      errors[:token] = ["The token field is required."] if params[:token].blank?
      errors[:email] = ["The email field is required."] if params[:email].blank?
      errors[:password] = ["The password field is required."] if params[:password].blank?

      if params[:password].present? && params[:password].length < 8
        errors[:password] = ["The password must be at least 8 characters."]
      end

      if params[:password].present? && params[:password] != params[:password_confirmation]
        errors[:password_confirmation] = ["The password confirmation does not match."]
      end

      unless errors.empty?
        return render json: { errors: errors }, status: :unprocessable_entity
      end

      user_class = "User".safe_constantize
      user = user_class&.find_by(email: params[:email])

      unless user
        return render json: { message: "Token is invalid or expired." }, status: :bad_request
      end

      # Verify token
      valid_token = user.respond_to?(:reset_password_token) &&
                    user.reset_password_token == params[:token] &&
                    user.respond_to?(:reset_password_sent_at) &&
                    user.reset_password_sent_at.present? &&
                    user.reset_password_sent_at > 1.hour.ago

      unless valid_token
        return render json: { message: "Token is invalid or expired." }, status: :bad_request
      end

      # Update password
      user.password = params[:password]
      user.reset_password_token = nil
      user.reset_password_sent_at = nil
      user.save!

      hook_response = run_hook(:after_password_reset, user, revoke_on_reject: false)
      return if hook_response

      render json: { message: "Password has been reset." }, status: :ok
    end

    # POST /api/auth/register
    def register_with_invitation
      errors = {}
      errors[:token] = ["The token field is required."] if params[:token].blank?
      errors[:name] = ["The name field is required."] if params[:name].blank?
      errors[:email] = ["The email field is required."] if params[:email].blank?
      errors[:password] = ["The password field is required."] if params[:password].blank?

      if params[:password].present? && params[:password].length < 8
        errors[:password] = ["The password must be at least 8 characters."]
      end

      if params[:password].present? && params[:password] != params[:password_confirmation]
        errors[:password_confirmation] = ["The password confirmation does not match."]
      end

      user_class = "User".safe_constantize
      if user_class && params[:email].present? && user_class.exists?(email: params[:email])
        errors[:email] = ["The email has already been taken."]
      end

      unless errors.empty?
        return render json: { errors: errors }, status: :unprocessable_entity
      end

      # Find invitation
      invitation = OrganizationInvitation.find_by(token: params[:token], status: "pending")

      unless invitation
        return render json: { message: "Invalid or expired invitation token" }, status: :not_found
      end

      if invitation.expired?
        invitation.update!(status: "expired")
        return render json: { message: "This invitation has expired" }, status: :unprocessable_entity
      end

      # Validate email matches invitation
      unless invitation.email == params[:email]
        return render json: { message: "Email does not match the invitation" }, status: :unprocessable_entity
      end

      # Create user
      user = user_class.create!(
        name: params[:name],
        email: params[:email],
        password: params[:password]
      )

      # Accept invitation (adds user to organization, carrying its route_group)
      invitation.accept!(user)

      # Generate token
      token = generate_api_token(user)

      # Get organization slug for redirect
      organization = invitation.organization
      organization_slug = organization&.slug

      # Lifecycle hook for the group the invitee joined (from the invitation).
      invite_group = invitation.respond_to?(:route_group) ? invitation.route_group : nil
      hook_response = run_hook(
        :after_register, user,
        token: token, revoke_on_reject: true,
        group_override: invite_group, organization_override: organization
      )
      return if hook_response

      render json: {
        message: "Registration successful",
        token: token,
        user: user.as_json(except: %w[password_digest api_token reset_password_token]),
        organization_slug: organization_slug
      }, status: :created
    end

    private

    # ------------------------------------------------------------------
    # Group-aware auth (GROUP_AUTH_DESIGN.md §5/§6/§7)
    # ------------------------------------------------------------------

    # The route_group resolved from the matched route's defaults. nil for the
    # legacy unprefixed auth routes with no :default group.
    def current_route_group
      params[:route_group].presence
    end

    # Resolve the organization for group-aware auth (tenant groups carry the
    # :organization prefix param). Returns nil for non-tenant/legacy routes.
    def current_organization
      return @current_organization if defined?(@current_organization)

      @current_organization = begin
        org_identifier = params[:organization]
        if org_identifier.present?
          org_class = "Organization".safe_constantize
          if org_class
            column = Rhino.config.multi_tenant[:organization_identifier_column] || "id"
            org_class.find_by(column => org_identifier)
          end
        end
      end
    end

    def membership_enforced?
      Rhino.config.respond_to?(:enforce_group_membership?) && Rhino.config.enforce_group_membership?
    end

    # Coarse membership gate for the resolved group (and org for tenant groups).
    def group_member?(user)
      Rhino::GroupMembership.member?(user, current_route_group, current_organization)
    end

    # Run the configured lifecycle hook for the current (or overridden) group.
    # Returns true when a response was rendered (rejection), false/nil otherwise.
    #
    # On Rhino::AuthRejected: for token-issuing actions (revoke_on_reject) the
    # just-issued token is revoked, then the carried status is returned.
    #
    # When swallow_reject is true (password/recover only), a rejection is run
    # for its side effects but NOT surfaced: the action proceeds to its uniform
    # response so the endpoint cannot be used as an email-enumeration oracle.
    def run_hook(event, user, token: nil, revoke_on_reject: false, swallow_reject: false, group_override: :__none__, organization_override: :__none__)
      group = group_override == :__none__ ? current_route_group : group_override
      org = organization_override == :__none__ ? current_organization : organization_override

      hooks = Rhino.config.respond_to?(:hooks_for_group) ? Rhino.config.hooks_for_group(group) : nil
      return false unless hooks
      return false unless hooks.respond_to?(event)

      context = {
        user: user,
        route_group: group,
        organization: org,
        token: token,
        request: request
      }

      hooks.public_send(event, user, context)
      false
    rescue Rhino::AuthRejected => e
      return false if swallow_reject

      revoke_token(user) if revoke_on_reject
      render json: { message: e.message }, status: e.status
      true
    end

    def revoke_token(user)
      return unless user

      if user.respond_to?(:regenerate_api_token)
        user.regenerate_api_token
      elsif user.respond_to?(:update_column) && user.class.column_names.include?("api_token")
        user.update_column(:api_token, SecureRandom.hex(32))
      end
    end

    def authenticate_user!
      unless current_user
        render json: { message: "Unauthenticated." }, status: :unauthorized
      end
    end

    def current_user
      @current_user ||= begin
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
    end

    def generate_api_token(user)
      if user.respond_to?(:regenerate_api_token)
        user.regenerate_api_token
        user.api_token
      elsif user.class.column_names.include?("api_token")
        token = SecureRandom.hex(32)
        user.update_column(:api_token, token)
        token
      else
        SecureRandom.hex(32)
      end
    end
  end
end
