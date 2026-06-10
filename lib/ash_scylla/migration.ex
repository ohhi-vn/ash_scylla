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

  These helpers return CQL strings that you execute via `Ecto.Migration.execute/1`
  in your migration modules, or directly through your repo at runtime.

  ## Example Migration

      defmodule MyApp.Repo.Migrations.CreateUsers do
        use Ecto.Migration

        def change do
          AshScylla.Migration.create_table_cql(MyApp.User)
          |> then(&execute/1)
        end
      end

  ## Important Note on `create_table_cql/1`

  This function reads compile-time module attributes set by the Ash resource DSL.
  For runtime use, prefer `Ash.Resource.Info.attributes/1` combined with
  `AshScylla.DataLayer.Dsl.table/1`.
  """

  @doc """
  Generates a CQL CREATE TABLE statement for an Ash resource.

  Returns a raw CQL string. Execute it in a migration via `Ecto.Migration.execute/1`
  or directly through your repo at runtime.
  """
  @spec create_table_cql(module()) :: String.t()
  def create_table_cql(resource) do
    table_name =
      resource
      |> Module.get_attribute(:table)
      |> to_string()
      |> case do
        "" ->
          resource
          |> Module.split()
          |> List.last()
          |> Macro.underscore()

        name ->
          name
      end

    attributes =
      resource
      |> Module.get_attribute(:attributes)
      |> Enum.map(&attribute_to_cql/1)

    primary_keys =
      resource
      |> Module.get_attribute(:attributes)
      |> Enum.filter(fn attr -> Keyword.get(attr, :primary_key) end)
      |> Enum.map_join(", ", fn attr -> Keyword.get(attr, :name) end)

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
        use Ecto.Migration

        def change do
          AshScylla.Migration.create_secondary_indexes_cql(MyApp.User)
          |> Enum.each(&execute/1)
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

  ## Example

      create_type "full_name" do
        field :first_name, :text
        field :last_name, :text
      end

  This generates:
      CREATE TYPE full_name (first_name TEXT, last_name TEXT)
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

  @doc """
  Drop a User Defined Type (UDT) in ScyllaDB.
  """
  @spec drop_type(String.t()) :: String.t()
  def drop_type(type_name) do
    "DROP TYPE IF EXISTS #{type_name}"
  end

  @spec attribute_to_cql(keyword()) :: String.t()
  defp attribute_to_cql(attr) do
    name = Keyword.get(attr, :name)
    type = Keyword.get(attr, :type, :string)
    opts = Keyword.get(attr, :type_opts, [])

    type_str = ash_type_to_cql_type(type, opts)

    primary_key = if Keyword.get(attr, :primary_key), do: " PRIMARY KEY", else: ""
    nullable = if Keyword.get(attr, :allow_nil, true), do: "", else: " NOT NULL"

    "#{name} #{type_str}#{primary_key}#{nullable}"
  end

  @type_mapping %{
    :uuid => "UUID",
    :string => "TEXT",
    :integer => "BIGINT",
    :boolean => "BOOLEAN",
    :utc_datetime => "TIMESTAMP",
    :date => "DATE",
    :time => "TIME"
  }

  @spec ash_type_to_cql_type(atom(), keyword()) :: String.t()
  defp ash_type_to_cql_type(type, opts) when is_atom(type) do
    base_type =
      case type do
        :map ->
          "MAP<#{Keyword.get(opts, :key_type, "TEXT")}, #{Keyword.get(opts, :value_type, "TEXT")}>"

        :array ->
          "LIST<#{Keyword.get(opts, :element_type, "TEXT")}>"

        :set ->
          "SET<#{Keyword.get(opts, :element_type, "TEXT")}>"

        :udt ->
          Keyword.get(opts, :type_name, "frozen<undefined>")

        mapped_type ->
          Map.get(@type_mapping, mapped_type, "TEXT")
      end

    if Keyword.get(opts, :frozen), do: "frozen<#{base_type}>", else: base_type
  end
end
