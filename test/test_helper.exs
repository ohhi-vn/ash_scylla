# Test environment setup.
# Container engine host (CONTAINER_ENGINE_HOST / DOCKER_HOST) is auto-detected by testcontainer_ex.
# The TESTCONTAINERS_PULL_POLICY is set via .testcontainer_ex.properties.

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

# ScyllaContainer module is always loaded (pure module, no side effects at load time)
Code.require_file("test/support/scylla_container.ex")

Code.require_file("test/support/container_engine.ex")
Code.require_file("test/support/schema_fixtures.ex")

# Load test resource definitions (must be before ExUnit.start so protocols are consolidated)
Code.require_file("test/support/test_resource.ex")
Code.require_file("test/support/test_resource_with_indexes.ex")
Code.require_file("test/support/test_domain.ex")

ExUnit.start()
