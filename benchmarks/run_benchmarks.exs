#!/usr/bin/env elixir

# Benchmark runner script for AshScylla
# Usage: mix run benchmarks/run_benchmarks.exs

Mix.install([
  {:benchee, "~> 1.1"},
  {:benchee_html, "~> 1.0"}
])

Code.require_file("performance_bench.exs")
Code.require_file("workload_bench.exs")

alias AshScylla.Benchmarks.Performance
alias AshScylla.Benchmarks.Workload

IO.puts("\n=== AshScylla Benchmark Suite ===\n")

# Run performance benchmarks
IO.puts("Running performance benchmarks...")
Performance.run()

# Run workload benchmarks
IO.puts("\nRunning workload benchmarks...")
Workload.run()

IO.puts("\n=== Benchmarks Complete ===\n")
IO.puts("Results saved to benchmarks/results/")
