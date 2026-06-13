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

defmodule AshScylla.Migrator do
  @moduledoc """
  Thin wrapper for executing CQL schema migrations via Xandra directly.

  Replaces the Exandra/Ecto.Migration pattern. Since CQL has no transactional
  DDL, each statement is executed independently.

  ## Usage

      # Start a temporary connection for migrations:
      AshScylla.Migrator.run("127.0.0.1:9042", [
        \"\"\"
        CREATE KEYSPACE IF NOT EXISTS my_app
        WITH REPLICATION = {'class': 'SimpleStrategy', 'replication_factor': 1}
        \"\"\",
        \"\"\"
        CREATE TABLE IF NOT EXISTS my_app.users (
          id UUID PRIMARY KEY,
          name TEXT
        )
        \"\"\"
      ])

  ## In a Mix task or release task:

      AshScylla.Migrator.run!(nodes, statements,
        keyspace: "my_app",
        connect_timeout: 10_000
      )
  """

  require Logger

  @doc """
  Executes a list of CQL statements against a ScyllaDB node.

  A temporary connection is started, all statements are executed sequentially,
  and the connection is stopped.

  Returns `{:ok, results}` or `{:error, {failed_index, reason}}`.
  """
  @spec run(String.t() | [String.t()], [String.t()], keyword()) ::
          {:ok, [term()]} | {:error, {non_neg_integer(), term()}}
  def run(nodes, statements, opts \\ []) when is_list(statements) do
    nodes = if is_binary(nodes), do: [nodes], else: nodes
    conn_name = :"ash_scylla_migrator_#{:erlang.unique_integer([:positive])}"

    conn_opts = [
      name: conn_name,
      nodes: nodes,
      connect_timeout: Keyword.get(opts, :connect_timeout, 10_000)
    ]

    with {:ok, _} <- AshScylla.Connection.start_link(conn_opts),
         {:ok, results} <- execute_statements(conn_name, statements, 1, []) do
      AshScylla.Connection.stop(conn_name)
      {:ok, Enum.reverse(results)}
    else
      {:error, reason} ->
        AshScylla.Connection.stop(conn_name)
        {:error, reason}
    end
  end

  @doc """
  Same as `run/3` but raises on error.
  """
  @spec run!(String.t() | [String.t()], [String.t()], keyword()) :: [term()] | no_return()
  def run!(nodes, statements, opts \\ []) do
    case run(nodes, statements, opts) do
      {:ok, results} ->
        results

      {:error, {index, reason}} ->
        raise "Migration statement #{index} failed: #{inspect(reason)}"
    end
  end

  @doc """
  Executes CQL statements against an existing named connection.
  """
  @spec run_on(atom(), [String.t()]) :: {:ok, [term()]} | {:error, {non_neg_integer(), term()}}
  def run_on(conn_name, statements) when is_list(statements) do
    case execute_statements(conn_name, statements, 1, []) do
      {:ok, results} -> {:ok, Enum.reverse(results)}
      {:error, _} = error -> error
    end
  end

  @spec run_on!(atom(), [String.t()]) :: [term()] | no_return()
  def run_on!(conn_name, statements) do
    case run_on(conn_name, statements) do
      {:ok, results} ->
        results

      {:error, {index, reason}} ->
        raise "Migration statement #{index} failed: #{inspect(reason)}"
    end
  end

  defp execute_statements(_conn_name, [], _index, acc), do: {:ok, acc}

  defp execute_statements(conn_name, [stmt | rest], index, acc) do
    Logger.info("AshScylla.Migrator: Executing statement #{index}")

    case AshScylla.Connection.query(conn_name, stmt, [], consistency: :quorum) do
      {:ok, result} ->
        execute_statements(conn_name, rest, index + 1, [result | acc])

      {:error, reason} ->
        Logger.error("AshScylla.Migrator: Statement #{index} failed: #{inspect(reason)}")
        {:error, {index, reason}}
    end
  end
end
