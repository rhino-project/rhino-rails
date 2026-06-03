# frozen_string_literal: true

module Rhino
  # Raised by a lifecycle hook (or membership enforcement) to reject an auth
  # action. Carries an HTTP status (default 403) and a message. For
  # token-issuing actions (login/register) the controller revokes the
  # just-issued token before returning the status.
  #
  # See GROUP_AUTH_DESIGN.md §7.
  class AuthRejected < StandardError
    attr_reader :status

    def initialize(message = "Forbidden", status: 403)
      @status = status
      super(message)
    end
  end
end
