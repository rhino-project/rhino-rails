# frozen_string_literal: true

module Rhino
  module Blueprint
    module Generators
      # Generates RSpec request spec files with per-role contexts and individual action tests.
      class TestGenerator
        ALL_ACTIONS = %w[index show store update destroy trashed restore forceDelete].freeze

        ACTION_LABELS = {
          "index" => "list",
          "show" => "show",
          "store" => "create",
          "update" => "update",
          "destroy" => "delete",
          "trashed" => "view trashed",
          "restore" => "restore",
          "forceDelete" => "force delete"
        }.freeze

        def generate(blueprint, is_multi_tenant, org_identifier = "slug")
          model = blueprint[:model]
          slug = blueprint[:slug]
          permissions = blueprint[:permissions]
          columns = blueprint[:columns]
          factory_name = model_to_factory(model)

          role_contexts = build_role_contexts(slug, factory_name, permissions, columns, is_multi_tenant, org_identifier)

          if is_multi_tenant
            wrap_multi_tenant(model, slug, role_contexts, org_identifier)
          else
            wrap_non_tenant(model, slug, role_contexts)
          end
        end

        def actions_to_permissions(actions, slug)
          if (ALL_ACTIONS - actions).empty?
            "['#{slug}.*']"
          else
            items = actions.map { |a| "'#{slug}.#{a}'" }
            "[#{items.join(', ')}]"
          end
        end

        private

        def model_to_factory(model)
          model.gsub(/([a-z])([A-Z])/, '\1_\2').downcase
        end

        def build_role_contexts(slug, factory_name, permissions, columns, is_multi_tenant, org_identifier)
          return "" if permissions.empty?

          all_defined_actions = permissions.values.flat_map { |p| p[:actions] }.uniq & ALL_ACTIONS
          lines = []

          permissions.each do |role, perm|
            allowed = perm[:actions] & all_defined_actions
            blocked = all_defined_actions - perm[:actions]

            lines << "    context 'as #{role}' do"
            lines << build_let_user(role, perm[:actions], slug, is_multi_tenant, org_identifier)
            lines << build_let_record(factory_name, is_multi_tenant)
            lines << ""

            # Individual allowed action tests
            allowed.each do |action|
              lines << build_single_action_test(slug, action, is_multi_tenant, org_identifier, true)
              lines << ""
            end

            # Individual blocked action tests
            blocked.each do |action|
              lines << build_single_action_test(slug, action, is_multi_tenant, org_identifier, false)
              lines << ""
            end

            # Field visibility tests
            field_test = build_field_visibility_test(slug, role, perm, columns, is_multi_tenant, org_identifier)
            if field_test
              lines << field_test
              lines << ""
            end

            # Forbidden field tests
            forbidden_test = build_forbidden_field_test(slug, role, perm, columns, is_multi_tenant, org_identifier)
            if forbidden_test
              lines << forbidden_test
              lines << ""
            end

            lines << "    end"
            lines << ""
          end

          lines.join("\n")
        end

        def build_let_user(role, actions, slug, is_multi_tenant, org_identifier)
          perms = actions_to_permissions(actions, slug)
          if is_multi_tenant
            "      let(:user) { create_user_with_role('#{role}', org, #{perms}) }"
          else
            "      let(:user) { create_user_with_permissions(#{perms}) }"
          end
        end

        def build_let_record(factory_name, is_multi_tenant)
          if is_multi_tenant
            "      let(:record) { create(:#{factory_name}, organization: org) }"
          else
            "      let(:record) { create(:#{factory_name}) }"
          end
        end

        def build_single_action_test(slug, action, is_multi_tenant, org_identifier, expect_success)
          id_actions = %w[show update destroy restore forceDelete]
          needs_id = id_actions.include?(action)
          needs_discard = %w[restore forceDelete].include?(action)

          action_methods = {
            "index" => "get", "show" => "get", "store" => "post",
            "update" => "put", "destroy" => "delete", "trashed" => "get",
            "restore" => "post", "forceDelete" => "delete"
          }

          action_path_suffix = {
            "index" => "", "show" => "/\#{record.id}", "store" => "",
            "update" => "/\#{record.id}", "destroy" => "/\#{record.id}",
            "trashed" => "/trashed", "restore" => "/\#{record.id}/restore",
            "forceDelete" => "/\#{record.id}/force-delete"
          }

          success_codes = { "store" => ":created", "destroy" => ":no_content", "forceDelete" => ":no_content" }
          default_success = ":ok"

          http_method = action_methods[action]
          suffix = action_path_suffix[action]
          return "" unless http_method

          label = ACTION_LABELS[action] || action

          if is_multi_tenant
            url = "\"/api/\#{org.#{org_identifier}}/#{slug}#{suffix}\""
          else
            url = "\"/api/#{slug}#{suffix}\""
          end

          if expect_success
            code = success_codes[action] || default_success
            verb = "can"
          else
            code = ":forbidden"
            verb = "cannot"
          end

          lines = []
          lines << "      it '#{verb} #{label} #{slug}' do"
          lines << "        record.discard" if needs_discard
          lines << "        #{http_method} #{url}, headers: auth_headers(user)"
          if expect_success && action == "store"
            lines << "        expect(response.status).not_to eq(403)"
          else
            lines << "        expect(response).to have_http_status(#{code})"
          end
          lines << "      end"
          lines.join("\n")
        end

        def build_field_visibility_test(slug, role, perm, columns, is_multi_tenant, org_identifier)
          return nil unless perm[:actions].include?("show")
          return nil if perm[:show_fields] == ["*"]
          return nil if perm[:show_fields].empty?

          all_fields = columns.map { |c| c[:name] }
          visible = perm[:show_fields].include?("*") ? all_fields : perm[:show_fields]
          hidden = all_fields - visible + (perm[:hidden_fields] || [])
          hidden = hidden.uniq - visible

          return nil if hidden.empty? && visible.empty?

          lines = []
          lines << "      it 'shows only permitted fields' do"

          if is_multi_tenant
            lines << "        get \"/api/\#{org.#{org_identifier}}/#{slug}/\#{record.id}\", headers: auth_headers(user)"
          else
            lines << "        get \"/api/#{slug}/\#{record.id}\", headers: auth_headers(user)"
          end

          lines << "        expect(response).to have_http_status(:ok)"
          lines << "        data = JSON.parse(response.body)"
          lines << ""

          visible.each do |field|
            lines << "        expect(data).to have_key('#{field}')"
          end

          if hidden.any?
            lines << ""
            hidden.each do |field|
              lines << "        expect(data).not_to have_key('#{field}')"
            end
          end

          lines << "      end"
          lines.join("\n")
        end

        def build_forbidden_field_test(slug, role, perm, columns, is_multi_tenant, org_identifier)
          return nil unless perm[:actions].include?("store")
          return nil if perm[:create_fields] == ["*"]
          return nil if perm[:create_fields].empty?

          all_fields = columns.map { |c| c[:name] }
          forbidden = all_fields - perm[:create_fields]

          return nil if forbidden.empty?

          lines = []
          lines << "      it 'returns 403 when setting restricted fields' do"

          if is_multi_tenant
            lines << "        post \"/api/\#{org.#{org_identifier}}/#{slug}\","
          else
            lines << "        post \"/api/#{slug}\","
          end

          lines << "          params: { #{forbidden.first}: 'forbidden_value' },"
          lines << "          headers: auth_headers(user)"
          lines << ""
          lines << "        expect(response).to have_http_status(:forbidden)"
          lines << "      end"
          lines.join("\n")
        end

        def wrap_multi_tenant(model, slug, role_contexts, org_identifier)
          <<~RUBY
            # frozen_string_literal: true

            require 'rails_helper'

            RSpec.describe '#{model} — CRUD & Permissions', type: :request do
              let(:org) { create(:organization) }

              def create_user_with_role(role_slug, organization, permissions)
                user = create(:user)
                role = Role.find_or_create_by!(slug: role_slug, name: role_slug.capitalize)
                UserRole.find_or_create_by!(
                  user: user,
                  organization: organization,
                  role: role
                ) do |ur|
                  ur.permissions = permissions
                end
                user
              end

              def auth_headers(user)
                { 'Authorization' => "Bearer \#{user.api_token}" }
              end

            #{role_contexts}
            end
          RUBY
        end

        def wrap_non_tenant(model, slug, role_contexts)
          <<~RUBY
            # frozen_string_literal: true

            require 'rails_helper'

            RSpec.describe '#{model} — CRUD & Permissions', type: :request do
              def create_user_with_permissions(permissions)
                create(:user, permissions: permissions)
              end

              def auth_headers(user)
                { 'Authorization' => "Bearer \#{user.api_token}" }
              end

            #{role_contexts}
            end
          RUBY
        end
      end
    end
  end
end
