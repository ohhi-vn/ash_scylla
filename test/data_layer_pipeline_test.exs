defmodule AshScylla.DataLayer.PipelineTest do
  @moduledoc """
  Full pipeline integration tests: DSL → DataLayer → QueryBuilder → Xandra → ScyllaDB.

  Tests the complete flow from resource configuration through to actual database
  operations, verifying that the DataLayer correctly bridges Ash resources and
  ScyllaDB via Xandra.

  Uses testcontainer_ex 0.5 ScyllaContainer for container lifecycle management.
  """

  use ExUnit.Case, async: false

  alias AshScylla.DataLayer
  alias AshScylla.DataLayer.QueryBuilder
  alias AshScylla.TestRepo
  alias AshScylla.ScyllaContainer

  @moduletag :integration

  # ── Container config ────────────────────────────────────────────────────────

  @scylla_container_config ScyllaContainer.new()
                           |> ScyllaContainer.with_image("scylladb/scylla:5.4")
                           |> ScyllaContainer.with_cmd([
                             "--smp",
                             "1",
                             "--memory",
                             "1G",
                             "--developer-mode",
                             "1"
                           ])
                           |> ScyllaContainer.with_wait_timeout(300_000)

  # ── Shared helpers ──────────────────────────────────────────────────────────

  defp connect_with_retry(host, port, retries \\ 30) do
    case Xandra.start_link(nodes: ["#{host}:#{port}"], connect_timeout: 10_000) do
      {:ok, conn} ->
        case wait_for_cql(conn, 5) do
          :ok ->
            conn

          {:error, _} when retries > 0 ->
            Xandra.stop(conn)
            Process.sleep(2_000)
            connect_with_retry(host, port, retries - 1)

          {:error, reason} ->
            raise "ScyllaDB not ready: #{inspect(reason)}"
        end

      {:error, _} when retries > 0 ->
        Process.sleep(2_000)
        connect_with_retry(host, port, retries - 1)

      {:error, reason} ->
        raise "Failed to connect to ScyllaDB: #{inspect(reason)}"
    end
  end

  defp wait_for_cql(conn, retries \\ 30) do
    case Xandra.execute(conn, "SELECT now() FROM system.local") do
      {:ok, _} ->
        :ok

      {:error, _} when retries > 0 ->
        Process.sleep(1_000)
        wait_for_cql(conn, retries - 1)

      {:error, reason} ->
        raise "ScyllaDB not ready after 30s: #{inspect(reason)}"
    end
  end

  defp uid, do: generate_uuid()

  defp xq(conn, query, params \\ []) do
    encoded = Enum.map(params, &encode_param/1)

    case Xandra.execute(conn, query, encoded) do
      {:ok, page} ->
        rows =
          case page do
            %Xandra.Page{content: content} -> content || []
            _ -> []
          end

        columns =
          case page do
            %Xandra.Page{columns: cols} -> cols
            _ -> []
          end

        %{rows: rows, num_rows: length(rows), columns: columns}

      {:error, reason} ->
        raise "Query failed: #{inspect(reason)}"
    end
  end

  defp encode_param(value) when is_integer(value), do: {"int", value}
  defp encode_param(value) when is_float(value), do: {"double", value}
  defp encode_param(value) when is_boolean(value), do: {"boolean", value}
  defp encode_param(nil), do: {"null", nil}

  defp encode_param(value) when is_binary(value) do
    if uuid?(value), do: {"uuid", value}, else: {"text", value}
  end

  defp encode_param(value), do: {"text", to_string(value)}

  defp uuid?(value) when is_binary(value) do
    Regex.match?(~r/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i, value)
  end

  defp generate_uuid do
    <<a::32, b::16, c::16, d::16, e::48>> = :crypto.strong_rand_bytes(16)

    "#{format_hex(a, 8)}-#{format_hex(b, 4)}-#{format_hex(c, 4)}-#{format_hex(d, 4)}-#{format_hex(e, 12)}"
  end

  defp format_hex(value, len) do
    value |> Integer.to_string(16) |> String.pad_leading(len, "0")
  end

  defp rows_to_maps(%{rows: rows, columns: cols}) do
    col_names = Enum.map(cols, fn {_, _, name, _} -> to_string(name) end)

    Enum.map(rows, fn row ->
      row
      |> Enum.zip(col_names)
      |> Map.new(fn {val, col} -> {col, val} end)
    end)
  end

  # ── Setup: ensure schema exists ─────────────────────────────────────────────

  setup_all do
    case TestcontainerEx.start_container(@scylla_container_config) do
      {:ok, scylla_container} ->
        port = ScyllaContainer.port(scylla_container)
        host = TestcontainerEx.get_host(scylla_container)
        conn = connect_with_retry(host, port)

        # Create keyspace and tables if they don't exist
        Xandra.execute!(
          conn,
          "CREATE KEYSPACE IF NOT EXISTS ash_scylla_test WITH REPLICATION = {'class': 'SimpleStrategy', 'replication_factor': 1}"
        )

        Xandra.execute!(
          conn,
          "CREATE TABLE IF NOT EXISTS ash_scylla_test.users (id UUID PRIMARY KEY, name TEXT, email TEXT, age INT, status TEXT, created_at TIMESTAMP)"
        )

        Xandra.execute!(
          conn,
          "CREATE INDEX IF NOT EXISTS idx_users_email ON ash_scylla_test.users (email)"
        )

        Xandra.execute!(
          conn,
          "CREATE INDEX IF NOT EXISTS idx_users_status ON ash_scylla_test.users (status)"
        )

        Xandra.execute!(
          conn,
          "CREATE INDEX IF NOT EXISTS idx_users_age ON ash_scylla_test.users (age)"
        )

        %{conn: conn, scylla: scylla_container}

      {:error, reason} ->
        IO.puts("WARNING: Skipping integration tests — #{inspect(reason)}")
        {:skip, "Docker/Podman not available"}
    end
  end

  setup %{conn: conn} do
    # Clean the users table before each test
    {:ok, _} = Xandra.execute(conn, "TRUNCATE ash_scylla_test.users")
    %{conn: conn}
  end

  # ══════════════════════════════════════════════════════════════════════════
  # 1. DSL → DataLayer: resource_to_query builds correct struct
  # ══════════════════════════════════════════════════════════════════════════

  describe "DSL → DataLayer: resource_to_query" do
    test "builds query struct with table from DSL" do
      query = DataLayer.resource_to_query(AshScylla.TestResourceWithIndexes, nil)
      assert %DataLayer{} = query
      assert query.resource == AshScylla.TestResourceWithIndexes
      assert query.table == "test_users"
    end

    test "builds query struct with repo from DSL" do
      query = DataLayer.resource_to_query(AshScylla.TestResourceWithIndexes, nil)
      assert query.repo == AshScylla.TestRepo
    end

    test "builds query struct with default empty collections" do
      query = DataLayer.resource_to_query(AshScylla.TestResourceWithIndexes, nil)
      assert query.filters == []
      assert query.sorts == []
      assert query.limit == nil
      assert query.offset == nil
      assert query.select == nil
      assert query.tenant == nil
      assert query.context == %{}
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # 2. DSL → DataLayer: source/1 resolves table name
  # ══════════════════════════════════════════════════════════════════════════

  describe "DSL → DataLayer: source/1" do
    test "returns table name from DSL for resource with explicit table" do
      assert DataLayer.source(AshScylla.TestResourceWithIndexes) == "test_users"
    end

    test "falls back to underscored module name when no DSL table" do
      assert DataLayer.source(AshScylla.TestResource) == "test_resource"
    end

    test "caches the resolved table name" do
      # Call twice to verify caching doesn't change result
      first = DataLayer.source(AshScylla.TestResourceWithIndexes)
      second = DataLayer.source(AshScylla.TestResourceWithIndexes)
      assert first == second
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # 3. DataLayer → QueryBuilder: build_optimized_query generates valid CQL
  # ══════════════════════════════════════════════════════════════════════════

  describe "DataLayer → QueryBuilder: CQL generation" do
    test "generates SELECT with WHERE filter" do
      query = %DataLayer{
        resource: AshScylla.TestResourceWithIndexes,
        repo: TestRepo,
        table: "ash_scylla_test.users",
        filters: [%{operator: :eq, left: %{name: :status}, right: %{value: "active"}}],
        sorts: [],
        limit: nil,
        offset: nil,
        select: nil,
        tenant: nil
      }

      {cql, params} = QueryBuilder.build_optimized_query(query)
      assert cql =~ "SELECT * FROM ash_scylla_test.users"
      assert cql =~ "WHERE"
      assert cql =~ "status = ?"
      assert params == ["active"]
    end

    test "generates SELECT with specific columns" do
      query = %DataLayer{
        resource: AshScylla.TestResourceWithIndexes,
        repo: TestRepo,
        table: "ash_scylla_test.users",
        filters: [],
        sorts: [],
        limit: nil,
        offset: nil,
        select: [:id, :name, :email],
        tenant: nil
      }

      {cql, _params} = QueryBuilder.build_optimized_query(query)
      assert cql =~ "SELECT id, name, email FROM ash_scylla_test.users"
    end

    test "generates SELECT with LIMIT" do
      query = %DataLayer{
        resource: AshScylla.TestResourceWithIndexes,
        repo: TestRepo,
        table: "ash_scylla_test.users",
        filters: [],
        sorts: [],
        limit: 25,
        offset: nil,
        select: nil,
        tenant: nil
      }

      {cql, params} = QueryBuilder.build_optimized_query(query)
      assert cql =~ "LIMIT ?"
      assert 25 in params
    end

    test "generates SELECT with ORDER BY" do
      query = %DataLayer{
        resource: AshScylla.TestResourceWithIndexes,
        repo: TestRepo,
        table: "ash_scylla_test.users",
        filters: [],
        sorts: [{:name, :asc}],
        limit: nil,
        offset: nil,
        select: nil,
        tenant: nil
      }

      {cql, _params} = QueryBuilder.build_optimized_query(query)
      assert cql =~ "ORDER BY name asc"
    end

    test "generates SELECT with combined filter + sort + limit" do
      query = %DataLayer{
        resource: AshScylla.TestResourceWithIndexes,
        repo: TestRepo,
        table: "ash_scylla_test.users",
        filters: [%{operator: :eq, left: %{name: :status}, right: %{value: "active"}}],
        sorts: [{:created_at, :desc}],
        limit: 10,
        offset: nil,
        select: [:id, :name],
        tenant: nil
      }

      {cql, params} = QueryBuilder.build_optimized_query(query)
      assert cql =~ "SELECT id, name FROM ash_scylla_test.users"
      assert cql =~ "WHERE"
      assert cql =~ "ORDER BY created_at desc"
      assert cql =~ "LIMIT ?"
      assert "active" in params
      assert 10 in params
    end

    test "generates SELECT with IN operator" do
      ids = Enum.map(1..3, fn _ -> uid() end)

      query = %DataLayer{
        resource: AshScylla.TestResourceWithIndexes,
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
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # 4. Full pipeline: DataLayer → QueryBuilder → Xandra → ScyllaDB
  # ══════════════════════════════════════════════════════════════════════════

  describe "Full pipeline: insert → query → read from DB" do
    test "insert a record then read it back via DataLayer query struct", %{conn: c} do
      id = uid()

      # Insert directly via Xandra
      xq(
        c,
        "INSERT INTO ash_scylla_test.users (id, name, email, age, status) VALUES (?, ?, ?, ?, ?)",
        [id, "Pipeline Test", "pipeline@test.com", 30, "active"]
      )

      # Build a DataLayer query struct and verify the generated CQL works against real DB
      query = %DataLayer{
        resource: AshScylla.TestResourceWithIndexes,
        repo: TestRepo,
        table: "ash_scylla_test.users",
        filters: [%{operator: :eq, left: %{name: :id}, right: %{value: id}}],
        sorts: [],
        limit: nil,
        offset: nil,
        select: [:id, :name, :email],
        tenant: nil
      }

      {cql, params} = QueryBuilder.build_optimized_query(query)
      assert cql =~ "SELECT id, name, email FROM ash_scylla_test.users"
      assert cql =~ "WHERE id = ?"

      # Execute the generated CQL against real DB
      result = xq(c, cql, params)
      assert result.num_rows == 1

      [row] = rows_to_maps(result)
      assert row["name"] == "Pipeline Test"
      assert row["email"] == "pipeline@test.com"
    end

    test "insert multiple records then filter by indexed column", %{conn: c} do
      # Insert 5 records with different statuses
      Enum.each(1..5, fn i ->
        status = if rem(i, 2) == 0, do: "active", else: "inactive"

        xq(
          c,
          "INSERT INTO ash_scylla_test.users (id, name, email, status, age) VALUES (?, ?, ?, ?, ?)",
          [uid(), "User#{i}", "user#{i}@test.com", status, 20 + i]
        )
      end)

      # Query for active users via DataLayer query struct
      query = %DataLayer{
        resource: AshScylla.TestResourceWithIndexes,
        repo: TestRepo,
        table: "ash_scylla_test.users",
        filters: [%{operator: :eq, left: %{name: :status}, right: %{value: "active"}}],
        sorts: [],
        limit: 10,
        offset: nil,
        select: [:id, :name, :status],
        tenant: nil
      }

      {cql, params} = QueryBuilder.build_optimized_query(query)
      result = xq(c, cql, params)
      assert result.num_rows >= 2

      rows = rows_to_maps(result)
      Enum.each(rows, fn row -> assert row["status"] == "active" end)
    end

    test "filter by secondary index column (email)", %{conn: c} do
      id = uid()

      xq(
        c,
        "INSERT INTO ash_scylla_test.users (id, name, email, status, age) VALUES (?, ?, ?, ?, ?)",
        [id, "Email Test", "unique@test.com", "active", 25]
      )

      query = %DataLayer{
        resource: AshScylla.TestResourceWithIndexes,
        repo: TestRepo,
        table: "ash_scylla_test.users",
        filters: [%{operator: :eq, left: %{name: :email}, right: %{value: "unique@test.com"}}],
        sorts: [],
        limit: nil,
        offset: nil,
        select: [:id, :name, :email],
        tenant: nil
      }

      {cql, params} = QueryBuilder.build_optimized_query(query)
      result = xq(c, cql, params)
      assert result.num_rows >= 1

      [row] = rows_to_maps(result)
      assert row["name"] == "Email Test"
      assert row["email"] == "unique@test.com"
    end

    test "filter with LIMIT returns at most that many rows", %{conn: c} do
      # Insert 10 records
      Enum.each(1..10, fn i ->
        xq(
          c,
          "INSERT INTO ash_scylla_test.users (id, name, email, status) VALUES (?, ?, ?, ?)",
          [uid(), "Limit#{i}", "limit#{i}@test.com", "active"]
        )
      end)

      query = %DataLayer{
        resource: AshScylla.TestResourceWithIndexes,
        repo: TestRepo,
        table: "ash_scylla_test.users",
        filters: [%{operator: :eq, left: %{name: :status}, right: %{value: "active"}}],
        sorts: [],
        limit: 3,
        offset: nil,
        select: [:id, :name],
        tenant: nil
      }

      {cql, params} = QueryBuilder.build_optimized_query(query)
      result = xq(c, cql, params)
      assert result.num_rows <= 3
    end

    test "IN clause with multiple IDs", %{conn: c} do
      ids = Enum.map(1..5, fn _ -> uid() end)

      Enum.each(ids, fn id ->
        xq(
          c,
          "INSERT INTO ash_scylla_test.users (id, name, email) VALUES (?, ?, ?)",
          [id, "IN Test", "in@test.com"]
        )
      end)

      query = %DataLayer{
        resource: AshScylla.TestResourceWithIndexes,
        repo: TestRepo,
        table: "ash_scylla_test.users",
        filters: [%{operator: :in, left: %{name: :id}, right: %{value: ids}}],
        sorts: [],
        limit: nil,
        offset: nil,
        select: [:id, :name],
        tenant: nil
      }

      {cql, params} = QueryBuilder.build_optimized_query(query)
      assert cql =~ "IN"
      assert length(params) == 5

      result = xq(c, cql, params)
      assert result.num_rows == 5
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # 5. Full pipeline: DataLayer callbacks chain (filter → sort → limit → select)
  # ══════════════════════════════════════════════════════════════════════════

  describe "Full pipeline: callback chaining" do
    test "chaining filter → sort → limit → select produces correct CQL" do
      # Simulate the callback chain that Ash Framework would call
      query = %DataLayer{
        resource: AshScylla.TestResourceWithIndexes,
        repo: TestRepo,
        table: "ash_scylla_test.users",
        filters: [],
        sorts: [],
        limit: nil,
        offset: nil,
        select: nil,
        tenant: nil
      }

      # Chain: filter → sort → limit → select
      f1 = %{operator: :eq, left: %{name: :status}, right: %{value: "active"}}
      {:ok, q1} = DataLayer.filter(query, f1, nil)

      {:ok, q2} = DataLayer.sort(q1, [{:created_at, :desc}], nil)
      {:ok, q3} = DataLayer.limit(q2, 5, nil)
      {:ok, q4} = DataLayer.select(q3, [:id, :name, :status], nil)

      {cql, params} = QueryBuilder.build_optimized_query(q4)

      assert cql =~ "SELECT id, name, status FROM ash_scylla_test.users"
      assert cql =~ "WHERE"
      assert cql =~ "ORDER BY created_at desc"
      assert cql =~ "LIMIT ?"
      assert "active" in params
      assert 5 in params
    end

    test "chaining multiple filters produces AND-joined WHERE clause" do
      query = %DataLayer{
        resource: AshScylla.TestResourceWithIndexes,
        repo: TestRepo,
        table: "ash_scylla_test.users",
        filters: [],
        sorts: [],
        limit: nil,
        offset: nil,
        select: nil,
        tenant: nil
      }

      f1 = %{operator: :eq, left: %{name: :status}, right: %{value: "active"}}
      f2 = %{operator: :gt, left: %{name: :age}, right: %{value: 18}}

      {:ok, q1} = DataLayer.filter(query, f1, nil)
      {:ok, q2} = DataLayer.filter(q1, f2, nil)

      {cql, params} = QueryBuilder.build_optimized_query(q2)

      assert cql =~ "WHERE"
      assert cql =~ "AND"
      assert "active" in params
      assert 18 in params
    end

    test "set_tenant → set_context → filter chain preserves all state" do
      query = %DataLayer{
        resource: AshScylla.TestResourceWithIndexes,
        repo: TestRepo,
        table: "ash_scylla_test.users",
        filters: [],
        sorts: [],
        limit: nil,
        offset: nil,
        select: nil,
        tenant: nil,
        context: %{}
      }

      {:ok, q1} = DataLayer.set_tenant(query, "my_tenant", nil)
      {:ok, q2} = DataLayer.set_context(q1, %{custom: "value"}, nil)

      f = %{operator: :eq, left: %{name: :status}, right: %{value: "active"}}
      {:ok, q3} = DataLayer.filter(q2, f, nil)

      assert q3.tenant == "my_tenant"
      assert q3.context == %{custom: "value"}
      assert length(q3.filters) == 1
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # 6. Full pipeline: CQL generated by DataLayer executes against real ScyllaDB
  # ══════════════════════════════════════════════════════════════════════════

  describe "Full pipeline: generated CQL executes against ScyllaDB" do
    test "complex query with filter + limit executes successfully", %{conn: c} do
      # Insert test data
      Enum.each(1..5, fn i ->
        xq(
          c,
          "INSERT INTO ash_scylla_test.users (id, name, email, status, age) VALUES (?, ?, ?, ?, ?)",
          [uid(), "Exec#{i}", "exec#{i}@test.com", "active", 20 + i]
        )
      end)

      # Note: ScyllaDB doesn't support ORDER BY on non-clustering columns
      # when filtering by secondary index, so we test filter + limit only
      query = %DataLayer{
        resource: AshScylla.TestResourceWithIndexes,
        repo: TestRepo,
        table: "ash_scylla_test.users",
        filters: [%{operator: :eq, left: %{name: :status}, right: %{value: "active"}}],
        sorts: [],
        limit: 3,
        offset: nil,
        select: [:id, :name, :age],
        tenant: nil
      }

      {cql, params} = QueryBuilder.build_optimized_query(query)
      result = xq(c, cql, params)

      assert result.num_rows >= 1
      assert result.num_rows <= 3
    end

    test "empty filters produces simple SELECT without WHERE", %{conn: c} do
      id = uid()

      xq(
        c,
        "INSERT INTO ash_scylla_test.users (id, name) VALUES (?, ?)",
        [id, "No Filter"]
      )

      query = %DataLayer{
        resource: AshScylla.TestResourceWithIndexes,
        repo: TestRepo,
        table: "ash_scylla_test.users",
        filters: [],
        sorts: [],
        limit: nil,
        offset: nil,
        select: nil,
        tenant: nil
      }

      {cql, params} = QueryBuilder.build_optimized_query(query)
      refute cql =~ "WHERE"
      assert params == []

      result = xq(c, cql, params)
      assert result.num_rows >= 1
    end

    test "filter by single indexed column executes correctly", %{conn: c} do
      id = uid()

      xq(
        c,
        "INSERT INTO ash_scylla_test.users (id, name, email, status, age) VALUES (?, ?, ?, ?, ?)",
        [id, "Single Filter", "single@test.com", "active", 30]
      )

      # Note: ScyllaDB only allows filtering on one secondary index per query
      # without ALLOW FILTERING. Use status (which has an index).
      query = %DataLayer{
        resource: AshScylla.TestResourceWithIndexes,
        repo: TestRepo,
        table: "ash_scylla_test.users",
        filters: [
          %{operator: :eq, left: %{name: :status}, right: %{value: "active"}}
        ],
        sorts: [],
        limit: nil,
        offset: nil,
        select: [:id, :name],
        tenant: nil
      }

      {cql, params} = QueryBuilder.build_optimized_query(query)
      assert "active" in params

      result = xq(c, cql, params)
      assert result.num_rows >= 1

      rows = rows_to_maps(result)
      assert Enum.any?(rows, fn row -> row["name"] == "Single Filter" end)
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # 7. DSL repo configuration: repo via DSL vs @repo attribute
  # ══════════════════════════════════════════════════════════════════════════

  describe "DSL repo configuration" do
    test "Dsl.repo/1 returns repo for resource with DSL repo" do
      assert AshScylla.DataLayer.Dsl.repo(AshScylla.TestResourceWithIndexes) == AshScylla.TestRepo
    end

    test "Dsl.repo/1 returns repo for resource with DSL repo (TestResource)" do
      assert AshScylla.DataLayer.Dsl.repo(AshScylla.TestResource) == AshScylla.TestRepo
    end

    test "Dsl.repo/1 returns nil for resource without DSL" do
      assert AshScylla.DataLayer.Dsl.repo(String) == nil
    end

    test "resource_to_query uses DSL repo" do
      query = DataLayer.resource_to_query(AshScylla.TestResourceWithIndexes, nil)
      assert query.repo == AshScylla.TestRepo
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # 8. Error handling: missing repo produces actionable error
  # ══════════════════════════════════════════════════════════════════════════

  describe "Error handling: missing repo" do
    defmodule ResourceWithoutRepo do
      @moduledoc false
      use Ash.Resource, domain: nil, data_layer: AshScylla.DataLayer

      attributes do
        uuid_primary_key(:id)
        attribute(:name, :string)
      end

      actions do
        defaults([:read])
      end
    end

    test "raises actionable error when no repo is configured" do
      assert_raise RuntimeError, ~r/No repo configured for/, fn ->
        DataLayer.resource_to_query(ResourceWithoutRepo, nil)
      end
    end

    test "error message includes DSL configuration instructions" do
      error =
        assert_raise RuntimeError, fn ->
          DataLayer.resource_to_query(ResourceWithoutRepo, nil)
        end

      assert error.message =~ "ash_scylla"
      assert error.message =~ "repo"
    end
  end
end
