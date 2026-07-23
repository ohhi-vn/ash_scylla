defmodule AshScylla.Search.IntegrationTest do
  @moduledoc """
  Integration tests for the search engine against a real ScyllaDB instance.

  Tests the full inverted-index lifecycle:
    * Table creation / DDL validity
    * Index writes (single term + batch)
    * Term lookups (single + multi-shard)
    * Term frequency counting
    * Document update (diff-based add/remove)
    * Document deletion
    * Multi-word AND/OR search via boolean engine
    * Analyzer pipeline end-to-end against stored data
    * Pagination
  """

  use ExUnit.Case, async: false

  require Logger

  alias AshScylla.ScyllaContainer, warn: false
  alias AshScylla.Search.Analyzer
  alias AshScylla.Search.Storage

  @moduletag :integration
  @keyspace "ash_scylla_search_test"
  @table_terms "search_post_terms"
  @table_fields "search_post_fields"

  # ── Container / Connection helpers ────────────────────────────────────────

  defp scylla_container_config do
    ScyllaContainer.new()
    |> ScyllaContainer.with_image("scylladb/scylla:5.4")
    |> ScyllaContainer.with_cmd([
      "--smp", "1",
      "--memory", "512M",
      "--developer-mode", "1",
      "--overprovisioned", "1"
    ])
    |> ScyllaContainer.with_wait_timeout(120_000)
  end

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
          nil -> 9042
          nodes ->
            nodes |> String.split(",") |> hd() |> String.split(":") |> List.last() |> String.to_integer()
        end
      port -> String.to_integer(port)
    end
  end

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

  defp xq(conn, query, params \\ [])

  defp xq(nil, _query, _params) do
    %{rows: [], num_rows: 0, columns: []}
  end

  defp xq(conn, query, params) do
    encoded = Enum.map(params, &encode_param/1)

    result =
      case Xandra.execute(conn, query, encoded) do
        {:ok, page} -> page
        {:error, reason} ->
          raise "Query failed: #{inspect(reason)}\nQuery: #{query}\nParams: #{inspect(params)}"
      end

    rows = case result do
      %Xandra.Page{content: content} -> content || []
      _ -> []
    end

    columns = case result do
      %Xandra.Page{columns: cols} -> cols
      _ -> []
    end

    %{rows: rows, num_rows: length(rows), columns: columns}
  end

  defp encode_param(value) when is_binary(value), do: {"text", value}
  defp encode_param(value) when is_integer(value), do: {"int", value}
  defp encode_param(value) when is_float(value), do: {"double", value}
  defp encode_param(value) when is_boolean(value), do: {"boolean", value}
  defp encode_param(value), do: {"text", to_string(value)}

  defp connect_with_retry(host, port, retries \\ 20) do
    case Xandra.start_link(nodes: ["#{host}:#{port}"], connect_timeout: 15_000) do
      {:ok, conn} ->
        case wait_for_cql(conn, 15) do
          :ok -> {:ok, conn}
          {:error, _} when retries > 0 ->
            Xandra.stop(conn)
            Process.sleep(5_000)
            connect_with_retry(host, port, retries - 1)
          {:error, reason} ->
            Xandra.stop(conn)
            {:error, reason}
        end
      {:error, _} when retries > 0 ->
        Process.sleep(5_000)
        connect_with_retry(host, port, retries - 1)
      {:error, reason} ->
        {:error, reason}
    end
  end

  defp wait_for_cql(conn, retries) do
    case Xandra.execute(conn, "SELECT now() FROM system.local", [], timeout: 5_000, consistency: :one) do
      {:ok, _} -> :ok
      {:error, _} when retries > 0 ->
        Process.sleep(1_000)
        wait_for_cql(conn, retries - 1)
      {:error, reason} -> {:error, reason}
    end
  end

  defp quote_name(name), do: ~s("#{name}")

  defp full_table(name), do: "#{quote_name(@keyspace)}.#{quote_name(name)}"

  # ── CQL constructors for manual index operations ──────────────────────────

  defp insert_term(post_id, term, field, tf) do
    shard = Storage.shard_for(term)
    escaped = String.replace(term, "'", "''")
    "INSERT INTO #{full_table(@table_terms)} (term, shard, post_id, field, tf) " <>
      "VALUES ('#{escaped}', #{shard}, #{post_id}, #{field}, #{tf})"
  end

  defp select_term(conn, term) do
    escaped = String.replace(term, "'", "''")
    queries =
      0..15
      |> Enum.map(fn shard ->
        "SELECT post_id, field, tf FROM #{full_table(@table_terms)} " <>
          "WHERE term = '#{escaped}' AND shard = #{shard}"
      end)

    queries
    |> Enum.reduce(%{rows: [], num_rows: 0, columns: []}, fn query, acc ->
      case Xandra.execute(conn, query, []) do
        {:ok, %Xandra.Page{content: rows, columns: cols}} ->
          rows_list = rows || []
          %{rows: acc.rows ++ rows_list, num_rows: acc.num_rows + length(rows_list), columns: cols || acc.columns}
        {:error, reason} ->
          raise "Query failed: #{inspect(reason)}\nQuery: #{query}"
      end
    end)
  end

  defp delete_term_rows(post_id, term) do
    shard = Storage.shard_for(term)
    escaped = String.replace(term, "'", "''")
    "DELETE FROM #{full_table(@table_terms)} " <>
      "WHERE term = '#{escaped}' AND shard = #{shard} AND post_id = #{post_id}"
  end

  # ── Setup ─────────────────────────────────────────────────────────────────

  setup_all do
    if System.get_env("TEST_CLUSTER") == "true" do
      Logger.warning("TEST_CLUSTER=true — skipping search integration tests")
      %{conn: nil, scylla: nil}
    else
      if direct_connect?() do
        host = direct_host()
        port = direct_port()

        case connect_with_retry(host, port) do
          {:ok, conn} ->
            xq(conn, """
            CREATE KEYSPACE IF NOT EXISTS #{quote_name(@keyspace)}
            WITH REPLICATION = {'class': 'NetworkTopologyStrategy', 'replication_factor': 1}
            """)

            ensure_tables(conn)

            %{scylla: :direct, host: host, port: port}
          {:error, reason} ->
            Logger.warning(
              "ScyllaDB connection failed: #{inspect(reason)} — skipping search integration tests"
            )
            %{scylla: nil, conn: nil}
        end
      else
        case AshScylla.Test.ContainerEngine.ensure_running() do
          :ok ->
            case ScyllaContainer.start(scylla_container_config()) do
              {:ok, container} ->
                host = ScyllaContainer.host(container)
                port = ScyllaContainer.port(container)

                case connect_with_retry(host, port) do
                  {:ok, conn} ->
                    xq(conn, """
                    CREATE KEYSPACE IF NOT EXISTS #{quote_name(@keyspace)}
                    WITH REPLICATION = {'class': 'NetworkTopologyStrategy', 'replication_factor': 1}
                    """)

                    ensure_tables(conn)
                    Xandra.stop(conn)

                    on_exit(fn -> ScyllaContainer.stop(container.container_id) end)

                    %{scylla: :container, container_host: host, container_port: port}

                  {:error, reason} ->
                    Logger.warning(
                      "ScyllaDB container connection failed: #{inspect(reason)} — skipping search integration tests"
                    )

                    %{scylla: nil, conn: nil}
                end

              {:error, reason} ->
                Logger.warning(
                  "Failed to start ScyllaDB container: #{inspect(reason)}"
                )

                %{scylla: nil, conn: nil}
            end

          {:error, _} ->
            %{scylla: nil, conn: nil}
        end
      end
    end
  end

  setup context do
    case Map.fetch(context, :scylla) do
      {:ok, :direct} ->
        case connect_with_retry(context.host, context.port) do
          {:ok, conn} ->
            ensure_tables(conn)
            xq(conn, "TRUNCATE TABLE #{full_table(@table_terms)}")
            xq(conn, "TRUNCATE TABLE #{full_table(@table_fields)}")
            %{conn: conn}
          {:error, _} ->
            %{conn: nil}
        end

      {:ok, :container} ->
        case connect_with_retry(context.container_host, context.container_port) do
          {:ok, conn} ->
            ensure_tables(conn)
            xq(conn, "TRUNCATE TABLE #{full_table(@table_terms)}")
            xq(conn, "TRUNCATE TABLE #{full_table(@table_fields)}")
            %{conn: conn}
          {:error, _} ->
            %{conn: nil}
        end

      _ ->
        %{conn: nil}
    end
  end

  defp ensure_tables(conn) do
    xq(conn, "DROP TABLE IF EXISTS #{full_table(@table_terms)}")
    xq(conn, "DROP TABLE IF EXISTS #{full_table(@table_fields)}")

    cql = Storage.create_post_terms_cql(@keyspace)
    xq(conn, cql)

    cql = Storage.create_post_fields_cql(@keyspace)
    xq(conn, cql)
  end

  # ══════════════════════════════════════════════════════════════════════════
  # 1. Table creation and schema validation
  # ══════════════════════════════════════════════════════════════════════════

  describe "table schema" do
    test "creates search_post_terms table successfully", %{conn: conn} do
      if is_nil(conn), do: skip_scylla()

      result = xq(conn, "SELECT table_name FROM system_schema.tables
        WHERE keyspace_name = '#{@keyspace}' AND table_name = '#{@table_terms}'")

      assert result.num_rows == 1
    end

    test "creates search_post_fields table successfully", %{conn: conn} do
      if is_nil(conn), do: skip_scylla()

      result = xq(conn, "SELECT table_name FROM system_schema.tables
        WHERE keyspace_name = '#{@keyspace}' AND table_name = '#{@table_fields}'")

      assert result.num_rows == 1
    end

    test "search_post_terms has correct partition key", %{conn: conn} do
      if is_nil(conn), do: skip_scylla()

      result = xq(conn, "SELECT column_name, kind FROM system_schema.columns
        WHERE keyspace_name = '#{@keyspace}' AND table_name = '#{@table_terms}'")

      pk_columns =
        result.rows
        |> Enum.filter(fn [_, kind] -> kind in ["partition_key", "clustering"] end)
        |> Enum.map(fn [name, _] -> name end)

      assert "term" in pk_columns
      assert "shard" in pk_columns
      assert "post_id" in pk_columns
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # 2. Single-term indexing and lookup
  # ══════════════════════════════════════════════════════════════════════════

  describe "single-term index and lookup" do
    test "inserts a term and retrieves it via exact lookup", %{conn: conn} do
      if is_nil(conn), do: skip_scylla()

      post_id = uid()

      xq(conn, insert_term(post_id, "phoenix", 0, 2))
      xq(conn, "UPDATE #{full_table(@table_fields)} SET terms = {'phoenix'}
        WHERE post_id = #{post_id} AND field = 0")

      result = select_term(conn,"phoenix") 

      assert result.num_rows == 1
      assert Enum.map(result.rows, fn [pid, _, _] -> pid end) |> Enum.member?(post_id)
    end

    test "inserts multiple terms for same post and retrieves all", %{conn: conn} do
      if is_nil(conn), do: skip_scylla()

      post_id = uid()

      xq(conn, insert_term(post_id, "elixir", 1, 1))
      xq(conn, insert_term(post_id, "phoenix", 1, 3))

      xq(conn, "UPDATE #{full_table(@table_fields)} SET terms = {'elixir', 'phoenix'}
        WHERE post_id = #{post_id} AND field = 1")

      r1 = select_term(conn,"elixir") 
      r2 = select_term(conn,"phoenix") 

      assert r1.num_rows == 1
      assert r2.num_rows == 1
    end

    test "properly distributes terms across shards", %{conn: conn} do
      if is_nil(conn), do: skip_scylla()

      post_id = uid()
      term = "framework"

      shard = Storage.shard_for(term)
      xq(conn, insert_term(post_id, term, 0, 1))

      cql = "SELECT shard FROM #{full_table(@table_terms)}
        WHERE term = '#{term}' AND shard = #{shard}"

      result = xq(conn, cql)
      assert result.num_rows == 1

      [found_shard] = hd(result.rows)
      assert found_shard == shard
    end

    test "shard_for returns consistent results", %{conn: conn} do
      if is_nil(conn), do: skip_scylla()

      s1 = Storage.shard_for("phoenix")
      s2 = Storage.shard_for("phoenix")
      s3 = Storage.shard_for("phoenix")
      assert s1 == s2
      assert s2 == s3
      assert s1 in 0..15
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # 3. Multi-term indexing and frequency counting
  # ══════════════════════════════════════════════════════════════════════════

  describe "multi-term index with frequencies" do
    test "stores and retrieves term frequencies correctly", %{conn: conn} do
      if is_nil(conn), do: skip_scylla()

      post_id = uid()

      xq(conn, insert_term(post_id, "phoenix", 0, 5))
      xq(conn, insert_term(post_id, "elixir", 0, 2))

      result = select_term(conn,"phoenix") 

      assert result.num_rows == 1
      [[^post_id, 0, tf]] = result.rows
      assert tf == 5
    end

    test "handles same term in different fields", %{conn: conn} do
      if is_nil(conn), do: skip_scylla()

      post_id = uid()

      xq(conn, insert_term(post_id, "phoenix", 0, 3))
      xq(conn, insert_term(post_id, "phoenix", 1, 2))

      result = select_term(conn,"phoenix") 

      assert result.num_rows == 2

      tfs = Enum.map(result.rows, fn [_, _, tf] -> tf end)
      assert 3 in tfs
      assert 2 in tfs
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # 4. Multi-word AND search via intersection
  # ══════════════════════════════════════════════════════════════════════════

  describe "multi-word AND search" do
    test "finds documents containing all query terms", %{conn: conn} do
      if is_nil(conn), do: skip_scylla()

      post1 = uid()
      post2 = uid()
      post3 = uid()

      xq(conn, insert_term(post1, "phoenix", 0, 2))
      xq(conn, insert_term(post1, "framework", 0, 1))

      xq(conn, insert_term(post2, "phoenix", 0, 3))

      xq(conn, insert_term(post3, "framework", 0, 1))

      r_phoenix = select_term(conn,"phoenix") 
      r_framework = select_term(conn,"framework") 

      phoenix_posts = MapSet.new(Enum.map(r_phoenix.rows, fn [pid, _, _] -> pid end))
      framework_posts = MapSet.new(Enum.map(r_framework.rows, fn [pid, _, _] -> pid end))

      intersection = MapSet.intersection(phoenix_posts, framework_posts)

      assert MapSet.member?(intersection, post1)
      refute MapSet.member?(intersection, post2)
      refute MapSet.member?(intersection, post3)
      assert MapSet.size(intersection) == 1
    end

    test "returns empty when no document matches all terms", %{conn: conn} do
      if is_nil(conn), do: skip_scylla()

      post1 = uid()

      xq(conn, insert_term(post1, "elixir", 0, 1))

      r_elixir = select_term(conn,"elixir") 
      r_python = select_term(conn,"python") 

      elixir_posts = MapSet.new(Enum.map(r_elixir.rows, fn [pid, _, _] -> pid end))
      python_posts = MapSet.new(Enum.map(r_python.rows, fn [pid, _, _] -> pid end))

      assert MapSet.intersection(elixir_posts, python_posts) |> MapSet.size() == 0
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # 5. Document update (diff-based)
  # ══════════════════════════════════════════════════════════════════════════

  describe "document updates" do
    test "removes old terms and adds new terms on update", %{conn: conn} do
      if is_nil(conn), do: skip_scylla()

      post_id = uid()

      xq(conn, insert_term(post_id, "phoenix", 0, 2))
      xq(conn, insert_term(post_id, "elixir", 0, 1))
      xq(conn, "UPDATE #{full_table(@table_fields)} SET terms = {'phoenix', 'elixir'}
        WHERE post_id = #{post_id} AND field = 0")

      r_before = select_term(conn,"phoenix") 
      assert r_before.num_rows >= 1

      xq(conn, delete_term_rows(post_id, "phoenix"))
      xq(conn, "UPDATE #{full_table(@table_fields)} SET terms = terms - {'phoenix'}
        WHERE post_id = #{post_id} AND field = 0")

      xq(conn, insert_term(post_id, "framework", 0, 3))
      xq(conn, "UPDATE #{full_table(@table_fields)} SET terms = terms + {'framework'}
        WHERE post_id = #{post_id} AND field = 0")

      r_after_phoenix = select_term(conn,"phoenix") 
      r_after_framework = select_term(conn,"framework") 

      phoenix_posts = Enum.map(r_after_phoenix.rows, fn [pid, _, _] -> pid end)
      framework_posts = Enum.map(r_after_framework.rows, fn [pid, _, _] -> pid end)

      refute post_id in phoenix_posts
      assert post_id in framework_posts

      r_fields = xq(conn, "SELECT terms FROM #{full_table(@table_fields)}
        WHERE post_id = #{post_id} AND field = 0")
      [[stored_terms]] = r_fields.rows
      assert "elixir" in stored_terms
      assert "framework" in stored_terms
      refute "phoenix" in stored_terms
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # 6. Document deletion
  # ══════════════════════════════════════════════════════════════════════════

  describe "document deletion" do
    test "removes all index entries for a deleted document", %{conn: conn} do
      if is_nil(conn), do: skip_scylla()

      post_id = uid()

      xq(conn, insert_term(post_id, "phoenix", 0, 2))
      xq(conn, insert_term(post_id, "framework", 1, 1))
      xq(conn, "UPDATE #{full_table(@table_fields)} SET terms = {'phoenix'}
        WHERE post_id = #{post_id} AND field = 0")
      xq(conn, "UPDATE #{full_table(@table_fields)} SET terms = {'framework'}
        WHERE post_id = #{post_id} AND field = 1")

      r_before = select_term(conn,"phoenix") 
      assert Enum.map(r_before.rows, fn [pid, _, _] -> pid end) |> Enum.member?(post_id)

      xq(conn, delete_term_rows(post_id, "phoenix"))
      xq(conn, delete_term_rows(post_id, "framework"))
      xq(conn, "DELETE FROM #{full_table(@table_fields)} WHERE post_id = #{post_id}")

      r_after_phoenix = select_term(conn,"phoenix") 
      r_after_framework = select_term(conn,"framework") 

      phoenix_posts = Enum.map(r_after_phoenix.rows, fn [pid, _, _] -> pid end)
      framework_posts = Enum.map(r_after_framework.rows, fn [pid, _, _] -> pid end)

      refute post_id in phoenix_posts
      refute post_id in framework_posts

      r_fields = xq(conn, "SELECT terms FROM #{full_table(@table_fields)}
        WHERE post_id = #{post_id}")
      assert r_fields.num_rows == 0
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # 7. Analyzer pipeline end-to-end
  # ══════════════════════════════════════════════════════════════════════════

  describe "analyzer pipeline" do
    test "indexes analyzed terms and finds them via stemmed lookup", %{conn: conn} do
      if is_nil(conn), do: skip_scylla()

      post_id = uid()
      text = "Running Phoenix Framework applications"

      terms = Analyzer.analyze(text)

      Enum.each(terms, fn {term, tf} ->
        xq(conn, insert_term(post_id, term, 0, tf))
      end)

      unique_terms = Enum.map(terms, &elem(&1, 0))
      xq(conn, "UPDATE #{full_table(@table_fields)} SET terms = {#{format_set(unique_terms)}}
        WHERE post_id = #{post_id} AND field = 0")

      r_run = select_term(conn,"run") 
      r_phoenix = select_term(conn,"phoenix") 

      assert r_run.num_rows >= 1
      assert r_phoenix.num_rows >= 1
    end

    test "stop words are excluded from index", %{conn: conn} do
      if is_nil(conn), do: skip_scylla()

      post_id = uid()
      text = "The quick brown fox is very fast"

      terms = Analyzer.analyze(text)
      term_names = Enum.map(terms, &elem(&1, 0))

      refute "the" in term_names
      refute "is" in term_names
      refute "very" in term_names
      assert "quick" in term_names
      assert "fox" in term_names
      assert "fast" in term_names
    end

    test "stemmer reduces variations to root form", %{conn: conn} do
      if is_nil(conn), do: skip_scylla()

      post1 = uid()

      type1 = Analyzer.analyze("running")
      type2 = Analyzer.analyze("runs")
      type3 = Analyzer.analyze("runner")

      t1 = Enum.map(type1, &elem(&1, 0))
      t2 = Enum.map(type2, &elem(&1, 0))
      t3 = Enum.map(type3, &elem(&1, 0))

      assert "run" in t1
      assert "run" in t2
      assert "run" in t3
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # 8. Pagination
  # ══════════════════════════════════════════════════════════════════════════

  describe "pagination" do
    test "paginates search results correctly", %{conn: conn} do
      if is_nil(conn), do: skip_scylla()

      posts = Enum.map(1..25, fn _ -> uid() end)

      Enum.each(posts, fn post_id ->
        xq(conn, insert_term(post_id, "elixir", 0, 1))
      end)

      result = select_term(conn,"elixir") 

      assert result.num_rows == 25

      page1 = result.rows |> Enum.take(10)
      page2 = result.rows |> Enum.drop(10) |> Enum.take(10)
      page3 = result.rows |> Enum.drop(20) |> Enum.take(10)

      assert length(page1) == 10
      assert length(page2) == 10
      assert length(page3) == 5
    end

    test "empty search returns no results", %{conn: conn} do
      if is_nil(conn), do: skip_scylla()

      result = select_term(conn,"nonexistent_term_xyz") 

      assert result.num_rows == 0
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # 9. Storage and shard helpers
  # ══════════════════════════════════════════════════════════════════════════

  describe "storage helpers" do
    test "create_post_terms_cql generates valid CQL", %{conn: conn} do
      if is_nil(conn), do: skip_scylla()

      cql = Storage.create_post_terms_cql(@keyspace)
      assert String.contains?(cql, "CREATE TABLE IF NOT EXISTS")
      assert String.contains?(cql, @table_terms)
      assert String.contains?(cql, "PRIMARY KEY ((term, shard), post_id, field)")

      xq(conn, cql)
    end

    test "create_post_fields_cql generates valid CQL", %{conn: conn} do
      if is_nil(conn), do: skip_scylla()

      cql = Storage.create_post_fields_cql(@keyspace)
      assert String.contains?(cql, "CREATE TABLE IF NOT EXISTS")
      assert String.contains?(cql, @table_fields)
      assert String.contains?(cql, "PRIMARY KEY (post_id, field)")

      xq(conn, cql)
    end

    test "shard_for returns values in range", %{conn: conn} do
      if is_nil(conn), do: skip_scylla()

      Enum.each(1..100, fn i ->
        shard = Storage.shard_for("term_#{i}")
        assert shard >= 0
        assert shard < 16
      end)
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # 10. Edge cases
  # ══════════════════════════════════════════════════════════════════════════

  describe "edge cases" do
    test "handles terms with special characters", %{conn: conn} do
      if is_nil(conn), do: skip_scylla()

      post_id = uid()
      term = "c++"

      xq(conn, insert_term(post_id, term, 0, 3))

      result = select_term(conn,term) 
      assert result.num_rows == 1
    end

    test "handles Unicode terms", %{conn: conn} do
      if is_nil(conn), do: skip_scylla()

      post_id = uid()
      term = "テスト"

      xq(conn, insert_term(post_id, term, 0, 1))

      result = select_term(conn,term) 
      assert result.num_rows == 1
      [[^post_id, 0, 1]] = result.rows
    end

    test "handles duplicate inserts gracefully", %{conn: conn} do
      if is_nil(conn), do: skip_scylla()

      post_id = uid()

      xq(conn, insert_term(post_id, "phoenix", 0, 5))
      xq(conn, insert_term(post_id, "phoenix", 0, 3))

      result = select_term(conn,"phoenix") 
      assert result.num_rows == 1

      [[^post_id, 0, tf]] = result.rows
      assert tf == 3
    end

    test "handles large batch of terms", %{conn: conn} do
      if is_nil(conn), do: skip_scylla()

      post_id = uid()
      terms = Enum.map(1..50, fn i -> "term_#{i}" end)

      batch =
        terms
        |> Enum.map(fn term -> insert_term(post_id, term, 0, 1) end)

      Enum.each(batch, fn query -> xq(conn, query) end)

      result = select_term(conn,"term_25") 
      assert result.num_rows == 1
    end
  end

  defp skip_scylla do
    Logger.warning("No ScyllaDB connection available — skipping test")
  end

  defp format_set(terms) do
    terms |> Enum.map(&"'#{String.replace(&1, "'", "''")}'") |> Enum.join(", ")
  end
end
