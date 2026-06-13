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

  Supports Ash Framework 3.0+ features including base_filter, identities,
  aggregates, calculations, preparations, changes, validations, pipelines,
  multitenancy, code_interface, and extended action options.

  ## Usage

      defmodule MyApp.MyResource do
        use Ash.Resource,
          data_layer: AshScylla.DataLayer

        ash_scylla do
          table "my_table"
          keyspace "my_keyspace"
          consistency :quorum
          ttl 3600
          lwt true

          base_filter [status: "active"]
          default_context %{tenant: "org_123"}
          description "My resource description"

          secondary_index :email
          secondary_index [:name, :age]
          secondary_index :status, name: "idx_user_status"

          materialized_view :users_by_email,
            primary_key: [:email, :id],
            include_columns: [:name, :age]

          pagination :token
          per_action_consistency read: :one, create: :quorum
        end

        attributes do
          uuid_primary_key :id
          uuid_v7_primary_key :vid
          integer_primary_key :seq_id
          create_timestamp :inserted_at
          update_timestamp :updated_at
          attribute :name, :string, public?: true, writable?: true
          attribute :email, :string, sensitive?: false
          attribute :status, :string
          attribute :age, :integer
        end

        identities do
          identity :unique_email, [:email]
        end

        aggregates do
          count :total_count
          count :active_count, filter: [status: "active"]
        end

        calculations do
          calculate :display_name, :string, expr(name)
        end

        preparations do
          prepare build(:load, [:email])
        end

        changes do
          change fn changeset, _context -> changeset end
        end

        validations do
          validate attribute_equals(:status, "active")
        end

        pipelines do
          pipe_through :read
        end

        multitenancy do
          strategy :attribute
          attribute :org_id
        end

        code_interface do
          define :create_user
          define_calculation :active_count
        end

        relationships do
          belongs_to :organization, MyApp.Organization
          has_one :profile, MyApp.Profile
          has_many :posts, MyApp.Post
          many_to_many :tags, MyApp.Tag
        end

        actions do
          create :create do
            accept [:name, :email, :status]
            argument :organization_id, :uuid
            change fn changeset, _context -> changeset end
            validate present([:name])
          end

          read :read do
            prepare build(:load, [:email])
            pagination offset?: true, max_page_size: 100
            metadata :total_count, :integer
            filter [status: "active"]
          end

          update :update do
            accept [:name, :status]
            change fn changeset, _context -> changeset end
            validate present([:name])
          end

          destroy :destroy do
            soft? true
            change fn changeset, _context -> changeset end
          end
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
  - `:base_filter` - A filter expression applied to all queries on this resource (Ash 3.0)
  - `:default_context` - Default context map merged into every query/changeset (Ash 3.0)
  - `:description` - Human-readable description of the resource (Ash 3.0)
  - `:identity` - Define unique identity constraints for upsert operations
  - `:aggregate` - Define aggregate queries (count, sum, avg, min, max)
  - `:calculation` - Define expression-based calculations
  - `:preparation` - Define query preparations
  - `:change` - Define changes applied to changesets
  - `:validation` - Define attribute validations
  - `:pipeline` - Define action pipelines via pipe_through
  - `:multitenancy` - Configure multitenancy strategy (:context or :attribute)
  - `:code_interface` - Define code interface functions
  - `:relationship` - Define relationships (belongs_to, has_one, has_many, many_to_many)
  - `:action` - Define actions with extended options (accept, argument, change, validate, prepare, pagination, metadata, filter, soft?)

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
  - **Base filter** - Automatic filter applied to all queries (Ash 3.0)
  - **Default context** - Context merged into all queries (Ash 3.0)
  - **Identities** - Unique constraints for upsert operations (Ash 3.0)
  - **Multitenancy** - Context-based and attribute-based strategies (Ash 3.0)
  """

  @doc """
  Macro for configuring ScyllaDB options in Ash resources.

  ## Examples

      ash_scylla do
        table "users"
        keyspace "my_keyspace"
        consistency :quorum
        ttl 3600

        base_filter [status: "active"]
        default_context %{tenant: "org_123"}
        description "User accounts"

        secondary_index :email
        secondary_index [:name, :age]

        materialized_view :users_by_email,
          primary_key: [:email, :id],
          include_columns: [:name, :age]

        pagination :token
        per_action_consistency read: :one, create: :quorum

        identity :unique_email, [:email]

        aggregate :count, :total_users
        aggregate :count, :active_users, filter: [status: "active"]

        calculation :display_name, :string, expr(name)

        preparation build(:load, [:email])

        change fn changeset, _context -> changeset end

        validation present([:name])

        pipeline :read

        multitenancy do
          strategy :attribute
          attribute :org_id
        end

        code_interface do
          define :create_user
          define_calculation :active_users
        end

        relationship :belongs_to, :organization, MyApp.Organization
        relationship :has_one, :profile, MyApp.Profile
        relationship :has_many, :posts, MyApp.Post
        relationship :many_to_many, :tags, MyApp.Tag

        action :create, :create_user do
          accept [:name, :email]
          argument :organization_id, :uuid
          change fn changeset, _context -> changeset end
          validate present([:name])
        end

        action :read, :list_users do
          pagination offset?: true, max_page_size: 100
          metadata :total_count, :integer
          filter [status: "active"]
        end

        action :update, :update_user do
          accept [:name, :status]
          change fn changeset, _context -> changeset end
        end

        action :destroy, :delete_user do
          soft? true
        end
      end
  """
  @spec ash_scylla(keyword()) :: Macro.t()
  defmacro ash_scylla(do: block) do
    transformed =
      Macro.prewalk(block, fn
        # ── Existing ScyllaDB options ──

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

        # ── Ash 3.0+ resource-level options ──

        {:base_filter, meta, [value]} ->
          {{:., meta,
            [{:__aliases__, meta, [:AshScylla, :DataLayer, :Dsl]}, :__set_base_filter__]}, meta,
           [{:__MODULE__, [], nil}, value]}

        {:default_context, meta, [value]} ->
          {{:., meta,
            [{:__aliases__, meta, [:AshScylla, :DataLayer, :Dsl]}, :__set_default_context__]},
           meta, [{:__MODULE__, [], nil}, value]}

        {:description, meta, [value]} ->
          {{:., meta,
            [{:__aliases__, meta, [:AshScylla, :DataLayer, :Dsl]}, :__set_description__]}, meta,
           [{:__MODULE__, [], nil}, value]}

        # ── Identity DSL ──

        {:identity, meta, [name | rest]} when is_atom(name) ->
          {columns, opts} =
            case rest do
              [columns] when is_list(columns) -> {columns, []}
              [columns, opts] when is_list(columns) and is_list(opts) -> {columns, opts}
              _ -> raise "identity requires columns list, e.g. identity :unique_email, [:email]"
            end

          identity_map =
            quote do: %{
                    name: unquote(name),
                    columns: unquote(columns),
                    options: unquote(opts)
                  }

          {{:., meta, [{:__aliases__, meta, [:AshScylla, :DataLayer, :Dsl]}, :__add_identity__]},
           meta, [{:__MODULE__, [], nil}, identity_map]}

        # ── Aggregate DSL ──

        {:aggregate, meta, [type, name | rest]} when is_atom(type) and is_atom(name) ->
          {field, opts} =
            case rest do
              [] -> {nil, []}
              [opts] when is_list(opts) -> {nil, opts}
              [{field, opts}] when is_list(opts) -> {field, opts}
              [field] when is_atom(field) -> {field, []}
              _ -> {nil, []}
            end

          aggregate_map =
            quote do: %{
                    type: unquote(type),
                    name: unquote(name),
                    field: unquote(field),
                    options: unquote(opts)
                  }

          {{:., meta, [{:__aliases__, meta, [:AshScylla, :DataLayer, :Dsl]}, :__add_aggregate__]},
           meta, [{:__MODULE__, [], nil}, aggregate_map]}

        # ── Calculation DSL ──

        {:calculation, meta, [name, type, expression | rest]} when is_atom(name) and is_atom(type) ->
          calc_opts =
            case rest do
              [] -> []
              [opts] when is_list(opts) -> opts
              _ -> []
            end

          calc_map =
            quote do: %{
                    name: unquote(name),
                    type: unquote(type),
                    expression: unquote(expression),
                    options: unquote(calc_opts)
                  }

          {{:., meta,
            [{:__aliases__, meta, [:AshScylla, :DataLayer, :Dsl]}, :__add_calculation__]}, meta,
           [{:__MODULE__, [], nil}, calc_map]}

        # ── Preparation DSL ──

        {:preparation, meta, [value]} ->
          prep_map = quote do: %{preparation: unquote(value)}

          {{:., meta,
            [{:__aliases__, meta, [:AshScylla, :DataLayer, :Dsl]}, :__add_preparation__]}, meta,
           [{:__MODULE__, [], nil}, prep_map]}

        # ── Change DSL ──

        {:change, meta, [value]} ->
          change_map = quote do: %{change: unquote(value)}

          {{:., meta, [{:__aliases__, meta, [:AshScylla, :DataLayer, :Dsl]}, :__add_change__]},
           meta, [{:__MODULE__, [], nil}, change_map]}

        # ── Validation DSL ──

        {:validation, meta, [value]} ->
          validation_map = quote do: %{validation: unquote(value)}

          {{:., meta,
            [{:__aliases__, meta, [:AshScylla, :DataLayer, :Dsl]}, :__add_validation__]}, meta,
           [{:__MODULE__, [], nil}, validation_map]}

        # ── Pipeline DSL ──

        {:pipeline, meta, [value]} ->
          pipeline_map = quote do: %{pipeline: unquote(value)}

          {{:., meta, [{:__aliases__, meta, [:AshScylla, :DataLayer, :Dsl]}, :__add_pipeline__]},
           meta, [{:__MODULE__, [], nil}, pipeline_map]}

        # ── Multitenancy DSL ──

        {:multitenancy, meta, [value]} when is_list(value) ->
          strategy = value[:strategy] || :context
          attribute = value[:attribute]

          mt_map =
            quote do: %{
                    strategy: unquote(strategy),
                    attribute: unquote(attribute)
                  }

          {{:., meta,
            [{:__aliases__, meta, [:AshScylla, :DataLayer, :Dsl]}, :__set_multitenancy__]}, meta,
           [{:__MODULE__, [], nil}, mt_map]}

        # ── Code Interface DSL ──

        {:code_interface, meta, [value]} when is_list(value) ->
          ci_map = quote do: %{definitions: unquote(value)}

          {{:., meta,
            [{:__aliases__, meta, [:AshScylla, :DataLayer, :Dsl]}, :__set_code_interface__]},
           meta, [{:__MODULE__, [], nil}, ci_map]}

        # ── Relationship DSL ──

        {:relationship, meta, [type, name, target | rest]}
        when is_atom(type) and is_atom(name) and is_atom(target) ->
          rel_opts =
            case rest do
              [] -> []
              [opts] when is_list(opts) -> opts
              _ -> []
            end

          rel_map =
            quote do: %{
                    type: unquote(type),
                    name: unquote(name),
                    target: unquote(target),
                    options: unquote(rel_opts)
                  }

          {{:., meta,
            [{:__aliases__, meta, [:AshScylla, :DataLayer, :Dsl]}, :__add_relationship__]}, meta,
           [{:__MODULE__, [], nil}, rel_map]}

        # ── Action DSL (extended) ──

        {:action, meta, [type, name | rest]} when is_atom(type) and is_atom(name) ->
          action_config =
            case rest do
              [] -> []
              [opts] when is_list(opts) -> opts
              _ -> []
            end

          action_map =
            quote do: %{
                    type: unquote(type),
                    name: unquote(name),
                    options: unquote(action_config)
                  }

          {{:., meta,
            [{:__aliases__, meta, [:AshScylla, :DataLayer, :Dsl]}, :__add_action_config__]}, meta,
           [{:__MODULE__, [], nil}, action_map]}

        other ->
          other
      end)

    quote do
      # ── Existing ScyllaDB attributes ──
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

      # ── Ash 3.0+ resource-level attributes ──
      @ash_scylla_base_filter nil
      @ash_scylla_default_context nil
      @ash_scylla_description nil

      # ── Identity attributes ──
      @ash_scylla_identities []

      # ── Aggregate attributes ──
      @ash_scylla_aggregates []

      # ── Calculation attributes ──
      @ash_scylla_calculations []

      # ── Preparation attributes ──
      @ash_scylla_preparations []

      # ── Change attributes ──
      @ash_scylla_changes []

      # ── Validation attributes ──
      @ash_scylla_validations []

      # ── Pipeline attributes ──
      @ash_scylla_pipelines []

      # ── Multitenancy attributes ──
      @ash_scylla_multitenancy nil

      # ── Code Interface attributes ──
      @ash_scylla_code_interface nil

      # ── Relationship attributes ──
      @ash_scylla_relationships []

      # ── Action config attributes ──
      @ash_scylla_action_configs []

      unquote(transformed)

      # ── Unified getter function ──
      @ash_scylla_config %{
        table: @ash_scylla_table,
        keyspace: @ash_scylla_keyspace,
        consistency: @ash_scylla_consistency,
        ttl: @ash_scylla_ttl,
        secondary_indexes: @ash_scylla_secondary_indexes,
        materialized_views: @ash_scylla_materialized_views,
        pagination: @ash_scylla_pagination,
        per_action_consistency: @ash_scylla_per_action_consistency,
        lwt: @ash_scylla_lwt,
        repo: @ash_scylla_repo,
        base_filter: @ash_scylla_base_filter,
        default_context: @ash_scylla_default_context,
        description: @ash_scylla_description,
        identities: @ash_scylla_identities,
        aggregates: @ash_scylla_aggregates,
        calculations: @ash_scylla_calculations,
        preparations: @ash_scylla_preparations,
        changes: @ash_scylla_changes,
        validations: @ash_scylla_validations,
        pipelines: @ash_scylla_pipelines,
        multitenancy: @ash_scylla_multitenancy,
        code_interface: @ash_scylla_code_interface,
        relationships: @ash_scylla_relationships,
        action_configs: @ash_scylla_action_configs
      }

      def __ash_scylla__(key), do: Map.get(@ash_scylla_config, key)
    end
  end

  # ============================================================================
  # Parse helpers
  # ============================================================================

  @doc false
  @spec parse_secondary_index(atom() | list(atom()) | {atom(), keyword()}) :: map()
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

  # ============================================================================
  # Private helpers
  # ============================================================================

  defp get_config(resource, key, default \\ nil) do
    if function_exported?(resource, :__ash_scylla__, 1) do
      resource.__ash_scylla__(key)
    else
      default
    end
  end

  defp put_attr(module, attr, value), do: Module.put_attribute(module, attr, value)

  defp add_to_attr(module, attr, value) do
    current = Module.get_attribute(module, attr)
    Module.put_attribute(module, attr, [value | current])
  end

  # ============================================================================
  # Existing public API getters
  # ============================================================================

  @doc """
  Gets the configured table name for a resource.
  """
  @spec table(module()) :: String.t() | nil
  def table(resource), do: get_config(resource, :table)

  @doc """
  Gets the configured keyspace for a resource.
  """
  @spec keyspace(module()) :: String.t() | nil
  def keyspace(resource), do: get_config(resource, :keyspace)

  @doc """
  Gets the configured consistency level for a resource.
  """
  @spec consistency(module()) :: atom() | nil
  def consistency(resource), do: get_config(resource, :consistency)

  @doc """
  Gets the configured TTL for a resource.
  """
  @spec ttl(module()) :: pos_integer() | nil
  def ttl(resource), do: get_config(resource, :ttl)

  @doc """
  Gets the secondary indexes defined for a resource.

  Returns a list of maps with keys:
  - `:columns` - list of column names (atoms)
  - `:name` - optional custom index name
  - `:options` - additional options
  """
  @spec secondary_indexes(module()) :: [map()]
  def secondary_indexes(resource), do: get_config(resource, :secondary_indexes, [])

  @doc """
  Gets the materialized views defined for a resource.

  Returns a list of maps with keys:
  - `:name` - the view name (atom)
  - `:config` - the view configuration keyword list
  """
  @spec materialized_views(module()) :: [map()]
  def materialized_views(resource), do: get_config(resource, :materialized_views, [])

  @doc """
  Gets the pagination mode for a resource.

  Returns `:offset` or `:token`.
  """
  @spec pagination(module()) :: :offset | :token
  def pagination(resource), do: get_config(resource, :pagination, :offset)

  @doc """
  Gets the per-action consistency configuration for a resource.

  Returns a map of action_name => consistency_level.
  """
  @spec per_action_consistency(module()) :: map()
  def per_action_consistency(resource), do: get_config(resource, :per_action_consistency, %{})

  @doc """
  Checks if a column has a secondary index defined.
  """
  @spec has_secondary_index?(module(), atom()) :: boolean()
  def has_secondary_index?(resource, column) do
    indexes = secondary_indexes(resource)
    Enum.any?(indexes, fn idx -> column in idx.columns end)
  end

  @spec lwt(module()) :: boolean()
  def lwt(resource), do: get_config(resource, :lwt, false)

  @doc """
  Gets the configured repo for a resource.
  """
  @spec repo(module()) :: module() | nil
  def repo(resource), do: get_config(resource, :repo)

  # ============================================================================
  # Ash 3.0+ public API getters
  # ============================================================================

  @doc """
  Gets the base_filter configured for a resource.

  The base_filter is a filter expression that is automatically applied
  to all queries on this resource (Ash 3.0 feature).
  """
  @spec base_filter(module()) :: term() | nil
  def base_filter(resource), do: get_config(resource, :base_filter)

  @doc """
  Gets the default_context configured for a resource.

  The default_context is a map that is merged into every query and
  changeset context for this resource (Ash 3.0 feature).
  """
  @spec default_context(module()) :: map() | nil
  def default_context(resource), do: get_config(resource, :default_context)

  @doc """
  Gets the description configured for a resource.
  """
  @spec description(module()) :: String.t() | nil
  def description(resource), do: get_config(resource, :description)

  @doc """
  Gets the identities defined for a resource.

  Returns a list of maps with keys:
  - `:name` - the identity name (atom)
  - `:columns` - list of column names (atoms)
  - `:options` - additional options
  """
  @spec identities(module()) :: [map()]
  def identities(resource), do: get_config(resource, :identities, [])

  @doc """
  Gets the aggregates defined for a resource.

  Returns a list of maps with keys:
  - `:type` - the aggregate type (:count, :sum, :avg, :min, :max)
  - `:name` - the aggregate name (atom)
  - `:field` - the field to aggregate on (optional)
  - `:options` - additional options (filter, etc.)
  """
  @spec aggregates(module()) :: [map()]
  def aggregates(resource), do: get_config(resource, :aggregates, [])

  @doc """
  Gets the calculations defined for a resource.

  Returns a list of maps with keys:
  - `:name` - the calculation name (atom)
  - `:type` - the calculation type (atom)
  - `:expression` - the expression to evaluate
  - `:options` - additional options
  """
  @spec calculations(module()) :: [map()]
  def calculations(resource), do: get_config(resource, :calculations, [])

  @doc """
  Gets the preparations defined for a resource.
  """
  @spec preparations(module()) :: [map()]
  def preparations(resource), do: get_config(resource, :preparations, [])

  @doc """
  Gets the changes defined for a resource.
  """
  @spec changes(module()) :: [map()]
  def changes(resource), do: get_config(resource, :changes, [])

  @doc """
  Gets the validations defined for a resource.
  """
  @spec validations(module()) :: [map()]
  def validations(resource), do: get_config(resource, :validations, [])

  @doc """
  Gets the pipelines defined for a resource.
  """
  @spec pipelines(module()) :: [map()]
  def pipelines(resource), do: get_config(resource, :pipelines, [])

  @doc """
  Gets the multitenancy configuration for a resource.

  Returns a map with keys:
  - `:strategy` - :context or :attribute
  - `:attribute` - the attribute name for :attribute strategy (optional)
  """
  @spec multitenancy(module()) :: map() | nil
  def multitenancy(resource), do: get_config(resource, :multitenancy)

  @doc """
  Gets the code_interface configuration for a resource.
  """
  @spec scylla_code_interface(module()) :: map() | nil
  def scylla_code_interface(resource), do: get_config(resource, :code_interface)

  @doc """
  Gets the relationships defined for a resource.

  Returns a list of maps with keys:
  - `:type` - :belongs_to, :has_one, :has_many, or :many_to_many
  - `:name` - the relationship name (atom)
  - `:target` - the target resource module
  - `:options` - additional options
  """
  @spec relationships(module()) :: [map()]
  def relationships(resource), do: get_config(resource, :relationships, [])

  @doc """
  Gets the action configurations defined for a resource.

  Returns a list of maps with keys:
  - `:type` - the action type (:create, :read, :update, :destroy)
  - `:name` - the action name (atom)
  - `:options` - action options (accept, argument, change, validate, etc.)
  """
  @spec action_configs(module()) :: [map()]
  def action_configs(resource), do: get_config(resource, :action_configs, [])

  # ============================================================================
  # DSL setter functions — called by the DSL body at compile time
  # ============================================================================

  # ── Existing setters ──

  @doc false
  @spec __set_table__(module(), String.t()) :: :ok
  def __set_table__(module, value), do: put_attr(module, :ash_scylla_table, value)

  @doc false
  @spec __set_keyspace__(module(), String.t()) :: :ok
  def __set_keyspace__(module, value), do: put_attr(module, :ash_scylla_keyspace, value)

  @doc false
  @spec __set_consistency__(module(), atom()) :: :ok
  def __set_consistency__(module, value), do: put_attr(module, :ash_scylla_consistency, value)

  @doc false
  @spec __set_ttl__(module(), pos_integer()) :: :ok
  def __set_ttl__(module, value), do: put_attr(module, :ash_scylla_ttl, value)

  @doc false
  @spec __add_secondary_index__(module(), map()) :: :ok
  def __add_secondary_index__(module, index_config),
    do: add_to_attr(module, :ash_scylla_secondary_indexes, index_config)

  @doc false
  @spec __add_materialized_view__(module(), map()) :: :ok
  def __add_materialized_view__(module, view_config),
    do: add_to_attr(module, :ash_scylla_materialized_views, view_config)

  @doc false
  @spec __set_pagination__(module(), :offset | :token) :: :ok
  def __set_pagination__(module, value) when value in [:offset, :token],
    do: put_attr(module, :ash_scylla_pagination, value)

  @spec __set_pagination__(module(), :offset | :token) :: :ok
  def __set_pagination__(_module, value) do
    raise ArgumentError, "Invalid pagination mode: #{inspect(value)}. Must be :offset or :token"
  end

  @doc false
  @spec __set_per_action_consistency__(module(), keyword()) :: :ok
  def __set_per_action_consistency__(module, action_consistency)
      when is_list(action_consistency) do
    put_attr(module, :ash_scylla_per_action_consistency, Map.new(action_consistency))
  end

  @doc false
  @spec __set_lwt__(module(), boolean()) :: :ok
  def __set_lwt__(module, value) when is_boolean(value),
    do: put_attr(module, :ash_scylla_lwt, value)

  @doc false
  @spec __set_repo__(module(), module()) :: :ok
  def __set_repo__(module, value), do: put_attr(module, :ash_scylla_repo, value)

  # ── Ash 3.0+ setters ──

  @doc false
  @spec __set_base_filter__(module(), term()) :: :ok
  def __set_base_filter__(module, value), do: put_attr(module, :ash_scylla_base_filter, value)

  @doc false
  @spec __set_default_context__(module(), map()) :: :ok
  def __set_default_context__(module, value) when is_map(value),
    do: put_attr(module, :ash_scylla_default_context, value)

  @doc false
  @spec __set_description__(module(), String.t()) :: :ok
  def __set_description__(module, value) when is_binary(value),
    do: put_attr(module, :ash_scylla_description, value)

  # ── Identity setters ──

  @doc false
  @spec __add_identity__(module(), map()) :: :ok
  def __add_identity__(module, identity_config),
    do: add_to_attr(module, :ash_scylla_identities, identity_config)

  # ── Aggregate setters ──

  @doc false
  @spec __add_aggregate__(module(), map()) :: :ok
  def __add_aggregate__(module, aggregate_config),
    do: add_to_attr(module, :ash_scylla_aggregates, aggregate_config)

  # ── Calculation setters ──

  @doc false
  @spec __add_calculation__(module(), map()) :: :ok
  def __add_calculation__(module, calc_config),
    do: add_to_attr(module, :ash_scylla_calculations, calc_config)

  # ── Preparation setters ──

  @doc false
  @spec __add_preparation__(module(), map()) :: :ok
  def __add_preparation__(module, prep_config),
    do: add_to_attr(module, :ash_scylla_preparations, prep_config)

  # ── Change setters ──

  @doc false
  @spec __add_change__(module(), map()) :: :ok
  def __add_change__(module, change_config),
    do: add_to_attr(module, :ash_scylla_changes, change_config)

  # ── Validation setters ──

  @doc false
  @spec __add_validation__(module(), map()) :: :ok
  def __add_validation__(module, validation_config),
    do: add_to_attr(module, :ash_scylla_validations, validation_config)

  # ── Pipeline setters ──

  @doc false
  @spec __add_pipeline__(module(), map()) :: :ok
  def __add_pipeline__(module, pipeline_config),
    do: add_to_attr(module, :ash_scylla_pipelines, pipeline_config)

  # ── Multitenancy setters ──

  @doc false
  @spec __set_multitenancy__(module(), map()) :: :ok
  def __set_multitenancy__(module, mt_config),
    do: put_attr(module, :ash_scylla_multitenancy, mt_config)

  # ── Code Interface setters ──

  @doc false
  @spec __set_code_interface__(module(), map()) :: :ok
  def __set_code_interface__(module, ci_config),
    do: put_attr(module, :ash_scylla_code_interface, ci_config)

  # ── Relationship setters ──

  @doc false
  @spec __add_relationship__(module(), map()) :: :ok
  def __add_relationship__(module, rel_config),
    do: add_to_attr(module, :ash_scylla_relationships, rel_config)

  # ── Action config setters ──

  @doc false
  @spec __add_action_config__(module(), map()) :: :ok
  def __add_action_config__(module, action_config),
    do: add_to_attr(module, :ash_scylla_action_configs, action_config)
end
