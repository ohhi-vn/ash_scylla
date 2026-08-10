# Test environment setup.
# Container engine host (CONTAINER_ENGINE_HOST / DOCKER_HOST) is auto-detected by testcontainer_ex.
# The TESTCONTAINERS_PULL_POLICY is set via .testcontainer_ex.properties.

# config/test.exs is not auto-loaded by Mix (config/config.exs does not import
# per-environment configs), so register the multi-domain test configuration
# here so domain discovery and repo-level keyspace resolution are deterministic.
Application.put_env(:ash_scylla, :ash_domains, [
  AshScylla.TestDomain,
  AshScylla.SecondTestDomain
])

Application.put_env(:ash_scylla, AshScylla.SecondTestRepo,
  nodes: ["127.0.0.1:9052"],
  keyspace: "ash_scylla_second_repo_test",
  connect_timeout: 5_000
)

# Ensure the repo cache ETS table exists (created by Application in production)
# Tests that don't start the app need this to exist.
case :ets.info(:ash_scylla_repo_cache) do
  :undefined ->
    :ets.new(:ash_scylla_repo_cache, [:set, :public, :named_table, read_concurrency: true])

  _ ->
    :ok
end

# Load test support files
Code.require_file("test/support/test_repo.ex")
Code.require_file("test/support/second_test_repo.ex")

# ScyllaContainer module is always loaded (pure module, no side effects at load time)
Code.require_file("test/support/scylla_container.ex")

Code.require_file("test/support/container_engine.ex")
Code.require_file("test/support/schema_fixtures.ex")

# Load test resource definitions (must be before ExUnit.start so protocols are consolidated)
Code.require_file("test/support/test_resource.ex")
Code.require_file("test/support/test_resource_with_indexes.ex")
Code.require_file("test/support/test_resource_composite_pk.ex")
Code.require_file("test/support/test_domain.ex")
Code.require_file("test/support/second_test_domain_resource.ex")
Code.require_file("test/support/second_test_domain_repo_backed_resource.ex")
Code.require_file("test/support/second_test_domain.ex")

ExUnit.start(max_cases: 4)
