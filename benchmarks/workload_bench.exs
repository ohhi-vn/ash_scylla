# Workload benchmarks for AshScylla
# Simulates real-world workloads and concurrency scenarios

defmodule AshScylla.Benchmarks.Workload do
  @moduledoc """
  Workload benchmarks for AshScylla.

  Simulates:
  - Concurrent read/write workloads
  - Mixed workload patterns (read-heavy, write-heavy)
  - Bulk operations
  - Multi-tenant scenarios
  - Stress testing with high concurrency
  """

  alias AshScylla.DataLayer.QueryBuilder
  alias AshScylla.DataLayer.Batch

  def run do
    Benchee.run(
      %{
        "concurrent_reads_10" => fn -> bench_concurrent_reads(10) end,
        "concurrent_reads_50" => fn -> bench_concurrent_reads(50) end,
        "concurrent_reads_100" => fn -> bench_concurrent_reads(100) end,
        "concurrent_writes_10" => fn -> bench_concurrent_writes(10) end,
        "concurrent_writes_50" => fn -> bench_concurrent_writes(50) end,
        "concurrent_writes_100" => fn -> bench_concurrent_writes(100) end,
        "mixed_workload_50_50" => fn -> bench_mixed_workload(50, 50) end,
        "mixed_workload_80_20" => fn -> bench_mixed_workload(80, 20) end,
        "bulk_insert_1000" => fn -> bench_bulk_insert(1000) end,
        "bulk_insert_5000" => fn -> bench_bulk_insert(5000) end,
        "bulk_insert_10000" => fn -> bench_bulk_insert(10000) end,
        "sequential_reads_100" => fn -> bench_sequential_reads(100) end,
        "sequential_reads_1000" => fn -> bench_sequential_reads(1000) end,
        "multitenant_queries_10" => fn -> bench_multitenant_queries(10) end,
        "multitenant_queries_50" => fn -> bench_multitenant_queries(50) end
      },
      time: 10,
      memory_time: 2,
      reduction_time: 2,
      formatters: [
        Benchee.Formatters.Console,
        {Benchee.Formatters.HTML, file: "benchmarks/results/workload.html"}
      ]
    )
  end

  defp bench_concurrent_reads(concurrency) do
    tasks =
      Enum.map(1..concurrency, fn i ->
        Task.async(fn ->
          QueryBuilder.build_select(Performance.TestResource, [id: "uuid-#{i}"])
        end)
      end)

    Task.await_many(tasks, 30_000)
  end

  defp bench_concurrent_writes(concurrency) do
    tasks =
      Enum.map(1..concurrency, fn i ->
        Task.async(fn ->
          changeset =
            Performance.TestResource
            |> Ash.Changeset.for_create(:create, %{
              name: "User #{i}",
              email: "user#{i}@example.com"
            })

          QueryBuilder.build_insert(Performance.TestResource, changeset)
        end)
      end)

    Task.await_many(tasks, 30_000)
  end

  defp bench_mixed_workload(read_pct, write_pct) do
    total = 100
    reads = round(total * read_pct / 100)
    writes = total - reads

    tasks =
      Enum.map(1..total, fn i ->
        Task.async(fn ->
          if i <= reads do
            QueryBuilder.build_select(Performance.TestResource, [id: "uuid-#{i}"])
          else
            changeset =
              Performance.TestResource
              |> Ash.Changeset.for_create(:create, %{
                name: "User #{i}",
                email: "user#{i}@example.com"
              })

            QueryBuilder.build_insert(Performance.TestResource, changeset)
          end
        end)
      end)

    Task.await_many(tasks, 60_000)
  end

  defp bench_bulk_insert(count) do
    records =
      Enum.map(1..count, fn i ->
        %{
          id: "uuid-#{i}",
          name: "User #{i}",
          email: "user#{i}@example.com",
          status: "active",
          age: 20 + rem(i, 50)
        }
      end)

    Batch.batch_insert(Performance.TestResource, records)
  end

  defp bench_sequential_reads(count) do
    Enum.each(1..count, fn i ->
      QueryBuilder.build_select(Performance.TestResource, [id: "uuid-#{i}"])
    end)
  end

  defp bench_multitenant_queries(tenant_count) do
    tasks =
      Enum.map(1..tenant_count, fn i ->
        Task.async(fn ->
          # Simulate multitenant query with different keyspaces
          QueryBuilder.build_select(Performance.TestResource, [id: "uuid-#{i}"])
        end)
      end)

    Task.await_many(tasks, 30_000)
  end
end
