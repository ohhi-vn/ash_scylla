#!/usr/bin/env elixir

# Benchmark runner script for AshScylla
# Usage:
#   mix run benchmarks/run_benchmarks.exs                    # performance + workload
#   mix run benchmarks/run_benchmarks.exs --integration      # also run integration (needs ScyllaDB)
#   mix run benchmarks/run_benchmarks.exs --integration --container  # spawn test container (Podman) for integration

benchmark_dir = Path.dirname(__ENV__.file)
Code.require_file(Path.join(benchmark_dir, "performance_bench.exs"))
Code.require_file(Path.join(benchmark_dir, "workload_bench.exs"))

alias AshScylla.Benchmarks.Performance
alias AshScylla.Benchmarks.Workload

{opts, _} =
  OptionParser.parse!(System.argv(),
    strict: [integration: :boolean, container: :boolean]
  )

run_integration = Keyword.get(opts, :integration, false)
run_container = Keyword.get(opts, :container, false)

IO.puts("\n=== AshScylla Benchmark Suite ===\n")

# Run performance benchmarks
IO.puts("Running performance benchmarks...")
Performance.run()

# Run workload benchmarks
IO.puts("\nRunning workload benchmarks...")
Workload.run()

# Run integration benchmarks if requested
if run_integration do
  IO.puts("\nRunning integration benchmarks...")

  if run_container do
    IO.puts("  (using testcontainer_ex via Podman for local ScyllaDB)")
    Code.require_file(Path.join(benchmark_dir, "integration_bench.exs"))

    case AshScylla.Benchmarks.Integration.run_with_container() do
      {:ok, _} ->
        IO.puts("  Integration benchmarks complete.")

      {:error, reason} ->
        IO.puts("  WARNING: Failed to start test container: #{inspect(reason)}")
        IO.puts("  Skipping integration benchmarks.")
    end
  else
    IO.puts("  (using existing ScyllaDB at 127.0.0.1:9042)")
    Code.require_file(Path.join(benchmark_dir, "integration_bench.exs"))
    AshScylla.Benchmarks.Integration.run()
  end
end

IO.puts("\n=== Benchmarks Complete ===\n")
IO.puts("Results saved to benchmarks/results/")
