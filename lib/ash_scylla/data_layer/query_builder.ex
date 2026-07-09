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
  enabling efficient pagination without offset overhead.
  """

  require Logger

  alias AshScylla.Query
  alias AshScylla.DataLayer
  alias AshScylla.DataLayer.Dsl
  alias AshScylla.DataLayer.Types
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
  @spec build_optimized_query(Query.t()) ::
          {:ok, {String.t(), list()}} | {:error, {:unknown_filter, term()}}
  def build_optimized_query(%Query{
        resource: resource,
        table: table,
        filters: filters,
        sorts: sorts,
        limit: limit,
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
    uuid_fields = if resource, do: DataLayer.uuid_attribute_names(resource), else: %MapSet{}
    cql_types = if resource, do: DataLayer.attr_cql_type_map(resource), else: %{}

    case build_where_clause(filters, uuid_fields, cql_types) do
      {:error, _} = error ->
        error

      {:ok, {where_clause, params}} ->
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

        # Add LIMIT — tag as {"int", limit} to match ScyllaDB's INT type
        # (avoids marshaling error: Int32Type expects 4 bytes, bigint is 8)
        {query_acc, params} =
          if limit do
            Logger.debug("AshScylla: Adding LIMIT #{limit}")
            {[query_acc, " LIMIT ?"], params ++ [{"int", limit}]}
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

        # Append ALLOW FILTERING when doing a secondary index scan.
        # ScyllaDB requires ALLOW FILTERING for queries on secondary indexes.
        query_acc =
          if resource != nil and filters != [] and secondary_index_scan?(resource, filters) do
            Logger.debug(
              "AshScylla: Appending ALLOW FILTERING for secondary index scan on #{table}"
            )

            [query_acc, " ALLOW FILTERING"]
          else
            query_acc
          end

        query = IO.iodata_to_binary(query_acc)
        Logger.debug("AshScylla: Raw query before parameterization: #{inspect(query)}")
        Logger.debug("AshScylla: Params: #{inspect(params)}")
        {:ok, {query, params}}
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
    {Enum.map_join(columns, ", ", &cql_identifier/1), []}
  end

  defp build_select_clause(_table, nil, distinct_columns, nil) when is_list(distinct_columns) do
    cols = Enum.map_join(distinct_columns, ", ", &cql_identifier/1)
    {"DISTINCT #{cols}", []}
  end

  defp build_select_clause(_table, nil, nil, aggregates)
       when is_list(aggregates) and aggregates != [] do
    {agg_clause, params} =
      aggregates
      |> Enum.map(fn
        %{kind: :count, name: name, field: nil} ->
          {"COUNT(*) AS #{cql_identifier(name)}", []}

        %{kind: :count, name: name, field: field} ->
          {"COUNT(#{cql_identifier(field)}) AS #{cql_identifier(name)}", []}

        %{kind: :sum, name: name, field: field} ->
          {"SUM(#{cql_identifier(field)}) AS #{cql_identifier(name)}", []}

        %{kind: :avg, name: name, field: field} ->
          {"AVG(#{cql_identifier(field)}) AS #{cql_identifier(name)}", []}

        %{kind: :min, name: name, field: field} ->
          {"MIN(#{cql_identifier(field)}) AS #{cql_identifier(name)}", []}

        %{kind: :max, name: name, field: field} ->
          {"MAX(#{cql_identifier(field)}) AS #{cql_identifier(name)}", []}

        %{kind: kind, name: name} ->
          Logger.warning("AshScylla: Unsupported aggregate kind: #{kind}")
          {"COUNT(*) AS #{cql_identifier(name)}", []}
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
       when is_list(columns) and is_list(aggregates) and aggregates != [] do
    col_clause = Enum.map_join(columns, ", ", &cql_identifier/1)

    {agg_clause, params} =
      aggregates
      |> Enum.map(fn
        %{kind: :count, name: name, field: nil} ->
          {"COUNT(*) AS #{cql_identifier(name)}", []}

        %{kind: :count, name: name, field: field} ->
          {"COUNT(#{cql_identifier(field)}) AS #{cql_identifier(name)}", []}

        %{kind: :sum, name: name, field: field} ->
          {"SUM(#{cql_identifier(field)}) AS #{cql_identifier(name)}", []}

        %{kind: :avg, name: name, field: field} ->
          {"AVG(#{cql_identifier(field)}) AS #{cql_identifier(name)}", []}

        %{kind: :min, name: name, field: field} ->
          {"MIN(#{cql_identifier(field)}) AS #{cql_identifier(name)}", []}

        %{kind: :max, name: name, field: field} ->
          {"MAX(#{cql_identifier(field)}) AS #{cql_identifier(name)}", []}

        %{kind: kind, name: name} ->
          Logger.warning("AshScylla: Unsupported aggregate kind: #{kind}")
          {"COUNT(*) AS #{cql_identifier(name)}", []}
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

  @spec build_where_clause(list()) ::
          {:ok, {String.t(), list()}} | {:error, {:unknown_filter, term()}}
  def build_where_clause(filters), do: build_where_clause(filters, %MapSet{}, %{})

  @doc """
  Builds WHERE clause from Ash filters.

  `uuid_fields` is the set of attribute names (atoms and strings) declared as
  UUID on the resource. When a filter value is compared against one of those
  columns, the string is converted to its 16-byte UUID binary so Xandra encodes
  it as a `uuid`-typed parameter. Conversion is gated strictly on the declared
  attribute type — never on a value-based heuristic — to avoid silently
  corrupting ordinary text values that happen to look like UUIDs.

  `cql_types` is the attribute-name → CQL-type map (from
  `AshScylla.DataLayer.attr_cql_type_map/1`). It is used to type each filter
  parameter with its declared CQL type (e.g. float vs double, int vs
  smallint/tinyint/varint) so the read path encodes parameters identically to
  the write path.

  Returns `{:ok, {clause, params}}` on success or `{:error, {:unknown_filter, term()}}`
  when a filter predicate cannot be translated to CQL. Errors are propagated
  rather than silently dropped, because dropping a WHERE condition would return
  a broader (and potentially unauthorized) result set than the caller expects.
  """
  @spec build_where_clause(list(), MapSet.t(), map()) ::
          {:ok, {String.t(), list()}} | {:error, {:unknown_filter, term()}}
  def build_where_clause(filters, uuid_fields, cql_types) when is_map(filters) do
    build_where_clause(MapSet.to_list(filters), uuid_fields, cql_types)
  end

  def build_where_clause(filters, uuid_fields, cql_types) do
    case filters do
      [] ->
        {:ok, {"", []}}

      _ ->
        Enum.reduce_while(filters, {:ok, {[], []}}, fn filter, {:ok, {acc_c, acc_p}} ->
          case filter_to_cql(filter, uuid_fields, cql_types) do
            {:error, {:unknown_filter, unknown}} ->
              {:halt, {:error, {:unknown_filter, unknown}}}

            {c, p} ->
              {:cont, {:ok, {[c | acc_c], acc_p ++ p}}}
          end
        end)
        |> case do
          {:ok, {clauses, params}} ->
            joined_clauses =
              clauses
              |> Enum.reverse()
              |> Enum.intersperse(" AND ")
              |> IO.iodata_to_binary()

            {:ok, {joined_clauses, params}}

          {:error, _} = error ->
            error
        end
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

    key_list = Enum.map_join(keys, ", ", &cql_identifier/1)
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
    :ends_with => "LIKE",
    :has => "CONTAINS",
    :overlaps => "CONTAINS"
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
    :ends_with => "?",
    :has => "?",
    :overlaps => "?"
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
  - Ash Query functions: now(), today(), ago(), from_now() (evaluated client-side)
  - Ash Query fragment(...) for raw CQL injection
  - has operator → maps to CQL CONTAINS on collection columns
  - overlaps operator → CONTAINS checks (single-value) or in-memory
  """
  @spec filter_to_cql(term(), MapSet.t(), map()) ::
          {String.t(), list()} | {:error, {:unknown_filter, term()}}
  def filter_to_cql(%Ash.Query.Operator.In{left: left, right: right}, uuid_fields, cql_types) do
    filter_to_cql(%{operator: :in, left: left, right: right}, uuid_fields, cql_types)
  end

  # ── Ash Query Function: fragment ────────────────────────────────────────
  # fragment("col = ?", value) → raw CQL injection via Xandra
  def filter_to_cql(%{__function__?: true, name: :fragment} = func, _uuid_fields, _cql_types) do
    # Ash.Query.Function.Fragment stores args as [{:raw, str}, {:expr, arg}, ...]
    # We need to convert this into a CQL string with ? placeholders + params
    {cql_parts, params} =
      func.arguments
      |> Enum.reduce({[], []}, fn
        {:raw, str}, {acc_c, acc_p} -> {[acc_c, str], acc_p}
        {:expr, expr}, {acc_c, acc_p} -> {[acc_c, "?"], acc_p ++ [expr]}
        {:casted_expr, expr}, {acc_c, acc_p} -> {[acc_c, "?"], acc_p ++ [expr]}
        arg, {acc_c, acc_p} -> {[acc_c, inspect(arg)], acc_p}
      end)

    {IO.iodata_to_binary(cql_parts), params}
  end

  # ── Ash Query Functions (eager_evaluate? = false) ────────────────────────
  # now(), today(), ago(), from_now() are evaluated client-side by Ash before
  # reaching the data layer. They arrive as raw DateTime/Date values.
  # The catch-all filter_to_cql already handles these as parameterized values.

  # ── Ash.Query.Operator.Has → CQL CONTAINS ───────────────────────────────
  # has(collection_column, value) → collection_column CONTAINS value
  def filter_to_cql(%Ash.Query.Operator.Has{left: left, right: right}, uuid_fields, cql_types) do
    filter_to_cql(%{operator: :has, left: left, right: right}, uuid_fields, cql_types)
  end

  # ── Ash.Query.Operator.Overlaps → CQL CONTAINS (single-value only) ──────
  # overlaps(collection_column, [a, b]) → only single-value supported in CQL.
  # CQL has no OR operator, so multi-value overlaps requires multiple queries.
  def filter_to_cql(
        %Ash.Query.Operator.Overlaps{left: left, right: right},
        uuid_fields,
        cql_types
      ) do
    values =
      case right do
        %MapSet{} = ms -> MapSet.to_list(ms)
        list when is_list(list) -> list
        _ -> []
      end

    cond do
      values == [] ->
        {"FALSE", []}

      length(values) == 1 ->
        filter_to_cql(
          %{operator: :has, left: left, right: %{value: hd(values)}},
          uuid_fields,
          cql_types
        )

      true ->
        raise AshScylla.Error,
          message:
            "CQL does not support OR, so overlaps/2 with multiple values cannot be expressed in a single query. " <>
              "Found: overlaps(#{inspect(attribute_name(left))}, #{inspect(values)}). " <>
              "Workaround: split into multiple queries (one per value) and merge in application code."
    end
  end

  def filter_to_cql(%{expression: expression}, uuid_fields, cql_types) do
    expression
    |> filter_to_cql(uuid_fields, cql_types)
    |> maybe_iodata_to_binary()
  end

  def filter_to_cql(%{op: op, left: left, right: right}, uuid_fields, cql_types) do
    case filter_to_cql(left, uuid_fields, cql_types) do
      {:error, _} = error ->
        error

      {left_cql, left_params} ->
        case filter_to_cql(right, uuid_fields, cql_types) do
          {:error, _} = error ->
            error

          {right_cql, right_params} ->
            case op do
              :and ->
                {[left_cql, " AND ", right_cql], left_params ++ right_params}

              :or ->
                # Try to rewrite same-field OR as IN (CQL supports IN on partition/clustering keys).
                case rewrite_or_to_in(left, right) do
                  {:ok, {field_name, values}} ->
                    placeholders =
                      values
                      |> Enum.map(fn _ -> "?" end)
                      |> Enum.intersperse(", ")
                      |> IO.iodata_to_binary()

                    {["#{cql_identifier(field_name)} IN (#{placeholders})"],
                     Enum.map(values, &typed_param(field_name, &1, uuid_fields, cql_types))}

                  :error ->
                    # CQL does not support OR across different fields or with
                    # operators other than eq/==.  This is a fundamental CQL
                    # limitation — the WHERE clause only allows a flat list of
                    # AND-ed predicates (plus IN on partition/clustering keys).
                    #
                    # Workarounds:
                    # 1. Redesign the table with a canonical partition key
                    #    (e.g. conversation_id = hash(sorted(user_a, user_b)))
                    # 2. Split into two queries and merge in application code
                    # 3. Rewrite same-field OR as IN (handled above)
                    raise AshScylla.Error,
                      message:
                        "CQL does not support OR across different fields or with non-equality operators. " <>
                          "Found: or(#{inspect(deeply_unwrap_expr(left))}, #{inspect(deeply_unwrap_expr(right))}). " <>
                          "Workarounds: (1) redesign the table with a canonical partition key, " <>
                          "(2) split into two queries and merge in application code, " <>
                          "or (3) rewrite same-field OR as IN."
                end

              _ ->
                filter_to_cql(%{operator: op, left: left, right: right}, uuid_fields, cql_types)
            end
        end
    end
    |> maybe_iodata_to_binary()
  end

  def filter_to_cql(%{operator: op, left: left, right: right}, uuid_fields, cql_types) do
    case filter_to_cql(left, uuid_fields, cql_types) do
      {:error, _} = error ->
        error

      {left_cql, left_params} ->
        name = attribute_name(left)

        case filter_to_cql(right, uuid_fields, cql_types) do
          {:error, {:unknown_filter, raw_value}} ->
            # Raw value on the right side of an operator (e.g. DateTime, string, number)
            # Handle operators that need special CQL syntax with raw values
            case op do
              :in when is_list(raw_value) ->
                build_in_clause(
                  left_cql,
                  left_params ++
                    Enum.map(raw_value, &typed_param(name, &1, uuid_fields, cql_types))
                )

              :in when is_struct(raw_value, MapSet) ->
                raw_value
                |> MapSet.to_list()
                |> Enum.map(&typed_param(name, &1, uuid_fields, cql_types))
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
                {"#{left_cql} CONTAINS KEY ?",
                 left_params ++ [typed_param(name, raw_value, uuid_fields, cql_types)]}

              :exists ->
                {"#{left_cql} IS NOT NULL", left_params}

              :has ->
                {"#{left_cql} CONTAINS ?",
                 left_params ++ [typed_param(name, raw_value, uuid_fields, cql_types)]}

              :overlaps ->
                # overlaps with a single raw value → CONTAINS
                {"#{left_cql} CONTAINS ?",
                 left_params ++ [typed_param(name, raw_value, uuid_fields, cql_types)]}

              _ ->
                cql_op = Map.get(@operator_mapping, op, "=")
                cql_val = Map.get(@operator_values, op, "?")

                {"#{left_cql} #{cql_op} #{cql_val}",
                 left_params ++ [typed_param(name, raw_value, uuid_fields, cql_types)]}
            end

          {_right_cql, right_params} ->
            case {op, right} do
              {:in, %{value: values}} when is_list(values) ->
                build_in_clause(
                  left_cql,
                  left_params ++ Enum.map(values, &typed_param(name, &1, uuid_fields, cql_types))
                )

              {:in, values} when is_list(values) ->
                build_in_clause(
                  left_cql,
                  left_params ++ Enum.map(values, &typed_param(name, &1, uuid_fields, cql_types))
                )

              {:in, %MapSet{} = values} ->
                values
                |> MapSet.to_list()
                |> Enum.map(&typed_param(name, &1, uuid_fields, cql_types))
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

              {:has, %{value: value}} ->
                {"#{left_cql} CONTAINS ?",
                 left_params ++ [typed_param(name, value, uuid_fields, cql_types)]}

              {:has, value} ->
                {"#{left_cql} CONTAINS ?",
                 left_params ++ [typed_param(name, value, uuid_fields, cql_types)]}

              {:overlaps, %{value: values}} when is_list(values) and length(values) == 1 ->
                {"#{left_cql} CONTAINS ?",
                 left_params ++ Enum.map(values, &typed_param(name, &1, uuid_fields, cql_types))}

              {:overlaps, %{value: values}} when is_list(values) ->
                raise AshScylla.Error,
                  message:
                    "CQL does not support OR, so overlaps/2 with multiple values cannot be expressed in a single query. " <>
                      "Found: overlaps(#{left_cql}, #{inspect(values)}). " <>
                      "Workaround: split into multiple queries and merge in application code."

              {:overlaps, %{value: %MapSet{} = ms}} ->
                vals = MapSet.to_list(ms)

                if length(vals) == 1 do
                  {"#{left_cql} CONTAINS ?",
                   left_params ++ Enum.map(vals, &typed_param(name, &1, uuid_fields, cql_types))}
                else
                  raise AshScylla.Error,
                    message:
                      "CQL does not support OR, so overlaps/2 with multiple values cannot be expressed in a single query. " <>
                        "Found: overlaps(#{left_cql}, #{inspect(vals)}). " <>
                        "Workaround: split into multiple queries and merge in application code."
                end

              {:overlaps, %MapSet{} = values} ->
                vals = MapSet.to_list(values)

                if length(vals) == 1 do
                  {"#{left_cql} CONTAINS ?",
                   left_params ++ Enum.map(vals, &typed_param(name, &1, uuid_fields, cql_types))}
                else
                  raise AshScylla.Error,
                    message:
                      "CQL does not support OR, so overlaps/2 with multiple values cannot be expressed in a single query. " <>
                        "Found: overlaps(#{left_cql}, #{inspect(vals)}). " <>
                        "Workaround: split into multiple queries and merge in application code."
                end

              {:overlaps, value} ->
                {"#{left_cql} CONTAINS ?",
                 left_params ++ [typed_param(name, value, uuid_fields, cql_types)]}

              {:starts_with, %{value: value}} ->
                {"#{left_cql} LIKE ?", left_params ++ ["%" <> value]}

              {:ends_with, %{value: value}} ->
                {"#{left_cql} LIKE ?", left_params ++ [value <> "%"]}

              {:contains, %{value: value}} ->
                {"#{left_cql} LIKE ?", left_params ++ ["%" <> value <> "%"]}

              {:contains_key, %{value: value}} ->
                {"#{left_cql} CONTAINS KEY ?",
                 left_params ++ [typed_param(name, value, uuid_fields, cql_types)]}

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

  def filter_to_cql(%{op: op, name: name, right: right}, uuid_fields, cql_types) do
    filter_to_cql(%{operator: op, left: %{name: name}, right: right}, uuid_fields, cql_types)
  end

  def filter_to_cql(%Ash.Query.Ref{attribute: attribute}, _uuid_fields, _cql_types) do
    {cql_identifier(attribute_name(attribute)), []}
  end

  def filter_to_cql(%{value: value}, _uuid_fields, _cql_types) do
    # Standalone value (e.g. right side of IN). No column context, so emit the
    # raw value — connection.typed_params infers the correct type.
    {"?", [value]}
  end

  def filter_to_cql(%{name: name}, _uuid_fields, _cql_types) do
    {cql_identifier(name), []}
  end

  def filter_to_cql(unknown, _uuid_fields, _cql_types) do
    # Raw value — return it as a parameter placeholder so parent operators can use it
    # This handles cases like: %{operator: :eq, left: %{name: :status}, right: "active"}
    # where the right side is a raw value, not a filter expression.
    # The value is emitted raw; connection.typed_params infers the correct type.
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

  @spec filter_to_cql(term()) ::
          {String.t(), list()} | {:error, {:unknown_filter, term()}}
  def filter_to_cql(filter) do
    filter_to_cql(filter, %MapSet{}, %{})
  end

  @doc """
  Converts Ash filter expressions to CQL (bang version).

  Raises `ArgumentError` on unknown filter expressions.
  """
  @spec filter_to_cql!(term()) :: {String.t(), list()}
  def filter_to_cql!(filter) do
    filter_to_cql!(filter, %MapSet{}, %{})
  end

  @spec filter_to_cql!(term(), MapSet.t(), map()) :: {String.t(), list()}
  def filter_to_cql!(filter, uuid_fields, cql_types) do
    case filter_to_cql(filter, uuid_fields, cql_types) do
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
  def aggregate_to_cql(:count, field), do: "COUNT(#{cql_identifier(field)})"
  def aggregate_to_cql(:sum, field), do: "SUM(#{cql_identifier(field)})"
  def aggregate_to_cql(:avg, field), do: "AVG(#{cql_identifier(field)})"
  def aggregate_to_cql(:min, field), do: "MIN(#{cql_identifier(field)})"
  def aggregate_to_cql(:max, field), do: "MAX(#{cql_identifier(field)})"

  def aggregate_to_cql(kind, field) do
    Logger.warning("AshScylla: Unsupported aggregate kind: #{kind}, falling back to COUNT")
    if field, do: "COUNT(#{cql_identifier(field)})", else: "COUNT(*)"
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
    {"#{cql_identifier(column)} CONTAINS ?", [value]}
  end

  def build_contains_clause(column, value, :contains_key) do
    {"#{cql_identifier(column)} CONTAINS KEY ?", [value]}
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

  # CQL reserved keywords that must be quoted when used as identifiers.
  # Source: https://cassandra.apache.org/doc/latest/cassandra/cql/appendix.html#keywords
  @cql_reserved_keywords MapSet.new([
                           "add",
                           "allow",
                           "alter",
                           "and",
                           "apply",
                           "asc",
                           "authorize",
                           "batch",
                           "begin",
                           "by",
                           "columnfamily",
                           "create",
                           "delete",
                           "desc",
                           "describe",
                           "drop",
                           "entries",
                           "execute",
                           "from",
                           "full",
                           "grant",
                           "if",
                           "in",
                           "index",
                           "infinity",
                           "insert",
                           "into",
                           "is",
                           "keyspace",
                           "limit",
                           "materialized",
                           "modify",
                           "nan",
                           "norecursive",
                           "not",
                           "null",
                           "of",
                           "on",
                           "or",
                           "order",
                           "primary",
                           "rename",
                           "replace",
                           "schema",
                           "select",
                           "set",
                           "table",
                           "to",
                           "token",
                           "truncate",
                           "unlogged",
                           "update",
                           "use",
                           "using",
                           "view",
                           "where",
                           "with"
                         ])

  def cql_identifier(name) do
    name_str = name |> to_string() |> Identifier.sanitize!()

    if MapSet.member?(@cql_reserved_keywords, String.downcase(name_str)) do
      "\"#{name_str}\""
    else
      name_str
    end
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
  def get_filter_columns(filters) do
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

  # Attempt to rewrite an OR-of-eq on the same field to IN (CQL doesn't support OR).
  # Returns {:ok, {field_name, values}} or :error.
  @doc false
  @spec rewrite_or_to_in(term(), term()) :: {:ok, {atom(), list()}} | :error
  def rewrite_or_to_in(left, right) do
    left = deeply_unwrap_expr(left)
    right = deeply_unwrap_expr(right)

    Logger.debug(
      "AshScylla: rewrite_or_to_in left: #{inspect(left, pretty: true, limit: :infinity)}"
    )

    Logger.debug(
      "AshScylla: rewrite_or_to_in right: #{inspect(right, pretty: true, limit: :infinity)}"
    )

    case {left, right} do
      # Standard form: %{left: %{name: name}, operator: op, right: %{value: v}}
      {%{left: %{name: name1}, operator: op1, right: v1},
       %{left: %{name: name2}, operator: op2, right: v2}}
      when name1 == name2 and name1 != nil and op1 in [:eq, :==] and op2 in [:eq, :==] ->
        {:ok, {name1, [extract_value(v1), extract_value(v2)]}}

      # Short form with op key: %{left: %{name: name}, op: op, right: %{value: v}}
      {%{left: %{name: name1}, op: op1, right: v1}, %{left: %{name: name2}, op: op2, right: v2}}
      when name1 == name2 and name1 != nil and op1 in [:eq, :==] and op2 in [:eq, :==] ->
        {:ok, {name1, [extract_value(v1), extract_value(v2)]}}

      # Flat short form: %{name: name, op: op, right: %{value: v}}
      {%{name: name1, op: op1, right: v1}, %{name: name2, op: op2, right: v2}}
      when name1 == name2 and name1 != nil and op1 in [:eq, :==] and op2 in [:eq, :==] ->
        {:ok, {name1, [extract_value(v1), extract_value(v2)]}}

      _ ->
        :error
    end
  end

  # defp unwrap_expr(%{expression: expr}), do: unwrap_expr(expr)
  # defp unwrap_expr(other), do: other

  defp deeply_unwrap_expr(%{expression: expr}), do: deeply_unwrap_expr(expr)

  defp deeply_unwrap_expr(%{left: left, op: op, right: right}) do
    %{left: deeply_unwrap_expr(left), op: op, right: deeply_unwrap_expr(right)}
  end

  defp deeply_unwrap_expr(%{left: left, operator: op, right: right}) do
    %{left: deeply_unwrap_expr(left), operator: op, right: deeply_unwrap_expr(right)}
  end

  defp deeply_unwrap_expr(%Ash.Query.Ref{attribute: %{name: name}}), do: %{name: name}
  defp deeply_unwrap_expr(%Ash.Query.Ref{attribute: name}) when is_atom(name), do: %{name: name}

  defp deeply_unwrap_expr(%{name: _} = n), do: n
  defp deeply_unwrap_expr(%{value: _} = v), do: v
  defp deeply_unwrap_expr(other), do: other

  # Builds a typed parameter for a filter value compared against `name`.
  #
  # 1. If the column is declared as a UUID attribute, a UUID-shaped string is
  #    converted to its 16-byte binary (gated strictly on the declared type,
  #    never on a value-based heuristic).
  # 2. The value is then wrapped with its declared CQL type via
  #    DataLayer.wrap_typed/3 so the read path types parameters identically to
  #    the write path (e.g. float vs double, int vs smallint/tinyint/varint).
  defp typed_param(name, value, uuid_fields, cql_types) do
    converted = maybe_convert_uuid(name, value, uuid_fields)
    wrapped = DataLayer.wrap_typed(converted, name, cql_types)

    # Only emit a {type, value} tuple when the declared type is one that
    # Xandra's prepared-statement path would NOT infer correctly on its own.
    # For the common default-inferable types (text, bigint, double, boolean)
    # connection.typed_params already produces the right tag, so we return the
    # raw value to keep parameter encoding identical to the write path without
    # changing behaviour for ordinary values. This closes the real gap:
    # float vs double and int vs smallint/tinyint/varint disambiguation.
    case wrapped do
      {type, _} when type in ["text", "bigint", "double", "boolean"] ->
        converted

      _ ->
        wrapped
    end
  end

  # Converts a filter value to its 16-byte UUID binary when the column it is
  # compared against is declared as a UUID attribute. Gated strictly on the
  # declared attribute type (never on a value-based heuristic) so ordinary
  # text values that happen to look like UUIDs are left untouched.
  defp maybe_convert_uuid(_name, value, _uuid_fields) when not is_binary(value), do: value

  defp maybe_convert_uuid(name, value, uuid_fields) do
    if name in uuid_fields do
      case Types.uuid_string_to_binary(value) do
        {:ok, bin} -> bin
        _ -> value
      end
    else
      value
    end
  end

  defp extract_value(%{value: v}), do: extract_value(v)
  defp extract_value(v), do: v

  @doc false
  @spec secondary_index_scan?(term(), list()) :: boolean()
  def secondary_index_scan?(resource, filters) do
    pk_columns =
      if Ash.Resource.Info.resource?(resource) do
        resource
        |> Ash.Resource.Info.primary_key()
        |> MapSet.new()
      else
        MapSet.new()
      end

    secondary_indexed_columns =
      resource
      |> Dsl.secondary_indexes()
      |> Enum.flat_map(fn idx -> idx.columns end)
      |> MapSet.new()

    filter_columns = get_filter_columns(filters)

    # A secondary index scan occurs when:
    # 1. There are filters
    # 2. At least one filter column uses a secondary index (not a PK)
    # 3. All filter columns are either PK or secondary index columns (no unindexed columns)
    filter_columns != [] and
      Enum.any?(filter_columns, fn col -> MapSet.member?(secondary_indexed_columns, col) end) and
      Enum.all?(filter_columns, fn col ->
        MapSet.member?(pk_columns, col) or MapSet.member?(secondary_indexed_columns, col)
      end)
  end
end
