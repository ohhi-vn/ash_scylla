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
    table_name =
      case Dsl.table(resource) do
        nil ->
          resource
          |> Module.split()
          |> List.last()
          |> Macro.underscore()

        name ->
          to_string(name)
      end

    attributes =
      resource
      |> Ash.Resource.Info.attributes()
      |> Enum.map(&attribute_to_cql/1)

    primary_keys =
      resource
      |> Ash.Resource.Info.attributes()
      |> Enum.filter(fn attr -> attr.primary_key? end)
      |> Enum.map_join(", ", fn attr -> to_string(attr.name) end)

    clustering_order =
      if primary_keys != "" do
        "WITH CLUSTERING ORDER BY (#{primary_keys} DESC)"
      else
        ""
      end

    """
    CREATE TABLE #{table_name} (
      #{Enum.join(attributes, ",\n  ")}
    ) #{clustering_order}
    """
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

        indexes
        |> Enum.map(fn idx ->
          index_name = idx.name || generate_index_name(table_name, idx.columns)
          columns = idx.columns |> Enum.map_join(", ", &to_string/1)

          "CREATE INDEX IF NOT EXISTS #{index_name} ON #{table_name} (#{columns})"
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

  @spec get_table_name(module()) :: String.t()
  defp get_table_name(resource) do
    # Try DSL getter first (works at runtime), then fall back to compile-time attribute
    case Dsl.table(resource) do
      nil ->
        resource
        |> Module.split()
        |> List.last()
        |> Macro.underscore()

      name ->
        to_string(name)
    end
  end

  @spec generate_index_name(String.t(), [atom()]) :: String.t()
  defp generate_index_name(table_name, columns) do
    column_str = columns |> Enum.map_join("_", &to_string/1)
    "idx_#{table_name}_#{column_str}"
  end

  @doc """
  Returns the keyspace for a resource if configured via DSL.
  Note: This is a placeholder for future DSL implementation.
  """
  @spec keyspace(module()) :: String.t() | nil
  def keyspace(_resource) do
    nil
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
        "ADD #{name} #{ash_type_to_cql_type(type, [])}"
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
    "SELECT type_name FROM system_schema.types WHERE type_name = '#{type_name}'"
  end

  defp attribute_to_cql(attr_or_keyword) do
    {name, type, opts, primary_key?, allow_nil?} =
      case attr_or_keyword do
        %Ash.Resource.Attribute{} = attr ->
          {attr.name, attr.type, attr.constraints, attr.primary_key?, attr.allow_nil?}

        attr when is_list(attr) ->
          {Keyword.get(attr, :name), Keyword.get(attr, :type, :string),
           Keyword.get(attr, :type_opts, []), Keyword.get(attr, :primary_key, false),
           Keyword.get(attr, :allow_nil, true)}
      end

    type_str = ash_type_to_cql_type(type, opts)
    primary_key = if primary_key?, do: " PRIMARY KEY", else: ""
    nullable = if allow_nil?, do: "", else: " NOT NULL"

    "#{name} #{type_str}#{primary_key}#{nullable}"
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
