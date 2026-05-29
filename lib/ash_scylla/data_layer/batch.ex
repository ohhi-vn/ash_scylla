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

defmodule AshScylla.DataLayer.Batch do
  @moduledoc """
  Batch operations support for AshScylla using ScyllaDB's BATCH statements.

  ScyllaDB/Cassandra supports batch operations for executing multiple
  CQL statements in a single request.
  """

  require Logger

  @moduledoc since: "1.0.0"

  @doc """
  Executes a batch of INSERT statements.

  ## Examples

      statements = [
        {"INSERT INTO users (id, name) VALUES (?, ?)", [id1, "Alice"]},
        {"INSERT INTO users (id, name) VALUES (?, ?)", [id2, "Bob"]}
      ]

      DataLayer.Batch.batch_insert(repo, statements)
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
end
