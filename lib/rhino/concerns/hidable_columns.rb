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
    # @return [Hash]
    def as_rhino_json
      user = rhino_current_user
      hidden = hidden_columns_for(user)
      result = as_json(except: hidden)

      # Merge computed attributes from model BEFORE applying policy filtering
      computed = rhino_computed_attributes
      result.merge!(computed) if computed.is_a?(Hash) && computed.any?

      # Apply blacklist to the final hash (covers DB columns from as_json
      # overrides AND computed attributes from rhino_computed_attributes)
      hidden_set = Set.new(hidden)
      result.reject! { |key, _| hidden_set.include?(key) }

      # Apply whitelist to the final hash (covers computed attributes too)
      permitted = policy_permitted_attributes(user)
      if permitted && permitted != ['*']
        permitted_set = Set.new(permitted.map(&:to_s))
        permitted_set.add('id') # id is always allowed
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

    private

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
          hidden.concat(not_permitted)
        end
      end

      hidden
    rescue StandardError
      []
    end
  end
end
