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
end
