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
      requested = params[:scope].presence
      name = requested ? requested.to_s.underscore : model_class.try(:default_rhino_scope)
      return unless name

      allowed = model_class.try(:allowed_scopes) || {}
      entry = allowed[name]
      # The default scope is implicitly allowed when requested by name.
      entry ||= name.to_sym if name == model_class.try(:default_rhino_scope)

      # Echo the client's wire name (not the underscored form) in the error.
      raise Rhino::ScopeNotAllowedError, (requested ? requested.to_s : name) if entry.nil?

      user = defined?(RequestStore) ? RequestStore.store[:rhino_current_user] : nil

      @scope =
        case entry
        when Symbol
          # Whitelisted AR scope. Client input never reaches public_send unless the
          # developer declared it via rhino_scopes. .merge composes with default_scopes.
          @scope.merge(model_class.public_send(entry))
        when Proc
          entry.call(@scope, user)
        else
          entry.new.apply(@scope) # Rhino::ResourceScope subclass (user/org/role helpers)
        end
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

      apply_sort_string(default)
    end

    def apply_sorts
      sort_param = params[:sort]
      return unless sort_param.present?

      apply_sort_string(sort_param.to_s)
    end

    def apply_sort_string(sort_string)
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

        next unless allowed.empty? || allowed.include?(column)

        @scope = @scope.order(column => direction)
      end
    end

    # ------------------------------------------------------------------
    # Search: ?search=term
    # ------------------------------------------------------------------

    def apply_search
      search_term = params[:search]
      return unless search_term.present?

      columns = model_class.try(:allowed_search) || []
      return if columns.empty?

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
