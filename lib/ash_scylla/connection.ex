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

defmodule AshScylla.Connection do
  @moduledoc """
  Direct Xandra connection wrapper for AshScylla.

  Replaces the Exandra/Ecto.Repo pattern. Manages a Xandra connection
  process and provides query/prepare operations.

  ## Usage

      # In your application supervision tree:
      children = [
        {AshScylla.Connection, name: MyApp.Scylla, nodes: ["127.0.0.1:9042"], keyspace: "my_app"}
      ]

      # Or start manually:
      {:ok, conn} = AshScylla.Connection.start_link(nodes: ["127.0.0.1:9042"], keyspace: "my_app")

  ## Options

  All options are passed through to `Xandra.start_link/1`. Key options:

  - `:name` - Register the connection under this name (required for supervised start)
  - `:nodes` - List of nodes, e.g. `["127.0.0.1:9042"]`
  - `:keyspace` - Keyspace to USE on connect
  """

  use GenServer

  defstruct [:conn, :keyspace, :nodes]

  @type t :: %__MODULE__{conn: pid(), keyspace: String.t() | nil, nodes: [String.t()]}

  # Client API

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.get(opts, :name)
    gen_server_opts = if name, do: [name: name], else: []
    GenServer.start_link(__MODULE__, opts, gen_server_opts)
  end

  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    name = Keyword.get(opts, :name, __MODULE__)

    %{
      id: name,
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :permanent,
      shutdown: 5_000
    }
  end

  @doc "Returns the connection struct by name (local or global)."
  @spec get_conn(module() | atom()) :: t() | nil
  def get_conn(name \\ __MODULE__) do
    case name do
      name when is_atom(name) ->
        case Process.whereis(name) do
          nil ->
            case :global.whereis_name(name) do
              :undefined -> nil
              pid -> GenServer.call(pid, :get_conn_struct, 5_000)
            end

          pid ->
            GenServer.call(pid, :get_conn_struct, 5_000)
        end

      _ ->
        nil
    end
  end

  @doc "Executes a simple or prepared query."
  @spec query(t() | module(), String.t(), list(), keyword()) :: {:ok, term()} | {:error, term()}
  def query(conn_or_name, query, params, opts \\ [])

  def query(%__MODULE__{conn: conn}, query, params, opts) do
    Xandra.execute(conn, query, params, opts)
  end

  def query(name, query, params, opts) when is_atom(name) do
    case get_conn(name) do
      nil -> {:error, :not_connected}
      conn -> query(conn, query, params, opts)
    end
  end

  @doc "Executes a simple or prepared query, raising on error."
  @spec query!(t() | module(), String.t(), list(), keyword()) :: term() | no_return()
  def query!(conn_or_name, query, params, opts \\ [])

  def query!(%__MODULE__{conn: conn}, query, params, opts) do
    Xandra.execute!(conn, query, params, opts)
  end

  def query!(name, query, params, opts) when is_atom(name) do
    case get_conn(name) do
      nil -> raise "No AshScylla connection found for #{inspect(name)}"
      conn -> query!(conn, query, params, opts)
    end
  end

  @doc "Prepares a CQL statement."
  @spec prepare(t() | module(), String.t(), keyword()) ::
          {:ok, Xandra.Prepared.t()} | {:error, term()}
  def prepare(conn_or_name, query, opts \\ [])

  def prepare(%__MODULE__{conn: conn}, query, opts) do
    Xandra.prepare(conn, query, opts)
  end

  def prepare(name, query, opts) when is_atom(name) do
    case get_conn(name) do
      nil -> {:error, :not_connected}
      conn -> prepare(conn, query, opts)
    end
  end

  @doc "Prepares a CQL statement, raising on error."
  @spec prepare!(t() | module(), String.t(), keyword()) :: Xandra.Prepared.t() | no_return()
  def prepare!(conn_or_name, query, opts \\ [])

  def prepare!(%__MODULE__{conn: conn}, query, opts) do
    Xandra.prepare!(conn, query, opts)
  end

  def prepare!(name, query, opts) when is_atom(name) do
    case get_conn(name) do
      nil -> raise "No AshScylla connection found for #{inspect(name)}"
      conn -> prepare!(conn, query, opts)
    end
  end

  @doc "Stops the connection."
  @spec stop(t() | module()) :: :ok
  def stop(%__MODULE__{conn: conn}) do
    Xandra.stop(conn)
  end

  def stop(name) when is_atom(name) do
    case get_conn(name) do
      nil -> :ok
      conn -> stop(conn)
    end
  end

  # Server callbacks

  @impl GenServer
  def init(opts) do
    keyspace = Keyword.get(opts, :keyspace)
    nodes = Keyword.get(opts, :nodes, ["127.0.0.1:9042"])
    name = Keyword.get(opts, :name)

    xandra_opts =
      [
        nodes: nodes
      ]
      |> maybe_put(:name, name)
      |> maybe_put(:keyspace, keyspace)
      |> Keyword.merge(
        Keyword.take(opts, [
          :connect_timeout,
          :authentication,
          :compressor,
          :encryption,
          :protocol_version,
          :transport_options,
          :backoff_min,
          :backoff_max,
          :backoff_type
        ])
      )

    case Xandra.start_link(xandra_opts) do
      {:ok, conn} ->
        {:ok, %__MODULE__{conn: conn, keyspace: keyspace, nodes: nodes}}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  @impl GenServer
  def handle_call(:get_conn_struct, _from, state) do
    {:reply, state, state}
  end
end
