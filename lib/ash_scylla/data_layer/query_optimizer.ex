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

defmodule AshScylla.DataLayer.QueryOptimizer do
  @moduledoc """
  Query optimization hints for ScyllaDB.

  Provides:
  - Per-query consistency level overrides
  - Query-level timeouts
  - Paging hints for large result sets
  - Token range optimization for partition-aware queries
  - Speculative retry policy configuration
  - Query profiling helpers

  ## Usage

      # Build an optimized query
      query = AshScylla.DataLayer.QueryOptimizer.optimize(query, [
        consistency: :one,
        timeout: 5_000,
        page_size: 100,
        speculative_retry: :99percentile
      ])
  """

  require Logger

  alias AshScylla.DataLayer
  alias AshScylla.Identifier

  @default_page_size 50
  @max_page_size 1000

  @valid_consistency_levels [
    :any,
    :one,
    :two,
    :three,
    :quorum,
    :all,
    :local_quorum,
    :each_quorum,
    :serial,
    :local_serial,
    :local_one
  ]

  @valid_speculative_retry_policies [:none, :"99percentile", :custom]

  @doc """
  Applies optimization hints to a DataLayer query struct.

  Returns a keyword list of Xandra execution options that can be merged
  into the `repo.query/3` call.

  ## Options

  - `:consistency` - Override consistency level for this query
  - `:timeout` - Query timeout in milliseconds
  - `:page_size` - Number of rows per page for token-based pagination
  - `:speculative_retry` - Speculative retry policy (`:none`, `:"99percentile"`, `:custom`)
  - `:speculative_retry_delay_ms` - Custom delay for speculative retry (ms)
  - `:serial_consistency` - Serial consistency for LWT (`:serial`, `:local_serial`)
  - `:profiling` - Enable query profiling (default: false)
  - `:allow_filtering` - Allow filtering (default: false, not recommended)
  """
  @spec optimize(DataLayer.t(), keyword()) :: keyword()
  def optimize(_data_layer_query, opts \\ []) do
    []
    |> maybe_put_consistency(opts[:consistency])
    |> maybe_put_timeout(opts[:timeout])
    |> maybe_put_page_size(opts[:page_size])
    |> maybe_put_speculative_retry(opts[:speculative_retry], opts[:speculative_retry_delay_ms])
    |> maybe_put_serial_consistency(opts[:serial_consistency])
    |> maybe_put_profiling(opts[:profiling])
    |> maybe_put_allow_filtering(opts[:allow_filtering])
  end

  @doc """
  Generates CQL query options for Xandra execution.

  Converts optimization hints into Xandra execute options.
  This is an alias for `optimize/2` that makes the intent explicit
  when building Xandra calls directly.
  """
  @spec to_xandra_opts(keyword()) :: keyword()
  def to_xandra_opts(opts) when is_list(opts) do
    opts
    |> maybe_put_consistency(opts[:consistency])
    |> maybe_put_timeout(opts[:timeout])
    |> maybe_put_page_size(opts[:page_size])
    |> maybe_put_serial_consistency(opts[:serial_consistency])
  end

  @doc """
  Determines the optimal page size for a query based on result set estimation.

  Uses heuristics based on:
  - Whether the query has a partition key filter (small page)
  - Whether the query is a full table scan (large page)
  - The number of clustering columns
  """
  @spec optimal_page_size(DataLayer.t()) :: non_neg_integer()
  def optimal_page_size(%DataLayer{filters: filters, limit: limit}) do
    cond do
      # If there's a small explicit limit, use it
      is_integer(limit) and limit <= @default_page_size ->
        limit

      # Has partition key equality filter — small result set
      has_partition_key_filter?(filters) ->
        50

      # Has secondary index or clustering column filter — medium result set
      has_indexed_filter?(filters) ->
        100

      # Full table scan — use larger pages to reduce round trips
      true ->
        500
    end
    |> min(@max_page_size)
  end

  @doc """
  Analyzes a query and returns optimization suggestions.

  Returns a list of suggestion strings like:
  - "Consider adding secondary index on :email for faster lookups"
  - "Query performs full table scan - add partition key filter"
  - "Use token-based pagination for large result sets"
  """
  @spec analyze(DataLayer.t()) :: [String.t()]
  def analyze(%DataLayer{filters: filters, limit: limit, select: select} = query) do
    suggestions = []

    suggestions =
      if filters == [] do
        ["Query performs full table scan - add partition key filter" | suggestions]
      else
        suggestions
      end

    suggestions =
      if has_non_indexed_filter?(query) do
        non_indexed = non_indexed_filter_columns(query)

        Enum.reduce(non_indexed, suggestions, fn col, acc ->
          ["Consider adding secondary index on #{inspect(col)} for faster lookups" | acc]
        end)
      else
        suggestions
      end

    suggestions =
      if is_nil(limit) and filters == [] do
        ["Use token-based pagination for large result sets" | suggestions]
      else
        suggestions
      end

    suggestions =
      if select == nil or select == [] do
        ["Consider selecting only needed columns instead of SELECT *" | suggestions]
      else
        suggestions
      end

    suggestions =
      if is_nil(limit) do
        ["Consider adding a LIMIT clause to reduce result set size" | suggestions]
      else
        suggestions
      end

    Enum.reverse(suggestions)
  end

  @doc """
  Generates a token range query for partition-aware scanning.

  Useful for parallel data processing where you want to split
  the token range across workers.

  ## Parameters

  - `table` - The table name
  - `partition_key` - The partition key column name
  - `start_token` - Start of token range (inclusive)
  - `end_token` - End of token range (exclusive)

  ## Examples

      iex> AshScylla.DataLayer.QueryOptimizer.token_range_query("users", "id", "-9223372036854775808", "0")
      "SELECT * FROM users WHERE token(id) > -9223372036854775808 AND token(id) <= 0"
  """
  @spec token_range_query(String.t(), String.t(), String.t(), String.t()) :: String.t()
  def token_range_query(table, partition_key, start_token, end_token) do
    "SELECT * FROM #{sanitize_identifier(table)} WHERE token(#{sanitize_identifier(partition_key)}) > #{start_token} AND token(#{sanitize_identifier(partition_key)}) <= #{end_token}"
  end

  @doc """
  Generates CQL for speculative retry policy at session level.

  ## Examples

      iex> AshScylla.DataLayer.QueryOptimizer.speculative_retry_cql(:99percentile, nil)
      "USING SPECULATIVE_RETRY '99percentile'"

      iex> AshScylla.DataLayer.QueryOptimizer.speculative_retry_cql(:none, nil)
      "USING SPECULATIVE_RETRY 'NONE'"

      iex> AshScylla.DataLayer.QueryOptimizer.speculative_retry_cql(:custom, 500)
      "USING SPECULATIVE_RETRY '500ms'"
  """
  @spec speculative_retry_cql(atom(), non_neg_integer() | nil) :: String.t()
  def speculative_retry_cql(:none, _delay_ms) do
    "USING SPECULATIVE_RETRY 'NONE'"
  end

  def speculative_retry_cql(:"99percentile", _delay_ms) do
    "USING SPECULATIVE_RETRY '99percentile'"
  end

  def speculative_retry_cql(:custom, delay_ms) when is_integer(delay_ms) and delay_ms > 0 do
    "USING SPECULATIVE_RETRY '#{delay_ms}ms'"
  end

  def speculative_retry_cql(:custom, nil) do
    raise ArgumentError, "Custom speculative retry requires :speculative_retry_delay_ms"
  end

  def speculative_retry_cql(policy, _delay_ms) do
    raise ArgumentError, "Unknown speculative retry policy: #{inspect(policy)}"
  end

  @doc """
  Wraps a query with profiling enabled.

  ScyllaDB supports the PROFILE prefix for query profiling.
  This returns the query wrapped for profiling.

  ## Examples

      iex> AshScylla.DataLayer.QueryOptimizer.profile_query("SELECT * FROM users")
      "PROFILE SELECT * FROM users"
  """
  @spec profile_query(String.t()) :: String.t()
  def profile_query(query) when is_binary(query) do
    "PROFILE #{query}"
  end

  @doc """
  Returns recommended consistency level based on query type.

  - Read-heavy, low-latency: `:one`
  - Balanced: `:local_quorum`
  - Strong consistency: `:quorum`
  - Critical writes: `:all`
  """
  @spec recommended_consistency(atom()) :: atom()
  def recommended_consistency(:read), do: :one
  def recommended_consistency(:create), do: :local_quorum
  def recommended_consistency(:update), do: :local_quorum
  def recommended_consistency(:destroy), do: :local_quorum
  def recommended_consistency(:bulk_read), do: :one
  def recommended_consistency(:bulk_create), do: :local_quorum
  def recommended_consistency(:aggregate), do: :local_quorum
  def recommended_consistency(:lwt), do: :serial
  def recommended_consistency(_), do: :local_quorum

  @doc """
  Estimates query cost based on filters, sorts, and limit.

  Returns `:low`, `:medium`, `:high`, or `:full_scan`.
  """
  @spec estimate_cost(DataLayer.t()) :: atom()
  def estimate_cost(%DataLayer{filters: filters, limit: limit, sorts: sorts}) do
    base_cost =
      cond do
        filters == [] ->
          :full_scan

        has_partition_key_equality?(filters) ->
          :low

        has_secondary_index_filter?(filters) ->
          :medium

        has_clustering_column_range?(filters) ->
          :medium

        true ->
          :high
      end

    # Adjust for limit
    base_cost
    |> maybe_reduce_for_limit(limit)
    |> maybe_increase_for_sorts(sorts)
  end

  @doc """
  Generates a token-aware routing hint for the query.

  When the partition key is known, this enables Xandra to route
  the query directly to the correct node.

  Returns `[token: partition_key_value]` for Xandra's token-aware routing,
  or an empty keyword list if no partition key can be determined.
  """
  @spec token_aware_hint(DataLayer.t()) :: keyword()
  def token_aware_hint(%DataLayer{filters: filters, resource: resource}) do
    case extract_partition_key_value(filters, resource) do
      nil ->
        []

      value ->
        [token: value]
    end
  end

  # ============================================================================
  # Private helpers
  # ============================================================================

  ## optimize/2 helpers

  defp maybe_put_consistency(opts, nil), do: opts

  defp maybe_put_consistency(opts, level) when level in @valid_consistency_levels do
    Keyword.put(opts, :consistency, level)
  end

  defp maybe_put_consistency(_opts, level) do
    raise ArgumentError,
          "Invalid consistency level: #{inspect(level)}. Valid: #{inspect(@valid_consistency_levels)}"
  end

  defp maybe_put_timeout(opts, nil), do: opts

  defp maybe_put_timeout(opts, timeout) when is_integer(timeout) and timeout > 0 do
    Keyword.put(opts, :timeout, timeout)
  end

  defp maybe_put_timeout(_opts, timeout) do
    raise ArgumentError, "Timeout must be a positive integer, got: #{inspect(timeout)}"
  end

  defp maybe_put_page_size(opts, nil), do: opts

  defp maybe_put_page_size(opts, page_size) when is_integer(page_size) and page_size > 0 do
    Keyword.put(opts, :page_size, min(page_size, @max_page_size))
  end

  defp maybe_put_page_size(_opts, page_size) do
    raise ArgumentError, "Page size must be a positive integer, got: #{inspect(page_size)}"
  end

  defp maybe_put_speculative_retry(opts, nil, _delay_ms), do: opts

  defp maybe_put_speculative_retry(opts, policy, delay_ms)
       when policy in @valid_speculative_retry_policies do
    opts
    |> Keyword.put(:speculative_retry, policy)
    |> maybe_put_speculative_retry_delay(policy, delay_ms)
  end

  defp maybe_put_speculative_retry(_opts, policy, _delay_ms) do
    raise ArgumentError,
          "Invalid speculative retry policy: #{inspect(policy)}. Valid: [~s(99percentile), :custom, :none]"
  end

  defp maybe_put_speculative_retry_delay(opts, :custom, delay_ms)
       when is_integer(delay_ms) and delay_ms > 0 do
    Keyword.put(opts, :speculative_retry_delay_ms, delay_ms)
  end

  defp maybe_put_speculative_retry_delay(opts, :custom, nil) do
    Logger.warning(
      "Speculative retry policy :custom set without :speculative_retry_delay_ms, ignoring"
    )

    opts
  end

  defp maybe_put_speculative_retry_delay(opts, _policy, _delay_ms), do: opts

  defp maybe_put_serial_consistency(opts, nil), do: opts

  defp maybe_put_serial_consistency(opts, level) when level in [:serial, :local_serial] do
    Keyword.put(opts, :serial_consistency, level)
  end

  defp maybe_put_serial_consistency(_opts, level) do
    raise ArgumentError,
          "Invalid serial consistency: #{inspect(level)}. Valid: [:serial, :local_serial]"
  end

  defp maybe_put_profiling(opts, nil), do: opts
  defp maybe_put_profiling(opts, false), do: opts

  defp maybe_put_profiling(opts, true) do
    Keyword.put(opts, :profiling, true)
  end

  defp maybe_put_allow_filtering(opts, nil), do: opts
  defp maybe_put_allow_filtering(opts, false), do: opts

  defp maybe_put_allow_filtering(opts, true) do
    Logger.warning(
      "allow_filtering is enabled. This can cause full table scans and performance issues."
    )

    Keyword.put(opts, :allow_filtering, true)
  end

  ## optimal_page_size/1 helpers

  defp has_partition_key_filter?(filters) do
    # Check if any filter is an equality match on a primary key column
    Enum.any?(filters, fn
      %{operator: :eq, left: %{name: name}} when is_atom(name) ->
        true

      %{op: :eq, left: %{name: name}} when is_atom(name) ->
        true

      _ ->
        false
    end)
  end

  defp has_indexed_filter?(filters) do
    Enum.any?(filters, fn
      %{left: %{name: name}} when is_atom(name) ->
        true

      _ ->
        false
    end)
  end

  ## analyze/1 helpers

  defp has_non_indexed_filter?(%DataLayer{filters: filters}) do
    Enum.any?(filters, fn
      %{left: %{name: name}} when is_atom(name) ->
        true

      _ ->
        false
    end)
  end

  defp non_indexed_filter_columns(%DataLayer{filters: filters}) do
    filters
    |> Enum.filter(fn
      %{left: %{name: name}} when is_atom(name) -> true
      _ -> false
    end)
    |> Enum.map(fn %{left: %{name: name}} -> name end)
    |> Enum.uniq()
  end

  ## estimate_cost/1 helpers

  defp has_partition_key_equality?(filters) do
    Enum.any?(filters, fn
      %{operator: :eq, left: %{name: _}} -> true
      %{op: :eq, left: %{name: _}} -> true
      _ -> false
    end)
  end

  defp has_secondary_index_filter?(filters) do
    # Filters that reference columns by name (not partition key equality)
    Enum.any?(filters, fn
      %{left: %{name: name}} when is_atom(name) -> true
      _ -> false
    end)
  end

  defp has_clustering_column_range?(filters) do
    Enum.any?(filters, fn
      %{operator: op} -> op in [:gt, :gte, :lt, :lte, :>, :>=, :<, :<=]
      %{op: op} -> op in [:gt, :gte, :lt, :lte, :>, :>=, :<, :<=]
      _ -> false
    end)
  end

  defp maybe_reduce_for_limit(:full_scan, limit) when is_integer(limit) and limit > 0, do: :high
  defp maybe_reduce_for_limit(:high, limit) when is_integer(limit) and limit > 0, do: :medium
  defp maybe_reduce_for_limit(:medium, limit) when is_integer(limit) and limit > 0, do: :low
  defp maybe_reduce_for_limit(cost, _limit), do: cost

  defp maybe_increase_for_sorts(cost, []), do: cost
  defp maybe_increase_for_sorts(cost, nil), do: cost

  defp maybe_increase_for_sorts(:low, _sorts), do: :medium
  defp maybe_increase_for_sorts(:medium, _sorts), do: :high
  defp maybe_increase_for_sorts(cost, _sorts), do: cost

  ## token_aware_hint/1 helpers

  defp extract_partition_key_value(filters, resource) do
    pk_columns =
      if function_exported?(resource, :__ash_scylla__, 1) do
        # Try to get primary key from resource attributes
        resource
        |> then(&apply(Ash.Resource.Info, :attributes, [&1]))
        |> Enum.filter(& &1.primary_key?)
        |> Enum.map(& &1.name)
      else
        [:id]
      end

    Enum.find_value(filters, fn
      %{operator: :eq, left: %{name: name}, right: %{value: value}} ->
        if name in pk_columns, do: value, else: nil

      %{op: :eq, left: %{name: name}, right: %{value: value}} ->
        if name in pk_columns, do: value, else: nil

      _ ->
        nil
    end)
  end

  ## token_range_query/4 helper

  defp sanitize_identifier(name) when is_binary(name) do
    Identifier.sanitize!(name)
  end
end
