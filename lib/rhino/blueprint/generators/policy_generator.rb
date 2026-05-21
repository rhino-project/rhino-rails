# frozen_string_literal: true

module Rhino
  module Blueprint
    module Generators
      # Generates fully working Ruby policy classes with role-based attribute permissions.
      # Port of rhino-adonis-server policy_generator.ts.
      class PolicyGenerator
        # Generate a complete policy class.
        #
        # @param blueprint [Hash] ParsedBlueprint
        # @return [String] Ruby source code
        def generate(blueprint)
          model_name = blueprint[:model]
          slug = blueprint[:slug]
          permissions = blueprint[:permissions]

          show_method = build_permitted_attributes_method("permitted_attributes_for_show", permissions, :show_fields)
          hidden_method = build_hidden_attributes_method(permissions)
          create_method = build_permitted_attributes_method("permitted_attributes_for_create", permissions, :create_fields)
          update_method = build_permitted_attributes_method("permitted_attributes_for_update", permissions, :update_fields)

          <<~RUBY
            # frozen_string_literal: true

            class #{model_name}Policy < Rhino::ResourcePolicy
              self.resource_slug = '#{slug}'

            #{show_method}
            #{hidden_method}
            #{create_method}
            #{update_method}
            end
          RUBY
        end

        # Group roles with identical field sets into combined conditions.
        #
        # @param permissions [Hash<String, Hash>]
        # @param field_key [Symbol] :show_fields, :create_fields, etc.
        # @return [Array<Hash>] [{ fields: [...], roles: [...] }, ...]
        def group_roles_by_fields(permissions, field_key)
          groups = {}

          permissions.each do |role, perm|
            fields = perm[field_key] || []
            next if fields.empty?

            key = fields.sort.join(",")
            groups[key] ||= { fields: fields, roles: [] }
            groups[key][:roles] << role
          end

          groups.values
        end

        # Build a role condition string.
        #
        # @param roles [Array<String>]
        # @return [String] e.g. "has_role?(user, 'admin') || has_role?(user, 'editor')"
        def build_role_condition(roles)
          roles.map { |r| "has_role?(user, '#{r}')" }.join(" || ")
        end

        # Convert field array to Ruby array literal.
        #
        # @param fields [Array<String>]
        # @return [String]
        def fields_to_ruby_array(fields)
          return "[]" if fields.empty?
          return "['*']" if fields == ["*"]

          items = fields.map { |f| "'#{f}'" }
          inline = "[#{items.join(', ')}]"

          if inline.length <= 80
            inline
          else
            lines = items.join(",\n        ")
            "[\n        #{lines},\n      ]"
          end
        end

        # Build a permitted_attributes method body.
        #
        # @param method_name [String]
        # @param permissions [Hash<String, Hash>]
        # @param field_key [Symbol]
        # @return [String]
        def build_permitted_attributes_method(method_name, permissions, field_key)
          groups = group_roles_by_fields(permissions, field_key)

          if groups.empty?
            return <<~RUBY.chomp
                def #{method_name}(user)
                  ['*']
                end
            RUBY
          end

          lines = []
          lines << "  def #{method_name}(user)"

          groups.each do |group|
            condition = build_role_condition(group[:roles])
            array_str = fields_to_ruby_array(group[:fields])
            lines << "    return #{array_str} if #{condition}"
          end

          lines << "    []"
          lines << "  end"

          lines.join("\n")
        end

        # Build the hidden_attributes_for_show method.
        #
        # @param permissions [Hash<String, Hash>]
        # @return [String]
        def build_hidden_attributes_method(permissions)
          # Filter to only roles with hidden_fields
          hidden_perms = permissions.select { |_, perm| perm[:hidden_fields]&.any? }

          if hidden_perms.empty?
            return <<~RUBY.chomp
                def hidden_attributes_for_show(user)
                  []
                end
            RUBY
          end

          groups = group_roles_by_fields(
            hidden_perms.transform_values { |p| { show_fields: p[:hidden_fields] } },
            :show_fields
          )

          lines = []
          lines << "  def hidden_attributes_for_show(user)"

          groups.each do |group|
            condition = build_role_condition(group[:roles])
            array_str = fields_to_ruby_array(group[:fields])
            lines << "    return #{array_str} if #{condition}"
          end

          lines << "    []"
          lines << "  end"

          lines.join("\n")
        end
      end
    end
  end
end
