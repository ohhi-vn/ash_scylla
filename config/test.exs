import Config

config :logger, level: :warning

# Test configuration for AshScylla
config :ash_scylla, ash_domains: [AshScylla.TestDomain]

config :ash_scylla, AshScylla.TestRepo,
  nodes: ["127.0.0.1:9042"],
  keyspace: "ash_scylla_test",
  connect_timeout: 5_000

# For integration tests with testcontainer_ex (see test/scylla_integration_test.exs):
# The configuration is done dynamically in the test setup with:
#
#   repo_config = [
#     nodes: ["#{host}:#{port}"],
#     connect_timeout: 60_000
#   ]
#
#   {:ok, _} = TestRepo.start_link(repo_config)
