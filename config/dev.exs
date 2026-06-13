import Config

# Development configuration for AshScylla
# Use this in config/dev.exs of your application

config :my_app, MyApp.Repo,
  nodes: ["127.0.0.1:9042"],
  keyspace: "my_app_dev",
  connect_timeout: 5_000

# If using Podman/Docker for ScyllaDB in development:
# config :my_app, MyApp.Repo,
#   nodes: ["scylladb:9042"],
#   keyspace: "my_app_dev",
#   connect_timeout: 10_000
