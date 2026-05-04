import Config

# Development configuration for AshScylla
# Use this in config/dev.exs of your application

config :my_app, MyApp.Repo,
  nodes: ["127.0.0.1:9042"],
  keyspace: "my_app_dev",
  pool_size: 5,
  sync_connect: 5_000,
  pool_timeout: 5_000,
  queue_target: 50_000,
  queue_interval: 1_000,
  connect_timeout: 5_000,
  request_timeout: 60_000,
  log: [level: :debug]

# If using Docker for ScyllaDB in development:
# config :my_app, MyApp.Repo,
#   nodes: ["scylladb:9042"],
#   keyspace: "my_app_dev",
#   pool_size: 5,
#   sync_connect: 10_000
