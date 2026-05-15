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

defmodule AshScylla.DataLayer.Dsl do
  @moduledoc """
  DSL extensions for configuring ScyllaDB-specific options on Ash resources.

  ## Usage

      defmodule MyApp.MyResource do
        use Ash.Resource,
          data_layer: AshScylla.DataLayer

        ash_scylla do
          table "my_table"
          keyspace "my_keyspace"
          consistency :quorum
          ttl 3600

          # Define secondary indexes for non-primary key columns
          secondary_index :email
          secondary_index [:name, :age]
          secondary_index :status, name: "idx_user_status"
        end

        attributes do
          uuid_primary_key :id
          attribute :name, :string
          attribute :email, :string
          attribute :status, :string
          attribute :age, :integer
        end
      end

  ## Options

  - `:table` - The table name in ScyllaDB (overrides default)
  - `:keyspace` - The keyspace to use (overrides repo default)
  - `:consistency` - The consistency level for reads/writes
  - `:ttl` - Default TTL for inserted records (in seconds)
  - `:secondary_index` - Define secondary indexes for non-primary key columns
  - `:materialized_view` - Define materialized views with different primary key structure
  """

  @doc """
  Macro for configuring ScyllaDB options in Ash resources.

  ## Examples

      ash_scylla do
        table "users"
        keyspace "my_keyspace"
        consistency :quorum
        ttl 3600

        # Define secondary indexes for non-primary key columns
        secondary_index :email
        secondary_index [:name, :age]

        # Define materialized views
        materialized_view :users_by_email,
          primary_key: [:email, :id],
          include_columns: [:name, :age]
      end
  """
  defmacro ash_scylla(do: block) do
    quote do
      @ash_scylla_secondary_indexes []
      @ash_scylla_materialized_views []

      unquote(block)
      |> Keyword.new()
      |> Enum.each(fn
        {:table, val} ->
          @ash_scylla_table val

        {:keyspace, val} ->
          @ash_scylla_keyspace val

        {:consistency, val} ->
          @ash_scylla_consistency val

        {:ttl, val} ->
          @ash_scylla_ttl val

        {:secondary_index, index_config} ->
          parsed = AshScylla.DataLayer.Dsl.parse_secondary_index(index_config)
          @ash_scylla_secondary_indexes [parsed | @ash_scylla_secondary_indexes]

        {:materialized_view, {view_name, view_config}} when is_atom(view_name) ->
          @ash_scylla_materialized_views [
            %{name: view_name, config: view_config}
            | @ash_scylla_materialized_views
          ]

        {:materialized_view, view_config} when is_list(view_config) ->
          raise "materialized_view requires a name, e.g. materialized_view :view_name, primary_key: [...]"

        other ->
          raise "Unknown ash_scylla option: #{inspect(other)}"
      end)

      # Generate getter functions at compile time
      def __ash_scylla__(:table), do: Module.get_attribute(__MODULE__, :ash_scylla_table)
      def __ash_scylla__(:keyspace), do: Module.get_attribute(__MODULE__, :ash_scylla_keyspace)

      def __ash_scylla__(:consistency),
        do: Module.get_attribute(__MODULE__, :ash_scylla_consistency)

      def __ash_scylla__(:ttl), do: Module.get_attribute(__MODULE__, :ash_scylla_ttl)

      def __ash_scylla__(:secondary_indexes) do
        Module.get_attribute(__MODULE__, :ash_scylla_secondary_indexes) || []
      end

      def __ash_scylla__(:materialized_views) do
        Module.get_attribute(__MODULE__, :ash_scylla_materialized_views) || []
      end

      def __ash_scylla__(_opt), do: nil
    end
  end

  @doc false
  def parse_secondary_index(column) when is_atom(column) do
    %{columns: [column], name: nil, options: []}
  end

  def parse_secondary_index(columns) when is_list(columns) do
    %{columns: columns, name: nil, options: []}
  end

  def parse_secondary_index({column, opts}) when is_atom(column) do
    %{columns: [column], name: opts[:name], options: opts}
  end

  def parse_secondary_index(invalid) do
    raise "Invalid secondary_index configuration: #{inspect(invalid)}"
  end

  @doc """
  Gets the configured table name for a resource.
  """
  def table(resource) do
    if function_exported?(resource, :__ash_scylla__, 1) do
      resource.__ash_scylla__(:table)
    else
      nil
    end
  end

  @doc """
  Gets the configured keyspace for a resource.
  """
  def keyspace(resource) do
    if function_exported?(resource, :__ash_scylla__, 1) do
      resource.__ash_scylla__(:keyspace)
    else
      nil
    end
  end

  @doc """
  Gets the configured consistency level for a resource.
  """
  def consistency(resource) do
    if function_exported?(resource, :__ash_scylla__, 1) do
      resource.__ash_scylla__(:consistency)
    else
      nil
    end
  end

  @doc """
  Gets the configured TTL for a resource.
  """
  def ttl(resource) do
    if function_exported?(resource, :__ash_scylla__, 1) do
      resource.__ash_scylla__(:ttl)
    else
      nil
    end
  end

  @doc """
  Gets the secondary indexes defined for a resource.

  Returns a list of maps with keys:
  - `:columns` - list of column names (atoms)
  - `:name` - optional custom index name
  - `:options` - additional options
  """
  def secondary_indexes(resource) do
    if function_exported?(resource, :__ash_scylla__, 1) do
      resource.__ash_scylla__(:secondary_indexes)
    else
      []
    end
  end

  @doc """
  Gets the materialized views defined for a resource.

  Returns a list of maps with keys:
  - `:name` - the view name (atom)
  - `:config` - the view configuration keyword list
  """
  def materialized_views(resource) do
    if function_exported?(resource, :__ash_scylla__, 1) do
      resource.__ash_scylla__(:materialized_views)
    else
      []
    end
  end

  @doc """
  Checks if a column has a secondary index defined.
  """
  def has_secondary_index?(resource, column) do
    indexes = secondary_indexes(resource)
    Enum.any?(indexes, fn idx -> column in idx.columns end)
  end
end
