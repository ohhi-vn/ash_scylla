defmodule AshScylla.ClusterIntegrationTest do
  @moduledoc """
  Integration tests for AshScylla against a real ScyllaDB cluster.

  Uses testcontainer_ex 0.6 (Podman) to spin up multiple ScyllaDB containers
  and verifies the data layer works correctly across the cluster.

  Run with: mix test test/ash_scylla/cluster_integration_test.exs --only integration
  """

  use ExUnit.Case, async: false

  require Logger

  alias AshScylla.DataLayer
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

  # ── Container helpers ───────────────────────────────────────────────────────

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

  defp connect_node(container, retries \\ 30) do
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

                %{nodes: [node1, node2, node3]}

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

        %{nodes: nil}
    end
  end

  setup context do
    case Map.fetch(context, :nodes) do
      {:ok, nodes} when nodes != [] ->
        {_index, container} = hd(nodes)
        conn = connect_node(container, 10)
        %{conn: conn}

      _ ->
        raise "ScyllaDB cluster nodes not available — setup_all failed"
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
              IO.puts("[DEBUG] Row is map: #{inspect(row)}")
              row

            row when is_list(row) ->
              IO.puts("[DEBUG] Row is list: #{inspect(row)}, col_names: #{inspect(col_names)}")
              Enum.zip(col_names, row) |> Map.new()
          end)

        %{rows: mapped_rows, num_rows: length(mapped_rows)}

      {:error, reason} ->
        raise "Query failed: #{inspect(reason)}\nQuery: #{query}\nParams: #{inspect(params)}"
    end
  end

  defp encode_param(value) when is_integer(value), do: {"int", value}
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

    <<ts::48, 1::4, clock::12>>
    |> Base.encode16(case: :lower)
    |> String.downcase()
    |> then(fn hex ->
      <<a::binary-size(8), b::binary-size(4), c::binary-size(4), d::binary-size(4),
        e::binary-size(12)>> = hex

      "#{a}-#{b}-#{c}-#{d}-#{e}"
    end)
  end

  # ── Cluster connectivity tests ─────────────────────────────────────────────

  describe "cluster connectivity" do
    test "keyspace exists with correct replication", %{conn: conn} do
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
      result = xq(conn, "SELECT now() FROM system.local")
      assert result.num_rows == 1
    end
  end

  # ── CRUD operations against cluster ─────────────────────────────────────────

  describe "CRUD operations against cluster" do
    test "insert and read from cluster", %{conn: conn} do
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
      assert Enum.any?(result.rows, fn row -> row["id"] == id end)
    end

    test "query by secondary index on status", %{conn: conn} do
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
      assert Enum.any?(result.rows, fn row -> row["id"] == id end)
    end
  end

  # ── Clustering key queries against cluster ──────────────────────────────────

  describe "clustering key queries against cluster" do
    test "insert and query events with clustering order", %{conn: conn} do
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
      id = uid()

      xq(
        conn,
        "INSERT INTO #{@keyspace}.users (id, name, email, status, age) VALUES (?, ?, ?, ?, ?)",
        [id, "DL Cluster", "dl@cluster.com", "active", 25]
      )

      query = %DataLayer{
        resource: nil,
        repo: TestRepo,
        table: "#{@keyspace}.users",
        filters: [
          %{operator: :eq, left: %{name: :status}, right: %{value: "active"}}
        ],
        sorts: [],
        limit: 10,
        offset: nil,
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
      assert 10 in params

      result = xq(conn, cql, params)
      assert result.num_rows >= 1
    end

    test "build_optimized_query with IN operator against cluster", %{conn: conn} do
      ids = Enum.map(1..3, fn _ -> uid() end)

      Enum.each(ids, fn id ->
        xq(
          conn,
          "INSERT INTO #{@keyspace}.users (id, name) VALUES (?, ?)",
          [id, "IN Test"]
        )
      end)

      query = %DataLayer{
        resource: nil,
        repo: TestRepo,
        table: "#{@keyspace}.users",
        filters: [%{operator: :in, left: %{name: :id}, right: %{value: ids}}],
        sorts: [],
        limit: nil,
        offset: nil,
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
    test "concurrent inserts to cluster", %{nodes: nodes} do
      tasks =
        Enum.map(1..20, fn i ->
          Task.async(fn ->
            # Pick a random node to connect to
            {_index, container} = Enum.random(nodes)
            conn = connect_node(container)

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

    test "concurrent reads against cluster", %{nodes: nodes} do
      # First insert a record to read
      [node1 | _] = nodes
      {_idx, container1} = node1
      conn1 = connect_node(container1)
      id = uid()

      xq(
        conn1,
        "INSERT INTO #{@keyspace}.users (id, name, email) VALUES (?, ?, ?)",
        [id, "Shared", "shared@cluster.com"]
      )

      Xandra.stop(conn1)

      # Now read from multiple nodes concurrently
      tasks =
        Enum.map(1..10, fn _ ->
          Task.async(fn ->
            {_index, container} = Enum.random(nodes)
            conn = connect_node(container)

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
end
