# frozen_string_literal: true

require "rhino/version"
require "rhino/configuration"
require "rhino/resource_scope"
require "rhino/routing/domain_constraint"
require "rhino/routing/route_group_validator"
require "rhino/middleware/resolve_organization_from_route"
require "rails"
require "rhino/engine"

module Rhino
  class << self
    def configure
      yield(configuration)
    end

    def configuration
      @configuration ||= Configuration.new
    end

    alias_method :config, :configuration

    def reset_configuration!
      @configuration = Configuration.new
    end
  end
end
