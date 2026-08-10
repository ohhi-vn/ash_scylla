import Config

config :logger, level: :warning

# Test configuration for AshScylla
config :ash_scylla, ash_domains: [AshScylla.TestDomain, AshScylla.SecondTestDomain]

config :ash_scylla, AshScylla.TestRepo,
  nodes: ["127.0.0.1:9051"],
  keyspace: "ash_scylla_test",
  connect_timeout: 5_000

config :ash_scylla, AshScylla.SecondTestRepo,
  nodes: ["127.0.0.1:9052"],
  keyspace: "ash_scylla_second_repo_test",
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
