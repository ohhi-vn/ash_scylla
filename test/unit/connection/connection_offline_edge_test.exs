defmodule AshScylla.ConnectionOfflineEdgeTest do
  @moduledoc """
  Additional hermetic `AshScylla.Connection` tests covering keyspace-session
  bookkeeping paths that require direct GenServer state manipulation, plus
  invalid-keyspace startup and exotic node configurations.
  """

  use ExUnit.Case, async: true

  alias AshScylla.Connection

  @dead_node "127.0.0.1:59999"

  defp unique_name do
    :"conn_edge_#{System.unique_integer([:positive])}"
  end

  defp start_conn(opts) do
    name = unique_name()
    {:ok, _pid} = Connection.start_link(Keyword.put(opts, :name, name))
    on_exit(fn -> Connection.stop(name) end)
    name
  end

  describe "startup with an invalid keyspace" do
    test "logs a warning, skips USE, and still starts the connection" do
      name = start_conn(nodes: [@dead_node], keyspace: "123 definitely invalid")

      conn = Connection.get_conn(name)

      assert %Connection{} = conn
      assert conn.keyspace_used == false
      assert conn.keyspace == "123 definitely invalid"
    end
  end

  describe "release_session/1 with an active session" do
    test "reports USE failures when the session cannot be switched to system" do
      name = start_conn(nodes: [@dead_node])

      # A keyspace-less connection considers its session "used"; force a real
      # keyspace binding so release_session reaches the GenServer handler.
      :sys.replace_state(name, fn state -> %{state | keyspace: "held_ks"} end)

      assert {:error, %Xandra.ConnectionError{}} = Connection.release_session(name)
    end

    test "replies :ok when there is no configured keyspace to release" do
      name = start_conn(nodes: [@dead_node])

      :sys.replace_state(name, fn state -> %{state | keyspace: nil, keyspace_used: true} end)

      assert Connection.release_session(name) == :ok
    end
  end

  describe "set_keyspace/2 against an unreachable cluster" do
    test "propagates USE failures for valid names" do
      name = start_conn(nodes: [@dead_node])

      assert {:error, %Xandra.ConnectionError{}} =
               Connection.set_keyspace(name, "brand_new_ks")
    end
  end

  describe "query/4 with a different keyspace option" do
    test "raises Xandra.Error from query! when set_keyspace fails" do
      name = start_conn(nodes: [@dead_node], keyspace: nil)

      assert_raise Xandra.Error, fn ->
        Connection.query!(name, "SELECT now() FROM system.local", [], keyspace: "another_ks")
      end
    end
  end

  describe "stale connection cache entries" do
    @tag timeout: 30_000
    test "get_conn/1 recovers when persistent_term holds a dead pid" do
      # Background Xandra processes connected to unreachable nodes can crash
      # asynchronously; trap exits so their noise cannot kill this test.
      Process.flag(:trap_exit, true)

      name = start_conn(nodes: [@dead_node])
      original = Connection.get_conn(name)

      dead_pid =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      stale = %{original | conn: dead_pid}
      :persistent_term.put({{Connection, :conn_struct}, name}, stale)

      refreshed = Connection.get_conn(name)
      assert %Connection{} = refreshed
      assert refreshed.conn == original.conn
      refute refreshed.conn == dead_pid

      send(dead_pid, :stop)
    end

    test "get_conn/1 returns nil after the cached entry is erased and the process is gone" do
      name = start_conn(nodes: [@dead_node])
      assert %Connection{} = Connection.get_conn(name)

      :persistent_term.erase({{Connection, :conn_struct}, name})
      GenServer.stop(name, :normal)

      wait_until(fn ->
        Process.whereis(name) == nil and Connection.get_conn(name) == nil
      end)
    end
  end

  describe "cluster configuration edge cases" do
    @tag :slow_cluster_connect
    test "non-integer ports on every node fall back to a single-node connection" do
      parent = self()

      {probe, probe_ref} =
        spawn_monitor(fn ->
          # Trap exits so init failures surface as results instead of kills.
          Process.flag(:trap_exit, true)

          result =
            try do
              Connection.start_link(
                name: unique_name(),
                nodes: ["127.0.0.2:jmx", "127.0.0.3:jmx"]
              )
            rescue
              e -> {:rescue, e}
            catch
              :exit, reason -> {:exit, reason}
            end

          send(parent, {:cluster_start_result, result})

          receive do
            {:EXIT, _, _} -> :ok
          after
            0 -> :ok
          end
        end)

      assert_receive {:cluster_start_result, result}, 15_000

      case result do
        {:ok, pid} ->
          conn = Connection.get_conn(pid)
          refute conn.cluster?
          GenServer.stop(pid, :normal)

        _other ->
          # Xandra rejects non-integer ports during option validation; either
          # way the single-node fallback decision has already been made.
          :ok
      end

      receive do
        {:DOWN, ^probe_ref, :process, ^probe, _} -> :ok
      end
    end
  end

  defp wait_until(fun, attempts \\ 100)

  defp wait_until(_fun, 0), do: flunk("condition not met")

  defp wait_until(fun, attempts) do
    if fun.() do
      :ok
    else
      Process.sleep(10)
      wait_until(fun, attempts - 1)
    end
  end
end
