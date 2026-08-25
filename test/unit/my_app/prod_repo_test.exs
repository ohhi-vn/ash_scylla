defmodule MyApp.ProdRepoTest do
  use ExUnit.Case, async: true

  describe "MyApp.ProdRepo" do
    test "compiles as a valid module" do
      assert is_atom(MyApp.ProdRepo)
      assert Code.ensure_loaded?(MyApp.ProdRepo)
    end

    test "uses AshScylla.Repo behaviour" do
      assert function_exported?(Code.ensure_loaded!(MyApp.ProdRepo), :__info__, 1)
    end
  end

  describe "config accessors with no application env" do
    test "config/0 returns empty list" do
      assert MyApp.ProdRepo.config() == []
    end

    test "keyspace/0 returns nil" do
      assert MyApp.ProdRepo.keyspace() == nil
    end

    test "nodes/0 returns the default node" do
      assert MyApp.ProdRepo.nodes() == ["127.0.0.1:9042"]
    end

    test "disable_lwt?/0 defaults to false" do
      refute MyApp.ProdRepo.disable_lwt?()
    end

    test "disable_atomic_actions?/0 defaults to false" do
      refute MyApp.ProdRepo.disable_atomic_actions?()
    end

    test "installed_extensions/0 defaults to empty list" do
      assert MyApp.ProdRepo.installed_extensions() == []
    end
  end

  describe "connection-dependent callbacks without a connection" do
    test "connection/0 returns nil" do
      assert MyApp.ProdRepo.connection() == nil
    end

    test "query/3 returns {:error, :not_connected}" do
      assert MyApp.ProdRepo.query("SELECT 1", []) == {:error, :not_connected}
    end

    test "query_all/3 returns {:error, :not_connected}" do
      assert MyApp.ProdRepo.query_all("SELECT 1", []) == {:error, :not_connected}
    end

    test "prepare/2 returns {:error, :not_connected}" do
      assert MyApp.ProdRepo.prepare("SELECT 1") == {:error, :not_connected}
    end

    test "query!/3 raises when not connected" do
      assert_raise RuntimeError, ~r/No AshScylla connection found/, fn ->
        MyApp.ProdRepo.query!("SELECT 1", [])
      end
    end

    test "prepare!/2 raises when not connected" do
      assert_raise RuntimeError, ~r/No AshScylla connection found/, fn ->
        MyApp.ProdRepo.prepare!("SELECT 1")
      end
    end
  end

  describe "build_replication_clause/1" do
    test "defaults to NetworkTopologyStrategy with replication factor 1" do
      clause = MyApp.ProdRepo.build_replication_clause([])

      assert clause ==
               "{'class': 'NetworkTopologyStrategy', 'replication_factor': 1}"
    end

    test "supports SimpleStrategy with a replication factor" do
      clause =
        MyApp.ProdRepo.build_replication_clause(strategy: :simple, replication_factor: 3)

      assert clause == "{'class': 'SimpleStrategy', 'replication_factor': 3}"
    end

    test "supports explicit datacenter topologies" do
      clause =
        MyApp.ProdRepo.build_replication_clause(topologies: [datacenter1: 3, datacenter2: 2])

      assert clause ==
               "{'class': 'NetworkTopologyStrategy', 'datacenter1': 3, 'datacenter2': 2}"
    end
  end

  describe "keyspace management validation" do
    test "create_keyspace/2 rejects invalid keyspace names" do
      assert_raise ArgumentError, fn ->
        MyApp.ProdRepo.create_keyspace("123invalid")
      end
    end

    test "drop_keyspace/1 rejects invalid keyspace names" do
      assert_raise ArgumentError, fn ->
        MyApp.ProdRepo.drop_keyspace("123invalid")
      end
    end

    test "drop_keyspace/1 returns an error tuple when not connected" do
      assert {:error, :not_connected} = MyApp.ProdRepo.drop_keyspace("valid_ks")
    end
  end

  describe "child_spec/1" do
    test "returns a supervisor child spec named after the repo" do
      spec = MyApp.ProdRepo.child_spec([])

      assert spec[:id] == MyApp.ProdRepo
      assert spec[:type] == :worker
      assert {AshScylla.Connection, :start_link, [opts]} = spec[:start]
      assert Keyword.get(opts, :name) == MyApp.ProdRepo
      assert Keyword.get(opts, :nodes) == ["127.0.0.1:9042"]
    end
  end
end
