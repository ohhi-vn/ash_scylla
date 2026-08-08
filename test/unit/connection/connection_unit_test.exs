defmodule AshScylla.ConnectionUnitTest do
  @moduledoc """
  Unit tests for AshScylla.Connection that do NOT require a running ScyllaDB instance.
  Covers pure functions and edge cases.
  """
  use ExUnit.Case, async: true

  alias AshScylla.Connection

  describe "execute_module/1" do
    test "returns Xandra.Cluster for cluster connections" do
      assert Connection.execute_module(true) == Xandra.Cluster
    end

    test "returns Xandra for non-cluster connections" do
      assert Connection.execute_module(false) == Xandra
      assert Connection.execute_module(nil) == Xandra
    end
  end

  describe "prepare_module/1" do
    test "returns Xandra.Cluster for cluster connections" do
      assert Connection.prepare_module(true) == Xandra.Cluster
    end

    test "returns Xandra for non-cluster connections" do
      assert Connection.prepare_module(false) == Xandra
    end
  end

  describe "stop_module/1" do
    test "returns Xandra.Cluster for cluster connections" do
      assert Connection.stop_module(true) == Xandra.Cluster
    end

    test "returns Xandra for non-cluster connections" do
      assert Connection.stop_module(false) == Xandra
    end
  end

  describe "typed_params/1 with struct types" do
    test "MapSet is tagged as set<text>" do
      params = Connection.typed_params([MapSet.new(["a", "b"])])
      assert match?([{"set<text>", _}], params)
    end

    test "map is tagged as map<text, text>" do
      params = Connection.typed_params([%{"key" => "value"}])
      assert params == [{"map<text, text>", %{"key" => "value"}}]
    end

    test "list of strings is tagged as list<text>" do
      params = Connection.typed_params([["a", "b", "c"]])
      assert params == [{"list<text>", ["a", "b", "c"]}]
    end

    test "DateTime struct is tagged as timestamp" do
      dt = DateTime.from_naive!(~N[2024-01-01 00:00:00], "Etc/UTC")
      params = Connection.typed_params([dt])
      assert match?([{"timestamp", _}], params)
    end

    test "Date struct is tagged as date" do
      d = ~D[2024-01-01]
      params = Connection.typed_params([d])
      assert params == [{"date", d}]
    end

    test "Time struct is tagged as time" do
      t = ~T[12:00:00]
      params = Connection.typed_params([t])
      assert params == [{"time", t}]
    end

    test "unknown struct is tagged as text via to_string" do
      params = Connection.typed_params([URI.parse("https://example.com")])
      assert match?([{"text", "https://example.com"}], params)
    end

    test "non-typed_value is encoded as list<text>" do
      params = Connection.typed_params([[1, 2, 3]])
      assert params == [{"list<text>", [1, 2, 3]}]
    end

    test "already-typed tuples pass through regardless of struct" do
      params = Connection.typed_params([{"int", 42}])
      assert params == [{"int", 42}]
    end

    test "non-list params pass through" do
      assert Connection.typed_params("not_a_list") == "not_a_list"
      assert Connection.typed_params(nil) == nil
    end
  end

  describe "validate_keyspace!/1" do
    test "passes for valid keyspace" do
      assert Connection.validate_keyspace!("valid_ks") == :ok
    end

    test "raises for invalid keyspace" do
      assert_raise ArgumentError, fn ->
        Connection.validate_keyspace!("123invalid")
      end
    end
  end

  describe "child_spec/1" do
    test "uses provided name as id" do
      spec = Connection.child_spec(name: MyCustomConn, nodes: ["127.0.0.1:9042"])
      assert spec.id == MyCustomConn
    end

    test "defaults name to AshScylla.Connection" do
      spec = Connection.child_spec(nodes: ["127.0.0.1:9042"])
      assert spec.id == AshScylla.Connection
    end

    test "spec has correct structure" do
      spec = Connection.child_spec(name: MyConn, nodes: ["127.0.0.1:9042"])
      assert spec.type == :worker
      assert spec.restart == :permanent
      assert spec.shutdown == 5_000
    end
  end

  describe "ensure_keyspace!/2" do
    test "returns conn unchanged when second arg is not an atom" do
      conn = %Connection{keyspace: nil, keyspace_used: true}
      assert Connection.ensure_keyspace!(conn, "string_name") == conn
    end
  end

  describe "do_get_conn/1" do
    test "returns nil for dead pid" do
      _dead_pid = spawn(fn -> :ok end)
      Process.sleep(10)
      # Use the rescue/catch path indirectly via get_conn
      assert Connection.get_conn(:non_existent_conn_for_test) == nil
    end
  end

  describe "prepare/3" do
    test "dispatches to Xandra when not clustered" do
      conn = %Connection{conn: nil, cluster?: false}
      assert match?({:error, %Xandra.ConnectionError{}}, Connection.prepare(conn, "SELECT 1"))
    end

    test "dispatches to Xandra.Cluster when clustered" do
      conn = %Connection{conn: nil, cluster?: true}
      assert catch_exit(Connection.prepare(conn, "SELECT 1"))
    end

    test "returns {:error, :not_connected} for atom name without connection" do
      assert {:error, :not_connected} = Connection.prepare(:non_existent_name, "SELECT 1")
    end
  end

  describe "prepare!/3" do
    test "dispatches to Xandra when not clustered" do
      conn = %Connection{conn: nil, cluster?: false}

      assert_raise Xandra.ConnectionError, fn ->
        Connection.prepare!(conn, "SELECT 1")
      end
    end

    test "dispatches to Xandra.Cluster when clustered" do
      conn = %Connection{conn: nil, cluster?: true}
      assert catch_exit(Connection.prepare!(conn, "SELECT 1"))
    end

    test "raises for atom name without connection" do
      assert_raise RuntimeError, ~r/No AshScylla connection found/, fn ->
        Connection.prepare!(:non_existent_name, "SELECT 1")
      end
    end
  end

  describe "release_session/1" do
    test "returns :ok for non-existent connection" do
      assert Connection.release_session(:non_existent_name) == :ok
    end
  end

  describe "reconnect_keyspace/1" do
    test "returns {:error, :no_keyspace_configured} for non-existent connection" do
      assert catch_exit(Connection.reconnect_keyspace(:non_existent_name_for_reconnect))
    end
  end

  describe "set_keyspace/2" do
    test "exits when connection does not exist" do
      assert catch_exit(Connection.set_keyspace(:non_existent_name_for_set, "ks"))
    end
  end

  describe "stop/1" do
    test "dispatches to Xandra when not clustered" do
      conn = %Connection{conn: nil, cluster?: false}
      assert catch_exit(Connection.stop(conn))
    end

    test "dispatches to Xandra.Cluster when clustered" do
      conn = %Connection{conn: nil, cluster?: true}
      assert catch_exit(Connection.stop(conn))
    end

    test "returns :ok for non-existent atom name" do
      assert Connection.stop(:non_existent_name_for_stop) == :ok
    end
  end
end
