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

  @table __MODULE__
  @cleanup_interval :timer.minutes(5)

  @doc """
  Starts the prepared statement cache.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = case opts[:name] do
      nil -> nil
      :undefined -> nil
      other -> other
    end
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Returns the ETS table name for inspection/testing.
  """
  @spec table() :: atom()
  def table, do: @table

  @doc """
  Prepares a CQL statement, using the cache if available.

  Returns `{:ok, stmt}` on success or `{:error, reason}` on failure.
  """
  @spec prepare(module(), String.t(), keyword()) :: {:ok, term()} | {:error, term()}
  def prepare(repo, cql, opts \\ []) do
    key = :erlang.phash2(cql)

    case :ets.lookup(@table, key) do
      [{^key, stmt}] ->
        {:ok, stmt}

      [] ->
        case do_prepare(repo, cql, opts) do
          {:ok, stmt} ->
            :ets.insert(@table, {key, stmt})
            {:ok, stmt}

          {:error, _} = error ->
            error
        end
    end
  end

  @doc """
  Invalidates a specific cached statement by CQL string.
  """
  @spec invalidate(String.t()) :: :ok
  def invalidate(cql) do
    key = :erlang.phash2(cql)
    :ets.delete(@table, key)
    :ok
  end

  @doc """
  Clears all cached prepared statements.
  """
  @spec clear() :: :ok
  def clear do
    try do
      :ets.delete_all_objects(@table)
    rescue
      ArgumentError -> :ok
    end

    :ok
  end

  @doc """
  Returns the number of cached statements.
  """
  @spec size() :: non_neg_integer()
  def size do
    :ets.info(@table, :size)
  end

  @impl GenServer
  def init(_opts) do
    try do
      :ets.new(@table, [
        :set,
        :public,
        :named_table,
        read_concurrency: true,
        write_concurrency: true
      ])
    rescue
      ArgumentError -> :ok
    end

    schedule_cleanup()
    {:ok, %{}}
  end

  @impl GenServer
  def handle_info(:cleanup, state) do
    # ETS entries are automatically cleaned when the server stops.
    # This is a placeholder for future TTL-based eviction if needed.
    schedule_cleanup()
    {:noreply, state}
  end

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup, @cleanup_interval)
  end

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
end
