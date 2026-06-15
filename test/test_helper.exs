# Test environment setup.
# Container engine host (CONTAINER_ENGINE_HOST / DOCKER_HOST) is auto-detected by testcontainer_ex.
# The TESTCONTAINERS_PULL_POLICY is set via .testcontainer_ex.properties.

# Load test support files
Code.require_file("test/support/test_repo.ex")

# ScyllaContainer module is always loaded (pure module, no side effects at load time)
Code.require_file("test/support/scylla_container.ex")

Code.require_file("test/support/container_engine.ex")
Code.require_file("test/support/schema_fixtures.ex")

ExUnit.start()
