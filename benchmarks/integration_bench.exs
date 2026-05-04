#!/usr/bin/env elixir

# Integration benchmark script for AshScylla with real ScyllaDB
# Usage: mix run benchmarks/integration_bench.exs
#
# Prerequisites:
# 1. ScyllaDB running on 127.0.0.1:9042
# 2. Keyspace created

Mix.install([
  {:benchee, "~> 1.1"},
  {:benchee_html, "~> 1.0"},
  {:ash_scylla, path: "."}
])

defmodule AshScylla.Benchmarks.Integration do
  @moduledoc """
  Integration benchmarks that connect to a real ScyllaDB instance.
  """

  # Define a test resource
  defmodule TestUser do
    use Ash.Resource,
      data_layer: AshScylla.DataLayer,
      repo: AshScylla.Benchmarks.Integration.Repo

    ash_scylla do
      table "bench_users"
      keyspace "ash_scylla_bench"
      consistency :quorum
      secondary_index :email
      secondary_index :status
    end

    attributes do
      uuid_primary_key :id
      attribute :name, :string
      attribute :email, :string
      attribute :status, :string
      attribute :age, :integer
      attribute :inserted_at, :utc_datetime
    end

    actions do
      defaults [:create, :read, :update, :destroy]
    end
  end

  # Define a repo
  defmodule Repo do
    use AshScylla.Repo,
      otp_app: :ash_scylla

    def init(_type, config) do
      config =
        Keyword.merge(config,
          nodes: ["127.0.0.1:9042"],
          keyspace: "ash_scylla_bench",
          pool_size: 10
        )

      {:ok, config}
    end
  end

  def run do
    # Ensure Repo is started
    case Repo.start_link() do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
      error -> raise "Failed to start Repo: #{inspect(error)}"
    end

    IO.puts("Running integration benchmarks with real ScyllaDB...")

    Benchee.run(
      %{
        "real_insert" => fn -> bench_real_insert() end,
        "real_read_by_pk" => fn -> bench_real_read_by_pk() end,
        "real_read_with_filter" => fn -> bench_real_read_with_filter() end,
        "real_update" => fn -> bench_real_update() end,
        "real_bulk_insert_100" => fn -> bench_real_bulk_insert(100) end,
        "real_bulk_insert_1000" => fn -> bench_real_bulk_insert(1000) end
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
    {:ok, user} =
      TestUser
      |> Ash.Changeset.for_create(:create, %{
        name: "Test User #{:rand.uniform(10000)}",
        email: "test#{:rand.uniform(10000)}@example.com",
        status: "active",
        age: :rand.uniform(80)
      })
      |> Ash.create()

    user
  end

  defp bench_real_read_by_pk do
    # First create a user
    {:ok, user} =
      TestUser
      |> Ash.Changeset.for_create(:create, %{
        name: "Read Test",
        email: "readtest@example.com"
      })
      |> Ash.create()

    # Then read by PK
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
    # First create a user
    {:ok, user} =
      TestUser
      |> Ash.Changeset.for_create(:create, %{
        name: "Update Test",
        email: "updatetest@example.com"
      })
      |> Ash.create()

    # Then update
    user
    |> Ash.Changeset.for_update(:update, %{name: "Updated #{:rand.uniform(10000)}"})
    |> Ash.update()
  end

  defp bench_real_bulk_insert(count) do
    users_data =
      Enum.map(1..count, fn i ->
        %{
          name: "Bulk User #{i}",
          email: "bulk#{i}_#{:rand.uniform(10000)}@example.com",
          status: if(rem(i, 2) == 0, do: "active", else: "inactive"),
          age: 20 + rem(i, 60)
        }
      end)

    TestUser
    |> Ash.bulk_create(users_data, :create)
  end
end

# Run the benchmarks
AshScylla.Benchmarks.Integration.run()
