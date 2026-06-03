# frozen_string_literal: true

module Rhino
  # Base class for per-group auth lifecycle hooks. A group's optional `hooks:`
  # class may subclass this (or simply respond to the event methods) and
  # override any of the events; each defaults to a no-op.
  #
  # Each event receives the affected user and a context hash:
  #   { user:, route_group:, organization:, token:, request: }
  #
  # A hook rejects an action by raising Rhino::AuthRejected (optionally with a
  # status). For token-issuing actions (login/register) the controller revokes
  # the just-issued token and returns the status; for the others it returns the
  # status without side effects.
  #
  # See GROUP_AUTH_DESIGN.md §7.
  class AuthHooks
    def after_login(user, context = {}); end

    def after_logout(user, context = {}); end

    def after_register(user, context = {}); end

    def after_password_recover(user, context = {}); end

    def after_password_reset(user, context = {}); end
  end
end
