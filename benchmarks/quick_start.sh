#!/bin/bash

# Quick start script for AshScylla benchmarks

set -e

echo "=== AshScylla Benchmark Quick Start ==="
echo ""

# Install dependencies
echo "Step 1: Installing dependencies..."
mix deps.get

echo ""
echo "Step 2: Choose benchmark type:"
echo "  1) Performance benchmarks (no ScyllaDB required)"
echo "  2) Workload benchmarks (no ScyllaDB required)"
echo "  3) All benchmarks (no ScyllaDB required)"
echo "  4) Integration benchmarks (requires existing ScyllaDB at 127.0.0.1:9042)"
echo "  5) Integration benchmarks with test container (Podman/Docker)"
echo "  6) All benchmarks with test container"
echo "  7) Exit"
echo ""
read -p "Enter your choice [1-7]: " choice

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
    echo "Running integration benchmarks against existing ScyllaDB..."
    mix run benchmarks/integration_bench.exs
    ;;
  5)
    echo ""
    echo "Running integration benchmarks with test container..."
    mix run benchmarks/integration_bench.exs --container
    ;;
  6)
    echo ""
    echo "Running all benchmarks with test container..."
    mix run benchmarks/run_benchmarks.exs --integration --container
    ;;
  7)
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
echo "Open benchmarks/results/*.html in your browser to view detailed results."
