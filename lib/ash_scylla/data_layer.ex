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
  - `:sort` - Sort results
  - `:limit` - Limit results
  - `:offset` - Offset results (use with caution in Cassandra)
  - `:select` - Select specific fields
  - `:multitenancy` - Keyspace-based multitenancy

  ## Limitations

  Since ScyllaDB/Cassandra is a wide-column store, not all SQL features are supported:
  - No JOINs (use denormalization or multiple queries)
  - Limited aggregation support
  - No transactions across partitions (lightweight transactions only)
  - No complex WHERE clauses on non-primary key columns without secondary indexes
  """

  @behaviour Ash.DataLayer

  require Ecto.Query
  require Logger
  require Xandra

  alias Ash.Resource.Info
  alias Ash.Type.UUID
  alias AshScylla.DataLayer.Batch
  alias AshScylla.DataLayer.Dsl
  alias AshScylla.DataLayer.QueryBuilder

  @dialyzer :no_match

  @supported_features MapSet.new([
                        :create,
                        :read,
                        :update,
                        :destroy,
                        :filter,
                        :sort,
                        :limit,
                        :offset,
                        :select,
                        :multitenancy,
                        :bulk_create
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
    tenant: nil
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
          tenant: term()
        }

  # ============================================================================
  # Required Callbacks
  # ============================================================================

  @impl Ash.DataLayer
  @spec can?(Ash.Resource.t() | Ash.DataLayer.t(), atom() | {atom(), term()}) :: boolean()
  def can?(_resource_or_dsl, feature) when is_atom(feature) do
    MapSet.member?(@supported_features, feature)
  end

  def can?(_resource_or_dsl, _other) do
    false
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
    %__MODULE__{repo: repo, table: _table, tenant: tenant} = data_layer_query

    # Build the optimized query with filters, sorts, limit, offset
    {query, params} = QueryBuilder.build_optimized_query(data_layer_query)

    opts = if tenant, do: [prefix: tenant], else: []

    Logger.debug(
      "Executing run_query: #{query} with params #{inspect(params)} opts #{inspect(opts)}"
    )

    case repo.query(query, params, opts) do
      {:ok, %{rows: rows}} ->
        records = Enum.map(rows, &to_ash_record(&1, resource))
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

    {:ok, %{data_layer_query | filters: [filter | filters]}}
  end

  # ============================================================================
  # Optional Callbacks - Sort
  # ============================================================================

  @impl Ash.DataLayer
  @spec sort(t(), term(), Ash.Resource.t()) :: {:ok, t()}
  def sort(data_layer_query, sort, _resource) do
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
  # Helper Functions
  # ============================================================================

  @valid_identifier ~r/^[a-zA-Z_][a-zA-Z0-9_]*$/

  @doc false
  @spec sanitize_identifier(String.t()) :: String.t()
  defp sanitize_identifier(name) when is_binary(name) do
    if Regex.match?(@valid_identifier, name) do
      name
    else
      raise ArgumentError,
            "Invalid identifier: #{inspect(name)}. Identifiers must match ~r/^[a-zA-Z_][a-zA-Z0-9_]*$/"
    end
  end

  defp repo(resource) do
    # Cache the repo module per resource to avoid repeated Module.get_attribute calls.
    case Process.get({__MODULE__, :repo, resource}) do
      nil ->
        case Module.get_attribute(resource, :repo) do
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

  defp changeset_to_update_attrs(changeset, _resource) do
    changeset.attributes
  end

  defp autogenerate_value(attr) do
    case attr.type do
      UUID -> Ecto.UUID.generate()
      Ash.Type.Integer -> nil
      _ -> nil
    end
  end

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

  defp get_primary_key(changeset, resource) do
    Enum.reduce(Info.attributes(resource), %{}, fn attr, acc ->
      if attr.primary_key? do
        Map.put(acc, attr.name, Map.get(changeset.attributes, attr.name))
      else
        acc
      end
    end)
  end

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
  defp build_opts(resource) do
    keyspace = Dsl.keyspace(resource)
    ttl = Dsl.ttl(resource)
    consistency = Dsl.consistency(resource)

    []
    |> maybe_put(:prefix, sanitize_keyspace(keyspace))
    |> maybe_put(:ttl, ttl)
    |> maybe_put(:consistency, consistency)
  end

  defp sanitize_keyspace(nil), do: nil
  defp sanitize_keyspace(keyspace), do: sanitize_identifier(keyspace)

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  # Normalize ScyllaDB/Xandra errors into AshScylla errors.
  defp handle_scylla_result({:ok, _} = ok), do: ok
  defp handle_scylla_result(:ok), do: :ok

  defp handle_scylla_result({:error, %Xandra.Error{} = error}) do
    Logger.warning("Xandra error: #{Exception.message(error)}")
    {:error, AshScylla.Error.wrap_xandra_error(error)}
  end

  defp handle_scylla_result({:error, %Xandra.ConnectionError{} = error}) do
    Logger.warning("Xandra connection error: #{Exception.message(error)}")
    {:error, AshScylla.Error.wrap_xandra_error(error)}
  end

  defp handle_scylla_result({:error, error}) do
    Logger.error("Unexpected error: #{inspect(error)}")
    {:error, AshScylla.Error.wrap_xandra_error(error)}
  end
end
