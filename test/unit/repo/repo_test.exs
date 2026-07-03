defmodule AshScylla.RepoTest do
  @moduledoc """
  Tests for AshScylla.Repo behaviour — covers replication strategy,
  keyspace creation options, and config resolution.
  """
  use ExUnit.Case, async: true

  alias AshScylla.TestRepo

  describe "build_replication_clause/1" do
    test "default strategy is network_topology (no topologies => replication_factor form)" do
      result = TestRepo.build_replication_clause([])
      assert result =~ "NetworkTopologyStrategy"
      assert result =~ "'replication_factor': 1"
      refute result =~ "SimpleStrategy"
    end

    test "default strategy with custom replication_factor" do
      result = TestRepo.build_replication_clause(replication_factor: 3)
      assert result =~ "NetworkTopologyStrategy"
      assert result =~ "'replication_factor': 3"
    end

    test "network_topology strategy with datacenter topologies" do
      result =
        TestRepo.build_replication_clause(
          strategy: :network_topology,
          topologies: [dc1: 3, dc2: 2]
        )

      assert result =~ "NetworkTopologyStrategy"
      assert result =~ "'dc1': 3"
      assert result =~ "'dc2': 2"
      refute result =~ "replication_factor"
    end

    test "simple strategy still works when explicitly requested" do
      result = TestRepo.build_replication_clause(strategy: :simple, replication_factor: 2)
      assert result =~ "SimpleStrategy"
      assert result =~ "'replication_factor': 2"
    end

    test "simple strategy default replication factor is 1" do
      result = TestRepo.build_replication_clause(strategy: :simple)
      assert result =~ "SimpleStrategy"
      assert result =~ "'replication_factor': 1"
    end

    test "topologies with string keys" do
      result =
        TestRepo.build_replication_clause(
          strategy: :network_topology,
          topologies: [{"us_east", 3}, {"us_west", 2}]
        )

      assert result =~ "NetworkTopologyStrategy"
      assert result =~ "'us_east': 3"
      assert result =~ "'us_west': 2"
    end

    test "raises on invalid characters in topology keys" do
      assert_raise ArgumentError, ~r/Invalid CQL identifier/, fn ->
        TestRepo.build_replication_clause(
          strategy: :network_topology,
          topologies: [{"dc-1", 3}]
        )
      end
    end
  end

  describe "config_to_conn_opts/1" do
    test "returns default nodes when not configured" do
      opts = AshScylla.Repo.config_to_conn_opts(TestRepo)
      assert Keyword.get(opts, :nodes) == ["127.0.0.1:9042"]
    end

    test "includes keyspace when configured" do
      # Temporarily override config
      original = Application.get_env(:ash_scylla, AshScylla.TestRepo)

      Application.put_env(:ash_scylla, AshScylla.TestRepo,
        nodes: ["127.0.0.1:9042"],
        keyspace: "custom_ks"
      )

      opts = AshScylla.Repo.config_to_conn_opts(TestRepo)
      assert Keyword.get(opts, :keyspace) == "custom_ks"

      # Restore
      if original, do: Application.put_env(:ash_scylla, AshScylla.TestRepo, original)
    end

    test "default connect_timeout is 5000" do
      opts = AshScylla.Repo.config_to_conn_opts(TestRepo)
      assert Keyword.get(opts, :connect_timeout) == 5_000
    end
  end
end
