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
  """

  @moduledoc since: "1.0.0"

  @doc """
  Executes a batch of INSERT statements.

  ## Examples:

      statements = [
        {"INSERT INTO users (id, name) VALUES (?, ?)", [id1, "Alice"]},
        {"INSERT INTO users (id, name) VALUES (?, ?)", [id2, "Bob"]}
      ]

      DataLayer.Batch.batch_insert(repo, statements)
  """
  def batch_insert(repo, statements, opts \\ []) do
    case statements do
      [] -> {:ok, []}
      _ ->
        # Build BATCH statement
        {batch_query, all_params} =
          statements
          |> Enum.with_index()
          |> Enum.reduce({"BATCH BEGIN\n", []}, fn {{query, params}, _i}, {acc_q, acc_p} ->
            {"#{acc_q}  #{query};\n", acc_p ++ params}
          end)

        batch_query = "#{batch_query}APPLY BATCH;"

        repo.query(batch_query, all_params, opts)
    end
  end

  @doc """
  Executes a batch of UPDATE statements.
  """
  def batch_update(repo, statements, opts \\ []) do
    case statements do
      [] -> {:ok, []}
      _ ->
        # Build BATCH statement
        {batch_query, all_params} =
          statements
          |> Enum.with_index()
          |> Enum.reduce({"BATCH BEGIN\n", []}, fn {{query, params}, _i}, {acc_q, acc_p} ->
            {"#{acc_q}  #{query};\n", acc_p ++ params}
          end)

        batch_query = "#{batch_query}APPLY BATCH;"

        repo.query(batch_query, all_params, opts)
    end
  end

  @doc """
  Executes a batch of DELETE statements.
  """
  def batch_delete(repo, statements, opts \\ []) do
    case statements do
      [] -> {:ok, []}
      _ ->
        # Build BATCH statement
        {batch_query, all_params} =
          statements
          |> Enum.with_index()
          |> Enum.reduce({"BATCH BEGIN\n", []}, fn {{query, params}, _i}, {acc_q, acc_p} ->
            {"#{acc_q}  #{query};\n", acc_p ++ params}
          end)

        batch_query = "#{batch_query}APPLY BATCH;"

        repo.query(batch_query, all_params, opts)
    end
  end
end
