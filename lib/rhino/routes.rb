# frozen_string_literal: true

module Rhino
  # Dynamic route registration from Rhino configuration.
  # Mirrors the Laravel routes/api.php behavior exactly.
  module Routes
    class << self
      def draw(router)
        config = Rhino.config
        route_groups = config.route_groups

        # Sort: literal prefixes first, parameterized (containing ':') last
        sorted_groups = route_groups.sort_by { |_name, cfg| cfg[:prefix].include?(":") ? 1 : 0 }

        router.instance_eval do
          scope path: "api", defaults: { format: :json } do
            # ---------------------------------------------------------------
            # Auth Routes (always registered)
            # ---------------------------------------------------------------
            scope path: "auth" do
              post "login", to: "rhino/auth#login"
              post "password/recover", to: "rhino/auth#recover_password"
              post "password/reset", to: "rhino/auth#reset"
              post "register", to: "rhino/auth#register_with_invitation"
              post "logout", to: "rhino/auth#logout"
            end

            # ---------------------------------------------------------------
            # Invitation accept (public, always registered)
            # ---------------------------------------------------------------
            post "invitations/accept", to: "rhino/invitations#accept"

            # ---------------------------------------------------------------
            # Tenant-specific routes (invitations + nested)
            # ---------------------------------------------------------------
            if config.has_tenant_group?
              tenant_config = route_groups[:tenant]
              tenant_prefix = tenant_config[:prefix]

              # Invitation routes under tenant prefix
              invitation_prefix = tenant_prefix.present? ? "#{tenant_prefix}/invitations" : "invitations"

              scope path: invitation_prefix do
                get "/", to: "rhino/invitations#index"
                post "/", to: "rhino/invitations#create"
                post ":id/resend", to: "rhino/invitations#resend"
                delete ":id", to: "rhino/invitations#cancel"
              end

              # Nested operations under tenant prefix
              nested_config = config.nested
              nested_path = nested_config[:path] || "nested"
              nested_prefix = tenant_prefix.present? ? "#{tenant_prefix}/#{nested_path}" : nested_path

              post nested_prefix, to: "rhino/resources#nested", as: :rhino_nested
            else
              # No tenant group — register nested at top level
              nested_config = config.nested
              nested_path = nested_config[:path] || "nested"
              post nested_path, to: "rhino/resources#nested", as: :rhino_nested
            end

            # ---------------------------------------------------------------
            # Per-group CRUD routes
            # ---------------------------------------------------------------
            sorted_groups.each do |group_name, group_config|
              group_prefix = group_config[:prefix]
              group_models = config.models_for_group(group_name)

              group_models.each do |slug|
                model_class_name = config.models[slug]
                model_class = begin
                  model_class_name.constantize
                rescue NameError
                  next
                end

                except_actions = model_class.try(:rhino_except_actions_list) || []

                route_prefix = [group_prefix, slug.to_s].reject(&:blank?).join("/")

                scope path: route_prefix, defaults: { model_slug: slug.to_s, route_group: group_name.to_s } do
                  unless except_actions.include?("index")
                    get "/", to: "rhino/resources#index", as: "rhino_#{group_name}_#{slug}_index"
                  end

                  unless except_actions.include?("store")
                    post "/", to: "rhino/resources#store", as: "rhino_#{group_name}_#{slug}_store"
                  end

                  if model_class.try(:uses_soft_deletes?)
                    unless except_actions.include?("trashed")
                      get "trashed", to: "rhino/resources#trashed", as: "rhino_#{group_name}_#{slug}_trashed"
                    end

                    unless except_actions.include?("restore")
                      post ":id/restore", to: "rhino/resources#restore", as: "rhino_#{group_name}_#{slug}_restore"
                    end

                    unless except_actions.include?("forceDelete")
                      delete ":id/force-delete", to: "rhino/resources#force_delete", as: "rhino_#{group_name}_#{slug}_force_delete"
                    end
                  end

                  unless except_actions.include?("show")
                    get ":id", to: "rhino/resources#show", as: "rhino_#{group_name}_#{slug}_show"
                  end

                  unless except_actions.include?("update")
                    put ":id", to: "rhino/resources#update", as: "rhino_#{group_name}_#{slug}_update"
                  end

                  unless except_actions.include?("destroy")
                    delete ":id", to: "rhino/resources#destroy", as: "rhino_#{group_name}_#{slug}_destroy"
                  end
                end
              end
            end
          end
        end
      end
    end
  end
end
