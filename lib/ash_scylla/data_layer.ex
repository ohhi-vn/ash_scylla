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
  require Xandra

  alias AshScylla.DataLayer.QueryBuilder

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
  @spec can?(Ash.Resource.t() | Ash.DataLayer.t(), atom()) :: boolean()
  def can?(_resource_or_dsl, {feature, _arg}) do
    case feature do
      :aggregate -> false
      :join -> false
      :lateral_join -> false
      :lock -> false
      :calculate -> false
      :combine -> false
      :transact -> false
      _ -> false
    end
  end

  def can?(_resource_or_dsl, feature) when is_atom(feature) do
    MapSet.member?(@supported_features, feature)
  end

  def can?(_resource_or_dsl, _other) do
    false
  end

  @impl Ash.DataLayer
  @spec resource_to_query(Ash.Resource.t(), Ash.Domain.t()) :: t()
  def resource_to_query(resource, _domain) do
    %__MODULE__{
      resource: resource,
      repo: repo(resource),
      table: source(resource)
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

    case repo.query(query, params, opts) do
      {:ok, %{rows: rows}} ->
        records = Enum.map(rows, &to_ash_record(&1, resource))
        {:ok, records}

      {:error, %Xandra.Error{} = error} ->
        {:error, AshScylla.Error.wrap_xandra_error(error)}

      {:error, %Xandra.ConnectionError{} = error} ->
        {:error, AshScylla.Error.wrap_xandra_error(error)}

      {:error, error} ->
        {:error, AshScylla.Error.wrap_xandra_error(error)}
    end
  rescue
    e in Xandra.Error ->
      {:error, AshScylla.Error.wrap_xandra_error(e)}

    e in Xandra.ConnectionError ->
      {:error, AshScylla.Error.wrap_xandra_error(e)}

    e ->
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
    keyspace = AshScylla.DataLayer.Dsl.keyspace(resource)

    # Get TTL and consistency from resource DSL
    ttl = AshScylla.DataLayer.Dsl.ttl(resource)
    consistency = AshScylla.DataLayer.Dsl.consistency(resource)

    # Build batch insert statements
    statements =
      Enum.map(changesets, fn changeset ->
        attrs = changeset_to_insert_attrs(changeset, resource)

        {fields, values} =
          attrs
          |> Enum.with_index()
          |> Enum.map(fn {{k, v}, _i} -> {"#{k}", v} end)
          |> Enum.unzip()

        using_clause =
          if ttl do
            " USING TTL #{ttl}"
          else
            ""
          end

        query = """
        INSERT INTO #{table} (#{Enum.join(fields, ", ")})
        VALUES (#{Enum.map(1..length(values), fn _ -> "?" end) |> Enum.join(", ")})#{using_clause}
        """

        {query, values}
      end)

    # Execute batch insert
    opts =
      []
      |> maybe_put(:prefix, keyspace)
      |> maybe_put(:consistency, consistency)

    case AshScylla.DataLayer.Batch.batch_insert(repo, statements, opts) do
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
    # Get the table name from the resource configuration
    # This is typically configured via `table "name"` in the resource DSL
    resource
    |> Module.get_attribute(:table)
    |> to_string()
  rescue
    _ ->
      # Fallback to resource name
      resource
      |> Module.split()
      |> List.last()
      |> Macro.underscore()
  end

  # ============================================================================
  # Helper Functions
  # ============================================================================

  defp repo(resource) do
    # Get the repo from the resource configuration
    case Module.get_attribute(resource, :repo) do
      nil -> raise "No repo configured for #{inspect(resource)}"
      repo -> repo
    end
  end

  defp changeset_to_insert_attrs(changeset, resource) do
    attrs = changeset.attributes

    # Add primary key if not present and autogenerate is configured
    attrs =
      Enum.reduce(Ash.Resource.Info.attributes(resource), attrs, fn attr, acc ->
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
      Ash.Type.UUID -> Ecto.UUID.generate()
      Ash.Type.Integer -> nil
      _ -> nil
    end
  end

  defp do_insert(attrs, resource, repo) do
    table = source(resource)
    opts = build_opts(resource)

    # Get TTL from resource DSL
    ttl = AshScylla.DataLayer.Dsl.ttl(resource)

    # Build the CQL INSERT statement for ScyllaDB
    {fields, values} =
      attrs |> Enum.with_index() |> Enum.map(fn {{k, v}, i} -> {"#{k}", v, i} end) |> Enum.unzip()

    # Add USING TTL clause if configured
    using_clause =
      if ttl do
        " USING TTL #{ttl}"
      else
        ""
      end

    query = """
    INSERT INTO #{table} (#{Enum.join(fields, ", ")})
    VALUES (#{Enum.map(1..length(values), fn _ -> "?" end) |> Enum.join(", ")})#{using_clause}
    """

    with {:ok, _} <- repo.query(query, values, opts),
         {:ok, record} <- fetch_by_primary_key(attrs, resource, repo) do
      {:ok, to_ash_record(record, resource)}
    end
    |> handle_scylla_result()
  end

  defp do_update(attrs, changeset, resource, repo) do
    table = source(resource)
    opts = build_opts(resource)

    # Build UPDATE statement
    set_clauses = Enum.map(attrs, fn {k, _v} -> "#{k} = ?" end)
    values = Map.values(attrs)

    # Get primary key for WHERE clause
    pk = get_primary_key(changeset, resource)
    pk_clause = Enum.map(pk, fn {k, _} -> "#{k} = ?" end)
    pk_values = Map.values(pk)

    query = """
    UPDATE #{table}
    SET #{Enum.join(set_clauses, ", ")}
    WHERE #{Enum.join(pk_clause, " AND ")}
    """

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
    pk_clause = Enum.map(pk, fn {k, _} -> "#{k} = ?" end)
    pk_values = Map.values(pk)

    query = """
    DELETE FROM #{table}
    WHERE #{Enum.join(pk_clause, " AND ")}
    """

    case repo.query(query, pk_values, opts) do
      {:ok, _} ->
        :ok

      {:error, error} ->
        handle_scylla_result({:error, error})
    end
  end

  defp fetch_by_primary_key(pk, resource, repo) do
    table = source(resource)

    pk_clause = Enum.map(pk, fn {k, _} -> "#{k} = ?" end)
    pk_values = Map.values(pk)

    query = """
    SELECT * FROM #{table}
    WHERE #{Enum.join(pk_clause, " AND ")}
    LIMIT 1
    """

    case repo.query(query, pk_values) do
      {:ok, %{rows: [row | _]}} ->
        {:ok, row}

      {:error, error} ->
        handle_scylla_result({:error, error})
    end
  end

  defp get_primary_key(changeset, resource) do
    Enum.reduce(Ash.Resource.Info.attributes(resource), %{}, fn attr, acc ->
      if attr.primary_key? do
        Map.put(acc, attr.name, Map.get(changeset.attributes, attr.name))
      else
        acc
      end
    end)
  end

  defp to_ash_record(record, resource) do
    resource
    |> Ash.Resource.Info.attributes()
    |> Enum.reduce(%{}, fn attr, acc ->
      value = Map.get(record, attr.name)
      Map.put(acc, attr.name, value)
    end)
  end

  # Build repo query options from resource configuration (keyspace, TTL, consistency).
  defp build_opts(resource) do
    keyspace = AshScylla.DataLayer.Dsl.keyspace(resource)
    ttl = AshScylla.DataLayer.Dsl.ttl(resource)
    consistency = AshScylla.DataLayer.Dsl.consistency(resource)

    []
    |> maybe_put(:prefix, keyspace)
    |> maybe_put(:ttl, ttl)
    |> maybe_put(:consistency, consistency)
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  # Normalize ScyllaDB/Xandra errors into AshScylla errors.
  defp handle_scylla_result({:ok, _} = ok), do: ok
  defp handle_scylla_result(:ok), do: :ok

  defp handle_scylla_result({:error, %Xandra.Error{} = error}) do
    {:error, AshScylla.Error.wrap_xandra_error(error)}
  end

  defp handle_scylla_result({:error, %Xandra.ConnectionError{} = error}) do
    {:error, AshScylla.Error.wrap_xandra_error(error)}
  end

  defp handle_scylla_result({:error, error}) do
    {:error, AshScylla.Error.wrap_xandra_error(error)}
  end
end
