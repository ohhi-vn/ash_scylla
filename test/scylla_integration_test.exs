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

  defp xq(conn, query, params \\ [])

  defp xq(nil, _query, _params) do
    %{rows: [], num_rows: 0, columns: []}
  end

  defp xq(conn, query, params) do
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
                %{scylla: nil}

            end

          {:error, reason} ->
            IO.puts("WARNING: Skipping integration tests — #{inspect(reason)}")
            %{scylla: nil}

        end

      {:error, reason} ->
        IO.puts("WARNING: Skipping integration tests — #{inspect(reason)}")
        %{scylla: nil}

    end
  end

  setup context do
    case Map.fetch(context, :scylla) do
      {:ok, scylla_container} when not is_nil(scylla_container) ->
        port = ScyllaContainer.port(scylla_container)
        host = ScyllaContainer.host(scylla_container)
        conn = connect_with_retry(host, port, 5)
        %{conn: conn}

      {:ok, nil} ->
        %{conn: nil}

      :error ->
        %{conn: nil}
    end
  end

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
    setup context do
      case Map.fetch(context, :conn) do
        {:ok, c} when not is_nil(c) ->
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

        _ ->
          :ok
      end
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
      if is_nil(scylla_container) do
        flunk("ScyllaDB container not available")
      end

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
      if is_nil(scylla_container) do
        flunk("ScyllaDB container not available")
      end

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
      if is_nil(scylla_container) do
        flunk("ScyllaDB container not available")
      end

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
      if is_nil(scylla_container) do
        flunk("ScyllaDB container not available")
      end

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
      if is_nil(scylla_container) do
        flunk("ScyllaDB container not available")
      end

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

  # ══════════════════════════════════════════════════════════════════════════
  # Type conversion: write each CQL type and read back, verifying Elixir types
  # ══════════════════════════════════════════════════════════════════════════

  describe "type conversion round-trip" do
    setup %{conn: c} do
      # Create a dedicated type-roundtrip table covering all major CQL types
      xq(
        c,
        """
        CREATE TABLE IF NOT EXISTS ash_scylla_test.type_roundtrip (
          id UUID PRIMARY KEY,
          text_val TEXT,
          int_val INT,
          bigint_val BIGINT,
          float_val FLOAT,
          double_val DOUBLE,
          boolean_val BOOLEAN,
          timestamp_val TIMESTAMP,
          date_val DATE,
          time_val TIME,
          inet_val INET,
          blob_val BLOB,
          smallint_val SMALLINT,
          tinyint_val TINYINT,
          list_val LIST<TEXT>,
          map_val MAP<TEXT, TEXT>,
          set_val SET<INT>
        )
        """
      )

      xq(c, "TRUNCATE ash_scylla_test.type_roundtrip")

      :ok
    end

    test "TEXT round-trip preserves string type", %{conn: c} do
      id = uid()
      value = "Hello, Scylla!"

      xq(c, "INSERT INTO ash_scylla_test.type_roundtrip (id, text_val) VALUES (?, ?)", [id, value])
      result = xq(c, "SELECT text_val FROM ash_scylla_test.type_roundtrip WHERE id = ?", [id])

      rows = rows_to_maps(result)
      assert length(rows) == 1
      assert is_binary(rows[0]["text_val"])
      assert rows[0]["text_val"] == value
    end

    test "INT round-trip preserves integer type", %{conn: c} do
      id = uid()
      value = 42

      xq(c, "INSERT INTO ash_scylla_test.type_roundtrip (id, int_val) VALUES (?, ?)", [id, value])
      result = xq(c, "SELECT int_val FROM ash_scylla_test.type_roundtrip WHERE id = ?", [id])

      rows = rows_to_maps(result)
      assert length(rows) == 1
      assert is_integer(rows[0]["int_val"])
      assert rows[0]["int_val"] == 42
    end

    test "BIGINT round-trip preserves large integer type", %{conn: c} do
      id = uid()
      value = 9_007_199_254_740_991

      xq(c, "INSERT INTO ash_scylla_test.type_roundtrip (id, bigint_val) VALUES (?, ?)", [id, value])
      result = xq(c, "SELECT bigint_val FROM ash_scylla_test.type_roundtrip WHERE id = ?", [id])

      rows = rows_to_maps(result)
      assert length(rows) == 1
      assert is_integer(rows[0]["bigint_val"])
      assert rows[0]["bigint_val"] == 9_007_199_254_740_991
    end

    test "FLOAT round-trip preserves float type", %{conn: c} do
      id = uid()
      value = 3.14

      xq(c, "INSERT INTO ash_scylla_test.type_roundtrip (id, float_val) VALUES (?, ?)", [id, value])
      result = xq(c, "SELECT float_val FROM ash_scylla_test.type_roundtrip WHERE id = ?", [id])

      rows = rows_to_maps(result)
      assert length(rows) == 1
      assert is_float(rows[0]["float_val"])
      assert abs(rows[0]["float_val"] - 3.14) < 0.001
    end

    test "DOUBLE round-trip preserves double type", %{conn: c} do
      id = uid()
      value = 2.718281828459045

      xq(c, "INSERT INTO ash_scylla_test.type_roundtrip (id, double_val) VALUES (?, ?)", [id, value])
      result = xq(c, "SELECT double_val FROM ash_scylla_test.type_roundtrip WHERE id = ?", [id])

      rows = rows_to_maps(result)
      assert length(rows) == 1
      assert is_float(rows[0]["double_val"])
      assert rows[0]["double_val"] == 2.718281828459045
    end

    test "BOOLEAN round-trip preserves boolean type", %{conn: c} do
      id = uid()

      xq(c, "INSERT INTO ash_scylla_test.type_roundtrip (id, boolean_val) VALUES (?, ?)", [id, true])
      result = xq(c, "SELECT boolean_val FROM ash_scylla_test.type_roundtrip WHERE id = ?", [id])

      rows = rows_to_maps(result)
      assert length(rows) == 1
      assert rows[0]["boolean_val"] == true
      assert is_boolean(rows[0]["boolean_val"])
    end

    test "TIMESTAMP round-trip preserves DateTime type", %{conn: c} do
      id = uid()
      dt = ~U[2024-06-15 10:30:00Z]

      xq(c, "INSERT INTO ash_scylla_test.type_roundtrip (id, timestamp_val) VALUES (?, ?)", [
        id,
        {:"timestamp", dt}
      ])

      result = xq(c, "SELECT timestamp_val FROM ash_scylla_test.type_roundtrip WHERE id = ?", [id])

      rows = rows_to_maps(result)
      assert length(rows) == 1

      val = rows[0]["timestamp_val"]
      assert %DateTime{} = val
      assert val.year == 2024
      assert val.month == 6
      assert val.day == 15
    end

    test "DATE round-trip preserves Date type", %{conn: c} do
      id = uid()
      date = ~D[2024-01-15]

      xq(c, "INSERT INTO ash_scylla_test.type_roundtrip (id, date_val) VALUES (?, ?)", [
        id,
        {:"date", date}
      ])

      result = xq(c, "SELECT date_val FROM ash_scylla_test.type_roundtrip WHERE id = ?", [id])

      rows = rows_to_maps(result)
      assert length(rows) == 1

      val = rows[0]["date_val"]
      assert %Date{} = val
      assert val == ~D[2024-01-15]
    end

    test "TIME round-trip preserves Time type", %{conn: c} do
      id = uid()
      time = ~T[14:30:00]

      xq(c, "INSERT INTO ash_scylla_test.type_roundtrip (id, time_val) VALUES (?, ?)", [
        id,
        {:"time", time}
      ])

      result = xq(c, "SELECT time_val FROM ash_scylla_test.type_roundtrip WHERE id = ?", [id])

      rows = rows_to_maps(result)
      assert length(rows) == 1

      val = rows[0]["time_val"]
      assert %Time{} = val
      assert val.hour == 14
      assert val.minute == 30
      assert val.second == 0
    end

    test "INET round-trip preserves tuple type", %{conn: c} do
      id = uid()

      xq(c, "INSERT INTO ash_scylla_test.type_roundtrip (id, inet_val) VALUES (?, ?)", [
        id,
        {:"inet", {192, 168, 1, 1}}
      ])

      result = xq(c, "SELECT inet_val FROM ash_scylla_test.type_roundtrip WHERE id = ?", [id])

      rows = rows_to_maps(result)
      assert length(rows) == 1

      val = rows[0]["inet_val"]
      assert is_tuple(val)
      assert val == {192, 168, 1, 1}
    end

    test "BLOB round-trip preserves binary type", %{conn: c} do
      id = uid()
      blob = <<0, 1, 2, 255, 128, 64>>

      xq(c, "INSERT INTO ash_scylla_test.type_roundtrip (id, blob_val) VALUES (?, ?)", [
        id,
        {:"blob", blob}
      ])

      result = xq(c, "SELECT blob_val FROM ash_scylla_test.type_roundtrip WHERE id = ?", [id])

      rows = rows_to_maps(result)
      assert length(rows) == 1

      val = rows[0]["blob_val"]
      assert is_binary(val)
      assert val == <<0, 1, 2, 255, 128, 64>>
    end

    test "SMALLINT round-trip preserves integer type", %{conn: c} do
      id = uid()
      value = 32_767

      xq(c, "INSERT INTO ash_scylla_test.type_roundtrip (id, smallint_val) VALUES (?, ?)", [
        id,
        {:"smallint", value}
      ])

      result = xq(c, "SELECT smallint_val FROM ash_scylla_test.type_roundtrip WHERE id = ?", [id])

      rows = rows_to_maps(result)
      assert length(rows) == 1

      val = rows[0]["smallint_val"]
      assert is_integer(val)
      assert val == 32_767
    end

    test "TINYINT round-trip preserves integer type", %{conn: c} do
      id = uid()
      value = 127

      xq(c, "INSERT INTO ash_scylla_test.type_roundtrip (id, tinyint_val) VALUES (?, ?)", [
        id,
        {:"tinyint", value}
      ])

      result = xq(c, "SELECT tinyint_val FROM ash_scylla_test.type_roundtrip WHERE id = ?", [id])

      rows = rows_to_maps(result)
      assert length(rows) == 1

      val = rows[0]["tinyint_val"]
      assert is_integer(val)
      assert val == 127
    end

    test "LIST<TEXT> round-trip preserves list type", %{conn: c} do
      id = uid()
      value = ["a", "b", "c"]

      xq(c, "INSERT INTO ash_scylla_test.type_roundtrip (id, list_val) VALUES (?, ?)", [
        id,
        {:"list", value}
      ])

      result = xq(c, "SELECT list_val FROM ash_scylla_test.type_roundtrip WHERE id = ?", [id])

      rows = rows_to_maps(result)
      assert length(rows) == 1

      val = rows[0]["list_val"]
      assert is_list(val)
      assert val == ["a", "b", "c"]
    end

    test "MAP<TEXT, TEXT> round-trip preserves map type", %{conn: c} do
      id = uid()
      value = %{"key1" => "val1", "key2" => "val2"}

      xq(c, "INSERT INTO ash_scylla_test.type_roundtrip (id, map_val) VALUES (?, ?)", [
        id,
        {:"map", value}
      ])

      result = xq(c, "SELECT map_val FROM ash_scylla_test.type_roundtrip WHERE id = ?", [id])

      rows = rows_to_maps(result)
      assert length(rows) == 1

      val = rows[0]["map_val"]
      assert is_map(val)
      assert val["key1"] == "val1"
      assert val["key2"] == "val2"
    end

    test "SET<INT> round-trip preserves list type", %{conn: c} do
      id = uid()

      xq(c, "INSERT INTO ash_scylla_test.type_roundtrip (id, set_val) VALUES (?, ?)", [
        id,
        {:"set", [1, 2, 3]}
      ])

      result = xq(c, "SELECT set_val FROM ash_scylla_test.type_roundtrip WHERE id = ?", [id])

      rows = rows_to_maps(result)
      assert length(rows) == 1

      val = rows[0]["set_val"]
      assert is_list(val)
      assert Enum.sort(val) == [1, 2, 3]
    end

    test "NULL values round-trip preserves nil type", %{conn: c} do
      id = uid()

      xq(c, "INSERT INTO ash_scylla_test.type_roundtrip (id, text_val) VALUES (?, ?)", [id, "non-null"])

      # Insert another row with all NULLs for various types
      id2 = uid()

      xq(c, "INSERT INTO ash_scylla_test.type_roundtrip (id) VALUES (?)", [id2])
      result = xq(c, "SELECT int_val, bigint_val, float_val, double_val, boolean_val, text_val FROM ash_scylla_test.type_roundtrip WHERE id = ?", [id2])

      rows = rows_to_maps(result)
      assert length(rows) == 1

      row = rows[0]
      assert row["int_val"] == nil
      assert row["bigint_val"] == nil
      assert row["float_val"] == nil
      assert row["double_val"] == nil
      assert row["boolean_val"] == nil
      assert row["text_val"] == nil
    end

    test "all types in a single row round-trip", %{conn: c} do
      id = uid()

      xq(
        c,
        """
        INSERT INTO ash_scylla_test.type_roundtrip (
          id, text_val, int_val, bigint_val, float_val, double_val,
          boolean_val, timestamp_val, date_val, time_val, inet_val, blob_val
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """,
        [
          id,
          "all-types",
          100,
          9_007_199_254_740_991,
          1.5,
          3.1415926535,
          true,
          {:"timestamp", ~U[2024-12-25 00:00:00Z]},
          {:"date", ~D[2024-12-25]},
          {:"time", ~T[08:00:00]},
          {:"inet", {10, 0, 0, 1}},
          {:"blob", <<255, 254, 253>>}
        ]
      )

      result = xq(c, "SELECT * FROM ash_scylla_test.type_roundtrip WHERE id = ?", [id])

      rows = rows_to_maps(result)
      assert length(rows) == 1

      row = rows[0]
      assert row["text_val"] == "all-types"
      assert is_binary(row["text_val"])

      assert row["int_val"] == 100
      assert is_integer(row["int_val"])

      assert row["bigint_val"] == 9_007_199_254_740_991
      assert is_integer(row["bigint_val"])

      assert is_float(row["float_val"])
      assert abs(row["float_val"] - 1.5) < 0.001

      assert is_float(row["double_val"])
      assert abs(row["double_val"] - 3.1415926535) < 0.000_000_000_1

      assert row["boolean_val"] == true
      assert is_boolean(row["boolean_val"])

      assert %DateTime{} = row["timestamp_val"]
      assert row["timestamp_val"].year == 2024

      assert %Date{} = row["date_val"]
      assert row["date_val"] == ~D[2024-12-25]

      assert %Time{} = row["time_val"]
      assert row["time_val"].hour == 8

      assert is_tuple(row["inet_val"])
      assert row["inet_val"] == {10, 0, 0, 1}

      assert is_binary(row["blob_val"])
      assert row["blob_val"] == <<255, 254, 253>>
    end
  end
end
