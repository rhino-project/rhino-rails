# frozen_string_literal: true

module Rhino
  # Auto-detect and apply global scopes by convention.
  # Mirrors the Laravel HasAutoScope trait.
  #
  # Looks for a scope class at `Scopes::{ModelName}Scope`
  # (e.g., `Scopes::PostScope` for `Post` model).
  #
  # The scope class can either:
  #
  # 1. Extend +Rhino::ResourceScope+ (recommended) — provides access to
  #    +user+, +organization+, and +role+ inside the +apply+ instance method:
  #
  #   module Scopes
  #     class PostScope < Rhino::ResourceScope
  #       def apply(relation)
  #         if role == "viewer"
  #           relation.where(published: true)
  #         else
  #           relation
  #         end
  #       end
  #     end
  #   end
  #
  # 2. Implement +self.apply(relation)+ as a class method (legacy/simple):
  #
  #   module Scopes
  #     class PostScope
  #       def self.apply(relation)
  #         relation.where(active: true)
  #       end
  #     end
  #   end
  #
  module HasAutoScope
    extend ActiveSupport::Concern

    included do
      default_scope lambda {
        model = is_a?(ActiveRecord::Relation) ? self.klass : self
        if model.respond_to?(:rhino_auto_scope_class)
          scope_class = model.rhino_auto_scope_class
          if scope_class
            model.apply_rhino_scope(scope_class, where(nil))
          else
            where(nil)
          end
        else
          where(nil)
        end
      }
    end

    class_methods do
      def rhino_auto_scope_class
        return @rhino_auto_scope_class if instance_variable_defined?(:@rhino_auto_scope_class)

        result = find_auto_scope_class
        # Only cache non-nil results to avoid permanently caching nil
        # when the scope class hasn't been autoloaded yet (Zeitwerk)
        @rhino_auto_scope_class = result if result
        result
      end

      # Apply the scope class to a relation.
      # Supports both ResourceScope subclasses (instance method) and
      # plain classes with self.apply (class method).
      def apply_rhino_scope(scope_class, relation)
        if scope_class < Rhino::ResourceScope
          scope_class.new.apply(relation)
        elsif scope_class.respond_to?(:apply)
          scope_class.apply(relation)
        else
          relation
        end
      end

      private

      def find_auto_scope_class
        return nil if name.nil?

        model_name = name.demodulize
        "Scopes::#{model_name}Scope".safe_constantize ||
          "ModelScopes::#{model_name}Scope".safe_constantize
      end
    end
  end
end
