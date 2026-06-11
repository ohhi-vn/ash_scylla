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
          lwt true  # Enable lightweight transactions for atomic updates
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
  - `:lwt` - Enable Lightweight Transactions (LWT) for atomic upserts using `INSERT ... IF NOT EXISTS` (default: `false`)
  - `:secondary_index` - Define secondary indexes for non-primary key columns
  - `:materialized_view` - Define materialized views with different primary key structure
  - `:pagination` - Pagination mode: `:offset` (default) or `:token` for token-based pagination
  - `:per_action_consistency` - Per-action consistency overrides as a keyword list, e.g. `[read: :one, create: :quorum]`

  ## Features

  The data layer supports:
  - **Upsert** (`:upsert`) - Insert-or-update semantics with optional LWT
  - **Atomic updates** (`{:atomic, :update}`) - LWT-based conditional updates
  - **Atomic upserts** (`{:atomic, :upsert}`) - LWT-based insert-or-update
  - **Bulk update/destroy** - `update_query` and `destroy_query` for filtered operations
  - **Distinct** - On partition-key columns only
  - **Aggregates** - COUNT via `:count` aggregate
  - **Expression calculations** - In-memory post-processing
  - **Boolean filter** - With OR-to-IN rewriting
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

        pagination :token
        per_action_consistency read: :one, create: :quorum
      end
  """
  @spec ash_scylla(keyword()) :: Macro.t()
  defmacro ash_scylla(do: block) do
    # Transform DSL calls in the block into setter function calls.
    # `table "users"`       -> `__set_table__(__MODULE__, "users")`
    # `keyspace "my_ks"`    -> `__set_keyspace__(__MODULE__, "my_ks")`
    # etc.
    transformed =
      Macro.prewalk(block, fn
        {:table, meta, [value]} ->
          {{:., meta, [{:__aliases__, meta, [:AshScylla, :DataLayer, :Dsl]}, :__set_table__]},
           meta, [{:__MODULE__, [], nil}, value]}

        {:keyspace, meta, [value]} ->
          {{:., meta, [{:__aliases__, meta, [:AshScylla, :DataLayer, :Dsl]}, :__set_keyspace__]},
           meta, [{:__MODULE__, [], nil}, value]}

        {:consistency, meta, [value]} ->
          {{:., meta,
            [{:__aliases__, meta, [:AshScylla, :DataLayer, :Dsl]}, :__set_consistency__]}, meta,
           [{:__MODULE__, [], nil}, value]}

        {:ttl, meta, [value]} ->
          {{:., meta, [{:__aliases__, meta, [:AshScylla, :DataLayer, :Dsl]}, :__set_ttl__]}, meta,
           [{:__MODULE__, [], nil}, value]}

        {:secondary_index, meta, args} ->
          index_config =
            case args do
              [column] when is_atom(column) ->
                quote do: AshScylla.DataLayer.Dsl.parse_secondary_index(unquote(column))

              [columns] when is_list(columns) ->
                quote do: AshScylla.DataLayer.Dsl.parse_secondary_index(unquote(columns))

              [{column, opts}] when is_atom(column) ->
                quote do:
                        AshScylla.DataLayer.Dsl.parse_secondary_index(
                          {unquote(column), unquote(opts)}
                        )

              [column, opts] when is_atom(column) and is_list(opts) ->
                quote do:
                        AshScylla.DataLayer.Dsl.parse_secondary_index(
                          {unquote(column), unquote(opts)}
                        )
            end

          {{:., meta,
            [{:__aliases__, meta, [:AshScylla, :DataLayer, :Dsl]}, :__add_secondary_index__]},
           meta, [{:__MODULE__, [], nil}, index_config]}

        {:materialized_view, meta, [{view_name, view_config}]} when is_atom(view_name) ->
          view_map =
            quote do: %{
                    name: unquote(view_name),
                    config: unquote(view_config)
                  }

          {{:., meta,
            [{:__aliases__, meta, [:AshScylla, :DataLayer, :Dsl]}, :__add_materialized_view__]},
           meta, [{:__MODULE__, [], nil}, view_map]}

        {:materialized_view, _meta, [view_config]} when is_list(view_config) ->
          raise "materialized_view requires a name, e.g. materialized_view :view_name, primary_key: [...]"

        {:pagination, meta, [value]} ->
          {{:., meta,
            [{:__aliases__, meta, [:AshScylla, :DataLayer, :Dsl]}, :__set_pagination__]}, meta,
           [{:__MODULE__, [], nil}, value]}

        {:per_action_consistency, meta, [value]} ->
          {{:., meta,
            [
              {:__aliases__, meta, [:AshScylla, :DataLayer, :Dsl]},
              :__set_per_action_consistency__
            ]}, meta, [{:__MODULE__, [], nil}, value]}

        {:lwt, meta, [value]} ->
          {{:., meta, [{:__aliases__, meta, [:AshScylla, :DataLayer, :Dsl]}, :__set_lwt__]}, meta,
           [{:__MODULE__, [], nil}, value]}

        {:repo, meta, [value]} ->
          {{:., meta, [{:__aliases__, meta, [:AshScylla, :DataLayer, :Dsl]}, :__set_repo__]},
           meta, [{:__MODULE__, [], nil}, value]}

        other ->
          other
      end)

    quote do
      @ash_scylla_table nil
      @ash_scylla_keyspace nil
      @ash_scylla_consistency nil
      @ash_scylla_ttl nil
      @ash_scylla_secondary_indexes []
      @ash_scylla_materialized_views []
      @ash_scylla_pagination :offset
      @ash_scylla_per_action_consistency %{}
      @ash_scylla_lwt false
      @ash_scylla_repo nil

      unquote(transformed)

      # Generate getter functions at compile time
      @doc false
      def __ash_scylla__(:table), do: @ash_scylla_table

      @doc false
      def __ash_scylla__(:keyspace), do: @ash_scylla_keyspace

      @doc false
      def __ash_scylla__(:consistency), do: @ash_scylla_consistency

      @doc false
      def __ash_scylla__(:ttl), do: @ash_scylla_ttl

      @doc false
      def __ash_scylla__(:secondary_indexes) do
        @ash_scylla_secondary_indexes
      end

      @doc false
      def __ash_scylla__(:materialized_views) do
        @ash_scylla_materialized_views
      end

      @doc false
      def __ash_scylla__(:pagination), do: @ash_scylla_pagination

      @doc false
      def __ash_scylla__(:per_action_consistency), do: @ash_scylla_per_action_consistency

      @doc false
      def __ash_scylla__(:lwt), do: @ash_scylla_lwt

      @doc false
      def __ash_scylla__(:repo), do: @ash_scylla_repo

      @doc false
      def __ash_scylla__(_opt), do: nil
    end
  end

  @doc false
  @spec parse_secondary_index(atom() | list() | {atom(), keyword()}) :: map()
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
  @spec table(module()) :: String.t() | nil
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
  @spec keyspace(module()) :: String.t() | nil
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
  @spec consistency(module()) :: atom() | nil
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
  @spec ttl(module()) :: pos_integer() | nil
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
  @spec secondary_indexes(module()) :: [map()]
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
  @spec materialized_views(module()) :: [map()]
  def materialized_views(resource) do
    if function_exported?(resource, :__ash_scylla__, 1) do
      resource.__ash_scylla__(:materialized_views)
    else
      []
    end
  end

  @doc """
  Gets the pagination mode for a resource.

  Returns `:offset` or `:token`.
  """
  @spec pagination(module()) :: :offset | :token
  def pagination(resource) do
    if function_exported?(resource, :__ash_scylla__, 1) do
      resource.__ash_scylla__(:pagination)
    else
      :offset
    end
  end

  @doc """
  Gets the per-action consistency configuration for a resource.

  Returns a map of action_name => consistency_level.
  """
  @spec per_action_consistency(module()) :: map()
  def per_action_consistency(resource) do
    if function_exported?(resource, :__ash_scylla__, 1) do
      resource.__ash_scylla__(:per_action_consistency)
    else
      %{}
    end
  end

  @doc """
  Checks if a column has a secondary index defined.
  """
  @spec has_secondary_index?(module(), atom()) :: boolean()
  def has_secondary_index?(resource, column) do
    indexes = secondary_indexes(resource)
    Enum.any?(indexes, fn idx -> column in idx.columns end)
  end

  # ============================================================================
  # DSL setter functions — called by the DSL body at compile time
  # ============================================================================

  @doc false
  @spec __set_table__(module(), String.t()) :: :ok
  def __set_table__(module, value) do
    Module.put_attribute(module, :ash_scylla_table, value)
  end

  @doc false
  @spec __set_keyspace__(module(), String.t()) :: :ok
  def __set_keyspace__(module, value) do
    Module.put_attribute(module, :ash_scylla_keyspace, value)
  end

  @doc false
  @spec __set_consistency__(module(), atom()) :: :ok
  def __set_consistency__(module, value) do
    Module.put_attribute(module, :ash_scylla_consistency, value)
  end

  @doc false
  @spec __set_ttl__(module(), pos_integer()) :: :ok
  def __set_ttl__(module, value) do
    Module.put_attribute(module, :ash_scylla_ttl, value)
  end

  @doc false
  @spec __add_secondary_index__(module(), map()) :: :ok
  def __add_secondary_index__(module, index_config) do
    current = Module.get_attribute(module, :ash_scylla_secondary_indexes)
    Module.put_attribute(module, :ash_scylla_secondary_indexes, [index_config | current])
  end

  @doc false
  @spec __add_materialized_view__(module(), map()) :: :ok
  def __add_materialized_view__(module, view_config) do
    current = Module.get_attribute(module, :ash_scylla_materialized_views)
    Module.put_attribute(module, :ash_scylla_materialized_views, [view_config | current])
  end

  @doc false
  @spec __set_pagination__(module(), :offset | :token) :: :ok
  def __set_pagination__(module, value) when value in [:offset, :token] do
    Module.put_attribute(module, :ash_scylla_pagination, value)
  end

  @spec __set_pagination__(module(), :offset | :token) :: :ok
  def __set_pagination__(_module, value) do
    raise ArgumentError, "Invalid pagination mode: #{inspect(value)}. Must be :offset or :token"
  end

  @doc false
  @spec __set_per_action_consistency__(module(), keyword()) :: :ok
  def __set_per_action_consistency__(module, action_consistency)
      when is_list(action_consistency) do
    map = Map.new(action_consistency)
    Module.put_attribute(module, :ash_scylla_per_action_consistency, map)
  end

  @doc false
  @spec __set_lwt__(module(), boolean()) :: :ok
  def __set_lwt__(module, value) when is_boolean(value) do
    Module.put_attribute(module, :ash_scylla_lwt, value)
  end

  @spec lwt(module()) :: boolean()
  def lwt(resource) do
    if function_exported?(resource, :__ash_scylla__, 1) do
      resource.__ash_scylla__(:lwt)
    else
      false
    end
  end

  @doc """
  Gets the configured repo for a resource.
  """
  @spec repo(module()) :: module() | nil
  def repo(resource) do
    if function_exported?(resource, :__ash_scylla__, 1) do
      resource.__ash_scylla__(:repo)
    else
      nil
    end
  end

  @doc false
  @spec __set_repo__(module(), module()) :: :ok
  def __set_repo__(module, value) do
    Module.put_attribute(module, :ash_scylla_repo, value)
  end
end
