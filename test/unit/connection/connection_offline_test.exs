defmodule AshScylla.ConnectionOfflineTest do
  @moduledoc """
  Hermetic tests for `AshScylla.Connection` that never touch a reachable
  ScyllaDB instance.

  Connections are started toward an unreachable node ("127.0.0.1:59999").
  Xandra connects asynchronously, so `start_link/1` succeeds immediately while
  every statement execution fails fast with `%Xandra.ConnectionError{}` —
  which is exactly what the error paths of `query/4`, `query!/4`, `prepare/3`,
  `release_session/1`, `set_keyspace/2`, and friends need.
  """

  use ExUnit.Case, async: true

  alias AshScylla.Connection

  @dead_node "127.0.0.1:59999"

  defp unique_name do
    :"conn_offline_#{System.unique_integer([:positive])}"
  end

  defp start_conn(opts) do
    name = unique_name()
    {:ok, _pid} = Connection.start_link(Keyword.put(opts, :name, name))
    on_exit(fn -> Connection.stop(name) end)
    name
  end

  describe "get_conn/1" do
    test "returns the cached struct for a started connection" do
      name = start_conn(nodes: [@dead_node])

      conn = Connection.get_conn(name)

      assert %Connection{} = conn
      assert conn.nodes == [@dead_node]
      assert conn.keyspace == nil
      assert conn.keyspace_used == true
      refute conn.cluster?

      second_read = Connection.get_conn(name)
      assert second_read.conn == conn.conn
    end

    test "returns nil for a non-atom name" do
      assert Connection.get_conn("not_an_atom") == nil
    end

    test "returns nil for an unregistered atom" do
      assert Connection.get_conn(:"never_started_#{System.unique_integer()}") == nil
    end

    test "resolves globally registered connections" do
      {:ok, pid} = Connection.start_link(nodes: [@dead_node])
      global_name = :"global_conn_#{System.unique_integer([:positive])}"
      :yes = :global.register_name(global_name, pid)

      on_exit(fn ->
        :global.unregister_name(global_name)

        if Process.alive?(pid) do
          GenServer.stop(pid, :normal, 5_000)
        end
      end)

      conn = Connection.get_conn(global_name)

      assert %Connection{} = conn
      assert is_pid(conn.conn)
      assert Process.alive?(conn.conn)
    end
  end

  describe "query/4 by connection name" do
    test "returns an error tuple when the node is unreachable" do
      name = start_conn(nodes: [@dead_node])

      assert {:error, %Xandra.ConnectionError{}} =
               Connection.query(name, "SELECT release_version FROM system.local", [])
    end

    test "propagates set_keyspace failures when opts request another keyspace" do
      name = start_conn(nodes: [@dead_node])

      assert {:error, %Xandra.ConnectionError{}} =
               Connection.query(name, "SELECT 1 FROM system.local", [], keyspace: "some_ks")
    end
  end

  describe "query/4 by connection struct" do
    test "falls back to executing the statement when USE fails" do
      name = start_conn(nodes: [@dead_node])
      conn = Connection.get_conn(name)

      assert {:error, %Xandra.ConnectionError{}} =
               Connection.query(conn, "CREATE TABLE some_ks.t (id UUID)", [], keyspace: "some_ks")
    end

    test "skips the redundant USE round-trip for qualified statements" do
      name = start_conn(nodes: [@dead_node])
      %{conn: xandra_pid} = Connection.get_conn(name)

      conn = %Connection{
        conn: xandra_pid,
        keyspace: "qualified_ks",
        nodes: [@dead_node],
        keyspace_used: true,
        cluster?: false
      }

      assert {:error, %Xandra.ConnectionError{}} =
               Connection.query(conn, "SELECT * FROM qualified_ks.users", [],
                 keyspace: "qualified_ks"
               )
    end

    test "raises ArgumentError for an invalid keyspace option" do
      name = start_conn(nodes: [@dead_node])
      conn = Connection.get_conn(name)

      assert_raise ArgumentError, fn ->
        Connection.query(conn, "SELECT 1", [], keyspace: "123invalid")
      end
    end
  end

  describe "query/4 param typing" do
    test "atoms are tagged as text via to_string" do
      assert Connection.typed_params([:ready]) == [{"text", "ready"}]
    end
  end

  describe "query!/4" do
    test "raises when no connection is registered under the name" do
      assert_raise RuntimeError, ~r/No AshScylla connection found/, fn ->
        Connection.query!(:"missing_#{System.unique_integer()}", "SELECT 1", [])
      end
    end

    test "raises when the statement cannot reach a node" do
      name = start_conn(nodes: [@dead_node])

      assert_raise Xandra.ConnectionError, fn ->
        Connection.query!(name, "SELECT release_version FROM system.local", [])
      end
    end

    test "raises Xandra.Error when switching to an invalid keyspace" do
      name = start_conn(nodes: [@dead_node])

      assert_raise Xandra.Error, fn ->
        Connection.query!(name, "SELECT 1", [], keyspace: "123invalid")
      end
    end

    test "raises through the struct clause when USE and the statement fail" do
      name = start_conn(nodes: [@dead_node])
      conn = Connection.get_conn(name)

      assert_raise Xandra.ConnectionError, fn ->
        Connection.query!(conn, "CREATE TABLE other_ks.t (id UUID)", [], keyspace: "other_ks")
      end
    end
  end

  describe "query_all/4" do
    test "returns {:error, :not_connected} for an unregistered name" do
      assert Connection.query_all(:"missing_#{System.unique_integer()}", "SELECT 1", []) ==
               {:error, :not_connected}
    end

    test "propagates execution errors for registered connections" do
      name = start_conn(nodes: [@dead_node])

      assert {:error, %Xandra.ConnectionError{}} =
               Connection.query_all(name, "SELECT release_version FROM system.local", [])
    end
  end

  describe "prepare/3 and prepare!/3" do
    test "prepare returns {:error, :not_connected} for an unregistered name" do
      assert Connection.prepare(:"missing_#{System.unique_integer()}", "SELECT 1") ==
               {:error, :not_connected}
    end

    test "prepare returns the execution error for a dead connection" do
      name = start_conn(nodes: [@dead_node])

      assert {:error, %Xandra.ConnectionError{}} =
               Connection.prepare(name, "SELECT release_version FROM system.local")
    end

    test "prepare! raises when no connection is registered" do
      assert_raise RuntimeError, ~r/No AshScylla connection found/, fn ->
        Connection.prepare!(:"missing_#{System.unique_integer()}", "SELECT 1")
      end
    end

    test "prepare! raises the preparation error for a dead connection" do
      name = start_conn(nodes: [@dead_node])

      assert_raise Xandra.ConnectionError, fn ->
        Connection.prepare!(name, "SELECT release_version FROM system.local")
      end
    end
  end

  describe "set_keyspace/2 and reconnect_keyspace/1" do
    test "set_keyspace rejects invalid keyspace names without touching the network" do
      name = start_conn(nodes: [@dead_node])

      assert Connection.set_keyspace(name, "123invalid") == {:error, :invalid_keyspace}
    end

    test "reconnect_keyspace reports when no keyspace is configured" do
      name = start_conn(nodes: [@dead_node])

      assert Connection.reconnect_keyspace(name) == {:error, :no_keyspace_configured}
    end

    test "reconnect_keyspace propagates USE failures" do
      name = start_conn(nodes: [@dead_node], keyspace: "offline_ks")

      assert {:error, %Xandra.ConnectionError{}} = Connection.reconnect_keyspace(name)
    end
  end

  describe "release_session/1" do
    test "is a no-op for unknown names" do
      assert Connection.release_session(:"missing_#{System.unique_integer()}") == :ok
    end

    test "replies :ok when the connection holds no keyspace session" do
      name = start_conn(nodes: [@dead_node])

      assert Connection.release_session(name) == :ok
    end

    test "switches to system and reports failure when USE system cannot run" do
      name = start_conn(nodes: [@dead_node], keyspace: "held_ks")

      assert Connection.get_conn(name).keyspace_used == false
      assert Connection.release_session(name) == :ok
    end
  end

  describe "stop/1 and termination" do
    test "stops a running connection and clears the cache" do
      name = start_conn(nodes: [@dead_node])
      assert %Connection{} = Connection.get_conn(name)

      assert Connection.stop(name) == :ok
      wait_until(fn -> Connection.get_conn(name) == nil end)

      refute Process.whereis(name)
    end

    test "is idempotent for unknown names" do
      assert Connection.stop(:"missing_#{System.unique_integer()}") == :ok
    end
  end

  describe "node format handling" do
    test "{host, port} tuples are converted and parsed" do
      name = start_conn(nodes: [{"127.0.0.1", 59_996}])

      conn = Connection.get_conn(name)

      assert conn.nodes == ["127.0.0.1:59996"]
      refute conn.cluster?
    end

    test "non-string nodes fall back to to_string" do
      name = start_conn(nodes: [:loopback])

      assert %Connection{} = Connection.get_conn(name)
    end

    test "host-only strings parse without a port" do
      name = start_conn(nodes: ["localhost"])

      assert Connection.get_conn(name).nodes == ["localhost"]
    end

    test "non-integer ports leave the host portless during node parsing" do
      # The second node has a non-integer port, which forces the different-port
      # fallback (parsed as {host, nil}); the connection then uses the first
      # node only.
      name = start_conn(nodes: ["localhost:59994", "otherhost:jmx"])

      conn = Connection.get_conn(name)

      refute conn.cluster?
      assert conn.nodes == ["localhost:59994", "otherhost:jmx"]
    end
  end

  describe "cluster configuration" do
    test "multiple nodes on different ports fall back to single-node Xandra" do
      name =
        start_conn(nodes: ["127.0.0.1:59997", "127.0.0.1:59998"])

      conn = Connection.get_conn(name)

      refute conn.cluster?
      assert conn.nodes == ["127.0.0.1:59997", "127.0.0.1:59998"]
    end

    @tag :slow_cluster_connect
    test "same-port clusters fail with :sync_connect_timeout when unreachable" do
      parent = self()

      {probe, probe_ref} =
        spawn_monitor(fn ->
          Process.flag(:trap_exit, true)

          result =
            try do
              Connection.start_link(
                name: unique_name(),
                nodes: ["127.0.0.1:59995", "127.0.0.2:59995"],
                pool_size: 2
              )
            catch
              :exit, reason -> reason
            end

          send(parent, {:cluster_start_result, result})
        end)

      assert_receive {:cluster_start_result, {:error, :sync_connect_timeout}}, 10_000

      receive do
        {:DOWN, ^probe_ref, :process, ^probe, _} -> :ok
      end
    end
  end

  defp wait_until(fun, attempts \\ 50)

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
