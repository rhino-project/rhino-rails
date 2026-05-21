# frozen_string_literal: true

module Rhino
  module Middleware
    # Rack middleware that extracts the organization from the route parameter.
    # Mirrors the Laravel ResolveOrganizationFromRoute middleware.
    #
    # For route-prefix multi-tenancy: /api/{organization}/posts
    class ResolveOrganizationFromRoute
      def initialize(app)
        @app = app
      end

      def call(env)
        request = ActionDispatch::Request.new(env)

        # Extract organization identifier from route params
        org_identifier = request.path_parameters[:organization]

        if org_identifier.present?
          organization = find_organization(org_identifier)

          unless organization
            return [404, { "Content-Type" => "application/json" }, ['{"message":"Organization not found"}']]
          end

          # Check if authenticated user belongs to this organization
          user = resolve_user(request)
          if user && !user_belongs_to_organization?(user, organization)
            return [404, { "Content-Type" => "application/json" }, ['{"message":"Organization not found"}']]
          end

          env["rhino.organization"] = organization

          if defined?(RequestStore)
            RequestStore.store[:rhino_organization] = organization
          end
        end

        @app.call(env)
      end

      private

      def find_organization(identifier)
        org_class = "Organization".safe_constantize
        return nil unless org_class

        column = Rhino.config.multi_tenant[:organization_identifier_column] || "id"
        org_class.find_by(column => identifier)
      end

      def resolve_user(request)
        token = request.headers["Authorization"]&.sub(/\ABearer /, "")
        return nil unless token

        user_class = "User".safe_constantize
        return nil unless user_class

        if user_class.column_names.include?("api_token")
          user_class.find_by(api_token: token)
        end
      end

      def user_belongs_to_organization?(user, organization)
        return true unless user.respond_to?(:user_roles)

        user.user_roles.exists?(organization_id: organization.id)
      end
    end
  end
end
