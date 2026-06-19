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

defmodule AshScylla.PreparedStatementCache do
  @moduledoc """
  ETS-based prepared statement cache for ScyllaDB/Cassandra queries.

  Caches prepared statements keyed by query hash to eliminate repeated
  query parsing overhead on ScyllaDB. This is especially impactful for
  high-throughput workloads where the same queries are executed repeatedly.

  All ETS operations are routed through the GenServer to avoid race
  conditions when multiple processes access the cache concurrently.

  ## Usage

      AshScylla.PreparedStatementCache.prepare(repo, "SELECT * FROM users WHERE id = ?")

  ## Starting the Cache

  Add to your supervision tree:

      children = [
        AshScylla.PreparedStatementCache,
        # ... other children
      ]

  Or start manually:

      AshScylla.PreparedStatementCache.start_link([])
  """

  use GenServer

  require Logger

  @cleanup_interval :timer.minutes(5)
  @max_cache_size 10_000

  @doc """
  Starts the prepared statement cache.

  When no `:name` option is given, the GenServer is registered globally
  as `{:global, __MODULE__}` so that all processes share a single cache.
  Pass `name: :undefined` or a custom name to register locally instead.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name =
      case Keyword.get(opts, :name) do
        nil -> {:global, __MODULE__}
        :undefined -> {:global, __MODULE__}
        other -> other
      end

    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @type cache_entry :: {term(), term()}
  @type cache_key :: {module(), String.t(), String.t(), keyword()}

  @doc """
  Returns the ETS table tid for inspection/testing.
  """
  @spec table() :: :ets.tid() | nil
  def table do
    case :global.whereis_name(__MODULE__) do
      :undefined ->
        case Process.whereis(__MODULE__) do
          nil -> nil
          pid -> get_table_from_pid(pid)
        end

      pid ->
        get_table_from_pid(pid)
    end
  end

  defp get_table_from_pid(pid) do
    case Process.alive?(pid) do
      true ->
        try do
          GenServer.call(pid, :get_table, 5_000)
        catch
          :exit, _ -> nil
        end

      false ->
        nil
    end
  end

  @doc """
  Prepares a CQL statement, using the cache if available.

  Returns `{:ok, stmt}` on success or `{:error, reason}` on failure.
  """
  @spec prepare(module(), String.t(), keyword()) :: {:ok, term()} | {:error, term()}
  def prepare(repo, cql, opts \\ []) do
    GenServer.call(server_name(), {:prepare, repo, cql, opts}, 30_000)
  end

  @doc """
  Invalidates a specific cached statement by CQL string.
  """
  @spec invalidate(String.t()) :: :ok
  def invalidate(cql) do
    GenServer.call(server_name(), {:invalidate, cql}, 5_000)
  end

  @doc """
  Clears all cached prepared statements.
  """
  @spec clear() :: :ok
  def clear do
    GenServer.call(server_name(), :clear, 5_000)
  end

  @doc """
  Returns the number of cached statements.
  """
  @spec size() :: non_neg_integer()
  def size do
    GenServer.call(server_name(), :size, 5_000)
  end

  # Returns the name to use for GenServer calls.
  # Uses the globally registered name if available, otherwise falls back
  # to the default local name.
  defp server_name do
    case :global.whereis_name(__MODULE__) do
      :undefined -> __MODULE__
      _pid -> {:global, __MODULE__}
    end
  end

  @impl GenServer
  def init(_opts) do
    tid =
      :ets.new(:ash_scylla_prepared_statement_cache, [
        :set,
        :protected,
        read_concurrency: true,
        write_concurrency: true
      ])

    schedule_cleanup()
    {:ok, %{table: tid}}
  end

  @impl GenServer
  def handle_call(:get_table, _from, %{table: tid} = state) do
    {:reply, {:ok, tid}, state}
  end

  def handle_call({:prepare, repo, cql, opts}, _from, %{table: tid} = state) do
    key = cache_key(repo, cql, opts)

    result =
      case :ets.lookup(tid, key) do
        [{^key, stmt}] ->
          {:ok, stmt}

        [] ->
          case do_prepare(repo, cql, opts) do
            {:ok, stmt} ->
              maybe_evict_oldest(tid)
              :ets.insert(tid, {key, stmt})
              {:ok, stmt}

            {:error, _} = error ->
              error
          end
      end

    {:reply, result, state}
  end

  def handle_call({:invalidate, repo, cql, opts}, _from, %{table: tid} = state) do
    :ets.delete(tid, cache_key(repo, cql, opts))
    {:reply, :ok, state}
  end

  def handle_call({:invalidate, cql}, _from, %{table: tid} = state) do
    # Delete all entries matching this CQL string (regardless of repo/keyspace/opts)
    # Iterate all entries and delete matching ones
    :ets.tab2list(tid)
    |> Enum.filter(fn {{_repo, entry_cql, _keyspace, _opts}, _value} -> entry_cql == cql end)
    |> Enum.each(fn {key, _value} -> :ets.delete(tid, key) end)

    {:reply, :ok, state}
  end

  def handle_call(:clear, _from, %{table: tid} = state) do
    :ets.delete_all_objects(tid)
    {:reply, :ok, state}
  end

  def handle_call(:size, _from, %{table: tid} = state) do
    {:reply, :ets.info(tid, :size), state}
  end

  @impl GenServer
  def handle_info(:cleanup, %{table: tid} = state) do
    # Evict oldest entries if cache exceeds max size
    current_size = :ets.info(tid, :size)

    if current_size > @max_cache_size do
      evict_oldest(tid, div(current_size - @max_cache_size, 2))
    end

    schedule_cleanup()
    {:noreply, state}
  end

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup, @cleanup_interval)
  end

  @doc false
  @spec maybe_evict_oldest(:ets.tid()) :: :ok
  defp maybe_evict_oldest(tid) do
    case :ets.info(tid, :size) do
      size when size >= @max_cache_size ->
        evict_oldest(tid, div(size - @max_cache_size, 2) + 1)

      _ ->
        :ok
    end
  end

  @doc false
  @spec evict_oldest(:ets.tid(), non_neg_integer()) :: :ok
  defp evict_oldest(tid, count) when count > 0 do
    # Delete the first N entries (oldest insertion order in ETS set type)
    # ETS set type doesn't guarantee insertion order, but this is best-effort
    # eviction to prevent unbounded growth
    first_n = :ets.select(tid, [{{:_, :_}, [], [true]}], count)

    case first_n do
      {entries, _continuation} ->
        Enum.each(entries, fn key -> :ets.delete(tid, key) end)

      _ ->
        :ok
    end

    :ok
  catch
    _ -> :ok
  end

  defp evict_oldest(_tid, _count), do: :ok

  defp do_prepare(repo, cql, opts) do
    if function_exported?(repo, :prepare, 2) do
      repo.prepare(cql, opts)
    else
      Logger.warning(
        "AshScylla.PreparedStatementCache: #{inspect(repo)} does not implement prepare/2. " <>
          "Falling back to unprepared query execution."
      )

      {:error, :prepare_not_supported}
    end
  end

  defp cache_key(repo, cql, opts) do
    keyspace = Keyword.get(opts, :keyspace) || repo_keyspace(repo)

    {repo, cql, keyspace, Keyword.take(opts, [:consistency, :default_consistency, :compressor])}
  end

  defp repo_keyspace(repo) do
    if function_exported?(repo, :keyspace, 0) do
      repo.keyspace()
    else
      nil
    end
  end
end
