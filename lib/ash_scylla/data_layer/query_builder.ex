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
  prepared statement support, and token-based pagination.

  ## Secondary Index Support

  When filtering on non-primary key columns, this module checks if a
  secondary index exists and generates appropriate CQL. ScyllaDB/Cassandra
  can use secondary indexes for equality checks (=) but not for range queries.
  """

  require Logger

  alias AshScylla.DataLayer
  alias AshScylla.DataLayer.Dsl

  @doc """
  Builds an optimized CQL query from the data layer query struct.

  If filters are on columns with secondary indexes, the query will
  use those indexes automatically.
  """
  @spec build_optimized_query(DataLayer.t()) :: {String.t(), list()}
  def build_optimized_query(%DataLayer{
        table: table,
        filters: filters,
        sorts: sorts,
        limit: limit,
        offset: offset,
        select: select
      }) do
    Logger.debug("AshScylla: Building optimized query for table #{table}")

    # Build SELECT clause
    select_clause =
      case select do
        nil -> "*"
        [] -> "*"
        columns -> Enum.map_join(columns, ", ", &"#{&1}")
      end

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

    # Build ORDER BY clause
    {order_clause, order_params} = build_order_by(sorts)

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

    query = IO.iodata_to_binary(query_acc)

    # Add OFFSET (note: OFFSET in CQL requires special handling)
    if offset do
      Logger.warning(
        "AshScylla: OFFSET is not natively supported in ScyllaDB/Cassandra; ignoring offset=#{offset}"
      )

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
  @spec build_where_clause(list()) :: {String.t(), list()}
  def build_where_clause(filters) do
    case filters do
      [] ->
        {"", []}

      _ ->
        {clauses, params} =
          filters
          |> Enum.map(&filter_to_cql!/1)
          |> Enum.reduce({[], []}, fn {c, p}, {acc_c, acc_p} ->
            # Prepend clause as IO list element, prepend params in reverse
            {[c | acc_c], Enum.reverse(p, acc_p)}
          end)

        # clauses are in reverse order (prepended), params are in reverse
        joined_clauses =
          clauses
          |> Enum.reverse()
          |> Enum.intersperse(" AND ")
          |> IO.iodata_to_binary()

        {joined_clauses, :lists.reverse(params)}
    end
  end

  @doc """
  Builds ORDER BY clause from sort items.

  Sort items can be:
  - Maps with `:field` and `:direction` keys
  - Tuples like `{field, direction}` (Ash standard format)
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
                "#{field} #{direction}"

              {field, direction} when is_atom(field) ->
                "#{field} #{direction}"

              %{field: field} ->
                "#{field} ASC"

              {field} when is_atom(field) ->
                "#{field} ASC"

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

    # Check if all filter columns have secondary indexes
    # Note: Secondary indexes work best with equality checks
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

  @doc """
  Converts Ash filter expressions to CQL (safe version).

  Returns `{cql, params}` on success or `{:error, {:unknown_filter, term()}}` on failure.
  """
  @spec filter_to_cql(term()) :: {String.t(), list()} | {:error, {:unknown_filter, term()}}
  def filter_to_cql(%{expression: expression}) do
    expression
    |> filter_to_cql()
    |> maybe_iodata_to_binary()
  end

  def filter_to_cql(%{op: op, left: left, right: right}) do
    with {left_cql, left_params} <- filter_to_cql(left),
         {right_cql, right_params} <- filter_to_cql(right) do
      case op do
        :and ->
          {["(", left_cql, ") AND (", right_cql, ")"], left_params ++ right_params}

        :or ->
          {["(", left_cql, ") OR (", right_cql, ")"], left_params ++ right_params}

        _ ->
          {"", []}
      end
    end
    |> maybe_iodata_to_binary()
  end

  @operator_mapping %{
    :eq => "=",
    :not_eq => "!=",
    :gt => ">",
    :gte => ">=",
    :lt => "<",
    :lte => "<=",
    :contains => "LIKE",
    :starts_with => "LIKE",
    :ends_with => "LIKE"
  }

  @operator_values %{
    :contains => "?",
    :starts_with => "%?",
    :ends_with => "?%"
  }

  def filter_to_cql(%{operator: op, left: left, right: right}) do
    with {left_cql, left_params} <- filter_to_cql(left) do
      case {op, right} do
        {:in, %{value: values}} when is_list(values) ->
          placeholders = Enum.map_join(Enum.to_list(1..length(values)//1), ", ", fn _ -> "?" end)
          {"#{left_cql} IN (#{placeholders})", left_params ++ values}

        _ ->
          case filter_to_cql(right) do
            {:error, _} = error ->
              error

            {_right_cql, right_params} ->
              cql_op = Map.get(@operator_mapping, op, "=")
              cql_val = Map.get(@operator_values, op, "?")
              {"#{left_cql} #{cql_op} #{cql_val}", left_params ++ right_params}
          end
      end
    end
  end

  def filter_to_cql(%{value: value}) do
    {"?", [value]}
  end

  def filter_to_cql(%{name: name}) do
    {"#{name}", []}
  end

  def filter_to_cql(unknown) do
    Logger.warning("AshScylla: Unknown filter expression: #{inspect(unknown)}")
    {:error, {:unknown_filter, unknown}}
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

  # Ensures the CQL part of the tuple is always a binary string.
  # Internal helpers may return IO lists for efficiency; this normalizes them.
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
  defp extract_filter_columns(%{left: %{name: name}}) when not is_nil(name), do: [name]
  defp extract_filter_columns(%{expression: expr}), do: get_filter_columns([expr])
  defp extract_filter_columns(%{left: left, right: right}), do: get_filter_columns([left, right])
  defp extract_filter_columns(_), do: []
end
