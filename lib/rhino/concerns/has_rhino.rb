# frozen_string_literal: true

module Rhino
  # Main model concern that provides the DSL for configuring query builder options.
  #
  # Usage:
  #   class Post < ApplicationRecord
  #     include Rhino::HasRhino
  #
  #     rhino_filters :status, :user_id
  #     rhino_sorts :title, :created_at
  #     rhino_default_sort '-created_at'
  #     rhino_includes :user, :comments
  #     rhino_fields :id, :title, :status, :created_at
  #     rhino_search :title, :content, 'user.name'
  #     rhino_scopes :active, available_for_drivers: Scopes::AvailableForDriversScope
  #     rhino_default_scope :active
  #     rhino_per_page 25
  #     rhino_pagination_enabled true
  #     rhino_middleware 'throttle:60,1'
  #     rhino_middleware_actions store: ['verified'], update: ['verified']
  #     rhino_except_actions :destroy
  #   end
  module HasRhino
    extend ActiveSupport::Concern

    included do
      class_attribute :allowed_filters, default: []
      class_attribute :allowed_scopes, default: {}
      class_attribute :default_rhino_scope, default: nil
      class_attribute :allowed_sorts, default: []
      class_attribute :default_sort_field, default: nil
      class_attribute :allowed_includes, default: []
      class_attribute :allowed_fields, default: []
      class_attribute :allowed_search, default: []
      class_attribute :rhino_per_page_count, default: 25
      class_attribute :pagination_enabled, default: false
      class_attribute :rhino_model_middleware, default: []
      class_attribute :rhino_middleware_actions_map, default: {}
      class_attribute :rhino_except_actions_list, default: []
      class_attribute :rhino_owner_path, default: nil
    end

    class_methods do
      def rhino_filters(*fields)
        self.allowed_filters = fields.map(&:to_s)
      end

      # Whitelist client-selectable named scopes for ?scope=.
      #   rhino_scopes :active, available_for_drivers: Scopes::AvailableForDriversScope
      # Bare symbols must name an existing ActiveRecord scope/class method on the model.
      # Hash values may be a Proc(relation, user) or a Rhino::ResourceScope subclass.
      def rhino_scopes(*names, **named)
        merged = allowed_scopes.dup
        names.each { |n| merged[n.to_s] = n.to_sym }
        named.each { |k, v| merged[k.to_s] = v }
        self.allowed_scopes = merged
      end

      # Named scope applied when no ?scope param is sent. Convenience, not a
      # security boundary. Value is the scope name (string/symbol).
      def rhino_default_scope(name)
        self.default_rhino_scope = name.to_s
      end

      def rhino_sorts(*fields)
        self.allowed_sorts = fields.map(&:to_s)
      end

      def rhino_default_sort(field)
        self.default_sort_field = field.to_s
      end

      def rhino_includes(*relations)
        self.allowed_includes = relations.map(&:to_s)
      end

      def rhino_fields(*fields)
        self.allowed_fields = fields.map(&:to_s)
      end

      def rhino_search(*fields)
        self.allowed_search = fields.map(&:to_s)
      end

      def rhino_per_page(count)
        self.rhino_per_page_count = count
      end

      def rhino_pagination_enabled(enabled = true)
        self.pagination_enabled = enabled
      end

      def rhino_middleware(*middleware)
        self.rhino_model_middleware = middleware.map(&:to_s)
      end

      def rhino_middleware_actions(actions_hash)
        self.rhino_middleware_actions_map = actions_hash.transform_keys(&:to_s)
      end

      def rhino_except_actions(*actions)
        self.rhino_except_actions_list = actions.map(&:to_s)
      end

      # Check if model uses soft deletes (Discard gem)
      def uses_soft_deletes?
        column_names.include?("discarded_at") || column_names.include?("deleted_at")
      rescue ActiveRecord::StatementInvalid
        false
      end
    end
  end
end
