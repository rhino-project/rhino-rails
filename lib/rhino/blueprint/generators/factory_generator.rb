# frozen_string_literal: true

module Rhino
  module Blueprint
    module Generators
      # Generates FactoryBot factory files with smart Faker detection.
      # Reuses faker mapping logic from GenerateCommand.
      class FactoryGenerator
        # Generate a FactoryBot factory file.
        #
        # @param blueprint [Hash] ParsedBlueprint
        # @return [String] Ruby source code
        def generate(blueprint)
          model_name = blueprint[:model]
          factory_name = model_name.underscore
          columns = blueprint[:columns]

          field_lines = columns.map do |col|
            next if col[:name] == "organization_id" && blueprint[:options][:belongs_to_organization]

            if col[:type] == "foreignId" || col[:type] == "references"
              if col[:foreign_model]
                relation = col[:name].sub(/_id\z/, "")
                "    association :#{relation}, factory: :#{col[:foreign_model].underscore}"
              else
                "    #{col[:name]} { Faker::Number.between(from: 1, to: 10) }"
              end
            else
              "    #{col[:name]} { #{column_to_faker(col)} }"
            end
          end.compact

          <<~RUBY
            # frozen_string_literal: true

            FactoryBot.define do
              factory :#{factory_name} do
            #{field_lines.join("\n")}
              end
            end
          RUBY
        end

        private

        def column_to_faker(column)
          case column[:name]
          when "name", "full_name" then "Faker::Name.name"
          when "email" then "Faker::Internet.email"
          when "title" then "Faker::Lorem.sentence(word_count: 3)"
          when "description", "content", "body" then "Faker::Lorem.paragraph"
          when "slug" then "Faker::Internet.slug"
          when "phone", "phone_number" then "Faker::PhoneNumber.phone_number"
          when "url", "website" then "Faker::Internet.url"
          when /\Ais_/ then "[true, false].sample"
          else
            case column[:type]
            when "string" then "Faker::Lorem.sentence(word_count: 3)"
            when "text" then "Faker::Lorem.paragraph"
            when "integer", "bigInteger" then "Faker::Number.between(from: 1, to: 100)"
            when "boolean" then "[true, false].sample"
            when "date" then "Faker::Date.between(from: 1.year.ago, to: Date.today)"
            when "datetime", "timestamp" then "Faker::Time.between(from: 1.year.ago, to: Time.current)"
            when "decimal", "float" then "Faker::Number.decimal(l_digits: 3, r_digits: 2)"
            when "json" then "{}"
            when "uuid" then "SecureRandom.uuid"
            else "Faker::Lorem.word"
            end
          end
        end
      end
    end
  end
end
