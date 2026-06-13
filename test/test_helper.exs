# Test environment setup.
# Container engine host (CONTAINER_ENGINE_HOST / DOCKER_HOST) is auto-detected by testcontainer_ex.
# The TESTCONTAINERS_PULL_POLICY is set via .testcontainer_ex.properties.

# Load test support files
Code.require_file("test/support/test_repo.ex")
Code.require_file("test/support/container_engine.ex")
Code.require_file("priv/test_support/scylla_container.ex")

ExUnit.start()
