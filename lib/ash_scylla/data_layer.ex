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
  def can?(_resource_or_dsl, feature) do
    case feature do
      # Core CRUD operations
      :create ->
        true

      :read ->
        true

      :update ->
        true

      :destroy ->
        true

      # Query features
      :filter ->
        true

      :sort ->
        true

      :limit ->
        true

      :offset ->
        true

      :select ->
        true

      # Multitenancy (keyspace-based)
      :multitenancy ->
        true

      # Not supported features
      :transact ->
        false

      :bulk_create ->
        false

      :calculate ->
        false

      :combine ->
        false

      {:aggregate, _} ->
        false

      {:join, _} ->
        false

      {:lateral_join, _} ->
        false

      {:lock, _} ->
        false

      _ ->
        false
    end
  end

  @impl Ash.DataLayer
  def resource_to_query(resource, _domain) do
    %__MODULE__{
      resource: resource,
      repo: repo(resource),
      table: source(resource)
    }
  end

  @impl Ash.DataLayer
  def create(resource, changeset) do
    repo = repo(resource)

    changeset
    |> changeset_to_insert_attrs(resource)
    |> do_insert(resource, repo)
  end

  @impl Ash.DataLayer
  def update(resource, changeset) do
    repo = repo(resource)

    changeset
    |> changeset_to_update_attrs(resource)
    |> do_update(changeset, resource, repo)
  end

  @impl Ash.DataLayer
  def destroy(resource, changeset) do
    repo = repo(resource)

    do_delete(changeset, resource, repo)
  end

  @impl Ash.DataLayer
  def run_query(data_layer_query, resource) do
    %__MODULE__{repo: repo, table: _table, tenant: tenant} = data_layer_query

    # Build the optimized query with filters, sorts, limit, offset
    {query, params} = QueryBuilder.build_optimized_query(data_layer_query)

    opts = if tenant, do: [prefix: tenant], else: []

    case repo.query(query, params, opts) do
      {:ok, %{rows: rows}} ->
        records = Enum.map(rows, &to_ash_record(&1, resource))
        {:ok, records}

      {:error, %Xandra.Error{reason: reason}} ->
        {:error, "ScyllaDB query failed: #{inspect(reason)}"}

      {:error, %Xandra.ConnectionError{reason: reason}} ->
        {:error, "ScyllaDB connection error: #{inspect(reason)}"}

      {:error, error} ->
        {:error, "Database error: #{inspect(error)}"}
    end
  rescue
    e in Xandra.Error ->
      {:error, "ScyllaDB error: #{Exception.message(e)}"}

    e in Xandra.ConnectionError ->
      {:error, "ScyllaDB connection error: #{Exception.message(e)}"}

    e ->
      {:error, "Unexpected error: #{Exception.message(e)}"}
  end

  # ============================================================================
  # Optional Callbacks - Filter
  # ============================================================================

  @impl Ash.DataLayer
  def filter(data_layer_query, filter, _resource) do
    %__MODULE__{filters: filters} = data_layer_query

    {:ok, %{data_layer_query | filters: [filter | filters]}}
  end

  # ============================================================================
  # Optional Callbacks - Sort
  # ============================================================================

  @impl Ash.DataLayer
  def sort(data_layer_query, sort, _resource) do
    %__MODULE__{sorts: sorts} = data_layer_query

    {:ok, %{data_layer_query | sorts: sort ++ sorts}}
  end

  # ============================================================================
  # Optional Callbacks - Limit/Offset
  # ============================================================================

  @impl Ash.DataLayer
  def limit(data_layer_query, limit, _resource) do
    {:ok, %{data_layer_query | limit: limit}}
  end

  @impl Ash.DataLayer
  def offset(data_layer_query, offset, _resource) do
    {:ok, %{data_layer_query | offset: offset}}
  end

  # ============================================================================
  # Optional Callbacks - Select
  # ============================================================================

  @impl Ash.DataLayer
  def select(data_layer_query, select, _resource) do
    {:ok, %{data_layer_query | select: select}}
  end

  # ============================================================================
  # Optional Callbacks - Multitenancy
  # ============================================================================

  @impl Ash.DataLayer
  def set_tenant(data_layer_query, tenant, _resource) do
    {:ok, %{data_layer_query | tenant: tenant}}
  end

  # ============================================================================
  # Optional Callbacks - Source
  # ============================================================================

  @impl Ash.DataLayer
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
    resource
    |> Module.get_attribute(:repo)
    || raise "No repo configured for #{inspect(resource)}"
  rescue
    _ -> raise "No repo configured for #{inspect(resource)}"
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
    tenant = get_tenant(resource)

    opts = if tenant, do: [prefix: tenant], else: []

    # Build the CQL INSERT statement for ScyllaDB
    {fields, values} =
      attrs |> Enum.with_index() |> Enum.map(fn {{k, v}, i} -> {"#{k}", v, i} end) |> Enum.unzip()

    query = """
    INSERT INTO #{table} (#{Enum.join(fields, ", ")})
    VALUES (#{Enum.map(1..length(values), fn _ -> "?" end) |> Enum.join(", ")})
    """

    case repo.query(query, values, opts) do
      {:ok, _} ->
        # Fetch the created record
        case fetch_by_primary_key(attrs, resource, repo, tenant) do
          {:ok, record} -> {:ok, to_ash_record(record, resource)}
          error -> error
        end

      {:error, _} = error ->
        error
    end
  end

  defp do_update(attrs, changeset, resource, repo) do
    table = source(resource)
    tenant = get_tenant(resource)
    opts = if tenant, do: [prefix: tenant], else: []

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

    case repo.query(query, values ++ pk_values, opts) do
      {:ok, _} ->
        case fetch_by_primary_key(pk, resource, repo, tenant) do
          {:ok, record} -> {:ok, to_ash_record(record, resource)}
          error -> error
        end

      {:error, _} = error ->
        error
    end
  end

  defp do_delete(changeset, resource, repo) do
    table = source(resource)
    tenant = get_tenant(resource)
    opts = if tenant, do: [prefix: tenant], else: []

    pk = get_primary_key(changeset, resource)
    pk_clause = Enum.map(pk, fn {k, _} -> "#{k} = ?" end)
    pk_values = Map.values(pk)

    query = """
    DELETE FROM #{table}
    WHERE #{Enum.join(pk_clause, " AND ")}
    """

    case repo.query(query, pk_values, opts) do
      {:ok, _} -> :ok
      {:error, _} = error -> error
    end
  end

  defp fetch_by_primary_key(pk, resource, repo, _tenant) do
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

      {:error, _} = error ->
        error
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

  defp get_tenant(_resource) do
    # This should be configured per-resource or per-request
    nil
  end

  defp to_ash_record(record, resource) do
    # Convert the record (map or struct) to a format Ash expects
    # Ash expects a map with the attribute values
    attrs =
      Enum.reduce(Ash.Resource.Info.attributes(resource), %{}, fn attr, acc ->
        value = Map.get(record, attr.name) || Map.get(record, String.to_atom(attr.name))
        Map.put(acc, attr.name, value)
      end)

    attrs
  end
end
