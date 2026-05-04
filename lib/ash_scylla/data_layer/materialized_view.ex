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

defmodule AshScylla.DataLayer.MaterializedView do
  @moduledoc """
  Materialized view support for AshScylla.

  Materialized views in ScyllaDB/Cassandra allow you to define a view with a
  different primary key structure from the base table. This enables efficient
  queries on non-primary key columns without using secondary indexes.

  ## Usage

  Define a materialized view in your resource DSL:

      defmodule MyApp.MyResource do
        use Ash.Resource,
          data_layer: AshScylla.DataLayer

        ash_scylla do
          table "users"
          materialized_view :users_by_email,
            primary_key: [:email, :id],
            include_columns: [:name, :age]
        end
      end

  This will generate:

      CREATE MATERIALIZED VIEW IF NOT EXISTS users_by_email
      AS SELECT id, email, name, age
      FROM users
      WHERE email IS NOT NULL AND id IS NOT NULL
      PRIMARY KEY (email, id)
      WITH CLUSTERING ORDER BY (id ASC)
  """

  @type t :: %{
          name: atom(),
          primary_key: [atom()],
          clustering_order: keyword(),
          include_columns: [atom()],
          where_clause: String.t() | nil
        }

  @doc """
  Generates CQL for creating a materialized view.
  """
  def create_view_cql(view_name, base_table, view_config) do
    primary_key = Keyword.fetch!(view_config, :primary_key)
    include_columns = Keyword.get(view_config, :include_columns, [])
    clustering_order = Keyword.get(view_config, :clustering_order, [])
    where_clause = Keyword.get(view_config, :where_clause)

    # Build column list (primary key columns + included columns)
    all_columns = Enum.uniq(primary_key ++ include_columns)
    columns_str = Enum.join(all_columns, ", ")

    # Build WHERE clause for NOT NULL constraints
    not_null_clause =
      if where_clause do
        where_clause
      else
        primary_key
        |> Enum.map(&"#{&1} IS NOT NULL")
        |> Enum.join(" AND ")
      end

    # Build PRIMARY KEY definition
    pk_def =
      case primary_key do
        [partition_key] -> "(#{partition_key})"
        [partition_key | clustering_keys] -> "(#{partition_key}, #{Enum.join(clustering_keys, ", ")})"
      end

    # Build CLUSTERING ORDER if specified
    clustering_order_clause =
      if clustering_order != [] do
        order_str =
          clustering_order
          |> Enum.map(fn {col, dir} -> "#{col} #{dir}" end)
          |> Enum.join(", ")

        " WITH CLUSTERING ORDER BY (#{order_str})"
      else
        ""
      end

    """
    CREATE MATERIALIZED VIEW IF NOT EXISTS #{view_name}
    AS SELECT #{columns_str}
    FROM #{base_table}
    WHERE #{not_null_clause}
    PRIMARY KEY #{pk_def}#{clustering_order_clause}
    """
  end

  @doc """
  Generates CQL for dropping a materialized view.
  """
  def drop_view_cql(view_name) do
    "DROP MATERIALIZED VIEW IF EXISTS #{view_name}"
  end

  @doc """
  Validates a materialized view configuration.
  """
  def validate_view_config(view_config) do
    with {:ok, _} <- validate_primary_key(view_config),
         {:ok, _} <- validate_columns(view_config) do
      :ok
    end
  end

  defp validate_primary_key(view_config) do
    case Keyword.get(view_config, :primary_key) do
      nil -> {:error, "primary_key is required for materialized view"}
      [] -> {:error, "primary_key cannot be empty"}
      [_ | _] -> {:ok, :valid}
    end
  end

  defp validate_columns(view_config) do
    primary_key = Keyword.fetch!(view_config, :primary_key)
    include_columns = Keyword.get(view_config, :include_columns, [])

    # Check for duplicates
    all_columns = primary_key ++ include_columns
    unique_columns = Enum.uniq(all_columns)

    if length(all_columns) != length(unique_columns) do
      {:error, "duplicate columns in materialized view definition"}
    else
      {:ok, :valid}
    end
  end
end
