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

defmodule AshScylla.DataLayer.QueryBuilder do
  @moduledoc """
  Query building functions for AshScylla data layer.

  Provides optimized query building with filter-to-CQL conversion,
  prepared statement support, token-based pagination, aggregate queries,
  and support for Ash 3.0+ features including base_filter, select, distinct,
  keyset pagination, group by, CONTAINS/CONTAINS KEY, and TOKEN() functions.

  ## Secondary Index Support

  When filtering on non-primary key columns, this module checks if a
  secondary index exists and generates appropriate CQL. ScyllaDB/Cassandra
  can use secondary indexes for equality checks (=) but not for range queries.

  ## Aggregate Queries

  Supports COUNT, SUM, AVG, MIN, MAX aggregate functions with optional
  GROUP BY clauses for per-partition aggregation.

  ## Keyset Pagination

  Token-based pagination using the CQL TOKEN() function on partition keys,
  enabling efficient pagination without OFFSET overhead.
  """

  require Logger

  alias AshScylla.DataLayer
  alias AshScylla.DataLayer.Dsl
  alias AshScylla.Identifier

  @doc """
  Builds an optimized CQL query from the data layer query struct.

  Supports:
  - Column selection (`:select`)
  - DISTINCT on partition key columns
  - Keyset pagination (`:keyset`)
  - Aggregate queries (`:aggregates`)
  - GROUP BY for aggregate queries
  - Base filter from resource DSL
  - Multiple ORDER BY columns
  - IN queries with multiple values
  - CONTAINS / CONTAINS KEY for collection types
  - TOKEN() function for partition key queries
  """
  @spec build_optimized_query(DataLayer.t()) :: {String.t(), list()}
  def build_optimized_query(%DataLayer{
        resource: resource,
        table: table,
        filters: filters,
        sorts: sorts,
        limit: limit,
        offset: offset,
        select: select,
        distinct: distinct,
        keyset: keyset,
        aggregates: aggregates,
        group_by: group_by
      }) do
    Logger.debug("AshScylla: Building optimized query for table #{table}")

    # Build SELECT clause (handles select, distinct, and aggregates)
    {select_clause, agg_params} =
      build_select_clause(table, select, distinct, aggregates)

    base_query = "SELECT #{select_clause} FROM #{table}"

    # Build WHERE clause from filters
    {where_clause, params} = build_where_clause(filters)

    # Use IO list for efficient query assembly
    query_acc = [base_query]

    query_acc =
      if where_clause != "" do
        [query_acc, " WHERE ", where_clause]
      else
        query_acc
      end

    # Build GROUP BY clause for aggregate queries
    {group_clause, group_params} = build_group_by(group_by)

    query_acc =
      if group_clause != "" do
        [query_acc, " GROUP BY ", group_clause]
      else
        query_acc
      end

    params = params ++ agg_params ++ group_params

    # Detect secondary index scan — ScyllaDB does NOT support ORDER BY
    # when querying via a secondary index. Strip the order clause and warn.
    {order_clause, order_params} =
      if resource != nil and sorts != [] and sorts != nil and
           secondary_index_scan?(resource, filters) do
        Logger.warning(
          "AshScylla: ScyllaDB does not support ORDER BY with secondary index scans; " <>
            "dropping ORDER BY for query on #{table}"
        )

        {"", []}
      else
        build_order_by(sorts)
      end

    query_acc =
      if order_clause != "" do
        [query_acc, " ORDER BY ", order_clause]
      else
        query_acc
      end

    params = params ++ order_params

    # Add LIMIT
    {query_acc, params} =
      if limit do
        Logger.debug("AshScylla: Adding LIMIT #{limit}")
        {[query_acc, " LIMIT ?"], params ++ [limit]}
      else
        {query_acc, params}
      end

    # Add keyset pagination (token-based)
    {query_acc, params} =
      if keyset do
        {keyset_clause, keyset_params} = build_keyset_clause(keyset)
        {[query_acc, " ", keyset_clause], params ++ keyset_params}
      else
        {query_acc, params}
      end

    # Append ALLOW FILTERING when enabled and a secondary index scan is detected.
    query_acc =
      if resource != nil and Dsl.allow_filtering(resource) and
           secondary_index_scan?(resource, filters) do
        Logger.debug("AshScylla: Appending ALLOW FILTERING for secondary index scan on #{table}")
        [query_acc, " ALLOW FILTERING"]
      else
        query_acc
      end

    query = IO.iodata_to_binary(query_acc)

    # Add OFFSET (note: OFFSET in CQL requires special handling)
    if offset do
      Logger.warning(
        "AshScylla: OFFSET is not natively supported in ScyllaDB/Cassandra; ignoring offset=#{offset}"
      )

      {query, params}
    else
      {query, params}
    end
  end

  # ============================================================================
  # SELECT clause builders
  # ============================================================================

  @spec build_select_clause(String.t(), list() | nil, list() | nil, list() | nil) ::
          {String.t(), list()}
  defp build_select_clause(_table, nil, nil, nil) do
    {"*", []}
  end

  defp build_select_clause(_table, [], nil, nil) do
    {"*", []}
  end

  defp build_select_clause(_table, [], nil, aggregates)
       when aggregates == nil or aggregates == [] do
    {"*", []}
  end

  defp build_select_clause(_table, columns, nil, aggregates)
       when is_list(columns) and (aggregates == nil or aggregates == []) do
    {Enum.map_join(columns, ", ", &"#{&1}"), []}
  end

  defp build_select_clause(_table, nil, distinct_columns, nil) when is_list(distinct_columns) do
    cols = Enum.map_join(distinct_columns, ", ", &"#{&1}")
    {"DISTINCT #{cols}", []}
  end

  defp build_select_clause(_table, nil, nil, aggregates)
       when is_list(aggregates) and length(aggregates) > 0 do
    {agg_clause, params} =
      aggregates
      |> Enum.map(fn
        %{kind: :count, name: name, field: nil} ->
          {"COUNT(*) AS #{name}", []}

        %{kind: :count, name: name, field: field} ->
          {"COUNT(#{field}) AS #{name}", []}

        %{kind: :sum, name: name, field: field} ->
          {"SUM(#{field}) AS #{name}", []}

        %{kind: :avg, name: name, field: field} ->
          {"AVG(#{field}) AS #{name}", []}

        %{kind: :min, name: name, field: field} ->
          {"MIN(#{field}) AS #{name}", []}

        %{kind: :max, name: name, field: field} ->
          {"MAX(#{field}) AS #{name}", []}

        %{kind: kind, name: name} ->
          Logger.warning("AshScylla: Unsupported aggregate kind: #{kind}")
          {"COUNT(*) AS #{name}", []}
      end)
      |> Enum.reduce({"", []}, fn {c, p}, {acc_c, acc_p} ->
        {[acc_c, ", ", c], acc_p ++ p}
      end)

    # Remove leading ", "
    agg_clause =
      agg_clause
      |> IO.iodata_to_binary()
      |> String.trim_leading(", ")

    {agg_clause, params}
  end

  defp build_select_clause(_table, columns, nil, aggregates)
       when is_list(columns) and is_list(aggregates) and length(aggregates) > 0 do
    col_clause = Enum.map_join(columns, ", ", &"#{&1}")

    {agg_clause, params} =
      aggregates
      |> Enum.map(fn
        %{kind: :count, name: name, field: nil} ->
          {"COUNT(*) AS #{name}", []}

        %{kind: :count, name: name, field: field} ->
          {"COUNT(#{field}) AS #{name}", []}

        %{kind: :sum, name: name, field: field} ->
          {"SUM(#{field}) AS #{name}", []}

        %{kind: :avg, name: name, field: field} ->
          {"AVG(#{field}) AS #{name}", []}

        %{kind: :min, name: name, field: field} ->
          {"MIN(#{field}) AS #{name}", []}

        %{kind: :max, name: name, field: field} ->
          {"MAX(#{field}) AS #{name}", []}

        %{kind: _kind, name: name} ->
          {"COUNT(*) AS #{name}", []}
      end)
      |> Enum.reduce({"", []}, fn {c, p}, {acc_c, acc_p} ->
        {[acc_c, ", ", c], acc_p ++ p}
      end)

    agg_clause =
      agg_clause
      |> IO.iodata_to_binary()
      |> String.trim_leading(", ")

    {"#{col_clause}, #{agg_clause}", params}
  end

  defp build_select_clause(_table, _select, _distinct, _aggregates) do
    {"*", []}
  end

  # ============================================================================
  # WHERE clause builders
  # ============================================================================

  @doc """
  Builds WHERE clause from Ash filters.
  """
  @spec build_where_clause(list()) :: {String.t(), list()}
  def build_where_clause(filters) do
    case filters do
      [] ->
        {"", []}

      _ ->
        {clauses, params} =
          filters
          |> Enum.reduce({[], []}, fn filter, {acc_c, acc_p} ->
            case filter_to_cql(filter) do
              {:error, {:unknown_filter, unknown}} ->
                Logger.warning(
                  "AshScylla: Skipping unknown filter expression: #{inspect(unknown)}"
                )

                {acc_c, acc_p}

              {c, p} ->
                {[c | acc_c], Enum.reverse(p, acc_p)}
            end
          end)

        joined_clauses =
          clauses
          |> Enum.reverse()
          |> Enum.intersperse(" AND ")
          |> IO.iodata_to_binary()

        {joined_clauses, :lists.reverse(params)}
    end
  end

  # ============================================================================
  # ORDER BY builder (supports multiple columns)
  # ============================================================================

  @doc """
  Builds ORDER BY clause from sort items.

  Sort items can be:
  - Maps with `:field` and `:direction` keys
  - Tuples like `{field, direction}` (Ash standard format)
  - Bare atoms (default to ASC)
  - Maps with only `:field` key (default to ASC)

  Supports multiple columns for compound ordering.
  """
  @spec build_order_by(list()) :: {String.t(), list()}
  def build_order_by(sorts) do
    case sorts do
      [] ->
        {"", []}

      _ ->
        clauses =
          Enum.map(sorts, fn sort_item ->
            case sort_item do
              %{field: field, direction: direction} ->
                "#{cql_identifier(field)} #{direction}"

              {field, direction} when is_atom(field) ->
                "#{cql_identifier(field)} #{direction}"

              %{field: field} ->
                "#{cql_identifier(field)} ASC"

              {field} when is_atom(field) ->
                "#{cql_identifier(field)} ASC"

              other ->
                Logger.warning(
                  "AshScylla: Unexpected sort item format: #{inspect(other)}, skipping"
                )

                nil
            end
          end)
          |> Enum.reject(&is_nil/1)

        {Enum.join(clauses, ", "), []}
    end
  end

  # ============================================================================
  # GROUP BY builder
  # ============================================================================

  @doc """
  Builds GROUP BY clause for aggregate queries.
  """
  @spec build_group_by(list() | nil) :: {String.t(), list()}
  def build_group_by(nil), do: {"", []}
  def build_group_by([]), do: {"", []}

  def build_group_by(columns) when is_list(columns) do
    {Enum.map_join(columns, ", ", &cql_identifier(&1)), []}
  end

  # ============================================================================
  # Keyset (token-based) pagination builder
  # ============================================================================

  @doc """
  Builds keyset pagination clause using TOKEN() function.

  Keyset pagination is more efficient than OFFSET for large datasets.
  It uses the CQL TOKEN() function on partition keys to fetch pages.

  ## Examples

      # For a single partition key column:
      build_keyset_clause(%{partition_keys: [:id], values: [last_id], direction: :after})
      # => {"WHERE TOKEN(id) > TOKEN(?)", [last_id]}

      # For composite partition keys:
      build_keyset_clause(%{partition_keys: [:org_id, :id], values: [last_org, last_id], direction: :after})
      # => {"WHERE TOKEN(org_id, id) > TOKEN(?, ?)", [last_org, last_id]}
  """
  @spec build_keyset_clause(map()) :: {String.t(), list()}
  def build_keyset_clause(%{partition_keys: keys, values: values, direction: direction})
      when is_list(keys) and is_list(values) do
    token_op = if direction == :before, do: "<", else: ">"

    key_list = Enum.map_join(keys, ", ", &"#{&1}")
    placeholder_list = Enum.map_join(Enum.to_list(1..length(values)), ", ", fn _ -> "?" end)

    {"WHERE TOKEN(#{key_list}) #{token_op} TOKEN(#{placeholder_list})", values}
  end

  def build_keyset_clause(%{partition_keys: keys, values: values}) do
    build_keyset_clause(%{partition_keys: keys, values: values, direction: :after})
  end

  # ============================================================================
  # Secondary index support
  # ============================================================================

  @doc """
  Checks if a filter can use secondary indexes.

  Returns `{:ok, indexed_columns}` if the filter can use indexes,
  or `{:error, reason}` if it cannot.
  """
  @spec can_use_secondary_index?(term(), list()) :: {:ok, list()} | {:error, term()}
  def can_use_secondary_index?(resource, filters) do
    indexed_columns =
      resource
      |> Dsl.secondary_indexes()
      |> Enum.flat_map(fn idx -> idx.columns end)
      |> MapSet.new()

    filter_columns = get_filter_columns(filters)

    case filter_columns do
      [] ->
        {:error, :no_filters}

      cols ->
        all_indexed = cols |> Enum.all?(fn col -> MapSet.member?(indexed_columns, col) end)

        if all_indexed do
          {:ok, cols}
        else
          non_indexed = cols |> Enum.reject(fn col -> MapSet.member?(indexed_columns, col) end)
          {:error, {:missing_indexes, non_indexed}}
        end
    end
  end

  # ============================================================================
  # Filter to CQL conversion
  # ============================================================================

  @operator_mapping %{
    :eq => "=",
    :== => "=",
    :not_eq => "!=",
    :!= => "!=",
    :gt => ">",
    :> => ">",
    :gte => ">=",
    :>= => ">=",
    :lt => "<",
    :< => "<",
    :lte => "<=",
    :<= => "<=",
    :contains => "LIKE",
    :contains_key => "CONTAINS KEY",
    :starts_with => "LIKE",
    :ends_with => "LIKE"
  }

  @operator_values %{
    :eq => "?",
    :== => "?",
    :not_eq => "?",
    :!= => "?",
    :gt => "?",
    :> => "?",
    :gte => "?",
    :>= => "?",
    :lt => "?",
    :< => "?",
    :lte => "?",
    :<= => "?",
    :contains => "?",
    :contains_key => "?",
    :starts_with => "?",
    :ends_with => "?"
  }

  # Helper to resolve operator CQL syntax for raw values (not %{value: ...} maps).
  # Uses multi-clause function to avoid LSP type-narrowing warnings.
  defp operator_cql(:is_nil, right, _params) when right in [true, false] do
    if right, do: {"IS NULL", "", []}, else: {"IS NOT NULL", "", []}
  end

  # LIKE operators: embed wildcards in the parameter value, not in the CQL string.
  # CQL does not support `column LIKE %?` — the `%` must be part of the bound value.
  defp operator_cql(:starts_with, _right, params) do
    {rest, [value]} = Enum.split(params, -1)
    {"LIKE", "?", rest ++ ["%" <> value]}
  end

  defp operator_cql(:ends_with, _right, params) do
    {rest, [value]} = Enum.split(params, -1)
    {"LIKE", "?", rest ++ [value <> "%"]}
  end

  defp operator_cql(:contains, _right, params) do
    {rest, [value]} = Enum.split(params, -1)
    {"LIKE", "?", rest ++ ["%" <> value <> "%"]}
  end

  defp operator_cql(:contains_key, _right, params) do
    {"CONTAINS KEY", "?", params}
  end

  defp operator_cql(op, _right, params) do
    {Map.get(@operator_mapping, op, "="), Map.get(@operator_values, op, "?"), params}
  end

  @doc """
  Converts Ash filter expressions to CQL (safe version).

  Returns `{cql, params}` on success or `{:error, {:unknown_filter, term()}}` on failure.

  Supports:
  - Standard comparison operators: eq, not_eq, gt, gte, lt, lte
  - IN with list values
  - CONTAINS for collection type filtering
  - CONTAINS KEY for map key filtering
  - TOKEN() function for partition key queries
  - EXISTS for existence checks
  - AND/OR boolean combinations
  - Nested expressions
  """
  @spec filter_to_cql(term()) :: {String.t(), list()} | {:error, {:unknown_filter, term()}}
  def filter_to_cql(%{expression: expression}) do
    expression
    |> filter_to_cql()
    |> maybe_iodata_to_binary()
  end

  def filter_to_cql(%{op: op, left: left, right: right}) do
    case filter_to_cql(left) do
      {:error, _} = error ->
        error

      {left_cql, left_params} ->
        case filter_to_cql(right) do
          {:error, _} = error ->
            error

          {right_cql, right_params} ->
            case op do
              :and ->
                {[left_cql, " AND ", right_cql], left_params ++ right_params}

              :or ->
                {["(", left_cql, " OR ", right_cql, ")"], left_params ++ right_params}

              _ ->
                filter_to_cql(%{operator: op, left: left, right: right})
            end
        end
    end
    |> maybe_iodata_to_binary()
  end

  def filter_to_cql(%{operator: op, left: left, right: right}) do
    case filter_to_cql(left) do
      {:error, _} = error ->
        error

      {left_cql, left_params} ->
        case filter_to_cql(right) do
          {:error, {:unknown_filter, raw_value}} ->
            # Raw value on the right side of an operator (e.g. DateTime, string, number)
            # Handle operators that need special CQL syntax with raw values
            case op do
              :in when is_list(raw_value) ->
                build_in_clause(left_cql, left_params ++ raw_value)

              :in when is_struct(raw_value, MapSet) ->
                raw_value
                |> MapSet.to_list()
                |> then(&build_in_clause(left_cql, left_params ++ &1))

              :is_nil when raw_value in [true, false] ->
                if raw_value,
                  do: {"#{left_cql} IS NULL", left_params},
                  else: {"#{left_cql} IS NOT NULL", left_params}

              :starts_with ->
                {"#{left_cql} LIKE ?", left_params ++ ["%" <> raw_value]}

              :ends_with ->
                {"#{left_cql} LIKE ?", left_params ++ [raw_value <> "%"]}

              :contains ->
                {"#{left_cql} LIKE ?", left_params ++ ["%" <> raw_value <> "%"]}

              :contains_key ->
                {"#{left_cql} CONTAINS KEY ?", left_params ++ [raw_value]}

              :exists ->
                {"#{left_cql} IS NOT NULL", left_params}

              _ ->
                cql_op = Map.get(@operator_mapping, op, "=")
                cql_val = Map.get(@operator_values, op, "?")
                {"#{left_cql} #{cql_op} #{cql_val}", left_params ++ [raw_value]}
            end

          {_right_cql, right_params} ->
            case {op, right} do
              {:in, %{value: values}} when is_list(values) ->
                build_in_clause(left_cql, left_params ++ values)

              {:in, values} when is_list(values) ->
                build_in_clause(left_cql, left_params ++ values)

              {:in, %MapSet{} = values} ->
                values
                |> MapSet.to_list()
                |> then(&build_in_clause(left_cql, left_params ++ &1))

              {:is_nil, %{value: true}} ->
                {"#{left_cql} IS NULL", left_params}

              {:is_nil, %{value: false}} ->
                {"#{left_cql} IS NOT NULL", left_params}

              {:is_nil, true} ->
                {"#{left_cql} IS NULL", left_params}

              {:is_nil, false} ->
                {"#{left_cql} IS NOT NULL", left_params}

              {:token, %{value: keys}} when is_list(keys) ->
                build_token_clause(Enum.map(left_cql, & &1), keys)

              {:token, keys} when is_list(keys) ->
                build_token_clause(Enum.map(left_cql, & &1), keys)

              {:exists, _} ->
                {"#{left_cql} IS NOT NULL", left_params}

              {:starts_with, %{value: value}} ->
                {"#{left_cql} LIKE ?", left_params ++ ["%" <> value]}

              {:ends_with, %{value: value}} ->
                {"#{left_cql} LIKE ?", left_params ++ [value <> "%"]}

              {:contains, %{value: value}} ->
                {"#{left_cql} LIKE ?", left_params ++ ["%" <> value <> "%"]}

              {:contains_key, %{value: value}} ->
                {"#{left_cql} CONTAINS KEY ?", left_params ++ [value]}

              _ ->
                # Handle operators that need special CQL syntax even when right side
                # is a raw value (not a %{value: ...} map)
                {cql_op, cql_val, extra_params} =
                  operator_cql(op, right, right_params)

                {"#{left_cql} #{cql_op} #{cql_val}", left_params ++ extra_params}
            end
        end
    end
    |> maybe_iodata_to_binary()
  end

  def filter_to_cql(%{op: op, name: name, right: right}) do
    filter_to_cql(%{operator: op, left: %{name: name}, right: right})
  end

  def filter_to_cql(%Ash.Query.Ref{attribute: attribute}) do
    {cql_identifier(attribute_name(attribute)), []}
  end

  def filter_to_cql(%{value: value}) do
    {"?", [value]}
  end

  def filter_to_cql(%{name: name}) do
    {cql_identifier(name), []}
  end

  def filter_to_cql(unknown) do
    # Raw value — return it as a parameter placeholder so parent operators can use it
    # This handles cases like: %{operator: :eq, left: %{name: :status}, right: "active"}
    # where the right side is a raw value, not a filter expression
    case unknown do
      nil ->
        {"?", [nil]}

      val when is_boolean(val) ->
        {"?", [val]}

      val when is_number(val) ->
        {"?", [val]}

      val when is_binary(val) ->
        {"?", [val]}

      val when is_struct(val, DateTime) ->
        {"?", [val]}

      val when is_struct(val, Date) ->
        {"?", [val]}

      val when is_struct(val, Time) ->
        {"?", [val]}

      val when is_struct(val, Decimal) ->
        {"?", [val]}

      val when is_list(val) ->
        {"?", [val]}

      val when is_map(val) ->
        {"?", [val]}

      val when is_tuple(val) ->
        {"?", [val]}

      val when is_atom(val) ->
        {"?", [val]}

      _ ->
        Logger.warning("AshScylla: Unknown filter expression: #{inspect(unknown)}")
        {:error, {:unknown_filter, unknown}}
    end
  end

  @doc """
  Converts Ash filter expressions to CQL (bang version).

  Raises `ArgumentError` on unknown filter expressions.
  """
  @spec filter_to_cql!(term()) :: {String.t(), list()}
  def filter_to_cql!(filter) do
    case filter_to_cql(filter) do
      {:error, {:unknown_filter, unknown}} ->
        raise ArgumentError, "Unknown filter expression: #{inspect(unknown)}"

      result ->
        result
    end
  end

  # ============================================================================
  # Base filter support
  # ============================================================================

  @doc """
  Applies the base_filter from the resource DSL to the query filters.

  The base_filter is prepended to the query filters so it is always applied.
  """
  @spec apply_base_filter(list(), term()) :: list()
  def apply_base_filter(filters, nil), do: filters
  def apply_base_filter(filters, []), do: filters

  def apply_base_filter(filters, base_filter) when is_list(base_filter) do
    base_filter ++ filters
  end

  def apply_base_filter(filters, base_filter) do
    [base_filter | filters]
  end

  # ============================================================================
  # Aggregate query support
  # ============================================================================

  @doc """
  Builds an aggregate CQL query.

  Supports COUNT, SUM, AVG, MIN, MAX with optional GROUP BY.

  ## Examples

      build_aggregate_query("users", "COUNT(*) AS total", "WHERE status = ?", ["active"])
      # => {"SELECT COUNT(*) AS total FROM users WHERE status = ?", ["active"]}
  """
  @spec build_aggregate_query(String.t(), String.t(), String.t(), list()) :: {String.t(), list()}
  def build_aggregate_query(table, agg_expression, where_clause, params) do
    base = "SELECT #{agg_expression} FROM #{table}"

    query =
      if where_clause != "" do
        "#{base} WHERE #{where_clause}"
      else
        base
      end

    {query, params}
  end

  @doc """
  Converts aggregate type and field to CQL aggregate expression.
  """
  @spec aggregate_to_cql(atom(), atom() | nil) :: String.t()
  def aggregate_to_cql(:count, nil), do: "COUNT(*)"
  def aggregate_to_cql(:count, field), do: "COUNT(#{field})"
  def aggregate_to_cql(:sum, field), do: "SUM(#{field})"
  def aggregate_to_cql(:avg, field), do: "AVG(#{field})"
  def aggregate_to_cql(:min, field), do: "MIN(#{field})"
  def aggregate_to_cql(:max, field), do: "MAX(#{field})"

  def aggregate_to_cql(kind, field) do
    Logger.warning("AshScylla: Unsupported aggregate kind: #{kind}, falling back to COUNT")
    if field, do: "COUNT(#{field})", else: "COUNT(*)"
  end

  # ============================================================================
  # CONTAINS / CONTAINS KEY support
  # ============================================================================

  @doc """
  Builds a CONTAINS clause for collection type filtering.

  In CQL, CONTAINS is used to check if a collection column contains a value.
  CONTAINS KEY is used to check if a map column contains a key.
  """
  @spec build_contains_clause(String.t(), term(), :contains | :contains_key) ::
          {String.t(), list()}
  def build_contains_clause(column, value, :contains) do
    {"#{column} CONTAINS ?", [value]}
  end

  def build_contains_clause(column, value, :contains_key) do
    {"#{column} CONTAINS KEY ?", [value]}
  end

  # ============================================================================
  # TOKEN() function support
  # ============================================================================

  @spec build_token_clause(list(), list()) :: {String.t(), list()}
  defp build_token_clause(keys, values) when is_list(keys) and is_list(values) do
    key_list = Enum.map_join(keys, ", ", &cql_identifier(&1))
    placeholder_list = Enum.map_join(Enum.to_list(1..length(values)), ", ", fn _ -> "?" end)
    {"TOKEN(#{key_list}) = TOKEN(#{placeholder_list})", values}
  end

  defp build_in_clause(left_cql, values) do
    placeholders = Enum.map_join(Enum.to_list(1..length(values)//1), ", ", fn _ -> "?" end)
    {"#{left_cql} IN (#{placeholders})", values}
  end

  defp cql_identifier(name) do
    name
    |> to_string()
    |> Identifier.sanitize!()
  end

  defp attribute_name(%{name: name}), do: name
  defp attribute_name(name), do: name

  # ============================================================================
  # Private helpers
  # ============================================================================

  @spec maybe_iodata_to_binary({iolist(), list()} | {:error, term()}) ::
          {String.t(), list()} | {:error, term()}
  defp maybe_iodata_to_binary({cql, params}) when is_list(cql) do
    {IO.iodata_to_binary(cql), params}
  end

  @spec maybe_iodata_to_binary({String.t(), list()}) :: {String.t(), list()}
  defp maybe_iodata_to_binary({cql, params}) when is_binary(cql) do
    {cql, params}
  end

  @spec maybe_iodata_to_binary({:error, term()}) :: {:error, term()}
  defp maybe_iodata_to_binary({:error, _} = error), do: error

  @spec get_filter_columns(list()) :: [atom()]
  defp get_filter_columns(filters) do
    filters
    |> Enum.flat_map(&extract_filter_columns/1)
    |> Enum.uniq()
  end

  @spec extract_filter_columns(term()) :: [atom()]
  defp extract_filter_columns(%Ash.Query.Ref{attribute: %{name: name}}) when not is_nil(name),
    do: [name]

  defp extract_filter_columns(%Ash.Query.Ref{attribute: name}) when is_atom(name), do: [name]
  defp extract_filter_columns(%{left: %{name: name}}) when not is_nil(name), do: [name]
  defp extract_filter_columns(%{expression: expr}), do: get_filter_columns([expr])
  defp extract_filter_columns(%{left: left, right: right}), do: get_filter_columns([left, right])
  defp extract_filter_columns(_), do: []

  @doc false
  @spec secondary_index_scan?(term(), list()) :: boolean()
  def secondary_index_scan?(resource, filters) do
    indexed_columns =
      resource
      |> Dsl.secondary_indexes()
      |> Enum.flat_map(fn idx -> idx.columns end)
      |> MapSet.new()

    filter_columns = get_filter_columns(filters)

    filter_columns != [] and
      Enum.all?(filter_columns, fn col -> MapSet.member?(indexed_columns, col) end)
  end
end
