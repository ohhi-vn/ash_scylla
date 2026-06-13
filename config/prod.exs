import Config

# Production configuration for AshScylla
# Use this in config/prod.exs of your application

config :my_app, MyApp.Repo,
  nodes: ["scylla-1:9042", "scylla-2:9042", "scylla-3:9042"],
  keyspace: "my_app_prod",
  connect_timeout: 10_000

# For high-throughput applications, consider:
# - Monitoring connection utilization and adjusting accordingly
#
# Example for very high load:
# config :my_app, MyApp.Repo,
#   nodes: ["scylla-1:9042", "scylla-2:9042", "scylla-3:9042"],
#   keyspace: "my_app_prod",
#   connect_timeout: 10_000
