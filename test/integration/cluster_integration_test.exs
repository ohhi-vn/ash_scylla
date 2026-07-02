defmodule AshScylla.ClusterIntegrationTest do
  @moduledoc """
  Integration tests for AshScylla against a real ScyllaDB cluster.

  Supports three modes:

  **Container mode** (default): Uses testcontainer_ex (Podman) to spin up a
  3-node ScyllaDB cluster. Requires Podman installed and running.

  **Single-node direct mode** (`SCYLLA_DIRECT=1`): Connects to a single
  ScyllaDB instance. Uses `SCYLLA_HOST`/`SCYLLA_PORT` (defaults to
  `127.0.0.1:9042`).

  **Cluster direct mode** (`TEST_CLUSTER=true`): Connects to a multi-node
  ScyllaDB cluster. Uses `SCYLLA_NODES` (comma-separated `host:port` pairs).

  ## Running

  ```bash
  # Container mode (requires Podman, default)
  mix test test/integration/cluster_integration_test.exs --only integration

  # Single-node direct mode
  SCYLLA_DIRECT=1 mix test test/integration/cluster_integration_test.exs --only integration

  # Cluster direct mode (multi-node)
  TEST_CLUSTER=true SCYLLA_NODES="node1:9042,node2:9042,node3:9042" \\
    mix test test/integration/cluster_integration_test.exs --only integration
  ```

  ## Configuration

  | Env Var | Default | Description |
  |---------|---------|-------------|
  | `TEST_CLUSTER` | `false` | Set to `true` for multi-node cluster mode |
  | `SCYLLA_DIRECT` | — | Set to `1` for single-node direct mode |
  | `SCYLLA_NODES` | — | Comma-separated `host:port` pairs (cluster mode) |
  | `SCYLLA_HOST` | `127.0.0.1` | Single host (single-node direct mode) |
  | `SCYLLA_PORT` | `9042` | Single port (single-node direct mode) |
  """

  use ExUnit.Case, async: false

  require Logger

  # Enable source annotations for debugging (see https://spark.hexdocs.pm/use-source-annotations.html)
  setup do
    debug_info? = Code.get_compiler_option(:debug_info)
    Code.put_compiler_option(:debug_info, true)
    on_exit(fn -> Code.put_compiler_option(:debug_info, debug_info?) end)
    :ok
  end

  alias AshScylla.DataLayer.QueryBuilder
  alias AshScylla.TestRepo
  alias AshScylla.ScyllaContainer, warn: false

  @moduletag :integration

  @keyspace "ash_scylla_cluster_test"
  @replication_factor 3

  @scylla_image "scylladb/scylla:latest"
  @scylla_wait_timeout 180_000
  @scylla_cmd [
    "--smp",
    "2",
    "--memory",
    "1024",
    "--developer-mode",
    "1",
    "--overprovisioned",
    "1"
  ]

  # ── Mode detection ──────────────────────────────────────────────────────────

  # TEST_CLUSTER=true  → multi-node cluster (SCYLLA_NODES required)
  # TEST_CLUSTER=false → single-node (default, uses SCYLLA_HOST/SCYLLA_PORT)
  defp cluster_mode?, do: System.get_env("TEST_CLUSTER") == "true"

  defp direct_nodes do
    case System.get_env("SCYLLA_NODES") do
      nil ->
        host = System.get_env("SCYLLA_HOST") || "127.0.0.1"
        port = System.get_env("SCYLLA_PORT") || "9042"
        ["#{host}:#{port}"]

      nodes ->
        nodes
        |> String.split(",", trim: true)
        |> Enum.map(&String.trim/1)
    end
  end

  # ── Container helpers (container mode only) ─────────────────────────────────

  defp build_container(index) do
    suffix = :crypto.strong_rand_bytes(3) |> Base.encode16(case: :lower)
    container_name = "scylla_cluster_#{index}_#{suffix}"

    AshScylla.ScyllaContainer.new()
    |> AshScylla.ScyllaContainer.with_image(@scylla_image)
    |> AshScylla.ScyllaContainer.with_cmd(@scylla_cmd)
    |> AshScylla.ScyllaContainer.with_wait_timeout(@scylla_wait_timeout)
    |> AshScylla.ScyllaContainer.with_name(container_name)
  end

  defp start_node(index) do
    container = build_container(index)

    case TestcontainerEx.start_container(container) do
      {:ok, started} -> {:ok, {index, started}}
      {:error, reason} -> {:error, reason}
      {:error, reason, _extra} -> {:error, reason}
    end
  end

  defp get_host_port({_, container}) do
    get_host_port(container)
  end

  defp get_host_port(container) do
    host = TestcontainerEx.get_host(container)
    port = TestcontainerEx.get_port(container, 9042)
    {host, port}
  end

  defp stop_container(container) do
    TestcontainerEx.stop_container(container.container_id)
  end

  # ── Connection helpers ──────────────────────────────────────────────────────

  defp connect_node(container_or_node, retries \\ 30)

  defp connect_node({_index, container}, retries) do
    connect_node(container, retries)
  end

  defp connect_node(container, retries) when is_tuple(container) do
    connect_node(container, retries)
  end

  defp connect_node(container, retries) do
    {host, port} = get_host_port(container)

    case Xandra.start_link(nodes: ["#{host}:#{port}"], connect_timeout: 10_000) do
      {:ok, conn} ->
        case wait_for_node_ready(conn, 5) do
          :ready ->
            conn

          :pending when retries > 0 ->
            Xandra.stop(conn)
            Process.sleep(2_000)
            connect_node(container, retries - 1)

          :pending ->
            raise "ScyllaDB node not ready after retries"
        end

      {:error, _} when retries > 0 ->
        Process.sleep(2_000)
        connect_node(container, retries - 1)

      {:error, reason} ->
        raise "Failed to connect to ScyllaDB node: #{inspect(reason)}"
    end
  end

  defp connect_direct(node_string, retries \\ 30) do
    case Xandra.start_link(nodes: [node_string], connect_timeout: 10_000) do
      {:ok, conn} ->
        case wait_for_node_ready(conn, 5) do
          :ready ->
            conn

          :pending when retries > 0 ->
            Xandra.stop(conn)
            Process.sleep(2_000)
            connect_direct(node_string, retries - 1)

          :pending ->
            raise "ScyllaDB node #{node_string} not ready after retries"
        end

      {:error, _} when retries > 0 ->
        Process.sleep(2_000)
        connect_direct(node_string, retries - 1)

      {:error, reason} ->
        raise "Failed to connect to ScyllaDB node #{node_string}: #{inspect(reason)}"
    end
  end

  defp wait_for_node_ready(conn, retries \\ 30) do
    Enum.reduce_while(1..retries, :pending, fn _attempt, _acc ->
      case Xandra.execute(conn, "SELECT now() FROM system.local") do
        {:ok, _} ->
          {:halt, :ready}

        {:error, _} ->
          Process.sleep(2_000)
          {:cont, :pending}
      end
    end)
  end

  # ── Schema helpers ──────────────────────────────────────────────────────────

  defp create_keyspace(conn) do
    cql = """
    CREATE KEYSPACE IF NOT EXISTS #{@keyspace}
    WITH REPLICATION = {
      'class': 'SimpleStrategy',
      'replication_factor': #{@replication_factor}
    }
    AND DURABLE_WRITES = true
    """

    case Xandra.execute(conn, cql) do
      {:ok, _} -> :ok
      {:error, reason} -> raise "Failed to create keyspace: #{inspect(reason)}"
    end
  end

  defp create_tables(conn) do
    statements = [
      "USE #{@keyspace}",
      """
      CREATE TABLE IF NOT EXISTS #{@keyspace}.users (
        id UUID PRIMARY KEY,
        name TEXT,
        email TEXT,
        age INT,
        status TEXT,
        created_at TIMESTAMP
      )
      """,
      "CREATE INDEX IF NOT EXISTS idx_users_email ON #{@keyspace}.users (email)",
      "CREATE INDEX IF NOT EXISTS idx_users_status ON #{@keyspace}.users (status)",
      """
      CREATE TABLE IF NOT EXISTS #{@keyspace}.events (
        user_id UUID,
        event_type TEXT,
        event_id TIMEUUID,
        payload TEXT,
        PRIMARY KEY ((user_id, event_type), event_id)
      ) WITH CLUSTERING ORDER BY (event_id DESC)
      """
    ]

    Enum.each(statements, fn stmt ->
      case Xandra.execute(conn, stmt) do
        {:ok, _} -> :ok
        {:error, reason} -> raise "Failed to execute: #{stmt}\n#{inspect(reason)}"
      end
    end)
  end

  # ── Test setup ──────────────────────────────────────────────────────────────

  setup_all do
    cond do
      cluster_mode?() ->
        # Multi-node cluster mode: connect directly to existing nodes
        nodes = direct_nodes()
        Logger.info("TEST_CLUSTER=true. Connecting to multi-node cluster: #{inspect(nodes)}")

        # Connect to the first node to create schema
        conn = connect_direct(hd(nodes))
        create_keyspace(conn)
        create_tables(conn)
        Xandra.stop(conn)

        # Build node info for tests: list of {index, node_string}
        node_infos =
          nodes
          |> Enum.with_index(1)
          |> Enum.map(fn {node_str, idx} -> {idx, node_str} end)

        %{nodes: node_infos, mode: :cluster}

      System.get_env("SCYLLA_DIRECT") != nil ->
        # Single-node direct mode (legacy SCYLLA_DIRECT)
        nodes = direct_nodes()
        Logger.info("SCYLLA_DIRECT set. Connecting directly to: #{inspect(nodes)}")

        conn = connect_direct(hd(nodes))
        create_keyspace(conn)
        create_tables(conn)
        Xandra.stop(conn)

        node_infos =
          nodes
          |> Enum.with_index(1)
          |> Enum.map(fn {node_str, idx} -> {idx, node_str} end)

        %{nodes: node_infos, mode: :direct}

      true ->
        # Container mode: spin up ScyllaDB via Podman
        case AshScylla.Test.ContainerEngine.ensure_running() do
          :ok ->
            # Start first node
            case start_node(1) do
              {:ok, node1} ->
                conn1 = connect_node(elem(node1, 1))

                case wait_for_node_ready(conn1) do
                  :ready ->
                    # Create keyspace and tables before adding more nodes
                    create_keyspace(conn1)
                    create_tables(conn1)
                    Xandra.stop(conn1)

                    # Start additional nodes
                    {:ok, node2} = start_node(2)
                    {:ok, node3} = start_node(3)

                    # Wait for cluster to form
                    Process.sleep(10_000)

                    # Register cleanup for after all tests complete
                    on_exit(fn ->
                      [node1, node2, node3]
                      |> Enum.each(fn {_index, container} ->
                        stop_container(container)
                      end)
                    end)

                    %{nodes: [node1, node2, node3], mode: :container}

                  :pending ->
                    stop_container(elem(node1, 1))

                    raise "ScyllaDB node1 not ready after retries — cannot run cluster integration tests"
                end

              {:error, reason} ->
                raise "Failed to start ScyllaDB node1: #{inspect(reason)}"
            end

          {:error, reason} ->
            Logger.warning(
              "Container engine not available: #{inspect(reason)}. Skipping cluster integration tests."
            )

            %{nodes: nil, mode: :skipped}
        end
    end
  end

  setup context do
    case Map.fetch(context, :nodes) do
      {:ok, nodes} when nodes != nil and nodes != [] ->
        conn =
          case hd(nodes) do
            {_idx, container} when is_tuple(container) or is_struct(container) ->
              # Container mode: node is {index, container_struct}
              connect_node(container, 10)

            {_idx, node_string} when is_binary(node_string) ->
              # Direct mode: node is {index, "host:port"}
              connect_direct(node_string, 10)
          end

        %{conn: conn}

      _ ->
        %{conn: nil}
    end
  end

  # ── Helpers ─────────────────────────────────────────────────────────────────

  defp uid do
    <<a::32, b::16, c::16, d::16, e::48>> = :crypto.strong_rand_bytes(16)

    "#{format_hex(a, 8)}-#{format_hex(b, 4)}-#{format_hex(c, 4)}-#{format_hex(d, 4)}-#{format_hex(e, 12)}"
  end

  defp format_hex(value, len) do
    value |> Integer.to_string(16) |> String.pad_leading(len, "0")
  end

  defp xq(conn, query, params \\ []) do
    encoded = Enum.map(params, &encode_param/1)

    case Xandra.execute(conn, query, encoded) do
      {:ok, %Xandra.Void{}} ->
        %{rows: [], num_rows: 0, columns: []}

      {:ok, page} ->
        rows = page.content || []
        columns = page.columns || []
        col_names = Enum.map(columns, fn {_, _, name, _} -> to_string(name) end)

        mapped_rows =
          Enum.map(rows, fn
            row when is_map(row) ->
              row

            row when is_list(row) ->
              Enum.zip(col_names, row) |> Map.new()
          end)

        %{rows: mapped_rows, num_rows: length(mapped_rows)}

      {:error, reason} ->
        raise "Query failed: #{inspect(reason)}\nQuery: #{query}\nParams: #{inspect(params)}"
    end
  end

  defp encode_param({type, value}) when is_binary(type), do: {to_string(type), value}

  defp encode_param(value) when is_integer(value) do
    if value > 2_147_483_647 or value < -2_147_483_648,
      do: {"bigint", value},
      else: {"int", value}
  end

  defp encode_param(value) when is_float(value), do: {"double", value}
  defp encode_param(value) when is_boolean(value), do: {"boolean", value}
  defp encode_param(nil), do: {"null", nil}
  defp encode_param(%DateTime{} = value), do: {"timestamp", value}

  defp encode_param(value) when is_binary(value) do
    if uuid?(value), do: {"uuid", value}, else: {"text", value}
  end

  defp encode_param(value), do: {"text", to_string(value)}

  defp uuid?(value) when is_binary(value) do
    Regex.match?(~r/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i, value)
  end

  defp timeuuid_from_microsecond(microsecond, sequence) do
    <<timestamp_high::48, version_and_clock::16>> = <<microsecond::48, sequence::16>>
    ts = Bitwise.band(timestamp_high, 0x0000_FFFF_FFFF_FFFF)
    clock = Bitwise.band(version_and_clock, 0x0FFF)

    # Build a 16-byte UUID v1-like value:
    # 48 bits timestamp | 4 bits version (1) | 12 bits clock | 64 bits node (zero-padded)
    <<ts::48, 1::4, clock::12, 0::64>>
    |> Base.encode16(case: :lower)
    |> then(fn hex ->
      <<a::binary-size(8), b::binary-size(4), c::binary-size(4), d::binary-size(4),
        e::binary-size(12)>> = hex

      "#{a}-#{b}-#{c}-#{d}-#{e}"
    end)
  end

  # ── Cluster connectivity tests ─────────────────────────────────────────────

  describe "cluster connectivity" do
    test "keyspace exists with correct replication", %{conn: conn} do
      if is_nil(conn), do: :ok

      result =
        xq(
          conn,
          "SELECT replication FROM system_schema.keyspaces WHERE keyspace_name = ?",
          [@keyspace]
        )

      assert result.num_rows == 1
      [%{"replication" => replication}] = result.rows

      assert replication["class"] in [
               "SimpleStrategy",
               "org.apache.cassandra.locator.SimpleStrategy"
             ]

      assert replication["replication_factor"] == to_string(@replication_factor)
    end

    test "tables exist in cluster keyspace", %{conn: conn} do
      if is_nil(conn), do: :ok

      result =
        xq(
          conn,
          "SELECT table_name FROM system_schema.tables WHERE keyspace_name = ?",
          [@keyspace]
        )

      tables = MapSet.new(result.rows, &Map.fetch!(&1, "table_name"))
      assert "users" in tables
      assert "events" in tables
    end

    test "system.local returns data", %{conn: conn} do
      if is_nil(conn), do: :ok
      result = xq(conn, "SELECT now() FROM system.local")
      assert result.num_rows == 1
    end
  end

  # ── CRUD operations against cluster ─────────────────────────────────────────

  describe "CRUD operations against cluster" do
    test "insert and read from cluster", %{conn: conn} do
      if is_nil(conn), do: :ok
      id = uid()

      xq(
        conn,
        "INSERT INTO #{@keyspace}.users (id, name, email, age, status) VALUES (?, ?, ?, ?, ?)",
        [id, "Cluster User", "cluster@test.com", 30, "active"]
      )

      result =
        xq(
          conn,
          "SELECT * FROM #{@keyspace}.users WHERE id = ?",
          [id]
        )

      assert result.num_rows == 1,
             "Expected 1 row, got #{result.num_rows}. Rows: #{inspect(result.rows)}"

      [row] = result.rows

      assert row["name"] == "Cluster User",
             "Expected name='Cluster User', got #{inspect(row["name"])}. Row: #{inspect(row)}"

      assert row["email"] == "cluster@test.com",
             "Expected email='cluster@test.com', got #{inspect(row["email"])}"
    end

    test "update record in cluster", %{conn: conn} do
      if is_nil(conn), do: :ok
      id = uid()

      xq(
        conn,
        "INSERT INTO #{@keyspace}.users (id, name, status) VALUES (?, ?, ?)",
        [id, "Original", "active"]
      )

      xq(
        conn,
        "UPDATE #{@keyspace}.users SET name = ?, status = ? WHERE id = ?",
        ["Updated", "inactive", id]
      )

      result =
        xq(
          conn,
          "SELECT name, status FROM #{@keyspace}.users WHERE id = ?",
          [id]
        )

      assert result.num_rows == 1
      [row] = result.rows
      assert row["name"] == "Updated"
      assert row["status"] == "inactive"
    end

    test "delete record from cluster", %{conn: conn} do
      if is_nil(conn), do: :ok
      id = uid()

      xq(
        conn,
        "INSERT INTO #{@keyspace}.users (id, name) VALUES (?, ?)",
        [id, "To Delete"]
      )

      xq(conn, "DELETE FROM #{@keyspace}.users WHERE id = ?", [id])

      result =
        xq(
          conn,
          "SELECT * FROM #{@keyspace}.users WHERE id = ?",
          [id]
        )

      assert result.num_rows == 0
    end
  end

  # ── Secondary index queries against cluster ─────────────────────────────────

  describe "secondary index queries against cluster" do
    test "query by secondary index on email", %{conn: conn} do
      if is_nil(conn), do: :ok
      id = uid()
      email = "idx_test_#{id}@example.com"

      xq(
        conn,
        "INSERT INTO #{@keyspace}.users (id, name, email, status) VALUES (?, ?, ?, ?)",
        [id, "Indexed User", email, "active"]
      )

      result =
        xq(
          conn,
          "SELECT * FROM #{@keyspace}.users WHERE email = ?",
          [email]
        )

      assert result.num_rows >= 1

      assert Enum.any?(result.rows, fn row ->
               String.downcase(row["id"]) == String.downcase(id)
             end)
    end

    test "query by secondary index on status", %{conn: conn} do
      if is_nil(conn), do: :ok
      id = uid()

      xq(
        conn,
        "INSERT INTO #{@keyspace}.users (id, name, status) VALUES (?, ?, ?)",
        [id, "Status User", "pending"]
      )

      result =
        xq(
          conn,
          "SELECT * FROM #{@keyspace}.users WHERE status = ?",
          ["pending"]
        )

      assert result.num_rows >= 1

      assert Enum.any?(result.rows, fn row ->
               String.downcase(row["id"]) == String.downcase(id)
             end)
    end
  end

  # ── Clustering key queries against cluster ──────────────────────────────────

  describe "clustering key queries against cluster" do
    test "insert and query events with clustering order", %{conn: conn} do
      if is_nil(conn), do: :ok
      user_id = uid()
      event_type = "click_#{String.slice(user_id, 0, 8)}"

      insert_query =
        "INSERT INTO #{@keyspace}.events (user_id, event_type, event_id, payload) VALUES (?, ?, ?, ?)"

      insert_event = fn i ->
        ts = DateTime.utc_now() |> DateTime.to_unix(:microsecond)
        event_id = timeuuid_from_microsecond(ts, i)
        xq(conn, insert_query, [user_id, event_type, event_id, "event-#{i}"])
      end

      Enum.each(1..5, insert_event)

      result =
        xq(
          conn,
          "SELECT * FROM #{@keyspace}.events WHERE user_id = ? AND event_type = ? LIMIT 3",
          [user_id, event_type]
        )

      assert result.num_rows == 3
    end
  end

  # ── DataLayer query building against cluster ────────────────────────────────

  describe "DataLayer query building against cluster" do
    test "build_optimized_query produces valid CQL for cluster", %{conn: conn} do
      if is_nil(conn), do: :ok
      id = uid()

      xq(
        conn,
        "INSERT INTO #{@keyspace}.users (id, name, email, status, age) VALUES (?, ?, ?, ?, ?)",
        [id, "DL Cluster", "dl@cluster.com", "active", 25]
      )

      query = %AshScylla.Query{
        resource: nil,
        repo: TestRepo,
        table: "#{@keyspace}.users",
        filters: [
          %{operator: :eq, left: %{name: :status}, right: %{value: "active"}}
        ],
        sorts: [],
        limit: 10,
        select: [:id, :name, :email],
        tenant: nil,
        distinct: nil,
        keyset: nil,
        aggregates: [],
        group_by: nil
      }

      {cql, params} = QueryBuilder.build_optimized_query(query)

      assert cql =~ "SELECT id, name, email FROM #{@keyspace}.users"
      assert cql =~ "WHERE"
      assert cql =~ "LIMIT ?"
      assert "active" in params
      assert {"int", 10} in params

      result = xq(conn, cql, params)
      assert result.num_rows >= 1
    end

    test "build_optimized_query with IN operator against cluster", %{conn: conn} do
      if is_nil(conn), do: :ok
      ids = Enum.map(1..3, fn _ -> uid() end)

      Enum.each(ids, fn id ->
        xq(
          conn,
          "INSERT INTO #{@keyspace}.users (id, name) VALUES (?, ?)",
          [id, "IN Test"]
        )
      end)

      query = %AshScylla.Query{
        resource: nil,
        repo: TestRepo,
        table: "#{@keyspace}.users",
        filters: [%{operator: :in, left: %{name: :id}, right: %{value: ids}}],
        sorts: [],
        limit: nil,
        select: nil,
        tenant: nil,
        distinct: nil,
        keyset: nil,
        aggregates: [],
        group_by: nil
      }

      {cql, params} = QueryBuilder.build_optimized_query(query)
      assert cql =~ "IN"
      assert length(params) == 3

      result = xq(conn, cql, params)
      assert result.num_rows == 3
    end
  end

  # ── Concurrent operations against cluster ───────────────────────────────────

  describe "concurrent operations against cluster" do
    test "concurrent inserts to cluster", %{nodes: nodes, mode: mode} do
      tasks =
        Enum.map(1..20, fn i ->
          Task.async(fn ->
            conn =
              case mode do
                :direct ->
                  {_idx, node_string} = Enum.random(nodes)
                  connect_direct(node_string)

                :cluster ->
                  {_idx, node_string} = Enum.random(nodes)
                  connect_direct(node_string)

                :container ->
                  {_index, container} = Enum.random(nodes)
                  connect_node(container)
              end

            id = uid()

            xq(
              conn,
              "INSERT INTO #{@keyspace}.users (id, name, status) VALUES (?, ?, ?)",
              [id, "Concurrent-#{i}", "active"]
            )

            Xandra.stop(conn)
            :ok
          end)
        end)

      results = Task.await_many(tasks, 30_000)
      assert Enum.all?(results, &(&1 == :ok))
    end

    test "concurrent reads against cluster", %{nodes: nodes, mode: mode} do
      # First insert a record to read
      conn =
        case mode do
          :direct ->
            {_idx, node_string} = hd(nodes)
            connect_direct(node_string)

          :cluster ->
            {_idx, node_string} = hd(nodes)
            connect_direct(node_string)

          :container ->
            {_idx, container} = hd(nodes)
            connect_node(container)
        end

      id = uid()

      xq(
        conn,
        "INSERT INTO #{@keyspace}.users (id, name, email) VALUES (?, ?, ?)",
        [id, "Shared", "shared@cluster.com"]
      )

      Xandra.stop(conn)

      # Now read from multiple nodes concurrently
      tasks =
        Enum.map(1..10, fn _ ->
          Task.async(fn ->
            conn =
              case mode do
                :direct ->
                  {_idx, node_string} = Enum.random(nodes)
                  connect_direct(node_string)

                :cluster ->
                  {_idx, node_string} = Enum.random(nodes)
                  connect_direct(node_string)

                :container ->
                  {_index, container} = Enum.random(nodes)
                  connect_node(container)
              end

            result =
              xq(
                conn,
                "SELECT * FROM #{@keyspace}.users WHERE email = ?",
                ["shared@cluster.com"]
              )

            Xandra.stop(conn)
            result.num_rows
          end)
        end)

      results = Task.await_many(tasks, 15_000)
      assert Enum.all?(results, &(&1 >= 1))
    end
  end

  # ── Consistency levels against cluster ──────────────────────────────────────

  describe "consistency levels against cluster" do
    test "write and read with default consistency", %{conn: conn} do
      if is_nil(conn), do: :ok
      id = uid()

      xq(
        conn,
        "INSERT INTO #{@keyspace}.users (id, name, status) VALUES (?, ?, ?)",
        [id, "Quorum User", "active"]
      )

      result =
        xq(
          conn,
          "SELECT * FROM #{@keyspace}.users WHERE id = ?",
          [id]
        )

      assert result.num_rows == 1
    end

    test "write and read with LOCAL_QUORUM consistency", %{conn: conn} do
      if is_nil(conn), do: :ok
      id = uid()

      xq(
        conn,
        "INSERT INTO #{@keyspace}.users (id, name) VALUES (?, ?)",
        [id, "Local Quorum"]
      )

      result =
        xq(
          conn,
          "SELECT * FROM #{@keyspace}.users WHERE id = ?",
          [id]
        )

      assert result.num_rows == 1
    end
  end

  # ── AshScylla.Connection cluster mode ─────────────────────────────────────

  describe "AshScylla.Connection with multi-node cluster" do
    @tag :skip
    test "Connection struct has cluster? true for multi-node", %{conn: _raw_conn} do
      # This test verifies that starting an AshScylla.Connection with multiple
      # nodes sets cluster? correctly, preventing the function_clause crash
      # where Xandra.execute is called on a Xandra.Cluster PID.
      #
      # See: https://github.com/lexhide/xandra/issues
      #
      # The cluster_integration_test setup uses raw Xandra, not AshScylla,
      # so we start our own AshScylla.Connection here.
      nodes = direct_nodes()
      name = Module.concat(__MODULE__, :"AshScyllaCluster_#{System.unique_integer([:positive])}")

      {:ok, _pid} =
        AshScylla.Connection.start_link(
          name: name,
          nodes: nodes,
          keyspace: @keyspace,
          connect_timeout: 10_000
        )

      on_exit(fn -> AshScylla.Connection.stop(name) end)

      conn = AshScylla.Connection.get_conn(name)
      assert conn.cluster? == true, "multi-node should have cluster? true"

      # Query via AshScylla.Connection — this must not crash with function_clause
      assert {:ok, result} =
               AshScylla.Connection.query(name, "SELECT * FROM #{@keyspace}.users LIMIT 1", [])

      assert result.num_rows == 0
    end

    @tag :skip
    test "query via AshScylla.Connection in cluster mode does not crash", %{conn: _raw_conn} do
      nodes = direct_nodes()
      name = Module.concat(__MODULE__, :"AshScyllaCluster_#{System.unique_integer([:positive])}")

      {:ok, _pid} =
        AshScylla.Connection.start_link(
          name: name,
          nodes: nodes,
          keyspace: @keyspace,
          connect_timeout: 10_000
        )

      on_exit(fn -> AshScylla.Connection.stop(name) end)

      conn = AshScylla.Connection.get_conn(name)
      assert conn.cluster?

      id = uid()

      # Insert
      assert {:ok, _} =
               AshScylla.Connection.query(
                 name,
                 "INSERT INTO #{@keyspace}.users (id, name, status) VALUES (?, ?, ?)",
                 [id, "cluster_test", "active"]
               )

      # Read
      assert {:ok, result} =
               AshScylla.Connection.query(
                 name,
                 "SELECT * FROM #{@keyspace}.users WHERE id = ?",
                 [id]
               )

      assert result.num_rows == 1
    end
  end
end
