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
  alias AshScylla.DataLayer.Types
  alias AshScylla.Identifier
  alias AshScylla.Telemetry

  @dialyzer :no_match

  @compile {:inline, sanitize_identifier: 1}

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
                        :boolean_filter
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
    distinct: nil,
    tenant: nil,
    context: %{},
    atomic: nil,
    upsert?: false,
    upsert_fields: [],
    upsert_identity: nil,
    keyset: nil,
    aggregates: [],
    group_by: nil
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
          distinct: list(atom()) | nil,
          tenant: term(),
          context: map(),
          atomic: atom() | nil,
          upsert?: boolean(),
          upsert_fields: list(atom()),
          upsert_identity: atom() | nil,
          keyset: term(),
          aggregates: list(map()),
          group_by: list(atom()) | nil
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

  @impl Ash.DataLayer
  def can?(_resource_or_dsl, {:atomic, :upsert}) do
    true
  end

  @impl Ash.DataLayer
  def can?(_resource_or_dsl, :upsert), do: true

  @impl Ash.DataLayer
  def can?(_resource_or_dsl, :keyset), do: true

  @impl Ash.DataLayer
  def can?(_resource_or_dsl, {:combine, :union}), do: false

  @impl Ash.DataLayer
  def can?(_resource_or_dsl, :boolean_filter), do: true

  @impl Ash.DataLayer
  def can?(_resource_or_dsl, :distinct), do: true

  @impl Ash.DataLayer
  def can?(_resource_or_dsl, :expression_calculation), do: false

  @impl Ash.DataLayer
  def can?(_resource_or_dsl, :lateral_join), do: false

  @impl Ash.DataLayer
  def can?(_resource_or_dsl, {:aggregate, :count}), do: true

  @impl Ash.DataLayer
  def can?(_resource_or_dsl, {:aggregate, _}), do: false

  @impl Ash.DataLayer
  def can?(_resource_or_dsl, :update_query), do: true

  @impl Ash.DataLayer
  def can?(_resource_or_dsl, :destroy_query), do: true

  @impl Ash.DataLayer
  def can?(_resource_or_dsl, :lock), do: false

  @impl Ash.DataLayer
  def can?(_resource_or_dsl, :offset), do: false

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

    # Convert UUID string params to binary for Xandra
    params = convert_uuid_params(params, resource)

    opts = build_query_opts(resource, tenant)

    Logger.debug(
      "Executing run_query: #{query} with params #{inspect(params)} opts #{inspect(opts)}"
    )

    Telemetry.span(resource, :read, query, fn ->
      case repo.query(query, params, opts) do
        {:ok, %Xandra.Page{content: content, columns: columns}} when columns != nil ->
            rows = content || []
            records = Enum.map(rows, &to_ash_record(&1, resource, columns))
            %__MODULE__{context: context} = data_layer_query
            {:ok, apply_calculations(records, context)}

          {:ok, %Xandra.Page{content: content}} ->
          rows = content || []
          records = Enum.map(rows, &to_ash_record(&1, resource))
          %__MODULE__{context: context} = data_layer_query
          {:ok, apply_calculations(records, context)}

        error ->
          handle_query_result(error)
      end
    end)
  rescue
    e -> handle_query_result({:error, e})
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
  def offset(_data_layer_query, _offset, _resource) do
    raise "OFFSET is not supported in ScyllaDB/Cassandra. Use keyset pagination instead."
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
  @spec transform_query(Ash.Query.t()) :: Ash.Query.t()
  def transform_query(query) do
    # Hook for pre-execution transformation.
    # Currently a no-op; can be used to inject mandatory filters from context.
    query
  end

  @impl Ash.DataLayer
  @spec bulk_create(Ash.Resource.t(), Enumerable.t(Ash.Changeset.t()), map()) ::
          :ok | {:ok, Enumerable.t(Ash.Resource.t())} | {:error, term()}
  def bulk_create(resource, changesets, opts) do
    opts = normalize_bulk_options(opts)
    repo = repo(resource)
    table = source(resource)
    keyspace = Dsl.keyspace(resource)

    ttl = Dsl.ttl(resource)
    consistency = Dsl.consistency(resource)
    sanitized_table = sanitize_identifier(table)
    batch_size = Keyword.get(opts, :batch_size, :infinity)
    return_records? = Keyword.get(opts, :return_records?, true)

    statements =
      changesets
      |> Enum.map(fn changeset ->
        attrs = changeset_to_insert_attrs(changeset, resource)
        build_insert_statement(sanitized_table, attrs, ttl, resource)
      end)

    opts =
      []
      |> maybe_put(:prefix, sanitize_keyspace(keyspace))
      |> maybe_put(:consistency, consistency)

    Logger.info("Bulk creating records in table #{table}")

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
      :ok -> :ok
      {:error, error} -> handle_scylla_result({:error, error})
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
    _ ->
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
            |> Enum.map(&Macro.underscore/1)
            |> Enum.join("_")
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
    |> sanitize_identifier()
  end

  # ============================================================================
  # Optional Callbacks - Bulk Update / Delete / Distinct / Lock / Combination
  # ============================================================================

  @impl Ash.DataLayer
  @spec update_query(t(), Ash.Changeset.t(), keyword(), Ash.Resource.t()) ::
          {:ok, [Ash.Resource.t()]} | {:error, term()}
  def update_query(data_layer_query, changeset, _opts, resource) do
    repo = repo(resource)
    opts = build_opts(resource)
    sanitized_table = sanitize_identifier(source(resource))
    attrs = changeset_to_update_attrs(changeset, resource)

    {set_clauses, set_values} = build_set_clauses(attrs, resource)

    %__MODULE__{filters: filters} = data_layer_query
    {where_clause, where_params} = QueryBuilder.build_where_clause(filters)
    where_params = convert_uuid_params(where_params, resource)

    query =
      IO.iodata_to_binary([
        "UPDATE ",
        sanitized_table,
        " SET ",
        Enum.join(set_clauses, ", "),
        " WHERE ",
        where_clause
      ])

    Logger.debug(
      "Executing bulk UPDATE: #{query} with params #{inspect(set_values ++ where_params)}"
    )

    with {:ok, _} <- repo.query(query, set_values ++ where_params, opts) do
      run_query(data_layer_query, resource)
    end
  end

  @impl Ash.DataLayer
  @spec destroy_query(t(), Ash.Changeset.t(), keyword(), Ash.Resource.t()) ::
          :ok | {:error, term()}
  def destroy_query(data_layer_query, _changeset, _opts, resource) do
    repo = repo(resource)
    opts = build_opts(resource)
    sanitized_table = sanitize_identifier(source(resource))

    %__MODULE__{filters: filters} = data_layer_query
    {where_clause, where_params} = QueryBuilder.build_where_clause(filters)
    where_params = convert_uuid_params(where_params, resource)

    query =
      IO.iodata_to_binary(["DELETE FROM ", sanitized_table, " WHERE ", where_clause])

    Logger.debug("Executing bulk DELETE: #{query} with params #{inspect(where_params)}")

    with {:ok, _} <- repo.query(query, where_params, opts), do: :ok
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
    where_params = convert_uuid_params(where_params, resource)

    # Build COUNT queries for each aggregate
    results =
      Enum.reduce_while(aggregates, %{}, fn aggregate, acc ->
        case build_aggregate_query(aggregate, sanitized_table, where_clause) do
          {:error, reason} ->
            {:halt, {:error, reason}}

          {query, params} ->
            case repo.query(query, where_params ++ params, opts) do
              {:ok, %Xandra.Page{content: [[count]]}} when is_integer(count) ->
                {:cont, Map.put(acc, aggregate.name, count)}

              {:ok, %Xandra.Page{content: [[count]]}} ->
                count = String.to_integer(to_string(count))
                {:cont, Map.put(acc, aggregate.name, count)}

              {:ok, %Xandra.Page{content: []}} ->
                {:cont, Map.put(acc, aggregate.name, 0)}

              {:ok, %Xandra.Page{content: nil}} ->
                {:cont, Map.put(acc, aggregate.name, 0)}

              {:error, reason} ->
                {:halt, {:error, reason}}
            end
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

  @spec build_insert_statement(String.t(), map(), pos_integer() | nil, module()) :: {String.t(), list()}
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

    sanitized_table = sanitize_identifier(source(resource))

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

  @doc false
  @spec sanitize_identifier(String.t()) :: String.t() | no_return()
  defp sanitize_identifier(name) when is_binary(name) do
    Identifier.sanitize!(name)
  end

  @spec repo(module()) :: module()
  defp repo(resource) do
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

            To fix this, add a repo to your resource's ash_scylla DSL block:

                import AshScylla.DataLayer.Dsl

                ash_scylla do
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
    case attr.type do
      UUID -> generate_uuid()
      Ash.Type.Integer -> nil
      _ -> nil
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
    case Map.fetch(attr, :autogenerate?) do
      {:ok, value} -> value
      :error -> is_function(Map.get(attr, :default))
    end
  end

  @spec do_insert(map(), module(), module()) :: {:ok, term()} | {:error, term()}
  defp do_insert(attrs, resource, repo) do
    opts = build_opts(resource)
    ttl = Dsl.ttl(resource)

    sanitized_table = sanitize_identifier(source(resource))
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

    Logger.debug("Executing INSERT: #{query} with params #{inspect(values)}")

    with {:ok, _} <- repo.query(query, values, opts),
         pk <- get_primary_key(%{attributes: attrs}, resource),
         {:ok, record} <- fetch_by_primary_key(pk, resource, repo) do
      {:ok, to_ash_record(record, resource)}
    end
    |> handle_scylla_result()
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
        {:error, _} = error -> handle_scylla_result(error)
      end
    else
      do_update_non_empty(attrs, changeset, resource, repo)
    end
  end

  defp do_update_non_empty(attrs, changeset, resource, repo) do
    opts = build_opts(resource)
    sanitized_table = sanitize_identifier(source(resource))

    {set_clauses, values} = build_set_clauses(attrs, resource)

    {pk_where, pk_values} = build_pk_where_clause(changeset, resource)

    query =
      IO.iodata_to_binary([
        "UPDATE ",
        sanitized_table,
        " SET ",
        Enum.join(set_clauses, ", "),
        " WHERE ",
        pk_where
      ])

    Logger.debug("Executing UPDATE: #{query} with params #{inspect(values ++ pk_values)}")

    with {:ok, _} <- repo.query(query, values ++ pk_values, opts),
         {:ok, record} <- fetch_by_pk(changeset, resource, repo) do
      {:ok, to_ash_record(record, resource)}
    end
    |> handle_scylla_result()
  end

  @spec do_delete(term(), module(), module()) :: :ok | {:error, term()}
  defp do_delete(changeset, resource, repo) do
    opts = build_opts(resource)
    sanitized_table = sanitize_identifier(source(resource))

    {pk_where, pk_values} = build_pk_where_clause(changeset, resource)

    query =
      IO.iodata_to_binary(["DELETE FROM ", sanitized_table, " WHERE ", pk_where])

    Logger.debug("Executing DELETE: #{query} with params #{inspect(pk_values)}")

    with {:ok, _} <- repo.query(query, pk_values, opts), do: :ok
  end

  @spec fetch_by_primary_key(map(), module(), module()) :: {:ok, term()} | {:error, term()}
  defp fetch_by_primary_key(pk, resource, repo) do
    sanitized_table = sanitize_identifier(source(resource))
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

      {:ok, %Xandra.Page{content: []}} -> not_found_error(sanitized_table, pk)
      {:ok, %Xandra.Page{content: nil}} -> not_found_error(sanitized_table, pk)
      {:error, error} -> handle_scylla_result({:error, error})
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

  @spec to_ash_record(term(), module(), list() | nil) :: struct()
  defp to_ash_record(record, resource, columns \\ nil)

  defp to_ash_record({row, columns}, resource, _) do
    to_ash_record(row, resource, columns)
  end

  defp to_ash_record(record, resource, columns) when is_list(record) and is_list(columns) do
    # Convert positional list from Xandra to a map using column metadata names
    record_map =
      record
      |> Enum.zip(columns)
      |> Enum.reduce(%{}, fn {value, col_name}, acc -> Map.put(acc, col_name, value) end)

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

    attrs =
      resource
      |> Info.attributes()
      |> Enum.reduce(%{}, fn attr, acc ->
        value = Map.get(record, attr.name)

        decoded_value =
          if attr.name in uuid_fields and is_binary(value) and byte_size(value) == 16 do
            case Types.uuid_binary_to_string(value) do
              {:ok, str} -> str
              _ -> value
            end
          else
            value
          end

        Map.put(acc, attr.name, decoded_value)
      end)

    struct(resource, attrs)
  end

  # Build repo query options from resource configuration (consistency only).
  # Keyspace is handled at connection level; TTL is inline in CQL.
  @spec build_opts(module()) :: keyword()
  defp build_opts(resource) do
    consistency = Dsl.consistency(resource)
    if consistency, do: [consistency: consistency], else: []
  end

  # Build query options for read operations (consistency only).
  # Keyspace is handled at connection level.
  @spec build_query_opts(module(), String.t() | nil) :: keyword()
  defp build_query_opts(resource, _tenant) do
    consistency = Dsl.consistency(resource)
    if consistency, do: [consistency: consistency], else: []
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

  defp handle_scylla_result({:error, %AshScylla.Error.ScyllaError{}} = error), do: error

  @spec handle_scylla_result({:error, term()}) :: {:error, term()}
  defp handle_scylla_result({:error, error}) do
    Logger.error("Unexpected error: #{inspect(error)}")
    {:error, AshScylla.Error.wrap_xandra_error(error)}
  end

  # ---------------------------------------------------------------------------
  # SQL Construction Helpers
  # ---------------------------------------------------------------------------

  @spec handle_query_result({:ok, term()} | {:error, term()}) :: {:ok, term()} | {:error, term()}
  defp handle_query_result({:ok, _} = ok), do: ok

  defp handle_query_result({:error, %Xandra.Error{} = error}) do
    Logger.warning("Xandra error: #{Exception.message(error)}")
    {:error, AshScylla.Error.wrap_xandra_error(error)}
  end

  defp handle_query_result({:error, %Xandra.ConnectionError{} = error}) do
    Logger.warning("Xandra connection error: #{Exception.message(error)}")
    {:error, AshScylla.Error.wrap_xandra_error(error)}
  end

  defp handle_query_result({:error, error}) when is_exception(error) do
    Logger.error("Unexpected error in run_query: #{Exception.message(error)}")
    {:error, AshScylla.Error.wrap_xandra_error(error)}
  end

  defp handle_query_result({:error, error}) do
    Logger.error("Unexpected error: #{inspect(error)}")
    {:error, AshScylla.Error.wrap_xandra_error(error)}
  end

  @spec build_field_value_pairs(map(), module()) :: {[String.t()], [term()]}
  defp build_field_value_pairs(attrs, resource) do
    uuid_fields = uuid_attribute_names(resource)

    {fields, values} =
      Enum.reduce(attrs, {[], []}, fn {k, v}, {fs, vs} ->
        value =
          if k in uuid_fields and is_binary(v) do
            case Types.uuid_string_to_binary(v) do
              {:ok, bin} -> bin
              _ -> v
            end
          else
            v
          end

        {[sanitize_identifier(to_string(k)) | fs], [value | vs]}
      end)

    {Enum.reverse(fields), :lists.reverse(values)}
  end

  @spec build_set_clauses(map(), module()) :: {[String.t()], [term()]}
  defp build_set_clauses(attrs, resource) do
    uuid_fields = uuid_attribute_names(resource)

    {clauses, values} =
      Enum.reduce(attrs, {[], []}, fn {k, v}, {cs, vs} ->
        sanitized = sanitize_identifier(to_string(k))

        value =
          if k in uuid_fields and is_binary(v) do
            case Types.uuid_string_to_binary(v) do
              {:ok, bin} -> bin
              _ -> v
            end
          else
            v
          end

        {["#{sanitized} = ?" | cs], [value | vs]}
      end)

    {Enum.reverse(clauses), :lists.reverse(values)}
  end

  @spec build_pk_where_clause(term(), module()) :: {String.t(), [term()]}
  defp build_pk_where_clause(changeset, resource) do
    pk = get_primary_key(changeset, resource)
    build_where_from_map(pk, resource)
  end

  @spec build_where_from_map(map(), module()) :: {String.t(), [term()]}
  defp build_where_from_map(pk_map, resource) do
    uuid_fields = uuid_attribute_names(resource)

    {clauses, values} =
      Enum.reduce(pk_map, {[], []}, fn {k, v}, {cs, vs} ->
        sanitized = sanitize_identifier(to_string(k))

        value =
          if k in uuid_fields and is_binary(v) do
            case Types.uuid_string_to_binary(v) do
              {:ok, bin} -> bin
              _ -> v
            end
          else
            v
          end

        {["#{sanitized} = ?" | cs], [value | vs]}
      end)

    {Enum.reverse(clauses) |> Enum.join(" AND "), :lists.reverse(values)}
  end

  @spec uuid_attribute_names(module()) :: MapSet.t(atom())
  defp uuid_attribute_names(resource) do
    resource
    |> Info.attributes()
    |> Enum.filter(fn attr ->
      case attr.type do
        Ash.Type.UUID -> true
        :uuid -> true
        _ -> false
      end
    end)
    |> Enum.map(& &1.name)
    |> MapSet.new()
  end

  # Converts UUID string params to 16-byte binaries for Xandra.
  # This handles filter params where we don't have attribute name context -
  # we check if the param looks like a UUID string (36 chars, 4 hyphens).
  @spec convert_uuid_params(list(), module()) :: list()
  defp convert_uuid_params(params, _resource) do
    Enum.map(params, fn
      value when is_binary(value) and byte_size(value) == 36 ->
        bin_count = value |> String.graphemes() |> Enum.count(&(&1 == "-"))

        if bin_count == 4 do
          case Types.uuid_string_to_binary(value) do
            {:ok, bin} -> bin
            _ -> value
          end
        else
          value
        end

      value ->
        value
    end)
  end
end
