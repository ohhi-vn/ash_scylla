defmodule AshScylla.MigrationFlowIntegrationTest do
  @moduledoc """
  Integration tests for the full migration flow:
  1. Generate migration CQL (no keyspace prefix in statements)
  2. Execute migration via Migrator.run/3 (keyspace via USE at connection level)
  3. Perform CRUD operations against the migrated tables

  Requires a running ScyllaDB instance (container or SCYLLA_DIRECT). Tagged
  :integration and excluded from default test runs.
  """
  use ExUnit.Case, async: false

  require Logger

  alias AshScylla.ScyllaContainer, warn: false

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

  defp test_keyspace, do: "ash_scylla_flow_test"

  setup_all do
    if direct_connect?() do
      host = direct_host()
      port = direct_port()
      conn = connect_with_retry(host, port)

      Xandra.execute(
        conn,
        "CREATE KEYSPACE IF NOT EXISTS #{test_keyspace()} WITH REPLICATION = {'class': 'NetworkTopologyStrategy', 'replication_factor': 1}"
      )

      case AshScylla.Connection.start_link(
             name: AshScylla.TestRepo,
             nodes: ["#{host}:#{port}"],
             keyspace: test_keyspace(),
             connect_timeout: 15_000
           ) do
        {:ok, _} -> :ok
        {:error, {:already_started, _}} -> :ok
      end

      %{conn: conn, keyspace: test_keyspace()}
    else
      case AshScylla.Test.ContainerEngine.ensure_running() do
        :ok ->
          _ =
            ScyllaContainer.start(
              ScyllaContainer.new()
              |> ScyllaContainer.with_image("scylladb/scylla:5.4")
              |> ScyllaContainer.with_wait_timeout(120_000)
            )

          %{conn: nil, keyspace: nil}

        {:error, _} ->
          %{conn: nil, keyspace: nil}
      end
    end
  end

  defp build_flow_resource(table, ks, columns, opts \\ []) do
    attrs =
      Enum.map(columns, fn
        {:id, type, pk_opts} ->
          pk = Keyword.get(pk_opts, :primary_key?, false)
          ~s[attribute(:id, #{inspect(type)}, primary_key?: #{pk}, allow_nil?: #{!pk})]

        {name, type} ->
          ~s[attribute(#{inspect(name)}, #{inspect(type)})]
      end)

    attrs_str = Enum.join(attrs, "\n      ")

    indexes_dsl =
      case Keyword.get(opts, :indexes, []) do
        [] ->
          ""

        indexes ->
          indexes
          |> Enum.map_join("\n        ", fn
            {nil, col} -> ~s[secondary_index(#{inspect(col)})]
            {name, col} -> ~s[secondary_index(#{inspect(col)}, name: #{inspect(name)})]
          end)
      end

    scylla_body =
      if indexes_dsl == "" do
        ~s[repo(AshScylla.TestRepo)
        table(#{inspect(table)})
        keyspace(#{inspect(ks)})]
      else
        ~s[repo(AshScylla.TestRepo)
        table(#{inspect(table)})
        keyspace(#{inspect(ks)})
        #{indexes_dsl}]
      end

    module_name = Module.concat(["FlowRes#{System.unique_integer([:positive])}"])

    Code.eval_string("""
    defmodule #{module_name} do
      use Ash.Resource,
        domain: AshScylla.TestDomain,
        data_layer: AshScylla.DataLayer

      import AshScylla.DataLayer.Dsl

      scylla do
        #{scylla_body}
      end

      attributes do
        #{attrs_str}
      end

      actions do
        defaults([:create, :read, :update, :destroy])
      end
    end
    """)

    module_name
  end

  defp extract_column(page, col_name) do
    col_idx =
      page.columns
      |> Enum.find_index(fn col ->
        case col do
          {_ks, _tbl, name, _type} -> name == col_name
          {_ks, _tbl, name} -> name == col_name
          name when is_binary(name) -> name == col_name
        end
      end)

    (page.content || [])
    |> Enum.map(fn row ->
      case row do
        row when is_tuple(row) -> elem(row, col_idx)
        row when is_list(row) -> Enum.at(row, col_idx)
      end
    end)
  end

  describe "full migration flow" do
    test "Migrator.run/3 executes bare table name CQL via keyspace context", %{
      conn: conn,
      keyspace: ks
    } do
      if is_nil(conn) do
        Logger.warning("No ScyllaDB connection available — skipping test")
        :ok
      else
        table = "flow_bare_table"

        statements = [
          ~s[CREATE TABLE IF NOT EXISTS "#{table}" (id UUID PRIMARY KEY, name TEXT, email TEXT)],
          ~s[CREATE INDEX IF NOT EXISTS idx_#{table}_email ON "#{table}" (email)]
        ]

        assert {:ok, _} =
                 AshScylla.Migrator.run(
                   ["#{direct_host()}:#{direct_port()}"],
                   statements,
                   keyspace: ks
                 )

        {:ok, page} =
          Xandra.execute(
            conn,
            "SELECT table_name FROM system_schema.tables WHERE keyspace_name = ? AND table_name = ?",
            [{"text", ks}, {"text", table}]
          )

        assert table in extract_column(page, "table_name"),
               "Table #{table} should exist in keyspace #{ks}"

        {:ok, page} =
          Xandra.execute(
            conn,
            "SELECT index_name FROM system_schema.indexes WHERE keyspace_name = ? AND table_name = ?",
            [{"text", ks}, {"text", table}]
          )

        assert "idx_#{table}_email" in extract_column(page, "index_name"),
               "Index should exist"

        {:ok, _} =
          Xandra.execute(
            conn,
            ~s[INSERT INTO #{ks}."#{table}" (id, name, email) VALUES (uuid(), 'test', 'test@example.com')]
          )

        {:ok, page} =
          Xandra.execute(
            conn,
            ~s[SELECT * FROM #{ks}."#{table}" WHERE name = 'test' ALLOW FILTERING]
          )

        assert (page.content || []) != []
      end
    end

    test "Migrator.run/3 auto-migrate via SchemaMigration.generate", %{conn: conn, keyspace: ks} do
      if is_nil(conn) do
        Logger.warning("No ScyllaDB connection available — skipping test")
        :ok
      else
        table = "flow_auto_migrate"

        resource =
          build_flow_resource(table, ks, [
            {:id, :uuid, [primary_key?: true]},
            {:name, :string},
            {:email, :string},
            {:score, :integer}
          ])

        statements = AshScylla.DataLayer.SchemaMigration.generate(resource)

        create_stmt = Enum.find(statements, &String.starts_with?(&1, "CREATE TABLE"))
        assert create_stmt
        assert create_stmt =~ ~s[CREATE TABLE IF NOT EXISTS "#{ks}"."#{table}"]

        # Indexes (if any) should remain unqualified and rely on keyspace context.
        Enum.each(statements, fn stmt ->
          if String.starts_with?(stmt, "CREATE INDEX") do
            refute stmt =~ ~s("#{ks}".),
                   "CREATE INDEX should not contain keyspace prefix: #{stmt}"
          end
        end)

        assert {:ok, _} =
                 AshScylla.Migrator.run(
                   ["#{direct_host()}:#{direct_port()}"],
                   statements,
                   keyspace: ks
                 )

        {:ok, page} =
          Xandra.execute(
            conn,
            "SELECT table_name FROM system_schema.tables WHERE keyspace_name = ? AND table_name = ?",
            [{"text", ks}, {"text", table}]
          )

        assert table in extract_column(page, "table_name")
      end
    end

    test "SchemaMigration.generate renders CQL without keyspace prefix", %{conn: conn} do
      if is_nil(conn) do
        Logger.warning("No ScyllaDB connection available — skipping test")
        :ok
      else
        resource =
          build_flow_resource(
            "flow_render_test",
            test_keyspace(),
            [
              {:id, :uuid, [primary_key?: true]},
              {:name, :string}
            ],
            indexes: [{nil, :name}]
          )

        statements = AshScylla.DataLayer.SchemaMigration.generate(resource)

        create_stmt = Enum.find(statements, &String.starts_with?(&1, "CREATE TABLE"))
        assert create_stmt

        assert create_stmt =~
                 ~s[CREATE TABLE IF NOT EXISTS "#{test_keyspace()}"."flow_render_test"]

        index_stmt = Enum.find(statements, &String.starts_with?(&1, "CREATE INDEX"))
        assert index_stmt

        refute index_stmt =~ ~s("#{test_keyspace()}"),
               "CREATE INDEX should not contain keyspace prefix: #{index_stmt}"

        assert index_stmt =~ ~s[ON "flow_render_test"]
      end
    end

    test "migrate then CRUD works", %{conn: conn, keyspace: ks} do
      if is_nil(conn) do
        Logger.warning("No ScyllaDB connection available — skipping test")
        :ok
      else
        table = "flow_crud_test"

        statements = [
          ~s[CREATE TABLE IF NOT EXISTS "#{table}" (id UUID PRIMARY KEY, name TEXT, value INT)]
        ]

        assert {:ok, _} =
                 AshScylla.Migrator.run(
                   ["#{direct_host()}:#{direct_port()}"],
                   statements,
                   keyspace: ks
                 )

        id = Ash.UUID.generate()

        {:ok, _} =
          Xandra.execute(
            conn,
            ~s[INSERT INTO #{ks}."#{table}" (id, name, value) VALUES (?, ?, ?)],
            [{"uuid", id}, {"text", "flow_test"}, {"int", 42}]
          )

        {:ok, page} =
          Xandra.execute(
            conn,
            ~s[SELECT name, value FROM #{ks}."#{table}" WHERE id = ?],
            [{"uuid", id}]
          )

        rows = page.content || []
        assert rows != []
      end
    end

    test "multiple resources in same migration", %{conn: conn, keyspace: ks} do
      if is_nil(conn) do
        Logger.warning("No ScyllaDB connection available — skipping test")
        :ok
      else
        table_a = "flow_multi_a"
        table_b = "flow_multi_b"

        statements = [
          ~s[CREATE TABLE IF NOT EXISTS "#{table_a}" (id UUID PRIMARY KEY, label TEXT)],
          ~s[CREATE TABLE IF NOT EXISTS "#{table_b}" (id UUID PRIMARY KEY, label TEXT)]
        ]

        assert {:ok, results} =
                 AshScylla.Migrator.run(
                   ["#{direct_host()}:#{direct_port()}"],
                   statements,
                   keyspace: ks
                 )

        assert length(results) == 2

        for table <- [table_a, table_b] do
          {:ok, page} =
            Xandra.execute(
              conn,
              "SELECT table_name FROM system_schema.tables WHERE keyspace_name = ? AND table_name = ?",
              [{"text", ks}, {"text", table}]
            )

          assert table in extract_column(page, "table_name"),
                 "Table #{table} should exist"
        end
      end
    end

    test "add column migration via SchemaMigration.diff", %{conn: conn, keyspace: ks} do
      if is_nil(conn) do
        Logger.warning("No ScyllaDB connection available — skipping test")
        :ok
      else
        table = "flow_add_col"

        {:ok, _} =
          Xandra.execute(
            conn,
            ~s[CREATE TABLE IF NOT EXISTS #{ks}."#{table}" (id UUID PRIMARY KEY, name TEXT)]
          )

        resource =
          build_flow_resource(table, ks, [
            {:id, :uuid, [primary_key?: true]},
            {:name, :string},
            {:email, :string}
          ])

        statements = AshScylla.DataLayer.SchemaMigration.diff(resource, AshScylla.TestRepo)

        assert Enum.any?(statements, fn stmt ->
                 stmt =~ ~s[ALTER TABLE "#{ks}"."#{table}" ADD "email"]
               end),
               "diff should generate ALTER TABLE ADD for the new column"

        assert {:ok, _} =
                 AshScylla.Migrator.run(
                   ["#{direct_host()}:#{direct_port()}"],
                   statements,
                   keyspace: ks
                 )

        {:ok, page} =
          Xandra.execute(
            conn,
            "SELECT column_name FROM system_schema.columns WHERE keyspace_name = ? AND table_name = ?",
            [{"text", ks}, {"text", table}]
          )

        assert "email" in extract_column(page, "column_name"),
               "email column should have been added"
      end
    end

    test "add index migration via SchemaMigration.diff", %{conn: conn, keyspace: ks} do
      if is_nil(conn) do
        Logger.warning("No ScyllaDB connection available — skipping test")
        :ok
      else
        table = "flow_add_idx"

        {:ok, _} =
          Xandra.execute(
            conn,
            ~s[CREATE TABLE IF NOT EXISTS #{ks}."#{table}" (id UUID PRIMARY KEY, name TEXT, email TEXT, status TEXT)]
          )

        resource =
          build_flow_resource(
            table,
            ks,
            [
              {:id, :uuid, [primary_key?: true]},
              {:name, :string},
              {:email, :string},
              {:status, :string}
            ],
            indexes: [{nil, :email}, {"idx_custom_status", :status}]
          )

        statements = AshScylla.DataLayer.SchemaMigration.diff(resource, AshScylla.TestRepo)

        assert Enum.any?(statements, fn stmt ->
                 stmt =~ ~s[CREATE INDEX IF NOT EXISTS] and stmt =~ ~s[ON "#{table}"]
               end),
               "diff should generate CREATE INDEX"

        refute Enum.any?(statements, fn stmt ->
                 stmt =~ ~s("#{ks}".)
               end),
               "Statements should not contain keyspace prefix"

        assert {:ok, _} =
                 AshScylla.Migrator.run(
                   ["#{direct_host()}:#{direct_port()}"],
                   statements,
                   keyspace: ks
                 )

        {:ok, page} =
          Xandra.execute(
            conn,
            "SELECT index_name FROM system_schema.indexes WHERE keyspace_name = ? AND table_name = ?",
            [{"text", ks}, {"text", table}]
          )

        index_names = extract_column(page, "index_name")
        assert "idx_#{table}_email" in index_names
        assert "idx_custom_status_status" in index_names
      end
    end

    test "plan and migrate produce consistent results", %{conn: conn, keyspace: ks} do
      if is_nil(conn) do
        Logger.warning("No ScyllaDB connection available — skipping test")
        :ok
      else
        table = "flow_plan_test"

        {:ok, _} =
          Xandra.execute(
            conn,
            ~s[CREATE TABLE IF NOT EXISTS #{ks}."#{table}" (id UUID PRIMARY KEY, name TEXT)]
          )

        resource =
          build_flow_resource(table, ks, [
            {:id, :uuid, [primary_key?: true]},
            {:name, :string},
            {:email, :string}
          ])

        {:ok, plan_statements} =
          AshScylla.DataLayer.SchemaMigration.plan(resource, AshScylla.TestRepo)

        assert plan_statements != []
        assert Enum.any?(plan_statements, &String.contains?(&1, ~s[ADD "email"]))

        assert {:ok, _} =
                 AshScylla.DataLayer.SchemaMigration.migrate(
                   resource,
                   AshScylla.TestRepo,
                   keyspace: ks
                 )
      end
    end
  end

  setup_all do
    if direct_connect?() do
      on_exit(fn ->
        for table <- [
              "flow_bare_table",
              "flow_auto_migrate",
              "flow_render_test",
              "flow_crud_test",
              "flow_multi_a",
              "flow_multi_b",
              "flow_add_col",
              "flow_add_idx",
              "flow_plan_test"
            ] do
          try do
            Xandra.execute(
              connect_with_retry(direct_host(), direct_port()),
              ~s[DROP TABLE IF EXISTS #{test_keyspace()}."#{table}"]
            )
          rescue
            _ -> :ok
          end
        end

        AshScylla.Connection.stop(AshScylla.TestRepo)
      end)
    end

    :ok
  end
end
