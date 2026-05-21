# frozen_string_literal: true

module Rhino
  module Blueprint
    module Generators
      # Generates seeder files for roles and users with aggregated permissions.
      # Port of rhino-adonis-server seeder_generator.ts.
      class SeederGenerator
        ALL_ACTIONS = %w[index show store update destroy trashed restore forceDelete].freeze

        # Generate a RoleSeeder file for multi-tenant apps.
        #
        # @param roles [Hash<String, Hash>]
        # @return [String] Ruby source code
        def generate_role_seeder(roles)
          role_entries = roles.map do |slug, role|
            desc = role[:description].gsub("'", "\\\\'")
            <<~RUBY.chomp
                Role.find_or_create_by!(slug: '#{slug}') do |r|
                  r.name = '#{role[:name]}'
                  r.description = '#{desc}'
                end
            RUBY
          end.join("\n\n")

          <<~RUBY
            # frozen_string_literal: true


            #{role_entries}
          RUBY
        end

        # Generate a UserRoleSeeder file for multi-tenant apps.
        #
        # @param roles [Hash<String, Hash>]
        # @param aggregated_permissions [Hash<String, Array<String>>]
        # @return [String] Ruby source code
        def generate_user_role_seeder(roles, aggregated_permissions)
          user_entries = roles.map do |slug, role|
            permissions = aggregated_permissions[slug] || []
            perm_str = permissions_to_ruby_array(permissions)

            <<~RUBY.chomp
                # #{role[:name]}
                #{slug}_user = User.find_or_create_by!(email: '#{slug}@demo.com') do |u|
                  u.password = 'password'
                end
                #{slug}_role = Role.find_by!(slug: '#{slug}')
                UserRole.find_or_create_by!(
                  user: #{slug}_user,
                  organization: org,
                  role: #{slug}_role
                ) do |ur|
                  ur.permissions = #{perm_str}
                end
            RUBY
          end.join("\n\n")

          <<~RUBY
            # frozen_string_literal: true


            org = Organization.find_or_create_by!(slug: 'demo-org') do |o|
              o.name = 'Demo Organization'
            end

            #{user_entries}
          RUBY
        end

        # Generate a UserPermissionSeeder file for non-tenant apps.
        #
        # @param roles [Hash<String, Hash>]
        # @param aggregated_permissions [Hash<String, Array<String>>]
        # @return [String] Ruby source code
        def generate_user_permission_seeder(roles, aggregated_permissions)
          user_entries = roles.map do |slug, role|
            permissions = aggregated_permissions[slug] || []
            perm_str = permissions_to_ruby_array(permissions)

            <<~RUBY.chomp
                # #{role[:name]}
                User.find_or_create_by!(email: '#{slug}@demo.com') do |u|
                  u.password = 'password'
                  u.permissions = #{perm_str}
                end
            RUBY
          end.join("\n\n")

          <<~RUBY
            # frozen_string_literal: true


            #{user_entries}
          RUBY
        end

        # Aggregate permissions from multiple blueprints.
        # Returns { role_slug => ['model.action', ...] } with wildcard simplification.
        #
        # @param blueprints [Array<Hash>]
        # @return [Hash<String, Array<String>>]
        def aggregate_permissions(blueprints)
          result = {}

          blueprints.each do |blueprint|
            slug = blueprint[:slug]

            blueprint[:permissions].each do |role, perm|
              result[role] ||= Set.new

              has_all = ALL_ACTIONS.all? { |a| perm[:actions].include?(a) }

              if has_all
                result[role].add("#{slug}.*")
              else
                perm[:actions].each { |action| result[role].add("#{slug}.#{action}") }
              end
            end
          end

          # Simplify: if a role has wildcard on ALL models → ['*']
          model_slugs = blueprints.map { |b| b[:slug] }
          final_result = {}

          result.each do |role, perms|
            perm_array = perms.to_a.sort

            has_all_wildcards = model_slugs.all? { |s| perms.include?("#{s}.*") }

            if has_all_wildcards && model_slugs.any?
              final_result[role] = ["*"]
            else
              final_result[role] = perm_array
            end
          end

          final_result
        end

        # Convert permission array to Ruby array literal.
        def permissions_to_ruby_array(permissions)
          return "[]" if permissions.empty?
          return "['*']" if permissions.length == 1 && permissions[0] == "*"

          items = permissions.map { |p| "'#{p}'" }
          inline = "[#{items.join(', ')}]"

          if inline.length <= 80
            inline
          else
            lines = items.join(",\n        ")
            "[\n        #{lines},\n      ]"
          end
        end
      end
    end
  end
end
