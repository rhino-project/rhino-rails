# frozen_string_literal: true

module Rhino
  # Column-level visibility control concern.
  # Mirrors the Laravel HidableColumns trait.
  #
  # Base hidden columns: password, remember_token, created_at, updated_at,
  #   deleted_at, discarded_at, email_verified_at
  #
  # Usage:
  #   class User < ApplicationRecord
  #     include Rhino::HidableColumns
  #
  #     rhino_additional_hidden :secret_field, :internal_notes
  #   end
  #
  # Adding computed attributes to JSON responses:
  #   class Comment < Rhino::RhinoModel
  #     def author_name
  #       user&.name || 'Anonymous'
  #     end
  #
  #     def rhino_computed_attributes
  #       {
  #         'author_name' => author_name
  #       }
  #     end
  #   end
  #
  # Policy-based hiding:
  #   class UserPolicy < Rhino::ResourcePolicy
  #     def hidden_attributes_for_show(user)
  #       has_role?(user, 'admin') ? [] : ['email', 'phone']
  #     end
  #
  #     def permitted_attributes_for_show(user)
  #       has_role?(user, 'admin') ? ['*'] : ['id', 'name', 'avatar']
  #     end
  #   end
  module HidableColumns
    extend ActiveSupport::Concern

    BASE_HIDDEN_COLUMNS = %w[
      password
      password_digest
      remember_token
      created_at
      updated_at
      deleted_at
      discarded_at
      email_verified_at
    ].freeze

    included do
      class_attribute :additional_hidden_columns, default: []
    end

    class_methods do
      def rhino_additional_hidden(*columns)
        self.additional_hidden_columns = columns.map(&:to_s)
      end

      # Override this method to declare COLLECTION-level computed attributes,
      # served by <tt>GET /api/{resource}/computed?attributes=a,b</tt>.
      #
      # Each callable receives the fully scoped relation (organization scope,
      # default/global scopes, <tt>?scope=</tt>, <tt>?filter[]=</tt> and
      # <tt>?search=</tt> already applied) plus the current user, and is
      # evaluated ONCE for the whole collection — not once per row. This is the
      # cheap way to expose aggregates such as counts.
      #
      # Declaring at least one attribute here is what registers the
      # <tt>/computed</tt> route for the model.
      #
      # An attribute may also declare PARAMETERS the client supplies as
      # <tt>?attributes[name][param]=value</tt>. Use the extended form — a hash
      # carrying +params+ (and optionally +optional+ and +with+) — and the bound
      # arguments are appended after +user+, in declared order. An attribute
      # with a REQUIRED parameter is skipped by a bare <tt>GET /computed</tt>
      # rather than 403'd, so adding one never breaks a client that asks for
      # everything.
      #
      # @example
      #   def self.rhino_collection_computed_attributes
      #     {
      #       'active_users_count' => ->(scope, _user) { scope.where(status: 'active').count },
      #       'blocked_users_count' => ->(scope, _user) { scope.where(status: 'blocked').count },
      #       'revenue' => {
      #         params: %i[from to],
      #         with: ->(scope, _user, from, to) { scope.where(created_at: from..to).sum(:total) }
      #       }
      #     }
      #   end
      #
      # @return [Hash{String => Object}]
      def rhino_collection_computed_attributes
        {}
      end
    end

    # Get the list of columns to hide for the current user.
    # Merges base + static + policy-defined hidden columns.
    # Resolves the user from RequestStore automatically.
    #
    # @return [Array<String>] Column names to hide
    def hidden_columns_for(user = nil)
      user ||= rhino_current_user
      columns = BASE_HIDDEN_COLUMNS.dup
      columns.concat(additional_hidden_columns)
      columns.concat(policy_hidden_columns(user))
      columns.uniq
    end

    # Serialize to JSON excluding hidden columns and respecting policy whitelist.
    #
    # The current user is resolved automatically from RequestStore. Policy
    # filtering (blacklist + whitelist) is applied AFTER computed attributes
    # are merged, so computed attributes are always subject to policy control.
    #
    # Do NOT override this method. Override +rhino_computed_attributes+ instead
    # to add computed/virtual attributes to the JSON response.
    #
    # @param computed_attributes [Array<String>] opt-in record-level computed
    #   attributes to evaluate, selected via <tt>?computed_attributes=</tt>.
    # @param computed_arguments [Hash{String => Array}] positional arguments per
    #   attribute name. An attribute with required parameters and no entry here
    #   is skipped rather than called with too few arguments, so an existing
    #   direct caller that passes only names keeps working.
    # @return [Hash]
    def as_rhino_json(computed_attributes: [], computed_arguments: {})
      user = rhino_current_user
      hidden = hidden_columns_for(user)
      result = as_json(except: hidden)

      # Merge computed attributes from model BEFORE applying policy filtering
      computed = rhino_computed_attributes
      result.merge!(computed) if computed.is_a?(Hash) && computed.any?

      # Merge the OPT-IN record-level computed attributes the client selected via
      # ?computed_attributes=. Nothing here is evaluated unless it was asked for
      # by name, so declaring an expensive attribute costs nothing on requests
      # that don't want it. Merged before policy filtering, so the blacklist and
      # whitelist below still govern them.
      result.merge!(
        rhino_resolve_record_computed_attributes(computed_attributes, user, computed_arguments)
      )

      # Apply blacklist to the final hash (covers DB columns from as_json
      # overrides AND computed attributes from rhino_computed_attributes)
      hidden_set = Set.new(hidden)
      result.reject! { |key, _| hidden_set.include?(key) }

      # Apply whitelist to the final hash (covers computed attributes too)
      permitted = policy_permitted_attributes(user)
      if permitted && permitted != ['*']
        permitted_set = Set.new(permitted.map(&:to_s))
        permitted_set.add('id') # id is always allowed
        # The route key column is always allowed too — responses must stay
        # routable even when a policy whitelist omits it.
        route_key = self.class.try(:rhino_resolved_route_key)
        permitted_set.add(route_key.to_s) if route_key
        result.select! { |key, _| permitted_set.include?(key) }
      end

      result
    end

    # Override this method in your model to add computed/virtual attributes
    # to the JSON response. These attributes are subject to policy-level
    # blacklist (+hidden_attributes_for_show+) and whitelist
    # (+permitted_attributes_for_show+) just like database columns.
    #
    # @example
    #   def rhino_computed_attributes
    #     {
    #       'full_name' => "#{first_name} #{last_name}",
    #       'is_overdue' => due_date&.past?,
    #       'days_until_expiry' => expiry_date ? (expiry_date - Date.current).to_i : nil
    #     }
    #   end
    #
    # @return [Hash] key-value pairs to merge into the JSON response
    def rhino_computed_attributes
      {}
    end

    # Override this method to declare OPT-IN record-level computed attributes.
    #
    # Unlike +rhino_computed_attributes+, nothing here is evaluated unless the
    # client names it in <tt>?computed_attributes=a,b</tt> on index/show/trashed
    # — so expensive per-row work is only paid for when it is actually wanted.
    #
    # Return a hash of attribute name => callable. The callable may accept
    # zero, one (record) or two (record, user) arguments.
    #
    # An attribute may also declare PARAMETERS the client supplies as
    # <tt>?computed_attributes[name][param]=value</tt>. Use the extended form —
    # a hash carrying +params+ (and optionally +optional+ and +with+) — and the
    # bound arguments are appended after +user+, in declared order. A
    # parameterised entry is always called as <tt>call(record, user, *args)</tt>.
    # Any other declared value (a callable, a scalar, a plain array) keeps its
    # current meaning.
    #
    # @example
    #   def rhino_record_computed_attributes
    #     {
    #       'open_tickets_count' => ->(record, _user) { record.tickets.where(closed_at: nil).count },
    #       'full_name' => ->(record, _user) { "#{record.first_name} #{record.last_name}" },
    #       'tickets_since' => {
    #         params: [:since],
    #         with: ->(record, _user, since) { record.tickets.where("created_at >= ?", since).count }
    #       }
    #     }
    #   end
    #
    # @return [Hash{String => Object}]
    def rhino_record_computed_attributes
      {}
    end

    private

    # Evaluate the selected opt-in record-level computed attributes.
    #
    # Names that are not declared are silently skipped — the controller has
    # already rejected unknown/forbidden names with a 403, and a direct
    # +as_rhino_json+ caller must not be able to force an arbitrary call.
    #
    # An attribute that declares a required parameter is likewise skipped when
    # +arguments+ carries no entry for it, so a custom controller calling
    # <tt>as_rhino_json(computed_attributes: ['tickets_since'])</tt> gets a
    # missing key rather than an ArgumentError.
    def rhino_resolve_record_computed_attributes(names, user, arguments = {})
      return {} if names.blank?

      specs = Rhino::ComputedAttributeSpec.normalize(rhino_record_computed_attributes)
      return {} if specs.empty?

      arguments = (arguments || {}).transform_keys(&:to_s)

      Array(names).each_with_object({}) do |name, memo|
        key = name.to_s
        spec = specs[key]
        next if spec.nil?

        if arguments.key?(key)
          args = Array(arguments[key])
        elsif Rhino::ComputedAttributeSpec.requires_arguments?(spec)
          next
        else
          args = []
        end

        memo[key] = rhino_call_computed(spec, self, user, args)
      end
    end

    # Invoke a declared entry.
    #
    # A PARAMETERISED entry is always called as `call(record, user, *args)` —
    # the declaration is the contract. A parameterless entry keeps today's
    # tolerant arity 0/1/2 branch: Ruby lambdas are strict about arity, so the
    # arity is honoured rather than forcing every declaration to accept both
    # arguments.
    def rhino_call_computed(spec, record, user, args = [])
      entry = spec[:target]
      return entry unless entry.respond_to?(:call)

      return entry.call(record, user, *args) if Rhino::ComputedAttributeSpec.parameterised?(spec)

      case entry.try(:arity)
      when 0 then entry.call
      when 1 then entry.call(record)
      else entry.call(record, user)
      end
    end

    # Resolves the current user from RequestStore.
    # @return [Object, nil]
    def rhino_current_user
      RequestStore.store[:rhino_current_user] if defined?(RequestStore)
    end

    # Returns the permitted attributes list from the policy, or nil if no policy.
    def policy_permitted_attributes(user)
      policy_class = Pundit::PolicyFinder.new(self).policy
      return nil unless policy_class

      policy = policy_class.new(user, self)
      if policy.respond_to?(:permitted_attributes_for_show)
        policy.permitted_attributes_for_show(user)
      end
    rescue StandardError
      nil
    end

    def policy_hidden_columns(user)
      policy_class = Pundit::PolicyFinder.new(self).policy
      return [] unless policy_class

      policy = policy_class.new(user, self)
      hidden = []

      # Blacklist: hidden_attributes_for_show
      if policy.respond_to?(:hidden_attributes_for_show)
        hidden.concat(policy.hidden_attributes_for_show(user))
      end

      # Whitelist: permitted_attributes_for_show
      # Hide DB columns not in permitted list (computed attributes handled in as_rhino_json)
      if policy.respond_to?(:permitted_attributes_for_show)
        permitted = policy.permitted_attributes_for_show(user)
        if permitted != ['*']
          all_columns = self.class.column_names
          not_permitted = all_columns - permitted.map(&:to_s)
          # A configured route key is never hidden by a policy whitelist —
          # responses must stay routable. Default path (route key == primary
          # key) is intentionally untouched for backward compatibility.
          route_key = self.class.try(:rhino_resolved_route_key)
          if route_key && route_key.to_s != self.class.primary_key.to_s
            not_permitted -= [route_key.to_s]
          end
          hidden.concat(not_permitted)
        end
      end

      hidden
    rescue StandardError
      []
    end
  end
end
