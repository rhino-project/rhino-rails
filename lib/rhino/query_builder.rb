# frozen_string_literal: true

module Rhino
  # Custom query builder that provides Rhino's exact URL parameter format.
  # Replaces Spatie QueryBuilder for Rails.
  #
  # Supports:
  #   - Filtering:    ?filter[status]=published&filter[user_id]=1
  #   - Sorting:      ?sort=-created_at,title
  #   - Search:       ?search=term
  #   - Pagination:   ?page=1&per_page=20
  #   - Fields:       ?fields[posts]=id,title,status
  #   - Includes:     ?include=user,comments
  class QueryBuilder
    # Fallback for how many named scopes one request may combine, used when no
    # Rhino configuration is reachable. Apps set +config.max_scopes_per_request+.
    #
    # Scopes are arbitrary query fragments, so stacking many of them is a good
    # way to build an accidental cross join; three covers every real listing.
    DEFAULT_MAX_SCOPES_PER_REQUEST = 3

    attr_reader :scope, :model_class, :params

    def initialize(model_class, params: {}, named_scopes: false)
      @model_class = model_class
      @scope = model_class.all
      @params = params
      @named_scopes = named_scopes
    end

    # Apply all query modifications based on params and model config.
    def build
      apply_named_scope if @named_scopes
      apply_filters
      apply_default_sort
      apply_sorts
      apply_search
      apply_fields
      apply_includes
      self
    end

    # Apply only the modifications that define WHICH rows are in the set:
    # named scope, filters and search. Sorting, sparse fieldsets, includes and
    # pagination are irrelevant to an aggregate over the collection and are
    # deliberately skipped — a `select` in particular would break `count`.
    def build_for_computed
      apply_named_scope if @named_scopes
      apply_filters
      apply_search
      self
    end

    # Get the final ActiveRecord relation.
    def to_scope
      @scope
    end

    # Execute with pagination. Returns { items:, pagination: }.
    def paginate(per_page: nil, page: nil)
      per_page = (per_page || params[:per_page] || model_class.try(:rhino_per_page_count) || 25).to_i
      per_page = [[per_page, 1].max, 100].min # clamp between 1 and 100
      page = (page || params[:page] || 1).to_i
      page = [page, 1].max

      total = @scope.count
      last_page = (total.to_f / per_page).ceil
      last_page = [last_page, 1].max

      items = @scope.offset((page - 1) * per_page).limit(per_page)

      {
        items: items,
        pagination: {
          current_page: page,
          last_page: last_page,
          per_page: per_page,
          total: total
        }
      }
    end

    private

    # ------------------------------------------------------------------
    # Named scopes: ?scope=availableForDrivers
    # ------------------------------------------------------------------
    #
    # Only runs for collection endpoints (index/trashed), which pass
    # +named_scopes: true+. `show` (including its ?include= build path) stays
    # unscoped so a record excluded by the default scope is still viewable.
    def apply_named_scope
      raw = params[:scope]
      raw = raw.to_unsafe_h if raw.respond_to?(:to_unsafe_h)

      declared = Rhino::ScopeSpec.normalize(model_class.try(:allowed_scopes))
      default = model_class.try(:default_rhino_scope)

      # Nothing requested: the model's default scope, which takes no arguments.
      if raw.nil? || raw == "" || raw == {}
        return if default.nil?

        return run_named_scope(default.to_s, declared[default.to_s] || {}, [])
      end

      requested =
        if raw.is_a?(Hash)
          raw
        else
          # Legacy form — ?scope=name, one scope, no arguments.
          { raw.to_s => "" }
        end

      raise Rhino::ScopeNotAllowedError, "Too many scopes requested" if requested.size > max_scopes_per_request

      permitted = permitted_scope_names

      requested.each do |wire_name, raw_arguments|
        raise Rhino::ScopeNotAllowedError, wire_name.to_s if wire_name.to_s.empty?

        name = wire_name.to_s.underscore
        entry = declared[name]
        # The default scope is implicitly allowed when requested by name.
        entry ||= { target: name.to_sym, params: [], optional: [] } if name == default

        # Echo the client's wire name (not the underscored form) in the error.
        raise Rhino::ScopeNotAllowedError, wire_name.to_s if entry.nil?

        if permitted != ["*"] && !permitted.include?(name)
          raise Rhino::ScopeNotAllowedError, wire_name.to_s
        end

        run_named_scope(name, entry, Rhino::ScopeSpec.bind(wire_name.to_s, entry, raw_arguments))
      end
    end

    # How many named scopes this app allows in one request.
    def max_scopes_per_request
      configured = Rhino.config.try(:max_scopes_per_request)
      configured.is_a?(Integer) && configured.positive? ? configured : DEFAULT_MAX_SCOPES_PER_REQUEST
    rescue StandardError
      DEFAULT_MAX_SCOPES_PER_REQUEST
    end

    # Run one already-authorized named scope, passing the bound arguments in the
    # order the model declared them.
    def run_named_scope(name, entry, args)
      target = entry[:target] || name.to_sym
      user = current_user

      @scope =
        case target
        when Symbol, String
          # Whitelisted AR scope. Client input never reaches public_send unless the
          # developer declared it via rhino_scopes. .merge composes with default_scopes.
          @scope.merge(model_class.public_send(target, *args))
        when Proc
          target.call(@scope, user, *args)
        else
          target.new.apply(@scope, *args) # Rhino::ResourceScope subclass (user/org/role helpers)
        end
    end

    # Scope names this user may select, or ["*"] when the policy does not
    # restrict them (the default, and the behavior of every policy written
    # before permitted_scopes existed).
    def permitted_scope_names
      policy = policy_instance
      return ["*"] unless policy.respond_to?(:permitted_scopes)

      permitted = policy.permitted_scopes(current_user)
      return ["*"] unless permitted.is_a?(Array)

      permitted.map(&:to_s)
    end

    # ------------------------------------------------------------------
    # Filtering: ?filter[status]=published&filter[user_id]=1
    # ------------------------------------------------------------------

    def apply_filters
      filter_params = params[:filter]
      return unless filter_params.is_a?(ActionController::Parameters) || filter_params.is_a?(Hash)

      allowed = model_class.try(:allowed_filters) || []
      return if allowed.empty? && filter_params.present?

      filter_params.each do |key, value|
        key = key.to_s
        next unless allowed.include?(key)

        unless attribute_queryable?(key)
          raise Rhino::QueryAttributeNotAllowedError, "Filter '#{key}' is not allowed"
        end

        if value.to_s.include?(",")
          # Multiple values: OR condition
          values = value.to_s.split(",").map(&:strip)
          values = coerce_filter_values(key, values)
          @scope = @scope.where(key => values)
        else
          @scope = @scope.where(key => coerce_filter_value(key, value))
        end
      end
    end

    # ------------------------------------------------------------------
    # Sorting: ?sort=-created_at,title
    # ------------------------------------------------------------------

    def apply_default_sort
      return if params[:sort].present?

      default = model_class.try(:default_sort_field)
      return unless default

      # The default sort is the server's own choice, so it is not subject to the
      # client allowlist or to the policy.
      apply_sort_string(default, client_supplied: false)
    end

    def apply_sorts
      sort_param = params[:sort]
      return unless sort_param.present?

      apply_sort_string(sort_param.to_s)
    end

    def apply_sort_string(sort_string, client_supplied: true)
      allowed = model_class.try(:allowed_sorts) || []

      sort_string.split(",").each do |field|
        field = field.strip
        if field.start_with?("-")
          column = field[1..]
          direction = :desc
        else
          column = field
          direction = :asc
        end

        if client_supplied
          # Deny by default: an undeclared column is ignored, never sorted by.
          next unless allowed.include?(column)

          unless attribute_queryable?(column)
            raise Rhino::QueryAttributeNotAllowedError, "Sort '#{column}' is not allowed"
          end
        end

        @scope = @scope.order(column => direction)
      end
    end

    # ------------------------------------------------------------------
    # Policy-aware attribute gate
    # ------------------------------------------------------------------
    #
    # Attribute permissions used to apply only when serializing, so a hidden
    # column stayed usable as a query predicate: ?filter[salary]=300000 never
    # printed a salary but told the caller whose salary it was, and ?sort= leaked
    # the whole ordering. Filters, sorts and search now go through the same gate
    # as the response body.

    def attribute_queryable?(name)
      return true if name.nil? || name.to_s.empty?

      attribute_path_allowed?(base_class, name.to_s)
    end

    def attribute_path_allowed?(klass, path)
      if path.include?(".")
        relation, rest = path.split(".", 2)
        assoc = klass.respond_to?(:reflect_on_association) ? klass.reflect_on_association(relation.to_sym) : nil
        # An unresolvable relation is left alone, so nothing that worked before
        # starts failing for a reason nobody can find.
        return true if assoc.nil?

        begin
          return attribute_path_allowed?(assoc.klass, rest)
        rescue NoMethodError, NameError
          return true
        end
      end

      policy = policy_instance(klass)
      user = current_user

      if policy.respond_to?(:hidden_attributes_for_show)
        return false if Array(policy.hidden_attributes_for_show(user)).map(&:to_s).include?(path)
      end

      return true unless policy.respond_to?(:permitted_attributes_for_show)

      permitted = Array(policy.permitted_attributes_for_show(user)).map(&:to_s)
      permitted == ["*"] || permitted.include?(path)
    end

    # The model class behind the builder: +model_class+ may be a relation, as it
    # is for the trashed listing.
    def base_class
      @base_class ||= model_class.respond_to?(:klass) ? model_class.klass : model_class
    end

    def policy_instance(klass = base_class)
      @policy_instances ||= {}
      @policy_instances[klass] ||= begin
        policy_class = "#{klass.name}Policy".safe_constantize || Rhino::ResourcePolicy
        policy_class.new(current_user, klass)
      rescue StandardError
        Rhino::ResourcePolicy.new(current_user, klass)
      end
    end

    def current_user
      defined?(RequestStore) ? RequestStore.store[:rhino_current_user] : nil
    end

    # ------------------------------------------------------------------
    # Search: ?search=term
    # ------------------------------------------------------------------

    def apply_search
      search_term = params[:search]
      return unless search_term.present?

      declared = model_class.try(:allowed_search) || []
      return if declared.empty?

      columns = declared.select { |column| attribute_queryable?(column.to_s) }

      # Every searchable column is hidden from this user. Searching a hidden
      # column tells the caller what is in it, so return nothing rather than
      # silently returning the whole list the client asked to narrow.
      if columns.empty?
        @scope = @scope.none
        return
      end

      term = "%#{search_term.to_s.downcase}%"
      conditions = []
      values = []

      columns.each do |column|
        if column.include?(".")
          # Relationship search: 'user.name' -> joins(:user).where("users.name ILIKE ?", term)
          parts = column.split(".", 2)
          relation = parts[0]
          field = parts[1]

          # Determine the table name from the association
          assoc = model_class.reflect_on_association(relation.to_sym)
          if assoc
            begin
              table_name = assoc.klass.table_name
              @scope = @scope.left_outer_joins(relation.to_sym)
              conditions << "LOWER(#{table_name}.#{field}) LIKE ?"
              values << term
            rescue NoMethodError, NameError
              next
            end
          end
        else
          conditions << "LOWER(#{model_class.table_name}.#{column}) LIKE ?"
          values << term
        end
      end

      return if conditions.empty?

      @scope = @scope.where(conditions.join(" OR "), *values)
    end

    # ------------------------------------------------------------------
    # Sparse fieldsets: ?fields[posts]=id,title,status
    # ------------------------------------------------------------------

    def apply_fields
      fields_params = params[:fields]
      return unless fields_params.is_a?(ActionController::Parameters) || fields_params.is_a?(Hash)

      allowed = model_class.try(:allowed_fields) || []
      return if allowed.empty?

      # Find fields for this model's table
      slug = Rhino.config.slug_for(model_class)
      model_fields = fields_params[slug.to_s] || fields_params[model_class.table_name]
      return unless model_fields

      requested = model_fields.to_s.split(",").map(&:strip)
      # Only allow fields that are in the allowed list
      valid_fields = requested.select { |f| allowed.include?(f) }

      if valid_fields.any?
        # Always include the primary key
        valid_fields.unshift(model_class.primary_key) unless valid_fields.include?(model_class.primary_key)
        # Also include the configured route key — sparse responses must stay
        # routable. No-op in the default path (route key == primary key).
        route_key = model_class.try(:rhino_resolved_route_key)
        if route_key && route_key.to_s != model_class.primary_key.to_s && !valid_fields.include?(route_key.to_s)
          valid_fields << route_key.to_s
        end
        @scope = @scope.select(valid_fields.map { |f| "#{model_class.table_name}.#{f}" })
      end
    end

    # ------------------------------------------------------------------
    # Eager loading: ?include=user,comments
    # ------------------------------------------------------------------

    def apply_includes
      include_param = params[:include]
      return unless include_param.present?

      allowed = model_class.try(:allowed_includes) || []
      return if allowed.empty?

      requested = include_param.to_s.split(",").map(&:strip)

      includes_list = []
      requested.each do |inc|
        base = resolve_base_include(inc, allowed)
        next unless base

        if inc.include?(".")
          # Nested include: 'comments.user' -> { comments: :user }
          parts = inc.split(".")
          nested = parts.reverse.inject { |inner, outer| { outer.to_sym => inner.to_sym } }
          includes_list << nested
        elsif inc.end_with?("Count") || inc.end_with?("Exists")
          # Count/Exists suffixes are handled separately in serialization
          next
        else
          includes_list << inc.to_sym
        end
      end

      @scope = @scope.includes(*includes_list) if includes_list.any?
    end

    # Coerce a single filter value to the column's type (e.g. string → integer).
    def coerce_filter_value(column, value)
      col = model_class.columns_hash[column]
      return value unless col

      case col.type
      when :integer, :bigint
        value.to_s.match?(/\A-?\d+\z/) ? value.to_i : value
      when :float, :decimal
        value.to_s.match?(/\A-?\d+(\.\d+)?\z/) ? value.to_f : value
      when :boolean
        ActiveModel::Type::Boolean.new.cast(value)
      else
        value
      end
    end

    # Coerce an array of filter values.
    def coerce_filter_values(column, values)
      values.map { |v| coerce_filter_value(column, v) }
    end

    # Resolve an include segment to the base relationship name.
    # Handles Count/Exists suffixes.
    def resolve_base_include(segment, allowed)
      return segment if allowed.include?(segment)

      # Check Count suffix
      if segment.end_with?("Count")
        base = segment.sub(/Count\z/, "")
        return base if allowed.include?(base)
      end

      # Check Exists suffix
      if segment.end_with?("Exists")
        base = segment.sub(/Exists\z/, "")
        return base if allowed.include?(base)
      end

      nil
    end
  end
end
