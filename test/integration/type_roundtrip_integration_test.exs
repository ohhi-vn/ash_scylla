defmodule AshScylla.TypeRoundtripIntegrationTest do
  @moduledoc """
  Integration tests for Ash type → ScyllaDB → Ash type round-trip.

  Tests all supported Ash types against a real ScyllaDB instance to verify:
  1. Values are correctly encoded and stored in ScyllaDB
  2. Values are correctly read back and converted to Ash types
  3. Round-trip preserves values for all supported types

  Requires a running ScyllaDB instance. Set SCYLLA_DIRECT=true with
  SCYLLA_HOST and SCYLLA_PORT to connect to an existing instance.
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

  defp direct_connect?, do: System.get_env("SCYLLA_DIRECT") != nil

  defp direct_host do
    System.get_env("SCYLLA_HOST") || "127.0.0.1"
  end

  defp direct_port do
    case System.get_env("SCYLLA_PORT") do
      nil -> 9042
      port -> String.to_integer(port)
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

  defp execute_cql(conn, query, params \\ []) do
    encoded = Enum.map(params, &encode_param/1)

    case Xandra.execute(conn, query, encoded, consistency: :one, timeout: 10_000) do
      {:ok, result} ->
        result

      {:error, reason} ->
        raise "CQL failed: #{inspect(reason)}\nQuery: #{query}\nParams: #{inspect(params)}"
    end
  end

  # Pass through already-typed tuples from QueryBuilder (e.g., {"int", 10})
  defp encode_param({type, value}) when is_binary(type), do: {type, value}
  defp encode_param({type, value}), do: {to_string(type), value}
  defp encode_param(value) when is_integer(value), do: {"bigint", value}
  defp encode_param(value) when is_float(value), do: {"float", value}
  defp encode_param(value) when is_boolean(value), do: {"boolean", value}
  defp encode_param(nil), do: {"null", nil}
  defp encode_param(%DateTime{} = value), do: {"timestamp", value}
  defp encode_param(%Date{} = value), do: {"date", value}
  defp encode_param(%Time{} = value), do: {"time", value}
  defp encode_param(%Decimal{} = value), do: {"decimal", value}
  defp encode_param(value) when is_binary(value) do
    if uuid?(value), do: {"uuid", value}, else: {"text", value}
  end
  defp encode_param(%MapSet{} = value), do: {"set<int>", value}
  defp encode_param(value) when is_map(value), do: {"map<text, text>", value}
  defp encode_param(value) when is_list(value), do: {"list<text>", value}
  defp encode_param(value), do: {"text", to_string(value)}

  defp uuid?(value) when is_binary(value) do
    Regex.match?(~r/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i, value)
  end
  defp uuid?(_), do: false

  # ── Setup ──────────────────────────────────────────────────────────────────

  setup_all do
    if direct_connect?() do
      host = direct_host()
      port = direct_port()
      conn = connect_with_retry(host, port)

      # Create keyspace and table for type round-trip tests
      execute_cql(
        conn,
        "CREATE KEYSPACE IF NOT EXISTS ash_scylla_type_test WITH REPLICATION = {'class': 'SimpleStrategy', 'replication_factor': 1}"
      )

      execute_cql(
        conn,
        """
        CREATE TABLE IF NOT EXISTS ash_scylla_type_test.roundtrip (
          id UUID PRIMARY KEY,
          str_val TEXT,
          int_val BIGINT,
          float_val FLOAT,
          double_val DOUBLE,
          bool_val BOOLEAN,
          timestamp_val TIMESTAMP,
          date_val DATE,
          time_val TIME,
          smallint_val SMALLINT,
          tinyint_val TINYINT,
          decimal_val DECIMAL,
          blob_val BLOB,
          list_val LIST<TEXT>,
          set_val SET<INT>,
          map_val MAP<TEXT, TEXT>,
          atom_val TEXT
        )
        """
      )

      %{conn: conn, scylla: :direct}
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

  setup context do
    case Map.fetch(context, :scylla) do
      {:ok, :direct} ->
        conn = connect_with_retry(direct_host(), direct_port())
        execute_cql(conn, "TRUNCATE ash_scylla_type_test.roundtrip")
        %{conn: conn}

      _ ->
        :ok
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # Integration tests: Ash resource → ScyllaDB → Ash resource
  # ══════════════════════════════════════════════════════════════════════════

  describe "Type round-trip through real ScyllaDB" do
    test "string type: Ash :string → ScyllaDB TEXT → Ash :string", %{conn: conn} do
      if is_nil(conn), do: :ok
      id = uid()

      # Write directly to ScyllaDB
      execute_cql(
        conn,
        "INSERT INTO ash_scylla_type_test.roundtrip (id, str_val) VALUES (?, ?)",
        [id, "Hello ScyllaDB"]
      )

      # Read back via DataLayer
      query = %DataLayer{
        resource: nil,
        repo: nil,
        table: "ash_scylla_type_test.roundtrip",
        select: [:id, :str_val],
        filters: [%{operator: :eq, left: %{name: :id}, right: %{value: id}}],
        limit: 1
      }

      {cql, params} = DataLayer.QueryBuilder.build_optimized_query(query)
      encoded = Enum.map(params, &encode_param/1)
      {:ok, %Xandra.Page{content: [row]}} = Xandra.execute(conn, cql, encoded, consistency: :one)

      [read_id, read_str] = row
      assert read_str == "Hello ScyllaDB"
      assert is_binary(read_str)
    end

    test "integer type: Ash :integer → ScyllaDB BIGINT → Ash :integer", %{conn: conn} do
      if is_nil(conn), do: :ok
      id = uid()
      large_int = 9_223_372_036_854_775_807

      execute_cql(
        conn,
        "INSERT INTO ash_scylla_type_test.roundtrip (id, int_val) VALUES (?, ?)",
        [id, large_int]
      )

      query = %DataLayer{
        resource: nil,
        repo: nil,
        table: "ash_scylla_type_test.roundtrip",
        select: [:id, :int_val],
        filters: [%{operator: :eq, left: %{name: :id}, right: %{value: id}}],
        limit: 1
      }

      {cql, params} = DataLayer.QueryBuilder.build_optimized_query(query)
      encoded = Enum.map(params, &encode_param/1)
      {:ok, %Xandra.Page{content: [row]}} = Xandra.execute(conn, cql, encoded, consistency: :one)

      [read_id, read_int] = row
      assert read_int == large_int
      assert is_integer(read_int)
    end

    test "float type: Ash :float → ScyllaDB FLOAT → Ash :float", %{conn: conn} do
      if is_nil(conn), do: :ok
      id = uid()

      execute_cql(
        conn,
        "INSERT INTO ash_scylla_type_test.roundtrip (id, float_val) VALUES (?, ?)",
        [id, 3.14]
      )

      query = %DataLayer{
        resource: nil,
        repo: nil,
        table: "ash_scylla_type_test.roundtrip",
        select: [:id, :float_val],
        filters: [%{operator: :eq, left: %{name: :id}, right: %{value: id}}],
        limit: 1
      }

      {cql, params} = DataLayer.QueryBuilder.build_optimized_query(query)
      encoded = Enum.map(params, &encode_param/1)
      {:ok, %Xandra.Page{content: [row]}} = Xandra.execute(conn, cql, encoded, consistency: :one)

      [read_id, read_float] = row
      assert is_float(read_float)
      # ScyllaDB FLOAT is single-precision, so there may be rounding
      assert_in_delta(read_float, 3.14, 0.01)
    end

    test "boolean type: Ash :boolean → ScyllaDB BOOLEAN → Ash :boolean", %{conn: conn} do
      if is_nil(conn), do: :ok
      id = uid()

      execute_cql(
        conn,
        "INSERT INTO ash_scylla_type_test.roundtrip (id, bool_val) VALUES (?, ?)",
        [id, true]
      )

      query = %DataLayer{
        resource: nil,
        repo: nil,
        table: "ash_scylla_type_test.roundtrip",
        select: [:id, :bool_val],
        filters: [%{operator: :eq, left: %{name: :id}, right: %{value: id}}],
        limit: 1
      }

      {cql, params} = DataLayer.QueryBuilder.build_optimized_query(query)
      encoded = Enum.map(params, &encode_param/1)
      {:ok, %Xandra.Page{content: [row]}} = Xandra.execute(conn, cql, encoded, consistency: :one)

      [read_id, read_bool] = row
      assert read_bool == true
      assert is_boolean(read_bool)
    end

    test "timestamp type: Ash :utc_datetime → ScyllaDB TIMESTAMP → Ash :utc_datetime", %{
      conn: conn
    } do
      if is_nil(conn), do: :ok
      id = uid()
      now = DateTime.utc_now() |> DateTime.truncate(:millisecond)

      execute_cql(
        conn,
        "INSERT INTO ash_scylla_type_test.roundtrip (id, timestamp_val) VALUES (?, ?)",
        [id, now]
      )

      query = %DataLayer{
        resource: nil,
        repo: nil,
        table: "ash_scylla_type_test.roundtrip",
        select: [:id, :timestamp_val],
        filters: [%{operator: :eq, left: %{name: :id}, right: %{value: id}}],
        limit: 1
      }

      {cql, params} = DataLayer.QueryBuilder.build_optimized_query(query)
      encoded = Enum.map(params, &encode_param/1)
      {:ok, %Xandra.Page{content: [row]}} = Xandra.execute(conn, cql, encoded, consistency: :one)

      [read_id, read_ts] = row
      assert %DateTime{} = read_ts
      # Timestamps should be equal (truncated to millisecond)
      assert DateTime.compare(read_ts, now) == :eq
    end

    test "date type: Ash :date → ScyllaDB DATE → Ash :date", %{conn: conn} do
      if is_nil(conn), do: :ok
      id = uid()
      today = ~D[2024-06-15]

      execute_cql(
        conn,
        "INSERT INTO ash_scylla_type_test.roundtrip (id, date_val) VALUES (?, ?)",
        [id, today]
      )

      query = %DataLayer{
        resource: nil,
        repo: nil,
        table: "ash_scylla_type_test.roundtrip",
        select: [:id, :date_val],
        filters: [%{operator: :eq, left: %{name: :id}, right: %{value: id}}],
        limit: 1
      }

      {cql, params} = DataLayer.QueryBuilder.build_optimized_query(query)
      encoded = Enum.map(params, &encode_param/1)
      {:ok, %Xandra.Page{content: [row]}} = Xandra.execute(conn, cql, encoded, consistency: :one)

      [read_id, read_date] = row
      assert %Date{} = read_date
      assert read_date == today
    end

    test "time type: Ash :time → ScyllaDB TIME → Ash :time", %{conn: conn} do
      if is_nil(conn), do: :ok
      id = uid()
      now_time = ~T[14:30:00]

      execute_cql(
        conn,
        "INSERT INTO ash_scylla_type_test.roundtrip (id, time_val) VALUES (?, ?)",
        [id, now_time]
      )

      query = %DataLayer{
        resource: nil,
        repo: nil,
        table: "ash_scylla_type_test.roundtrip",
        select: [:id, :time_val],
        filters: [%{operator: :eq, left: %{name: :id}, right: %{value: id}}],
        limit: 1
      }

      {cql, params} = DataLayer.QueryBuilder.build_optimized_query(query)
      encoded = Enum.map(params, &encode_param/1)
      {:ok, %Xandra.Page{content: [row]}} = Xandra.execute(conn, cql, encoded, consistency: :one)

      [read_id, read_time] = row
      assert %Time{} = read_time
      end

    test "list type: Ash {:array, :string} → ScyllaDB LIST<TEXT> → Ash list", %{conn: conn} do
      if is_nil(conn), do: :ok
      id = uid()

      execute_cql(
        conn,
        "INSERT INTO ash_scylla_type_test.roundtrip (id, list_val) VALUES (?, ?)",
        [id, ["elixir", "phoenix", "scylla"]]
      )

      query = %DataLayer{
        resource: nil,
        repo: nil,
        table: "ash_scylla_type_test.roundtrip",
        select: [:id, :list_val],
        filters: [%{operator: :eq, left: %{name: :id}, right: %{value: id}}],
        limit: 1
      }

      {cql, params} = DataLayer.QueryBuilder.build_optimized_query(query)
      encoded = Enum.map(params, &encode_param/1)
      {:ok, %Xandra.Page{content: [row]}} = Xandra.execute(conn, cql, encoded, consistency: :one)

      [read_id, read_list] = row
      assert is_list(read_list)
      assert length(read_list) == 3
    end

    test "set type: ScyllaDB SET<INT> round-trip", %{conn: conn} do
      if is_nil(conn), do: :ok
      id = uid()

      execute_cql(
        conn,
        "INSERT INTO ash_scylla_type_test.roundtrip (id, set_val) VALUES (?, ?)",
        [id, MapSet.new([1, 2, 3])]
      )

      query = %DataLayer{
        resource: nil,
        repo: nil,
        table: "ash_scylla_type_test.roundtrip",
        select: [:id, :set_val],
        filters: [%{operator: :eq, left: %{name: :id}, right: %{value: id}}],
        limit: 1
      }

      {cql, params} = DataLayer.QueryBuilder.build_optimized_query(query)
      encoded = Enum.map(params, &encode_param/1)
      {:ok, %Xandra.Page{content: [row]}} = Xandra.execute(conn, cql, encoded, consistency: :one)

      [read_id, read_set] = row
      assert %MapSet{} = read_set
      assert MapSet.size(read_set) == 3
    end

    test "map type: ScyllaDB MAP<TEXT, TEXT> round-trip", %{conn: conn} do
      if is_nil(conn), do: :ok
      id = uid()

      execute_cql(
        conn,
        "INSERT INTO ash_scylla_type_test.roundtrip (id, map_val) VALUES (?, ?)",
        [id, %{"key1" => "value1", "key2" => "value2"}]
      )

      query = %DataLayer{
        resource: nil,
        repo: nil,
        table: "ash_scylla_type_test.roundtrip",
        select: [:id, :map_val],
        filters: [%{operator: :eq, left: %{name: :id}, right: %{value: id}}],
        limit: 1
      }

      {cql, params} = DataLayer.QueryBuilder.build_optimized_query(query)
      encoded = Enum.map(params, &encode_param/1)
      {:ok, %Xandra.Page{content: [row]}} = Xandra.execute(conn, cql, encoded, consistency: :one)

      [read_id, read_map] = row
      assert is_map(read_map)
      assert map_size(read_map) == 2
    end

    test "blob type: ScyllaDB BLOB round-trip", %{conn: conn} do
      if is_nil(conn), do: :ok
      id = uid()
      binary_data = <<0, 1, 2, 255, 128, 64>>

      execute_cql(
        conn,
        "INSERT INTO ash_scylla_type_test.roundtrip (id, blob_val) VALUES (?, ?)",
        [id, binary_data]
      )

      query = %DataLayer{
        resource: nil,
        repo: nil,
        table: "ash_scylla_type_test.roundtrip",
        select: [:id, :blob_val],
        filters: [%{operator: :eq, left: %{name: :id}, right: %{value: id}}],
        limit: 1
      }

      {cql, params} = DataLayer.QueryBuilder.build_optimized_query(query)
      encoded = Enum.map(params, &encode_param/1)
      {:ok, %Xandra.Page{content: [row]}} = Xandra.execute(conn, cql, encoded, consistency: :one)

      [read_id, read_blob] = row
      assert is_binary(read_blob)
      assert byte_size(read_blob) == 6
    end

    test "atom type: Ash :atom → ScyllaDB TEXT → Ash :atom", %{conn: conn} do
      if is_nil(conn), do: :ok
      id = uid()

      # Write atom value as text
      execute_cql(
        conn,
        "INSERT INTO ash_scylla_type_test.roundtrip (id, atom_val) VALUES (?, ?)",
        [id, "active"]
      )

      # Read back - the value should be a string from ScyllaDB
      query = %DataLayer{
        resource: nil,
        repo: nil,
        table: "ash_scylla_type_test.roundtrip",
        select: [:id, :atom_val],
        filters: [%{operator: :eq, left: %{name: :id}, right: %{value: id}}],
        limit: 1
      }

      {cql, params} = DataLayer.QueryBuilder.build_optimized_query(query)
      encoded = Enum.map(params, &encode_param/1)
      {:ok, %Xandra.Page{content: [row]}} = Xandra.execute(conn, cql, encoded, consistency: :one)

      [read_id, read_atom] = row
      assert read_atom == "active"
      assert is_binary(read_atom)
    end

    test "LIMIT parameter uses int32-compatible encoding", %{conn: conn} do
      if is_nil(conn), do: :ok
      id = uid()

      execute_cql(
        conn,
        "INSERT INTO ash_scylla_type_test.roundtrip (id, str_val) VALUES (?, ?)",
        [id, "limit test"]
      )

      query = %DataLayer{
        resource: nil,
        repo: nil,
        table: "ash_scylla_type_test.roundtrip",
        select: [:id, :str_val],
        filters: [%{operator: :eq, left: %{name: :id}, right: %{value: id}}],
        limit: 250
      }

      {cql, params} = DataLayer.QueryBuilder.build_optimized_query(query)

      # The limit param is tagged as {"int", value} for ScyllaDB INT type compatibility
      assert cql =~ "LIMIT ?"
      assert {"int", 250} in params

      # Execute the query to verify it works with ScyllaDB
      encoded = Enum.map(params, &encode_param/1)
      {:ok, %Xandra.Page{content: [_row]}} = Xandra.execute(conn, cql, encoded, consistency: :one)
    end

    test "multiple types in single row round-trip", %{conn: conn} do
      if is_nil(conn), do: :ok
      id = uid()

      execute_cql(
        conn,
        """
        INSERT INTO ash_scylla_type_test.roundtrip
          (id, str_val, int_val, float_val, bool_val, timestamp_val, date_val, time_val)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        """,
        [id, "test", 42, 3.14, true, ~U[2024-06-15 10:30:00Z], ~D[2024-06-15], ~T[10:30:00]]
      )

      query = %DataLayer{
        resource: nil,
        repo: nil,
        table: "ash_scylla_type_test.roundtrip",
        select: [:id, :str_val, :int_val, :float_val, :bool_val, :timestamp_val, :date_val, :time_val],
        filters: [%{operator: :eq, left: %{name: :id}, right: %{value: id}}],
        limit: 1
      }

      {cql, params} = DataLayer.QueryBuilder.build_optimized_query(query)
      encoded = Enum.map(params, &encode_param/1)
      {:ok, %Xandra.Page{content: [row]}} = Xandra.execute(conn, cql, encoded, consistency: :one)

      [read_id, read_str, read_int, read_float, read_bool, read_ts, read_date, read_time] = row

      assert read_str == "test"
      assert read_int == 42
      assert is_float(read_float)
      assert read_bool == true
      assert %DateTime{} = read_ts
      assert %Date{} = read_date
      assert %Time{} = read_time
    end
  end
end
