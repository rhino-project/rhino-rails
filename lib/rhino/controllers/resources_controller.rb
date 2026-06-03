# frozen_string_literal: true

module Rhino
  # Global CRUD controller that handles all registered models.
  # Mirrors the Laravel GlobalController exactly.
  #
  # Routes pass the model slug via route defaults, and this controller
  # resolves the appropriate ActiveRecord class to operate on.
  class ResourcesController < ActionController::API
    include Pundit::Authorization

    # Disable parameter wrapping — Rhino expects flat JSON params
    wrap_parameters false

    rescue_from Pundit::NotAuthorizedError do |_exception|
      render json: { message: "This action is unauthorized." }, status: :forbidden
    end

    # Cache for auto-detected organization paths (class-level, survives across requests)
    @@organization_path_cache = {}

    before_action :set_model_class
    before_action :set_route_group
    before_action :resolve_organization
    before_action :authenticate_user!, unless: :public_route_group?
    before_action :enforce_group_membership, unless: :public_route_group?

    # GET /api/{slug}
    def index
      authorize model_class, :index?, policy_class: policy_for(model_class)

      builder = QueryBuilder.new(model_class, params: params)
      apply_organization_scope(builder)
      builder.build

      per_page = params[:per_page]
      pagination_enabled = model_class.try(:pagination_enabled) || false

      if per_page.present? || pagination_enabled
        result = builder.paginate
        set_pagination_headers(result[:pagination])
        render json: { data: serialize_collection(result[:items]) }
      else
        render json: { data: serialize_collection(builder.to_scope) }
      end
    end

    # POST /api/{slug}
    def store
      authorize model_class, :create?, policy_class: policy_for(model_class)

      data = params_hash

      # Strip organization_id — it's auto-set by the framework
      data.delete("organization_id") if current_organization

      permitted_fields = resolve_permitted_fields(current_user, "create")

      # Check for forbidden fields → 403
      forbidden = find_forbidden_fields(data, permitted_fields)
      if forbidden.any?
        return render json: {
          message: "You are not allowed to set the following field(s): #{forbidden.join(', ')}"
        }, status: :forbidden
      end

      model_instance = model_class.new
      validation = model_instance.validate_for_action(
        data, permitted_fields: permitted_fields, organization: current_organization
      )

      unless validation[:valid]
        return render json: { errors: validation[:errors] }, status: :unprocessable_entity
      end

      validated = validation[:validated]
      add_organization_to_data(validated)

      record = model_class.create!(validated)
      render json: serialize_record(record), status: :created
    end

    # GET /api/{slug}/:id
    def show
      record = find_record
      authorize record, :show?, policy_class: policy_for(record)

      # Apply includes if requested
      if params[:include].present?
        auth_response = authorize_includes
        return auth_response if auth_response

        builder = QueryBuilder.new(model_class, params: params)
        builder.instance_variable_set(:@scope, model_class.where(id: record.id))
        apply_organization_scope(builder)
        builder.build
        record = builder.to_scope.first!
      end

      render json: serialize_record(record)
    end

    # PUT /api/{slug}/:id
    def update
      record = find_record
      authorize record, :update?, policy_class: policy_for(record)

      data = params_hash

      # Reject organization_id changes — cross-tenant reassignment is not allowed
      if current_organization && data.key?("organization_id")
        return render json: {
          message: "You are not allowed to change the organization_id."
        }, status: :forbidden
      end

      permitted_fields = resolve_permitted_fields(current_user, "update")

      # Check for forbidden fields → 403
      forbidden = find_forbidden_fields(data, permitted_fields)
      if forbidden.any?
        return render json: {
          message: "You are not allowed to set the following field(s): #{forbidden.join(', ')}"
        }, status: :forbidden
      end

      model_instance = model_class.new
      validation = model_instance.validate_for_action(
        data, permitted_fields: permitted_fields, organization: current_organization
      )

      unless validation[:valid]
        return render json: { errors: validation[:errors] }, status: :unprocessable_entity
      end

      record.update!(validation[:validated])
      record.reload

      render json: serialize_record(record)
    end

    # DELETE /api/{slug}/:id
    def destroy
      record = find_record
      authorize record, :destroy?, policy_class: policy_for(record)

      if record.respond_to?(:discard!)
        record.discard!
      else
        record.destroy!
      end

      head :no_content
    end

    # ------------------------------------------------------------------
    # Soft Delete Endpoints
    # ------------------------------------------------------------------

    # GET /api/{slug}/trashed
    def trashed
      authorize model_class, :view_trashed?, policy_class: policy_for(model_class)

      builder = QueryBuilder.new(model_class.discarded, params: params)
      apply_organization_scope(builder)
      builder.build

      per_page = params[:per_page]
      pagination_enabled = model_class.try(:pagination_enabled) || false

      if per_page.present? || pagination_enabled
        result = builder.paginate
        set_pagination_headers(result[:pagination])
        render json: { data: serialize_collection(result[:items]) }
      else
        render json: { data: serialize_collection(builder.to_scope) }
      end
    end

    # POST /api/{slug}/:id/restore
    def restore
      record = model_class.discarded.find(params[:id])
      authorize record, :restore?, policy_class: policy_for(record)

      record.undiscard!
      record.reload

      render json: serialize_record(record)
    end

    # DELETE /api/{slug}/:id/force-delete
    def force_delete
      record = model_class.discarded.find(params[:id])
      authorize record, :force_delete?, policy_class: policy_for(record)

      record.destroy!

      head :no_content
    end

    # ------------------------------------------------------------------
    # Nested Operations
    # ------------------------------------------------------------------

    # POST /api/nested
    def nested
      operations = validate_nested_structure
      return if performed?

      nested_config = Rhino.config.nested
      max_ops = nested_config[:max_operations]

      if max_ops && operations.length > max_ops
        return render json: {
          message: "Too many operations.",
          errors: { operations: ["Maximum #{max_ops} operations allowed."] }
        }, status: :unprocessable_entity
      end

      allowed_models = nested_config[:allowed_models]
      if allowed_models.is_a?(Array)
        operations.each_with_index do |op, index|
          unless allowed_models.include?(op["model"])
            return render json: {
              message: "Operation not allowed.",
              errors: { "operations.#{index}.model" => ["Model \"#{op['model']}\" is not allowed for nested operations."] }
            }, status: :unprocessable_entity
          end
        end
      end

      # Validate and authorize each operation
      validated_per_op = []
      auth_results = []

      operations.each_with_index do |operation, index|
        validated = validate_nested_operation(operation, index)
        return if performed?
        validated_per_op << validated

        auth_result = authorize_nested_operation(operation, validated, index)
        return if performed?
        auth_results << auth_result
      end

      # Execute all operations in a transaction
      results = execute_nested_operations(operations, validated_per_op, auth_results)
      render json: { results: results }
    end

    private

    # ------------------------------------------------------------------
    # Model resolution
    # ------------------------------------------------------------------

    def set_model_class
      slug = params[:model_slug] || request.env["rhino.model_slug"]
      @model_class = Rhino.config.resolve_model(slug)
    rescue ActiveRecord::RecordNotFound => e
      render json: { message: e.message }, status: :not_found
    end

    def model_class
      @model_class
    end

    def model_slug
      params[:model_slug] || request.env["rhino.model_slug"]
    end

    # ------------------------------------------------------------------
    # Authentication
    # ------------------------------------------------------------------

    def public_route_group?
      current_route_group == "public"
    end

    def current_route_group
      params[:route_group]
    end

    # Expose the resolved route_group to policies/permissions via RequestStore
    # so group-aware permission resolution (when enforcement is on) can use it.
    def set_route_group
      return unless defined?(RequestStore)

      RequestStore.store[:rhino_route_group] = params[:route_group].presence
    end

    # Coarse group-membership gate (GROUP_AUTH_DESIGN.md §6). Entirely gated by
    # the enforce_group_membership flag; off = unchanged. Runs after auth, so an
    # authenticated user without a matching membership row gets 403.
    def enforce_group_membership
      return unless Rhino.config.respond_to?(:enforce_group_membership?)
      return unless Rhino.config.enforce_group_membership?

      user = current_user
      return unless user # unauthenticated already handled by authenticate_user!

      unless Rhino::GroupMembership.member?(user, current_route_group, current_organization)
        render json: { message: "You are not a member of this group" }, status: :forbidden
      end
    end

    def authenticate_user!
      unless current_user
        render json: { message: "Unauthenticated." }, status: :unauthorized
      end
    end

    def current_user
      # Override in host app or use token auth
      @current_user ||= begin
        token = request.headers["Authorization"]&.sub(/\ABearer /, "")
        return nil unless token

        # Look for user by API token
        user_class = "User".safe_constantize
        return nil unless user_class

        user = if user_class.respond_to?(:find_by_api_token)
          user_class.find_by_api_token(token)
        elsif user_class.column_names.include?("api_token")
          user_class.find_by(api_token: token)
        end

        # Store in RequestStore so scopes and concerns can access it
        RequestStore.store[:rhino_current_user] = user if defined?(RequestStore) && user

        user
      end
    end

    # ------------------------------------------------------------------
    # Organization (multi-tenant)
    # ------------------------------------------------------------------

    def resolve_organization
      org_identifier = params[:organization]
      return unless org_identifier.present?

      org_class = "Organization".safe_constantize
      return unless org_class

      column = Rhino.config.multi_tenant[:organization_identifier_column] || "id"
      organization = org_class.find_by(column => org_identifier)

      unless organization
        render json: { message: "Organization not found" }, status: :not_found
        return
      end

      # Check if authenticated user belongs to this organization
      user = current_user
      if user && user.respond_to?(:user_roles) && !user.user_roles.exists?(organization_id: organization.id)
        render json: { message: "Organization not found" }, status: :not_found
        return
      end

      request.env["rhino.organization"] = organization

      if defined?(RequestStore)
        RequestStore.store[:rhino_organization] = organization
      end
    end

    def current_organization
      request.env["rhino.organization"]
    end

    def apply_organization_scope(builder)
      org = current_organization
      return unless org

      # When the resource IS the Organization model
      if org.class == model_class
        builder.instance_variable_set(
          :@scope,
          builder.scope.where(model_class.primary_key => org.send(model_class.primary_key))
        )
        return
      end

      # Check for scopeForOrganization
      if model_class.respond_to?(:for_organization)
        builder.instance_variable_set(:@scope, model_class.for_organization(org))
        return
      end

      # Check for organization_id column
      if model_class.column_names.include?("organization_id")
        builder.instance_variable_set(
          :@scope,
          builder.scope.where(organization_id: org.id)
        )
        return
      end

      # Auto-detect from belongs_to relationships
      detected_path = discover_organization_path(model_class)
      if detected_path.present?
        apply_organization_scope_through_relationship(builder, org, detected_path)
      end
    end

    def apply_organization_scope_through_relationship(builder, organization, relationship_path)
      if relationship_path.include?(".")
        # Nested path: 'post.blog' -> joins(post: :blog).where(blogs: { organization_id: org.id })
        parts = relationship_path.split(".")
        join_chain = parts.reverse.inject(:organization) { |inner, outer| { outer.to_sym => inner } }

        builder.instance_variable_set(
          :@scope,
          builder.scope.joins(join_chain.is_a?(Symbol) ? join_chain : parts.first.to_sym => join_chain)
                       .where(organizations: { id: organization.id })
        )
      else
        # Single relationship
        assoc = model_class.reflect_on_association(relationship_path.to_sym)
        return unless assoc

        if assoc.klass.column_names.include?("organization_id")
          builder.instance_variable_set(
            :@scope,
            builder.scope.joins(relationship_path.to_sym)
                         .where(assoc.klass.table_name => { organization_id: organization.id })
          )
        end
      end
    end

    def add_organization_to_data(data)
      org = current_organization
      return unless org

      if model_class.column_names.include?("organization_id")
        data["organization_id"] = org.id
      end
    end

    # Recursively discover the relationship path from a model to Organization
    # by introspecting BelongsTo associations. Returns dot-notation path or nil.
    #
    # Results are cached per model class to avoid repeated reflection.
    def discover_organization_path(klass, visited = [], max_depth = 3)
      # Return cached result (including nil)
      if @@organization_path_cache.key?(klass.name)
        return @@organization_path_cache[klass.name]
      end

      result = _discover_organization_path_recursive(klass, visited, max_depth)
      @@organization_path_cache[klass.name] = result
      result
    end

    def _discover_organization_path_recursive(klass, visited, max_depth)
      return nil if max_depth <= 0 || visited.include?(klass.name)

      visited = visited + [klass.name]

      begin
        associations = klass.reflect_on_all_associations(:belongs_to)
      rescue StandardError
        return nil
      end

      matching_paths = []

      associations.each do |assoc|
        begin
          related_class = assoc.klass
        rescue StandardError
          next
        end

        # Direct match: related model IS Organization
        if related_class.name == "Organization"
          matching_paths << assoc.name.to_s
          next
        end

        # Related model has organization_id column
        begin
          if related_class.column_names.include?("organization_id")
            matching_paths << assoc.name.to_s
            next
          end
        rescue StandardError
          # Table may not exist yet
        end

        # Related model includes BelongsToOrganization concern
        if related_class.include?(Rhino::BelongsToOrganization)
          matching_paths << assoc.name.to_s
          next
        end

        # Recurse into related model's BelongsTo associations
        sub_path = _discover_organization_path_recursive(related_class, visited, max_depth - 1)
        if sub_path.present?
          matching_paths << "#{assoc.name}.#{sub_path}"
        end
      end

      return nil if matching_paths.empty?

      if matching_paths.length > 1
        Rails.logger&.debug(
          "Rhino: Model #{klass.name} has multiple BelongsTo paths to Organization. " \
          "Using '#{matching_paths[0]}'. " \
          "Paths found: #{matching_paths.inspect}"
        )
      end

      matching_paths[0]
    end

    # ------------------------------------------------------------------
    # Record finding
    # ------------------------------------------------------------------

    def find_record
      scope = model_class.all

      org = current_organization
      if org && model_class.column_names.include?("organization_id")
        scope = scope.where(organization_id: org.id)
      end

      scope.find(params[:id])
    end

    # ------------------------------------------------------------------
    # Include authorization
    # ------------------------------------------------------------------

    def authorize_includes
      include_param = params[:include]
      return nil unless include_param.present?

      allowed = model_class.try(:allowed_includes) || []
      return nil if allowed.empty?

      requested = include_param.to_s.split(",").map(&:strip)

      requested.each do |include_path|
        segments = include_path.split(".")
        current_model = model_class

        segments.each do |segment|
          base = resolve_base_include_segment(segment, allowed)
          next unless base

          assoc = current_model.reflect_on_association(base.to_sym)
          next unless assoc

          related_class = assoc.klass
          policy = policy_for(related_class)

          begin
            unless policy.new(current_user, related_class).index?
              render json: {
                message: "You do not have permission to include #{include_path}."
              }, status: :forbidden
              return true
            end
          rescue StandardError
            # If policy check fails, deny
            render json: {
              message: "You do not have permission to include #{include_path}."
            }, status: :forbidden
            return true
          end

          current_model = related_class
        end
      end

      nil
    end

    def resolve_base_include_segment(segment, allowed)
      return segment if allowed.include?(segment)

      if segment.end_with?("Count")
        base = segment.sub(/Count\z/, "")
        return base if allowed.include?(base)
      end

      if segment.end_with?("Exists")
        base = segment.sub(/Exists\z/, "")
        return base if allowed.include?(base)
      end

      nil
    end

    # ------------------------------------------------------------------
    # Serialization
    # ------------------------------------------------------------------

    def serialize_record(record)
      if record.respond_to?(:as_rhino_json)
        record.as_rhino_json
      else
        record.as_json
      end
    end

    def serialize_collection(records)
      records.map { |r| serialize_record(r) }
    end

    # ------------------------------------------------------------------
    # Pagination headers
    # ------------------------------------------------------------------

    def set_pagination_headers(pagination)
      response.headers["X-Current-Page"] = pagination[:current_page].to_s
      response.headers["X-Last-Page"] = pagination[:last_page].to_s
      response.headers["X-Per-Page"] = pagination[:per_page].to_s
      response.headers["X-Total"] = pagination[:total].to_s
    end

    # ------------------------------------------------------------------
    # Policy resolution
    # ------------------------------------------------------------------

    def policy_for(record_or_class)
      klass = record_or_class.is_a?(Class) ? record_or_class : record_or_class.class

      # Try to find a specific policy (e.g., PostPolicy)
      policy_name = "#{klass.name}Policy"
      policy_class = policy_name.safe_constantize

      # Fall back to Rhino::ResourcePolicy
      policy_class || Rhino::ResourcePolicy
    end

    # ------------------------------------------------------------------
    # Nested operations helpers
    # ------------------------------------------------------------------

    def validate_nested_structure
      data = params.to_unsafe_h
      operations = data["operations"]

      unless operations.is_a?(Array)
        render json: {
          message: "The operations field is required and must be an array.",
          errors: { operations: ["The operations field is required and must be an array."] }
        }, status: :unprocessable_entity
        return nil
      end

      operations.each_with_index do |op, index|
        unless op.is_a?(Hash)
          render json: {
            message: "Invalid structure.",
            errors: { "operations.#{index}" => ["Each operation must be an object."] }
          }, status: :unprocessable_entity
          return nil
        end

        if op["model"].blank?
          render json: {
            message: "Invalid structure.",
            errors: { "operations.#{index}.model" => ["The model field is required."] }
          }, status: :unprocessable_entity
          return nil
        end

        unless %w[create update].include?(op["action"])
          render json: {
            message: "Invalid structure.",
            errors: { "operations.#{index}.action" => ["The action must be create or update."] }
          }, status: :unprocessable_entity
          return nil
        end

        unless op["data"].is_a?(Hash)
          render json: {
            message: "Invalid structure.",
            errors: { "operations.#{index}.data" => ["The data field is required and must be an object."] }
          }, status: :unprocessable_entity
          return nil
        end

        if op["action"] == "update" && !op.key?("id")
          render json: {
            message: "Invalid structure.",
            errors: { "operations.#{index}.id" => ["The id field is required for update operations."] }
          }, status: :unprocessable_entity
          return nil
        end
      end

      operations
    end

    def validate_nested_operation(operation, index)
      slug = operation["model"]
      op_model_class = begin
        Rhino.config.resolve_model(slug)
      rescue ActiveRecord::RecordNotFound
        render json: {
          message: "Unknown model.",
          errors: { "operations.#{index}.model" => ["The model \"#{slug}\" does not exist."] }
        }, status: :unprocessable_entity
        return nil
      end

      action = operation["action"] == "create" ? "create" : "update"
      op_policy = policy_for(op_model_class)
      op_policy_instance = op_policy.new(current_user, op_model_class)

      permitted_fields = if action == "create" && op_policy_instance.respond_to?(:permitted_attributes_for_create)
        op_policy_instance.permitted_attributes_for_create(current_user)
      elsif action == "update" && op_policy_instance.respond_to?(:permitted_attributes_for_update)
        op_policy_instance.permitted_attributes_for_update(current_user)
      else
        ['*']
      end

      # Check for forbidden fields → 403
      forbidden = find_forbidden_fields(operation["data"], permitted_fields)
      if forbidden.any?
        render json: {
          message: "You are not allowed to set the following field(s): #{forbidden.join(', ')}"
        }, status: :forbidden
        return nil
      end

      model_instance = op_model_class.new
      validation = model_instance.validate_for_action(operation["data"], permitted_fields: permitted_fields)

      unless validation[:valid]
        errors = {}
        validation[:errors].each do |key, messages|
          errors["operations.#{index}.data.#{key}"] = messages
        end
        render json: { message: "Validation failed.", errors: errors }, status: :unprocessable_entity
        return nil
      end

      validation[:validated]
    end

    def authorize_nested_operation(operation, _validated, _index)
      slug = operation["model"]
      op_model_class = Rhino.config.resolve_model(slug)
      policy = policy_for(op_model_class)

      if operation["action"] == "create"
        unless policy.new(current_user, op_model_class).create?
          render json: { message: "This action is unauthorized." }, status: :forbidden
          return nil
        end
        nil
      else
        record = op_model_class.find(operation["id"])
        unless policy.new(current_user, record).update?
          render json: { message: "This action is unauthorized." }, status: :forbidden
          return nil
        end
        record
      end
    end

    def execute_nested_operations(operations, validated_per_op, auth_results)
      results = []

      ActiveRecord::Base.transaction do
        operations.each_with_index do |op, index|
          validated = validated_per_op[index]
          model_or_nil = auth_results[index]

          if op["action"] == "create"
            op_model_class = Rhino.config.resolve_model(op["model"])
            data = validated.dup
            add_organization_to_data(data)
            record = op_model_class.create!(data)
            results << {
              model: op["model"],
              action: "create",
              id: record.id,
              data: serialize_record(record)
            }
          else
            model_or_nil.update!(validated)
            model_or_nil.reload
            results << {
              model: op["model"],
              action: "update",
              id: model_or_nil.id,
              data: serialize_record(model_or_nil)
            }
          end
        end
      end

      results
    end

    # ------------------------------------------------------------------
    # Permitted fields resolution
    # ------------------------------------------------------------------

    def resolve_permitted_fields(user, action)
      policy = policy_for(model_class)
      policy_instance = policy.new(user, model_class)

      case action.to_s
      when "create"
        policy_instance.respond_to?(:permitted_attributes_for_create) ?
          policy_instance.permitted_attributes_for_create(user) : ["*"]
      when "update"
        policy_instance.respond_to?(:permitted_attributes_for_update) ?
          policy_instance.permitted_attributes_for_update(user) : ["*"]
      else
        ["*"]
      end
    end

    def find_forbidden_fields(params_data, permitted_fields)
      return [] if permitted_fields == ["*"]

      permitted = permitted_fields.map(&:to_s)
      params_data.keys.map(&:to_s) - permitted
    end

    def params_hash
      params.except(:controller, :action, :model_slug, :route_group, :organization, :id, :format).to_unsafe_h
    end
  end
end
