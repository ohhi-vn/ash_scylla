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
  GenServer wrapper for Xandra connections.

  Provides a process-based connection to ScyllaDB/Cassandra via Xandra,
  supporting both single-node and cluster connection modes.

  ## Usage

      {:ok, pid} = AshScylla.Connection.start_link(nodes: ["127.0.0.1:9042"])
      AshScylla.Connection.query(pid, "SELECT * FROM system.local", [])
      AshScylla.Connection.stop(pid)

  ## Options

  - `:name` — Register the connection under a name (for `get_conn/1`)
  - `:nodes` — List of ScyllaDB nodes
  - `:keyspace` — Default keyspace for the connection
  - `:connect_timeout` — TCP connection timeout in ms (default: 5000)

  ## Cluster Mode

  When multiple nodes are provided, Xandra.Cluster is used for
  automatic node discovery and load balancing.

  ### Single-node connection

      children = [
        {AshScylla.Connection, name: MyApp.Scylla, nodes: ["127.0.0.1:9042"], keyspace: "my_app"}
      ]

      {:ok, conn} = AshScylla.Connection.start_link(nodes: ["127.0.0.1:9042"], keyspace: "my_app")

  ### Multi-node cluster connection

  All nodes must use the same port:

      children = [
        {AshScylla.Connection,
          name: MyApp.Scylla,
          nodes: ["scylla-1:9042", "scylla-2:9042", "scylla-3:9042"],
          keyspace: "my_app",
          pool_size: 10}
      ]

  ### Cluster Mode Details

  When multiple nodes are provided, `AshScylla.Connection` uses `Xandra.Cluster`
  for load balancing and fault tolerance.

  **Important:** Xandra.Cluster requires all nodes to share the same port.
  It uses a single `autodiscovered_nodes_port` for all discovered peers
  (Scylla/Cassandra `system.peers` does not advertise ports).

  If nodes have different ports, `AshScylla.Connection` falls back to a
  single-node connection to the first node and logs a warning.
  """
  require Logger

  use GenServer

  defstruct [:conn, :keyspace, :nodes, :keyspace_used, :cluster?]

  @type t :: %__MODULE__{
          conn: pid(),
          keyspace: String.t() | nil,
          nodes: [String.t()],
          keyspace_used: boolean(),
          cluster?: boolean()
        }

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
    try do
      case name do
        name when is_atom(name) ->
          case Process.whereis(name) do
            nil ->
              case :global.whereis_name(name) do
                :undefined -> nil
                pid -> do_get_conn(pid)
              end

            pid ->
              do_get_conn(pid)
          end

        _ ->
          nil
      end
    rescue
      _ -> nil
    catch
      _, _ -> nil
    end
  end

  defp do_get_conn(pid) do
    case Process.alive?(pid) do
      true -> GenServer.call(pid, :get_conn_struct, 5_000)
      false -> nil
    end
  end

  @doc """
  Executes a simple or prepared query.

  Automatically types simple query values for Xandra 0.19.x compatibility.
  Xandra requires typed `{type_string, value}` tuples for simple query parameters,
  so we wrap raw Elixir values in their appropriate CQL type annotations.
  """
  @spec query(t() | module(), String.t(), list(), keyword()) :: {:ok, term()} | {:error, term()}
  def query(conn_or_name, query, params, opts \\ [])

  def query(%__MODULE__{conn: conn, cluster?: cluster?}, query, params, opts) do
    case Keyword.pop(opts, :keyspace) do
      {nil, opts} ->
        execute_module(cluster?).execute(conn, query, typed_params(params), opts)

      {keyspace, opts} ->
        validate_keyspace!(keyspace)

        # Try USE first, but if it fails (e.g. keyspace doesn't exist yet),
        # still attempt the actual statement. Statements like CREATE KEYSPACE
        # don't require keyspace context; if the statement itself needs a
        # keyspace, it will fail with its own descriptive error.
        case execute_module(cluster?).execute(conn, "USE #{keyspace}", []) do
          {:ok, _} ->
            execute_module(cluster?).execute(conn, query, typed_params(params), opts)

          {:error, _} ->
            execute_module(cluster?).execute(conn, query, typed_params(params), opts)
        end
    end
  end

  def query(name, query, params, opts) when is_atom(name) do
    case get_conn(name) do
      nil ->
        {:error, :not_connected}

      %__MODULE__{} = conn ->
        request_keyspace = Keyword.get(opts, :keyspace)

        if request_keyspace && request_keyspace != conn.keyspace do
          GenServer.call(name, {:set_keyspace, request_keyspace}, 5_000)
          opts = Keyword.delete(opts, :keyspace)

          query(
            %__MODULE__{conn | keyspace: request_keyspace, keyspace_used: true},
            query,
            params,
            opts
          )
        else
          ensure_keyspace!(conn, name)

          # Re-fetch connection to get updated `keyspace_used` state after
          # `ensure_keyspace!` (the GenServer may have tried `USE keyspace`
          # again and updated the state).
          updated_conn = get_conn(name) || conn

          # Always keep keyspace in opts so `query/4` re-issues `USE keyspace`
          # before each statement. This guarantees the correct keyspace context
          # for every statement regardless of connection type (single-node or
          # cluster) or whether a prior `USE` appeared to succeed.
          opts = opts

          query(updated_conn, query, params, opts)
        end
    end
  end

  @doc """
  Converts raw Elixir values to typed Xandra params.

  Xandra 0.19.x requires simple query values to be `{type_string, value}` tuples.
  This function infers the CQL type from the Elixir type.
  """
  @spec typed_params(list()) :: list()
  def typed_params(params) when is_list(params) do
    Enum.map(params, &type_value/1)
  end

  def typed_params(params), do: params

  defp type_value({type_str, _value} = typed) when is_binary(type_str), do: typed
  defp type_value(%_{} = struct), do: type_struct(struct)
  defp type_value(value) when is_binary(value), do: {"text", value}

  defp type_value(value) when is_integer(value), do: {"bigint", value}
  defp type_value(value) when is_float(value), do: {"double", value}
  defp type_value(true), do: {"boolean", true}
  defp type_value(false), do: {"boolean", false}
  defp type_value(nil), do: nil
  defp type_value(%MapSet{} = value), do: {"set<text>", value}
  defp type_value(value) when is_list(value), do: {"list<text>", value}
  defp type_value(value) when is_map(value), do: {"map<text, text>", value}
  defp type_value(value), do: {"text", to_string(value)}

  defp type_struct(%DateTime{} = dt), do: {"timestamp", dt}
  defp type_struct(%Date{} = d), do: {"date", d}
  defp type_struct(%Time{} = t), do: {"time", t}
  defp type_struct(%Decimal{} = d), do: {"decimal", d}
  defp type_struct(other), do: {"text", to_string(other)}

  @doc "Executes a simple or prepared query, raising on error."
  @spec query!(t() | module(), String.t(), list(), keyword()) :: term() | no_return()
  def query!(conn_or_name, query, params, opts \\ [])

  def query!(%__MODULE__{conn: conn, cluster?: cluster?}, query, params, opts) do
    case Keyword.pop(opts, :keyspace) do
      {nil, opts} ->
        execute_module(cluster?).execute!(conn, query, typed_params(params), opts)

      {keyspace, opts} ->
        validate_keyspace!(keyspace)

        case execute_module(cluster?).execute(conn, "USE #{keyspace}", []) do
          {:ok, _} ->
            execute_module(cluster?).execute!(conn, query, typed_params(params), opts)

          {:error, _} ->
            execute_module(cluster?).execute!(conn, query, typed_params(params), opts)
        end
    end
  end

  def query!(name, query, params, opts) when is_atom(name) do
    case get_conn(name) do
      nil ->
        raise "No AshScylla connection found for #{inspect(name)}"

      %__MODULE__{} = conn ->
        request_keyspace = Keyword.get(opts, :keyspace)

        if request_keyspace && request_keyspace != conn.keyspace do
          GenServer.call(name, {:set_keyspace, request_keyspace}, 5_000)
          opts = Keyword.delete(opts, :keyspace)

          query!(
            %__MODULE__{conn | keyspace: request_keyspace, keyspace_used: true},
            query,
            params,
            opts
          )
        else
          ensure_keyspace!(conn, name)

          updated_conn = get_conn(name) || conn

          opts =
            if updated_conn.cluster? or not updated_conn.keyspace_used do
              opts
            else
              Keyword.delete(opts, :keyspace)
            end

          query!(updated_conn, query, params, opts)
        end
    end
  end

  @doc "Prepares a CQL statement."
  @spec prepare(t() | module(), String.t(), keyword()) ::
          {:ok, Xandra.Prepared.t()} | {:error, term()}
  def prepare(conn_or_name, query, opts \\ [])

  def prepare(%__MODULE__{conn: conn, cluster?: cluster?}, query, opts) do
    prepare_module(cluster?).prepare(conn, query, opts)
  end

  def prepare(name, query, opts) when is_atom(name) do
    case get_conn(name) do
      nil ->
        {:error, :not_connected}

      conn ->
        ensure_keyspace!(conn, name)
        prepare(conn, query, opts)
    end
  end

  @doc "Prepares a CQL statement, raising on error."
  @spec prepare!(t() | module(), String.t(), keyword()) :: Xandra.Prepared.t() | no_return()
  def prepare!(conn_or_name, query, opts \\ [])

  def prepare!(%__MODULE__{conn: conn, cluster?: cluster?}, query, opts) do
    prepare_module(cluster?).prepare!(conn, query, opts)
  end

  def prepare!(name, query, opts) when is_atom(name) do
    case get_conn(name) do
      nil ->
        raise "No AshScylla connection found for #{inspect(name)}"

      conn ->
        ensure_keyspace!(conn, name)
        prepare!(conn, query, opts)
    end
  end

  @doc "Ensures the keyspace is selected. Retries USE if not yet applied."
  def ensure_keyspace!(conn, name) when is_atom(name) do
    if conn.keyspace != nil and not conn.keyspace_used do
      GenServer.call(name, :ensure_keyspace, 5_000)
    end

    conn
  end

  def ensure_keyspace!(conn, _name) do
    conn
  end

  @doc false
  @spec validate_keyspace!(String.t()) :: :ok | no_return()
  def validate_keyspace!(keyspace) do
    AshScylla.Identifier.validate_keyspace!(keyspace)
    :ok
  end

  @doc """
  Sets the keyspace to use. Useful when the keyspace is created after connection start.
  Returns `{:ok, :set}` or `{:error, reason}`.
  """
  @spec set_keyspace(atom(), String.t()) :: {:ok, :set} | {:error, term()}
  def set_keyspace(name, keyspace) when is_atom(name) do
    GenServer.call(name, {:set_keyspace, keyspace}, 5_000)
  end

  @doc """
  Reconnects to the keyspace. Useful after the keyspace has been created.
  Returns `{:ok, :set}` or `{:error, reason}`.
  """
  @spec reconnect_keyspace(atom()) :: {:ok, :set} | {:error, term()}
  def reconnect_keyspace(name) when is_atom(name) do
    GenServer.call(name, :ensure_keyspace, 5_000)
  end

  @doc "Stops the connection."
  @spec stop(t() | module()) :: :ok
  def stop(%__MODULE__{conn: conn, cluster?: cluster?}) do
    stop_module(cluster?).stop(conn)
  end

  def stop(name) when is_atom(name) do
    case get_conn(name) do
      nil ->
        :ok

      _conn ->
        try do
          GenServer.stop(name)
        rescue
          _ -> :ok
        catch
          _, _ -> :ok
        end
    end
  end

  # Server callbacks

  @impl GenServer
  def init(opts) do
    keyspace = Keyword.get(opts, :keyspace)
    nodes = Keyword.get(opts, :nodes, ["127.0.0.1:9042"])

    # Parse node addresses to extract host/port tuples
    parsed_nodes = Enum.map(nodes, &parse_node/1)

    # Convert tuple format nodes to "host:port" strings for Xandra
    nodes_as_strings =
      Enum.map(nodes, fn
        {host, port} when is_binary(host) and is_integer(port) -> "#{host}:#{port}"
        node when is_binary(node) -> node
        node -> to_string(node)
      end)

    xandra_opts =
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
      |> Keyword.put(:nodes, nodes_as_strings)

    {start_fun, xandra_opts, cluster?} =
      if length(nodes) > 1 do
        # Check if all nodes use the same port. Xandra.Cluster uses a single
        # autodiscovered_nodes_port for all peers, so mixed-port clusters
        # won't work properly with Xandra.Cluster.
        ports = Enum.map(parsed_nodes, &elem(&1, 1))

        if length(Enum.uniq(ports)) == 1 do
          # All nodes share the same port — safe to use Xandra.Cluster.
          # Auto-detect the port from the first node.
          xandra_opts =
            if Keyword.has_key?(xandra_opts, :autodiscovered_nodes_port) do
              xandra_opts
            else
              case parsed_nodes do
                [{_host, port} | _] when is_integer(port) ->
                  Keyword.put(xandra_opts, :autodiscovered_nodes_port, port)

                _ ->
                  xandra_opts
              end
            end

          # Use sync_connect to ensure at least one connection is established
          # before returning. This prevents the pool from staying in :never_connected
          # and crashing with FunctionClauseError on unhandled events.
          xandra_opts =
            if Keyword.has_key?(xandra_opts, :sync_connect) do
              xandra_opts
            else
              Keyword.put(xandra_opts, :sync_connect, 5_000)
            end

          {&Xandra.Cluster.start_link/1, xandra_opts, true}
        else
          # Nodes have different ports — Xandra.Cluster can't handle this.
          # Fall back to a single-node connection to the first node.
          Logger.warning(
            "AshScylla: Nodes have different ports (#{inspect(ports)}). " <>
              "Xandra.Cluster requires all nodes to share the same port. " <>
              "Falling back to single-node connection to #{inspect(hd(nodes))}."
          )

          # Override nodes to only use the first node for single connection
          xandra_opts = Keyword.put(xandra_opts, :nodes, [hd(nodes_as_strings)])
          {&Xandra.start_link/1, xandra_opts, false}
        end
      else
        {&Xandra.start_link/1, xandra_opts, false}
      end

    case start_fun.(xandra_opts) do
      {:ok, conn} ->
        # Try to USE keyspace, but don't fail if it doesn't exist yet
        # (e.g. during first-time setup before create_keyspace runs)
        keyspace_used? =
          if keyspace do
            # Validate keyspace name before use (defense-in-depth)
            try do
              validate_keyspace!(keyspace)
            rescue
              ArgumentError ->
                Logger.warning(
                  "AshScylla: Invalid keyspace name: #{inspect(keyspace)}, skipping USE"
                )

                false
            end

            case execute_module(cluster?).execute(conn, "USE #{keyspace}", []) do
              {:ok, _} ->
                Logger.info(
                  "AshScylla: Connected to ScyllaDB at #{inspect(nodes)}, keyspace: #{keyspace}"
                )

                true

              {:error, reason} ->
                Logger.warning(
                  "AshScylla: Connected to ScyllaDB at #{inspect(nodes)} but keyspace '#{keyspace}' not available: #{inspect(reason)}. " <>
                    "This is expected before keyspace creation. Will retry on first query."
                )

                false
            end
          else
            Logger.info(
              "AshScylla: Connected to ScyllaDB at #{inspect(nodes)}, no keyspace configured"
            )

            true
          end

        {:ok,
         %__MODULE__{
           conn: conn,
           keyspace: keyspace,
           nodes: nodes_as_strings,
           keyspace_used: keyspace_used?,
           cluster?: cluster?
         }}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl GenServer
  def handle_call(:get_conn_struct, _from, state) do
    {:reply, state, state}
  end

  @impl GenServer
  def handle_call(:ensure_keyspace, _from, %__MODULE__{keyspace: nil} = state) do
    {:reply, {:error, :no_keyspace_configured}, state}
  end

  @impl GenServer
  def handle_call(
        :ensure_keyspace,
        _from,
        %__MODULE__{conn: conn, keyspace: keyspace, cluster?: cluster?} = state
      ) do
    try do
      validate_keyspace!(keyspace)
    rescue
      ArgumentError ->
        {:reply, {:error, :invalid_keyspace}, state}
    end

    case execute_module(cluster?).execute(conn, "USE #{keyspace}", []) do
      {:ok, _} ->
        Logger.info("AshScylla: Keyspace '#{keyspace}' is now active")
        {:reply, {:ok, :set}, %{state | keyspace_used: true}}

      {:error, reason} ->
        Logger.warning("AshScylla: Failed to set keyspace '#{keyspace}': #{inspect(reason)}")
        {:reply, {:error, reason}, state}
    end
  end

  @impl GenServer
  def handle_call(
        {:set_keyspace, new_keyspace},
        _from,
        %__MODULE__{conn: conn, cluster?: cluster?} = state
      ) do
    try do
      validate_keyspace!(new_keyspace)
    rescue
      ArgumentError ->
        {:reply, {:error, :invalid_keyspace}, state}
    end

    case execute_module(cluster?).execute(conn, "USE #{new_keyspace}", []) do
      {:ok, _} ->
        Logger.info("AshScylla: Keyspace set to '#{new_keyspace}'")
        {:reply, {:ok, :set}, %{state | keyspace: new_keyspace, keyspace_used: true}}

      {:error, reason} ->
        Logger.warning("AshScylla: Failed to set keyspace '#{new_keyspace}': #{inspect(reason)}")
        {:reply, {:error, reason}, state}
    end
  end

  @doc false
  # Dispatches to Xandra or Xandra.Cluster based on connection type.
  def execute_module(true), do: Xandra.Cluster
  def execute_module(_), do: Xandra

  @doc false
  def prepare_module(true), do: Xandra.Cluster
  def prepare_module(_), do: Xandra

  @doc false
  def stop_module(true), do: Xandra.Cluster
  def stop_module(_), do: Xandra

  # Parses a node string like "127.0.0.1:9042" or "host:port" into {host, port}.
  # Returns {host, nil} if no port is specified.
  defp parse_node(node) when is_binary(node) do
    case String.split(node, ":", parts: 2) do
      [host, port_str] ->
        case Integer.parse(port_str) do
          {port, ""} -> {host, port}
          _ -> {host, nil}
        end

      [host] ->
        {host, nil}
    end
  end

  defp parse_node({host, port}) when is_binary(host) and is_integer(port) do
    {host, port}
  end

  defp parse_node(node), do: {to_string(node), nil}
end
