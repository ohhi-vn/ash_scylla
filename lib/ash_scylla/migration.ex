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

defmodule AshScylla.Migration do
  alias AshScylla.DataLayer.Dsl

  @moduledoc """
  CQL schema generation helpers for ScyllaDB.

  This module generates raw CQL DDL statements (CREATE TABLE, CREATE INDEX,
  CREATE TYPE, etc.) from Ash resource definitions. It is NOT an Ecto SQL
  migration runner — CQL has no transactional DDL concept.

  These helpers return CQL strings that you execute via `AshScylla.Migrator.run/3`
  in your migration modules, or directly through your repo at runtime.

  ## Example Migration

      defmodule MyApp.Repo.Migrations.CreateUsers do
        def change do
          AshScylla.Migration.create_table_cql(MyApp.User)
          |> then(&AshScylla.Migrator.run!/3)
        end
      end

  ## Important Note on `create_table_cql/1`

  This function reads compile-time module attributes set by the Ash resource DSL.
  For runtime use, prefer `Ash.Resource.Info.attributes/1` combined with
  `AshScylla.DataLayer.Dsl.table/1`.

  ## Functions

  - `create_table_cql/1` — Generate `CREATE TABLE IF NOT EXISTS` CQL
  - `create_secondary_indexes_cql/1` — Generate `CREATE INDEX IF NOT EXISTS` CQL
  - `create_type/2` — Generate `CREATE TYPE IF NOT EXISTS` CQL
  - `drop_type/1` — Generate `DROP TYPE IF NOT EXISTS` CQL
  - `alter_type_cql/3` — Generate `ALTER TYPE` CQL (add/rename fields)
  - `quote_name/1` — Safely quote CQL identifiers
  - `ash_type_to_cql_type/2` — Convert Ash type to CQL type string
  """

  @doc """
  Generates a CQL CREATE TABLE statement for an Ash resource.

  Returns a raw CQL string. Execute it in a migration via `AshScylla.Migrator.run/3`
  or directly through your repo at runtime.
  """
  @spec create_table_cql(module()) :: String.t()
  def create_table_cql(resource) do
    create_table_cql(resource, [])
  end

  @spec create_table_cql(module(), keyword()) :: String.t()
  def create_table_cql(resource, _opts) do
    table_name = get_table_name(resource)
    keyspace = keyspace(resource)

    qualified_table_name =
      if keyspace,
        do: "#{quote_name(keyspace)}.#{quote_name(table_name)}",
        else: quote_name(table_name)

    all_attributes = Ash.Resource.Info.attributes(resource)

    # Separate primary key columns from regular columns
    {pk_attrs, regular_attrs} =
      Enum.split_with(all_attributes, fn attr -> attr.primary_key? end)

    # If no primary key found, default to :id as partition key
    {pk_attrs, regular_attrs} =
      if pk_attrs == [] do
        {id_attr, rest} =
          Enum.split_with(regular_attrs, fn attr -> attr.name == :id end)

        case id_attr do
          [id] -> {[id], rest}
          [] -> {[], regular_attrs}
        end
      else
        {pk_attrs, regular_attrs}
      end

    # Build column definitions for PK attributes (as regular column defs with types)
    pk_columns =
      pk_attrs
      |> Enum.map(&attribute_to_cql/1)

    # Build column definitions (without PRIMARY KEY inline)
    regular_columns =
      regular_attrs
      |> Enum.map(&attribute_to_cql/1)

    # Build PRIMARY KEY clause
    pk_clause = build_primary_key_clause(pk_attrs)

    # Combine all column definitions with PK clause
    all_definitions =
      if pk_clause == "" do
        pk_columns ++ regular_columns
      else
        pk_columns ++ regular_columns ++ [pk_clause]
      end

    # Build CLUSTERING ORDER BY clause
    clustering_order_clause = build_clustering_order_clause(pk_attrs)

    # Build the full CQL, handling empty clustering clause
    suffix =
      if clustering_order_clause == "" do
        ""
      else
        " #{clustering_order_clause}"
      end

    """
    CREATE TABLE IF NOT EXISTS #{qualified_table_name} (
      #{Enum.join(all_definitions, ",\n  ")}
    )#{suffix}
    """
  end

  # Build PRIMARY KEY clause from primary key attributes
  # Supports both simple and composite primary keys
  @spec build_primary_key_clause([Ash.Resource.Attribute.t()]) :: String.t()
  defp build_primary_key_clause([]), do: ""

  defp build_primary_key_clause(pk_attrs) do
    # Separate partition keys from clustering keys
    # In Ash, the first primary key is the partition key,
    # subsequent ones are clustering keys
    case pk_attrs do
      [single_pk] ->
        # Simple primary key - just one column
        "PRIMARY KEY (#{single_pk.name})"

      [partition_key | clustering_keys] ->
        # Composite primary key
        pk_cols =
          [partition_key.name | Enum.map(clustering_keys, & &1.name)]

        "PRIMARY KEY (#{Enum.join(pk_cols, ", ")})"
    end
  end

  # Build CLUSTERING ORDER BY clause for clustering keys
  @spec build_clustering_order_clause([Ash.Resource.Attribute.t()]) :: String.t()
  defp build_clustering_order_clause([]), do: ""
  defp build_clustering_order_clause([_single_pk]), do: ""

  defp build_clustering_order_clause([_partition_key | clustering_keys]) do
    order_str =
      clustering_keys
      |> Enum.map_join(", ", fn attr -> "#{attr.name} DESC" end)

    "WITH CLUSTERING ORDER BY (#{order_str})"
  end

  @doc """
  Generates CQL CREATE INDEX statements for secondary indexes.

  Returns a list of CQL strings that should be executed in migrations.

  ## Example

      defmodule MyApp.Repo.Migrations.CreateUserIndexes do
        def change do
          AshScylla.Migration.create_secondary_indexes_cql(MyApp.User)
          |> Enum.each(&AshScylla.Migrator.run!/3)
        end
      end
  """
  @spec create_secondary_indexes_cql(module()) :: [String.t()]
  def create_secondary_indexes_cql(resource) do
    case Dsl.secondary_indexes(resource) do
      [] ->
        []

      indexes ->
        table_name = get_table_name(resource)
        unindexable = unindexable_columns(resource)

        indexes
        |> Enum.flat_map(fn idx ->
          # ScyllaDB OSS doesn't support multi-column secondary indexes.
          # Generate a separate single-column index per column.
          # Skip the sole partition key column — already indexed by the partitioner.
          idx.columns
          |> Enum.reject(fn col -> col in unindexable end)
          |> Enum.map(fn col ->
            index_name =
              if idx.name do
                "#{idx.name}_#{col}"
              else
                "idx_#{table_name}_#{col}"
              end

            "CREATE INDEX IF NOT EXISTS #{index_name} ON #{quote_name(table_name)} (#{col})"
          end)
        end)
    end
  end

  @doc """
  Executes migration CQL via the Migrator.
  """
  @spec execute([String.t()], keyword()) :: {:ok, [term()]} | {:error, term()}
  def execute(statements, opts \\ []) do
    nodes = Keyword.get(opts, :nodes, ["127.0.0.1:9042"])
    AshScylla.Migrator.run(nodes, statements, opts)
  end

  @doc """
  Generates a CQL DROP INDEX statement for a secondary index.
  """
  @spec drop_secondary_index_cql(module(), String.t()) :: String.t()
  def drop_secondary_index_cql(_resource, index_name) do
    "DROP INDEX IF EXISTS #{index_name}"
  end

  @spec unindexable_columns(module()) :: [atom()]
  defp unindexable_columns(resource) do
    AshScylla.DataLayer.SchemaUtils.unindexable_columns(resource)
  end

  @spec get_table_name(module()) :: String.t()
  defp get_table_name(resource) do
    AshScylla.DataLayer.SchemaUtils.get_table_name(resource)
  end

  # Quotes an identifier for use in CQL, protecting reserved words.
  @spec quote_name(atom() | String.t()) :: String.t()
  def quote_name(name) when is_atom(name), do: quote_name(Atom.to_string(name))

  def quote_name(name) when is_binary(name) do
    if String.contains?(name, "\"") do
      # Escape embedded double quotes by doubling them (CQL standard)
      escaped = String.replace(name, "\"", "\"\"")
      "\"#{escaped}\""
    else
      "\"#{name}\""
    end
  end

  @doc """
  Returns the keyspace for a resource if configured via DSL.
  """
  @spec keyspace(module()) :: String.t() | nil
  def keyspace(resource) do
    AshScylla.DataLayer.Dsl.keyspace(resource)
  end

  @doc """
  Define a User Defined Type (UDT) in ScyllaDB.

  Supports two calling styles:

  ## Keyword-list style (with do block)

      create_type "full_name" do
        field :first_name, :text
        field :last_name, :text
      end

  ## Explicit field-list style

      create_type("address", city: :text, street: :text, zip: :text)

  Both generate:

      CREATE TYPE IF NOT EXISTS <name> (field1 TYPE1, field2 TYPE2)
  """
  @spec create_type(String.t(), keyword()) :: String.t()
  def create_type(type_name, do: block) do
    fields =
      block
      |> Keyword.new()
      |> Enum.map_join(",\n", fn {name, {type, opts}} ->
        type_str = ash_type_to_cql_type(type, opts)
        "  #{name} #{type_str}"
      end)

    """
    CREATE TYPE IF NOT EXISTS #{type_name} (
    #{fields}
    )
    """
  end

  @spec create_type(String.t() | atom(), [{atom(), atom()}]) :: String.t()
  def create_type(type_name, fields) when is_atom(type_name) do
    create_type(Atom.to_string(type_name), fields)
  end

  def create_type(type_name, fields) when is_binary(type_name) do
    fields_cql =
      fields
      |> Enum.map_join(", ", fn {name, type} ->
        "#{name} #{ash_type_to_cql_type(type, [])}"
      end)

    """
    CREATE TYPE IF NOT EXISTS #{type_name} (
      #{fields_cql}
    )
    """
  end

  @doc """
  Generates CQL for creating a UDT from a type name and field specs.

  Returns a raw CQL string.
  """
  @spec create_type_cql(String.t() | atom(), [{atom(), atom()}]) :: String.t()
  def create_type_cql(type_name, fields) do
    create_type(type_name, fields)
  end

  @doc """
  Drop a User Defined Type (UDT) in ScyllaDB.
  """
  @spec drop_type(String.t()) :: String.t()
  def drop_type(type_name) do
    "DROP TYPE IF EXISTS #{type_name}"
  end

  @doc """
  Generates CQL for dropping a UDT.

  Returns a raw CQL string.
  """
  @spec drop_type_cql(String.t() | atom()) :: String.t()
  def drop_type_cql(type_name) when is_atom(type_name) do
    drop_type_cql(Atom.to_string(type_name))
  end

  def drop_type_cql(type_name) when is_binary(type_name) do
    "DROP TYPE IF EXISTS #{type_name}"
  end

  @doc """
  Generates CQL for altering a UDT (add or rename fields).

  ## Examples

      alter_type_cql("address", :add, [country: :text])
      alter_type_cql("address", :rename, [new_zip: :zip_code])
  """
  @spec alter_type_cql(String.t() | atom(), :add | :rename, [{atom(), atom()}]) :: String.t()
  def alter_type_cql(type_name, action, fields) when is_atom(type_name) do
    alter_type_cql(Atom.to_string(type_name), action, fields)
  end

  def alter_type_cql(type_name, :add, fields) when is_binary(type_name) do
    alterations =
      fields
      |> Enum.map_join(", ", fn {name, type} ->
        "ADD #{name} #{AshScylla.DataLayer.Types.ash_type_to_cql_type(type, [])}"
      end)

    "ALTER TYPE #{type_name} #{alterations}"
  end

  def alter_type_cql(type_name, :rename, renames) when is_binary(type_name) do
    alterations =
      renames
      |> Enum.map_join(", ", fn {new_name, old_name} ->
        "RENAME #{old_name} TO #{new_name}"
      end)

    "ALTER TYPE #{type_name} #{alterations}"
  end

  @doc """
  Generates CQL to list all UDTs in the keyspace.

  Returns a raw CQL string.
  """
  @spec list_types_cql() :: String.t()
  def list_types_cql do
    "SELECT type_name, field_names, field_types FROM system_schema.types"
  end

  @doc """
  Generates CQL to check if a UDT exists.

  Returns a raw CQL string.
  """
  @spec type_exists_cql(String.t() | atom()) :: String.t()
  def type_exists_cql(type_name) when is_atom(type_name) do
    type_exists_cql(Atom.to_string(type_name))
  end

  def type_exists_cql(type_name) when is_binary(type_name) do
    sanitized = AshScylla.DataLayer.SchemaUtils.sanitize_type_name(type_name)
    "SELECT type_name FROM system_schema.types WHERE type_name = '#{sanitized}'"
  end

  defp attribute_to_cql(attr_or_keyword) do
    {name, type, opts, _allow_nil?} =
      case attr_or_keyword do
        %Ash.Resource.Attribute{} = attr ->
          {attr.name, attr.type, attr.constraints, attr.allow_nil?}

        attr when is_list(attr) ->
          {Keyword.get(attr, :name), Keyword.get(attr, :type, :string),
           Keyword.get(attr, :type_opts, []), Keyword.get(attr, :allow_nil, true)}
      end

    type_str = ash_type_to_cql_type(type, opts)

    "#{name} #{type_str}"
  end

  @doc """
  Converts an Ash type atom to its CQL type string representation.

  Delegates to `AshScylla.DataLayer.Types.ash_type_to_cql_type/2`.

  ## Examples

      iex> AshScylla.Migration.ash_type_to_cql_type(:uuid, [])
      "UUID"

      iex> AshScylla.Migration.ash_type_to_cql_type(:string, [])
      "TEXT"

      iex> AshScylla.Migration.ash_type_to_cql_type(:map, key_type: "TEXT", value_type: "INT")
      "MAP<TEXT, INT>"
  """
  @spec ash_type_to_cql_type(atom(), keyword()) :: String.t()
  def ash_type_to_cql_type(type, opts),
    do: AshScylla.DataLayer.Types.ash_type_to_cql_type(type, opts)
end
