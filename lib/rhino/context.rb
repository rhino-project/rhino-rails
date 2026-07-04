# frozen_string_literal: true

module Rhino
  # Ambient tenant context resolver.
  #
  # Reads the current user/organization from RequestStore by default (request-time
  # context set by the controller before_actions), but can be overridden for the
  # duration of a block via +with+ — used by the explicit query builder so jobs,
  # rake tasks, and tests can query without a route.
  module Context
    module_function

    # The active organization: the explicit override if one is in effect, else the
    # request-time organization from RequestStore.
    def organization
      if store.key?(:rhino_organization)
        store[:rhino_organization]
      elsif defined?(RequestStore)
        RequestStore.store[:rhino_organization]
      end
    end

    # The active user: the explicit override if one is in effect, else the
    # request-time user from RequestStore.
    def user
      if store.key?(:rhino_current_user)
        store[:rhino_current_user]
      elsif defined?(RequestStore)
        RequestStore.store[:rhino_current_user]
      end
    end

    # Run +block+ with the given user/organization installed into RequestStore.
    # Snapshots the prior RequestStore user+org, sets the new ones, yields, and
    # restores the snapshot in an ensure. Returns the block's value.
    def with(user:, organization:)
      return yield unless defined?(RequestStore)

      had_user = RequestStore.store.key?(:rhino_current_user)
      had_org  = RequestStore.store.key?(:rhino_organization)
      prev_user = RequestStore.store[:rhino_current_user]
      prev_org  = RequestStore.store[:rhino_organization]

      # Track the active override so Context.user/organization prefer it even when
      # the passed value is nil (distinguishing "explicitly nil" from "absent").
      had_override_user = store.key?(:rhino_current_user)
      had_override_org  = store.key?(:rhino_organization)
      prev_override_user = store[:rhino_current_user]
      prev_override_org  = store[:rhino_organization]

      RequestStore.store[:rhino_current_user] = user
      RequestStore.store[:rhino_organization] = organization
      store[:rhino_current_user] = user
      store[:rhino_organization] = organization

      begin
        yield
      ensure
        if had_user
          RequestStore.store[:rhino_current_user] = prev_user
        else
          RequestStore.store.delete(:rhino_current_user)
        end
        if had_org
          RequestStore.store[:rhino_organization] = prev_org
        else
          RequestStore.store.delete(:rhino_organization)
        end

        if had_override_user
          store[:rhino_current_user] = prev_override_user
        else
          store.delete(:rhino_current_user)
        end
        if had_override_org
          store[:rhino_organization] = prev_override_org
        else
          store.delete(:rhino_organization)
        end
      end
    end

    # Fiber-local override store for the active explicit context.
    def store
      Thread.current[:rhino_context_override] ||= {}
    end
  end
end
