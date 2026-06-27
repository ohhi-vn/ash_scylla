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
      AshScylla.DataLayer.Batch.batch_insert(repo, statements)

      # Async partition-aware batch
      AshScylla.DataLayer.Batch.batch_insert_async(repo, statements, max_concurrency: 8)

  ## Consistency

  Batch operations use `:all` consistency by default. Override with
  `consistency:` option.
  """

  require Logger

  alias Ash.Resource.Info

  @default_max_concurrency System.schedulers_online()
  @default_max_statements_per_batch 500

  @doc """
  Executes a batch of INSERT statements.
  """
  @spec batch_insert(module(), [{String.t(), list()}], keyword()) ::
          {:ok, term()} | {:error, term()}
  def batch_insert(repo, statements, opts \\ []) do
    do_batch(repo, statements, opts, "insert")
  end

  @doc """
  Executes a batch of UPDATE statements.
  """
  @spec batch_update(module(), [{String.t(), list()}], keyword()) ::
          {:ok, term()} | {:error, term()}
  def batch_update(repo, statements, opts \\ []) do
    do_batch(repo, statements, opts, "update")
  end

  @doc """
  Executes a batch of DELETE statements.
  """
  @spec batch_delete(module(), [{String.t(), list()}], keyword()) ::
          {:ok, term()} | {:error, term()}
  def batch_delete(repo, statements, opts \\ []) do
    do_batch(repo, statements, opts, "delete")
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
    max_concurrency = Keyword.get(opts, :max_concurrency, @default_max_concurrency)

    max_per_batch =
      Keyword.get(opts, :max_statements_per_batch, @default_max_statements_per_batch)

    Logger.info(
      "AshScylla: Executing async batch insert with #{length(statements)} statements, " <>
        "max_concurrency=#{max_concurrency}, max_per_batch=#{max_per_batch}"
    )

    # Chunk statements into safe batch sizes to avoid exceeding ScyllaDB thresholds
    chunked_statements = Enum.chunk_every(statements, max_per_batch)

    # Execute each chunk in parallel, collecting results or stopping on first error
    results =
      chunked_statements
      |> Task.async_stream(
        fn chunk ->
          grouped =
            Enum.group_by(chunk, fn {_query, params} ->
              partition_key_hash(params)
            end)

          # Execute each partition group within this chunk, stop on first error
          Enum.reduce_while(grouped, {:ok, []}, fn {_pk, batch_statements}, {:ok, acc} ->
            case build_batch_query(batch_statements, repo, opts) do
              {:ok, result} -> {:cont, {:ok, [result | acc]}}
              {:error, reason} -> {:halt, {:error, reason}}
            end
          end)
        end,
        max_concurrency: max_concurrency,
        ordered: false,
        on_timeout: :kill_task
      )
      |> Enum.reduce_while({:ok, []}, fn
        {:ok, {:ok, chunk_results}}, {:ok, acc} ->
          {:cont, {:ok, acc ++ chunk_results}}

        {:ok, {:error, reason}}, _acc ->
          {:halt, {:error, reason}}

        {:exit, reason}, _acc ->
          {:halt, {:error, {:batch_execution_failed, reason}}}
      end)

    case results do
      {:ok, acc} -> {:ok, acc}
      {:error, _} = error -> error
    end
  end

  @doc """
  Splits a list of statements into chunks suitable for BATCH execution.

  ScyllaDB has a configurable batch size threshold (default warn at 128KB,
  fail at 256KB). Sending too many statements in a single BATCH will
  cause performance degradation or outright failure. This function
  chunks statements to stay within safe limits.

  ## Options

  - `:max_statements_per_batch` — Maximum statements per chunk (default: 500)

  ## Examples

      statements = [{"INSERT INTO users (id) VALUES (?)", [i}] <- 1..2000]
      chunks = AshScylla.DataLayer.Batch.chunk_batch(statements)
      # => 4 chunks of 500 statements each
  """
  @spec chunk_batch([{String.t(), list()}], keyword()) :: [[{String.t(), list()}]]
  def chunk_batch(statements, opts \\ []) do
    max_per_batch =
      Keyword.get(opts, :max_statements_per_batch, @default_max_statements_per_batch)

    Enum.chunk_every(statements, max_per_batch)
  end

  @doc """
  Returns the default max statements per batch.
  """
  @spec default_max_statements_per_batch() :: pos_integer()
  def default_max_statements_per_batch, do: @default_max_statements_per_batch

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

  # ---------------------------------------------------------------------------
  # Private functions
  # ---------------------------------------------------------------------------

  defp do_batch(repo, statements, opts, operation) do
    Logger.debug("AshScylla: Executing batch #{operation} with #{length(statements)} statements")
    build_batch_query(statements, repo, opts)
  end

  @spec build_batch_query([{String.t(), list()}], module(), keyword()) ::
          {:ok, term()} | {:error, term()}
  defp build_batch_query(statements, repo, opts) do
    case statements do
      [] ->
        Logger.debug("AshScylla: Empty batch, skipping execution")
        {:ok, []}

      _ ->
        if valid_statements?(statements) do
          queries = Enum.map(statements, fn {query, _} -> query end)
          all_params = Enum.flat_map(statements, fn {_, params} -> params end)
          batch_query = "BEGIN BATCH #{Enum.join(queries, "; ")} APPLY BATCH;"

          Logger.debug("AshScylla: Built batch query with #{length(statements)} statements")
          repo.query(batch_query, all_params, opts)
        else
          invalid =
            Enum.find(statements, fn
              {query, params} when is_binary(query) and is_list(params) -> false
              _ -> true
            end)

          Logger.error("AshScylla: Invalid batch statement: #{inspect(invalid)}")

          raise ArgumentError,
                "Invalid batch statement: #{inspect(invalid)}. Expected {query_string, params_list}"
        end
    end
  end

  defp valid_statements?(statements) do
    Enum.all?(statements, fn
      {query, params} when is_binary(query) and is_list(params) -> true
      _ -> false
    end)
  end

  @spec partition_key_hash(list()) :: non_neg_integer()
  defp partition_key_hash(params) do
    # Simple hash-based grouping for partition-aware batching
    # Uses the first parameter (typically the partition key value)
    case params do
      [first | _] -> :erlang.phash2(first)
      [] -> 0
    end
  end
end
