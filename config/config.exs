import Config

# This file contains configuration examples for AshScylla with connection pool tuning.
# Copy the appropriate configuration to your app's config/config.exs

# AshScylla.DataLayer doubles as the Ash extension, so `mix ash.codegen` and
# `mix ash.migrate` discover it automatically. If your Ash version does not
# auto-discover the data layer as an extension, register it explicitly here:
#
#     config :ash, extensions: [AshScylla.Extension]

# (No explicit registration is required for current Ash versions — the data
# layer module is discovered via the Spark.Dsl.Extension behaviour.)

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
