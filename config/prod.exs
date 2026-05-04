import Config

# Production configuration for AshScylla
# Use this in config/prod.exs of your application

config :my_app, MyApp.Repo,
  nodes: ["scylla-1:9042", "scylla-2:9042", "scylla-3:9042"],
  keyspace: "my_app_prod",
  pool_size: 50,
  sync_connect: 30_000,
  pool_timeout: 15_000,
  queue_target: 100_000,
  queue_interval: 2_000,
  connect_timeout: 10_000,
  request_timeout: 300_000,
  log: [level: :warning]

# For high-throughput applications, consider:
# - Increasing pool_size to 75-100 if you have many concurrent requests
# - Setting queue_target higher (150_000 - 200_000) for burst tolerance
# - Monitoring pool checkout times and adjusting accordingly
#
# Example for very high load:
# config :my_app, MyApp.Repo,
#   nodes: ["scylla-1:9042", "scylla-2:9042", "scylla-3:9042"],
#   keyspace: "my_app_prod",
#   pool_size: 100,
#   sync_connect: 30_000,
#   pool_timeout: 20_000,
#   queue_target: 200_000,
#   queue_interval: 5_000,
#   connect_timeout: 10_000,
#   request_timeout: 600_000
