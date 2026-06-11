# Workload benchmarks for AshScylla
# Simulates real-world workloads and concurrency scenarios (no database needed)

defmodule AshScylla.Benchmarks.Workload do
  @moduledoc """
  Workload benchmarks for AshScylla.

  Simulates:
  - Concurrent read/write query building
  - Mixed workload patterns (read-heavy, write-heavy)
  - Bulk operations
  - Multi-tenant scenarios
  """

  alias AshScylla.DataLayer
  alias AshScylla.DataLayer.QueryBuilder

  @table "bench_workload"

  def run do
    Benchee.run(
      %{
        "concurrent_reads_10" => fn -> bench_concurrent_reads(10) end,
        "concurrent_reads_50" => fn -> bench_concurrent_reads(50) end,
        "concurrent_reads_100" => fn -> bench_concurrent_reads(100) end,
        "concurrent_writes_10" => fn -> bench_concurrent_writes(10) end,
        "concurrent_writes_50" => fn -> bench_concurrent_writes(50) end,
        "concurrent_writes_100" => fn -> bench_concurrent_writes(100) end,
        "mixed_workload_80_20" => fn -> bench_mixed_workload(80, 20) end,
        "mixed_workload_50_50" => fn -> bench_mixed_workload(50, 50) end,
        "mixed_workload_20_80" => fn -> bench_mixed_workload(20, 80) end,
        "sequential_reads_100" => fn -> bench_sequential_reads(100) end,
        "sequential_reads_1000" => fn -> bench_sequential_reads(1000) end,
        "sequential_writes_100" => fn -> bench_sequential_writes(100) end,
        "sequential_writes_500" => fn -> bench_sequential_writes(500) end,
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

  # ── Concurrent benchmarks ────────────────────────────────────────────────

  defp bench_concurrent_reads(concurrency) do
    tasks =
      Enum.map(1..concurrency, fn i ->
        Task.async(fn ->
          query = %DataLayer{
            resource: nil,
            repo: nil,
            table: @table,
            filters: [%{operator: :eq, left: %{name: :id}, right: %{value: "uuid-#{i}"}}],
            sorts: [],
            limit: nil,
            offset: nil,
            select: nil,
            tenant: nil,
            context: %{}
          }

          QueryBuilder.build_optimized_query(query)
        end)
      end)

    Task.await_many(tasks, 30_000)
  end

  defp bench_concurrent_writes(concurrency) do
    tasks =
      Enum.map(1..concurrency, fn i ->
        Task.async(fn ->
          query = %DataLayer{
            resource: nil,
            repo: nil,
            table: @table,
            filters: [%{operator: :eq, left: %{name: :id}, right: %{value: "uuid-#{i}"}}],
            sorts: [],
            limit: nil,
            offset: nil,
            select: nil,
            tenant: nil,
            context: %{}
          }

          # Simulate write-path query building (INSERT is private, so we benchmark
          # the SELECT that precedes upsert checks, which is the public API)
          QueryBuilder.build_optimized_query(query)
        end)
      end)

    Task.await_many(tasks, 30_000)
  end

  defp bench_mixed_workload(read_pct, _write_pct) do
    total = 100
    reads = round(total * read_pct / 100)

    tasks =
      Enum.map(1..total, fn i ->
        Task.async(fn ->
          if i <= reads do
            query = %DataLayer{
              resource: nil,
              repo: nil,
              table: @table,
              filters: [%{operator: :eq, left: %{name: :id}, right: %{value: "uuid-#{i}"}}],
              sorts: [],
              limit: nil,
              offset: nil,
              select: nil,
              tenant: nil,
              context: %{}
            }

            QueryBuilder.build_optimized_query(query)
          else
            # Simulate write-path: build a SELECT + WHERE filter query
            query = %DataLayer{
              resource: nil,
              repo: nil,
              table: @table,
              filters: [
                %{operator: :eq, left: %{name: :id}, right: %{value: "uuid-#{i}"}},
                %{operator: :eq, left: %{name: :status}, right: %{value: "active"}}
              ],
              sorts: [],
              limit: 1,
              offset: nil,
              select: [:id],
              tenant: nil,
              context: %{}
            }

            QueryBuilder.build_optimized_query(query)
          end
        end)
      end)

    Task.await_many(tasks, 60_000)
  end

  # ── Sequential benchmarks ────────────────────────────────────────────────

  defp bench_sequential_reads(count) do
    Enum.each(1..count, fn i ->
      query = %DataLayer{
        resource: nil,
        repo: nil,
        table: @table,
        filters: [%{operator: :eq, left: %{name: :id}, right: %{value: "uuid-#{i}"}}],
        sorts: [],
        limit: nil,
        offset: nil,
        select: nil,
        tenant: nil,
        context: %{}
      }

      QueryBuilder.build_optimized_query(query)
    end)
  end

  defp bench_sequential_writes(count) do
    Enum.each(1..count, fn i ->
      query = %DataLayer{
        resource: nil,
        repo: nil,
        table: @table,
        filters: [%{operator: :eq, left: %{name: :id}, right: %{value: "uuid-#{i}"}}],
        sorts: [],
        limit: nil,
        offset: nil,
        select: nil,
        tenant: nil,
        context: %{}
      }

      QueryBuilder.build_optimized_query(query)
    end)
  end

  # ── Multi-tenant benchmarks ──────────────────────────────────────────────

  defp bench_multitenant_queries(tenant_count) do
    tasks =
      Enum.map(1..tenant_count, fn i ->
        Task.async(fn ->
          query = %DataLayer{
            resource: nil,
            repo: nil,
            table: @table,
            filters: [
              %{operator: :eq, left: %{name: :tenant_id}, right: %{value: "tenant-#{i}"}},
              %{operator: :eq, left: %{name: :status}, right: %{value: "active"}}
            ],
            sorts: [],
            limit: 100,
            offset: nil,
            select: nil,
            tenant: nil,
            context: %{}
          }

          QueryBuilder.build_optimized_query(query)
        end)
      end)

    Task.await_many(tasks, 30_000)
  end
end
