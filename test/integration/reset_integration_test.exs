defmodule AshScylla.ResetIntegrationTest do
  @moduledoc """
  Integration tests for `mix ash_scylla.reset`.

  Drops the keyspace (and all data), recreates it, and re-runs migrations
  against a real ScyllaDB instance. Requires a running ScyllaDB reachable via
  `SCYLLA_DIRECT` (or a container engine). Tagged `:integration` and excluded
  from default test runs.

      SCYLLA_DIRECT=1 mix test test/integration/reset_integration_test.exs
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  require Logger

  alias AshScylla.TestRepo

  @moduletag :integration

  defp direct_connect?, do: System.get_env("SCYLLA_DIRECT") != nil

  defp direct_host do
    System.get_env("SCYLLA_HOST") ||
      case System.get_env("SCYLLA_NODES") do
        nil -> "127.0.0.1"
        nodes -> nodes |> String.split(",") |> hd() |> String.split(":") |> hd()
      end
  end

  defp direct_port do
    case System.get_env("SCYLLA_PORT") do
      nil ->
        case System.get_env("SCYLLA_NODES") do
          nil ->
            9042

          nodes ->
            nodes
            |> String.split(",")
            |> hd()
            |> String.split(":")
            |> List.last()
            |> String.to_integer()
        end

      port ->
        String.to_integer(port)
    end
  end

  defp connect_with_retry(host, port, retries \\ 20) do
    case Xandra.start_link(nodes: ["#{host}:#{port}"], connect_timeout: 15_000) do
      {:ok, conn} ->
        case wait_for_cql(conn, 15) do
          :ok ->
            conn

          {:error, _} when retries > 0 ->
            Xandra.stop(conn)
            Process.sleep(5_000)
            connect_with_retry(host, port, retries - 1)

          {:error, reason} ->
            Xandra.stop(conn)
            raise "ScyllaDB not ready: #{inspect(reason)}"
        end

      {:error, _} when retries > 0 ->
        Process.sleep(5_000)
        connect_with_retry(host, port, retries - 1)

      {:error, reason} ->
        raise "Failed to connect to ScyllaDB: #{inspect(reason)}"
    end
  end

  defp wait_for_cql(conn, retries) do
    case Xandra.execute(conn, "SELECT now() FROM system.local", [],
           timeout: 5_000,
           consistency: :one
         ) do
      {:ok, _} ->
        :ok

      {:error, _} when retries > 0 ->
        Process.sleep(1_000)
        wait_for_cql(conn, retries - 1)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp keyspace_exists?(conn, keyspace) do
    result =
      Xandra.execute(
        conn,
        "SELECT keyspace_name FROM system_schema.keyspaces WHERE keyspace_name = ?",
        [{"text", keyspace}]
      )

    case result do
      {:ok, %Xandra.Page{content: rows}} -> length(rows || []) == 1
      _ -> false
    end
  end

  defp table_exists?(conn, keyspace, table) do
    result =
      Xandra.execute(
        conn,
        "SELECT table_name FROM system_schema.tables WHERE keyspace_name = ? AND table_name = ?",
        [{"text", keyspace}, {"text", table}]
      )

    case result do
      {:ok, %Xandra.Page{content: rows}} -> (rows || []) != []
      _ -> false
    end
  end

  # Polls until a table is gone from system_schema, accounting for ScyllaDB's
  # asynchronous DROP KEYSPACE race where old tables can reappear seconds after
  # the keyspace is recreated. Returns true if the table is absent throughout
  # the polling window, false if it is still present.
  defp table_gone?(conn, keyspace, table, polls_remaining \\ 20) do
    Process.sleep(500)

    if table_exists?(conn, keyspace, table) do
      false
    else
      if polls_remaining > 0 do
        table_gone?(conn, keyspace, table, polls_remaining - 1)
      else
        true
      end
    end
  end

  defp drop_keyspace_direct(conn, keyspace) do
    {:ok, _} =
      Xandra.execute(conn, "DROP KEYSPACE IF EXISTS #{keyspace}", [], consistency: :quorum)
  end

  # Runs the test body only when a live ScyllaDB connection is available,
  # skipping (with a warning) otherwise.
  defp with_scylla(conn, fun) do
    if is_nil(conn) do
      Logger.warning("No ScyllaDB connection available — skipping reset integration test")
      :ok
    else
      fun.(conn)
    end
  end

  setup_all do
    if direct_connect?() do
      host = direct_host()
      port = direct_port()
      conn = connect_with_retry(host, port)

      case AshScylla.Connection.start_link(
             name: AshScylla.TestRepo,
             nodes: ["#{host}:#{port}"],
             keyspace: "ash_scylla_test",
             connect_timeout: 15_000
           ) do
        {:ok, _} -> :ok
        {:error, {:already_started, _}} -> :ok
      end

      %{conn: conn, host: host, port: port}
    else
      case AshScylla.Test.ContainerEngine.ensure_running() do
        :ok ->
          case AshScylla.ScyllaContainer.start(
                 AshScylla.ScyllaContainer.new()
                 |> AshScylla.ScyllaContainer.with_image("scylladb/scylla:5.4")
                 |> AshScylla.ScyllaContainer.with_wait_timeout(120_000)
               ) do
            {:ok, container} ->
              host = AshScylla.ScyllaContainer.host(container)
              port = AshScylla.ScyllaContainer.port(container)
              conn = connect_with_retry(host, port)

              case AshScylla.Connection.start_link(
                     name: AshScylla.TestRepo,
                     nodes: ["#{host}:#{port}"],
                     keyspace: "ash_scylla_test",
                     connect_timeout: 15_000
                   ) do
                {:ok, _} -> :ok
                {:error, {:already_started, _}} -> :ok
              end

              on_exit(fn -> AshScylla.ScyllaContainer.stop(container.container_id) end)

              %{conn: conn, host: host, port: port}

            {:error, reason} ->
              Logger.warning("Failed to start ScyllaDB container: #{inspect(reason)}")
              %{conn: nil, host: nil, port: nil}
          end

        {:error, _} ->
          %{conn: nil, host: nil, port: nil}
      end
    end
  end

  # Clear and re-seed the keyspace before each test so every test case starts
  # from a known, isolated baseline (no leakage between cases).
  setup %{conn: conn} do
    if conn do
      keyspace = "ash_scylla_test"
      override = "ash_scylla_reset_override"

      drop_keyspace_direct(conn, keyspace)
      drop_keyspace_direct(conn, override)

      {:ok, _} =
        Xandra.execute(conn, """
        CREATE KEYSPACE #{keyspace}
        WITH REPLICATION = {'class': 'NetworkTopologyStrategy', 'replication_factor': 1}
        """)

      {:ok, _} =
        Xandra.execute(conn, """
        CREATE TABLE #{keyspace}.reset_seed (
          id UUID PRIMARY KEY,
          value TEXT
        )
        """)

      {:ok, _} =
        Xandra.execute(
          conn,
          "INSERT INTO #{keyspace}.reset_seed (id, value) VALUES (?, ?)",
          [
            {"uuid", "00000000-0000-0000-0000-000000000001"},
            {"text", "before-reset"}
          ]
        )
    end

    :ok
  end

  describe "mix ash_scylla.reset" do
    @tag :integration
    test "drops keyspace and data, then recreates it", %{conn: conn, host: host, port: port} do
      with_scylla(conn, fn conn ->
        keyspace = "ash_scylla_test"

        # Sanity: data exists before reset.
        assert keyspace_exists?(conn, keyspace)

        # The pre-existing `conn` (opened in `setup_all`) can return stale
        # `system_schema` metadata after the keyspace is dropped and recreated,
        # so assert post-reset state against a fresh connection.
        {:ok, verify_conn} =
          Xandra.start_link(nodes: ["#{host}:#{port}"], connect_timeout: 15_000)

        try do
          # Run the reset task.
          capture_io(fn ->
            Mix.Tasks.AshScylla.Reset.run(["--repo", "AshScylla.TestRepo"])
          end)

          # Keyspace exists again after reset.
          assert keyspace_exists?(verify_conn, keyspace)

          # Data was dropped: the seed table should be gone. ScyllaDB's async
          # DROP KEYSPACE race can cause old tables to reappear seconds after
          # the keyspace is recreated, so poll for the table to actually be
          # gone instead of asserting immediately.
          refute table_gone?(verify_conn, keyspace, "reset_seed")
        after
          Xandra.stop(verify_conn)
        end
      end)
    end

    @tag :integration
    test "reset recreates keyspace with --keyspace override", %{conn: conn} do
      with_scylla(conn, fn conn ->
        custom_keyspace = "ash_scylla_reset_override"

        # Make sure it does not exist yet.
        drop_keyspace_direct(conn, custom_keyspace)
        refute keyspace_exists?(conn, custom_keyspace)

        capture_io(fn ->
          Mix.Tasks.AshScylla.Reset.run([
            "--repo",
            "AshScylla.TestRepo",
            "--keyspace",
            custom_keyspace
          ])
        end)

        assert keyspace_exists?(conn, custom_keyspace)

        # Clean up the override keyspace.
        drop_keyspace_direct(conn, custom_keyspace)
      end)
    end

    @tag :integration
    test "reset with --dry-run does not drop the keyspace", %{conn: conn} do
      with_scylla(conn, fn conn ->
        keyspace = "ash_scylla_test"
        assert keyspace_exists?(conn, keyspace)

        output =
          capture_io(fn ->
            Mix.Tasks.AshScylla.Reset.run([
              "--repo",
              "AshScylla.TestRepo",
              "--dry-run"
            ])
          end)

        assert output =~ "DRY RUN"
        # Keyspace must still exist after a dry run.
        assert keyspace_exists?(conn, keyspace)
      end)
    end
  end
end
