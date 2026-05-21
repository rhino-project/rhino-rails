# frozen_string_literal: true

require "spec_helper"
require "rhino/blueprint/generators/factory_generator"

RSpec.describe Rhino::Blueprint::Generators::FactoryGenerator do
  let(:generator) { described_class.new }

  # ------------------------------------------------------------------
  # generate
  # ------------------------------------------------------------------

  describe "#generate" do
    it "generates a FactoryBot factory file" do
      blueprint = {
        model: "Article",
        columns: [
          { name: "title", type: "string" },
          { name: "content", type: "text" }
        ],
        options: { belongs_to_organization: false }
      }

      result = generator.generate(blueprint)

      expect(result).to include("FactoryBot.define")
      expect(result).to include("factory :article")
      expect(result).to include("title")
      expect(result).to include("content")
    end

    it "generates association for foreignId with foreign_model" do
      blueprint = {
        model: "Comment",
        columns: [
          { name: "user_id", type: "foreignId", foreign_model: "User" },
          { name: "body", type: "text" }
        ],
        options: { belongs_to_organization: false }
      }

      result = generator.generate(blueprint)

      expect(result).to include("association :user, factory: :user")
    end

    it "generates number for foreignId without foreign_model" do
      blueprint = {
        model: "Task",
        columns: [
          { name: "project_id", type: "foreignId", foreign_model: nil }
        ],
        options: { belongs_to_organization: false }
      }

      result = generator.generate(blueprint)

      expect(result).to include("project_id")
      expect(result).to include("Faker::Number.between")
    end

    it "skips organization_id when belongs_to_organization is true" do
      blueprint = {
        model: "Project",
        columns: [
          { name: "organization_id", type: "foreignId", foreign_model: "Organization" },
          { name: "name", type: "string" }
        ],
        options: { belongs_to_organization: true }
      }

      result = generator.generate(blueprint)

      expect(result).not_to include("organization_id")
      expect(result).to include("name")
    end

    it "generates references associations" do
      blueprint = {
        model: "Post",
        columns: [
          { name: "category_id", type: "references", foreign_model: "Category" }
        ],
        options: { belongs_to_organization: false }
      }

      result = generator.generate(blueprint)

      expect(result).to include("association :category, factory: :category")
    end
  end

  # ------------------------------------------------------------------
  # column_to_faker (private)
  # ------------------------------------------------------------------

  describe "#column_to_faker" do
    def faker(attrs)
      column = { name: "field", type: "string" }.merge(attrs)
      generator.send(:column_to_faker, column)
    end

    it "generates Faker::Name.name for name column" do
      expect(faker(name: "name")).to eq("Faker::Name.name")
    end

    it "generates Faker::Name.name for full_name column" do
      expect(faker(name: "full_name")).to eq("Faker::Name.name")
    end

    it "generates Faker::Internet.email for email column" do
      expect(faker(name: "email")).to eq("Faker::Internet.email")
    end

    it "generates Faker::Lorem.sentence for title column" do
      expect(faker(name: "title")).to eq("Faker::Lorem.sentence(word_count: 3)")
    end

    it "generates Faker::Lorem.paragraph for description column" do
      expect(faker(name: "description")).to eq("Faker::Lorem.paragraph")
    end

    it "generates Faker::Lorem.paragraph for content column" do
      expect(faker(name: "content")).to eq("Faker::Lorem.paragraph")
    end

    it "generates Faker::Lorem.paragraph for body column" do
      expect(faker(name: "body")).to eq("Faker::Lorem.paragraph")
    end

    it "generates Faker::Internet.slug for slug column" do
      expect(faker(name: "slug")).to eq("Faker::Internet.slug")
    end

    it "generates Faker::PhoneNumber for phone column" do
      expect(faker(name: "phone")).to eq("Faker::PhoneNumber.phone_number")
    end

    it "generates Faker::PhoneNumber for phone_number column" do
      expect(faker(name: "phone_number")).to eq("Faker::PhoneNumber.phone_number")
    end

    it "generates Faker::Internet.url for url column" do
      expect(faker(name: "url")).to eq("Faker::Internet.url")
    end

    it "generates Faker::Internet.url for website column" do
      expect(faker(name: "website")).to eq("Faker::Internet.url")
    end

    it "generates boolean sample for is_* column" do
      expect(faker(name: "is_active")).to eq("[true, false].sample")
      expect(faker(name: "is_published")).to eq("[true, false].sample")
    end

    # Type-based fallbacks
    it "generates sentence for unknown string column" do
      expect(faker(name: "custom_field", type: "string")).to eq("Faker::Lorem.sentence(word_count: 3)")
    end

    it "generates paragraph for text type" do
      expect(faker(name: "notes", type: "text")).to eq("Faker::Lorem.paragraph")
    end

    it "generates number for integer type" do
      expect(faker(name: "count", type: "integer")).to eq("Faker::Number.between(from: 1, to: 100)")
    end

    it "generates number for bigInteger type" do
      expect(faker(name: "big_count", type: "bigInteger")).to eq("Faker::Number.between(from: 1, to: 100)")
    end

    it "generates boolean for boolean type" do
      expect(faker(name: "active", type: "boolean")).to eq("[true, false].sample")
    end

    it "generates date for date type" do
      expect(faker(name: "start_date", type: "date")).to include("Faker::Date.between")
    end

    it "generates time for datetime type" do
      expect(faker(name: "started_at", type: "datetime")).to include("Faker::Time.between")
    end

    it "generates time for timestamp type" do
      expect(faker(name: "fired_at", type: "timestamp")).to include("Faker::Time.between")
    end

    it "generates decimal for decimal type" do
      expect(faker(name: "price", type: "decimal")).to include("Faker::Number.decimal")
    end

    it "generates decimal for float type" do
      expect(faker(name: "score", type: "float")).to include("Faker::Number.decimal")
    end

    it "generates empty hash for json type" do
      expect(faker(name: "metadata", type: "json")).to eq("{}")
    end

    it "generates SecureRandom.uuid for uuid type" do
      expect(faker(name: "external_id", type: "uuid")).to eq("SecureRandom.uuid")
    end

    it "generates Faker::Lorem.word for unknown type" do
      expect(faker(name: "unknown", type: "binary")).to eq("Faker::Lorem.word")
    end
  end
end
