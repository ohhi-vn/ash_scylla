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
          query(%__MODULE__{conn | keyspace: request_keyspace, keyspace_used: true}, query, params, opts)
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
  defp type_value(nil), do: nil
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
          query!(%__MODULE__{conn | keyspace: request_keyspace, keyspace_used: true}, query, params, opts)
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

    case Xandra.start_link(xandra_opts) do
      {:ok, conn} ->
        # Try to USE keyspace, but don't fail if it doesn't exist yet
        # (e.g. during first-time setup before create_keyspace runs)
        keyspace_used? =
          if keyspace do
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
    case Xandra.execute(conn, "USE #{new_keyspace}", []) do
      {:ok, _} ->
        Logger.info("AshScylla: Keyspace set to '#{new_keyspace}'")
        {:reply, {:ok, :set}, %{state | keyspace: new_keyspace, keyspace_used: true}}

      {:error, reason} ->
        Logger.warning("AshScylla: Failed to set keyspace '#{new_keyspace}': #{inspect(reason)}")
        {:reply, {:error, reason}, state}
    end
  end
end
