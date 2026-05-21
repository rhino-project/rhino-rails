# frozen_string_literal: true

module Rhino
  # Auto-generate UUID on model creation.
  # Mirrors the Laravel HasUuid trait.
  #
  # Usage:
  #   class Post < ApplicationRecord
  #     include Rhino::HasUuid
  #   end
  #
  # Requires a `uuid` column in the migration.
  module HasUuid
    extend ActiveSupport::Concern

    included do
      before_create :generate_uuid
    end

    private

    def generate_uuid
      self.uuid ||= SecureRandom.uuid if respond_to?(:uuid=)
    end
  end
end
