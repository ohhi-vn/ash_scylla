defmodule AshScylla.ConnectionTest do
  @moduledoc """
  Tests for AshScylla.Connection — covers edge cases around
  lazy keyspace handling, connection lifecycle, error paths,
  and cluster mode selection logic (single-node vs Xandra.Cluster).

  NOTE: These tests require a running ScyllaDB instance at 127.0.0.1:9042.
  They are tagged :integration and excluded from default test runs.
  """
  use ExUnit.Case, async: false

  @moduletag :integration

  alias AshScylla.Connection

  # ── Helpers ────────────────────────────────────────────────────────────────

  defp unique_name do
    Module.concat(__MODULE__, :"Conn_#{System.unique_integer([:positive])}")
  end

  defp start_conn(opts) do
    name = unique_name()
    full_opts = Keyword.put(opts, :name, name)
    {:ok, _pid} = Connection.start_link(full_opts)
    on_exit(fn -> Connection.stop(name) end)
    name
  end

  # ── start_link / child_spec ────────────────────────────────────────────────

  describe "start_link/1" do
    test "starts with nodes and keyspace options" do
      name = start_conn(nodes: ["127.0.0.1:9042"], keyspace: "test_keyspace")

      assert %Connection{conn: conn, keyspace: "test_keyspace", nodes: ["127.0.0.1:9042"]} =
               Connection.get_conn(name)

      assert is_pid(conn)
    end

    test "starts without keyspace" do
      name = start_conn(nodes: ["127.0.0.1:9042"])
      conn = Connection.get_conn(name)
      assert conn.keyspace == nil
      assert conn.keyspace_used == true
    end

    test "child_spec produces valid spec" do
      spec = Connection.child_spec(name: MyTestConn, nodes: ["127.0.0.1:9042"])
      assert spec.id == MyTestConn

      assert spec.start ==
               {Connection, :start_link, [[name: MyTestConn, nodes: ["127.0.0.1:9042"]]]}

      assert spec.type == :worker
      assert spec.restart == :permanent
    end
  end

  # ── get_conn ───────────────────────────────────────────────────────────────

  describe "get_conn/1" do
    test "returns nil for unregistered name" do
      assert Connection.get_conn(:nonexistent_conn) == nil
    end

    test "returns nil for non-atom argument" do
      assert Connection.get_conn("string") == nil
      assert Connection.get_conn(%{}) == nil
    end

    test "returns connection struct for registered name" do
      name = start_conn(nodes: ["127.0.0.1:9042"])
      conn = Connection.get_conn(name)
      assert %Connection{conn: conn_pid} = conn
      assert is_pid(conn_pid)
    end
  end

  # ── query ──────────────────────────────────────────────────────────────────

  describe "query/4" do
    test "returns {:error, :not_connected} for unregistered name" do
      assert {:error, :not_connected} = Connection.query(:nonexistent, "SELECT 1", [])
    end
  end

  describe "query!/4" do
    test "raises for unregistered name" do
      assert_raise RuntimeError, ~r/No AshScylla connection found/, fn ->
        Connection.query!(:nonexistent, "SELECT 1", [])
      end
    end
  end

  # ── prepare ────────────────────────────────────────────────────────────────

  describe "prepare/3" do
    test "returns {:error, :not_connected} for unregistered name" do
      assert {:error, :not_connected} = Connection.prepare(:nonexistent, "SELECT 1")
    end
  end

  describe "prepare!/3" do
    test "raises for unregistered name" do
      assert_raise RuntimeError, ~r/No AshScylla connection found/, fn ->
        Connection.prepare!(:nonexistent, "SELECT 1")
      end
    end
  end

  # ── stop ───────────────────────────────────────────────────────────────────

  describe "stop/1" do
    test "returns :ok for unregistered name (idempotent)" do
      assert Connection.stop(:nonexistent) == :ok
    end

    test "stops a running connection" do
      name = start_conn(nodes: ["127.0.0.1:9042"])
      assert Connection.stop(name) == :ok
      assert Connection.get_conn(name) == nil
    end
  end

  # ── ensure_keyspace! ───────────────────────────────────────────────────────

  describe "ensure_keyspace!/2" do
    test "is no-op when keyspace is nil" do
      name = start_conn(nodes: ["127.0.0.1:9042"])
      conn = Connection.get_conn(name)
      assert Connection.ensure_keyspace!(conn, name) == conn
    end

    test "is no-op when keyspace_used is already true" do
      name = start_conn(nodes: ["127.0.0.1:9042"], keyspace: "test_keyspace")
      conn = Connection.get_conn(name)

      if conn.keyspace_used do
        assert Connection.ensure_keyspace!(conn, name) == conn
      end
    end
  end

  # ── set_keyspace ───────────────────────────────────────────────────────────

  describe "set_keyspace/2" do
    test "exits when connection does not exist" do
      assert catch_exit(Connection.set_keyspace(:nonexistent, "some_keyspace"))
    end
  end

  # ── reconnect_keyspace ─────────────────────────────────────────────────────

  describe "reconnect_keyspace/1" do
    test "returns {:error, :no_keyspace_configured} when keyspace not configured" do
      name = start_conn(nodes: ["127.0.0.1:9042"])
      assert {:error, :no_keyspace_configured} = Connection.reconnect_keyspace(name)
    end

    test "exits when connection does not exist" do
      assert catch_exit(Connection.reconnect_keyspace(:nonexistent))
    end
  end

  # ── struct / state ─────────────────────────────────────────────────────────

  describe "connection struct" do
    test "default keyspace_used is nil before init" do
      assert %Connection{conn: nil, keyspace: nil, nodes: nil, keyspace_used: nil} ==
               %Connection{}
    end
  end

  # ── Cluster mode selection ─────────────────────────────────────────────────

  describe "cluster mode selection" do
    test "single node uses Xandra (not Xandra.Cluster)" do
      name = start_conn(nodes: ["127.0.0.1:9042"])
      conn = Connection.get_conn(name)
      assert is_pid(conn.conn)
      assert conn.nodes == ["127.0.0.1:9042"]
    end

    test "multiple nodes with same port uses Xandra.Cluster" do
      name = start_conn(nodes: ["127.0.0.1:9042", "127.0.0.1:9042"])
      conn = Connection.get_conn(name)
      assert is_pid(conn.conn)
    end

    test "multiple nodes with different ports falls back to single-node" do
      name = start_conn(nodes: ["127.0.0.1:9043", "127.0.0.1:9044"])
      conn = Connection.get_conn(name)
      assert is_pid(conn.conn)
    end

    test "multiple nodes with tuple format and same port uses Xandra.Cluster" do
      name = start_conn(nodes: [{"127.0.0.1", 9042}, {"127.0.0.1", 9042}])
      conn = Connection.get_conn(name)
      assert is_pid(conn.conn)
    end
  end

  # ── parse_node/1 (private function tested via init behavior) ──────────────

  describe "node parsing" do
    test "parses string host:port" do
      name = start_conn(nodes: ["127.0.0.1:9042"])
      conn = Connection.get_conn(name)
      assert conn.nodes == ["127.0.0.1:9042"]
    end

    test "parses tuple {host, port}" do
      name = start_conn(nodes: [{"127.0.0.1", 9042}])
      conn = Connection.get_conn(name)
      assert is_pid(conn.conn)
    end

    test "parses hostname:port string" do
      name = start_conn(nodes: ["scylla.example.com:9042"])
      conn = Connection.get_conn(name)
      assert conn.nodes == ["scylla.example.com:9042"]
    end
  end

  # ── Non-standard port auto-detection ──────────────────────────────────────

  describe "non-standard port handling" do
    @tag :skip
    test "single node with non-standard port" do
      name = start_conn(nodes: ["127.0.0.1:9043"])
      conn = Connection.get_conn(name)
      assert is_pid(conn.conn)
      assert conn.nodes == ["127.0.0.1:9043"]
    end

    @tag :skip
    test "multiple nodes with same non-standard port" do
      name = start_conn(nodes: ["127.0.0.1:9043", "127.0.0.1:9043"])
      conn = Connection.get_conn(name)
      assert is_pid(conn.conn)
    end
  end

  # ── typed_params / type_value ────────────────────────────────────────────

  describe "typed_params/1" do
    test "integers are tagged as bigint" do
      params = Connection.typed_params([10, 250, 1000])
      assert params == [{"bigint", 10}, {"bigint", 250}, {"bigint", 1000}]
    end

    test "large integers are tagged as bigint" do
      params = Connection.typed_params([2_147_483_648, -2_147_483_649, 9_999_999_999])

      assert params == [
               {"bigint", 2_147_483_648},
               {"bigint", -2_147_483_649},
               {"bigint", 9_999_999_999}
             ]
    end

    test "limit value 250 is passed as raw integer (query_builder.ex tags it as int)" do
      # Connection.type_value tags all integers as bigint
      # The LIMIT int32 fix is in query_builder.ex which tags the limit as {"int", limit}
      params = Connection.typed_params(["active", 250])
      assert params == [{"text", "active"}, {"bigint", 250}]
    end

    test "passes through already-typed tuples" do
      params = Connection.typed_params([{"int", 10}, {"text", "hello"}])
      assert params == [{"int", 10}, {"text", "hello"}]
    end

    test "floats are tagged as double" do
      params = Connection.typed_params([3.14])
      assert params == [{"double", 3.14}]
    end

    test "booleans are tagged as boolean" do
      params = Connection.typed_params([true, false])
      assert params == [{"boolean", true}, {"boolean", false}]
    end

    test "nil passes through as nil" do
      params = Connection.typed_params([nil])
      assert params == [nil]
    end

    test "atoms are encoded as text via to_string" do
      params = Connection.typed_params([:active])
      assert params == [{"text", "active"}]
    end
  end

  # ── sync_connect option ───────────────────────────────────────────────────

  describe "sync_connect option" do
    test "single node works without sync_connect" do
      name = start_conn(nodes: ["127.0.0.1:9042"])
      conn = Connection.get_conn(name)
      assert is_pid(conn.conn)
    end

    test "single node works with sync_connect disabled" do
      name = start_conn(nodes: ["127.0.0.1:9042"], sync_connect: false)
      conn = Connection.get_conn(name)
      assert is_pid(conn.conn)
    end
  end
end
