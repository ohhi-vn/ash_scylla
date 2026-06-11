# Test environment setup.
# Note: DOCKER_HOST is configured in config/test.exs (before testcontainer_ex starts).
# The TESTCONTAINERS_PULL_POLICY is set via .testcontainer_ex.properties.

# Load test support files
Code.require_file("test/support/test_repo.ex")
Code.require_file("test/support/test_resource.ex")
Code.require_file("test/support/test_resource_with_indexes.ex")

ExUnit.start()
