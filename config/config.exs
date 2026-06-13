import Config

# This file contains configuration examples for AshScylla with connection pool tuning.
# Copy the appropriate configuration to your app's config/config.exs

# ============================================
# Basic Development Configuration
# ============================================
config :ash_scylla, AshScylla.TestRepo,
  nodes: ["127.0.0.1:9042"],
  keyspace: "ash_scylla_dev",
  connect_timeout: 5_000

# ============================================
# Production Configuration Example
# ============================================
# config :my_app, MyApp.Repo,
#   nodes: ["scylla-1:9042", "scylla-2:9042", "scylla-3:9042"],
#   keyspace: "my_app_prod",
#   connect_timeout: 10_000

# ============================================
# Connection Tuning Guidelines
# ============================================
#
# connect_timeout:
#   - TCP connection timeout
#   - Usually 5_000 - 10_000 milliseconds
