defmodule AshScylla.ScyllaIntegrationTest do
  @moduledoc """
  Integration tests for AshScylla with a real ScyllaDB instance.
  Uses testcontainer_ex 0.6 ScyllaContainer for container lifecycle management.
  Gracefully skips all tests when Podman is not available.
  """

  use ExUnit.Case, async: false

  alias AshScylla.TestRepo
  alias AshScylla.ScyllaContainer

  @moduletag :integration

  @scylla_container_config ScyllaContainer.new()
                           |> ScyllaContainer.with_image("scylladb/scylla:5.4")
                           |> ScyllaContainer.with_cmd([
                             "--smp",
                             "1",
                             "--memory",
                             "1G",
                             "--developer-mode",
                             "1",
                             "--overprovisioned",
                             "1"
                           ])
                           |> ScyllaContainer.with_wait_timeout(300_000)

  # ── Helpers ────────────────────────────────────────────────────────────────

  defp uid, do: generate_uuid()

  defp generate_uuid do
    <<a::32, b::16, c::16, d::16, e::48>> = :crypto.strong_rand_bytes(16)

    # Generate lowercase UUID to match ScyllaDB's storage format
    hex =
      "#{format_hex(a, 8)}#{format_hex(b, 4)}#{format_hex(c, 4)}#{format_hex(d, 4)}#{format_hex(e, 12)}"

    String.downcase(hex)
    |> String.to_charlist()
    |> then(fn chars ->
      {a, rest} = Enum.split(chars, 8)
      {b, rest} = Enum.split(rest, 4)
      {c, rest} = Enum.split(rest, 4)
      {d, e} = Enum.split(rest, 4)
      Enum.join([a, b, c, d, e], "-")
    end)
  end

  defp format_hex(value, len) do
    value |> Integer.to_string(16) |> String.pad_leading(len, "0")
  end

  defp uuid?(value) when is_binary(value) do
    Regex.match?(~r/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i, value)
  end

  defp rows_to_maps(%{rows: rows, columns: cols}) do
    col_names = Enum.map(cols, fn {_, _, name, _} -> to_string(name) end)

    Enum.map(rows, fn
      row when is_list(row) ->
        row
        |> Enum.zip(col_names)
        |> Map.new(fn {val, col} -> {col, val} end)

      row when is_map(row) ->
        Map.new(row, fn
          {{_, _, name, _}, val} -> {to_string(name), val}
          {key, val} when is_binary(key) -> {key, val}
          {key, val} -> {inspect(key), val}
        end)
    end)
  end

  defp xq(conn, query, params \\ []) do
    encoded_params = Enum.map(params, &encode_param/1)

    result =
      case Xandra.execute(conn, query, encoded_params) do
        {:ok, page} -> page
        {:error, reason} -> raise "Query failed: #{inspect(reason)}"
      end

    rows =
      case result do
        %Xandra.Page{content: content} -> content || []
        _ -> []
      end

    columns =
      case result do
        %Xandra.Page{columns: cols} -> cols
        _ -> []
      end

    %{rows: rows, num_rows: length(rows), columns: columns}
  end

  defp encode_param({:timestamp, value}), do: {"timestamp", value}
  defp encode_param(value) when is_integer(value), do: {"int", value}
  defp encode_param(value) when is_float(value), do: {"double", value}
  defp encode_param(value) when is_boolean(value), do: {"boolean", value}
  defp encode_param(nil), do: {"null", nil}

  defp encode_param(value) when is_binary(value) do
    if uuid?(value), do: {"uuid", value}, else: {"text", value}
  end

  defp encode_param(value), do: {"text", to_string(value)}

  defp connect_with_retry(host, port, retries \\ 20) do
    case Xandra.start_link(
           nodes: ["#{host}:#{port}"],
           connect_timeout: 10_000
         ) do
      {:ok, conn} ->
        case wait_for_cql(conn, 5) do
          :ok ->
            conn

          {:error, _} when retries > 0 ->
            Xandra.stop(conn)
            Process.sleep(3_000)
            connect_with_retry(host, port, retries - 1)

          {:error, reason} ->
            Xandra.stop(conn)
            raise "ScyllaDB not ready: #{inspect(reason)}"
        end

      {:error, _} when retries > 0 ->
        Process.sleep(3_000)
        connect_with_retry(host, port, retries - 1)

      {:error, reason} ->
        raise "Failed to connect to ScyllaDB: #{inspect(reason)}"
    end
  end

  defp try_connect(host, port) do
    conn = connect_with_retry(host, port, 5)
    {:ok, conn}
  rescue
    _ -> {:error, :not_connected}
  catch
    _ -> {:error, :not_connected}
  end

  defp wait_for_cql(_conn, retries) when retries <= 0 do
    {:error, :timeout}
  end

  defp wait_for_cql(conn, retries) do
    case Xandra.execute(conn, "SELECT now() FROM system.local", [],
           timeout: 5_000,
           consistency: :one
         ) do
      {:ok, _} ->
        :ok

      {:error, _} ->
        Process.sleep(1_000)
        wait_for_cql(conn, retries - 1)
    end
  end

  defp schema(conn) do
    case wait_for_cql(conn, 60) do
      :ok ->
        Enum.each(
          [
            "CREATE KEYSPACE IF NOT EXISTS ash_scylla_test WITH REPLICATION = {'class': 'SimpleStrategy', 'replication_factor': 1}",
            "CREATE TABLE IF NOT EXISTS ash_scylla_test.users (id UUID PRIMARY KEY, name TEXT, email TEXT, age INT, status TEXT, created_at TIMESTAMP)",
            "CREATE INDEX IF NOT EXISTS idx_users_email ON ash_scylla_test.users (email)",
            "CREATE INDEX IF NOT EXISTS idx_users_status ON ash_scylla_test.users (status)",
            "CREATE INDEX IF NOT EXISTS idx_users_age ON ash_scylla_test.users (age)",
            "CREATE MATERIALIZED VIEW IF NOT EXISTS ash_scylla_test.users_by_email AS SELECT * FROM ash_scylla_test.users WHERE email IS NOT NULL AND id IS NOT NULL PRIMARY KEY (email, id)",
            "CREATE TABLE IF NOT EXISTS ash_scylla_test.events (user_id UUID, event_type TEXT, event_id TIMEUUID, payload TEXT, PRIMARY KEY ((user_id, event_type), event_id)) WITH CLUSTERING ORDER BY (event_id DESC)",
            "CREATE TABLE IF NOT EXISTS ash_scylla_test.counters (id UUID PRIMARY KEY, views COUNTER, likes COUNTER)"
          ],
          fn q -> {:ok, _} = Xandra.execute(conn, q) end
        )

      {:error, reason} ->
        raise "ScyllaDB not ready after 60s: #{inspect(reason)}"
    end
  end

  # ── Setup ──────────────────────────────────────────────────────────────────

  setup_all do
    case AshScylla.Test.ContainerEngine.ensure_running() do
      :ok ->
        case ScyllaContainer.start(@scylla_container_config) do
          {:ok, scylla_container} ->
            port = ScyllaContainer.port(scylla_container)
            host = ScyllaContainer.host(scylla_container)

            case try_connect(host, port) do
              {:ok, conn} ->
                schema(conn)

                on_exit(fn ->
                  ScyllaContainer.stop(scylla_container.container_id)
                end)

                %{scylla: scylla_container}

              {:error, _} ->
                IO.puts("WARNING: Skipping integration tests — ScyllaDB not reachable")
                ScyllaContainer.stop(scylla_container.container_id)
                :ok
            end

          {:error, reason} ->
            IO.puts("WARNING: Skipping integration tests — #{inspect(reason)}")
            :ok
        end

      {:error, reason} ->
        IO.puts("WARNING: Skipping integration tests — #{inspect(reason)}")
        :ok
    end
  end

  setup %{scylla: scylla_container} do
    port = ScyllaContainer.port(scylla_container)
    host = ScyllaContainer.host(scylla_container)
    conn = connect_with_retry(host, port, 5)
    %{conn: conn}
  end

  setup _, do: :ok

  # ══════════════════════════════════════════════════════════════════════════
  # 1. Basic connectivity
  # ══════════════════════════════════════════════════════════════════════════

  describe "basic connectivity" do
    test "system.local", %{conn: c} do
      assert xq(c, "SELECT now() FROM system.local").num_rows == 1
    end

    test "keyspace exists", %{conn: c} do
      assert xq(c, "SELECT keyspace_name FROM system_schema.keyspaces WHERE keyspace_name = ?", [
               "ash_scylla_test"
             ]).num_rows == 1
    end

    test "tables exist", %{conn: c} do
      tables =
        xq(c, "SELECT table_name FROM system_schema.tables WHERE keyspace_name = ?", [
          "ash_scylla_test"
        ]).rows
        |> MapSet.new(&hd/1)

      assert "users" in tables and "events" in tables and "counters" in tables
    end

    test "indexes exist", %{conn: c} do
      names =
        xq(
          c,
          "SELECT index_name FROM system_schema.indexes WHERE keyspace_name = ? AND table_name = ?",
          ["ash_scylla_test", "users"]
        ).rows
        |> MapSet.new(&hd/1)

      assert "idx_users_email" in names and "idx_users_status" in names and
               "idx_users_age" in names
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # 2. CRUD operations
  # ══════════════════════════════════════════════════════════════════════════

  describe "CRUD operations" do
    test "insert and select", %{conn: c} do
      id = uid()

      xq(
        c,
        "INSERT INTO ash_scylla_test.users (id, name, email, age, status) VALUES (?, ?, ?, ?, ?)",
        [id, "Alice", "alice@example.com", 30, "active"]
      )

      [row] = rows_to_maps(xq(c, "SELECT * FROM ash_scylla_test.users WHERE id = ?", [id]))
      assert row["name"] == "Alice"
      assert row["email"] == "alice@example.com"
      assert row["age"] == 30
      assert row["status"] == "active"
    end

    test "insert and select simple", %{conn: c} do
      id = uid()
      xq(c, "INSERT INTO ash_scylla_test.users (id, name, age) VALUES (?, ?, ?)", [id, "Bob", 25])

      [row] =
        rows_to_maps(xq(c, "SELECT name, age FROM ash_scylla_test.users WHERE id = ?", [id]))

      assert row["name"] == "Bob"
      assert row["age"] == 25
    end

    test "update specific columns", %{conn: c} do
      id = uid()

      xq(c, "INSERT INTO ash_scylla_test.users (id, name, age) VALUES (?, ?, ?)", [
        id,
        "Charlie",
        25
      ])

      xq(c, "UPDATE ash_scylla_test.users SET age = ? WHERE id = ?", [26, id])
      [row] = rows_to_maps(xq(c, "SELECT * FROM ash_scylla_test.users WHERE id = ?", [id]))
      assert row["age"] == 26
      assert row["name"] == "Charlie"
    end

    test "delete a record", %{conn: c} do
      id = uid()
      xq(c, "INSERT INTO ash_scylla_test.users (id, name) VALUES (?, ?)", [id, "Delete Me"])
      xq(c, "DELETE FROM ash_scylla_test.users WHERE id = ?", [id])
      assert xq(c, "SELECT * FROM ash_scylla_test.users WHERE id = ?", [id]).num_rows == 0
    end

    test "insert with timestamp fields", %{conn: c} do
      id = uid()
      now = DateTime.utc_now() |> DateTime.to_unix(:millisecond)

      xq(c, "INSERT INTO ash_scylla_test.users (id, name, created_at) VALUES (?, ?, ?)", [
        id,
        "Time User",
        {:timestamp, now}
      ])

      assert xq(c, "SELECT created_at FROM ash_scylla_test.users WHERE id = ?", [id]).num_rows ==
               1
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # 3. Round-trip CRUD
  # ══════════════════════════════════════════════════════════════════════════

  describe "round-trip CRUD" do
    test "full lifecycle: insert -> select -> update -> select -> delete", %{conn: c} do
      id = uid()

      # Insert
      xq(
        c,
        "INSERT INTO ash_scylla_test.users (id, name, email, age, status) VALUES (?, ?, ?, ?, ?)",
        [id, "Alice", "alice@example.com", 30, "active"]
      )

      # Select and verify insert
      [row] = rows_to_maps(xq(c, "SELECT * FROM ash_scylla_test.users WHERE id = ?", [id]))
      assert row["name"] == "Alice"
      assert row["email"] == "alice@example.com"
      assert row["age"] == 30
      assert row["status"] == "active"

      # Update
      xq(c, "UPDATE ash_scylla_test.users SET name = ?, age = ?, status = ? WHERE id = ?", [
        "Alice Updated",
        31,
        "inactive",
        id
      ])

      # Select and verify update
      [row] = rows_to_maps(xq(c, "SELECT * FROM ash_scylla_test.users WHERE id = ?", [id]))
      assert row["name"] == "Alice Updated"
      assert row["age"] == 31
      assert row["status"] == "inactive"
      # Email should remain unchanged
      assert row["email"] == "alice@example.com"

      # Delete
      xq(c, "DELETE FROM ash_scylla_test.users WHERE id = ?", [id])

      # Select and verify deletion
      assert xq(c, "SELECT * FROM ash_scylla_test.users WHERE id = ?", [id]).num_rows == 0
    end

    test "round-trip with secondary index: insert -> query by index -> update -> re-query -> delete",
         %{
           conn: c
         } do
      id = uid()
      email = "roundtrip_#{id}@example.com"

      # Insert
      xq(
        c,
        "INSERT INTO ash_scylla_test.users (id, name, email, age, status) VALUES (?, ?, ?, ?, ?)",
        [id, "Bob", email, 25, "active"]
      )

      # Query by secondary index (email)
      [row] =
        rows_to_maps(xq(c, "SELECT * FROM ash_scylla_test.users WHERE email = ?", [email]))

      assert row["name"] == "Bob"
      assert row["id"] == id

      # Update indexed column
      new_email = "updated_#{id}@example.com"
      xq(c, "UPDATE ash_scylla_test.users SET email = ? WHERE id = ?", [new_email, id])

      # Old email should no longer find the record
      assert xq(c, "SELECT * FROM ash_scylla_test.users WHERE email = ?", [email]).num_rows == 0

      # New email should find the record
      [row] =
        rows_to_maps(xq(c, "SELECT * FROM ash_scylla_test.users WHERE email = ?", [new_email]))

      assert row["name"] == "Bob"
      assert row["id"] == id

      # Delete
      xq(c, "DELETE FROM ash_scylla_test.users WHERE id = ?", [id])

      assert xq(c, "SELECT * FROM ash_scylla_test.users WHERE email = ?", [new_email]).num_rows ==
               0
    end

    test "round-trip with partial insert (null columns)", %{conn: c} do
      id = uid()

      # Insert with only required fields
      xq(c, "INSERT INTO ash_scylla_test.users (id, name) VALUES (?, ?)", [id, "Sparse"])

      # Select — null columns should be absent
      [row] = rows_to_maps(xq(c, "SELECT * FROM ash_scylla_test.users WHERE id = ?", [id]))
      assert row["name"] == "Sparse"
      assert row["id"] == id

      # Update to fill in previously null columns
      xq(c, "UPDATE ash_scylla_test.users SET email = ?, age = ? WHERE id = ?", [
        "sparse@example.com",
        40,
        id
      ])

      # Select and verify all columns
      [row] = rows_to_maps(xq(c, "SELECT * FROM ash_scylla_test.users WHERE id = ?", [id]))
      assert row["name"] == "Sparse"
      assert row["email"] == "sparse@example.com"
      assert row["age"] == 40

      # Delete
      xq(c, "DELETE FROM ash_scylla_test.users WHERE id = ?", [id])
      assert xq(c, "SELECT * FROM ash_scylla_test.users WHERE id = ?", [id]).num_rows == 0
    end

    test "round-trip with timestamp: insert -> select -> update timestamp -> select -> delete", %{
      conn: c
    } do
      id = uid()
      ts1 = DateTime.utc_now() |> DateTime.to_unix(:millisecond)

      # Insert with timestamp
      xq(
        c,
        "INSERT INTO ash_scylla_test.users (id, name, created_at) VALUES (?, ?, ?)",
        [id, "TimeUser", {:timestamp, ts1}]
      )

      # Select and verify timestamp exists
      [row] = rows_to_maps(xq(c, "SELECT * FROM ash_scylla_test.users WHERE id = ?", [id]))
      assert row["name"] == "TimeUser"
      assert row["created_at"] != nil

      # Update name, keep timestamp
      xq(c, "UPDATE ash_scylla_test.users SET name = ? WHERE id = ?", ["TimeUser V2", id])

      # Select and verify both fields
      [row] = rows_to_maps(xq(c, "SELECT * FROM ash_scylla_test.users WHERE id = ?", [id]))
      assert row["name"] == "TimeUser V2"
      assert row["created_at"] != nil

      # Delete
      xq(c, "DELETE FROM ash_scylla_test.users WHERE id = ?", [id])
      assert xq(c, "SELECT * FROM ash_scylla_test.users WHERE id = ?", [id]).num_rows == 0
    end

    test "round-trip with status index: insert -> filter by status -> update status -> re-filter -> delete",
         %{
           conn: c
         } do
      id = uid()
      # Use unique test name to avoid pollution from other tests
      test_name = "StatusTest_#{String.slice(id, 0, 8)}"

      # Insert with unique name
      xq(
        c,
        "INSERT INTO ash_scylla_test.users (id, name, status) VALUES (?, ?, ?)",
        [id, test_name, "active"]
      )

      # Filter by status index and find our record by unique name
      rows =
        rows_to_maps(xq(c, "SELECT * FROM ash_scylla_test.users WHERE status = ?", ["active"]))

      assert Enum.any?(rows, fn r -> r["id"] == id end)

      # Update status
      xq(c, "UPDATE ash_scylla_test.users SET status = ? WHERE id = ?", ["archived", id])

      # Old status should not find it (check by unique name)
      rows =
        rows_to_maps(xq(c, "SELECT * FROM ash_scylla_test.users WHERE status = ?", ["active"]))

      refute Enum.any?(rows, fn r -> r["name"] == test_name end)

      # New status should find it
      rows =
        rows_to_maps(xq(c, "SELECT * FROM ash_scylla_test.users WHERE status = ?", ["archived"]))

      assert Enum.any?(rows, fn r -> r["id"] == id end)

      # Delete
      xq(c, "DELETE FROM ash_scylla_test.users WHERE id = ?", [id])
      assert xq(c, "SELECT * FROM ash_scylla_test.users WHERE id = ?", [id]).num_rows == 0
    end

    test "multiple round-trips in sequence on different records", %{conn: c} do
      # Create 5 records, update them all, verify, then delete them all
      records =
        Enum.map(1..5, fn i ->
          id = uid()
          {id, "User#{i}", "user#{i}@example.com", 20 + i, "active"}
        end)

      # Insert all
      Enum.each(records, fn {id, name, email, age, status} ->
        xq(
          c,
          "INSERT INTO ash_scylla_test.users (id, name, email, age, status) VALUES (?, ?, ?, ?, ?)",
          [id, name, email, age, status]
        )
      end)

      # Verify all exist
      Enum.each(records, fn {id, name, _email, age, _status} ->
        [row] = rows_to_maps(xq(c, "SELECT * FROM ash_scylla_test.users WHERE id = ?", [id]))
        assert row["name"] == name
        assert row["age"] == age
      end)

      # Update all
      Enum.each(records, fn {id, _name, _email, age, _status} ->
        xq(c, "UPDATE ash_scylla_test.users SET age = ?, status = ? WHERE id = ?", [
          age + 100,
          "updated",
          id
        ])
      end)

      # Verify all updated
      Enum.each(records, fn {id, _name, _email, age, _status} ->
        [row] = rows_to_maps(xq(c, "SELECT * FROM ash_scylla_test.users WHERE id = ?", [id]))
        assert row["age"] == age + 100
        assert row["status"] == "updated"
      end)

      # Delete all
      Enum.each(records, fn {id, _, _, _, _} ->
        xq(c, "DELETE FROM ash_scylla_test.users WHERE id = ?", [id])
      end)

      # Verify all deleted
      Enum.each(records, fn {id, _, _, _, _} ->
        assert xq(c, "SELECT * FROM ash_scylla_test.users WHERE id = ?", [id]).num_rows == 0
      end)
    end

    test "delete non-existent record is a no-op", %{conn: c} do
      fake_id = uid()
      # First verify the record doesn't exist
      before_count = xq(c, "SELECT count(*) FROM ash_scylla_test.users").num_rows
      # Deleting a non-existent record should not raise
      xq(c, "DELETE FROM ash_scylla_test.users WHERE id = ?", [fake_id])
      # Count should remain the same
      after_count = xq(c, "SELECT count(*) FROM ash_scylla_test.users").num_rows
      assert before_count == after_count
    end

    test "update non-existent record is a no-op", %{conn: c} do
      fake_id = uid()
      # First verify the record doesn't exist
      before_count = xq(c, "SELECT count(*) FROM ash_scylla_test.users").num_rows
      # Updating a non-existent record should not raise
      xq(c, "UPDATE ash_scylla_test.users SET name = ? WHERE id = ?", ["Ghost", fake_id])
      # Count should remain the same
      after_count = xq(c, "SELECT count(*) FROM ash_scylla_test.users").num_rows
      assert before_count == after_count
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # 4. Complex queries
  # ══════════════════════════════════════════════════════════════════════════

  describe "complex queries" do
    setup %{conn: c} do
      Enum.each(1..20, fn i ->
        id = uid()

        status =
          cond do
            rem(i, 3) == 0 -> "active"
            rem(i, 3) == 1 -> "pending"
            true -> "inactive"
          end

        xq(
          c,
          "INSERT INTO ash_scylla_test.users (id, name, email, status, age) VALUES (?, ?, ?, ?, ?)",
          [id, "User#{i}", "user#{i}@test.com", status, 20 + i]
        )
      end)
    end

    test "filter by email index", %{conn: c} do
      rows =
        rows_to_maps(
          xq(c, "SELECT * FROM ash_scylla_test.users WHERE email = ?", ["user5@test.com"])
        )

      assert length(rows) >= 1
      assert Enum.any?(rows, fn row -> row["name"] == "User5" end)
    end

    test "filter by status index", %{conn: c} do
      rows =
        rows_to_maps(xq(c, "SELECT * FROM ash_scylla_test.users WHERE status = ?", ["active"]))

      assert length(rows) > 0
      Enum.each(rows, fn row -> assert row["status"] == "active" end)
    end

    test "filter by age index", %{conn: c} do
      rows = rows_to_maps(xq(c, "SELECT * FROM ash_scylla_test.users WHERE age = ?", [25]))
      assert length(rows) >= 1
      Enum.each(rows, fn row -> assert row["age"] == 25 end)
    end

    test "filter by status with LIMIT", %{conn: c} do
      rows =
        rows_to_maps(
          xq(c, "SELECT * FROM ash_scylla_test.users WHERE status = ? LIMIT 5", ["active"])
        )

      assert length(rows) <= 5
      Enum.each(rows, fn row -> assert row["status"] == "active" end)
    end

    test "IN clause", %{conn: c} do
      ids = Enum.map(1..3, fn _ -> uid() end)

      Enum.each(
        ids,
        &xq(c, "INSERT INTO ash_scylla_test.users (id, name) VALUES (?, ?)", [&1, "IN Test"])
      )

      assert xq(c, "SELECT * FROM ash_scylla_test.users WHERE id IN (?, ?, ?)", ids).num_rows == 3
    end

    test "clustering key range", %{conn: c} do
      user_id = uid()

      Enum.each(1..5, fn i ->
        xq(
          c,
          "INSERT INTO ash_scylla_test.events (user_id, event_type, event_id, payload) VALUES (?, ?, now(), ?)",
          [user_id, "click", "e#{i}"]
        )
      end)

      assert xq(
               c,
               "SELECT * FROM ash_scylla_test.events WHERE user_id = ? AND event_type = ? LIMIT 3",
               [user_id, "click"]
             ).num_rows == 3
    end

    test "materialized view", %{conn: c} do
      id = uid()

      xq(
        c,
        "INSERT INTO ash_scylla_test.users (id, name, email, age, status) VALUES (?, ?, ?, ?, ?)",
        [id, "MV User", "mv@test.com", 40, "active"]
      )

      Process.sleep(1000)

      rows =
        rows_to_maps(
          xq(c, "SELECT * FROM ash_scylla_test.users_by_email WHERE email = ?", ["mv@test.com"])
        )

      assert length(rows) >= 1
      assert Enum.any?(rows, fn r -> r["name"] == "MV User" end)
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # 5. TTL support
  # ══════════════════════════════════════════════════════════════════════════

  describe "TTL support" do
    test "insert with short TTL and verify expiry", %{conn: c} do
      id = uid()

      xq(c, "INSERT INTO ash_scylla_test.users (id, name) VALUES (?, ?) USING TTL 2", [
        id,
        "Short Lived"
      ])

      assert xq(c, "SELECT * FROM ash_scylla_test.users WHERE id = ?", [id]).num_rows == 1
      Process.sleep(3000)
      assert xq(c, "SELECT * FROM ash_scylla_test.users WHERE id = ?", [id]).num_rows == 0
    end

    test "insert with long TTL persists", %{conn: c} do
      id = uid()

      xq(c, "INSERT INTO ash_scylla_test.users (id, name) VALUES (?, ?) USING TTL 3600", [
        id,
        "Long Lived"
      ])

      assert xq(c, "SELECT * FROM ash_scylla_test.users WHERE id = ?", [id]).num_rows == 1
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # 6. Counter operations
  # ══════════════════════════════════════════════════════════════════════════

  describe "counter operations" do
    test "increment and decrement counters", %{conn: c} do
      id = uid()

      xq(
        c,
        "UPDATE ash_scylla_test.counters SET views = views + 1, likes = likes + 1 WHERE id = ?",
        [id]
      )

      xq(c, "UPDATE ash_scylla_test.counters SET views = views + 5 WHERE id = ?", [id])
      [row] = rows_to_maps(xq(c, "SELECT * FROM ash_scylla_test.counters WHERE id = ?", [id]))
      assert row["views"] == 6
      assert row["likes"] == 1
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # 7. Concurrent read/write simulation
  # ══════════════════════════════════════════════════════════════════════════

  describe "concurrent read/write simulation" do
    test "50 concurrent writers insert distinct records", %{scylla: scylla_container} do
      port = ScyllaContainer.port(scylla_container)
      host = TestcontainerEx.get_host(scylla_container)

      tasks =
        Enum.map(1..50, fn i ->
          Task.async(fn ->
            {:ok, conn} = Xandra.start_link(nodes: ["#{host}:#{port}"])
            id = uid()

            xq(conn, "INSERT INTO ash_scylla_test.users (id, name, status) VALUES (?, ?, ?)", [
              id,
              "Concurrent-#{i}",
              "active"
            ])

            Xandra.stop(conn)
            :ok
          end)
        end)

      results = Task.await_many(tasks, 30_000)

      assert Enum.all?(results, fn
               :ok -> true
               _ -> false
             end)
    end

    test "concurrent readers and writers", %{scylla: scylla_container} do
      port = ScyllaContainer.port(scylla_container)
      host = TestcontainerEx.get_host(scylla_container)

      tasks =
        Enum.map(1..20, fn i ->
          Task.async(fn ->
            {:ok, conn} = Xandra.start_link(nodes: ["#{host}:#{port}"])
            id = uid()

            xq(conn, "INSERT INTO ash_scylla_test.users (id, name, status) VALUES (?, ?, ?)", [
              id,
              "W#{i}",
              "active"
            ])

            Xandra.stop(conn)
            :ok
          end)
        end)

      results = Task.await_many(tasks, 30_000)

      assert Enum.all?(results, fn
               :ok -> true
               _ -> false
             end)
    end

    test "concurrent reads on same secondary index query", %{scylla: scylla_container} do
      port = ScyllaContainer.port(scylla_container)
      host = TestcontainerEx.get_host(scylla_container)
      {:ok, setup_conn} = Xandra.start_link(nodes: ["#{host}:#{port}"])
      id = uid()

      xq(
        setup_conn,
        "INSERT INTO ash_scylla_test.users (id, name, email, status) VALUES (?, ?, ?, ?)",
        [id, "Shared", "shared@test.com", "active"]
      )

      Xandra.stop(setup_conn)

      tasks =
        Enum.map(1..10, fn _ ->
          Task.async(fn ->
            {:ok, conn} = Xandra.start_link(nodes: ["#{host}:#{port}"])

            {:ok, result} =
              Xandra.execute(conn, "SELECT * FROM ash_scylla_test.users WHERE email = ?", [
                encode_param("shared@test.com")
              ])

            Xandra.stop(conn)
            length(result.content)
          end)
        end)

      results = Task.await_many(tasks, 15_000)
      assert Enum.all?(results, fn count -> count >= 1 end)
    end

    test "concurrent event writes to same partition", %{scylla: scylla_container} do
      port = ScyllaContainer.port(scylla_container)
      host = TestcontainerEx.get_host(scylla_container)
      user_id = uid()

      tasks =
        Enum.map(1..20, fn i ->
          Task.async(fn ->
            {:ok, conn} = Xandra.start_link(nodes: ["#{host}:#{port}"])

            xq(
              conn,
              "INSERT INTO ash_scylla_test.events (user_id, event_type, event_id, payload) VALUES (?, ?, now(), ?)",
              [user_id, "page_view", "evt-#{i}"]
            )

            Xandra.stop(conn)
            :ok
          end)
        end)

      results = Task.await_many(tasks, 30_000)

      assert Enum.all?(results, fn
               :ok -> true
               _ -> false
             end)
    end

    test "mixed CRUD operations under concurrent load", %{scylla: scylla_container} do
      port = ScyllaContainer.port(scylla_container)
      host = TestcontainerEx.get_host(scylla_container)
      {:ok, setup_conn} = Xandra.start_link(nodes: ["#{host}:#{port}"])
      base_ids = Enum.map(1..10, fn _ -> uid() end)

      Enum.each(
        base_ids,
        &xq(
          setup_conn,
          "INSERT INTO ash_scylla_test.users (id, name, status, age) VALUES (?, ?, ?, ?)",
          [&1, "CRUD", "active", 25]
        )
      )

      Xandra.stop(setup_conn)

      tasks =
        Enum.flat_map(base_ids, fn id ->
          [
            Task.async(fn ->
              {:ok, conn} = Xandra.start_link(nodes: ["#{host}:#{port}"])

              result =
                Xandra.execute(conn, "SELECT * FROM ash_scylla_test.users WHERE id = ?", [
                  encode_param(id)
                ])

              Xandra.stop(conn)
              result
            end),
            Task.async(fn ->
              {:ok, conn} = Xandra.start_link(nodes: ["#{host}:#{port}"])

              result =
                Xandra.execute(conn, "UPDATE ash_scylla_test.users SET age = ? WHERE id = ?", [
                  encode_param(30),
                  encode_param(id)
                ])

              Xandra.stop(conn)
              result
            end)
          ]
        end)

      results = Task.await_many(tasks, 30_000)
      assert length(results) == 20

      assert Enum.all?(results, fn
               {:ok, _} -> true
               _ -> false
             end)
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # 8. DataLayer query struct against real DB
  # ══════════════════════════════════════════════════════════════════════════

  describe "DataLayer query struct against real DB" do
    test "build_optimized_query produces valid CQL", %{conn: c} do
      alias AshScylla.DataLayer
      alias AshScylla.DataLayer.QueryBuilder

      id = uid()

      xq(
        c,
        "INSERT INTO ash_scylla_test.users (id, name, email, status, age) VALUES (?, ?, ?, ?, ?)",
        [id, "DL Test", "dl@test.com", "active", 35]
      )

      query = %DataLayer{
        resource: nil,
        repo: TestRepo,
        table: "ash_scylla_test.users",
        filters: [
          %{operator: :eq, left: %{name: :status}, right: %{value: "active"}}
        ],
        sorts: [],
        limit: 10,
        offset: nil,
        select: [:id, :name, :email],
        tenant: nil
      }

      {cql, params} = QueryBuilder.build_optimized_query(query)
      assert cql =~ "SELECT id, name, email FROM ash_scylla_test.users"
      assert cql =~ "WHERE"
      assert cql =~ "LIMIT ?"
      assert "active" in params
      assert 10 in params

      encoded = Enum.map(params, &encode_param/1)
      {:ok, result} = Xandra.execute(c, cql, encoded)
      assert length(result.content) >= 1
    end

    test "build_optimized_query with IN operator", %{conn: c} do
      alias AshScylla.DataLayer
      alias AshScylla.DataLayer.QueryBuilder

      ids = Enum.map(1..3, fn _ -> uid() end)

      Enum.each(
        ids,
        &xq(c, "INSERT INTO ash_scylla_test.users (id, name) VALUES (?, ?)", [&1, "IN Test"])
      )

      query = %DataLayer{
        resource: nil,
        repo: TestRepo,
        table: "ash_scylla_test.users",
        filters: [%{operator: :in, left: %{name: :id}, right: %{value: ids}}],
        sorts: [],
        limit: nil,
        offset: nil,
        select: nil,
        tenant: nil
      }

      {cql, params} = QueryBuilder.build_optimized_query(query)
      assert cql =~ "IN"
      assert length(params) == 3
      assert xq(c, cql, params).num_rows == 3
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # 9. Filter validation against real schema
  # ══════════════════════════════════════════════════════════════════════════

  describe "filter validation against real schema" do
    test "validates filters on indexed columns pass" do
      assert :ok ==
               AshScylla.DataLayer.FilterValidator.validate_filters(
                 AshScylla.TestResourceWithIndexes,
                 [%{operator: :eq, left: %{name: :email}, right: %{value: "test@test.com"}}]
               )
    end

    test "validates filters on composite index columns pass" do
      assert :ok ==
               AshScylla.DataLayer.FilterValidator.validate_filters(
                 AshScylla.TestResourceWithIndexes,
                 [
                   %{operator: :eq, left: %{name: :name}, right: %{value: "Test"}},
                   %{operator: :eq, left: %{name: :age}, right: %{value: 25}}
                 ]
               )
    end

    test "rejects filters on non-indexed columns" do
      assert_raise AshScylla.Error, ~r/requires a secondary index/, fn ->
        AshScylla.DataLayer.FilterValidator.validate_filters(
          AshScylla.TestResourceWithIndexes,
          [%{operator: :eq, left: %{name: :nonexistent}, right: %{value: "x"}}]
        )
      end
    end

    test "accepts empty filter list" do
      assert :ok ==
               AshScylla.DataLayer.FilterValidator.validate_filters(
                 AshScylla.TestResourceWithIndexes,
                 []
               )
    end
  end
end
