.PHONY: bench bench-perf bench-workload bench-integration bench-integration-container bench-all clean-results help

# Run all benchmarks (performance + workload, no ScyllaDB needed)
bench: bench-all

# Run performance benchmarks only (no ScyllaDB needed)
bench-perf:
	@echo "Running performance benchmarks..."
	@mix run benchmarks/performance_bench.exs

# Run workload benchmarks only (no ScyllaDB needed)
bench-workload:
	@echo "Running workload benchmarks..."
	@mix run benchmarks/workload_bench.exs

# Run integration benchmarks (requires existing ScyllaDB at 127.0.0.1:9042)
bench-integration:
	@echo "Running integration benchmarks (existing ScyllaDB)..."
	@mix run benchmarks/integration_bench.exs

# Run integration benchmarks with a local test container (Podman/Docker)
bench-integration-container:
	@echo "Running integration benchmarks (test container)..."
	@mix run benchmarks/integration_bench.exs --container

# Run all benchmarks (performance + workload, no ScyllaDB)
bench-all:
	@echo "Running all benchmarks..."
	@mix run benchmarks/run_benchmarks.exs

# Run all benchmarks including integration with test container
bench-all-container:
	@echo "Running all benchmarks (with test container integration)..."
	@mix run benchmarks/run_benchmarks.exs --integration --container

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
	@echo "  make bench-perf                 - Run performance benchmarks (no DB needed)"
	@echo "  make bench-workload             - Run workload benchmarks (no DB needed)"
	@echo "  make bench-integration          - Run integration benchmarks (needs ScyllaDB)"
	@echo "  make bench-integration-container - Run integration benchmarks (test container)"
	@echo "  make bench-all                  - Run performance + workload (no DB needed)"
	@echo "  make bench-all-container        - Run all benchmarks (with test container)"
	@echo "  make clean-results              - Clean benchmark results"
	@echo "  make bench-deps                 - Install benchmark dependencies"
