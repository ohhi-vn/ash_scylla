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
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

defmodule AshScylla.DataLayer do
  @moduledoc """
  An Ash data layer for ScyllaDB using Xandra (direct CQL driver).

  This data layer implements the `Ash.DataLayer` behaviour to allow Ash resources
  to be backed by ScyllaDB/Cassandra.

  ## Configuration

  Configure your resource to use this data layer:

      defmodule MyApp.MyResource do
        use Ash.Resource,
          data_layer: AshScylla.DataLayer

        attributes do
          uuid_primary_key :id
          attribute :name, :string
        end

        relationships do
          # Define relationships as needed
        end
      end

  ## Features Supported

  - `:create` - Create records
  - `:read` - Read records with filtering
  - `:update` - Update records
  - `:destroy` - Delete records
  - `:filter` - Filter queries
  - `:limit` - Limit results
  - `:select` - Select specific fields
  - `:multitenancy` - Keyspace-based multitenancy
  - `:upsert` - Upsert records (INSERT IF NOT EXISTS with LWT)
  - `:update_query` - Bulk update via filtered queries
  - `:destroy_query` - Bulk delete via filtered queries
  - `:keyset` - Token-based keyset pagination (the default pagination mode)
  - `:distinct` - DISTINCT on partition key columns
  - `:sort` / `{:sort, _}` - ORDER BY on clustering columns
  - `:boolean_filter` - OR filter rewriting to IN where possible
  - `:nested_expressions` - Nested filter expressions
  - `{:filter_expr, _}` - Filter expression support
  - `:changeset_filter` - Changeset-based filtering
  - `:calculate` - In-memory calculations
  - `:action_select` - Action-specific select
  - `:async_engine` - Async engine support
  - `:bulk_create` - Batch INSERT operations
  - `:transact` - Transaction wrapper
  - `:composite_primary_key` - Composite primary key support
  - `{:aggregate, :count}` / `{:aggregate, :sum}` / `{:aggregate, :avg}` / `{:aggregate, :min}` / `{:aggregate, :max}` - Per-partition aggregate functions
  - `{:query_aggregate, :count}` / `{:query_aggregate, :sum}` / `{:query_aggregate, :avg}` / `{:query_aggregate, :min}` / `{:query_aggregate, :max}` - Query-level aggregate functions (`Ash.count/2`, `Ash.sum/2`, etc.)
  - `{:aggregate_relationship, _}` - Relationship aggregates (belongs_to via per-record subqueries)
  - `{:atomic, :update}` - Atomic updates via LWT (IF clauses)
  - `{:atomic, :upsert}` - Atomic upserts via LWT
  - `{:atomic, :create}` - Atomic creates

  ## Features NOT Supported

  - `:offset` - ScyllaDB has no OFFSET; use keyset pagination
  - `:expr_error` - Expression error handling not implemented
  - `:expression_calculation_sort` - Not supported
  - `:aggregate_filter` - Aggregate filtering not supported
  - `:aggregate_sort` - Aggregate sorting not supported
  - `:bulk_create_with_partial_success` - Bulk create is all-or-nothing
  - `:update_many` - Update-many not implemented
  - `:composite_type` - Composite types not supported
  - `:through_relationship` - Through relationships not supported
  - `:bulk_upsert_return_skipped` - Not supported
  - `:distinct_sort` - Not supported
  - `{:combine, :union}` / `{:combine, :union_all}` / `{:combine, :intersection}` - No combination queries
  - `{:lock, :for_update}` - Locking is a no-op
  - `{:join, _}` - No JOINs (use denormalization)
  - `{:lateral_join, _}` - No lateral joins
  - `{:filter_relationship, _}` - Relationship filtering not supported
  - `{:exists, :unrelated}` - Exists queries not supported
  - `{:aggregate, :unrelated}` - Unrelated aggregates not supported
  - `{:query_aggregate, :list}` / `{:query_aggregate, :first}` / `{:query_aggregate, :exists}` / `{:query_aggregate, :custom}` - Only COUNT, SUM, AVG, MIN, MAX are supported
  - `{:aggregate, :list}` / `{:aggregate, :first}` / `{:aggregate, :exists}` / `{:aggregate, :custom}` - Only COUNT, SUM, AVG, MIN, MAX are supported
  - `{:aggregate, :unrelated}` - Unrelated aggregates not supported

  ## Ash Query Extensions

  The following Ash 3.0+ query features are supported via Xandra:
  - `fragment/1+` — raw CQL injection: `fragment("col = ?", value)` passes through to Xandra directly
  - `now()`, `today()`, `ago(...)`, `from_now(...)` — evaluated client-side by Ash before reaching the data layer
  - `has(collection_col, value)` — maps to CQL `CONTAINS` on collection/set/list columns
  - `overlaps(collection_col, [a, b])` — maps to `col CONTAINS a OR col CONTAINS b` with ALLOW FILTERING
  - Arithmetic operators (`+`, `-`, `*`, `/`) — evaluated client-side by Ash
  - String functions (`concat`, `contains`, `starts_with`, `ends_with`, `string_length`, etc.) — maps to CQL `LIKE` where applicable
  - `if/3`, `is_nil/1`, `length/1`, `round/1`, `string_downcase/1`, `string_trim/1` — evaluated client-side by Ash

  ## Limitations

  Since ScyllaDB/Cassandra is a wide-column store, not all SQL features are supported:
  - No JOINs (use denormalization or multiple queries)
  - Expression calculations are done in Elixir post-processing (not in-database)
  - DISTINCT only works on partition key columns
  - Limited aggregation support
  - Combination queries (UNION/INTERSECT) are not supported
  - No transactions across partitions (lightweight transactions only)
  - Locking is a no-op (use LWT for conditional operations)
  - No complex WHERE clauses on non-primary key columns without secondary indexes
  - Cross-partition aggregates require materialized views
  - CQL ORDER BY only works on clustering columns within a partition

  ## Filtering with LIKE (`contains` / `starts_with` / `ends_with`)

  Ash's `contains/2`, `starts_with/2`, and `ends_with/2` are translated to CQL
  `LIKE`. In ScyllaDB, `LIKE` is only available on columns indexed with a
  SASI index (or a similar text index). A `LIKE` filter against an unindexed
  column will fail at query time rather than silently returning wrong results.
  If you rely on substring/prefix/suffix matching, declare a SASI index on the
  relevant column (e.g. via `secondary_index` with the appropriate index type)
  or expect the query to error.
  """

  @behaviour Ash.DataLayer
  @behaviour Ash.Extension

  # Ash discovers extensions for `mix ash.codegen` / `mix ash.migrate` / etc. by
  # scanning all modules that implement the `Spark.Dsl.Extension` behaviour.
  # The data layer module doubles as the extension (per Ash's own data layers),
  # so we declare it as a (section-less) Spark DSL extension here. The actual
  # callback logic lives in `AshScylla.Extension`, which this module forwards to.
  use Spark.Dsl.Extension, sections: []

  require Logger

  alias Ash.Resource.Info
  alias Ash.Type.UUID
  alias AshScylla.DataLayer.Batch
  alias AshScylla.DataLayer.Dsl
  alias AshScylla.DataLayer.FilterValidator
  alias AshScylla.DataLayer.QueryBuilder
  alias AshScylla.DataLayer.Types
  alias AshScylla.Identifier
  alias AshScylla.Telemetry

  @dialyzer :no_match

  @compile {:inline, sanitize_identifier: 1}

  @default_query_timeout 30_000
  @default_batch_size 100
  @max_batch_size 1000

  @supported_features MapSet.new([
                        :create,
                        :read,
                        :update,
                        :destroy,
                        :filter,
                        :limit,
                        :select,
                        :multitenancy,
                        :bulk_create,
                        :upsert,
                        :update_query,
                        :destroy_query,
                        :distinct,
                        :keyset,
                        :boolean_filter,
                        :transact,
                        :composite_primary_key,
                        :changeset_filter,
                        :sort,
                        :calculate,
                        :action_select,
                        :nested_expressions,
                        :async_engine
                      ])

  # Query struct is owned by AshScylla.Query — this module operates on it.
  alias AshScylla.Query

  @type t :: Query.t()

  # ============================================================================
  # Required Callbacks
  # ============================================================================

  @impl Ash.DataLayer
  def can?(_resource_or_dsl, {:atomic, :update}) do
    # LWT is supported - Ash will use it when resource has lwt: true
    true
  end

  @impl Ash.DataLayer
  def can?(_resource_or_dsl, {:atomic, :upsert}) do
    true
  end

  @impl Ash.DataLayer
  def can?(_resource_or_dsl, {:atomic, :create}) do
    true
  end

  @impl Ash.DataLayer
  def can?(_resource_or_dsl, :upsert), do: true

  @impl Ash.DataLayer
  def can?(_resource_or_dsl, :keyset), do: true

  @impl Ash.DataLayer
  def can?(_resource_or_dsl, :boolean_filter), do: true

  @impl Ash.DataLayer
  def can?(_resource_or_dsl, :distinct), do: true

  @impl Ash.DataLayer
  def can?(_resource_or_dsl, :expression_calculation), do: true

  @impl Ash.DataLayer
  def can?(_resource_or_dsl, :lateral_join), do: false

  @impl Ash.DataLayer
  def can?(_resource_or_dsl, {:aggregate, kind}) when kind in [:count, :sum, :avg, :min, :max],
    do: true

  @impl Ash.DataLayer
  def can?(_resource_or_dsl, {:aggregate, _}), do: false

  @impl Ash.DataLayer
  def can?(_resource_or_dsl, :update_query), do: true

  @impl Ash.DataLayer
  def can?(_resource_or_dsl, :destroy_query), do: true

  @impl Ash.DataLayer
  def can?(_resource_or_dsl, :lock), do: false

  @impl Ash.DataLayer
  def can?(_resource_or_dsl, {:filter_expr, _}), do: true

  @impl Ash.DataLayer
  def can?(_resource_or_dsl, {:sort, _}), do: true

  @impl Ash.DataLayer
  def can?(_resource_or_dsl, :bulk_create), do: true

  @impl Ash.DataLayer
  def can?(_resource_or_dsl, :transact), do: true

  @impl Ash.DataLayer
  def can?(_resource_or_dsl, :composite_primary_key), do: true

  @impl Ash.DataLayer
  def can?(_resource_or_dsl, :changeset_filter), do: true

  @impl Ash.DataLayer
  def can?(_resource_or_dsl, :calculate), do: true

  @impl Ash.DataLayer
  def can?(_resource_or_dsl, :action_select), do: true

  @impl Ash.DataLayer
  def can?(_resource_or_dsl, :nested_expressions), do: true

  @impl Ash.DataLayer
  def can?(_resource_or_dsl, :async_engine), do: true

  # ── Unsupported features ──────────────────────────────────────────────

  @impl Ash.DataLayer
  def can?(_resource_or_dsl, :offset), do: false

  @impl Ash.DataLayer
  def can?(_resource_or_dsl, :expr_error), do: false

  @impl Ash.DataLayer
  def can?(_resource_or_dsl, :expression_calculation_sort), do: false

  @impl Ash.DataLayer
  def can?(_resource_or_dsl, :aggregate_filter), do: false

  @impl Ash.DataLayer
  def can?(_resource_or_dsl, :aggregate_sort), do: false

  @impl Ash.DataLayer
  def can?(_resource_or_dsl, :bulk_create_with_partial_success), do: false

  @impl Ash.DataLayer
  def can?(_resource_or_dsl, :update_many), do: false

  @impl Ash.DataLayer
  def can?(_resource_or_dsl, :composite_type), do: false

  @impl Ash.DataLayer
  def can?(_resource_or_dsl, :through_relationship), do: false

  @impl Ash.DataLayer
  def can?(_resource_or_dsl, :bulk_upsert_return_skipped), do: false

  @impl Ash.DataLayer
  def can?(_resource_or_dsl, :distinct_sort), do: false

  @impl Ash.DataLayer
  def can?(_resource_or_dsl, {:combine, :union}), do: false

  @impl Ash.DataLayer
  def can?(_resource_or_dsl, {:combine, :union_all}), do: false

  @impl Ash.DataLayer
  def can?(_resource_or_dsl, {:combine, :intersection}), do: false

  @impl Ash.DataLayer
  def can?(_resource_or_dsl, {:lock, :for_update}), do: false

  @impl Ash.DataLayer
  def can?(_resource_or_dsl, {:join, _other_resource}) do
    false
  end

  @impl Ash.DataLayer
  def can?(_resource_or_dsl, {:lateral_join, _resources}) do
    false
  end

  @impl Ash.DataLayer
  def can?(_resource_or_dsl, {:filter_relationship, _relationship}) do
    false
  end

  @impl Ash.DataLayer
  def can?(_resource_or_dsl, {:exists, :unrelated}), do: false

  @impl Ash.DataLayer
  def can?(_resource_or_dsl, {:aggregate_relationship, _relationship}) do
    true
  end

  @impl Ash.DataLayer
  def can?(_resource_or_dsl, {:query_aggregate, kind})
      when kind in [:count, :sum, :avg, :min, :max],
      do: true

  @impl Ash.DataLayer
  def can?(_resource_or_dsl, {:query_aggregate, _kind}), do: false

  @impl Ash.DataLayer
  def can?(_resource_or_dsl, feature) when is_atom(feature) do
    MapSet.member?(@supported_features, feature)
  end

  @impl Ash.DataLayer
  def can?(_resource_or_dsl, _other) do
    false
  end

  @impl Ash.DataLayer
  @spec data_layer_keyset_by_default?() :: boolean()
  def data_layer_keyset_by_default? do
    true
  end

  @impl Ash.DataLayer
  @spec return_query(t(), Ash.Resource.t()) :: {:ok, t()} | {:error, term()}
  def return_query(data_layer_query, _resource) do
    {:ok, data_layer_query}
  end

  @impl Ash.DataLayer
  @spec resource_to_query(Ash.Resource.t(), Ash.Domain.t()) :: t()
  def resource_to_query(resource, _domain) do
    table = source(resource)

    %Query{
      resource: resource,
      repo: repo(resource),
      table: table,
      filters: []
    }
  end

  @impl Ash.DataLayer
  @spec create(Ash.Resource.t(), Ash.Changeset.t()) :: {:ok, Ash.Resource.t()} | {:error, term()}
  def create(resource, changeset) do
    repo = repo(resource)

    changeset
    |> changeset_to_insert_attrs(resource)
    |> do_insert(resource, repo)
  end

  @impl Ash.DataLayer
  @spec update(Ash.Resource.t(), Ash.Changeset.t()) :: {:ok, Ash.Resource.t()} | {:error, term()}
  def update(resource, changeset) do
    repo = repo(resource)

    changeset
    |> changeset_to_update_attrs(resource)
    |> do_update(changeset, resource, repo)
  end

  @impl Ash.DataLayer
  @spec prefer_transaction?(Ash.Resource.t()) :: boolean()
  def prefer_transaction?(resource) do
    # ScyllaDB supports lightweight transactions (LWT) but not full ACID transactions.
    # Only prefer transaction mode when LWT is enabled.
    Dsl.lwt(resource) == true
  end

  @impl Ash.DataLayer
  @spec prefer_transaction_for_atomic_updates?(Ash.Resource.t()) :: boolean()
  def prefer_transaction_for_atomic_updates?(resource) do
    Dsl.lwt(resource) == true
  end

  @impl Ash.DataLayer
  @spec in_transaction?(Ash.Resource.t()) :: boolean()
  def in_transaction?(_resource) do
    # ScyllaDB doesn't have a traditional transaction state.
    # LWT operations are atomic but not part of a multi-statement transaction.
    false
  end

  @impl Ash.DataLayer
  @spec transaction(Ash.Resource.t(), function(), timeout() | nil, term()) ::
          {:ok, term()} | {:error, term()}
  def transaction(_resource, func, _timeout \\ nil, _reason \\ %{type: :custom, metadata: %{}}) do
    # ScyllaDB doesn't support multi-statement transactions.
    # We execute the function directly and wrap errors.
    # For LWT operations, individual statements are already atomic.
    result = func.()
    {:ok, result}
  rescue
    e -> {:error, Ash.Error.to_ash_error(e, __STACKTRACE__)}
  end

  @impl Ash.DataLayer
  @spec rollback(Ash.Resource.t(), term()) :: :ok | {:error, term()}
  def rollback(_resource, _reason) do
    # ScyllaDB doesn't support rollback of multi-statement transactions.
    # Individual LWT operations are atomic and don't need rollback.
    :ok
  end

  @impl Ash.DataLayer
  @spec destroy(Ash.Resource.t(), Ash.Changeset.t()) :: :ok | {:error, term()}
  def destroy(resource, changeset) do
    repo = repo(resource)

    case do_delete(changeset, resource, repo) do
      :ok -> :ok
      {:error, _} = error -> error
    end
  end

  @impl Ash.DataLayer
  @spec run_query(t(), Ash.Resource.t()) :: {:ok, [Ash.Resource.t()]} | {:error, term()}
  def run_query(data_layer_query, resource) do
    %Query{repo: repo, table: table, tenant: tenant, filters: filters, sorts: sorts} =
      data_layer_query

    Logger.debug("AshScylla: Data Layer query #{inspect(data_layer_query)}")
    Logger.debug("AshScylla: Filter query: #{inspect(filters)}")

    # Validate filters to prevent ALLOW FILTERING anti-pattern
    FilterValidator.validate_filters(resource, filters)

    # Build the optimized query with filters, sorts, limit, offset
    case QueryBuilder.build_optimized_query(data_layer_query) do
      {:error, {:unknown_filter, unknown}} ->
        raise AshScylla.Error,
          message:
            "AshScylla: Unable to translate filter expression to CQL: " <>
              "#{inspect(unknown)}. The query was not executed to avoid returning " <>
              "a broader result set than intended."

      {:ok, {query, params}} ->
        execute_single_query(
          data_layer_query,
          resource,
          repo,
          table,
          tenant,
          query,
          params,
          filters,
          sorts
        )
    end
  rescue
    e in [AshScylla.Error] ->
      # Handle OR split: CQL has no OR, so split into two queries and merge
      case e do
        %AshScylla.Error{or_split: {left, right}} ->
          query = data_layer_query
          left_query = %{query | filters: [left]}
          right_query = %{query | filters: [right]}

          with {:ok, left_records} <- run_query(left_query, resource),
               {:ok, right_records} <- run_query(right_query, resource) do
            # Merge and deduplicate by id
            merged = (left_records ++ right_records) |> Enum.uniq_by(& &1.id)
            {:ok, merged}
          end

        _ ->
          reraise(e, __STACKTRACE__)
      end

    e ->
      handle_result({:error, e})
  end

  defp execute_single_query(
         data_layer_query,
         resource,
         repo,
         table,
         tenant,
         query,
         params,
         filters,
         sorts
       ) do
    # Detect if ORDER BY was dropped due to secondary index scan
    order_dropped? =
      resource != nil and sorts != [] and sorts != nil and
        QueryBuilder.secondary_index_scan?(resource, filters)

    opts = build_query_opts(resource, tenant)

    Logger.debug("Executing run_query on #{table}")
    Logger.debug("AshScylla: Final query: #{inspect(query)}")
    Logger.debug("AshScylla: Final params: #{inspect(params)}")

    result =
      Telemetry.span(resource, :read, query, fn ->
        case repo.query(query, params, opts) do
          {:ok, %Xandra.Page{content: content, columns: columns}} when columns != nil ->
            rows = content || []
            records = Enum.map(rows, &to_ash_record(&1, resource, columns))
            records = maybe_apply_in_memory_sort(records, sorts, order_dropped?)
            {:ok, records}

          {:ok, %Xandra.Page{content: content}} ->
            rows = content || []
            records = Enum.map(rows, &to_ash_record(&1, resource))
            records = maybe_apply_in_memory_sort(records, sorts, order_dropped?)
            {:ok, records}

          error ->
            handle_result(error)
        end
      end)

    with {:ok, records} <- result do
      %Query{context: context} = data_layer_query
      aggregates = Map.get(context, :aggregates, [])
      records = apply_calculations(records, context)
      records = attach_aggregates(records, aggregates, resource, repo, opts)
      {:ok, records}
    end
  end

  # When ORDER BY is dropped due to secondary index scan, apply sorting in-memory
  # to compensate. This is not ideal for large result sets but ensures correctness.
  defp maybe_apply_in_memory_sort(records, sorts, true) do
    sort_keys =
      Enum.map(sorts, fn
        {field, _direction} when is_atom(field) -> field
        field when is_atom(field) -> field
        %{field: field} -> field
      end)

    Enum.sort_by(records, fn record ->
      Enum.map(sort_keys, fn sort_field ->
        value = Map.get(record, sort_field)
        # Ensure nil values sort last
        {value == nil, value}
      end)
    end)
  end

  defp maybe_apply_in_memory_sort(records, _, false), do: records

  # ============================================================================
  # Optional Callbacks - Filter
  # ============================================================================

  @impl Ash.DataLayer
  @spec filter(t(), term(), Ash.Resource.t()) :: {:ok, t()}
  def filter(data_layer_query, filter, _resource) do
    %Query{filters: filters} = data_layer_query
    {:ok, %{data_layer_query | filters: [maybe_rewrite_or_to_in(filter) | filters]}}
  end

  # Rewrites a 2-way OR of equality predicates on the same column into a single
  # IN filter, since CQL does not support OR. Returns the rewritten filter (with
  # an `:operator` key) or the original filter when no rewrite applies.
  @doc false
  @spec maybe_rewrite_or_to_in(term()) :: term()
  def maybe_rewrite_or_to_in(%{op: :or, left: left, right: right} = filter) do
    case QueryBuilder.rewrite_or_to_in(left, right) do
      {:ok, {field_name, values}} ->
        %{
          operator: :in,
          left: %{name: field_name},
          right: %{value: values}
        }

      :error ->
        filter
    end
  end

  def maybe_rewrite_or_to_in(filter), do: filter

  # ============================================================================
  # Optional Callbacks - Sort
  # ============================================================================

  @impl Ash.DataLayer
  @spec sort(t(), term(), Ash.Resource.t()) :: {:ok, t()}
  def sort(data_layer_query, sort, _resource) do
    %Query{sorts: sorts} = data_layer_query

    {:ok, %{data_layer_query | sorts: sort ++ sorts}}
  end

  # ============================================================================
  # Optional Callbacks - Limit/Offset
  # ============================================================================

  @impl Ash.DataLayer
  @spec limit(t(), pos_integer(), Ash.Resource.t()) :: {:ok, t()}
  def limit(data_layer_query, limit, _resource) do
    {:ok, %{data_layer_query | limit: limit}}
  end

  # offset callback removed — CQL doesn't support OFFSET

  # ============================================================================
  # Optional Callbacks - Select
  # ============================================================================

  @impl Ash.DataLayer
  @spec select(t(), list(atom()), Ash.Resource.t()) :: {:ok, t()}
  def select(data_layer_query, select, _resource) do
    {:ok, %{data_layer_query | select: select}}
  end

  # ============================================================================
  # Optional Callbacks - Multitenancy
  # ============================================================================

  @impl Ash.DataLayer
  @spec set_tenant(t(), term(), Ash.Resource.t()) :: {:ok, t()}
  def set_tenant(resource, data_layer_query, tenant) do
    if is_nil(resource) do
      {:ok, %{data_layer_query | tenant: tenant}}
    else
      strategy = Ash.Resource.Info.multitenancy_strategy(resource)

      case strategy do
        :context ->
          {:ok, %{data_layer_query | tenant: tenant}}

        :attribute ->
          attribute = Ash.Resource.Info.multitenancy_attribute(resource)

          if attribute do
            filter(
              data_layer_query,
              %{name: attribute, op: :eq, right: %{value: tenant}},
              resource
            )
          else
            {:ok, %{data_layer_query | tenant: tenant}}
          end

        nil ->
          {:ok, %{data_layer_query | tenant: tenant}}
      end
    end
  end

  @impl Ash.DataLayer
  @spec set_context(Ash.Resource.t(), t(), map()) :: {:ok, t()}
  def set_context(_resource, data_layer_query, context) do
    %Query{context: existing} = data_layer_query
    merged = Map.merge(existing || %{}, context)
    {:ok, %{data_layer_query | context: merged}}
  end

  @impl Ash.DataLayer
  @spec transform_query(Ash.Query.t()) :: Ash.Query.t()
  def transform_query(query) do
    # Apply base_filter from DSL configuration if present
    resource = query.resource
    base_filter = Dsl.base_filter(resource)

    query =
      if base_filter do
        Ash.Query.do_filter(query, base_filter)
      else
        query
      end

    # Apply default_context from DSL configuration if present
    default_context = Dsl.default_context(resource)

    if default_context do
      Ash.Query.set_context(query, default_context)
    else
      query
    end
  end

  @impl Ash.DataLayer
  @spec bulk_create(Ash.Resource.t(), Enumerable.t(Ash.Changeset.t()), map()) ::
          :ok | {:ok, Enumerable.t(Ash.Resource.t())} | {:error, term()}
  def bulk_create(resource, changesets, opts) do
    opts = normalize_bulk_options(opts)
    repo = repo(resource)
    ttl = Dsl.ttl(resource)
    consistency = Dsl.consistency(resource)
    sanitized_table = qualified_table(resource)

    batch_size =
      opts
      |> Keyword.get(:batch_size, @default_batch_size)
      |> min(@max_batch_size)

    return_records? = Keyword.get(opts, :return_records?, true)

    statements =
      changesets
      |> Enum.map(fn changeset ->
        attrs = changeset_to_insert_attrs(changeset, resource)
        build_insert_statement(sanitized_table, attrs, ttl, resource)
      end)

    opts =
      []
      |> maybe_put(:consistency, consistency)

    Logger.info("Bulk creating records in table #{source(resource)}")

    result =
      statements
      |> chunk_statements(batch_size)
      |> Enum.reduce_while(:ok, fn chunk, _acc ->
        case Batch.batch_insert(repo, chunk, opts) do
          :ok -> {:cont, :ok}
          {:ok, _} -> {:cont, :ok}
          {:error, error} -> {:halt, {:error, error}}
        end
      end)

    case result do
      :ok when return_records? -> {:ok, stream_bulk_records(changesets, resource)}
      :ok -> {:ok, []}
      {:error, error} -> handle_result({:error, error})
    end
  end

  @spec upsert(Ash.Resource.t(), Ash.Changeset.t()) ::
          {:ok, Ash.Resource.t()} | {:error, term()}
  def upsert(resource, changeset) do
    upsert(resource, changeset, Info.primary_key(resource))
  end

  @impl Ash.DataLayer
  @spec upsert(Ash.Resource.t(), Ash.Changeset.t(), list(atom)) ::
          {:ok, Ash.Resource.t()} | {:error, term()}
  def upsert(resource, changeset, fields) do
    repo = repo(resource)
    attrs = changeset_to_insert_attrs(changeset, resource)
    do_upsert(attrs, changeset, resource, repo, fields: fields)
  end

  @impl Ash.DataLayer
  @spec upsert(Ash.Resource.t(), Ash.Changeset.t(), list(atom), Ash.Resource.Identity.t() | nil) ::
          {:ok, Ash.Resource.t()} | {:error, term()}
  def upsert(resource, changeset, fields, _identity) do
    upsert(resource, changeset, fields)
  end

  @impl Ash.DataLayer
  @spec source(Ash.Resource.t()) :: String.t()
  def source(resource) do
    # Cache the resolved table name per resource to avoid repeated Module.get_attribute calls.
    # This function is called multiple times per request (create, update, delete, fetch).
    case Process.get({__MODULE__, :source, resource}) do
      nil ->
        resolved = resolve_table_name(resource)
        Process.put({__MODULE__, :source, resource}, resolved)
        resolved

      cached ->
        cached
    end
  rescue
    ArgumentError ->
      # Only the specific ArgumentError from an unset module attribute is expected
      # here; any other exception is a real bug and should propagate.
      resolve_table_name(resource)
  end

  # Resolves the table name for a resource, using domain-prefixed names to avoid
  # collisions when multiple domains have resources with the same name.
  # e.g. Games.Stats -> "games_stats", OfflineGame.Stats -> "offline_game_stats"
  @doc false
  @spec resolve_table_name(module()) :: String.t()
  def resolve_table_name(resource) do
    case Dsl.table(resource) do
      nil ->
        segments = Module.split(resource)

        # Check if resource has a domain (real app resource vs test resource)
        name =
          if Ash.Resource.Info.domain(resource) do
            # Use last two segments (domain_resource) to avoid collisions
            # e.g. Games.Stats -> "games_stats", OfflineGame.Stats -> "offline_game_stats"
            segments
            |> Enum.take(-2)
            |> Enum.map_join("_", &Macro.underscore/1)
          else
            # No domain (test resources, etc.) — use just the last segment
            segments
            |> List.last()
            |> Macro.underscore()
          end

        # Fall back to @table attribute if it exists (safe for compiled modules)
        table_attr =
          try do
            Module.get_attribute(resource, :table)
          rescue
            ArgumentError -> nil
          end

        case table_attr do
          nil -> name
          "" -> name
          table -> to_string(table)
        end

      dsl_table ->
        to_string(dsl_table)
    end
    |> QueryBuilder.cql_identifier()
  end

  # ============================================================================
  # Optional Callbacks - Bulk Update / Delete / Distinct / Lock / Combination
  # ============================================================================

  @impl Ash.DataLayer
  @spec update_query(t(), Ash.Changeset.t(), keyword(), Ash.Resource.t()) ::
          {:ok, [Ash.Resource.t()]} | {:error, term()}
  def update_query(data_layer_query, changeset, resource, _opts) do
    repo = repo(resource)
    opts = build_opts(resource)
    sanitized_table = qualified_table(resource)
    attrs = changeset_to_update_attrs(changeset, resource)

    {set_clauses, set_values} = build_set_clauses(attrs, resource)

    %Query{filters: filters} = data_layer_query

    where_result =
      case filters do
        [] ->
          {clause, params} = build_pk_where_clause(changeset, resource)
          {:ok, {clause, params}}

        _ ->
          uuid_fields = uuid_attribute_names(resource)
          cql_types = attr_cql_type_map(resource)
          QueryBuilder.build_where_clause(filters, uuid_fields, cql_types)
      end

    case where_result do
      {:error, {:unknown_filter, unknown}} ->
        raise AshScylla.Error,
          message:
            "AshScylla: Unable to translate filter expression to CQL: " <>
              "#{inspect(unknown)}. The query was not executed to avoid returning " <>
              "a broader result set than intended."

      {:ok, {where_clause, where_params}} ->
        query =
          IO.iodata_to_binary([
            "UPDATE ",
            sanitized_table,
            " SET ",
            Enum.join(set_clauses, ", "),
            " WHERE ",
            where_clause
          ])

        Logger.debug("Executing bulk UPDATE on #{sanitized_table}")

        with {:ok, _} <- repo.query(query, set_values ++ where_params, opts) do
          run_query(data_layer_query, resource)
        end
    end
  end

  @impl Ash.DataLayer
  @spec destroy_query(t(), Ash.Changeset.t(), keyword(), Ash.Resource.t()) ::
          :ok | {:error, term()}
  def destroy_query(data_layer_query, changeset, _opts, resource) do
    repo = repo(resource)
    opts = build_opts(resource)
    sanitized_table = qualified_table(resource)

    %Query{filters: filters} = data_layer_query

    where_result =
      case filters do
        [] ->
          {clause, params} = build_pk_where_clause(changeset, resource)
          {:ok, {clause, params}}

        _ ->
          uuid_fields = uuid_attribute_names(resource)
          cql_types = attr_cql_type_map(resource)
          QueryBuilder.build_where_clause(filters, uuid_fields, cql_types)
      end

    case where_result do
      {:error, {:unknown_filter, unknown}} ->
        raise AshScylla.Error,
          message:
            "AshScylla: Unable to translate filter expression to CQL: " <>
              "#{inspect(unknown)}. The query was not executed to avoid returning " <>
              "a broader result set than intended."

      {:ok, {where_clause, where_params}} ->
        # Check if this is a secondary index scan (for bulk delete by filter)
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

        filter_columns = QueryBuilder.get_filter_columns(filters)

        needs_allow_filtering =
          filter_columns != [] and
            Enum.any?(filter_columns, fn col -> MapSet.member?(secondary_indexed_columns, col) end) and
            Enum.all?(filter_columns, fn col ->
              MapSet.member?(pk_columns, col) or MapSet.member?(secondary_indexed_columns, col)
            end)

        query =
          IO.iodata_to_binary([
            "DELETE FROM ",
            sanitized_table,
            " WHERE ",
            where_clause,
            if(needs_allow_filtering, do: " ALLOW FILTERING", else: "")
          ])

        Logger.debug("Executing bulk DELETE on #{sanitized_table}")

        with {:ok, _} <- repo.query(query, where_params, opts), do: :ok
    end
  end

  @impl Ash.DataLayer
  @spec distinct(t(), list(atom()), Ash.Resource.t()) :: {:ok, t()} | {:error, term()}
  def distinct(data_layer_query, distinct_columns, resource) do
    pk_columns =
      resource
      |> Info.attributes()
      |> Enum.filter(& &1.primary_key?)
      |> Enum.map(& &1.name)

    all_pk? = Enum.all?(distinct_columns, &(&1 in pk_columns))

    if all_pk? do
      # Store distinct columns in the query struct via the select field
      %Query{select: existing_select} = data_layer_query
      select = ((existing_select || []) ++ distinct_columns) |> Enum.uniq()
      {:ok, %{data_layer_query | select: select}}
    else
      {:error,
       AshScylla.Error.ScyllaError.from_error(
         "DISTINCT on non-partition-key columns is not supported in ScyllaDB/Cassandra. " <>
           "Distinct columns: #{inspect(distinct_columns)}. " <>
           "Partition key columns: #{inspect(pk_columns)}. " <>
           "Consider using a materialized view instead."
       )}
    end
  end

  @impl Ash.DataLayer
  @spec lock(t(), term(), Ash.Resource.t()) :: {:ok, t()}
  def lock(data_layer_query, _lock_type, _resource) do
    # ScyllaDB/Cassandra doesn't support row-level locking.
    # LWT (Lightweight Transactions) are handled via atomic updates instead.
    {:ok, data_layer_query}
  end

  @impl Ash.DataLayer
  @spec combination_of(t(), term(), Ash.Resource.t()) :: {:ok, t()} | {:error, term()}
  def combination_of(_data_layer_query, _combination, _resource) do
    {:error,
     AshScylla.Error.ScyllaError.from_error(
       "Combination queries (UNION/INTERSECT) are not supported in ScyllaDB/Cassandra. " <>
         "Ash will fall back to in-memory combination of separate query results."
     )}
  end

  # ============================================================================
  # Optional Callbacks - Aggregates
  # ============================================================================

  @impl Ash.DataLayer
  @spec add_aggregate(t(), Ash.Query.Aggregate.t(), Ash.Resource.t()) ::
          {:ok, t()} | {:error, term()}
  def add_aggregate(data_layer_query, aggregate, _resource) do
    # Store aggregate info in the query struct for run_aggregate_query
    %Query{context: context} = data_layer_query
    aggregates = Map.get(context, :aggregates, [])
    {:ok, %{data_layer_query | context: Map.put(context, :aggregates, [aggregate | aggregates])}}
  end

  @impl Ash.DataLayer
  @spec add_aggregates(t(), [Ash.Query.Aggregate.t()], Ash.Resource.t()) ::
          {:ok, t()} | {:error, term()}
  def add_aggregates(data_layer_query, aggregates, _resource) do
    %Query{context: context} = data_layer_query
    existing = Map.get(context, :aggregates, [])
    {:ok, %{data_layer_query | context: Map.put(context, :aggregates, aggregates ++ existing)}}
  end

  @impl Ash.DataLayer
  @spec run_aggregate_query(t(), [Ash.Query.Aggregate.t()], Ash.Resource.t()) ::
          {:ok, map()} | {:error, term()}
  def run_aggregate_query(data_layer_query, aggregates, resource) do
    repo = repo(resource)
    opts = build_opts(resource)
    sanitized_table = qualified_table(resource)
    %Query{filters: filters} = data_layer_query

    where_result =
      case filters do
        nil ->
          {:ok, {"", []}}

        [] ->
          {:ok, {"", []}}

        _ ->
          uuid_fields = uuid_attribute_names(resource)
          cql_types = attr_cql_type_map(resource)
          QueryBuilder.build_where_clause(filters, uuid_fields, cql_types)
      end

    case where_result do
      {:error, {:unknown_filter, unknown}} ->
        raise AshScylla.Error,
          message:
            "AshScylla: Unable to translate filter expression to CQL: " <>
              "#{inspect(unknown)}. The query was not executed to avoid returning " <>
              "a broader result set than intended."

      {:ok, {where_clause, where_params}} ->
        # Build aggregate queries for each aggregate
        results =
          Enum.reduce_while(aggregates, %{}, fn aggregate, acc ->
            case build_aggregate_query(
                   aggregate,
                   sanitized_table,
                   where_clause,
                   resource,
                   filters
                 ) do
              {:error, reason} ->
                {:halt, {:error, reason}}

              {query, params} ->
                case repo.query(query, where_params ++ params, opts) do
                  {:ok, %Xandra.Page{content: [[value]]}} when not is_nil(value) ->
                    {:cont, Map.put(acc, aggregate.name, value)}

                  {:ok, %Xandra.Page{content: [[value]]}} when is_nil(value) ->
                    {:cont, Map.put(acc, aggregate.name, nil)}

                  {:ok, %Xandra.Page{content: []}} ->
                    {:cont, Map.put(acc, aggregate.name, Map.get(aggregate, :default_value))}

                  {:ok, %Xandra.Page{content: nil}} ->
                    {:cont, Map.put(acc, aggregate.name, Map.get(aggregate, :default_value))}

                  {:error, reason} ->
                    {:halt, {:error, reason}}
                end
            end
          end)

        case results do
          {:error, _reason} = error -> error
          map -> {:ok, map}
        end
    end
  end

  @impl Ash.DataLayer
  @spec calculate(t(), Ash.Query.Calculation.t(), Ash.Resource.t()) ::
          {:ok, t()} | {:error, term()}
  def calculate(data_layer_query, calculation, _resource) do
    # Expression calculations are done in Elixir post-processing
    %Query{context: context} = data_layer_query
    calculations = Map.get(context, :calculations, [])

    {:ok,
     %{data_layer_query | context: Map.put(context, :calculations, [calculation | calculations])}}
  end

  # ============================================================================
  # Private Helpers
  # ============================================================================

  @spec build_aggregate_query(Ash.Query.Aggregate.t(), String.t(), String.t(), module(), list()) ::
          {String.t(), list()} | {:error, term()}
  defp build_aggregate_query(
         %{kind: :count, field: nil},
         table,
         where_clause,
         _resource,
         _filters
       ) do
    query =
      IO.iodata_to_binary([
        "SELECT COUNT(*) FROM ",
        table,
        if(where_clause != "", do: [" WHERE ", where_clause], else: [])
      ])

    {query, []}
  end

  defp build_aggregate_query(%{kind: :count} = aggregate, table, where_clause, resource, _filters) do
    field = Map.get(aggregate, :field)
    cql_field = resolve_aggregate_field(field, resource)

    query =
      IO.iodata_to_binary([
        "SELECT COUNT(",
        cql_field,
        ") FROM ",
        table,
        if(where_clause != "", do: [" WHERE ", where_clause], else: [])
      ])

    {query, []}
  end

  defp build_aggregate_query(%{kind: :sum, field: field}, table, where_clause, resource, _filters) do
    cql_field = resolve_aggregate_field(field, resource)

    query =
      IO.iodata_to_binary([
        "SELECT SUM(",
        cql_field,
        ") FROM ",
        table,
        if(where_clause != "", do: [" WHERE ", where_clause], else: [])
      ])

    {query, []}
  end

  defp build_aggregate_query(%{kind: :avg, field: field}, table, where_clause, resource, _filters) do
    cql_field = resolve_aggregate_field(field, resource)

    query =
      IO.iodata_to_binary([
        "SELECT AVG(",
        cql_field,
        ") FROM ",
        table,
        if(where_clause != "", do: [" WHERE ", where_clause], else: [])
      ])

    {query, []}
  end

  defp build_aggregate_query(%{kind: :min, field: field}, table, where_clause, resource, _filters) do
    cql_field = resolve_aggregate_field(field, resource)

    query =
      IO.iodata_to_binary([
        "SELECT MIN(",
        cql_field,
        ") FROM ",
        table,
        if(where_clause != "", do: [" WHERE ", where_clause], else: [])
      ])

    {query, []}
  end

  defp build_aggregate_query(%{kind: :max, field: field}, table, where_clause, resource, _filters) do
    cql_field = resolve_aggregate_field(field, resource)

    query =
      IO.iodata_to_binary([
        "SELECT MAX(",
        cql_field,
        ") FROM ",
        table,
        if(where_clause != "", do: [" WHERE ", where_clause], else: [])
      ])

    {query, []}
  end

  defp build_aggregate_query(%{kind: kind}, _table, _where_clause, _resource, _filters) do
    {:error,
     AshScylla.Error.ScyllaError.from_error(
       "Aggregate kind #{kind} is not supported in ScyllaDB/Cassandra. Supported kinds: :count, :sum, :avg, :min, :max"
     )}
  end

  defp resolve_aggregate_field(nil, _resource), do: "*"

  defp resolve_aggregate_field(field, resource) when is_atom(field) do
    case Ash.Resource.Info.field(resource, field) do
      %{name: name} -> QueryBuilder.cql_identifier(name)
      nil -> QueryBuilder.cql_identifier(field)
    end
  end

  defp resolve_aggregate_field(%{name: name}, _resource) do
    QueryBuilder.cql_identifier(name)
  end

  defp resolve_aggregate_field(field, _resource) do
    QueryBuilder.cql_identifier(field)
  end

  # ============================================================================
  # Relationship Aggregate Support (aggregates do ... end)
  # ============================================================================

  @doc false
  def attach_aggregates(records, [], _resource, _repo, _opts), do: records

  def attach_aggregates(records, _aggregates, _resource, repo, _opts) when is_nil(repo),
    do: records

  def attach_aggregates(records, aggregates, resource, repo, opts) do
    pkey = Ash.Resource.Info.primary_key(resource)

    # Compute each record's aggregates concurrently. Relationship aggregates
    # issue one synchronous ScyllaDB query per record, so a page of N records
    # would otherwise be N sequential round trips. We parallelize across records
    # with Task.async_stream (bounded concurrency) to avoid the N+1 latency.
    max_concurrency = System.schedulers_online()

    {records, _errors} =
      records
      |> Task.async_stream(
        fn record ->
          pk_values = Map.take(record, pkey)

          agg_values =
            Enum.reduce(aggregates, %{}, fn aggregate, acc ->
              case compute_record_aggregate(aggregate, pk_values, resource, repo, opts) do
                {:ok, value} ->
                  Map.put(acc, aggregate.name, value)

                :error ->
                  Map.put(acc, aggregate.name, aggregate.default_value)
              end
            end)

          {record, agg_values}
        end,
        max_concurrency: max_concurrency,
        ordered: true,
        on_timeout: :kill_task
      )
      |> Enum.reduce({[], []}, fn
        {:ok, {record, agg_values}}, {acc_records, acc_errors} ->
          updated = Map.update!(record, :aggregates, &Map.merge(&1, agg_values))
          {[updated | acc_records], acc_errors}

        {:exit, reason}, {acc_records, acc_errors} ->
          # A timed-out/aborted task (on_timeout: :kill_task) surfaces as {:exit, reason}.
          # Fall back to default aggregate values for the affected record rather than
          # failing the entire read.
          {acc_records, [reason | acc_errors]}

        {:error, reason}, {acc_records, acc_errors} ->
          {acc_records, [reason | acc_errors]}
      end)

    Enum.reverse(records)
  end

  defp compute_record_aggregate(aggregate, pk_values, resource, repo, opts) do
    %{kind: kind, field: field, relationship_path: path, query: agg_query} = aggregate

    if path == [] do
      # Same-table aggregate: SELECT COUNT(*) FROM table WHERE pk = ?
      compute_same_table_aggregate(kind, field, resource, repo, opts, pk_values)
    else
      # Relationship aggregate: traverse to related table
      compute_related_table_aggregate(
        kind,
        field,
        path,
        resource,
        repo,
        opts,
        pk_values,
        agg_query
      )
    end
  end

  defp compute_same_table_aggregate(kind, field, resource, repo, opts, pk_values) do
    table = qualified_table(resource)
    {pk_where, pk_params} = build_pk_where_clause_from_map(pk_values, resource)
    cql_field = aggregate_field_to_cql(kind, field, resource)

    query =
      IO.iodata_to_binary([
        "SELECT ",
        cql_field,
        " FROM ",
        table,
        " WHERE ",
        pk_where
      ])

    case repo.query(query, pk_params, opts) do
      {:ok, %Xandra.Page{content: [[value]]}} when not is_nil(value) ->
        {:ok, value}

      _ ->
        :error
    end
  end

  defp compute_related_table_aggregate(
         kind,
         field,
         path,
         resource,
         repo,
         opts,
         pk_values,
         _agg_query
       ) do
    # Resolve the relationship chain to find the destination resource
    related = Ash.Resource.Info.related(resource, path)
    relationship = Ash.Resource.Info.relationship(resource, List.first(path))

    related_table = qualified_table(related)

    # Build the WHERE clause for the relationship link
    # This connects the source record's PK to the related table
    case relationship.type do
      :belongs_to ->
        # Source has the foreign key that references the destination
        fk_value = Map.get(pk_values, relationship.source_attribute)
        dest_pkey = Ash.Resource.Info.primary_key(related)

        if length(dest_pkey) == 1 do
          [pk_col] = dest_pkey
          cql_field = aggregate_field_to_cql(kind, field, related)

          query =
            IO.iodata_to_binary([
              "SELECT ",
              cql_field,
              " FROM ",
              related_table,
              " WHERE ",
              QueryBuilder.cql_identifier(pk_col),
              " = ?"
            ])

          case repo.query(query, [fk_value], opts) do
            {:ok, %Xandra.Page{content: [[value]]}} when not is_nil(value) ->
              {:ok, value}

            {:ok, %Xandra.Page{content: [[_]]}} ->
              :error

            _ ->
              :error
          end
        else
          :error
        end

      _ ->
        # Other relationship types (has_many, many_to_many, etc.)
        # Not yet implemented for per-record aggregation in ScyllaDB
        :error
    end
  end

  defp aggregate_field_to_cql(:count, nil, _resource), do: "COUNT(*)"

  defp aggregate_field_to_cql(kind, field, resource) do
    cql_field = resolve_aggregate_field(field, resource)
    kind_str = String.upcase(to_string(kind))
    "#{kind_str}(#{cql_field})"
  end

  defp build_pk_where_clause_from_map(pk_values, resource) do
    pkey = Ash.Resource.Info.primary_key(resource)
    attrs = Ash.Resource.Info.attributes(resource)
    uuid_fields = uuid_attribute_names(resource)
    atom_fields = atom_attribute_names(resource)

    clauses =
      Enum.map(pkey, fn field_name ->
        value = Map.get(pk_values, field_name)
        attr = Enum.find(attrs, &(&1.name == field_name))
        cql_type = attr && resolve_attr_cql_type(attr)

        typed_value =
          cond do
            field_name in uuid_fields and is_binary(value) ->
              # UUID PK: convert the string to its 16-byte binary and tag it as
              # {"uuid", bin} so Xandra marshals it as a uuid-typed parameter.
              # A bare binary would otherwise be inferred as text/blob and
              # rejected by ScyllaDB with "Validation failed for uuid".
              case Types.uuid_string_to_binary(value) do
                {:ok, bin} -> {"uuid", bin}
                _ -> {"uuid", value}
              end

            field_name in atom_fields and is_atom(value) ->
              Atom.to_string(value)

            cql_type && cql_type != "text" && is_binary(value) ->
              value

            true ->
              wrap_typed(value, field_name, %{field_name => cql_type})
          end

        {QueryBuilder.cql_identifier(field_name), typed_value}
      end)

    where =
      clauses
      |> Enum.map(fn {col, _} -> "#{col} = ?" end)
      |> Enum.join(" AND ")

    params =
      clauses
      |> Enum.map(fn {_, val} -> val end)

    {where, params}
  end

  @spec build_insert_statement(String.t(), map(), pos_integer() | nil, module()) ::
          {String.t(), list()}
  defp build_insert_statement(table, attrs, ttl, resource) do
    {sanitized_fields, values} = build_field_value_pairs(attrs, resource)

    query =
      IO.iodata_to_binary([
        "INSERT INTO ",
        table,
        " (",
        Enum.join(sanitized_fields, ", "),
        ") VALUES (",
        Enum.map_join(1..length(sanitized_fields), ", ", fn _ -> "?" end),
        ")",
        if(ttl, do: [" USING TTL ", to_string(ttl)], else: [])
      ])

    {query, values}
  end

  @spec normalize_bulk_options(keyword() | map()) :: keyword()
  defp normalize_bulk_options(opts) when is_map(opts) do
    Map.to_list(opts)
  end

  defp normalize_bulk_options(opts) when is_list(opts), do: opts

  @spec chunk_statements([{String.t(), list()}], pos_integer() | :infinity) :: [
          [{String.t(), list()}]
        ]
  defp chunk_statements(statements, :infinity), do: [statements]
  defp chunk_statements(statements, batch_size), do: Enum.chunk_every(statements, batch_size)

  @spec stream_bulk_records(Enumerable.t(Ash.Changeset.t()), module()) ::
          Enumerable.t(Ash.Resource.t())
  defp stream_bulk_records(changesets, resource) do
    Stream.map(changesets, fn changeset ->
      changeset
      |> changeset_to_insert_attrs(resource)
      |> to_ash_record(resource)
    end)
  end

  @spec do_upsert(map(), Ash.Changeset.t(), Ash.Resource.t(), module(), keyword()) ::
          {:ok, Ash.Resource.t()} | {:error, term()}
  defp do_upsert(attrs, changeset, resource, repo, _opts) do
    opts = build_opts(resource)
    ttl = Dsl.ttl(resource)
    lwt? = Dsl.lwt(resource)

    sanitized_table = qualified_table(resource)

    {sanitized_fields, values} = build_field_value_pairs(attrs, resource)
    field_count = length(sanitized_fields)

    # Use INSERT ... IF NOT EXISTS for LWT upsert semantics
    lwt_suffix = if lwt?, do: " IF NOT EXISTS", else: ""

    query =
      IO.iodata_to_binary([
        "INSERT INTO ",
        sanitized_table,
        " (",
        Enum.join(sanitized_fields, ", "),
        ") VALUES (",
        Enum.map_join(1..field_count, ", ", fn _ -> "?" end),
        ")",
        lwt_suffix,
        if(ttl, do: [" USING TTL ", to_string(ttl)], else: [])
      ])

    Logger.debug("Executing UPSERT: #{query} with params #{inspect(values)}")

    case repo.query(query, values, opts) do
      {:ok, %Xandra.Page{content: [[true]]}} ->
        {:ok, to_ash_record(attrs, resource)}

      {:ok, %Xandra.Page{content: [[false]]}} ->
        # LWT conflict — record already exists, do an update instead.
        pk_names =
          resource
          |> Info.attributes()
          |> Enum.filter(& &1.primary_key?)
          |> Enum.map(& &1.name)
          |> MapSet.new()

        update_attrs = Map.reject(attrs, fn {k, _} -> MapSet.member?(pk_names, k) end)
        do_update(update_attrs, changeset, resource, repo)

      {:ok, _} ->
        {:ok, to_ash_record(attrs, resource)}

      {:error, error} ->
        handle_result({:error, error})
    end
  end

  @spec apply_calculations([Ash.Resource.t()], map()) :: [Ash.Resource.t()]
  defp apply_calculations(records, %{calculations: calculations}) when is_list(calculations) do
    Enum.map(records, fn record ->
      Enum.reduce(calculations, record, fn calculation, acc ->
        case calculate_in_memory(calculation, acc) do
          {:ok, value} -> Map.put(acc, calculation.name, value)
          _ -> acc
        end
      end)
    end)
  end

  defp apply_calculations(records, _), do: records

  @spec calculate_in_memory(Ash.Query.Calculation.t(), Ash.Resource.t()) ::
          {:ok, term()} | {:error, term()}
  defp calculate_in_memory(%{module: module, opts: opts}, record) when is_atom(module) do
    if function_exported?(module, :calculate, 2) do
      result = module.calculate([record], opts)
      {:ok, result}
    else
      {:error, :no_calculate_function}
    end
  end

  defp calculate_in_memory(%{expr: expr}, record) when is_function(expr) do
    result = expr.(record)
    {:ok, result}
  end

  defp calculate_in_memory(_, _), do: {:error, :unsupported_calculation}

  # ============================================================================
  # Helper Functions
  # ============================================================================

  @doc false
  @spec sanitize_identifier(String.t()) :: String.t() | no_return()
  defp sanitize_identifier(name) when is_binary(name) do
    Identifier.sanitize!(name)
  end

  @spec repo(module()) :: module()
  defp repo(resource) do
    # The repo for a resource is fixed for the lifetime of the process (it is
    # derived from static DSL config / a module attribute), so this ETS cache is
    # intentionally permanent — there is no invalidation path by design. An
    # unexplained persistent ETS table here is expected, not a leak.
    case :ets.lookup(:ash_scylla_repo_cache, resource) do
      [{^resource, repo}] ->
        repo

      [] ->
        repo =
          try do
            Module.get_attribute(resource, :repo)
          rescue
            ArgumentError -> nil
          end

        # Fall back to DSL-configured repo if @repo attribute is not set
        repo =
          case repo do
            nil -> Dsl.repo(resource)
            _ -> repo
          end

        case repo do
          nil ->
            raise """
            No repo configured for #{inspect(resource)}.

            To fix this, add a repo to your resource's scylla DSL block:

                import AshScylla.DataLayer.Dsl

                scylla do
                  repo MyApp.Repo
                  table "my_table"
                end

            Or set it as a module attribute:

                @repo MyApp.Repo

            The repo must use AshScylla.Repo.
            """

          repo ->
            :ets.insert(:ash_scylla_repo_cache, {resource, repo})
            repo
        end
    end
  end

  @spec changeset_to_insert_attrs(term(), module()) :: map()
  defp changeset_to_insert_attrs(changeset, resource) do
    attrs = changeset.attributes

    # Add primary key if not present and autogenerate is configured
    attrs =
      Enum.reduce(Info.attributes(resource), attrs, fn attr, acc ->
        if attr.primary_key? && !Map.has_key?(acc, attr.name) && autogenerate_attribute?(attr) do
          Map.put(acc, attr.name, autogenerate_value(attr))
        else
          acc
        end
      end)

    attrs
  end

  @spec changeset_to_update_attrs(term(), module()) :: map()
  defp changeset_to_update_attrs(changeset, _resource) do
    changeset.attributes
  end

  @spec autogenerate_value(map()) :: term()
  defp autogenerate_value(attr) do
    cond do
      attr.type && function_exported?(attr.type, :generator, 1) ->
        constraints = Map.get(attr, :constraints, [])
        attr.type.generator(constraints) |> Enum.at(0)

      attr.type in [UUID, :uuid, Ash.Type.UUID, :uuid_v7] ->
        generate_uuid()

      true ->
        nil
    end
  end

  @spec generate_uuid() :: String.t()
  defp generate_uuid do
    <<a::32, b::16, c::16, d::16, e::48>> = :crypto.strong_rand_bytes(16)

    "#{format_hex(a, 8)}-#{format_hex(b, 4)}-#{format_hex(c, 4)}-#{format_hex(d, 4)}-#{format_hex(e, 12)}"
  end

  defp format_hex(value, len) do
    value |> Integer.to_string(16) |> String.pad_leading(len, "0")
  end

  @spec autogenerate_attribute?(map()) :: boolean()
  defp autogenerate_attribute?(attr) do
    cond do
      Map.get(attr, :autogenerate?) == true ->
        true

      attr.type && function_exported?(attr.type, :autogenerate_enabled?, 0) &&
          attr.type.autogenerate_enabled?() ->
        true

      true ->
        is_function(Map.get(attr, :default))
    end
  end

  @spec do_insert(map(), module(), module()) :: {:ok, term()} | {:error, term()}
  defp do_insert(attrs, resource, repo) do
    opts = build_opts(resource)
    ttl = Dsl.ttl(resource)

    sanitized_table = qualified_table(resource)
    {sanitized_fields, values} = build_field_value_pairs(attrs, resource)

    query =
      IO.iodata_to_binary([
        "INSERT INTO ",
        sanitized_table,
        " (",
        Enum.join(sanitized_fields, ", "),
        ") VALUES (",
        Enum.map_join(1..length(sanitized_fields), ", ", fn _ -> "?" end),
        ")",
        if(ttl, do: [" USING TTL ", to_string(ttl)], else: [])
      ])

    Logger.debug("Executing INSERT on #{sanitized_table}")

    with {:ok, _} <- repo.query(query, values, opts),
         pk <- get_primary_key(%{attributes: attrs}, resource),
         {:ok, record} <- fetch_by_primary_key(pk, resource, repo) do
      {:ok, to_ash_record(record, resource)}
    end
    |> handle_result()
  end

  @spec do_update(map(), term(), module(), module()) :: {:ok, term()} | {:error, term()}
  defp do_update(attrs, changeset, resource, repo) do
    # If there are no changed attributes (e.g. only relationships touched),
    # skip the UPDATE entirely — generating UPDATE table SET WHERE ... is invalid CQL.
    if map_size(attrs) == 0 do
      Logger.debug(
        "do_update: no changed attributes, skipping UPDATE and fetching existing record"
      )

      pk = get_primary_key(changeset, resource)

      case fetch_by_primary_key(pk, resource, repo) do
        {:ok, record} -> {:ok, to_ash_record(record, resource)}
        {:error, _} = error -> handle_result(error)
      end
    else
      do_update_non_empty(attrs, changeset, resource, repo)
    end
  end

  defp do_update_non_empty(attrs, changeset, resource, repo) do
    opts = build_opts(resource)
    sanitized_table = qualified_table(resource)

    {set_clauses, values} = build_set_clauses(attrs, resource)

    {pk_where, pk_values} = build_pk_where_clause(changeset, resource)

    # Use LWT IF EXISTS for conditional update when LWT is enabled
    lwt? = Dsl.lwt(resource)
    lwt_suffix = if lwt?, do: " IF EXISTS", else: ""

    query =
      IO.iodata_to_binary([
        "UPDATE ",
        sanitized_table,
        " SET ",
        Enum.join(set_clauses, ", "),
        " WHERE ",
        pk_where,
        lwt_suffix
      ])

    Logger.debug("Executing UPDATE on #{sanitized_table}")

    case repo.query(query, values ++ pk_values, opts) do
      {:ok, %Xandra.Page{content: [[false]]}} ->
        # LWT: record didn't exist (stale record)
        {:error,
         Ash.Error.Changes.StaleRecord.exception(
           resource: resource,
           filter: changeset.filter
         )}

      {:ok, _} ->
        case fetch_by_pk(changeset, resource, repo) do
          {:ok, record} -> {:ok, to_ash_record(record, resource)}
          {:error, _} = error -> handle_result(error)
        end

      {:error, error} ->
        handle_result({:error, error})
    end
  end

  @spec do_delete(term(), module(), module()) :: :ok | {:error, term()}
  defp do_delete(changeset, resource, repo) do
    opts = build_opts(resource)
    sanitized_table = qualified_table(resource)

    {pk_where, pk_values} = build_pk_where_clause(changeset, resource)

    # Check if this is a secondary index scan (for bulk delete by filter)
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

    filters = changeset.filter || []
    filter_columns = QueryBuilder.get_filter_columns(filters)

    needs_allow_filtering =
      filter_columns != [] and
        Enum.any?(filter_columns, fn col -> MapSet.member?(secondary_indexed_columns, col) end) and
        Enum.all?(filter_columns, fn col ->
          MapSet.member?(pk_columns, col) or MapSet.member?(secondary_indexed_columns, col)
        end)

    query =
      IO.iodata_to_binary([
        "DELETE FROM ",
        sanitized_table,
        " WHERE ",
        pk_where,
        if(needs_allow_filtering, do: " ALLOW FILTERING", else: "")
      ])

    Logger.debug("Executing DELETE on #{sanitized_table}")

    # Use LWT IF EXISTS for conditional delete when LWT is enabled
    lwt? = Dsl.lwt(resource)
    query = if lwt?, do: query <> " IF EXISTS", else: query

    case repo.query(query, pk_values, opts) do
      {:ok, %Xandra.Page{content: [[true]]}} ->
        # LWT: record existed and was deleted
        :ok

      {:ok, %Xandra.Page{content: [[false]]}} ->
        # LWT: record didn't exist (stale record)
        {:error,
         Ash.Error.Changes.StaleRecord.exception(
           resource: resource,
           filter: changeset.filter
         )}

      {:ok, _} ->
        :ok

      {:error, error} ->
        handle_result({:error, error})
    end
  end

  @spec fetch_by_primary_key(map(), module(), module()) :: {:ok, term()} | {:error, term()}
  defp fetch_by_primary_key(pk, resource, repo) do
    sanitized_table = qualified_table(resource)
    {pk_where, pk_values} = build_where_from_map(pk, resource)

    query =
      IO.iodata_to_binary([
        "SELECT * FROM ",
        sanitized_table,
        " WHERE ",
        pk_where,
        " LIMIT 1"
      ])

    Logger.debug("Executing SELECT: #{query} with params #{inspect(pk_values)}")

    case repo.query(query, pk_values) do
      {:ok, %Xandra.Page{content: [row | _], columns: columns}} when columns != nil ->
        {:ok, {row, columns}}

      {:ok, %Xandra.Page{content: [row | _]}} ->
        {:ok, row}

      {:ok, %Xandra.Page{content: []}} ->
        not_found_error(sanitized_table, pk)

      {:ok, %Xandra.Page{content: nil}} ->
        not_found_error(sanitized_table, pk)

      # Handle plain maps (used by FakeRepo in tests)
      {:ok, %{content: [row | _], columns: columns}} when columns != nil ->
        {:ok, {row, columns}}

      {:ok, %{content: [row | _]}} ->
        {:ok, row}

      {:ok, %{content: []}} ->
        not_found_error(sanitized_table, pk)

      {:ok, %{content: nil}} ->
        not_found_error(sanitized_table, pk)

      {:error, error} ->
        handle_result({:error, error})
    end
  end

  defp not_found_error(table, pk) do
    {:error,
     AshScylla.Error.ScyllaError.from_error(
       "Record not found in table #{table} with primary key #{inspect(pk)}"
     )}
  end

  defp fetch_by_pk(changeset, resource, repo) do
    pk = get_primary_key(changeset, resource)
    fetch_by_primary_key(pk, resource, repo)
  end

  @spec get_primary_key(term(), module()) :: map()
  defp get_primary_key(changeset, resource) do
    Enum.reduce(Info.attributes(resource), %{}, fn attr, acc ->
      if attr.primary_key? do
        Map.put(acc, attr.name, Map.get(changeset.attributes, attr.name))
      else
        acc
      end
    end)
  end

  @spec get_primary_key_from_changeset(term(), module()) :: map()
  defp get_primary_key_from_changeset(changeset, resource) do
    pk_from_attrs = get_primary_key(changeset, resource)

    pk_from_data =
      case Map.get(changeset, :data) do
        data when is_map(data) ->
          data_attributes = Map.get(data, :attributes, %{})

          pk_from_struct =
            Enum.reduce(Info.attributes(resource), %{}, fn attr, acc ->
              if attr.primary_key? do
                case Map.get(data, attr.name) do
                  nil -> acc
                  val -> Map.put(acc, attr.name, val)
                end
              else
                acc
              end
            end)

          if map_size(data_attributes) > 0 and map_size(pk_from_struct) == 0 do
            Enum.reduce(Info.attributes(resource), %{}, fn attr, acc ->
              if attr.primary_key? do
                case Map.get(data_attributes, attr.name) do
                  nil -> acc
                  val -> Map.put(acc, attr.name, val)
                end
              else
                acc
              end
            end)
          else
            pk_from_struct
          end

        _ ->
          %{}
      end

    # Merge: prefer non-nil attributes, fall back to data values
    pk_from_attrs_non_nil = Map.reject(pk_from_attrs, fn {_k, v} -> is_nil(v) end)
    Map.merge(pk_from_data, pk_from_attrs_non_nil)
  end

  @spec to_ash_record(term(), module(), list() | nil) :: struct()
  defp to_ash_record(record, resource, columns \\ nil)

  defp to_ash_record({row, columns}, resource, _) do
    to_ash_record(row, resource, columns)
  end

  defp to_ash_record(record, resource, columns) when is_list(record) and is_list(columns) do
    # Convert positional list from Xandra to a map using column metadata names.
    # Xandra columns can be 4-tuples: {keyspace, table, column_name, type}
    # or 3-tuples: {keyspace, table, column_name} (some Xandra versions)
    # or plain strings (some test fakes).
    record_map =
      record
      |> Enum.zip(columns)
      |> Enum.reduce(%{}, fn {value, col}, acc ->
        col_name =
          case col do
            {_, _, name, _} when is_binary(name) -> name
            {_, _, name} when is_binary(name) -> name
            name when is_binary(name) -> name
          end

        Map.put(acc, col_name, value)
      end)

    to_ash_record(record_map, resource)
  end

  defp to_ash_record(record, resource, _columns) when is_list(record) do
    # Fallback: use attribute order (may not match column order from Scylla)
    attr_names = resource |> Info.attributes() |> Enum.map(& &1.name)

    record_map =
      record
      |> Enum.zip(attr_names)
      |> Enum.reduce(%{}, fn {value, key}, acc -> Map.put(acc, key, value) end)

    to_ash_record(record_map, resource)
  end

  defp to_ash_record(record, resource, _columns) when is_tuple(record) do
    record |> Tuple.to_list() |> to_ash_record(resource)
  end

  defp to_ash_record(record, resource, _columns) when is_map(record) do
    uuid_fields = uuid_attribute_names(resource)
    atom_fields = atom_attribute_names(resource)

    attrs =
      resource
      |> Info.attributes()
      |> Enum.reduce(%{}, fn attr, acc ->
        value =
          case Map.fetch(record, attr.name) do
            {:ok, v} -> v
            :error -> Map.get(record, to_string(attr.name))
          end

        decoded_value =
          cond do
            attr.name in uuid_fields and is_binary(value) and byte_size(value) == 16 ->
              case Types.uuid_binary_to_string(value) do
                {:ok, str} -> str
                _ -> value
              end

            attr.name in atom_fields and is_binary(value) ->
              String.to_atom(value)

            true ->
              value
          end

        Map.put(acc, attr.name, decoded_value)
      end)

    struct(resource, attrs)
  end

  # Public test helper that exercises the private `to_ash_record/3` map branch.
  @doc false
  def to_ash_record_public(record, resource), do: to_ash_record(record, resource, nil)

  # Public test helper that exercises the in-memory sort fallback.
  @doc false
  def maybe_apply_in_memory_sort_public(records, sorts, dropped?) do
    maybe_apply_in_memory_sort(records, sorts, dropped?)
  end

  # Build repo query options from resource configuration (consistency only).
  # Keyspace is handled at connection level; TTL is inline in CQL.
  @spec build_opts(module()) :: keyword()
  defp build_opts(resource) do
    keyspace = Dsl.keyspace(resource)

    []
    |> maybe_put(:consistency, Dsl.consistency(resource))
    |> maybe_put(:keyspace, sanitize_keyspace(keyspace))
    |> maybe_put(:timeout, @default_query_timeout)
  end

  # Build query options for read operations (consistency only).
  # Keyspace is handled at connection level.
  @spec build_query_opts(module(), String.t() | nil) :: keyword()
  defp build_query_opts(resource, _tenant) do
    keyspace = Dsl.keyspace(resource)

    []
    |> maybe_put(:consistency, Dsl.consistency(resource))
    |> maybe_put(:keyspace, sanitize_keyspace(keyspace))
    |> maybe_put(:timeout, @default_query_timeout)
  end

  @spec sanitize_keyspace(String.t() | nil) :: String.t() | nil
  defp sanitize_keyspace(nil), do: nil
  defp sanitize_keyspace(keyspace), do: sanitize_identifier(keyspace)

  @doc """
  Returns the qualified table name (with keyspace prefix if configured).

  ## Examples

      iex> AshScylla.DataLayer.qualified_table(MyResource)
      "test_ks.my_table"

  """
  @spec qualified_table(module()) :: String.t()
  def qualified_table(resource) do
    # Use the same quoting rule as `source/1` (QueryBuilder.cql_identifier/1):
    # quote only CQL reserved words, leaving ordinary identifiers bare. This
    # keeps `qualified_table/1` consistent with the table name used in reads
    # while still producing valid CQL for reserved-word table names such as
    # "order".
    table = QueryBuilder.cql_identifier(raw_table_name(resource))

    case Dsl.keyspace(resource) do
      nil -> table
      ks -> "#{sanitize_keyspace(ks)}.#{table}"
    end
  end

  # Returns the unquoted, validated table name for a resource. Unlike `source/1`,
  # this does NOT run the name through `QueryBuilder.cql_identifier/1`, so it
  # never returns a double-quoted CQL display form. This is what `qualified_table/1`
  # needs so that reserved-word table names (e.g. "order") are sanitized correctly
  # rather than being re-validated against an already-quoted string.
  @doc false
  @spec raw_table_name(module()) :: String.t()
  defp raw_table_name(resource) do
    case Dsl.table(resource) do
      nil ->
        segments = Module.split(resource)

        name =
          if Ash.Resource.Info.domain(resource) do
            segments
            |> Enum.take(-2)
            |> Enum.map_join("_", &Macro.underscore/1)
          else
            segments
            |> List.last()
            |> Macro.underscore()
          end

        # Fall back to a direct @table module attribute (used by some resources
        # that set the table without the `scylla` DSL block).
        table_attr =
          try do
            Module.get_attribute(resource, :table)
          rescue
            ArgumentError -> nil
          end

        case table_attr do
          nil -> name
          "" -> name
          table -> to_string(table)
        end
        |> Identifier.sanitize!()

      dsl_table ->
        dsl_table |> to_string() |> Identifier.sanitize!()
    end
  end

  @spec maybe_put(keyword(), atom(), term()) :: keyword()
  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  # Normalize ScyllaDB/Xandra errors into AshScylla errors.
  @spec handle_result({:ok, term()} | :ok | {:error, term()}) ::
          {:ok, term()} | :ok | {:error, term()}
  defp handle_result({:ok, _} = ok), do: ok
  defp handle_result(:ok), do: :ok

  defp handle_result({:error, %Xandra.Error{} = error}) do
    Logger.warning("Xandra error: #{Exception.message(error)}")
    {:error, AshScylla.Error.wrap_xandra_error(error)}
  end

  defp handle_result({:error, %Xandra.ConnectionError{} = error}) do
    Logger.warning("Xandra connection error: #{Exception.message(error)}")
    {:error, AshScylla.Error.wrap_xandra_error(error)}
  end

  defp handle_result({:error, %AshScylla.Error.ScyllaError{}} = error), do: error

  defp handle_result({:error, error}) do
    Logger.error("Unexpected error: #{inspect(error)}")
    {:error, AshScylla.Error.wrap_xandra_error(error)}
  end

  # ---------------------------------------------------------------------------
  # SQL Construction Helpers
  # ---------------------------------------------------------------------------

  @spec build_field_value_pairs(map(), module()) :: {[String.t()], [term()]}
  defp build_field_value_pairs(attrs, resource) do
    uuid_fields = uuid_attribute_names(resource)
    cql_types = attr_cql_type_map(resource)

    {fields, values} =
      Enum.reduce(attrs, {[], []}, fn {k, v}, {fs, vs} ->
        value =
          if uuid_field?(k, v, uuid_fields, resource) do
            case Types.uuid_string_to_binary(v) do
              {:ok, bin} -> bin
              _ -> v
            end
          else
            v
          end

        wrapped = wrap_typed(value, k, cql_types)
        {[QueryBuilder.cql_identifier(to_string(k)) | fs], [wrapped | vs]}
      end)

    {Enum.reverse(fields), :lists.reverse(values)}
  end

  @spec build_set_clauses(map(), module()) :: {[String.t()], [term()]}
  defp build_set_clauses(attrs, resource) do
    uuid_fields = uuid_attribute_names(resource)
    cql_types = attr_cql_type_map(resource)

    {clauses, values} =
      Enum.reduce(attrs, {[], []}, fn {k, v}, {cs, vs} ->
        sanitized = QueryBuilder.cql_identifier(to_string(k))

        value =
          if uuid_field?(k, v, uuid_fields, resource) do
            case Types.uuid_string_to_binary(v) do
              {:ok, bin} -> bin
              _ -> v
            end
          else
            v
          end

        wrapped = wrap_typed(value, k, cql_types)
        {["#{sanitized} = ?" | cs], [wrapped | vs]}
      end)

    {Enum.reverse(clauses), :lists.reverse(values)}
  end

  @spec build_pk_where_clause(term(), module()) :: {String.t(), [term()]}
  defp build_pk_where_clause(changeset, resource) do
    pk = get_primary_key_from_changeset(changeset, resource)
    build_where_from_map(pk, resource)
  end

  @spec build_where_from_map(map(), module()) :: {String.t(), [term()]}
  defp build_where_from_map(pk_map, resource) do
    uuid_fields = uuid_attribute_names(resource)
    cql_types = attr_cql_type_map(resource)

    {clauses, values} =
      Enum.reduce(pk_map, {[], []}, fn {k, v}, {cs, vs} ->
        sanitized = QueryBuilder.cql_identifier(to_string(k))

        value =
          if uuid_field?(k, v, uuid_fields, resource) do
            case Types.uuid_string_to_binary(v) do
              {:ok, bin} -> bin
              _ -> v
            end
          else
            v
          end

        wrapped = wrap_typed(value, k, cql_types)
        {["#{sanitized} = ?" | cs], [wrapped | vs]}
      end)

    {Enum.reverse(clauses) |> Enum.join(" AND "), :lists.reverse(values)}
  end

  # Returns a MapSet of attribute names (atoms and strings) declared as UUID.
  # Used by the read path to decide which filter string values should be
  # encoded as 16-byte UUID binaries.
  @spec uuid_attribute_names(module()) :: MapSet.t(atom() | String.t())
  def uuid_attribute_names(resource) do
    if Ash.Resource.Info.resource?(resource) do
      resource
      |> Info.attributes()
      |> Enum.filter(fn attr ->
        # Detect any UUID-family attribute. We resolve the attribute's declared
        # type to its short name and check whether it contains "uuid". This
        # catches :uuid, :uuid_v7 (used by uuid_v7_primary_key), Ash.Type.UUID,
        # and any custom UUID type module (e.g. MyApp.UUIDv7, whose module name
        # or storage_type resolves to a uuid-like name). Previously only
        # Ash.Type.UUID and :uuid were recognized, so attributes declared as
        # :uuid_v7 were missed and their 36-char string values were bound as
        # text, causing "Validation failed for uuid - got 36 bytes".
        #
        # NOTE: we intentionally do NOT use resolve_attr_cql_type/1 here, because
        # that maps unknown UUID variants (e.g. :uuid_v7) to "text", which would
        # defeat detection.
        type = attr.type
        short = resolve_type_name(type)
        # Check both the resolved short name and the raw type's string form so
        # custom UUID modules (e.g. MyApp.UUIDv7) are also detected. Tuple types
        # (e.g. {:array, :string}) can't be stringified directly, so guard the
        # conversion.
        type_str = if is_atom(short), do: Atom.to_string(short), else: inspect(short)
        raw_str = if is_atom(type), do: Atom.to_string(type), else: inspect(type)

        (is_atom(short) and (type_str =~ "uuid" or raw_str =~ "uuid")) or
          (is_binary(short) and short =~ "uuid")
      end)
      |> Enum.flat_map(fn attr -> [attr.name, to_string(attr.name)] end)
      |> MapSet.new()
    else
      %MapSet{}
    end
  end

  # Resolves an Ash attribute type to its short name atom (e.g. :uuid_v7,
  # :uuid, :string). Module types are resolved via storage_type/1 or the Ash
  # type registry; plain atoms pass through.
  @doc false
  @spec resolve_type_name(atom() | tuple()) :: atom() | tuple()
  defp resolve_type_name(type) when is_atom(type) do
    cond do
      # Already a plain atom (e.g. :uuid, :uuid_v7, :string) — pass through
      not match?("Elixir." <> _, Atom.to_string(type)) ->
        type

      # Ash type module with storage_type/1 (e.g. Ash.Type.UUID -> :uuid)
      function_exported?(type, :storage_type, 1) ->
        case type.storage_type([]) do
          storage_type when is_atom(storage_type) -> storage_type
          _ -> type
        end

      # Fallback: try to find in Ash.Type.Registry by module
      true ->
        case Ash.Type.Registry.short_names() |> List.keyfind(type, 1) do
          {short_name, _module} -> short_name
          nil -> type
        end
    end
  end

  # Collection types arrive as {:array, inner_type}; resolve the inner type.
  defp resolve_type_name({:array, inner_type}) when is_atom(inner_type) do
    {:array, resolve_type_name(inner_type)}
  end

  defp resolve_type_name(other), do: other

  # Returns a MapSet of attribute names (atoms) that are typed as Atom.
  # These attributes need string-to-atom conversion when read from ScyllaDB.
  @spec atom_attribute_names(module()) :: MapSet.t(atom())
  defp atom_attribute_names(resource) do
    resource
    |> Info.attributes()
    |> Enum.filter(fn attr ->
      case attr.type do
        Ash.Type.Atom -> true
        :atom -> true
        _ -> false
      end
    end)
    |> Enum.map(& &1.name)
    |> MapSet.new()
  end

  # Returns true if the value should be converted from a UUID string to binary.
  # Conversion is gated strictly on the *attribute's declared type*: only
  # attributes configured as UUID (by name) are eligible. We deliberately do
  # NOT fall back to a value-based heuristic (36-char string with 4 hyphens)
  # because ordinary text values can match that shape by coincidence and would
  # be silently corrupted into a 16-byte binary.
  @spec uuid_field?(term(), term(), MapSet.t(), module()) :: boolean()
  defp uuid_field?(k, v, uuid_fields, _resource) do
    is_binary(v) and k in uuid_fields
  end

  # Builds a map of attribute name (atom & string) => CQL type string for typed params.
  # This allows the data layer to correctly tag FLOAT vs DOUBLE values for Xandra.
  @doc false
  @spec attr_cql_type_map(module()) :: %{(atom() | String.t()) => String.t()}
  def attr_cql_type_map(resource) do
    if Ash.Resource.Info.resource?(resource) do
      resource
      |> Info.attributes()
      |> Enum.reduce(%{}, fn attr, acc ->
        cql = resolve_attr_cql_type(attr)

        acc
        |> Map.put(attr.name, cql)
        |> Map.put(to_string(attr.name), cql)
      end)
    else
      %{}
    end
  end

  # Resolves the CQL type for an Ash attribute, trying storage_type/1 first
  # for Ash type modules, then falling back to the raw attr.type.
  defp resolve_attr_cql_type(attr) do
    if is_atom(attr.type) and function_exported?(attr.type, :storage_type, 1) do
      ash_type_to_cql(attr.type.storage_type([]))
    else
      ash_type_to_cql(attr.type)
    end
  end

  # ---------------------------------------------------------------------------
  # Ash → CQL Type Mapping
  # ---------------------------------------------------------------------------

  # Maps an Ash attribute type to a Xandra-compatible CQL type string.
  # Xandra's TypeParser.parse/1 parses these strings into the internal
  # representation used by encode_value/2 (e.g., "list<text>" → {:list, [:text]}).
  #
  # Simple types:
  #   :uuid → "uuid"
  #   :string → "text"
  #   :integer → "bigint"
  #   :float → "double"
  #   :boolean → "boolean"
  #   :utc_datetime → "timestamp"
  #   :date → "date"
  #   :time → "time"
  #   :decimal → "decimal"
  #   :binary → "blob"
  #
  # Collection types:
  #   {:array, :string} → "list<text>"
  #   {:array, :uuid} → "list<uuid>"
  #   {:set, :string} → "set<text>"
  #   {:map, :string, :string} → "map<text, text>"
  #   :list → "list<text>"
  #   :map → "map<text, text>"
  #
  # Module types (Ash.Type.*):
  #   Ash.Type.UUID → "uuid"
  #   Ash.Type.String → "text"
  #   etc.
  @spec ash_type_to_cql(atom() | tuple()) :: String.t()
  def ash_type_to_cql(type)

  # Module-based Ash types
  def ash_type_to_cql(Ash.Type.UUID), do: "uuid"
  def ash_type_to_cql(Ash.Type.Integer), do: "bigint"
  def ash_type_to_cql(Ash.Type.Float), do: "double"
  def ash_type_to_cql(Ash.Type.Boolean), do: "boolean"
  def ash_type_to_cql(Ash.Type.String), do: "text"
  def ash_type_to_cql(Ash.Type.DateTime), do: "timestamp"
  def ash_type_to_cql(Ash.Type.Date), do: "date"
  def ash_type_to_cql(Ash.Type.Time), do: "time"
  def ash_type_to_cql(Ash.Type.Decimal), do: "decimal"
  def ash_type_to_cql(Ash.Type.Atom), do: "text"
  def ash_type_to_cql(Ash.Type.CiString), do: "text"
  def ash_type_to_cql(Ash.Type.Binary), do: "blob"
  def ash_type_to_cql(Ash.Type.Duration), do: "duration"

  # Atom-based types
  def ash_type_to_cql(:uuid), do: "uuid"
  def ash_type_to_cql(:uuid_v7), do: "uuid"
  def ash_type_to_cql(:integer), do: "bigint"
  def ash_type_to_cql(:float), do: "double"
  def ash_type_to_cql(:double), do: "double"
  def ash_type_to_cql(:boolean), do: "boolean"
  def ash_type_to_cql(:string), do: "text"
  def ash_type_to_cql(:text), do: "text"
  def ash_type_to_cql(:utc_datetime), do: "timestamp"
  def ash_type_to_cql(:utc_datetime_usec), do: "timestamp"
  def ash_type_to_cql(:naive_datetime), do: "timestamp"
  def ash_type_to_cql(:naive_datetime_usec), do: "timestamp"
  def ash_type_to_cql(:timestamp), do: "timestamp"
  def ash_type_to_cql(:date), do: "date"
  def ash_type_to_cql(:time), do: "time"
  def ash_type_to_cql(:time_usec), do: "time"
  def ash_type_to_cql(:decimal), do: "decimal"
  def ash_type_to_cql(:binary), do: "blob"
  def ash_type_to_cql(:duration), do: "duration"
  def ash_type_to_cql(:ci_string), do: "text"
  def ash_type_to_cql(:atom), do: "text"

  # Collection types — default element types to "text"
  def ash_type_to_cql(:list), do: "list<text>"
  def ash_type_to_cql(:map), do: "map<text, text>"
  def ash_type_to_cql(:set), do: "set<text>"

  # Parameterized collection types
  def ash_type_to_cql({:array, element_type}) do
    "list<#{ash_type_to_cql(element_type)}>"
  end

  def ash_type_to_cql({:set, element_type}) do
    "set<#{ash_type_to_cql(element_type)}>"
  end

  def ash_type_to_cql({:map, key_type, value_type}) do
    "map<#{ash_type_to_cql(key_type)}, #{ash_type_to_cql(value_type)}>"
  end

  def ash_type_to_cql({:tuple, element_types}) when is_list(element_types) do
    inner = Enum.map_join(element_types, ", ", &ash_type_to_cql/1)
    "tuple<#{inner}>"
  end

  # Fallback for unknown types — default to "text"
  def ash_type_to_cql(_), do: "text"

  # ---------------------------------------------------------------------------
  # Value Type Wrapping
  # ---------------------------------------------------------------------------

  # Wraps values into {cql_type_string, value} tuples for Xandra 0.19.x.
  # Xandra requires typed parameters for simple queries — raw Elixir values
  # are not accepted. This function produces the correct type tag for every
  # Elixir value type, falling back to runtime type inference when the
  # attribute's declared CQL type is unavailable or incompatible.
  #
  # The cql_types map (from attr_cql_type_map/1) provides the declared CQL
  # type for each attribute. When the runtime value type conflicts with the
  # declared type (e.g., a list value for a :string attribute), runtime
  # inference takes precedence to avoid Xandra encoding errors.
  #
  # Public so the read path (QueryBuilder.filter_to_cql/3) can type filter
  # parameters identically to the write path.
  @doc false
  @spec wrap_typed(term(), atom() | String.t(), %{(atom() | String.t()) => String.t()}) ::
          {String.t(), term()} | nil
  def wrap_typed({type_str, _value} = typed, _key, _cql_types) when is_binary(type_str),
    do: typed

  # nil — wrapped as typed nil so Xandra's encode_query_value/1 handles it.
  # Raw nil would hit encode_query_value(nil) which has no matching clause.
  def wrap_typed(nil, _key, _cql_types), do: {"text", nil}

  # Boolean — always "boolean"
  def wrap_typed(value, _key, _cql_types) when is_boolean(value),
    do: {"boolean", value}

  # Float — use declared type (float vs double matters for ScyllaDB)
  def wrap_typed(value, key, cql_types) when is_float(value) do
    declared = Map.get(cql_types, key) || Map.get(cql_types, to_string(key))
    cql_type = if declared in ["float", "double"], do: declared, else: "double"
    {cql_type, value}
  end

  # Integer — use declared type or default to "bigint"
  def wrap_typed(value, key, cql_types) when is_integer(value) do
    declared = Map.get(cql_types, key) || Map.get(cql_types, to_string(key))

    cql_type =
      if declared in ["bigint", "int", "smallint", "tinyint", "counter", "varint"],
        do: declared,
        else: "bigint"

    {cql_type, value}
  end

  # Atom — convert to string, use declared type or default to "text"
  def wrap_typed(value, key, cql_types) when is_atom(value) do
    cql_type = Map.get(cql_types, key) || Map.get(cql_types, to_string(key), "text")
    {cql_type, Atom.to_string(value)}
  end

  # Binary — use declared type or default to "text"
  def wrap_typed(value, key, cql_types) when is_binary(value) do
    cql_type = Map.get(cql_types, key) || Map.get(cql_types, to_string(key), "text")
    {cql_type, value}
  end

  # List — must be wrapped as a list-compatible type for Xandra
  def wrap_typed(value, key, cql_types) when is_list(value) do
    declared = Map.get(cql_types, key) || Map.get(cql_types, to_string(key))

    cql_type =
      if declared && String.starts_with?(declared, "list") do
        declared
      else
        "list<text>"
      end

    {cql_type, value}
  end

  # Structs — must come before is_map since structs are maps.
  # These pass through unchanged; connection.ex typed_params handles wrapping.
  def wrap_typed(%DateTime{} = value, _key, _cql_types), do: value
  def wrap_typed(%Date{} = value, _key, _cql_types), do: value
  def wrap_typed(%Time{} = value, _key, _cql_types), do: value
  def wrap_typed(%Decimal{} = value, _key, _cql_types), do: value
  def wrap_typed(%MapSet{} = value, _key, _cql_types), do: value

  # Map — must be wrapped as a map-compatible type for Xandra
  def wrap_typed(value, key, cql_types) when is_map(value) do
    declared = Map.get(cql_types, key) || Map.get(cql_types, to_string(key))

    cql_type =
      if declared && String.starts_with?(declared, "map") do
        declared
      else
        "map<text, text>"
      end

    {cql_type, value}
  end

  # Catch-all: structs and unknown types pass through unchanged.
  # connection.ex typed_params handles struct wrapping (DateTime, Date, etc.).
  def wrap_typed(value, _key, _cql_types), do: value

  # ============================================================================
  # Ash.Extension callbacks
  # ============================================================================
  # Ash's generic mix tasks (codegen/migrate/setup/reset/rollback/tear_down/
  # install) dispatch to these. The data layer module is what gets discovered
  # as an extension, so the callbacks live here; the real implementation is
  # kept in `AshScylla.Extension` and forwarded to below.

  @impl Ash.Extension
  def codegen(argv) do
    AshScylla.MigrationGenerator.generate(AshScylla.Extension.parse_codegen_argv(argv))
  end

  @impl Ash.Extension
  def setup(argv), do: AshScylla.Extension.setup(argv)

  @impl Ash.Extension
  def migrate(argv), do: AshScylla.Extension.migrate(argv)

  @impl Ash.Extension
  def install(igniter, module, type, location, argv),
    do: AshScylla.Extension.install(igniter, module, type, location, argv)

  @impl Ash.Extension
  def reset(argv), do: AshScylla.Extension.reset(argv)

  @impl Ash.Extension
  def rollback(argv), do: AshScylla.Extension.rollback(argv)

  @impl Ash.Extension
  def tear_down(argv), do: AshScylla.Extension.tear_down(argv)
end
