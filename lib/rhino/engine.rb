# frozen_string_literal: true

require "pundit"
require "pagy"
require "discard"

module Rhino
  class Engine < ::Rails::Engine
    isolate_namespace Rhino

    rake_tasks do
      load File.expand_path("tasks/rhino.rake", __dir__)
    end

    initializer "rhino.autoloads" do
      # Concerns
      require "rhino/concerns/has_rhino"
      require "rhino/concerns/has_validation"
      require "rhino/concerns/has_permissions"
      require "rhino/concerns/has_audit_trail"
      require "rhino/concerns/belongs_to_organization"
      require "rhino/concerns/hidable_columns"
      require "rhino/concerns/has_uuid"
      require "rhino/concerns/has_auto_scope"

      # Policies
      require "rhino/policies/resource_policy"
      require "rhino/policies/invitation_policy"

      # Query builder, routing constraints and routes
      require "rhino/query_builder"
      require "rhino/routing/domain_constraint"
      require "rhino/routes"

      # Controllers
      require "rhino/controllers/resources_controller"
      require "rhino/controllers/auth_controller"
      require "rhino/controllers/invitations_controller"

      # Mailers (only if ActionMailer is available)
      require "rhino/mailers/invitation_mailer" if defined?(ActionMailer)
    end

    # Models that inherit from ApplicationRecord must be loaded after
    # ActiveRecord is available. Using after: :load_active_record ensures
    # ApplicationRecord exists before our models try to extend it.
    initializer "rhino.models", after: :load_active_record do
      require "rhino/models/rhino_model"
      require "rhino/models/audit_log"
      require "rhino/models/organization_invitation"
    end

    initializer "rhino.routes", after: :load_config_initializers do |app|
      app.routes.append do
        Rhino::Routes.draw(self)
      end
    end

    initializer "rhino.pundit" do
      ActiveSupport.on_load(:action_controller) do
        include Pundit::Authorization if defined?(Pundit)
      end
    end
  end
end
