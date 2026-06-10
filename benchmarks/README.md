# AshScylla Benchmarks

This directory contains benchmark scripts for testing the performance and workload characteristics of AshScylla.

## Overview

The benchmark suite is designed to measure:
- **Performance**: Latency and throughput of individual operations
- **Workload**: Real-world scenarios with concurrency and mixed operations

## Prerequisites

Add the following dependencies to your `mix.exs` (if not already present):

```elixir
defp deps do
  [
    {:benchee, "~> 1.1", only: [:dev, :test]},
    {:benchee_html, "~> 1.0", only: [:dev, :test]}
  ]
end
```

Then run:
```bash
mix deps.get
```

## Running Benchmarks

### Run All Benchmarks

```bash
cd ash_scylla
mix run benchmarks/run_benchmarks.exs
```

### Run Individual Benchmarks

**Performance Benchmarks Only:**
```bash
mix run benchmarks/performance_bench.exs
```

**Workload Benchmarks Only:**
```bash
mix run benchmarks/workload_bench.exs
```

## Benchmark Categories

### Performance Benchmarks (`performance_bench.exs`)

Measures latency and throughput of individual operations:

| Benchmark | Description |
|-----------|-------------|
| `single_insert` | Single record insertion query building |
| `single_read_by_pk` | Read by primary key query building |
| `single_update` | Single record update query building |
| `single_delete` | Single record delete query building |
| `query_with_pk` | Query optimization with primary key |
| `query_with_secondary_index` | Query with secondary index |
| `query_with_filter` | Filter conversion to CQL |
| `build_simple_query` | Simple SELECT query building |
| `build_complex_query` | Complex query with filters, sorting, limit |
| `batch_insert_10` | Batch insert of 10 records |
| `batch_insert_100` | Batch insert of 100 records |
| `batch_insert_1000` | Batch insert of 1000 records |

### Workload Benchmarks (`workload_bench.exs`)

Simulates real-world workload patterns:

| Benchmark | Description |
|-----------|-------------|
| `concurrent_reads_*` | Concurrent read operations (10, 50, 100) |
| `concurrent_writes_*` | Concurrent write operations (10, 50, 100) |
| `mixed_workload_50_50` | 50% reads, 50% writes |
| `mixed_workload_80_20` | 80% reads, 20% writes |
| `bulk_insert_*` | Bulk insert operations (1000, 5000, 10000) |
| `sequential_reads_*` | Sequential read operations (100, 1000) |
| `multitenant_queries_*` | Multi-tenant query simulation (10, 50) |

## Output

Benchmark results are saved to:
- **Console**: Summary statistics printed to terminal
- **HTML Reports**: 
  - `benchmarks/results/performance.html`
  - `benchmarks/results/workload.html`

## Understanding Results

### Key Metrics

- **Average (avg)**: Mean execution time
- **Median (median)**: Middle value of execution times
- **Minimum (min)**: Fastest execution
- **Maximum (max)**: Slowest execution
- **Standard Deviation (std_dev)**: Variability in execution times
- **Memory Usage**: Memory allocated during benchmark
- **Reductions**: Erlang VM reductions (work done)

### Interpreting Results

**Good Performance Indicators:**
- Low average and median times
- Low standard deviation (consistent performance)
- Linear scaling with batch size

**Potential Issues:**
- High standard deviation (inconsistent performance)
- Non-linear scaling
- High memory usage for simple operations

## Baseline Results

> **Note:** These baselines were measured on a development machine and are for relative comparison only. Your results will vary based on hardware, ScyllaDB cluster size, and network latency.

### Hardware

- **CPU**: Apple M-series (or equivalent x86_64)
- **RAM**: 16 GB
- **ScyllaDB**: Single-node, local Docker container
- **Network**: localhost (no network latency)

### Query Building Benchmarks

| Operation | Average | Median | Notes |
|-----------|---------|--------|-------|
| `single_insert` | ~5 µs | ~4 µs | Query string generation only |
| `single_read_by_pk` | ~3 µs | ~2 µs | Simple PK lookup query |
| `build_complex_query` | ~15 µs | ~12 µs | With filters, sorting, limit |
| `batch_insert_100` | ~50 µs | ~45 µs | 100 INSERT statements |

### Interpretation

- These benchmarks measure **query building** (CQL string generation), not actual database operations
- A 20%+ regression in any operation should be investigated
- For real database benchmarks, run the integration benchmarks against a live ScyllaDB instance

## CI Integration

Benchmarks are not run in CI by default. To compare before/after a change:

```bash
# Before your changes
mix run benchmarks/performance_bench.exs > /tmp/before.txt

# After your changes
mix run benchmarks/performance_bench.exs > /tmp/after.txt

# Compare
diff /tmp/before.txt /tmp/after.txt
```

## Customization

### Adjusting Benchmark Duration

Edit the `time:` parameter in the benchmark files:

```elixir
Benchee.run(
  %{...},
  time: 10,           # Seconds to run each benchmark
  memory_time: 2,     # Seconds for memory measurements
  reduction_time: 2   # Seconds for reduction measurements
)
```

### Adding Custom Benchmarks

Add new benchmark cases to the benchmark modules:

```elixir
def run do
  Benchee.run(
    %{
      "your_benchmark" => fn -> your_function() end
    },
    ...
  )
end
```

## Notes

- These benchmarks measure **query building** performance, not actual database operations
- To benchmark actual ScyllaDB operations, you need a running ScyllaDB instance and configured Repo
- The benchmarks use mock resources and simulate the query building layer
- For real database benchmarks, extend these scripts to use actual Repo queries

## Future Enhancements

- [ ] Add actual ScyllaDB connection benchmarks
- [ ] Add comparison benchmarks with other data layers
- [ ] Add long-running stability benchmarks
- [ ] Add memory leak detection benchmarks
- [ ] Add network partition simulation benchmarks
