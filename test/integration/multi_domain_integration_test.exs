defmodule AshScylla.MultiDomainIntegrationTest do
  @moduledoc """
  Integration tests for multi-domain scenarios against a real ScyllaDB instance.

  Two domains (`DomainA` / `DomainB`) map resources with the SAME table name
  (`md_users`) to DIFFERENT keyspaces (`ash_scylla_md_a` / `ash_scylla_md_b`),
  both using `AshScylla.TestRepo`. Verifies that:

  1. `DataLayer.resource_to_query/2` qualifies tables with the correct
     per-domain keyspace.
  2. CQL built by `QueryBuilder` targets the correct keyspace.
  3. Data written through one domain is physically isolated from the other.

  Tagged `:integration` and excluded from default test runs.
  """

  use ExUnit.Case, async: false

  require Logger

  alias AshScylla.DataLayer
  alias AshScylla.DataLayer.QueryBuilder
  alias AshScylla.ScyllaContainer, warn: false

  @moduletag :integration

  @keyspace_a "ash_scylla_md_a"
  @keyspace_b "ash_scylla_md_b"
  @table "md_users"

  # ── Domains under test ─────────────────────────────────────────────────────

  defmodule DomainA do
    use Ash.Domain, otp_app: :ash_scylla, validate_config_inclusion?: false

    resources do
      resource(AshScylla.MultiDomainIntegrationTest.ResourceA)
    end
  end

  defmodule DomainB do
    use Ash.Domain, otp_app: :ash_scylla, validate_config_inclusion?: false

    resources do
      resource(AshScylla.MultiDomainIntegrationTest.ResourceB)
    end
  end

  # ── Resources: same table, different domain + keyspace ────────────────────

  defmodule ResourceA do
    use Ash.Resource,
      domain: AshScylla.MultiDomainIntegrationTest.DomainA,
      data_layer: AshScylla.DataLayer

    import AshScylla.DataLayer.Dsl

    scylla do
      repo(AshScylla.TestRepo)
      table("md_users")
      keyspace("ash_scylla_md_a")
      consistency(:one)
    end

    attributes do
      uuid_primary_key(:id)
      attribute(:name, :string, public?: true)
      attribute(:email, :string, public?: true)
      attribute(:score, :integer, public?: true)
    end

    actions do
      defaults([:create, :read, :update, :destroy])
    end
  end

  defmodule ResourceB do
    use Ash.Resource,
      domain: AshScylla.MultiDomainIntegrationTest.DomainB,
      data_layer: AshScylla.DataLayer

    import AshScylla.DataLayer.Dsl

    scylla do
      repo(AshScylla.TestRepo)
      table("md_users")
      keyspace("ash_scylla_md_b")
      consistency(:one)
    end

    attributes do
      uuid_primary_key(:id)
      attribute(:name, :string, public?: true)
      attribute(:email, :string, public?: true)
      attribute(:score, :integer, public?: true)
    end

    actions do
      defaults([:create, :read, :update, :destroy])
    end
  end

  # ── Connection helpers ────────────────────────────────────────────────────

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

  defp create_keyspace(conn, keyspace) do
    Xandra.execute(
      conn,
      "CREATE KEYSPACE IF NOT EXISTS #{keyspace} WITH REPLICATION = {'class': 'NetworkTopologyStrategy', 'replication_factor': 1}"
    )
  end

  defp create_table(conn, keyspace) do
    Xandra.execute(
      conn,
      "CREATE TABLE IF NOT EXISTS #{keyspace}.#{@table} (id UUID PRIMARY KEY, name TEXT, email TEXT, score INT)"
    )
  end

  defp truncate_tables(conn) do
    for ks <- [@keyspace_a, @keyspace_b] do
      Xandra.execute(conn, "TRUNCATE #{ks}.#{@table}")
    end
  end

  defp count_rows(conn, keyspace) do
    {:ok, page} = Xandra.execute(conn, "SELECT COUNT(*) FROM #{keyspace}.#{@table}")
    [[count]] = page.content
    count
  end

  # ── Setup ──────────────────────────────────────────────────────────────────

  setup_all do
    if direct_connect?() do
      host = direct_host()
      port = direct_port()
      conn = connect_with_retry(host, port)

      create_keyspace(conn, @keyspace_a)
      create_keyspace(conn, @keyspace_b)
      create_table(conn, @keyspace_a)
      create_table(conn, @keyspace_b)

      start_test_repo(host, port)

      %{conn: conn}
    else
      case AshScylla.Test.ContainerEngine.ensure_running() do
        :ok ->
          case ScyllaContainer.start(
                 ScyllaContainer.new()
                 |> ScyllaContainer.with_image("scylladb/scylla:5.4")
                 |> ScyllaContainer.with_wait_timeout(120_000)
               ) do
            {:ok, container} ->
              host = ScyllaContainer.host(container)
              port = ScyllaContainer.port(container)
              conn = connect_with_retry(host, port)

              create_keyspace(conn, @keyspace_a)
              create_keyspace(conn, @keyspace_b)
              create_table(conn, @keyspace_a)
              create_table(conn, @keyspace_b)

              start_test_repo(host, port)

              Xandra.stop(conn)

              on_exit(fn ->
                ScyllaContainer.stop(container.container_id)
                AshScylla.Connection.stop(AshScylla.TestRepo)
              end)

              %{conn: nil}

            {:error, reason} ->
              Logger.warning("Failed to start ScyllaDB container: #{inspect(reason)}")
              %{conn: nil}
          end

        {:error, _} ->
          %{conn: nil}
      end
    end
  end

  defp start_test_repo(host, port) do
    case AshScylla.Connection.start_link(
           name: AshScylla.TestRepo,
           nodes: ["#{host}:#{port}"],
           keyspace: @keyspace_a,
           connect_timeout: 15_000
         ) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end
  end

  setup %{conn: conn} do
    if is_nil(conn) do
      Logger.warning("No ScyllaDB connection available — skipping test")
      :ok
    else
      truncate_tables(conn)
      :ok
    end
  end

  defp changeset(attrs), do: %Ash.Changeset{attributes: attrs}

  # ══════════════════════════════════════════════════════════════════════════
  # Multi-domain tests
  # ══════════════════════════════════════════════════════════════════════════

  describe "per-domain query construction" do
    test "resource_to_query/2 qualifies tables with the correct domain keyspace" do
      query_a = DataLayer.resource_to_query(ResourceA, DomainA)
      assert query_a.repo == AshScylla.TestRepo
      assert query_a.table == "#{@keyspace_a}.#{@table}"

      query_b = DataLayer.resource_to_query(ResourceB, DomainB)
      assert query_b.repo == AshScylla.TestRepo
      assert query_b.table == "#{@keyspace_b}.#{@table}"

      refute query_a.table == query_b.table
    end

    test "QueryBuilder CQL targets the correct keyspace per domain" do
      {:ok, {cql_a, _}} =
        ResourceA
        |> DataLayer.resource_to_query(DomainA)
        |> QueryBuilder.build_optimized_query()

      assert cql_a =~ "FROM #{@keyspace_a}.#{@table}"
      refute cql_a =~ @keyspace_b

      {:ok, {cql_b, _}} =
        ResourceB
        |> DataLayer.resource_to_query(DomainB)
        |> QueryBuilder.build_optimized_query()

      assert cql_b =~ "FROM #{@keyspace_b}.#{@table}"
      refute cql_b =~ @keyspace_a
    end
  end

  describe "data isolation across domains" do
    test "data written through one domain is not visible through the other", %{conn: conn} do
      assert {:ok, _record} =
               DataLayer.create(
                 ResourceA,
                 changeset(%{name: "Ada", email: "ada@example.com", score: 10})
               )

      {:ok, rows_a} =
        DataLayer.run_query(DataLayer.resource_to_query(ResourceA, DomainA), ResourceA)

      assert length(rows_a) == 1

      {:ok, rows_b} =
        DataLayer.run_query(DataLayer.resource_to_query(ResourceB, DomainB), ResourceB)

      assert rows_b == []

      # Physically, the row only exists in keyspace A.
      assert count_rows(conn, @keyspace_a) == 1
      assert count_rows(conn, @keyspace_b) == 0
    end

    test "each domain's CRUD is independent", %{conn: conn} do
      assert {:ok, record_a} =
               DataLayer.create(
                 ResourceA,
                 changeset(%{name: "Ada", email: "ada@example.com", score: 10})
               )

      assert {:ok, record_b} =
               DataLayer.create(
                 ResourceB,
                 changeset(%{name: "Bob", email: "bob@example.com", score: 20})
               )

      refute record_a.id == record_b.id

      # Both records exist, each retrievable through its own domain.
      {:ok, rows_a} =
        DataLayer.run_query(DataLayer.resource_to_query(ResourceA, DomainA), ResourceA)

      {:ok, rows_b} =
        DataLayer.run_query(DataLayer.resource_to_query(ResourceB, DomainB), ResourceB)

      assert length(rows_a) == 1
      assert length(rows_b) == 1

      # Destroy through domain B does not touch domain A's data.
      assert :ok = DataLayer.destroy(ResourceB, %Ash.Changeset{attributes: %{id: record_b.id}})

      assert count_rows(conn, @keyspace_b) == 0
      assert count_rows(conn, @keyspace_a) == 1
    end
  end
end
