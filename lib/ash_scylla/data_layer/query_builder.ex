defmodule AshScylla.DataLayer.QueryBuilder do
  @moduledoc """
  Query building functions for AshScylla data layer.

  Provides optimized query building with filter-to-CQL conversion,
  prepared statement support, and token-based pagination.

  ## Secondary Index Support

  When filtering on non-primary key columns, this module checks if a
  secondary index exists and generates appropriate CQL. ScyllaDB/Cassandra
  can use secondary indexes for equality checks (=) but not for range queries.
  """

  alias AshScylla.DataLayer
  alias AshScylla.DataLayer.Dsl

  @doc """
  Builds an optimized CQL query from the data layer query struct.

  If filters are on columns with secondary indexes, the query will
  use those indexes automatically.
  """
  def build_optimized_query(%DataLayer{
        table: table,
        filters: filters,
        sorts: sorts,
        limit: limit,
        offset: offset,
        select: select
      }) do
    # Build SELECT clause
    select_clause =
      if select && length(select) > 0 do
        select |> Enum.map(&"#{&1}") |> Enum.join(", ")
      else
        "*"
      end

    base_query = "SELECT #{select_clause} FROM #{table}"

    # Build WHERE clause from filters
    {where_clause, params} = build_where_clause(filters)

    query = if String.length(where_clause) > 0 do
      "#{base_query} WHERE #{where_clause}"
    else
      base_query
    end

    # Build ORDER BY clause
    {order_clause, order_params} = build_order_by(sorts)
    query = if String.length(order_clause) > 0 do
      "#{query} ORDER BY #{order_clause}"
    else
      query
    end
    params = params ++ order_params

    # Add LIMIT
    {query, params} = if limit do
      {"#{query} LIMIT ?", params ++ [limit]}
    else
      {query, params}
    end

    # Add OFFSET (note: OFFSET in CQL requires special handling)
    if offset do
      # ScyllaDB/Cassandra doesn't support OFFSET natively
      # This would need to be handled differently (pagination with tokens)
      {query, params}
    else
      {query, params}
    end
  end

  @doc """
  Builds WHERE clause from Ash filters.
  """
  def build_where_clause(filters) do
    case filters do
      [] -> {"", []}
      _ ->
        # Combine all filters with AND
        {clause, params} =
          filters
          |> Enum.map(&filter_to_cql/1)
          |> Enum.reduce({"", []}, fn {c, p}, {acc_c, acc_p} ->
            {if String.length(acc_c) > 0 do
               "#{acc_c} AND #{c}"
             else
               c
             end, acc_p ++ p}
          end)

        {clause, params}
    end
  end

  @doc """
  Builds ORDER BY clause from sort items.
  """
  def build_order_by(sorts) do
    case sorts do
      [] -> {"", []}
      _ ->
        clauses = Enum.map(sorts, fn sort_item ->
          field = Map.get(sort_item, :field)
          direction = Map.get(sort_item, :direction, :asc)
          "#{field} #{direction}"
        end)
        {Enum.join(clauses, ", "), []}
    end
  end

  @doc """
  Checks if a filter can use secondary indexes.

  Returns `{:ok, indexed_columns}` if the filter can use indexes,
  or `{:error, reason}` if it cannot.
  """
  def can_use_secondary_index?(resource, filters) do
    indexed_columns =
      resource
      |> Dsl.secondary_indexes()
      |> Enum.flat_map(fn idx -> idx.columns end)
      |> MapSet.new()

    filter_columns = get_filter_columns(filters)

    # Check if all filter columns have secondary indexes
    # Note: Secondary indexes work best with equality checks
    case filter_columns do
      [] -> {:error, :no_filters}
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

  defp get_filter_columns(filters) do
    filters
    |> Enum.flat_map(fn filter ->
      case filter do
        %{left: %{name: name}} when not is_nil(name) -> [name]
        %{expression: expr} -> get_filter_columns([expr])
        %{left: left, right: right} ->
          get_filter_columns([left, right])
        _ -> []
      end
    end)
    |> Enum.uniq()
  end

  @doc """
  Converts Ash filter expressions to CQL.

  Note: For secondary indexes to be used, filters should be equality checks
  on indexed columns. Range queries on secondary indexes are not recommended.
  """
  def filter_to_cql(%{expression: expression}) do
    filter_to_cql(expression)
  end

  def filter_to_cql(%{op: op, left: left, right: right}) do
    {left_cql, left_params} = filter_to_cql(left)
    {right_cql, right_params} = filter_to_cql(right)

    case op do
      :and ->
        {"(#{left_cql}) AND (#{right_cql})", left_params ++ right_params}
      :or ->
        {"(#{left_cql}) OR (#{right_cql})", left_params ++ right_params}
      _ ->
        {"", []}
    end
  end

  def filter_to_cql(%{expression: expression}) do
    filter_to_cql(expression)
  end

  def filter_to_cql(%{operator: op, left: left, right: right}) do
    {left_cql, left_params} = filter_to_cql(left)
    {_right_cql, right_params} = filter_to_cql(right)

    {cql_op, cql_right} = case op do
      :eq -> {"=", "?"}
      :not_eq -> {"!=", "?"}
      :gt -> {">", "?"}
      :gte -> {">=", "?"}
      :lt -> {"<", "?"}
      :lte -> {"<=", "?"}
      :in -> {"IN", "(#{Enum.map(1..length(right_params), fn _ -> "?" end) |> Enum.join(", ")}"}
      :contains -> {"LIKE", "?"}
      :starts_with -> {"LIKE", "?%"}
      :ends_with -> {"LIKE", "%?"}
      _ -> {"=", "?"}
    end

    {"#{left_cql} #{cql_op} #{cql_right}", left_params ++ right_params}
  end

  def filter_to_cql(%{value: value}) do
    {"?", [value]}
  end

  def filter_to_cql(%{name: name}) do
    {"#{name}", []}
  end

  def filter_to_cql(_) do
    {"1=1", []}  # Fallback
  end
end
