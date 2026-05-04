.PHONY: bench bench-perf bench-workload bench-integration bench-all clean-results

# Run all benchmarks
bench: bench-all

# Run performance benchmarks only
bench-perf:
	@echo "Running performance benchmarks..."
	@mix run benchmarks/performance_bench.exs

# Run workload benchmarks only
bench-workload:
	@echo "Running workload benchmarks..."
	@mix run benchmarks/workload_bench.exs

# Run integration benchmarks (requires ScyllaDB)
bench-integration:
	@echo "Running integration benchmarks (requires ScyllaDB)..."
	@mix run benchmarks/integration_bench.exs

# Run all benchmarks
bench-all:
	@echo "Running all benchmarks..."
	@mix run benchmarks/run_benchmarks.exs

# Clean benchmark results
clean-results:
	@echo "Cleaning benchmark results..."
	@rm -rf benchmarks/results/*

# Install benchmark dependencies
bench-deps:
	@mix deps.get

# Help
help:
	@echo "AshScylla Benchmark Commands:"
	@echo "  make bench-perf       - Run performance benchmarks"
	@echo "  make bench-workload   - Run workload benchmarks"
	@echo "  make bench-integration - Run integration benchmarks (needs ScyllaDB)"
	@echo "  make bench-all        - Run all benchmarks"
	@echo "  make clean-results    - Clean benchmark results"
	@echo "  make bench-deps       - Install benchmark dependencies"
