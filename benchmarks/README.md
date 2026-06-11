# AshScylla Benchmarks

This directory contains benchmark scripts for testing the performance and workload characteristics of AshScylla.

## Overview

The benchmark suite has three tiers:

| Tier | What it measures | Needs ScyllaDB? |
|------|----------------|----------------|
| **Performance** | Query building latency (CQL generation) | No |
| **Workload** | Concurrent query building, mixed patterns | No |
| **Integration** | Real database CRUD round-trips | Yes (or test container) |

## Quick Start

### Performance + Workload (no database needed)

```bash
# Using Make
make bench-perf        # Performance only
make bench-workload    # Workload only
make bench-all        # Both

# Direct
mix run benchmarks/performance_bench.exs
mix run benchmarks/workload_bench.exs
mix run benchmarks/run_benchmarks.exs
```

### Integration (with test container — Docker/Podman)

```bash
# Spawn a ScyllaDB container, run benchmarks, tear down
make bench-integration-container

# Or directly
mix run benchmarks/integration_bench.exs --container

# Via the runner (performance + workload + integration)
mix run benchmarks/run_benchmarks.exs --integration --container
```

### Integration (against existing ScyllaDB)

```bash
# Requires ScyllaDB running at 127.0.0.1:9042 with keyspace 'ash_scylla_bench'
make bench-integration
```

### Interactive

```bash
./benchmarks/quick_start.sh
```

## Performance Benchmarks

Measures the CPU cost of CQL query building — no database required.

| Benchmark | Description |
|-----------|-------------|
| `build_select_all` | Simple SELECT with no filters |
| `build_select_with_pk_filter` | SELECT with primary key equality |
| `build_select_with_secondary_index` | SELECT with secondary index filter |
| `build_select_with_multiple_filters` | SELECT with multiple WHERE clauses |
| `build_select_with_sort_and_limit` | SELECT with ORDER BY and LIMIT |
| `build_insert` | INSERT statement generation |
| `build_update` | UPDATE statement generation |
| `build_delete` | DELETE statement generation |
| `build_complex_query` | Multi-filter + sort + limit + select |
| `filter_to_cql_eq/gt/in/and/or` | Individual filter operator conversion |

## Workload Benchmarks

Simulates concurrent query building patterns — no database required.

| Benchmark | Description |
|-----------|-------------|
| `concurrent_reads_*` | Concurrent SELECT building (10, 50, 100) |
| `concurrent_writes_*` | Concurrent INSERT building (10, 50, 100) |
| `mixed_workload_*` | Mixed read/write ratios (80/20, 50/50, 20/80) |
| `sequential_reads_*` | Sequential SELECT building (100, 1000) |
| `sequential_writes_*` | Sequential INSERT building (100, 500) |
| `multitenant_queries_*` | Multi-tenant filter patterns (10, 50) |

## Integration Benchmarks

Real database operations against ScyllaDB.

| Benchmark | Description |
|-----------|-------------|
| `real_insert` | Insert a single record |
| `real_read_by_pk` | Insert + read by primary key |
| `real_read_with_filter` | Filter by secondary index + LIMIT |
| `real_update` | Insert + update |
| `real_delete` | Insert + delete |
| `real_bulk_insert_*` | Bulk insert (100, 500, 1000) |
| `real_round_trip` | Full insert → read → update → read → delete |

## Test Container Mode

The integration benchmarks support an optional **test container** mode that automatically:

1. Spins up a ScyllaDB container via `testcontainer_ex`
2. Creates the keyspace and schema
3. Runs all integration benchmarks
4. Tears down the container

This is ideal for local development — no manual ScyllaDB setup required.

```bash
# Just needs Docker or Podman running
mix run benchmarks/integration_bench.exs --container
```

## Output

- **Console**: Summary statistics (average, median, min, max, std_dev)
- **HTML Reports**: `benchmarks/results/*.html`

## Configuration

Edit `benchmarks/config.exs` to adjust:

- Benchmark duration (`time`, `warmup_time`)
- Concurrency levels
- Batch sizes
- Output directory

## Adding Custom Benchmarks

```elixir
def run do
  Benchee.run(
    %{
      "my_benchmark" -> fn -> my_function() end
    },
    time: 10,
    memory_time: 2,
    formatters: [
      Benchee.Formatters.Console,
      {Benchee.Formatters.HTML, file: "benchmarks/results/my_bench.html"}
    ]
  )
end
```
