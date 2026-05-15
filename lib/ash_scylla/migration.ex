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

defmodule AshScylla.Migration do
  @moduledoc """
  Helpers for working with ScyllaDB migrations using Exandra.

  This module provides utilities to help generate CQL statements for ScyllaDB tables
  based on Ash resource definitions.

  Note: For actual migrations, use Exandra with Ecto.Migration directly.
  See the Exandra documentation for more details on writing migrations.

  ## Example Migration

      defmodule MyApp.Repo.Migrations.CreateUsers do
        use Ecto.Migration

        def change do
          execute "CREATE TABLE users (id UUID PRIMARY KEY, name TEXT, email TEXT)"
        end
      end
  """

  @doc """
  Generates a CQL CREATE TABLE statement for an Ash resource.

  Note: This is a helper that returns a CQL string.
  You need to execute this in an Ecto migration using `execute/1`.
  """
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
      |> Enum.map(fn attr -> Keyword.get(attr, :name) end)
      |> Enum.join(", ")

    clustering_order =
      if primary_keys != "" do
        "WITH CLUSTERING ORDER BY (#{primary_keys} DESC)"
      else
        ""
      end

    cql = """
    CREATE TABLE #{table_name} (
      #{Enum.join(attributes, ",\n  ")}
    ) #{clustering_order}
    """

    cql
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
  def create_secondary_indexes_cql(resource) do
    case AshScylla.DataLayer.Dsl.secondary_indexes(resource) do
      [] ->
        []

      indexes ->
        table_name = get_table_name(resource)

        indexes
        |> Enum.map(fn idx ->
          index_name = idx.name || generate_index_name(table_name, idx.columns)
          columns = idx.columns |> Enum.map(&to_string/1) |> Enum.join(", ")

          "CREATE INDEX IF NOT EXISTS #{index_name} ON #{table_name} (#{columns})"
        end)
    end
  end

  @doc """
  Generates a CQL DROP INDEX statement for a secondary index.
  """
  def drop_secondary_index_cql(_resource, index_name) do
    "DROP INDEX IF EXISTS #{index_name}"
  end

  defp get_table_name(resource) do
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
  end

  defp generate_index_name(table_name, columns) do
    column_str = columns |> Enum.map(&to_string/1) |> Enum.join("_")
    "idx_#{table_name}_#{column_str}"
  end

  @doc """
  Returns the keyspace for a resource if configured via DSL.
  Note: This is a placeholder for future DSL implementation.
  """
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
  def create_type(type_name, do: block) do
    fields =
      block
      |> Keyword.new()
      |> Enum.map(fn {name, {type, opts}} ->
        type_str = ash_type_to_cql_type(type, opts)
        "  #{name} #{type_str}"
      end)

    """
    CREATE TYPE IF NOT EXISTS #{type_name} (
    #{Enum.join(fields, ",\n")}
    )
    """
  end

  @doc """
  Drop a User Defined Type (UDt) in ScyllaDB.
  """
  def drop_type(type_name) do
    "DROP TYPE IF EXISTS #{type_name}"
  end

  defp attribute_to_cql(attr) do
    name = Keyword.get(attr, :name)
    type = Keyword.get(attr, :type, :string)
    opts = Keyword.get(attr, :type_opts, [])

    type_str = ash_type_to_cql_type(type, opts)

    primary_key = if Keyword.get(attr, :primary_key), do: " PRIMARY KEY", else: ""
    nullable = unless Keyword.get(attr, :allow_nil, true), do: " NOT NULL", else: ""

    "  #{name} #{type_str}#{primary_key}#{nullable}"
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

        type ->
          Map.get(@type_mapping, type, "TEXT")
      end

    if Keyword.get(opts, :frozen), do: "frozen<#{base_type}>", else: base_type
  end
end
