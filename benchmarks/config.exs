# Benchmarks Configuration

# ScyllaDB Connection Settings (for real database benchmarks)
config :ash_scylla_benchmarks,
  scylla_nodes: ["127.0.0.1:9042"],
  keyspace: "ash_scylla_bench",
  pool_size: 10,
  sync_connect: 10_000

# Benchmark Settings
config :ash_scylla_benchmarks,
  benchmark_time: 10,           # seconds for each benchmark
  warmup_time: 2,               # seconds for warmup
  memory_time: 2,               # seconds for memory measurements
  reduction_time: 2,            # seconds for reduction measurements
  parallel: 1,                  # number of parallel benchmark iterations
  format: [:console, :html]     # output formats

# Workload Simulation Settings
config :ash_scylla_benchmarks,
  concurrent_users: [10, 50, 100, 200],
  batch_sizes: [10, 100, 1000, 5000],
  read_write_ratios: [
    {80, 20},  # 80% reads, 20% writes
    {50, 50},  # 50% reads, 50% writes
    {20, 80}   # 20% reads, 80% writes
  ]

# Test Data Settings
config :ash_scylla_benchmarks,
  test_record_count: 10_000,
  test_tenants: 10,
  data_size: :medium  # :small, :medium, :large

# Output Settings
config :ash_scylla_benchmarks,
  results_dir: "benchmarks/results",
  save_raw_data: true,
  generate_plots: true

# Performance Thresholds (for CI/CD)
config :ash_scylla_benchmarks,
  thresholds: %{
    single_insert: %{max_avg: 1.0, max_median: 0.5},  # milliseconds
    single_read: %{max_avg: 0.5, max_median: 0.3},
    batch_insert_1000: %{max_avg: 10.0, max_median: 8.0}
  }
