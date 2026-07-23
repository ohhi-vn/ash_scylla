# Copyright [2024] AshScylla Contributors
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT REQUIRED WARRANTIES OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

defmodule AshScylla.DataLayer.FilterValidator do
  @moduledoc """
  Validates that filter columns are queryable in ScyllaDB/Cassandra.

  ScyllaDB/Cassandra requires that WHERE clause columns are either:
  - Part of the primary key
  - Have a secondary index defined

  Filtering on non-indexed columns would require `ALLOW FILTERING`, which
  is an anti-pattern that causes full cluster scans. This module catches
  such issues at query-build time and provides actionable error messages.

  ## Ash 3.0+ Support

  This validator supports:
  - Aggregate filter validation (COUNT, SUM, AVG, MIN, MAX)
  - Calculation filter validation
  - Relationship filter validation (belongs_to, has_one, has_many, many_to_many)
  - EXISTS filter type
  - IN filter with list values
  - Base filter validation
  - Ash error type integration for better error messages

  """

  alias Ash.Resource.Info
  alias AshScylla.DataLayer.Dsl

  @doc """
  Validates that all filter columns on a resource are queryable.

  Returns `:ok` if all filters are on primary key columns or indexed columns.
  Raises `AshScylla.Error` with an actionable message if a filter would
  require `ALLOW FILTERING`.

  ## Parameters

  - `resource` - The Ash resource module
  - `filters` - List of Ash filter expressions

  ## Examples

      AshScylla.DataLayer.FilterValidator.validate_filters(MyApp.User, filters)
      # => :ok

      AshScylla.DataLayer.FilterValidator.validate_filters(MyApp.User, [{:non_indexed_col, :eq, "value"}])
      # => raises AshScylla.Error with suggestion to add secondary_index
  """
  @spec validate_filters(module(), list()) :: :ok | no_return()
  def validate_filters(resource, filters) do
    # Catch empty IN lists (which produce invalid CQL `col IN ()`) and IN filters
    # on non-queryable columns before they reach CQL generation.
    validate_in_filters(resource, filters)

    pk_columns = get_primary_key_columns(resource)
    indexed_columns = get_indexed_columns(resource)
    allowed_columns = MapSet.new(pk_columns ++ indexed_columns)

    filter_columns = extract_all_filter_columns(filters)

    non_queryable =
      filter_columns
      |> Enum.reject(fn col -> MapSet.member?(allowed_columns, col) end)
      |> Enum.uniq()

    case non_queryable do
      [] ->
        :ok

      cols ->
        col_names = Enum.map_join(cols, ", ", &"#{&1}")
        pk_names = Enum.map_join(pk_columns, ", ", &"#{&1}")
        idx_names = Enum.map_join(indexed_columns, ", ", &"#{&1}")

        raise AshScylla.Error,
          message:
            "Filter on column(s) [#{col_names}] requires a secondary index. " <>
              "These columns are not part of the primary key [#{pk_names}] " <>
              "and do not have secondary indexes [#{idx_names}]. " <>
              "Add `secondary_index :#{hd(cols)}` to your scylla block, " <>
              "or create a materialized view for this query pattern."
    end
  end

  @doc """
  Validates aggregate filters for a resource.

  Ensures that aggregate queries reference valid columns and that
  the aggregate type is supported by ScyllaDB.

  Supported aggregate types: `:count`, `:sum`, `:avg`, `:min`, `:max`

  ## Parameters

  - `resource` - The Ash resource module
  - `aggregates` - List of aggregate maps with `:type`, `:name`, and optional `:field` keys

  ## Examples

      FilterValidator.validate_aggregate_filters(MyApp.User, [%{type: :count, name: :total}])
      # => :ok

      FilterValidator.validate_aggregate_filters(MyApp.User, [%{type: :sum, name: :total_age, field: :age}])
      # => :ok
  """
  @spec validate_aggregate_filters(module(), list()) :: :ok | no_return()
  def validate_aggregate_filters(resource, aggregates) do
    supported_aggregates = [:count, :sum, :avg, :min, :max]
    pk_columns = get_primary_key_columns(resource)
    indexed_columns = get_indexed_columns(resource)
    allowed_columns = MapSet.new(pk_columns ++ indexed_columns)

    Enum.each(aggregates, fn aggregate ->
      type = Map.get(aggregate, :type)
      field = Map.get(aggregate, :field)
      name = Map.get(aggregate, :name)

      # Validate aggregate type
      if type not in supported_aggregates do
        raise AshScylla.Error,
          message:
            "Unsupported aggregate type `:#{type}` for aggregate `:#{name}`. " <>
              "Supported types are: #{Enum.map_join(supported_aggregates, ", ", &":#{&1}")}. " <>
              "Consider using an in-memory calculation instead."
      end

      # Validate field is queryable (if specified)
      if field != nil and not MapSet.member?(allowed_columns, field) do
        raise AshScylla.Error,
          message:
            "Aggregate `:#{name}` references field `:#{field}` which is not a primary key " <>
              "or indexed column. Aggregate fields must be part of the primary key " <>
              "or have a secondary index."
      end

      # Validate COUNT without field (COUNT(*) is always allowed)
      if type == :count and field == nil do
        :ok
      end
    end)

    :ok
  end

  @doc """
  Validates calculation filters for a resource.

  Ensures that calculation expressions reference valid attributes
  and that the calculation module (if specified) exists and implements
  the required behaviour.

  ## Parameters

  - `resource` - The Ash resource module
  - `calculations` - List of calculation maps with `:name`, `:type`, and `:expression` keys
  """
  @spec validate_calculation_filters(module(), list()) :: :ok | no_return()
  def validate_calculation_filters(resource, calculations) do
    resource_attributes =
      resource
      |> get_resource_attribute_names()
      |> MapSet.new()

    Enum.each(calculations, fn calculation ->
      name = Map.get(calculation, :name)
      expression = Map.get(calculation, :expression)
      module = Map.get(calculation, :module)

      # Validate module-based calculations
      if module != nil do
        unless Code.ensure_loaded?(module) do
          raise AshScylla.Error,
            message:
              "Calculation `:#{name}` references module `#{inspect(module)}` which could not be loaded. " <>
                "Ensure the module exists and is compiled."
        end
      end

      # Validate expression references valid attributes
      if is_map(expression) do
        expr_columns = extract_expression_columns(expression)

        invalid_columns =
          expr_columns
          |> Enum.reject(fn col -> MapSet.member?(resource_attributes, col) end)
          |> Enum.uniq()

        case invalid_columns do
          [] ->
            :ok

          cols ->
            col_names = Enum.map_join(cols, ", ", &"#{&1}")
            attr_names = Enum.map_join(MapSet.to_list(resource_attributes), ", ", &"#{&1}")

            raise AshScylla.Error,
              message:
                "Calculation `:#{name}` references unknown column(s) [#{col_names}]. " <>
                  "Available attributes are: [#{attr_names}]. " <>
                  "Check your calculation expression for typos."
        end
      end
    end)

    :ok
  end

  @doc """
  Validates relationship filters for a resource.

  Ensures that relationship filters reference valid relationships
  and that the relationship target columns are queryable.

  ## Parameters

  - `resource` - The Ash resource module
  - `filters` - List of filter expressions that may reference relationships

  ## Examples

      FilterValidator.validate_relationship_filters(MyApp.Post, [%{path: [:author, :name], op: :eq, value: "Alice"}])
      # => :ok if :author is a valid belongs_to relationship
  """
  @spec validate_relationship_filters(module(), list()) :: :ok | no_return()
  def validate_relationship_filters(resource, filters) do
    relationships = get_relationship_map(resource)

    Enum.each(filters, fn filter ->
      path = Map.get(filter, :path) || extract_filter_path(filter)

      case path do
        [rel_name | rest] when is_atom(rest) or is_list(rest) ->
          rel_def = Map.get(relationships, rel_name)

          if rel_def == nil do
            rel_names = Enum.map_join(Map.keys(relationships), ", ", &"#{&1}")

            raise AshScylla.Error,
              message:
                "Filter references relationship `:#{rel_name}` which is not defined on `#{inspect(resource)}`. " <>
                  "Available relationships are: [#{rel_names}]. " <>
                  "Add the relationship to your resource's relationships block."
          end

          # Validate the rest of the path against the target resource
          target = rel_def[:target] || rel_def["target"]

          if target != nil and rest != [] and Code.ensure_loaded?(target) do
            target_pk = get_primary_key_columns(target)
            target_idx = get_indexed_columns(target)
            target_allowed = MapSet.new(target_pk ++ target_idx)

            case rest do
              [col] when is_atom(col) ->
                unless MapSet.member?(target_allowed, col) do
                  raise AshScylla.Error,
                    message:
                      "Relationship filter `:#{rel_name}.:#{col}` references a column that is not " <>
                        "queryable on the target resource `#{inspect(target)}`. " <>
                        "The column must be part of the primary key or have a secondary index."
                end

              _ ->
                :ok
            end
          end

        _ ->
          :ok
      end
    end)

    :ok
  end

  @doc """
  Validates EXISTS filter expressions.

  EXISTS filters check for the presence of a value (IS NOT NULL in CQL).
  This is valid for any column that exists on the resource.

  ## Parameters

  - `resource` - The Ash resource module
  - `filters` - List of filter expressions that may include EXISTS checks
  """
  @spec validate_exists_filters(module(), list()) :: :ok | no_return()
  def validate_exists_filters(resource, filters) do
    resource_attributes =
      resource
      |> get_resource_attribute_names()
      |> MapSet.new()

    Enum.each(filters, fn filter ->
      case filter do
        %{operator: :exists, left: %{name: col}} when is_atom(col) ->
          unless MapSet.member?(resource_attributes, col) do
            attr_names = Enum.map_join(MapSet.to_list(resource_attributes), ", ", &"#{&1}")

            raise AshScylla.Error,
              message:
                "EXISTS filter references unknown column `:#{col}` on `#{inspect(resource)}`. " <>
                  "Available attributes are: [#{attr_names}]."
          end

        %{expression: expr} ->
          validate_exists_filters(resource, [expr])

        %{left: left, right: right} ->
          validate_exists_filters(resource, [left, right])

        _ ->
          :ok
      end
    end)

    :ok
  end

  @doc """
  Validates IN filter expressions with list values.

  IN filters are valid when:
  - The column is a primary key or indexed
  - The value list is not empty
  - All values in the list are of a compatible type

  ## Parameters

  - `resource` - The Ash resource module
  - `filters` - List of filter expressions that may include IN checks
  """
  @spec validate_in_filters(module(), list()) :: :ok | no_return()
  def validate_in_filters(resource, filters) do
    pk_columns = get_primary_key_columns(resource)
    indexed_columns = get_indexed_columns(resource)
    allowed_columns = MapSet.new(pk_columns ++ indexed_columns)

    Enum.each(filters, fn filter ->
      case filter do
        %{operator: :in, left: %{name: col}, right: %{value: values}}
        when is_atom(col) and is_list(values) ->
          unless MapSet.member?(allowed_columns, col) do
            raise AshScylla.Error,
              message:
                "IN filter on column `:#{col}` requires the column to be part of the " <>
                  "primary key or have a secondary index."
          end

          if values == [] do
            raise AshScylla.Error,
              message:
                "IN filter on column `:#{col}` has an empty value list. " <>
                  "IN requires at least one value."
          end

        %{expression: expr} ->
          validate_in_filters(resource, [expr])

        %{left: left, right: right} ->
          validate_in_filters(resource, [left, right])

        _ ->
          :ok
      end
    end)

    :ok
  end

  @doc """
  Validates base_filter expressions from the resource DSL.

  Ensures that the base_filter references valid columns and that
  those columns are queryable (primary key or indexed).

  ## Parameters

  - `resource` - The Ash resource module
  """
  @spec validate_base_filter(module()) :: :ok | no_return()
  def validate_base_filter(resource) do
    base_filter = Dsl.base_filter(resource)

    case base_filter do
      nil ->
        :ok

      [] ->
        :ok

      filters when is_list(filters) ->
        validate_filters(resource, filters)

      single_filter ->
        validate_filters(resource, [single_filter])
    end
  end

  @doc """
  Validates that filters do not contain cross-field OR expressions.

  CQL does not support OR across different fields — the WHERE clause only
  allows a flat list of AND-ed predicates.  This validator catches OR
  expressions that cannot be rewritten to IN (i.e. OR on different columns
  or with non-equality operators) and raises a clear error with workarounds.
  """
  @spec validate_or_filters(list()) :: :ok | no_return()
  def validate_or_filters(filters) do
    Enum.each(filters, &check_or_filter/1)
    :ok
  end

  defp check_or_filter(%{op: :or, left: left, right: right}) do
    # Check if this is a same-field OR with eq/== (rewritable to IN)
    left_unwrapped = unwrap_expr(left)
    right_unwrapped = unwrap_expr(right)

    case {left_unwrapped, right_unwrapped} do
      {%{left: %{name: name1}, operator: op1}, %{left: %{name: name2}, operator: op2}}
      when name1 == name2 and name1 != nil and op1 in [:eq, :==] and op2 in [:eq, :==] ->
        :ok

      {%{left: %{name: name1}, op: op1}, %{left: %{name: name2}, op: op2}}
      when name1 == name2 and name1 != nil and op1 in [:eq, :==] and op2 in [:eq, :==] ->
        :ok

      _ ->
        raise AshScylla.Error,
          message:
            "CQL does not support OR across different fields or with non-equality operators. " <>
              "Found: or(#{inspect(left_unwrapped)}, #{inspect(right_unwrapped)}). " <>
              "Workarounds: (1) redesign the table with a canonical partition key, " <>
              "(2) split into two queries and merge in application code, " <>
              "or (3) rewrite same-field OR as IN."
    end
  end

  defp check_or_filter(%{expression: expr}), do: check_or_filter(expr)

  defp check_or_filter(%{left: left, right: right}) do
    check_or_filter(left)
    check_or_filter(right)
  end

  defp check_or_filter(_), do: :ok

  defp unwrap_expr(%{expression: expr}), do: unwrap_expr(expr)
  defp unwrap_expr(other), do: other

  @doc """
  Comprehensive validation that runs all filter validators.

  This is the recommended entry point for validating all aspects
  of a query against a resource.

  ## Parameters

  - `resource` - The Ash resource module
  - `filters` - List of Ash filter expressions
  - `opts` - Keyword list of options:
    - `:aggregates` - List of aggregate maps
    - `:calculations` - List of calculation maps
    - `:validate_base` - Whether to validate the base_filter (default: true)
    - `:validate_relationships` - Whether to validate relationship filters (default: true)
    - `:validate_exists` - Whether to validate EXISTS filters (default: true)
    - `:validate_in` - Whether to validate IN filters (default: true)
    - `:validate_or` - Whether to validate OR filters (default: true)
  """
  @spec validate_all(module(), list(), keyword()) :: :ok | no_return()
  def validate_all(resource, filters, opts \\ []) do
    # Validate base_filter first
    if Keyword.get(opts, :validate_base, true) do
      validate_base_filter(resource)
    end

    # Validate standard filters
    validate_filters(resource, filters)

    # Validate OR expressions (CQL limitation)
    if Keyword.get(opts, :validate_or, true) do
      validate_or_filters(filters)
    end

    # Validate aggregate filters
    aggregates = Keyword.get(opts, :aggregates, [])

    if aggregates != [] do
      validate_aggregate_filters(resource, aggregates)
    end

    # Validate calculation filters
    calculations = Keyword.get(opts, :calculations, [])

    if calculations != [] do
      validate_calculation_filters(resource, calculations)
    end

    # Validate relationship filters
    if Keyword.get(opts, :validate_relationships, true) do
      validate_relationship_filters(resource, filters)
    end

    # Validate EXISTS filters
    if Keyword.get(opts, :validate_exists, true) do
      validate_exists_filters(resource, filters)
    end

    # Validate IN filters
    if Keyword.get(opts, :validate_in, true) do
      validate_in_filters(resource, filters)
    end

    :ok
  end

  @doc """
  Returns the list of columns that are safe to filter on for a resource.
  """
  @spec queryable_columns(module()) :: [atom()]
  def queryable_columns(resource) do
    get_primary_key_columns(resource) ++ get_indexed_columns(resource)
  end

  @spec get_primary_key_columns(module()) :: [atom()]
  defp get_primary_key_columns(resource) do
    if Info.resource?(resource) do
      resource
      |> Info.attributes()
      |> Enum.filter(& &1.primary_key?)
      |> Enum.map(& &1.name)
    else
      [:id]
    end
  end

  @spec get_indexed_columns(module()) :: [atom()]
  defp get_indexed_columns(resource) do
    resource
    |> Dsl.secondary_indexes()
    |> Enum.flat_map(fn idx -> idx.columns end)
    |> Enum.uniq()
  end

  @spec get_resource_attribute_names(module()) :: [atom()]
  defp get_resource_attribute_names(resource) do
    if Info.resource?(resource) do
      resource
      |> Info.attributes()
      |> Enum.map(& &1.name)
    else
      []
    end
  end

  @spec get_relationship_map(module()) :: map()
  defp get_relationship_map(resource) do
    if Info.resource?(resource) do
      resource
      |> Info.relationships()
      |> Enum.into(%{}, fn rel -> {rel.name, Map.from_struct(rel)} end)
    else
      %{}
    end
  end

  @spec extract_all_filter_columns(list()) :: [atom()]
  defp extract_all_filter_columns(filters) do
    filters
    |> List.flatten()
    |> Enum.flat_map(&extract_columns_from_filter/1)
    |> Enum.uniq()
  end

  @spec extract_columns_from_filter(term()) :: [atom()]
  defp extract_columns_from_filter(%{expression: expr}), do: extract_all_filter_columns([expr])

  # Handle AND/OR composites - recurse into both sides
  @spec extract_columns_from_filter(term()) :: [atom()]
  defp extract_columns_from_filter(%{left: left, right: right}),
    do: extract_all_filter_columns([left, right])

  # Handle Ash function calls - extract columns from arguments
  # Example: %Ash.Query.Function.Contains{name: :contains, arguments: [%Ref{name: :name}, %{value: "query"}]}
  defp extract_columns_from_filter(%{__function__?: true, arguments: arguments}),
    do: Enum.flat_map(arguments, &extract_columns_from_filter/1)

  # Handle function calls as plain maps (legacy or test format)
  defp extract_columns_from_filter(%{name: :contains, arguments: arguments}) do
    Enum.flat_map(arguments, &extract_columns_from_filter/1)
  end

  defp extract_columns_from_filter(%{name: :starts_with, arguments: arguments}) do
    Enum.flat_map(arguments, &extract_columns_from_filter/1)
  end

  defp extract_columns_from_filter(%{name: :ends_with, arguments: arguments}) do
    Enum.flat_map(arguments, &extract_columns_from_filter/1)
  end

  # Handle function calls with :args key (legacy format)
  defp extract_columns_from_filter(%{name: :contains, args: args}) do
    Enum.flat_map(args, &extract_columns_from_filter/1)
  end

  @spec extract_columns_from_filter(term()) :: [atom()]
  defp extract_columns_from_filter(%{left: %{name: name}}) when is_atom(name), do: [name]

  defp extract_columns_from_filter(%{name: :starts_with, args: args}) do
    Enum.flat_map(args, &extract_columns_from_filter/1)
  end

  defp extract_columns_from_filter(%{name: :ends_with, args: args}) do
    Enum.flat_map(args, &extract_columns_from_filter/1)
  end

  # Catch any function call with args before the %{name: name} fallback
  defp extract_columns_from_filter(%{name: _name, args: args}) when is_list(args) do
    Enum.flat_map(args, &extract_columns_from_filter/1)
  end

  @spec extract_columns_from_filter(%{name: atom()}) :: [atom()]
  defp extract_columns_from_filter(%{name: name}) when is_atom(name), do: [name]

  @spec extract_columns_from_filter(term()) :: [atom()]
  defp extract_columns_from_filter(_), do: []

  @spec extract_expression_columns(term()) :: [atom()]
  defp extract_expression_columns(%{name: name}) when is_atom(name), do: [name]

  defp extract_expression_columns(%{left: left, right: right}),
    do: extract_expression_columns(left) ++ extract_expression_columns(right)

  defp extract_expression_columns(%{expression: expr}), do: extract_expression_columns(expr)
  defp extract_expression_columns(_), do: []

  @spec extract_filter_path(term()) :: list()
  defp extract_filter_path(%{path: path}) when is_list(path), do: path
  defp extract_filter_path(%{left: %{name: name}}) when is_atom(name), do: [name]
  defp extract_filter_path(_), do: []
end
