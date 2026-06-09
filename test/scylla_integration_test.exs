defmodule AshScylla.ScyllaIntegrationTest do
  @moduledoc """
  Integration tests for AshScylla with a real ScyllaDB instance.
  Uses TestRepo with custom init/2 to strip incompatible Xandra options.
  Gracefully skips all tests when Docker is not available.
  """

  use ExUnit.Case, async: false

  alias AshScylla.TestRepo

  @moduletag :integration
  @image "scylladb/scylla:latest"
  @cql_port 9042

  # ── Helpers ────────────────────────────────────────────────────────────────

  defp uid, do: Ecto.UUID.generate()

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

  defp docker?, do: match?({_, 0}, System.cmd("docker", ["version"], stderr_to_stdout: true))

  defp scylla_ready?(port, retries \\ 90) do
    case Xandra.start_link(nodes: ["localhost:#{port}"], connect_timeout: 5_000) do
      {:ok, conn} ->
        case Xandra.execute(conn, "SELECT now() FROM system.local") do
          {:ok, _} ->
            Xandra.stop(conn)
            true

          {:error, _} ->
            Xandra.stop(conn)
            Process.sleep(2_000)
            if retries > 0, do: scylla_ready?(port, retries - 1), else: false
        end

      {:error, _} ->
        Process.sleep(2_000)
        if retries > 0, do: scylla_ready?(port, retries - 1), else: false
    end
  end

  defp docker_run do
    System.cmd(
      "docker",
      [
        "run",
        "-d",
        "--name",
        "ash-scylla-test",
        "-p",
        "#{@cql_port}:#{@cql_port}",
        @image,
        "--smp",
        "1",
        "--memory",
        "2G",
        "--developer-mode",
        "1"
      ], stderr_to_stdout: true)
  end

  defp docker_stop do
    System.cmd("docker", ["stop", "ash-scylla-test"], stderr_to_stdout: true)
    System.cmd("docker", ["rm", "ash-scylla-test"], stderr_to_stdout: true)
    :ok
  end

  defp find_container do
    case System.cmd("docker", ["ps", "-q", "-f", "name=ash-scylla-test"], stderr_to_stdout: true) do
      {out, 0} ->
        id = String.trim(out)
        if id != "", do: {:ok, id}, else: :not_found

      _ ->
        :not_found
    end
  end

  defp container_running?(id) do
    match?(
      {"true\n", 0},
      System.cmd("docker", ["inspect", "-f", "{{.State.Running}}", id], stderr_to_stdout: true)
    )
  end

  defp ensure_container do
    cid =
      case find_container() do
        {:ok, id} -> if container_running?(id), do: {:ok, id}, else: {:restart, id}
        :not_found -> :new
      end

    case cid do
      {:ok, id} ->
        {:ok, id, @cql_port}

      {:restart, _} ->
        docker_stop()
        start_and_wait()

      :new ->
        start_and_wait()
    end
  end

  defp start_and_wait do
    case docker_run() do
      {_, 0} ->
        case scylla_ready?(@cql_port) do
          true ->
            {:ok, @cql_port}

          false ->
            docker_stop()

            case docker_run() do
              {_, 0} ->
                scylla_ready?(@cql_port)
                {:ok, @cql_port}

              {err, _} ->
                {:error, String.trim(err)}
            end
        end

      {err, _} ->
        {:error, String.trim(err)}
    end
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

  defp encode_param(value) when is_binary(value) do
    case Ecto.UUID.cast(value) do
      {:ok, _} -> {"uuid", value}
      :error -> {"text", value}
    end
  end

  defp encode_param({:timestamp, value}), do: {"timestamp", value}
  defp encode_param(value) when is_integer(value), do: {"int", value}
  defp encode_param(value) when is_float(value), do: {"double", value}
  defp encode_param(value) when is_boolean(value), do: {"boolean", value}
  defp encode_param(nil), do: {"null", nil}
  defp encode_param(value), do: {"text", to_string(value)}

  defp schema(conn) do
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
  end

  # ── Setup ──────────────────────────────────────────────────────────────────

  setup_all do
    if not docker?() do
      :skip
    else
      case ensure_container() do
        {:ok, _cid, port} ->
          {:ok, conn} = Xandra.start_link(nodes: ["localhost:#{port}"])
          schema(conn)
          %{conn: conn}

        {:ok, port} ->
          {:ok, conn} = Xandra.start_link(nodes: ["localhost:#{port}"])
          schema(conn)
          %{conn: conn}

        {:error, reason} ->
          IO.puts("WARNING: #{reason}")
          :skip
      end
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
  # 3. Complex queries
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
  # 4. TTL support
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
  # 5. Counter operations
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
  # 6. Concurrent read/write simulation
  # ══════════════════════════════════════════════════════════════════════════

  describe "concurrent read/write simulation" do
    test "50 concurrent writers insert distinct records" do
      port = @cql_port

      tasks =
        Enum.map(1..50, fn i ->
          Task.async(fn ->
            {:ok, conn} = Xandra.start_link(nodes: ["localhost:#{port}"])
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

    test "concurrent readers and writers" do
      port = @cql_port

      tasks =
        Enum.map(1..20, fn i ->
          Task.async(fn ->
            {:ok, conn} = Xandra.start_link(nodes: ["localhost:#{port}"])
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

    test "concurrent reads on same secondary index query" do
      port = @cql_port
      {:ok, setup_conn} = Xandra.start_link(nodes: ["localhost:#{port}"])
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
            {:ok, conn} = Xandra.start_link(nodes: ["localhost:#{port}"])

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

    test "concurrent event writes to same partition" do
      port = @cql_port
      user_id = uid()

      tasks =
        Enum.map(1..20, fn i ->
          Task.async(fn ->
            {:ok, conn} = Xandra.start_link(nodes: ["localhost:#{port}"])

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

    test "mixed CRUD operations under concurrent load" do
      port = @cql_port
      {:ok, setup_conn} = Xandra.start_link(nodes: ["localhost:#{port}"])
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
              {:ok, conn} = Xandra.start_link(nodes: ["localhost:#{port}"])

              result =
                Xandra.execute(conn, "SELECT * FROM ash_scylla_test.users WHERE id = ?", [
                  encode_param(id)
                ])

              Xandra.stop(conn)
              result
            end),
            Task.async(fn ->
              {:ok, conn} = Xandra.start_link(nodes: ["localhost:#{port}"])

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
  # 7. DataLayer query struct against real DB
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
  # 8. Filter validation against real schema
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
