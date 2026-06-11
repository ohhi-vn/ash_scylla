import Config

# Test configuration for AshScylla

config :my_app, MyApp.Repo,
  nodes: ["127.0.0.1:9042"],
  keyspace: "my_app_test",
  pool_size: 3,
  sync_connect: 10_000,
  pool_timeout: 10_000,
  queue_target: 50_000,
  queue_interval: 1_000,
  connect_timeout: 5_000,
  request_timeout: 120_000

# For integration tests with testcontainer_ex (see test/scylla_integration_test.exs):
# The configuration is done dynamically in the test setup with:
#
#   repo_config = [
#     nodes: ["#{host}:#{port}"],
#     pool_size: 5,
#     sync_connect: 60_000
#   ]
#
#   {:ok, _} = TestRepo.start_link(repo_config)
