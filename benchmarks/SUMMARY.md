# Benchmark Scripts Summary

## Overview

Comprehensive benchmark scripts for AshScylla with three tiers: performance, workload, and integration.

## Files

| File | Purpose |
|------|---------|
| `run_benchmarks.exs` | Main runner (performance + workload, optional integration) |
| `performance_bench.exs` | Query building benchmarks (no DB needed) |
| `workload_bench.exs` | Concurrent workload benchmarks (no DB needed) |
| `integration_bench.exs` | Real DB benchmarks (supports test container) |
| `config.exs` | Benchmark configuration |
| `quick_start.sh` | Interactive launcher |
| `Makefile` | Make targets |
| `README.md` | Full documentation |

## Benchmark Tiers

### Performance (no database)
- SELECT query building with various filter combinations
- WHERE clause building
- ORDER BY building
- Filter-to-CQL conversion for all operators (eq, gt, gte, lt, in, and, or)

### Workload (no database)
- Concurrent reads/writes at 10, 50, 100 concurrency
- Mixed workloads at 80/20, 50/50, 20/80 read/write ratios
- Sequential reads/writes
- Multi-tenant query patterns

### Integration (real database)
- Real insert, read, update, delete operations
- Bulk insert (100, 500, 1000)
- Full round-trip (insert → read → update → read → delete)
- Supports test container mode for local-only benchmarking

## Test Container Mode

The integration benchmarks can automatically spawn a ScyllaDB container:

```bash
# Standalone
mix run benchmarks/integration_bench.exs --container

# Via runner
mix run benchmarks/run_benchmarks.exs --integration --container

# Via Make
make bench-integration-container
```

This uses `testcontainer_ex` to manage the container lifecycle — no manual setup needed.
