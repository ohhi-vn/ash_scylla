defmodule AshScylla.MigratorUnitTest do
  @moduledoc """
  Unit tests for AshScylla.Migrator that do NOT require a running ScyllaDB.
  Tests edge cases and error handling paths.
  """
  use ExUnit.Case, async: true

  alias AshScylla.Migrator

  describe "run_on/2" do
    test "returns {:ok, []} for empty statements list" do
      assert Migrator.run_on(:non_existent_conn, []) == {:ok, []}
    end

    test "returns {:error, {1, :not_connected}} for non-existent connection" do
      assert {:error, {1, :not_connected}} =
               Migrator.run_on(:non_existent_conn_for_test, ["SELECT 1"])
    end
  end

  describe "run_on!/2" do
    test "returns [] for empty statements" do
      assert Migrator.run_on!(:non_existent_conn_for_test, []) == []
    end

    test "raises for non-existent connection with statements" do
      assert_raise RuntimeError, ~r/Migration statement 1 failed/, fn ->
        Migrator.run_on!(:non_existent_conn_for_test, ["SELECT 1"])
      end
    end
  end

  describe "run/3" do
    test "returns an error tuple for unreachable single binary node" do
      assert {:error, {1, %Xandra.ConnectionError{}}} =
               Migrator.run("127.0.0.1:1", ["SELECT 1"], connect_timeout: 100)
    end

    test "returns an error tuple for unreachable node list" do
      assert {:error, {1, %Xandra.ConnectionError{}}} =
               Migrator.run(["127.0.0.1:1"], ["SELECT 1"], connect_timeout: 100)
    end

    test "returns an error tuple with keyspace option on unreachable nodes" do
      assert {:error, {1, %Xandra.ConnectionError{}}} =
               Migrator.run(["127.0.0.1:1"], ["SELECT 1"],
                 keyspace: "migrator_test_ks",
                 connect_timeout: 100
               )
    end

    test "returns {:ok, []} for empty statements without querying" do
      assert {:ok, []} = Migrator.run(["127.0.0.1:1"], [], connect_timeout: 100)
    end
  end

  describe "run!/3" do
    test "raises when a statement fails" do
      assert_raise RuntimeError, ~r/Migration statement 1 failed/, fn ->
        Migrator.run!(["127.0.0.1:1"], ["SELECT 1"], connect_timeout: 100)
      end
    end
  end
end
