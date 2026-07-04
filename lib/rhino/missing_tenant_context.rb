# frozen_string_literal: true

module Rhino
  # Raised by Rhino.query (and the explicit builder) when an organization-scopable
  # model is queried with no organization context available. Fail-closed: the
  # resolver never returns an unscoped relation for a tenant-scopable model.
  class MissingTenantContext < StandardError; end
end
