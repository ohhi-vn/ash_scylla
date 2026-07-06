defmodule AshScylla.MigratorTest do
  @moduledoc """
  Tests for AshScylla.Migrator — covers the keyspace propagation fix
  that ensures DDL statements run against the correct keyspace even
  when the Migrator's connection was started with keyspace: nil.

  The bug: execute_statements/4 called Connection.query without passing
  the keyspace, so DDL ran without keyspace context ("No keyspace has
  been specified" error) when --create-keyspace had just created the
  keyspace but the connection's own keyspace was still nil.

  NOTE: These tests require a running ScyllaDB instance at 127.0.0.1:9042.
  They are tagged :integration and excluded from default test runs.
  """
  use ExUnit.Case, async: false

  @moduletag :integration

  alias AshScylla.{Connection, Migrator}

  # ── Helpers ────────────────────────────────────────────────────────────────

  defp unique_name do
    :"ash_scylla_migrator_test_#{System.unique_integer([:positive])}"
  end

  defp start_conn(opts) do
    name = unique_name()
    full_opts = Keyword.put(opts, :name, name)
    {:ok, _pid} = Connection.start_link(full_opts)
    on_exit(fn -> Connection.stop(name) end)
    name
  end

  # ── run/3 — temporary connection ──────────────────────────────────────────

  describe "run/3" do
    test "executes statements and returns results" do
      assert {:ok, results} =
               Migrator.run("127.0.0.1:9042", ["SELECT now() FROM system.local"])

      assert length(results) == 1
    end

    test "returns error tuple on invalid CQL" do
      assert {:error, {1, _reason}} =
               Migrator.run("127.0.0.1:9042", ["THIS IS NOT VALID CQL"])
    end

    test "executes multiple statements sequentially" do
      assert {:ok, results} =
               Migrator.run("127.0.0.1:9042", [
                 "SELECT now() FROM system.local",
                 "SELECT count(*) FROM system_schema.keyspaces"
               ])

      assert length(results) == 2
    end

    test "returns error with failing statement index" do
      assert {:error, {2, _reason}} =
               Migrator.run("127.0.0.1:9042", [
                 "SELECT now() FROM system.local",
                 "INVALID STATEMENT HERE"
               ])
    end
  end

  # — run!/3 — raises on error ──────────────────────────────────────────────

  describe "run!/3" do
    test "returns results on success" do
      results = Migrator.run!("127.0.0.1:9042", ["SELECT now() FROM system.local"])
      assert length(results) == 1
    end

    test "raises on invalid CQL" do
      assert_raise RuntimeError, ~r/Migration statement 1 failed/, fn ->
        Migrator.run!("127.0.0.1:9042", ["BAD CQL"])
      end
    end
  end

  # — run_on/2 — existing named connection ───────────────────────────────────

  describe "run_on/2" do
    test "executes statements against an existing connection" do
      name = start_conn(nodes: ["127.0.0.1:9042"])

      assert {:ok, results} = Migrator.run_on(name, ["SELECT now() FROM system.local"])
      assert length(results) == 1
    end

    test "returns error tuple on invalid CQL" do
      name = start_conn(nodes: ["127.0.0.1:9042"])
      assert {:error, {1, _reason}} = Migrator.run_on(name, ["NOT VALID CQL"])
    end

    test "executes multiple statements sequentially" do
      name = start_conn(nodes: ["127.0.0.1:9042"])

      assert {:ok, results} =
               Migrator.run_on(name, [
                 "SELECT now() FROM system.local",
                 "SELECT count(*) FROM system_schema.keyspaces"
               ])

      assert length(results) == 2
    end
  end

  # — run_on!/2 — raises on error ───────────────────────────────────────────

  describe "run_on!/2" do
    test "returns results on success" do
      name = start_conn(nodes: ["127.0.0.1:9042"])
      results = Migrator.run_on!(name, ["SELECT now() FROM system.local"])
      assert length(results) == 1
    end

    test "raises on invalid CQL" do
      name = start_conn(nodes: ["127.0.0.1:9042"])

      assert_raise RuntimeError, ~r/Migration statement 1 failed/, fn ->
        Migrator.run_on!(name, ["BAD CQL"])
      end
    end
  end

  # ── Keyspace propagation fix ─────────────────────────────────────────────

  describe "keyspace propagation" do
    test "run_on executes DDL against the connection's keyspace" do
      keyspace = "ash_scylla_migrator_test_ks"
      table = "#{keyspace}.ddl_test_table"

      # Create keyspace first using a dedicated setup connection
      setup_conn = start_conn(nodes: ["127.0.0.1:9042"])

      {:ok, _} =
        Connection.query(
          setup_conn,
          "CREATE KEYSPACE IF NOT EXISTS #{keyspace} " <>
            "WITH REPLICATION = {'class': 'NetworkTopologyStrategy', 'replication_factor': 1}",
          []
        )

      # Start a connection WITH the keyspace — run_on should propagate it
      name = start_conn(nodes: ["127.0.0.1:9042"], keyspace: keyspace)

      assert {:ok, _} =
               Migrator.run_on(name, [
                 "CREATE TABLE IF NOT EXISTS #{table} (id UUID PRIMARY KEY, name TEXT)"
               ])

      # Verify table was created in the correct keyspace
      assert {:ok, _} =
               Connection.query(name, "INSERT INTO #{table} (id, name) VALUES (uuid(), ?)", [
                 "test"
               ])

      assert {:ok, _} = Migrator.run_on(name, ["DROP TABLE IF EXISTS #{table}"])

      # Cleanup keyspace via the setup connection (in the test process)
      Connection.query(setup_conn, "DROP KEYSPACE IF EXISTS #{keyspace}", [])
    end

    test "run_on works when connection has no keyspace (uses default)" do
      name = start_conn(nodes: ["127.0.0.1:9042"])

      # System queries work without a keyspace
      assert {:ok, results} = Migrator.run_on(name, ["SELECT now() FROM system.local"])
      assert length(results) == 1
    end

    test "run with keyspace option executes DDL in that keyspace" do
      keyspace = "ash_scylla_migrator_run_test_ks"

      assert {:ok, _} =
               Migrator.run(
                 "127.0.0.1:9042",
                 [
                   "CREATE KEYSPACE IF NOT EXISTS #{keyspace} " <>
                     "WITH REPLICATION = {'class': 'NetworkTopologyStrategy', 'replication_factor': 1}"
                 ],
                 keyspace: keyspace
               )

      table = "#{keyspace}.run_test_table"

      assert {:ok, _} =
               Migrator.run(
                 "127.0.0.1:9042",
                 [
                   "CREATE TABLE IF NOT EXISTS #{table} (id UUID PRIMARY KEY, value TEXT)"
                 ],
                 keyspace: keyspace
               )

      assert {:ok, _} =
               Migrator.run("127.0.0.1:9042", ["DROP TABLE IF EXISTS #{table}"],
                 keyspace: keyspace
               )

      # Cleanup keyspace (in the test process)
      Migrator.run("127.0.0.1:9042", ["DROP KEYSPACE IF EXISTS #{keyspace}"])
    end
  end
end
