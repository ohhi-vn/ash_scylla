#!/usr/bin/env elixir

# Integration benchmark script for AshScylla with real ScyllaDB
#
# Usage:
#   # Against an existing ScyllaDB instance:
#   mix run benchmarks/integration_bench.exs
#
#   # Spawn a local test container (Podman/Docker required):
#   mix run benchmarks/integration_bench.exs --container
#
#   # Or via the runner:
#   mix run benchmarks/run_benchmarks.exs --integration --container

defmodule AshScylla.Benchmarks.Integration do
  @moduledoc """
  Integration benchmarks that connect to a real ScyllaDB instance.

  Supports two modes:
  1. **Direct** — connects to an existing ScyllaDB at 127.0.0.1:9042
  2. **Container** — spawns a ScyllaDB test container via testcontainer_ex (local-only)
  """

  alias AshScylla.ScyllaContainer

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

  @keyspace "ash_scylla_bench"
  @table "bench_users"

  # ── Public API ──────────────────────────────────────────────────────────

  @doc "Run integration benchmarks against an existing ScyllaDB instance."
  def run do
    repo_config = [
      nodes: ["127.0.0.1:9042"],
      keyspace: @keyspace,
      pool_size: 10
    ]

    start_repo(repo_config)
    ensure_schema()
    do_benchmarks()
  end

  @doc """
  Run integration benchmarks with a local test container.
  Spins up ScyllaDB via testcontainer_ex, runs benchmarks, then tears down.
  """
  def run_with_container do
    IO.puts("Starting ScyllaDB test container...")

    case TestcontainerEx.start_container(@scylla_container_config) do
      {:ok, container} ->
        port = ScyllaContainer.port(container)
        host = TestcontainerEx.get_host(container)
        IO.puts("  ScyllaDB container ready at #{host}:#{port}")

        repo_config = [
          nodes: ["#{host}:#{port}"],
          keyspace: @keyspace,
          pool_size: 10,
          sync_connect: 60_000
        ]

        start_repo(repo_config)
        ensure_bench_keyspace(container)
        ensure_schema()
        do_benchmarks()

        IO.puts("Stopping ScyllaDB test container...")
        TestcontainerEx.stop_container(container.container_id)
        {:ok, :completed}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ── Repo management ─────────────────────────────────────────────────────

  defp start_repo(config) do
    # Stop any existing instance to avoid conflicts
    stop_repo()

    case Repo.start_link(config) do
      {:ok, _} ->
        IO.puts("  Repo started successfully.")
        :ok

      {:error, {:already_started, _}} ->
        IO.puts("  Repo already started.")
        :ok

      error ->
        raise "Failed to start Repo: #{inspect(error)}"
    end
  end

  defp stop_repo do
    try do
      Supervisor.stop(Repo, :normal, 5_000)
    catch
      :exit, _ -> :ok
    end
  end

  # ── Schema ───────────────────────────────────────────────────────────────

  defp ensure_bench_keyspace(container) do
    {:ok, conn} =
      Xandra.start_link(
        nodes: ["#{TestcontainerEx.get_host(container)}:#{ScyllaContainer.port(container)}"]
      )

    Xandra.execute(conn, """
    CREATE KEYSPACE IF NOT EXISTS #{@keyspace}
    WITH REPLICATION = {'class': 'SimpleStrategy', 'replication_factor': 1}
    """)

    Xandra.stop(conn)
  end

  defp ensure_schema do
    {:ok, _} =
      Repo.query("""
      CREATE TABLE IF NOT EXISTS #{@keyspace}.#{@table} (
        id UUID PRIMARY KEY,
        name TEXT,
        email TEXT,
        status TEXT,
        age INT,
        inserted_at TIMESTAMP
      )
      """)

    {:ok, _} =
      Repo.query("""
      CREATE INDEX IF NOT EXISTS idx_bench_email ON #{@keyspace}.#{@table} (email)
      """)

    {:ok, _} =
      Repo.query("""
      CREATE INDEX IF NOT EXISTS idx_bench_status ON #{@keyspace}.#{@table} (status)
      """)
  end

  # ── Benchmarks ───────────────────────────────────────────────────────────

  defp do_benchmarks do
    Benchee.run(
      %{
        "real_insert" => fn -> bench_real_insert() end,
        "real_read_by_pk" => fn -> bench_real_read_by_pk() end,
        "real_read_with_filter" => fn -> bench_real_read_with_filter() end,
        "real_update" => fn -> bench_real_update() end,
        "real_delete" => fn -> bench_real_delete() end,
        "real_bulk_insert_100" => fn -> bench_real_bulk_insert(100) end,
        "real_bulk_insert_500" => fn -> bench_real_bulk_insert(500) end,
        "real_bulk_insert_1000" => fn -> bench_real_bulk_insert(1000) end,
        "real_round_trip" => fn -> bench_real_round_trip() end
      },
      time: 10,
      memory_time: 2,
      formatters: [
        Benchee.Formatters.Console,
        {Benchee.Formatters.HTML, file: "benchmarks/results/integration.html"}
      ]
    )
  end

  defp bench_real_insert do
    {:ok, _user} =
      TestUser
      |> Ash.Changeset.for_create(:create, %{
        name: "Bench User #{:rand.uniform(100_000)}",
        email: "bench#{:rand.uniform(100_000)}@example.com",
        status: "active",
        age: :rand.uniform(80)
      })
      |> Ash.create()
  end

  defp bench_real_read_by_pk do
    {:ok, user} =
      TestUser
      |> Ash.Changeset.for_create(:create, %{
        name: "Read PK Test",
        email: "readpk#{:rand.uniform(100_000)}@example.com"
      })
      |> Ash.create()

    TestUser
    |> Ash.Query.filter(id == user.id)
    |> Ash.read_one()
  end

  defp bench_real_read_with_filter do
    TestUser
    |> Ash.Query.filter(status == "active")
    |> Ash.Query.limit(10)
    |> Ash.read()
  end

  defp bench_real_update do
    {:ok, user} =
      TestUser
      |> Ash.Changeset.for_create(:create, %{
        name: "Update Test",
        email: "update#{:rand.uniform(100_000)}@example.com"
      })
      |> Ash.create()

    user
    |> Ash.Changeset.for_update(:update, %{name: "Updated #{:rand.uniform(100_000)}"})
    |> Ash.update()
  end

  defp bench_real_delete do
    {:ok, user} =
      TestUser
      |> Ash.Changeset.for_create(:create, %{
        name: "Delete Test",
        email: "delete#{:rand.uniform(100_000)}@example.com"
      })
      |> Ash.create()

    Ash.destroy(user)
  end

  defp bench_real_bulk_insert(count) do
    users_data =
      Enum.map(1..count, fn i ->
        %{
          name: "Bulk User #{i}",
          email: "bulk#{i}_#{:rand.uniform(100_000)}@example.com",
          status: if(rem(i, 2) == 0, do: "active", else: "inactive"),
          age: 20 + rem(i, 60)
        }
      end)

    Ash.bulk_create(TestUser, users_data, :create)
  end

  defp bench_real_round_trip do
    # Full round-trip: insert -> read -> update -> read -> delete
    email = "roundtrip#{:rand.uniform(100_000)}@example.com"

    {:ok, user} =
      TestUser
      |> Ash.Changeset.for_create(:create, %{
        name: "Round Trip",
        email: email,
        status: "active",
        age: 25
      })
      |> Ash.create()

    {:ok, read_user} =
      TestUser
      |> Ash.Query.filter(id == user.id)
      |> Ash.read_one()

    {:ok, _updated} =
      read_user
      |> Ash.Changeset.for_update(:update, %{age: 26, status: "updated"})
      |> Ash.update()

    {:ok, _deleted} = Ash.destroy(user)
    :ok
  end

  # ── Test resource & repo (defined inline for self-containment) ───────────

  defmodule TestUser do
    @moduledoc "Benchmark test resource."
    use Ash.Resource,
      data_layer: AshScylla.DataLayer,
      repo: __MODULE__.Repo

    ash_scylla do
      table("bench_users")
      keyspace("ash_scylla_bench")
      consistency(:quorum)
      secondary_index(:email)
      secondary_index(:status)
    end

    attributes do
      uuid_primary_key(:id)
      attribute(:name, :string)
      attribute(:email, :string)
      attribute(:status, :string)
      attribute(:age, :integer)
      attribute(:inserted_at, :utc_datetime)
    end

    actions do
      defaults([:create, :read, :update, :destroy])
    end
  end

  defmodule Repo do
    @moduledoc "Benchmark repo — started dynamically with container or direct config."
    use AshScylla.Repo,
      otp_app: :ash_scylla

    def init(_type, config) do
      {:ok, Keyword.drop(config, [:label])}
    end
  end
end

# ── CLI entry point ────────────────────────────────────────────────────────

{opts, _} =
  OptionParser.parse!(System.argv(),
    strict: [container: :boolean]
  )

if Keyword.get(opts, :container, false) do
  AshScylla.Benchmarks.Integration.run_with_container()
else
  AshScylla.Benchmarks.Integration.run()
end
