# frozen_string_literal: true

module Rhino
  # Places a custom (non-Rhino) controller into a Rhino route group, so the
  # resource-scope resolver knows whether the request has a tenant boundary.
  #
  # Rhino's own generated controllers already publish their group; a controller
  # you write yourself is outside that chain, so include this concern in it:
  #
  #   class Admin::DashboardController < ApplicationController
  #     include Rhino::RouteGroupContext
  #     rhino_route_group :admin
  #
  #     def summary
  #       # :admin is declared `tenant: false`, so this spans every organization
  #       # instead of raising Rhino::MissingTenantContext.
  #       render json: { tasks: Rhino.query(Task).count }
  #     end
  #   end
  #
  # Without an explicit `rhino_route_group`, the group is read from the route's
  # own `route_group` default:
  #
  #   get "/api/admin/dashboard", to: "admin/dashboard#summary",
  #                               defaults: { route_group: "admin" }
  module RouteGroupContext
    extend ActiveSupport::Concern

    included do
      # Inheritable, so a base controller can declare the group for a whole
      # namespace and subclasses may override it.
      class_attribute :rhino_route_group_name, instance_writer: false, default: nil

      before_action :rhino_set_route_group
    end

    class_methods do
      # Declare the route group this controller's actions belong to.
      def rhino_route_group(name)
        self.rhino_route_group_name = name.to_s
      end
    end

    private

    # Publish the group for Rhino::Context (and therefore for Rhino.query, the
    # policies and the permission resolver) for the rest of this request.
    def rhino_set_route_group
      return unless defined?(RequestStore)

      # An explicit declaration wins; otherwise fall back to the route's own
      # `route_group` default, which only exists once a request is bound.
      resolved = rhino_route_group_name.presence
      resolved ||= params[:route_group].presence if request

      RequestStore.store[:rhino_route_group] = resolved
    end
  end
end
