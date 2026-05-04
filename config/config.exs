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
  sync_connect: 5_000,
  pool_timeout: 5_000,
  queue_target: 50_000,
  queue_interval: 1_000,
  connect_timeout: 5_000,
  request_timeout: 60_000

# ============================================
# Production Configuration Example
# ============================================
# config :my_app, MyApp.Repo,
#   nodes: ["scylla-1:9042", "scylla-2:9042", "scylla-3:9042"],
#   keyspace: "my_app_prod",
#   pool_size: 50,
#   sync_connect: 30_000,
#   pool_timeout: 15_000,
#   queue_target: 100_000,
#   queue_interval: 2_000,
#   connect_timeout: 10_000,
#   request_timeout: 300_000,
#   log: [level: :warning]

# ============================================
# Connection Pool Tuning Guidelines
# ============================================
#
# pool_size:
#   - Development: 5-10 connections per node
#   - Production: 25-100 connections per node (depends on workload)
#   - Formula: pool_size = (expected_concurrent_queries / number_of_nodes) * 1.5
#
# sync_connect:
#   - Time to wait for initial connection to be established
#   - Development: 5_000 (5 seconds)
#   - Production: 30_000 (30 seconds) for slower networks
#
# pool_timeout:
#   - Time to wait for a connection from the pool
#   - Should be less than request_timeout
#   - Recommended: 5_000 - 15_000
#
# queue_target & queue_interval:
#   - Control when the pool should start rejecting connections
#   - queue_target: max microseconds a request should wait in queue
#   - queue_interval: measurement window in milliseconds
#   - Higher values = more lenient, lower values = fail fast
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
