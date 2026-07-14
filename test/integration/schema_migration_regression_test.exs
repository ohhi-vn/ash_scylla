defmodule AshScylla.SchemaMigration.RegressionTest do
  @moduledoc """
  Regression tests for the migration flow where generated DDL (CREATE TABLE,
  ALTER TABLE, CREATE INDEX, CREATE MATERIALIZED VIEW) is emitted WITH a
  keyspace qualifier when the resource declares a keyspace. The keyspace
  qualifier keeps generated statements unambiguous even when the connection's
  `USE keyspace` context is lost (e.g. across separate migration statements or
  in release migrations).

  Requires a running ScyllaDB instance (container or SCYLLA_DIRECT). Tagged
  :integration and excluded from default test runs.
  """
  use ExUnit.Case, async: false

  require Logger

  alias AshScylla.DataLayer.SchemaMigration
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

  setup_all do
    if System.get_env("TEST_CLUSTER") == "true" do
      %{conn: nil}
    else
      if direct_connect?() do
        conn = connect_with_retry(direct_host(), direct_port())

        Xandra.execute(
          conn,
          "CREATE KEYSPACE IF NOT EXISTS ash_scylla_dl_test WITH REPLICATION = {'class': 'NetworkTopologyStrategy', 'replication_factor': 1}"
        )

        # Start the TestRepo connection so SchemaMigration.diff/migrate can
        # reach the DB via the repo. The repo module itself has no start_link/1;
        # the connection is registered under the repo module name.
        case AshScylla.Connection.start_link(
               name: AshScylla.TestRepo,
               nodes: ["#{direct_host()}:#{direct_port()}"],
               keyspace: "ash_scylla_dl_test",
               connect_timeout: 15_000
             ) do
               {:ok, _} -> :ok
               {:error, {:already_started, _}} -> :ok
             end

        %{conn: conn}
      else
        case AshScylla.Test.ContainerEngine.ensure_running() do
          :ok ->
            _ =
              ScyllaContainer.start(
                ScyllaContainer.new()
                |> ScyllaContainer.with_image("scylladb/scylla:5.4")
                |> ScyllaContainer.with_wait_timeout(120_000)
              )

            %{conn: nil}

          {:error, _} ->
            %{conn: nil}
        end
      end
    end
  end

  defp build_temp_resource(table, ks, columns) do
    attrs =
      Enum.map(columns, fn col ->
        if col == :id do
          "attribute(:id, :uuid, primary_key?: true, allow_nil?: false)"
        else
          "attribute(#{inspect(col)}, :string)"
        end
      end)

    module_name = Module.concat(["TempRes#{System.unique_integer([:positive])}"])

    Code.eval_string("""
    defmodule #{module_name} do
      use Ash.Resource,
        domain: nil,
        data_layer: AshScylla.DataLayer,
        validate_domain_inclusion?: false

      import AshScylla.DataLayer.Dsl

      scylla do
        repo(AshScylla.TestRepo)
        table(#{inspect(table)})
        keyspace(#{inspect(ks)})
      end

      attributes do
        #{Enum.join(attrs, "\n      ")}
      end

      actions do
        defaults([:create, :read, :update, :destroy])
      end
    end
    """)

    module_name
  end

  # Extracts column values from a Xandra.Page by column name.
  # Xandra rows may be lists or tuples; column metadata may be 3- or 4-tuples.
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

  describe "unqualified DDL (regression)" do
    test "diff/2 generates unqualified ALTER TABLE for an existing table", %{conn: conn} do
      if is_nil(conn) do
        Logger.warning("No ScyllaDB connection available — skipping regression test")
        :ok
      else
        ks = "ash_scylla_dl_test"
        table = "regression_add_col"

        Xandra.execute(
          conn,
          "CREATE TABLE IF NOT EXISTS #{ks}.#{table} (id UUID PRIMARY KEY, name TEXT)"
        )

        resource = build_temp_resource(table, ks, [:id, :name, :extra])

        statements = SchemaMigration.diff(resource, AshScylla.TestRepo)

        assert Enum.any?(statements, fn stmt ->
                 stmt =~ ~s/ALTER TABLE "#{ks}"."#{table}" ADD "extra"/
               end),
               "expected a keyspace-qualified ALTER TABLE ADD, got: #{inspect(statements)}"
      end
    end

    test "migrate/2 succeeds when only ALTER TABLE ADD is required", %{conn: conn} do
      if is_nil(conn) do
        Logger.warning("No ScyllaDB connection available - skipping regression test")
        :ok
      else
        ks = "ash_scylla_dl_test"
        table = "regression_migrate"

        Xandra.execute( conn,
          "CREATE TABLE IF NOT EXISTS #{ks}.#{table} (id UUID PRIMARY KEY, name TEXT)" )

        resource = build_temp_resource(table, ks, [:id, :name, :extra])

        assert {:ok, _} = SchemaMigration.migrate(resource, AshScylla.TestRepo)

        {:ok, page} =
          Xandra.execute(
            conn,
            "SELECT column_name FROM system_schema.columns WHERE keyspace_name = ? AND table_name = ?",
            [{"text", ks}, {"text", table}]
          )

        column_names = extract_column(page, "column_name")
        assert "extra" in column_names
      end
    end
  end
end
