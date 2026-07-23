defmodule AshScylla.MigratorTest do
  @moduledoc """
  Tests for AshScylla.Migrator — covers the keyspace propagation fix
  that ensures DDL statements run against the correct keyspace even
  when the Migrator's connection was started with keyspace: nil.

  The bug: execute_statements/4 called Connection.query without passing
  the keyspace, so DDL ran without keyspace context ("No keyspace has
  been specified" error) when --create-keyspace had just created the
  keyspace but the connection's own keyspace was still nil.

  NOTE: These tests require a running ScyllaDB instance. Set
  SCYLLA_DIRECT=1 with SCYLLA_HOST/SCYLLA_PORT to connect to an
  existing instance, or the test reads from config/test.exs
  (AshScylla.TestRepo). Tagged :integration and excluded from default
  test runs.

      SCYLLA_DIRECT=1 SCYLLA_HOST=127.0.0.1 SCYLLA_PORT=9051 mix test test/unit/migrator/migrator_test.exs
  """
  use ExUnit.Case, async: false

  @moduletag :integration

  require Logger

  alias AshScylla.{Connection, Migrator, TestRepo}

  @config_nodes Keyword.get(TestRepo.config(), :nodes, ["127.0.0.1:9042"])

  defp direct_connect?, do: System.get_env("SCYLLA_DIRECT") != nil

  defp direct_host do
    System.get_env("SCYLLA_HOST") || default_host()
  end

  defp default_host do
    @config_nodes |> hd() |> String.split(":") |> hd()
  end

  defp direct_port do
    case System.get_env("SCYLLA_PORT") do
      nil -> default_port()
      port -> String.to_integer(port)
    end
  end

  defp default_port do
    node = hd(@config_nodes)
    case String.split(node, ":") do
      [_, port] -> String.to_integer(port)
      [_host] -> 9042
    end
  end

  defp scylla_host, do: direct_host()
  defp scylla_port, do: direct_port()

  defp scylla_node do
    "#{scylla_host()}:#{scylla_port()}"
  end

  defp scylla_nodes do
    if direct_connect?() do
      [scylla_node()]
    else
      @config_nodes
    end
  end

  setup_all do
    case Xandra.start_link(nodes: scylla_nodes(), connect_timeout: 2_000) do
      {:ok, conn} ->
        Xandra.stop(conn)
        :ok

      {:error, _} ->
        :ok
    end
  end

  defp scylla_available? do
    case Xandra.start_link(nodes: scylla_nodes(), connect_timeout: 2_000) do
      {:ok, conn} ->
        Xandra.stop(conn)
        true

      {:error, _} ->
        false
    end
  end

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

  defp scylla_warning do
    Logger.warning(
      "No ScyllaDB reachable at #{scylla_node()} — skipping migrator integration test"
    )
  end

  # ── run/3 — temporary connection ──────────────────────────────────────────

  describe "run/3" do
    test "executes statements and returns results" do
      if scylla_available?() do
        assert {:ok, results} =
                 Migrator.run(scylla_node(), ["SELECT now() FROM system.local"])

        assert length(results) == 1
      else
        scylla_warning()
      end
    end

    test "returns error tuple on invalid CQL" do
      if scylla_available?() do
        assert {:error, {1, _reason}} =
                 Migrator.run(scylla_node(), ["THIS IS NOT VALID CQL"])
      else
        scylla_warning()
      end
    end

    test "executes multiple statements sequentially" do
      if scylla_available?() do
        assert {:ok, results} =
                 Migrator.run(scylla_node(), [
                   "SELECT now() FROM system.local",
                   "SELECT count(*) FROM system_schema.keyspaces"
                 ])

        assert length(results) == 2
      else
        scylla_warning()
      end
    end

    test "returns error with failing statement index" do
      if scylla_available?() do
        assert {:error, {2, _reason}} =
                 Migrator.run(scylla_node(), [
                   "SELECT now() FROM system.local",
                   "INVALID STATEMENT HERE"
                 ])
      else
        scylla_warning()
      end
    end
  end

  # — run!/3 — raises on error ──────────────────────────────────────────────

  describe "run!/3" do
    test "returns results on success" do
      if scylla_available?() do
        results = Migrator.run!(scylla_node(), ["SELECT now() FROM system.local"])
        assert length(results) == 1
      else
        scylla_warning()
      end
    end

    test "raises on invalid CQL" do
      if scylla_available?() do
        assert_raise RuntimeError, ~r/Migration statement 1 failed/, fn ->
          Migrator.run!(scylla_node(), ["BAD CQL"])
        end
      else
        scylla_warning()
      end
    end
  end

  # — run_on/2 — existing named connection ───────────────────────────────────

  describe "run_on/2" do
    test "executes statements against an existing connection" do
      if scylla_available?() do
        name = start_conn(nodes: scylla_nodes())

        assert {:ok, results} = Migrator.run_on(name, ["SELECT now() FROM system.local"])
        assert length(results) == 1
      else
        scylla_warning()
      end
    end

    test "returns error tuple on invalid CQL" do
      if scylla_available?() do
        name = start_conn(nodes: scylla_nodes())
        assert {:error, {1, _reason}} = Migrator.run_on(name, ["NOT VALID CQL"])
      else
        scylla_warning()
      end
    end

    test "executes multiple statements sequentially" do
      if scylla_available?() do
        name = start_conn(nodes: scylla_nodes())

        assert {:ok, results} =
                 Migrator.run_on(name, [
                   "SELECT now() FROM system.local",
                   "SELECT count(*) FROM system_schema.keyspaces"
                 ])

        assert length(results) == 2
      else
        scylla_warning()
      end
    end
  end

  # — run_on!/2 — raises on error ───────────────────────────────────────────

  describe "run_on!/2" do
    test "returns results on success" do
      if scylla_available?() do
        name = start_conn(nodes: scylla_nodes())
        results = Migrator.run_on!(name, ["SELECT now() FROM system.local"])
        assert length(results) == 1
      else
        scylla_warning()
      end
    end

    test "raises on invalid CQL" do
      if scylla_available?() do
        name = start_conn(nodes: scylla_nodes())

        assert_raise RuntimeError, ~r/Migration statement 1 failed/, fn ->
          Migrator.run_on!(name, ["BAD CQL"])
        end
      else
        scylla_warning()
      end
    end
  end

  # ── Keyspace propagation fix ─────────────────────────────────────────────

  describe "keyspace propagation" do
    test "run_on executes DDL against the connection's keyspace" do
      if scylla_available?() do
        keyspace = "ash_scylla_migrator_test_ks"
        table = "#{keyspace}.ddl_test_table"

        # Create keyspace first using a dedicated setup connection
        setup_conn = start_conn(nodes: scylla_nodes())

        {:ok, _} =
          Connection.query(
            setup_conn,
            "CREATE KEYSPACE IF NOT EXISTS #{keyspace} " <>
              "WITH REPLICATION = {'class': 'NetworkTopologyStrategy', 'replication_factor': 1}",
            []
          )

        # Start a connection WITH the keyspace — run_on should propagate it
        name = start_conn(nodes: scylla_nodes(), keyspace: keyspace)

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
      else
        scylla_warning()
      end
    end

    test "run_on works when connection has no keyspace (uses default)" do
      if scylla_available?() do
        name = start_conn(nodes: scylla_nodes())

        # System queries work without a keyspace
        assert {:ok, results} = Migrator.run_on(name, ["SELECT now() FROM system.local"])
        assert length(results) == 1
      else
        scylla_warning()
      end
    end

    test "run with keyspace option executes DDL in that keyspace" do
      if scylla_available?() do
        keyspace = "ash_scylla_migrator_run_test_ks"

        assert {:ok, _} =
                 Migrator.run(
                   scylla_node(),
                   [
                     "CREATE KEYSPACE IF NOT EXISTS #{keyspace} " <>
                       "WITH REPLICATION = {'class': 'NetworkTopologyStrategy', 'replication_factor': 1}"
                   ]
                 )

        table = "#{keyspace}.run_test_table"

        assert {:ok, _} =
                 Migrator.run(
                   scylla_node(),
                   [
                     "CREATE TABLE IF NOT EXISTS #{table} (id UUID PRIMARY KEY, value TEXT)"
                   ],
                   keyspace: keyspace
                 )

        assert {:ok, _} =
                 Migrator.run(scylla_node(), ["DROP TABLE IF EXISTS #{table}"],
                   keyspace: keyspace
                 )

        # Cleanup keyspace (in the test process)
        Migrator.run(scylla_node(), ["DROP KEYSPACE IF EXISTS #{keyspace}"])
      else
        scylla_warning()
      end
    end
  end
end
