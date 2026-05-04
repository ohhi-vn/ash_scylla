#!/bin/bash

# Quick start script for AshScylla benchmarks

set -e

echo "=== AshScylla Benchmark Quick Start ==="
echo ""

# Check if ScyllaDB is running (for integration benchmarks)
check_scylladb() {
  if nc -z 127.0.0.1 9042 2>/dev/null; then
    echo "✓ ScyllaDB is running on 127.0.0.1:9042"
    return 0
  else
    echo "✗ ScyllaDB is not running on 127.0.0.1:9042"
    return 1
  fi
}

# Install dependencies
echo "Step 1: Installing dependencies..."
mix deps.get

echo ""
echo "Step 2: Choose benchmark type:"
echo "  1) Performance benchmarks (no ScyllaDB required)"
echo "  2) Workload benchmarks (no ScyllaDB required)"
echo "  3) All benchmarks (no ScyllaDB required)"
echo "  4) Integration benchmarks (requires ScyllaDB)"
echo "  5) Exit"
echo ""
read -p "Enter your choice [1-5]: " choice

case $choice in
  1)
    echo ""
    echo "Running performance benchmarks..."
    mix run benchmarks/performance_bench.exs
    ;;
  2)
    echo ""
    echo "Running workload benchmarks..."
    mix run benchmarks/workload_bench.exs
    ;;
  3)
    echo ""
    echo "Running all benchmarks..."
    mix run benchmarks/run_benchmarks.exs
    ;;
  4)
    echo ""
    if check_scylladb; then
      echo "Running integration benchmarks..."
      echo "Note: Make sure you have created the keyspace 'ash_scylla_bench'"
      read -p "Continue? [y/N]: " confirm
      if [[ "$confirm" =~ ^[Yy]$ ]]; then
        mix run benchmarks/integration_bench.exs
      fi
    else
      echo ""
      echo "Please start ScyllaDB first:"
      echo "  docker run -d --name scylla -p 9042:9042 scylladb/scylla"
      echo ""
      echo "Then create the keyspace:"
      echo "  docker exec -it scylla cqlsh -e \"CREATE KEYSPACE IF NOT EXISTS ash_scylla_bench WITH replication = {'class': 'SimpleStrategy', 'replication_factor': 1};\""
    fi
    ;;
  5)
    echo "Exiting."
    exit 0
    ;;
  *)
    echo "Invalid choice."
    exit 1
    ;;
esac

echo ""
echo "=== Benchmarks Complete ==="
echo ""
echo "Results saved to: benchmarks/results/"
echo "Open benchmarks/results/performance.html or workload.html in your browser to view detailed results."
