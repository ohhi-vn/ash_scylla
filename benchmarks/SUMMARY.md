# Benchmark Scripts Summary

## Overview

Created comprehensive benchmark scripts for AshScylla to test performance and workload characteristics.

## Files Created

### Main Scripts

1. **`benchmarks/run_benchmarks.exs`** - Main runner that executes all benchmarks
2. **`benchmarks/performance_bench.exs`** - Performance benchmarks for individual operations
3. **`benchmarks/workload_bench.exs`** - Workload benchmarks for concurrency and real-world scenarios
4. **`benchmarks/integration_bench.exs`** - Integration benchmarks with real ScyllaDB
5. **`benchmarks/config.exs`** - Configuration file for benchmark settings
6. **`benchmarks/quick_start.sh`** - Interactive quick start script

### Documentation

7. **`benchmarks/README.md`** - Comprehensive documentation for all benchmarks

### Build Tools

8. **`benchmarks/Makefile`** - Make targets for easy benchmark execution

### Dependencies Added

9. **`mix.exs`** - Added `benchee` and `benchee_html` dependencies

## Benchmark Categories

### Performance Benchmarks
- Single record CRUD operations (insert, read, update, delete)
- Query building with different filter types
- Batch operations (10, 100, 1000 records)
- Secondary index query performance
- Query optimization tests

### Workload Benchmarks
- Concurrent reads (10, 50, 100 concurrent users)
- Concurrent writes (10, 50, 100 concurrent users)
- Mixed workloads (80/20, 50/50 read/write ratios)
- Bulk insert operations (1000, 5000, 10000 records)
- Sequential reads (100, 1000 records)
- Multi-tenant query simulation

### Integration Benchmarks (requires ScyllaDB)
- Real insert operations
- Real read operations by primary key
- Real read with filters
- Real update operations
- Real bulk insert operations

## Quick Start

### Option 1: Interactive Script (Recommended)
```bash
cd ash_scylla
./benchmarks/quick_start.sh
```

### Option 2: Using Make
```bash
cd ash_scylla/benchmarks
make bench-perf        # Performance benchmarks
make bench-workload    # Workload benchmarks
make bench-all         # All benchmarks
```

### Option 3: Direct Execution
```bash
cd ash_scylla
mix deps.get
mix run benchmarks/performance_bench.exs    # Performance only
mix run benchmarks/workload_bench.exs       # Workload only
mix run benchmarks/run_benchmarks.exs       # All benchmarks
```

## Output

All benchmarks generate:
- **Console output** with statistics (average, median, min, max, std_dev)
- **HTML reports** saved to `benchmarks/results/`:
  - `performance.html` - Performance benchmark results
  - `workload.html` - Workload benchmark results
  - `integration.html` - Integration benchmark results (when run)

## Key Features

✓ **No ScyllaDB required** for basic performance/workload benchmarks
✓ **Measures query building performance** (CPU, memory, reductions)
✓ **Concurrent workload simulation** using Elixir Tasks
✓ **Batch operation testing** for throughput measurement
✓ **HTML reports** for visualization
✓ **Configurable** benchmark duration and parameters
✓ **Easy to extend** with custom benchmarks

## Requirements

### For Performance & Workload Benchmarks
- Elixir installed
- `benchee` and `benchee_html` dependencies (added to mix.exs)

### For Integration Benchmarks
- ScyllaDB running on 127.0.0.1:9042
- Keyspace `ash_scylla_bench` created

### Starting ScyllaDB with Docker
```bash
docker run -d --name scylla -p 9042:9042 scylladb/scylla

# Create keyspace
docker exec -it scylla cqlsh -e "CREATE KEYSPACE IF NOT EXISTS ash_scylla_bench WITH replication = {'class': 'SimpleStrategy', 'replication_factor': 1};"
```

## Metrics Measured

- **Execution time** (average, median, min, max, std_dev)
- **Memory usage** (allocated memory during benchmark)
- **Reductions** (Erlang VM work measurement)
- **Throughput** (operations per second for batch operations)

## Notes

- The performance and workload benchmarks measure **query building** performance, not actual database operations
- This is useful for optimizing the AshScylla data layer itself
- For real database performance testing, use the integration benchmarks with a running ScyllaDB instance
- All benchmarks are non-destructive and don't require database cleanup

## Next Steps

1. Run the benchmarks to establish baseline performance
2. Use results to identify optimization opportunities
3. Add custom benchmarks for specific use cases
4. Set up CI/CD performance regression testing using the threshold configuration in `config.exs`
