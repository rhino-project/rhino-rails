# frozen_string_literal: true

module Rhino
  # Raised when a client requests a ?scope= name that is not whitelisted via
  # rhino_scopes / rhino_default_scope. Rendered as 403 by ResourcesController.
  class ScopeNotAllowedError < StandardError; end
end
