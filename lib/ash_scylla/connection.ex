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
  require Logger

  @moduledoc """
  Direct Xandra connection wrapper for AshScylla.

  Replaces the Exandra/Ecto.Repo pattern. Manages a Xandra connection
  process and provides query/prepare operations.

  Supports both single-node (`Xandra.start_link/1`) and multi-node
  (`Xandra.Cluster.start_link/1`) connections.

  ## Usage

  Single-node connection:

      # In your application supervision tree:
      children = [
        {AshScylla.Connection, name: MyApp.Scylla, nodes: ["127.0.0.1:9042"], keyspace: "my_app"}
      ]

      # Or start manually:
      {:ok, conn} = AshScylla.Connection.start_link(nodes: ["127.0.0.1:9042"], keyspace: "my_app")

  Multi-node cluster connection (all nodes must use the same port):

      children = [
        {AshScylla.Connection,
          name: MyApp.Scylla,
          nodes: ["scylla-1:9042", "scylla-2:9042", "scylla-3:9042"],
          keyspace: "my_app",
          pool_size: 10}
      ]

  ## Options

  All options are passed through to `Xandra.start_link/1` (single node) or
  `Xandra.Cluster.start_link/1` (multiple nodes). Key options:

  - `:name` - Register the connection under this name (required for supervised start)
  - `:nodes` - List of nodes, e.g. `["127.0.0.1:9042"]` or `[{"127.0.0.1", 9042}]`
  - `:keyspace` - Keyspace to USE on connect
  - `:pool_size` - Number of connections per node (cluster mode, default: 1)
  - `:connect_timeout` - Connection timeout in milliseconds (default: 5000)
  - `:autodiscovered_nodes_port` - Port for autodiscovered peers (default: 9042).
    When using a cluster with a non-standard port, this is auto-detected from
    the first node if all nodes share the same port.
  - `:sync_connect` - Wait for at least one connection before returning.
    Set to `false` for async connect (default: 5000ms timeout in cluster mode).

  ## Cluster Mode

  When multiple nodes are provided, `AshScylla.Connection` uses `Xandra.Cluster`
  for load balancing and fault tolerance.

  **Important:** Xandra.Cluster requires all nodes to share the same port.
  It uses a single `autodiscovered_nodes_port` for all discovered peers
  (Scylla/Cassandra `system.peers` does not advertise ports).

  If nodes have different ports, `AshScylla.Connection` falls back to a
  single-node connection to the first node and logs a warning.
  """

  use GenServer

  defstruct [:conn, :keyspace, :nodes, :keyspace_used]

  @type t :: %__MODULE__{
          conn: pid(),
          keyspace: String.t() | nil,
          nodes: [String.t()],
          keyspace_used: boolean()
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

  def query(%__MODULE__{conn: conn}, query, params, opts) do
    case Keyword.pop(opts, :keyspace) do
      {nil, opts} ->
        Xandra.execute(conn, query, typed_params(params), opts)

      {keyspace, opts} ->
        validate_keyspace!(keyspace)

        with {:ok, _} <- Xandra.execute(conn, "USE #{keyspace}", []) do
          Xandra.execute(conn, query, typed_params(params), opts)
        end
    end
  end

  def query(name, query, params, opts) when is_atom(name) do
    case get_conn(name) do
      nil ->
        {:error, :not_connected}

      %__MODULE__{} = conn ->
        # Set keyspace from opts if provided and different from current
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
          opts = Keyword.delete(opts, :keyspace)
          query(conn, query, params, opts)
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
  defp type_value(nil), do: {"text", nil}
  defp type_value(value) when is_list(value), do: {"list", value}
  defp type_value(value) when is_map(value), do: {"map", value}
  defp type_value(value), do: {"text", to_string(value)}

  defp type_struct(%DateTime{} = dt), do: {"timestamp", dt}
  defp type_struct(%Date{} = d), do: {"date", d}
  defp type_struct(%Time{} = t), do: {"time", t}
  defp type_struct(%Decimal{} = d), do: {"decimal", d}
  defp type_struct(other), do: {"text", to_string(other)}

  @doc "Executes a simple or prepared query, raising on error."
  @spec query!(t() | module(), String.t(), list(), keyword()) :: term() | no_return()
  def query!(conn_or_name, query, params, opts \\ [])

  def query!(%__MODULE__{conn: conn}, query, params, opts) do
    case Keyword.pop(opts, :keyspace) do
      {nil, opts} ->
        Xandra.execute!(conn, query, typed_params(params), opts)

      {keyspace, opts} ->
        validate_keyspace!(keyspace)

        with {:ok, _} <- Xandra.execute(conn, "USE #{keyspace}", []) do
          Xandra.execute!(conn, query, typed_params(params), opts)
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
          opts = Keyword.delete(opts, :keyspace)
          query!(conn, query, params, opts)
        end
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

  def prepare!(%__MODULE__{conn: conn}, query, opts) do
    Xandra.prepare!(conn, query, opts)
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

  @valid_keyspace_regex ~r/^[a-zA-Z_][a-zA-Z0-9_]{0,47}$/

  @doc false
  @spec validate_keyspace!(String.t()) :: :ok | no_return()
  def validate_keyspace!(keyspace) when is_binary(keyspace) do
    unless Regex.match?(@valid_keyspace_regex, keyspace) do
      raise ArgumentError,
            "Invalid keyspace name: #{inspect(keyspace)}. Keyspace names must match #{@valid_keyspace_regex.source}"
    end

    :ok
  end

  def validate_keyspace!(keyspace) do
    raise ArgumentError, "Keyspace name must be a string, got: #{inspect(keyspace)}"
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
  def stop(%__MODULE__{conn: conn}) do
    Xandra.stop(conn)
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

    xandra_opts =
      [
        nodes: nodes
      ]
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

    {start_fun, xandra_opts} =
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

          {&Xandra.Cluster.start_link/1, xandra_opts}
        else
          # Nodes have different ports — Xandra.Cluster can't handle this.
          # Fall back to a single-node connection to the first node.
          Logger.warning(
            "AshScylla: Nodes have different ports (#{inspect(ports)}). " <>
              "Xandra.Cluster requires all nodes to share the same port. " <>
              "Falling back to single-node connection to #{inspect(hd(nodes))}."
          )

          # Override nodes to only use the first node for single connection
          xandra_opts = Keyword.put(xandra_opts, :nodes, [hd(nodes)])
          {&Xandra.start_link/1, xandra_opts}
        end
      else
        {&Xandra.start_link/1, xandra_opts}
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

            case Xandra.execute(conn, "USE #{keyspace}", []) do
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
         %__MODULE__{conn: conn, keyspace: keyspace, nodes: nodes, keyspace_used: keyspace_used?}}

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
  def handle_call(:ensure_keyspace, _from, %__MODULE__{conn: conn, keyspace: keyspace} = state) do
    try do
      validate_keyspace!(keyspace)
    rescue
      ArgumentError ->
        {:reply, {:error, :invalid_keyspace}, state}
    end

    case Xandra.execute(conn, "USE #{keyspace}", []) do
      {:ok, _} ->
        Logger.info("AshScylla: Keyspace '#{keyspace}' is now active")
        {:reply, {:ok, :set}, %{state | keyspace_used: true}}

      {:error, reason} ->
        Logger.warning("AshScylla: Failed to set keyspace '#{keyspace}': #{inspect(reason)}")
        {:reply, {:error, reason}, state}
    end
  end

  @impl GenServer
  def handle_call({:set_keyspace, new_keyspace}, _from, %__MODULE__{conn: conn} = state) do
    try do
      validate_keyspace!(new_keyspace)
    rescue
      ArgumentError ->
        {:reply, {:error, :invalid_keyspace}, state}
    end

    case Xandra.execute(conn, "USE #{new_keyspace}", []) do
      {:ok, _} ->
        Logger.info("AshScylla: Keyspace set to '#{new_keyspace}'")
        {:reply, {:ok, :set}, %{state | keyspace: new_keyspace, keyspace_used: true}}

      {:error, reason} ->
        Logger.warning("AshScylla: Failed to set keyspace '#{new_keyspace}': #{inspect(reason)}")
        {:reply, {:error, reason}, state}
    end
  end

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
