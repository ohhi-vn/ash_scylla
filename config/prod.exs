import Config

# Production configuration for AshScylla
# Use this in config/prod.exs of your application

config :my_app, MyApp.Repo,
  nodes: ["scylla-1:9042", "scylla-2:9042", "scylla-3:9042"],
  keyspace: "my_app_prod",
  pool_size: 50,
  connect_timeout: 10_000,
  request_timeout: 300_000

# For high-throughput applications, consider:
# - Increasing pool_size to 75-100 if you have many concurrent requests
# - Monitoring pool checkout times and adjusting accordingly
#
# Example for very high load:
# config :my_app, MyApp.Repo,
#   nodes: ["scylla-1:9042", "scylla-2:9042", "scylla-3:9042"],
#   keyspace: "my_app_prod",
#   pool_size: 100,
#   connect_timeout: 10_000,
#   request_timeout: 600_000
