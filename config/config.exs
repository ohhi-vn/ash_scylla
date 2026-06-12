import Config

# This file contains configuration examples for AshScylla with connection pool tuning.
# Copy the appropriate configuration to your app's config/config.exs

# ============================================
# Basic Development Configuration
# ============================================
config :ash_scylla, AshScylla.TestRepo,
  nodes: ["127.0.0.1:9042"],
  keyspace: "ash_scylla_dev",
  pool_size: 5,
  connect_timeout: 5_000,
  request_timeout: 60_000

# ============================================
# Production Configuration Example
# ============================================
# config :my_app, MyApp.Repo,
#   nodes: ["scylla-1:9042", "scylla-2:9042", "scylla-3:9042"],
#   keyspace: "my_app_prod",
#   pool_size: 50,
#   connect_timeout: 10_000,
#   request_timeout: 300_000

# ============================================
# Connection Pool Tuning Guidelines
# ============================================
#
# pool_size:
#   - Development: 5-10 connections per node
#   - Production: 25-100 connections per node (depends on workload)
#   - Formula: pool_size = (expected_concurrent_queries / number_of_nodes) * 1.5
#
# connect_timeout:
#   - TCP connection timeout
#   - Usually 5_000 - 10_000 milliseconds
#
# request_timeout:
#   - Query execution timeout
#   - Simple queries: 60_000 (1 minute)
#   - Complex queries: 300_000 (5 minutes)
#   - Batch operations: 600_000 (10 minutes)
