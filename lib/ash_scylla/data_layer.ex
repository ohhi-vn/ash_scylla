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
  An Ash data layer for ScyllaDB using Exandra (Ecto adapter for Cassandra/ScyllaDB).

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
  - `{:aggregate, :count}` - Per-partition COUNT aggregates
  - `{:atomic, :update}` - Atomic updates via LWT (IF clauses)
  - `{:atomic, :upsert}` - Atomic upserts via LWT
  - `:boolean_filter` - OR filter rewriting to IN where possible

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
  - OFFSET is not natively supported in ScyllaDB
  """

  @behaviour Ash.DataLayer

  require Logger

  alias Ash.Resource.Info
  alias Ash.Type.UUID
  alias AshScylla.DataLayer.Batch
  alias AshScylla.DataLayer.Dsl
  alias AshScylla.DataLayer.FilterValidator
  alias AshScylla.DataLayer.QueryBuilder
  alias AshScylla.Telemetry

  @dialyzer :no_match

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
                        :upsert
                      ])

  # ============================================================================
  # Data Layer Query Struct
  # ============================================================================

  defstruct [
    :resource,
    :repo,
    :table,
    filters: [],
    sorts: [],
    limit: nil,
    offset: nil,
    select: nil,
    tenant: nil,
    context: %{},
    atomic: nil,
    upsert?: false,
    upsert_fields: [],
    upsert_identity: nil,
    keyset: nil
  ]

  @type t :: %__MODULE__{
          resource: Ash.Resource.t(),
          repo: module() | nil,
          table: String.t() | nil,
          filters: list(),
          sorts: list(),
          limit: pos_integer() | nil,
          offset: pos_integer() | nil,
          select: list(atom()) | nil,
          tenant: term(),
          context: map(),
          atomic: atom() | nil,
          upsert?: boolean(),
          upsert_fields: list(atom()),
          upsert_identity: atom() | nil,
          keyset: term()
        }

  # ============================================================================
  # Required Callbacks
  # ============================================================================

  @impl Ash.DataLayer
  @spec can?(Ash.Resource.t() | Ash.DataLayer.t(), atom() | {atom(), term()}) :: boolean()
  def can?(_resource_or_dsl, {:atomic, :update}) do
    # LWT is supported - Ash will use it when resource has lwt: true
    true
  end

  def can?(_resource_or_dsl, {:atomic, :upsert}) do
    true
  end

  def can?(_resource_or_dsl, :upsert), do: true
  def can?(_resource_or_dsl, :keyset), do: true
  def can?(_resource_or_dsl, {:combine, :union}), do: false
  def can?(_resource_or_dsl, :boolean_filter), do: true
  def can?(_resource_or_dsl, :distinct), do: true
  def can?(_resource_or_dsl, :expression_calculation), do: false
  def can?(_resource_or_dsl, :lateral_join), do: false
  def can?(_resource_or_dsl, {:aggregate, :count}), do: true
  def can?(_resource_or_dsl, {:aggregate, _}), do: false
  def can?(_resource_or_dsl, :update_query), do: true
  def can?(_resource_or_dsl, :destroy_query), do: true
  def can?(_resource_or_dsl, :lock), do: false

  def can?(_resource_or_dsl, feature) when is_atom(feature) do
    MapSet.member?(@supported_features, feature)
  end

  def can?(_resource_or_dsl, _other) do
    false
  end

  @impl Ash.DataLayer
  @spec data_layer_keyset_by_default?() :: boolean()
  def data_layer_keyset_by_default? do
    true
  end

  @impl Ash.DataLayer
  @spec resource_to_query(Ash.Resource.t(), Ash.Domain.t()) :: t()
  def resource_to_query(resource, _domain) do
    table = source(resource)

    %__MODULE__{
      resource: resource,
      repo: repo(resource),
      table: table
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
  @spec destroy(Ash.Resource.t(), Ash.Changeset.t()) :: :ok | {:error, term()}
  def destroy(resource, changeset) do
    repo = repo(resource)

    do_delete(changeset, resource, repo)
  end

  @impl Ash.DataLayer
  @spec run_query(t(), Ash.Resource.t()) :: {:ok, [Ash.Resource.t()]} | {:error, term()}
  def run_query(data_layer_query, resource) do
    %__MODULE__{repo: repo, table: _table, tenant: tenant, filters: filters} = data_layer_query

    # Validate filters to prevent ALLOW FILTERING anti-pattern
    FilterValidator.validate_filters(resource, filters)

    # Build the optimized query with filters, sorts, limit, offset
    {query, params} = QueryBuilder.build_optimized_query(data_layer_query)

    opts = build_query_opts(resource, tenant)

    Logger.debug(
      "Executing run_query: #{query} with params #{inspect(params)} opts #{inspect(opts)}"
    )

    Telemetry.span(resource, :read, query, fn ->
      case repo.query(query, params, opts) do
        {:ok, %{rows: rows}} ->
          records = Enum.map(rows, &to_ash_record(&1, resource))
          # Post-process expression calculations
          %__MODULE__{context: context} = data_layer_query
          records = apply_calculations(records, context)
          {:ok, records}

        {:error, %Xandra.Error{} = error} ->
          Logger.warning("Xandra error in run_query repo.query: #{Exception.message(error)}")
          {:error, AshScylla.Error.wrap_xandra_error(error)}

        {:error, %Xandra.ConnectionError{} = error} ->
          Logger.warning(
            "Xandra connection error in run_query repo.query: #{Exception.message(error)}"
          )

          {:error, AshScylla.Error.wrap_xandra_error(error)}

        {:error, error} ->
          Logger.error("Unexpected error in run_query repo.query: #{inspect(error)}")
          {:error, AshScylla.Error.wrap_xandra_error(error)}
      end
    end)
  rescue
    e in Xandra.Error ->
      Logger.warning("Xandra error in run_query: #{Exception.message(e)}")
      {:error, AshScylla.Error.wrap_xandra_error(e)}

    e in Xandra.ConnectionError ->
      Logger.warning("Xandra connection error in run_query: #{Exception.message(e)}")
      {:error, AshScylla.Error.wrap_xandra_error(e)}

    e ->
      Logger.error("Unexpected error in run_query: #{Exception.message(e)}")
      {:error, AshScylla.Error.wrap_xandra_error(e)}
  end

  # ============================================================================
  # Optional Callbacks - Filter
  # ============================================================================

  @impl Ash.DataLayer
  @spec filter(t(), term(), Ash.Resource.t()) :: {:ok, t()}
  def filter(data_layer_query, filter, _resource) do
    %__MODULE__{filters: filters} = data_layer_query
    filter = maybe_rewrite_or_to_in(filter)
    {:ok, %{data_layer_query | filters: [filter | filters]}}
  end

  # ============================================================================
  # Optional Callbacks - Sort
  # ============================================================================

  @impl Ash.DataLayer
  @spec sort(t(), term(), Ash.Resource.t()) :: {:ok, t()}
  def sort(data_layer_query, sort, _resource) do
    Logger.warning("sort/3: CQL ORDER BY only works on clustering columns within a partition")
    %__MODULE__{sorts: sorts} = data_layer_query

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

  @impl Ash.DataLayer
  @spec offset(t(), pos_integer(), Ash.Resource.t()) :: {:ok, t()}
  def offset(data_layer_query, offset, _resource) do
    Logger.warning(
      "offset/3: OFFSET is not natively supported in ScyllaDB and results will be silently dropped"
    )

    {:ok, %{data_layer_query | offset: offset}}
  end

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
  def set_tenant(data_layer_query, tenant, _resource) do
    {:ok, %{data_layer_query | tenant: tenant}}
  end

  @impl Ash.DataLayer
  @spec set_context(t(), map(), Ash.Resource.t()) :: {:ok, t()}
  def set_context(data_layer_query, context, _resource) do
    %__MODULE__{context: existing} = data_layer_query
    merged = Map.merge(existing || %{}, context)
    {:ok, %{data_layer_query | context: merged}}
  end

  @impl Ash.DataLayer
  @spec transform_query(t()) :: {:ok, t()} | {:error, term()}
  def transform_query(data_layer_query) do
    # Hook for pre-execution transformation.
    # Currently a no-op; can be used to inject mandatory filters from context.
    {:ok, data_layer_query}
  end

  @impl Ash.DataLayer
  @spec bulk_create(Ash.Resource.t(), [Ash.Changeset.t()], keyword()) ::
          {:ok, [Ash.Resource.t()]} | {:error, term()}
  def bulk_create(resource, changesets, _opts) do
    repo = repo(resource)
    table = source(resource)
    keyspace = Dsl.keyspace(resource)

    # Get TTL and consistency from resource DSL
    ttl = Dsl.ttl(resource)
    consistency = Dsl.consistency(resource)

    sanitized_table = sanitize_identifier(table)

    # Build batch insert statements
    statements =
      Enum.map(changesets, fn changeset ->
        attrs = changeset_to_insert_attrs(changeset, resource)

        {sanitized_fields, values} =
          Enum.reduce(attrs, {[], []}, fn {k, v}, {fs, vs} ->
            {[sanitize_identifier(to_string(k)) | fs], [v | vs]}
          end)

        sanitized_fields = Enum.reverse(sanitized_fields)
        values = :lists.reverse(values)
        field_count = length(sanitized_fields)

        query =
          IO.iodata_to_binary([
            "INSERT INTO ",
            sanitized_table,
            " (",
            Enum.join(sanitized_fields, ", "),
            ") VALUES (",
            Enum.map_join(1..field_count, ", ", fn _ -> "?" end),
            ")",
            if(ttl, do: [" USING TTL ", to_string(ttl)], else: [])
          ])

        {query, values}
      end)

    # Execute batch insert
    opts =
      []
      |> maybe_put(:prefix, sanitize_keyspace(keyspace))
      |> maybe_put(:consistency, consistency)

    Logger.info("Bulk creating #{length(changesets)} records in table #{table}")

    Logger.warning(
      "bulk_create returns records constructed from changeset attributes, not from DB. DB defaults/triggers may not be reflected."
    )

    case Batch.batch_insert(repo, statements, opts) do
      {:ok, _} ->
        # Fetch created records
        records =
          changesets
          |> Enum.map(fn changeset ->
            attrs = changeset_to_insert_attrs(changeset, resource)
            to_ash_record(attrs, resource)
          end)

        {:ok, records}

      {:error, error} ->
        handle_scylla_result({:error, error})
    end
  end

  @impl Ash.DataLayer
  @spec upsert(Ash.Resource.t(), Ash.Changeset.t(), keyword()) ::
          {:ok, Ash.Resource.t()} | {:error, term()}
  def upsert(resource, changeset, opts \\ []) do
    repo = repo(resource)
    attrs = changeset_to_insert_attrs(changeset, resource)
    do_upsert(attrs, changeset, resource, repo, opts)
  end

  @impl Ash.DataLayer
  @spec source(Ash.Resource.t()) :: String.t()
  def source(resource) do
    # Cache the resolved table name per resource to avoid repeated Module.get_attribute calls.
    # This function is called multiple times per request (create, update, delete, fetch).
    case Process.get({__MODULE__, :source, resource}) do
      nil ->
        name =
          resource
          |> Module.get_attribute(:table)
          |> to_string()

        resolved =
          case name do
            "" ->
              resource
              |> Module.split()
              |> List.last()
              |> Macro.underscore()

            _ ->
              name
          end

        resolved = sanitize_identifier(resolved)
        Process.put({__MODULE__, :source, resource}, resolved)
        resolved

      cached ->
        cached
    end
  rescue
    _ ->
      name =
        resource
        |> Module.split()
        |> List.last()
        |> Macro.underscore()

      sanitize_identifier(name)
  end

  # ============================================================================
  # Optional Callbacks - Bulk Update / Delete / Distinct / Lock / Combination
  # ============================================================================

  @impl Ash.DataLayer
  @spec update_query(t(), Ash.Changeset.t(), keyword(), Ash.Resource.t()) ::
          {:ok, [Ash.Resource.t()]} | {:error, term()}
  def update_query(data_layer_query, changeset, _opts, resource) do
    repo = repo(resource)
    table = source(resource)
    opts = build_opts(resource)
    sanitized_table = sanitize_identifier(table)

    attrs = changeset_to_update_attrs(changeset, resource)

    # Build SET clauses
    {set_clauses_reversed, values_reversed} =
      Enum.reduce(attrs, {[], []}, fn {k, v}, {cs, vs} ->
        {["#{sanitize_identifier(to_string(k))} = ?" | cs], [v | vs]}
      end)

    set_clauses = Enum.reverse(set_clauses_reversed)
    values = :lists.reverse(values_reversed)

    # Build WHERE clause from filters
    %__MODULE__{filters: filters} = data_layer_query
    {where_clause, where_params} = QueryBuilder.build_where_clause(filters)

    query =
      IO.iodata_to_binary([
        "UPDATE ",
        sanitized_table,
        " SET ",
        Enum.join(set_clauses, ", "),
        " WHERE ",
        where_clause
      ])

    all_params = values ++ where_params

    Logger.debug("Executing bulk UPDATE: #{query} with params #{inspect(all_params)}")

    case repo.query(query, all_params, opts) do
      {:ok, _} ->
        # Re-run the query to fetch updated records
        run_query(data_layer_query, resource)

      {:error, error} ->
        handle_scylla_result({:error, error})
    end
  end

  @impl Ash.DataLayer
  @spec destroy_query(t(), Ash.Changeset.t(), keyword(), Ash.Resource.t()) ::
          :ok | {:error, term()}
  def destroy_query(data_layer_query, _changeset, _opts, resource) do
    repo = repo(resource)
    table = source(resource)
    opts = build_opts(resource)
    sanitized_table = sanitize_identifier(table)

    %__MODULE__{filters: filters} = data_layer_query
    {where_clause, where_params} = QueryBuilder.build_where_clause(filters)

    query =
      IO.iodata_to_binary([
        "DELETE FROM ",
        sanitized_table,
        " WHERE ",
        where_clause
      ])

    Logger.debug("Executing bulk DELETE: #{query} with params #{inspect(where_params)}")

    case repo.query(query, where_params, opts) do
      {:ok, _} -> :ok
      {:error, error} -> handle_scylla_result({:error, error})
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
      %__MODULE__{select: existing_select} = data_layer_query
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
    %__MODULE__{context: context} = data_layer_query
    aggregates = Map.get(context, :aggregates, [])
    {:ok, %{data_layer_query | context: Map.put(context, :aggregates, [aggregate | aggregates])}}
  end

  @impl Ash.DataLayer
  @spec add_aggregates(t(), [Ash.Query.Aggregate.t()], Ash.Resource.t()) ::
          {:ok, t()} | {:error, term()}
  def add_aggregates(data_layer_query, aggregates, _resource) do
    %__MODULE__{context: context} = data_layer_query
    existing = Map.get(context, :aggregates, [])
    {:ok, %{data_layer_query | context: Map.put(context, :aggregates, aggregates ++ existing)}}
  end

  @impl Ash.DataLayer
  @spec run_aggregate_query(t(), [Ash.Query.Aggregate.t()], Ash.Resource.t()) ::
          {:ok, map()} | {:error, term()}
  def run_aggregate_query(data_layer_query, aggregates, resource) do
    repo = repo(resource)
    table = source(resource)
    opts = build_opts(resource)
    sanitized_table = sanitize_identifier(table)
    %__MODULE__{filters: filters} = data_layer_query

    {where_clause, where_params} = QueryBuilder.build_where_clause(filters)

    # Build COUNT queries for each aggregate
    results =
      Enum.reduce_while(aggregates, %{}, fn aggregate, acc ->
        with {query, params} <- build_aggregate_query(aggregate, sanitized_table, where_clause),
             {:ok, %{rows: [[count]]}} <- repo.query(query, where_params ++ params, opts) do
          count = if is_integer(count), do: count, else: String.to_integer(to_string(count))
          {:cont, Map.put(acc, aggregate.name, count)}
        else
          {:error, reason} ->
            {:halt, {:error, reason}}
        end
      end)

    case results do
      {:error, error} -> handle_scylla_result({:error, error})
      map when is_map(map) -> {:ok, map}
    end
  end

  @impl Ash.DataLayer
  @spec calculate(t(), Ash.Query.Calculation.t(), Ash.Resource.t()) ::
          {:ok, t()} | {:error, term()}
  def calculate(data_layer_query, calculation, _resource) do
    # Expression calculations are done in Elixir post-processing
    %__MODULE__{context: context} = data_layer_query
    calculations = Map.get(context, :calculations, [])

    {:ok,
     %{data_layer_query | context: Map.put(context, :calculations, [calculation | calculations])}}
  end

  # ============================================================================
  # Private Helpers
  # ============================================================================

  @spec build_aggregate_query(Ash.Query.Aggregate.t(), String.t(), String.t()) ::
          {String.t(), list()} | {:error, term()}
  defp build_aggregate_query(%{kind: :count}, table, where_clause) do
    query =
      IO.iodata_to_binary([
        "SELECT COUNT(*) FROM ",
        table,
        if(where_clause != "", do: [" WHERE ", where_clause], else: [])
      ])

    {query, []}
  end

  defp build_aggregate_query(%{kind: kind}, _table, _where_clause) do
    {:error,
     "Aggregate kind #{kind} is not supported in ScyllaDB/Cassandra. Use :count or materialized views."}
  end

  @spec do_upsert(map(), Ash.Changeset.t(), Ash.Resource.t(), module(), keyword()) ::
          {:ok, Ash.Resource.t()} | {:error, term()}
  defp do_upsert(attrs, changeset, resource, repo, _opts) do
    table = source(resource)
    opts = build_opts(resource)
    ttl = Dsl.ttl(resource)
    lwt? = Dsl.lwt(resource)

    {sanitized_fields, values} =
      Enum.reduce(attrs, {[], []}, fn {k, v}, {fs, vs} ->
        {[sanitize_identifier(to_string(k)) | fs], [v | vs]}
      end)

    sanitized_fields = Enum.reverse(sanitized_fields)
    values = :lists.reverse(values)
    sanitized_table = sanitize_identifier(table)
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
      {:ok, %{rows: [[true]]}} ->
        # LWT succeeded — fetch the record
        {:ok, to_ash_record(attrs, resource)}

      {:ok, %{rows: [[false]]}} ->
        # LWT conflict — record already exists, do an update instead
        do_update(attrs, changeset, resource, repo)

      {:ok, _} ->
        # Non-LWT insert succeeded
        {:ok, to_ash_record(attrs, resource)}

      {:error, error} ->
        handle_scylla_result({:error, error})
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
      try do
        {:ok, module.calculate([record], opts)}
      rescue
        _ -> {:error, :calculation_failed}
      end
    else
      {:error, :no_calculate_function}
    end
  end

  defp calculate_in_memory(%{expr: expr}, record) when is_function(expr) do
    try do
      {:ok, expr.(record)}
    rescue
      _ -> {:error, :calculation_failed}
    end
  end

  defp calculate_in_memory(_, _), do: {:error, :unsupported_calculation}

  @spec maybe_rewrite_or_to_in(term()) :: term()
  defp maybe_rewrite_or_to_in(filter) do
    case filter do
      %{op: :or, left: %{name: name, op: :eq}, right: %{name: name, op: :eq}} ->
        values = collect_or_values(filter, name, [])
        %{operator: :in, left: %{name: name}, right: %{value: values}}

      _ ->
        filter
    end
  end

  @spec collect_or_values(term(), atom(), list()) :: list()
  defp collect_or_values(%{op: :or, left: left, right: right}, name, acc) do
    acc = collect_or_values(left, name, acc)
    collect_or_values(right, name, acc)
  end

  @spec collect_or_values(%{name: atom(), right: %{value: term()}}, atom(), list()) :: list()
  defp collect_or_values(%{name: name, right: %{value: value}}, name, acc) do
    [value | acc]
  end

  @spec collect_or_values(term(), atom(), list()) :: list()
  defp collect_or_values(_, _, acc), do: acc

  # ============================================================================
  # Helper Functions
  # ============================================================================

  @valid_identifier ~r/^[a-zA-Z_][a-zA-Z0-9_]*$/

  @doc false
  @spec sanitize_identifier(String.t()) :: String.t() | no_return()
  defp sanitize_identifier(name) when is_binary(name) do
    if Regex.match?(@valid_identifier, name) do
      name
    else
      raise ArgumentError,
            "Invalid identifier: #{inspect(name)}. Identifiers must match ~r/^[a-zA-Z_][a-zA-Z0-9_]*$/"
    end
  end

  @spec repo(module()) :: module()
  defp repo(resource) do
    # Cache the repo module per resource to avoid repeated lookups.
    case Process.get({__MODULE__, :repo, resource}) do
      nil ->
        repo =
          try do
            Module.get_attribute(resource, :repo)
          rescue
            ArgumentError -> nil
          end

        case repo do
          nil ->
            raise "No repo configured for #{inspect(resource)}"

          repo ->
            Process.put({__MODULE__, :repo, resource}, repo)
            repo
        end

      cached ->
        cached
    end
  end

  @spec changeset_to_insert_attrs(term(), module()) :: map()
  defp changeset_to_insert_attrs(changeset, resource) do
    attrs = changeset.attributes

    # Add primary key if not present and autogenerate is configured
    attrs =
      Enum.reduce(Info.attributes(resource), attrs, fn attr, acc ->
        if attr.primary_key? && attr.autogenerate? && !Map.has_key?(acc, attr.name) do
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
    case attr.type do
      UUID -> Ecto.UUID.generate()
      Ash.Type.Integer -> nil
      _ -> nil
    end
  end

  @spec do_insert(map(), module(), module()) :: {:ok, term()} | {:error, term()}
  defp do_insert(attrs, resource, repo) do
    table = source(resource)
    opts = build_opts(resource)
    ttl = Dsl.ttl(resource)

    {sanitized_fields, values} =
      Enum.reduce(attrs, {[], []}, fn {k, v}, {fs, vs} ->
        {[sanitize_identifier(to_string(k)) | fs], [v | vs]}
      end)

    # Both lists are reversed (prepended), so reverse back
    sanitized_fields = Enum.reverse(sanitized_fields)
    values = :lists.reverse(values)

    sanitized_table = sanitize_identifier(table)
    field_count = length(sanitized_fields)

    query =
      IO.iodata_to_binary([
        "INSERT INTO ",
        sanitized_table,
        " (",
        Enum.join(sanitized_fields, ", "),
        ") VALUES (",
        Enum.map_join(1..field_count, ", ", fn _ -> "?" end),
        ")",
        if(ttl, do: [" USING TTL ", to_string(ttl)], else: [])
      ])

    Logger.debug("Executing INSERT: #{query} with params #{inspect(values)}")

    with {:ok, _} <- repo.query(query, values, opts),
         {:ok, record} <- fetch_by_primary_key(attrs, resource, repo) do
      {:ok, to_ash_record(record, resource)}
    end
    |> handle_scylla_result()
  end

  @spec do_update(map(), term(), module(), module()) :: {:ok, term()} | {:error, term()}
  defp do_update(attrs, changeset, resource, repo) do
    table = source(resource)
    opts = build_opts(resource)
    sanitized_table = sanitize_identifier(table)

    # Build SET clauses and values in a single pass
    {set_clauses_reversed, values_reversed} =
      Enum.reduce(attrs, {[], []}, fn {k, v}, {cs, vs} ->
        {["#{sanitize_identifier(to_string(k))} = ?" | cs], [v | vs]}
      end)

    set_clauses = Enum.reverse(set_clauses_reversed)
    values = :lists.reverse(values_reversed)

    # Build WHERE clause from primary key
    pk = get_primary_key(changeset, resource)

    {pk_clauses_reversed, pk_values_reversed} =
      Enum.reduce(pk, {[], []}, fn {k, v}, {cs, vs} ->
        {["#{sanitize_identifier(to_string(k))} = ?" | cs], [v | vs]}
      end)

    pk_clauses = Enum.reverse(pk_clauses_reversed)
    pk_values = :lists.reverse(pk_values_reversed)

    query =
      IO.iodata_to_binary([
        "UPDATE ",
        sanitized_table,
        " SET ",
        Enum.join(set_clauses, ", "),
        " WHERE ",
        Enum.join(pk_clauses, " AND ")
      ])

    Logger.debug("Executing UPDATE: #{query} with params #{inspect(values ++ pk_values)}")

    with {:ok, _} <- repo.query(query, values ++ pk_values, opts),
         {:ok, record} <- fetch_by_primary_key(pk, resource, repo) do
      {:ok, to_ash_record(record, resource)}
    end
    |> handle_scylla_result()
  end

  @spec do_delete(term(), module(), module()) :: :ok | {:error, term()}
  defp do_delete(changeset, resource, repo) do
    table = source(resource)
    opts = build_opts(resource)
    pk = get_primary_key(changeset, resource)
    sanitized_table = sanitize_identifier(table)

    {pk_clauses_reversed, pk_values_reversed} =
      Enum.reduce(pk, {[], []}, fn {k, v}, {cs, vs} ->
        {["#{sanitize_identifier(to_string(k))} = ?" | cs], [v | vs]}
      end)

    pk_clauses = Enum.reverse(pk_clauses_reversed)
    pk_values = :lists.reverse(pk_values_reversed)

    query =
      IO.iodata_to_binary([
        "DELETE FROM ",
        sanitized_table,
        " WHERE ",
        Enum.join(pk_clauses, " AND ")
      ])

    Logger.debug("Executing DELETE: #{query} with params #{inspect(pk_values)}")

    case repo.query(query, pk_values, opts) do
      {:ok, _} ->
        :ok

      {:error, error} ->
        handle_scylla_result({:error, error})
    end
  end

  @spec fetch_by_primary_key(map(), module(), module()) :: {:ok, term()} | {:error, term()}
  defp fetch_by_primary_key(pk, resource, repo) do
    table = source(resource)
    sanitized_table = sanitize_identifier(table)

    {pk_clauses_reversed, pk_values_reversed} =
      Enum.reduce(pk, {[], []}, fn {k, v}, {cs, vs} ->
        {["#{sanitize_identifier(to_string(k))} = ?" | cs], [v | vs]}
      end)

    pk_clauses = Enum.reverse(pk_clauses_reversed)
    pk_values = :lists.reverse(pk_values_reversed)

    query =
      IO.iodata_to_binary([
        "SELECT * FROM ",
        sanitized_table,
        " WHERE ",
        Enum.join(pk_clauses, " AND "),
        " LIMIT 1"
      ])

    Logger.debug("Executing SELECT: #{query} with params #{inspect(pk_values)}")

    case repo.query(query, pk_values) do
      {:ok, %{rows: [row | _]}} ->
        {:ok, row}

      {:error, error} ->
        handle_scylla_result({:error, error})
    end
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

  @spec to_ash_record(map(), module()) :: struct()
  defp to_ash_record(record, resource) do
    attrs =
      resource
      |> Info.attributes()
      |> Enum.reduce(%{}, fn attr, acc ->
        value = Map.get(record, attr.name)
        Map.put(acc, attr.name, value)
      end)

    struct(resource, attrs)
  end

  # Build repo query options from resource configuration (keyspace, TTL, consistency).
  @spec build_opts(module()) :: keyword()
  defp build_opts(resource) do
    keyspace = Dsl.keyspace(resource)
    ttl = Dsl.ttl(resource)
    consistency = Dsl.consistency(resource)

    []
    |> maybe_put(:prefix, sanitize_keyspace(keyspace))
    |> maybe_put(:ttl, ttl)
    |> maybe_put(:consistency, consistency)
  end

  # Build query options for read operations, including per-action consistency.
  @spec build_query_opts(module(), String.t() | nil) :: keyword()
  defp build_query_opts(resource, tenant) do
    keyspace = Dsl.keyspace(resource)
    consistency = Dsl.consistency(resource)

    # Use tenant as prefix if set (for multitenancy), otherwise use keyspace
    prefix = if tenant, do: tenant, else: keyspace

    []
    |> maybe_put(:prefix, sanitize_keyspace(prefix))
    |> maybe_put(:consistency, consistency)
  end

  @spec sanitize_keyspace(String.t() | nil) :: String.t() | nil
  defp sanitize_keyspace(nil), do: nil
  defp sanitize_keyspace(keyspace), do: sanitize_identifier(keyspace)

  @spec maybe_put(keyword(), atom(), term()) :: keyword()
  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  # Normalize ScyllaDB/Xandra errors into AshScylla errors.
  @spec handle_scylla_result({:ok, term()} | :ok | {:error, term()}) ::
          {:ok, term()} | :ok | {:error, term()}
  defp handle_scylla_result({:ok, _} = ok), do: ok
  defp handle_scylla_result(:ok), do: :ok

  @spec handle_scylla_result({:error, Xandra.Error.t()}) :: {:error, term()}
  defp handle_scylla_result({:error, %Xandra.Error{} = error}) do
    Logger.warning("Xandra error: #{Exception.message(error)}")
    {:error, AshScylla.Error.wrap_xandra_error(error)}
  end

  @spec handle_scylla_result({:error, Xandra.ConnectionError.t()}) :: {:error, term()}
  defp handle_scylla_result({:error, %Xandra.ConnectionError{} = error}) do
    Logger.warning("Xandra connection error: #{Exception.message(error)}")
    {:error, AshScylla.Error.wrap_xandra_error(error)}
  end

  @spec handle_scylla_result({:error, term()}) :: {:error, term()}
  defp handle_scylla_result({:error, error}) do
    Logger.error("Unexpected error: #{inspect(error)}")
    {:error, AshScylla.Error.wrap_xandra_error(error)}
  end
end
