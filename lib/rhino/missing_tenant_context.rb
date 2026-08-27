# frozen_string_literal: true

module Rhino
  # Raised by Rhino.query (and the explicit builder) when an organization-scopable
  # model is queried with no organization context available. Fail-closed: the
  # resolver never returns an unscoped relation for a tenant-scopable model.
  class MissingTenantContext < StandardError
    def initialize(model_class = nil)
      super(
        "Rhino.query(#{model_class}) requires an organization context but none is set. " \
        "Use Rhino.for_user(...).in_organization(...) outside a tenant request, or declare " \
        "the route group serving this request non-tenant with `tenant: false` if it " \
        "legitimately spans every organization."
      )
    end
  end
end
