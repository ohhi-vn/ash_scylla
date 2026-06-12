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

defmodule AshScylla.DataLayer.SchemaMigration do
  @moduledoc """
  Automatic schema migration support for AshScylla.

  Compares Ash resource definitions against the live ScyllaDB schema
  and generates the necessary DDL statements to bring the schema in sync.

  Since CQL has no transactional DDL, each statement is executed independently.

  ## Usage

      # Generate migration DDL for a resource
      statements = AshScylla.DataLayer.SchemaMigration.generate(MyApp.User)

      # Execute the migration
      AshScylla.Migrator.run(nodes, statements)

      # Or use the convenience function
      AshScylla.DataLayer.SchemaMigration.migrate(MyApp.User, repo)

      # Check what would change without executing
      AshScylla.DataLayer.SchemaMigration.plan(MyApp.User, repo)
  """

  require Logger

  alias AshScylla.DataLayer.Dsl
  alias AshScylla.DataLayer.MaterializedView
  alias AshScylla.Migration
  alias AshScylla.Migrator

  @doc """
  Generates all DDL statements needed to bring a resource's schema in sync.

  Returns a list of CQL statement strings. This includes:
  - CREATE TABLE IF NOT EXISTS
  - ALTER TABLE ADD for new columns
  - CREATE INDEX IF NOT EXISTS for new secondary indexes
  - CREATE MATERIALIZED VIEW IF NOT EXISTS for new views
  - CREATE TYPE IF NOT EXISTS for UDTs
  """
  @spec generate(module()) :: [String.t()]
  def generate(resource) do
    table_cql = [Migration.create_table_cql(resource)]
    index_cql = Migration.create_secondary_indexes_cql(resource)
    view_cql = generate_views(resource)

    table_cql ++ index_cql ++ view_cql
  end

  @doc """
  Generates DDL statements by comparing resource against live schema.

  Only returns statements for actual changes needed.
  """
  @spec diff(module(), module()) :: [String.t()]
  def diff(resource, repo) do
    with {:ok, live_schema} <- fetch_table_schema(resource, repo),
         {:ok, live_indexes} <- fetch_indexes(resource, repo),
         {:ok, live_views} <- fetch_materialized_views(resource, repo) do
      attributes = Ash.Resource.Info.attributes(resource)
      live_columns = Map.get(live_schema, :columns, [])

      column_diff = diff_columns(attributes, live_columns)

      add_column_cql =
        if column_diff.add != [] do
          generate_add_columns(resource, column_diff.add)
        else
          []
        end

      new_index_cql = generate_new_indexes(resource, live_indexes)
      new_view_cql = generate_new_views(resource, live_views)

      # If table doesn't exist yet, generate full DDL
      if live_columns == [] do
        generate(resource)
      else
        add_column_cql ++ new_index_cql ++ new_view_cql
      end
    else
      {:error, reason} ->
        Logger.error("Failed to diff schema for #{inspect(resource)}: #{inspect(reason)}")
        []
    end
  end

  @doc """
  Executes all migration DDL for a resource against a repo.

  Options:
  - `:nodes` - Override nodes (defaults to repo nodes)
  - `:keyspace` - Override keyspace (defaults to repo keyspace)
  - `:dry_run` - If true, only log statements without executing
  """
  @spec migrate(module(), module(), keyword()) :: {:ok, [term()]} | {:error, term()}
  def migrate(resource, repo, opts \\ []) do
    dry_run = Keyword.get(opts, :dry_run, false)
    statements = diff(resource, repo)

    if statements == [] do
      Logger.info("No schema changes needed for #{inspect(resource)}")
      {:ok, []}
    else
      if dry_run do
        Logger.info("Dry run - would execute the following statements:")
        Enum.each(statements, &Logger.info/1)
        {:ok, statements}
      else
        nodes = Keyword.get(opts, :nodes, repo.nodes())
        Migrator.run(nodes, statements, opts)
      end
    end
  end

  @doc """
  Returns a list of DDL statements that would be executed without running them.
  """
  @spec plan(module(), module()) :: {:ok, [String.t()]} | {:error, term()}
  def plan(resource, repo) do
    statements = diff(resource, repo)
    {:ok, statements}
  end

  @doc """
  Fetches the current table schema from ScyllaDB.

  Returns a map with column definitions.
  """
  @spec fetch_table_schema(module(), module()) :: {:ok, map()} | {:error, term()}
  def fetch_table_schema(resource, repo) do
    keyspace = repo.keyspace()
    table_name = get_table_name(resource)

    query = """
    SELECT * FROM system_schema.columns
    WHERE keyspace_name = ? AND table_name = ?
    """

    case repo.query(query, [keyspace, table_name], consistency: :quorum) do
      {:ok, result} ->
        columns =
          result
          |> Map.get(:rows, [])
          |> Enum.map(fn row ->
            %{
              name: row["column_name"],
              type: row["type"],
              kind: row["kind"],
              position: row["position"],
              clustering_order: row["clustering_order"]
            }
          end)

        {:ok, %{columns: columns, keyspace: keyspace, table: table_name}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Fetches existing indexes for a table.
  """
  @spec fetch_indexes(module(), module()) :: {:ok, [map()]} | {:error, term()}
  def fetch_indexes(resource, repo) do
    keyspace = repo.keyspace()
    table_name = get_table_name(resource)

    query = """
    SELECT * FROM system_schema.indexes
    WHERE keyspace_name = ? AND table_name = ?
    """

    case repo.query(query, [keyspace, table_name], consistency: :quorum) do
      {:ok, result} ->
        indexes =
          result
          |> Map.get(:rows, [])
          |> Enum.map(fn row ->
            %{
              index_name: row["index_name"],
              kind: row["kind"],
              options: row["options"]
            }
          end)

        {:ok, indexes}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Fetches existing materialized views for a table.
  """
  @spec fetch_materialized_views(module(), module()) :: {:ok, [map()]} | {:error, term()}
  def fetch_materialized_views(resource, repo) do
    keyspace = repo.keyspace()
    table_name = get_table_name(resource)

    query = """
    SELECT * FROM system_schema.views
    WHERE keyspace_name = ? AND base_table_name = ?
    """

    case repo.query(query, [keyspace, table_name], consistency: :quorum) do
      {:ok, result} ->
        views =
          result
          |> Map.get(:rows, [])
          |> Enum.map(fn row ->
            %{
              view_name: row["view_name"],
              base_table_name: row["base_table_name"],
              where_clause: row["where_clause"],
              include_all_columns: row["include_all_columns"],
              columns: row["columns"]
            }
          end)

        {:ok, views}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Compares resource attributes against live columns and returns
  lists of columns to add, type-change, etc.
  """
  @spec diff_columns([Ash.Resource.Attribute.t()], [map()]) :: %{
          add: [atom()],
          remove: [atom()],
          change_type: [atom()]
        }
  def diff_columns(attributes, live_columns) do
    resource_column_names =
      attributes
      |> Enum.map(fn attr -> to_string(attr.name) end)
      |> MapSet.new()

    live_column_names =
      live_columns
      |> Enum.map(fn col -> col.name end)
      |> MapSet.new()

    add =
      resource_column_names
      |> MapSet.difference(live_column_names)
      |> MapSet.to_list()
      |> Enum.map(&String.to_atom/1)

    remove =
      live_column_names
      |> MapSet.difference(resource_column_names)
      |> MapSet.to_list()
      |> Enum.map(&String.to_atom/1)

    # ScyllaDB does not support ALTER COLUMN TYPE, so we just note them
    change_type = []

    %{add: add, remove: remove, change_type: change_type}
  end

  @doc """
  Generates ALTER TABLE ADD statements for new columns.
  """
  @spec generate_add_columns(module(), [atom()]) :: [String.t()]
  def generate_add_columns(resource, columns) do
    table_name = get_table_name(resource)

    attributes =
      resource
      |> Ash.Resource.Info.attributes()
      |> Enum.reduce(%{}, fn attr, acc ->
        Map.put(acc, attr.name, attr)
      end)

    columns
    |> Enum.map(fn col_name ->
      case Map.get(attributes, col_name) do
        nil ->
          Logger.warning("Column #{col_name} not found in resource attributes")
          nil

        attr ->
          type_str = attr.type |> Migration.ash_type_to_cql_type(attr.constraints)
          "ALTER TABLE #{table_name} ADD #{col_name} #{type_str}"
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  @doc """
  Generates CREATE INDEX statements for new secondary indexes.
  """
  @spec generate_new_indexes(module(), [map()]) :: [String.t()]
  def generate_new_indexes(resource, live_indexes) do
    table_name = get_table_name(resource)
    resource_indexes = Dsl.secondary_indexes(resource)

    existing_index_names =
      live_indexes
      |> Enum.map(fn idx -> idx.index_name end)
      |> MapSet.new()

    resource_indexes
    |> Enum.filter(fn idx ->
      index_name = idx.name || generate_index_name(table_name, idx.columns)
      not MapSet.member?(existing_index_names, index_name)
    end)
    |> Enum.map(fn idx ->
      index_name = idx.name || generate_index_name(table_name, idx.columns)
      columns = idx.columns |> Enum.map_join(", ", &to_string/1)
      "CREATE INDEX IF NOT EXISTS #{index_name} ON #{table_name} (#{columns})"
    end)
  end

  @doc """
  Generates CREATE MATERIALIZED VIEW statements for new views.
  """
  @spec generate_new_views(module(), [map()]) :: [String.t()]
  def generate_new_views(resource, live_views) do
    table_name = get_table_name(resource)
    resource_views = Dsl.materialized_views(resource)

    existing_view_names =
      live_views
      |> Enum.map(fn v -> v.view_name end)
      |> MapSet.new()

    resource_views
    |> Enum.filter(fn view_config ->
      view_name = view_config[:name]
      not MapSet.member?(existing_view_names, to_string(view_name))
    end)
    |> Enum.map(fn view_config ->
      view_name = view_config[:name]
      config = view_config[:config] || []
      MaterializedView.create_view_cql(view_name, table_name, config)
    end)
  end

  @spec get_table_name(module()) :: String.t()
  defp get_table_name(resource) do
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

  @spec generate_views(module()) :: [String.t()]
  defp generate_views(resource) do
    table_name = get_table_name(resource)
    views = Dsl.materialized_views(resource)

    views
    |> Enum.map(fn view_config ->
      view_name = view_config[:name]
      config = view_config[:config] || []
      MaterializedView.create_view_cql(view_name, table_name, config)
    end)
  end
end
