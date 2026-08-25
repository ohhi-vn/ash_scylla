defmodule AshScylla.MigratorCoverageTest do
  @moduledoc """
  Hermetic line-coverage tests for AshScylla.Migrator: run/3 connection setup
  and run!/3 success unwrapping, using an unreachable node so no ScyllaDB is
  required.
  """

  use ExUnit.Case, async: true

  alias AshScylla.Migrator

  describe "run/3 with no statements" do
    test "starts a temporary connection and returns {:ok, []}" do
      assert {:ok, []} = Migrator.run(["127.0.0.1:59999"], [], connect_timeout: 100)
    end

    test "accepts a single binary node" do
      assert {:ok, []} = Migrator.run("127.0.0.1:59999", [], connect_timeout: 100)
    end

    test "uses default opts when none are given" do
      assert {:ok, []} = Migrator.run(["127.0.0.1:59999"], [])
    end
  end

  describe "run!/3 success path" do
    test "returns the results list when every statement succeeds" do
      assert [] = Migrator.run!(["127.0.0.1:59999"], [], connect_timeout: 100)
    end

    test "uses default opts when none are given" do
      assert [] = Migrator.run!(["127.0.0.1:59999"], [])
    end
  end
end
