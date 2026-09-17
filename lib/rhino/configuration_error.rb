# frozen_string_literal: true

module Rhino
  # Raised when Rhino is configured with something it cannot resolve at
  # request time — today only an explicit request-class registration
  # (`config.model :tasks, "Task", store_request: "..."`) whose class name
  # cannot be constantized, or which does not inherit from
  # Rhino::ResourceRequest.
  #
  # This is deliberately NOT rescued into a JSON response: a silently ignored
  # validation class is a security hole, so a misconfigured app must fail
  # loudly (500) on first use rather than quietly skipping validation.
  class ConfigurationError < StandardError; end
end
