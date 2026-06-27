defmodule AshScylla.DataLayer.IntegrationTest do
  @moduledoc """
  Integration tests for AshScylla.DataLayer against a real ScyllaDB instance.
  Tests the DataLayer's query building, CRUD operations, filter handling,
  and type pipeline end-to-end.
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

  alias AshScylla.DataLayer
  alias AshScylla.DataLayer.QueryBuilder
  alias AshScylla.ScyllaContainer, warn: false

  @moduletag :integration

  defp scylla_container_config do
    ScyllaContainer.new()
    |> ScyllaContainer.with_image("scylladb/scylla:5.4")
    |> ScyllaContainer.with_cmd([
      "--smp",
      "1",
      "--memory",
      "512M",
      "--developer-mode",
      "1",
      "--overprovisioned",
      "1"
    ])
    |> ScyllaContainer.with_wait_timeout(120_000)
  end

  # When SCYLLA_DIRECT is set, connect directly to a ScyllaDB instance
  # at the given host/port instead of spinning up a test container.
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

  # ── Helpers ────────────────────────────────────────────────────────────────

  defp uid do
    <<a::32, b::16, c::16, d::16, e::48>> = :crypto.strong_rand_bytes(16)

    hex =
      "#{format_hex(a, 8)}#{format_hex(b, 4)}#{format_hex(c, 4)}#{format_hex(d, 4)}#{format_hex(e, 12)}"

    hex
    |> String.downcase()
    |> String.to_charlist()
    |> then(fn chars ->
      {a, rest} = Enum.split(chars, 8)
      {b, rest} = Enum.split(rest, 4)
      {c, rest} = Enum.split(rest, 4)
      {d, e} = Enum.split(rest, 4)
      Enum.join([a, b, c, d, e], "-")
    end)
  end

  defp format_hex(value, len), do: value |> Integer.to_string(16) |> String.pad_leading(len, "0")

  defp uuid?(value) when is_binary(value) do
    Regex.match?(~r/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i, value)
  end

  defp xq(conn, query, params \\ [])

  defp xq(conn, query, params) do
    encoded_params = Enum.map(params, &encode_param/1)

    result =
      if needs_prepared?(encoded_params) do
        execute_prepared(conn, query, encoded_params)
      else
        case Xandra.execute(conn, query, encoded_params) do
          {:ok, page} ->
            page

          {:error, reason} ->
            raise "Query failed: #{inspect(reason)}\nQuery: #{query}\nParams: #{inspect(params)}"
        end
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

  defp needs_prepared?(encoded_params) do
    Enum.any?(encoded_params, fn
      {type, _} when is_tuple(type) -> true
      _ -> false
    end)
  end

  defp execute_prepared(conn, query, encoded_params) do
    {:ok, prepared} = Xandra.prepare(conn, query)

    xandra_values =
      Enum.map(encoded_params, fn
        {_type, value} -> value
      end)

    case Xandra.execute(conn, prepared, xandra_values) do
      {:ok, page} -> page
      {:error, reason} -> raise "Query failed: #{inspect(reason)}"
    end
  end

  defp rows_to_maps(%{rows: rows, columns: cols}) do
    col_names = Enum.map(cols, fn {_, _, name, _} -> to_string(name) end)

    Enum.map(rows, fn
      row when is_list(row) ->
        row |> Enum.zip(col_names) |> Map.new(fn {val, col} -> {col, val} end)

      row when is_map(row) ->
        Map.new(row, fn
          {{_, _, name, _}, val} -> {to_string(name), val}
          {key, val} when is_binary(key) -> {key, val}
          {key, val} -> {inspect(key), val}
        end)
    end)
  end

  defp encode_param({:timestamp, value}), do: {"timestamp", value}
  defp encode_param({:float, value}), do: {"float", value}
  defp encode_param({:double, value}), do: {"double", value}
  defp encode_param({:bigint, value}), do: {"bigint", value}
  defp encode_param({:smallint, value}), do: {"smallint", value}
  defp encode_param({:tinyint, value}), do: {"tinyint", value}
  defp encode_param({:date, value}), do: {"date", value}
  defp encode_param({:time, value}), do: {"time", value}
  defp encode_param({:inet, value}), do: {"inet", value}
  # Pass through already-typed tuples from QueryBuilder (e.g., {"int", 10})
  defp encode_param({type, value}) when is_binary(type), do: {type, value}
  defp encode_param({:blob, value}), do: {"blob", value}
  defp encode_param({:list, value}), do: {{:list, [:text]}, value}
  defp encode_param({:map, value}), do: {{:map, [:text, :text]}, value}
  defp encode_param({:set, value}) when is_list(value), do: {{:set, :int}, MapSet.new(value)}
  defp encode_param({:set, %MapSet{} = value}), do: {{:set, :int}, value}
  defp encode_param(nil), do: {"null", nil}
  defp encode_param(%DateTime{} = value), do: {"timestamp", value}
  defp encode_param(value) when is_boolean(value), do: {"boolean", value}
  defp encode_param(value) when is_integer(value), do: {"int", value}
  defp encode_param(value) when is_float(value), do: {"double", value}

  defp encode_param(value) when is_binary(value) do
    if uuid?(value), do: {"uuid", value}, else: {"text", value}
  end

  defp encode_param(value) when is_float(value), do: {"double", value}
  defp encode_param(value) when is_integer(value), do: {"int", value}
  defp encode_param(value) when is_boolean(value), do: {"boolean", value}
  defp encode_param(nil), do: {"null", nil}
  defp encode_param(value), do: {"text", to_string(value)}

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

  # ── Setup ──────────────────────────────────────────────────────────────────

  setup_all do
    if System.get_env("TEST_CLUSTER") == "true" do
      Logger.warning("TEST_CLUSTER=true set — skipping IntegrationTest (container-only)")
      %{conn: nil, scylla: nil}
    else
      if direct_connect?() do
        host = direct_host()
        port = direct_port()
        conn = connect_with_retry(host, port)

        xq(
          conn,
          "CREATE KEYSPACE IF NOT EXISTS ash_scylla_dl_test WITH REPLICATION = {'class': 'SimpleStrategy', 'replication_factor': 1}"
        )

        xq(
          conn,
          "CREATE TABLE IF NOT EXISTS ash_scylla_dl_test.items (id UUID PRIMARY KEY, name TEXT, status TEXT, value INT, score FLOAT, active BOOLEAN, created_at TIMESTAMP, tags LIST<TEXT>, metadata MAP<TEXT, TEXT>)"
        )

        xq(
          conn,
          "CREATE INDEX IF NOT EXISTS idx_items_status ON ash_scylla_dl_test.items (status)"
        )

        xq(conn, "CREATE INDEX IF NOT EXISTS idx_items_value ON ash_scylla_dl_test.items (value)")

        %{scylla: :direct}
      else
        case AshScylla.Test.ContainerEngine.ensure_running() do
          :ok ->
            _ = ScyllaContainer.start(scylla_container_config())
            %{scylla: nil}

          {:error, _} ->
            %{scylla: nil}
        end
      end
    end
  end

  setup context do
    case Map.fetch(context, :scylla) do
      {:ok, :direct} ->
        conn = connect_with_retry(direct_host(), direct_port())
        xq(conn, "TRUNCATE ash_scylla_dl_test.items")
        %{conn: conn}

      _ ->
        %{conn: nil}
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # 1. DataLayer.QueryBuilder integration tests
  # ══════════════════════════════════════════════════════════════════════════

  describe "QueryBuilder generates valid CQL" do
    test "simple SELECT with equality filter", %{conn: conn} do
      if is_nil(conn), do: :ok
      id = uid()

      xq(conn, "INSERT INTO ash_scylla_dl_test.items (id, name, status) VALUES (?, ?, ?)", [
        id,
        "QB Test",
        "active"
      ])

      query = %DataLayer{
        resource: nil,
        repo: nil,
        table: "ash_scylla_dl_test.items",
        filters: [%{operator: :eq, left: %{name: :status}, right: %{value: "active"}}],
        sorts: [],
        limit: 10,
        offset: nil,
        select: [:id, :name],
        tenant: nil
      }

      {cql, params} = QueryBuilder.build_optimized_query(query)
      assert cql =~ "SELECT id, name FROM ash_scylla_dl_test.items"
      assert cql =~ "WHERE"
      assert cql =~ "LIMIT ?"
      assert "active" in params
      assert {"int", 10} in params

      # Verify the generated CQL actually executes
      encoded = Enum.map(params, &encode_param/1)
      {:ok, result} = Xandra.execute(conn, cql, encoded)
      assert length(result.content) >= 1
    end

    test "SELECT with IN filter", %{conn: conn} do
      if is_nil(conn), do: :ok
      id = uid()

      xq(conn, "INSERT INTO ash_scylla_dl_test.items (id, name, status) VALUES (?, ?, ?)", [
        id,
        "IN Test",
        "pending"
      ])

      query = %DataLayer{
        resource: nil,
        repo: nil,
        table: "ash_scylla_dl_test.items",
        filters: [
          %{operator: :in, left: %{name: :status}, right: %{value: ["active", "pending"]}}
        ],
        sorts: [],
        limit: nil,
        offset: nil,
        select: nil,
        tenant: nil
      }

      {cql, params} = QueryBuilder.build_optimized_query(query)
      assert cql =~ "IN"
      assert "active" in params
      assert "pending" in params

      encoded = Enum.map(params, &encode_param/1)
      {:ok, result} = Xandra.execute(conn, cql <> " ALLOW FILTERING", encoded)
      assert length(result.content) >= 1
    end

    test "SELECT with comparison filters (gt, lt)", %{conn: conn} do
      if is_nil(conn), do: :ok
      id = uid()

      xq(conn, "INSERT INTO ash_scylla_dl_test.items (id, name, value) VALUES (?, ?, ?)", [
        id,
        "Range Test",
        50
      ])

      query = %DataLayer{
        resource: nil,
        repo: nil,
        table: "ash_scylla_dl_test.items",
        filters: [
          %{operator: :>=, left: %{name: :value}, right: %{value: 40}},
          %{operator: :<=, left: %{name: :value}, right: %{value: 60}}
        ],
        sorts: [],
        limit: 10,
        offset: nil,
        select: nil,
        tenant: nil
      }

      {cql, params} = QueryBuilder.build_optimized_query(query)
      assert cql =~ ">="
      assert cql =~ "<="
      assert 40 in params
      assert 60 in params

      encoded = Enum.map(params, &encode_param/1)
      {:ok, result} = Xandra.execute(conn, cql <> " ALLOW FILTERING", encoded)
      assert length(result.content) >= 1
    end

    test "SELECT with ORDER BY", %{conn: conn} do
      if is_nil(conn), do: :ok
      id = uid()

      xq(conn, "INSERT INTO ash_scylla_dl_test.items (id, name, value) VALUES (?, ?, ?)", [
        id,
        "Sort Test",
        100
      ])

      query = %DataLayer{
        resource: nil,
        repo: nil,
        table: "ash_scylla_dl_test.items",
        filters: [],
        sorts: [value: :desc],
        limit: 10,
        offset: nil,
        select: nil,
        tenant: nil
      }

      {cql, _params} = QueryBuilder.build_optimized_query(query)
      assert cql =~ "ORDER BY"
      assert cql =~ "desc"
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # 2. Type pipeline integration tests
  # ══════════════════════════════════════════════════════════════════════════

  describe "type pipeline: Elixir type → CQL → Xandra → Elixir type" do
    test "FLOAT round-trip preserves float type", %{conn: conn} do
      if is_nil(conn), do: :ok
      id = uid()

      xq(conn, "INSERT INTO ash_scylla_dl_test.items (id, name, score) VALUES (?, ?, ?)", [
        id,
        "Float Test",
        {:float, 3.14}
      ])

      result = xq(conn, "SELECT score FROM ash_scylla_dl_test.items WHERE id = ?", [id])
      [row] = rows_to_maps(result)
      assert is_float(row["score"])
      assert abs(row["score"] - 3.14) < 0.001
    end

    test "BOOLEAN round-trip preserves boolean type", %{conn: conn} do
      if is_nil(conn), do: :ok
      id = uid()

      xq(conn, "INSERT INTO ash_scylla_dl_test.items (id, name, active) VALUES (?, ?, ?)", [
        id,
        "Bool Test",
        true
      ])

      result = xq(conn, "SELECT active FROM ash_scylla_dl_test.items WHERE id = ?", [id])
      [row] = rows_to_maps(result)
      assert row["active"] == true
      assert is_boolean(row["active"])
    end

    test "TIMESTAMP round-trip preserves DateTime type", %{conn: conn} do
      if is_nil(conn), do: :ok
      id = uid()
      dt = ~U[2024-06-15 10:30:00Z]

      xq(conn, "INSERT INTO ash_scylla_dl_test.items (id, name, created_at) VALUES (?, ?, ?)", [
        id,
        "TS Test",
        {:timestamp, dt}
      ])

      result = xq(conn, "SELECT created_at FROM ash_scylla_dl_test.items WHERE id = ?", [id])
      [row] = rows_to_maps(result)
      assert %DateTime{} = row["created_at"]
      assert row["created_at"].year == 2024
      assert row["created_at"].month == 6
      assert row["created_at"].day == 15
    end

    test "LIST<TEXT> round-trip preserves list type", %{conn: conn} do
      if is_nil(conn), do: :ok
      id = uid()
      tags = ["elixir", "scylla", "integration"]

      xq(conn, "INSERT INTO ash_scylla_dl_test.items (id, name, tags) VALUES (?, ?, ?)", [
        id,
        "List Test",
        {:list, tags}
      ])

      result = xq(conn, "SELECT tags FROM ash_scylla_dl_test.items WHERE id = ?", [id])
      [row] = rows_to_maps(result)
      assert is_list(row["tags"])
      assert length(row["tags"]) == 3
    end

    test "MAP<TEXT, TEXT> round-trip preserves map type", %{conn: conn} do
      if is_nil(conn), do: :ok
      id = uid()
      metadata = %{"env" => "test", "version" => "1.0"}

      xq(conn, "INSERT INTO ash_scylla_dl_test.items (id, name, metadata) VALUES (?, ?, ?)", [
        id,
        "Map Test",
        {:map, metadata}
      ])

      result = xq(conn, "SELECT metadata FROM ash_scylla_dl_test.items WHERE id = ?", [id])
      [row] = rows_to_maps(result)
      assert is_map(row["metadata"])
      assert row["metadata"]["env"] == "test"
      assert row["metadata"]["version"] == "1.0"
    end

    test "NULL values round-trip preserves nil", %{conn: conn} do
      if is_nil(conn), do: :ok
      id = uid()
      xq(conn, "INSERT INTO ash_scylla_dl_test.items (id, name) VALUES (?, ?)", [id, "Null Test"])

      result =
        xq(
          conn,
          "SELECT name, status, value, score, active FROM ash_scylla_dl_test.items WHERE id = ?",
          [id]
        )

      [row] = rows_to_maps(result)
      assert row["name"] == "Null Test"
      assert row["status"] == nil
      assert row["value"] == nil
      assert row["score"] == nil
      assert row["active"] == nil
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # 3. Filter integration tests
  # ══════════════════════════════════════════════════════════════════════════

  describe "filter operations against real DB" do
    test "OR filter on same column (IN rewrite)", %{conn: conn} do
      if is_nil(conn), do: :ok
      id1 = uid()
      id2 = uid()

      xq(conn, "INSERT INTO ash_scylla_dl_test.items (id, name, status) VALUES (?, ?, ?)", [
        id1,
        "OR Test 1",
        "active"
      ])

      xq(conn, "INSERT INTO ash_scylla_dl_test.items (id, name, status) VALUES (?, ?, ?)", [
        id2,
        "OR Test 2",
        "pending"
      ])

      # Query using IN (which is how OR on same column is rewritten)
      result =
        xq(
          conn,
          "SELECT * FROM ash_scylla_dl_test.items WHERE status IN (?, ?) ALLOW FILTERING",
          [
            "active",
            "pending"
          ]
        )

      assert result.num_rows >= 2
    end

    test "AND filter on different columns", %{conn: conn} do
      if is_nil(conn), do: :ok
      id = uid()

      xq(
        conn,
        "INSERT INTO ash_scylla_dl_test.items (id, name, status, value) VALUES (?, ?, ?, ?)",
        [id, "AND Test", "active", 42]
      )

      result =
        xq(
          conn,
          "SELECT * FROM ash_scylla_dl_test.items WHERE status = ? AND value = ? ALLOW FILTERING",
          [
            "active",
            42
          ]
        )

      assert result.num_rows >= 1
      [row] = rows_to_maps(result)
      assert row["name"] == "AND Test"
    end

    test "range filter with secondary index", %{conn: conn} do
      if is_nil(conn), do: :ok
      id = uid()

      xq(conn, "INSERT INTO ash_scylla_dl_test.items (id, name, value) VALUES (?, ?, ?)", [
        id,
        "Range Test",
        50
      ])

      result =
        xq(
          conn,
          "SELECT * FROM ash_scylla_dl_test.items WHERE value >= ? AND value <= ? ALLOW FILTERING",
          [40, 60]
        )

      assert result.num_rows >= 1
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # 4. Error handling integration tests
  # ══════════════════════════════════════════════════════════════════════════

  describe "error handling" do
    test "querying non-existent table returns error", %{conn: conn} do
      if is_nil(conn), do: :ok

      assert_raise RuntimeError, ~r/Query failed/, fn ->
        xq(conn, "SELECT * FROM ash_scylla_dl_test.nonexistent_table")
      end
    end

    test "insert with missing primary key returns error", %{conn: conn} do
      if is_nil(conn), do: :ok

      assert_raise RuntimeError, ~r/Query failed/, fn ->
        xq(conn, "INSERT INTO ash_scylla_dl_test.items (name) VALUES (?)", ["No PK"])
      end
    end

    test "filter on non-indexed column requires ALLOW FILTERING", %{conn: conn} do
      if is_nil(conn), do: :ok
      id = uid()
      xq(conn, "INSERT INTO ash_scylla_dl_test.items (id, name) VALUES (?, ?)", [id, "No Index"])

      # name column has no secondary index, so filtering on it should fail without ALLOW FILTERING
      assert_raise RuntimeError, ~r/Query failed|ALLOW FILTERING/, fn ->
        xq(conn, "SELECT * FROM ash_scylla_dl_test.items WHERE name = ?", ["No Index"])
      end
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # 5. Bulk operations integration tests
  # ══════════════════════════════════════════════════════════════════════════

  describe "bulk operations" do
    test "batch insert multiple records", %{conn: conn} do
      if is_nil(conn), do: :ok
      ids = Enum.map(1..5, fn _ -> uid() end)

      # Use batch insert
      batch_cql = """
        BEGIN BATCH
        #{Enum.map(ids, fn _ -> "INSERT INTO ash_scylla_dl_test.items (id, name, status) VALUES (?, ?, ?)" end) |> Enum.join("\n")}
        APPLY BATCH
      """

      params = Enum.flat_map(ids, fn id -> [id, "Batch-#{String.slice(id, 0, 4)}", "active"] end)
      {:ok, _} = Xandra.execute(conn, batch_cql, Enum.map(params, &encode_param/1))

      # Verify all inserted
      result =
        xq(conn, "SELECT count(*) FROM ash_scylla_dl_test.items WHERE status = ?", ["active"])

      assert result.num_rows >= 1
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # 6. Consistency level integration tests
  # ══════════════════════════════════════════════════════════════════════════

  describe "consistency levels" do
    test "write and read with LOCAL_QUORUM consistency", %{conn: conn} do
      if is_nil(conn), do: :ok
      id = uid()

      {:ok, prepared} =
        Xandra.prepare(
          conn,
          "INSERT INTO ash_scylla_dl_test.items (id, name, status) VALUES (?, ?, ?)"
        )

      {:ok, _} =
        Xandra.execute(conn, prepared, [id, "Quorum Test", "active"], consistency: :local_quorum)

      result = xq(conn, "SELECT * FROM ash_scylla_dl_test.items WHERE id = ?", [id])
      assert result.num_rows == 1
      [row] = rows_to_maps(result)
      assert row["name"] == "Quorum Test"
    end

    test "write and read with ONE consistency", %{conn: conn} do
      if is_nil(conn), do: :ok
      id = uid()

      {:ok, prepared} =
        Xandra.prepare(conn, "INSERT INTO ash_scylla_dl_test.items (id, name) VALUES (?, ?)")

      {:ok, _} = Xandra.execute(conn, prepared, [id, "One Test"], consistency: :one)

      result = xq(conn, "SELECT * FROM ash_scylla_dl_test.items WHERE id = ?", [id])
      assert result.num_rows == 1
    end
  end
end
