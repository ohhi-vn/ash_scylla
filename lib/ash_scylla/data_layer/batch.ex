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

defmodule AshScylla.DataLayer.Batch do
  @moduledoc """
  Batch operations support for AshScylla using ScyllaDB's BATCH statements.

  ScyllaDB/Cassandra supports batch operations for executing multiple
  CQL statements in a single request.

  ## Synchronous Batches

  For small batches or when ordering matters, use `batch_insert/3`,
  `batch_update/3`, or `batch_delete/3`.

  ## Async Partition-Aware Batches

  For large bulk operations, use `batch_insert_async/4`. This function:
  - Groups records by partition key (safe for ScyllaDB)
  - Executes sub-batches in parallel using `Task.async_stream`
  - Respects ScyllaDB's recommendation to avoid cross-partition BATCH statements

  ## Examples

      # Synchronous batch
      statements = [
        {"INSERT INTO users (id, name) VALUES (?, ?)", [id1, "Alice"]},
        {"INSERT INTO users (id, name) VALUES (?, ?)", [id2, "Bob"]}
      ]
      DataLayer.Batch.batch_insert(repo, statements)

      # Async partition-aware batch
      DataLayer.Batch.batch_insert_async(repo, statements, max_concurrency: 8)
  """

  require Logger

  alias Ash.Resource.Info

  @default_max_concurrency System.schedulers_online()

  @doc """
  Executes a batch of INSERT statements.
  """
  @spec batch_insert(module(), [{String.t(), list()}], keyword()) ::
          {:ok, term()} | {:error, term()}
  def batch_insert(repo, statements, opts \\ []) do
    Logger.debug("AshScylla: Executing batch insert with #{length(statements)} statements")
    build_batch_query(statements, repo, opts)
  end

  @doc """
  Executes a batch of UPDATE statements.
  """
  @spec batch_update(module(), [{String.t(), list()}], keyword()) ::
          {:ok, term()} | {:error, term()}
  def batch_update(repo, statements, opts \\ []) do
    Logger.debug("AshScylla: Executing batch update with #{length(statements)} statements")
    build_batch_query(statements, repo, opts)
  end

  @doc """
  Executes a batch of DELETE statements.
  """
  @spec batch_delete(module(), [{String.t(), list()}], keyword()) ::
          {:ok, term()} | {:error, term()}
  def batch_delete(repo, statements, opts \\ []) do
    Logger.debug("AshScylla: Executing batch delete with #{length(statements)} statements")
    build_batch_query(statements, repo, opts)
  end

  @doc """
  Executes batch inserts asynchronously, grouped by partition key.

  This is the recommended approach for large bulk inserts in ScyllaDB.
  Records are grouped by their partition key values, and each group
  is executed as a separate batch in parallel. This avoids the
  cross-partition BATCH anti-pattern.

  ## Options

  - `:max_concurrency` - Maximum number of concurrent batch executions
    (defaults to `System.schedulers_online()`)

  ## Examples

      statements = [
        {"INSERT INTO users (id, name) VALUES (?, ?)", [id1, "Alice"]},
        {"INSERT INTO users (id, name) VALUES (?, ?)", [id2, "Bob"]},
        # ... hundreds more
      ]

      DataLayer.Batch.batch_insert_async(repo, statements, resource: MyApp.User)
  """
  @spec batch_insert_async(module(), [{String.t(), list()}], keyword()) ::
          {:ok, [term()]} | {:error, term()}
  def batch_insert_async(repo, statements, opts \\ []) do
    _resource = Keyword.fetch!(opts, :resource)
    max_concurrency = Keyword.get(opts, :max_concurrency, @default_max_concurrency)

    Logger.info(
      "AshScylla: Executing async batch insert with #{length(statements)} statements, " <>
        "max_concurrency=#{max_concurrency}"
    )

    # Group statements by partition key
    grouped =
      Enum.group_by(statements, fn {_query, params} ->
        # Use the first param as a simple partition grouping heuristic
        # For more sophisticated grouping, use partition_key/2
        partition_key_hash(params)
      end)

    group_count = map_size(grouped)
    Logger.debug("AshScylla: Grouped into #{count(group_count)} partition groups")

    # Execute each group in parallel
    results =
      grouped
      |> Task.async_stream(
        fn {_pk, batch_statements} ->
          build_batch_query(batch_statements, repo, opts)
        end,
        max_concurrency: max_concurrency,
        ordered: false,
        on_timeout: :kill_task
      )
      |> Enum.reduce_while({:ok, []}, fn
        {:ok, {:ok, result}}, {:ok, acc} ->
          {:cont, {:ok, [result | acc]}}

        {:ok, {:error, reason}}, _acc ->
          {:halt, {:error, reason}}

        {:exit, reason}, _acc ->
          {:halt, {:error, {:batch_execution_failed, reason}}}
      end)

    case results do
      {:ok, _} -> {:ok, :completed}
      {:error, _} = error -> error
    end
  end

  @doc """
  Extracts the partition key values from a record for a given resource.

  Returns a map of partition key column names to their values.
  """
  @spec partition_key(map(), module()) :: map()
  def partition_key(record, resource) do
    resource
    |> Info.attributes()
    |> Enum.filter(& &1.primary_key?)
    |> Enum.reduce(%{}, fn attr, acc ->
      case Map.fetch(record, attr.name) do
        {:ok, value} -> Map.put(acc, attr.name, value)
        :error -> acc
      end
    end)
  end

  @spec build_batch_query([{String.t(), list()}], module(), keyword()) ::
          {:ok, term()} | {:error, term()}
  defp build_batch_query(statements, repo, opts) do
    case statements do
      [] ->
        Logger.debug("AshScylla: Empty batch, skipping execution")
        {:ok, []}

      _ ->
        # Validate all statements are {query_string, params_list} tuples
        invalid_count =
          Enum.count(statements, fn
            {query, params} when is_binary(query) and is_list(params) -> false
            _ -> true
          end)

        if invalid_count > 0 do
          invalid =
            Enum.find(statements, fn
              {query, params} when is_binary(query) and is_list(params) -> false
              _ -> true
            end)

          Logger.error("AshScylla: Invalid batch statement: #{inspect(invalid)}")

          raise ArgumentError,
                "Invalid batch statement: #{inspect(invalid)}. Expected {query_string, params_list}"
        end

        {queries_reversed, params_reversed} =
          Enum.reduce(statements, {[], []}, fn {query, params}, {acc_q, acc_p} ->
            {[query | acc_q], Enum.reverse(params, acc_p)}
          end)

        joined_queries = Enum.reverse(queries_reversed) |> Enum.join("; ")
        all_params = :lists.reverse(params_reversed)
        batch_query = "BEGIN BATCH #{joined_queries} APPLY BATCH;"

        Logger.debug("AshScylla: Built batch query with #{length(statements)} statements")
        repo.query(batch_query, all_params, opts)
    end
  end

  defp partition_key_hash(params) do
    # Simple hash-based grouping for partition-aware batching
    # Uses the first parameter (typically the partition key value)
    case params do
      [first | _] -> :erlang.phash2(first)
      [] -> 0
    end
  end

  defp count(n), do: n
end
