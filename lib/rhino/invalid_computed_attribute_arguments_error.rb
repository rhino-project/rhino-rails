# frozen_string_literal: true

module Rhino
  # Raised when a client-requested computed attribute is given arguments that do
  # not match the model's declared parameter spec. Rendered as 403 by
  # ResourcesController, message and all: it is only ever raised after the
  # attribute name itself passed the declaration check and the policy, so naming
  # the parameters reveals nothing about attributes the user may not see.
  class InvalidComputedAttributeArgumentsError < StandardError; end
end
