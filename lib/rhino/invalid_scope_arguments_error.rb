# frozen_string_literal: true

module Rhino
  # Raised when a client-requested named scope is given arguments that do not
  # match the model's declared parameter spec. Rendered as 403 by
  # ResourcesController, message and all: it is only ever raised after the scope
  # name itself passed the whitelist and the policy, so naming the parameters
  # reveals nothing about scopes the user may not use.
  class InvalidScopeArgumentsError < StandardError; end

  # Raised when a client filters or sorts by an attribute the policy hides from
  # them. Rendered as 403 by ResourcesController.
  class QueryAttributeNotAllowedError < StandardError; end
end
