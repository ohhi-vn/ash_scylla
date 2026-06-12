import Config

# Container engine host detection is handled by testcontainer_ex 0.5+.
# It checks CONTAINER_ENGINE_HOST first, then DOCKER_HOST, then scans
# standard socket paths (Podman rootless/rootful, Docker, Colima, etc.).
# See TestcontainerEx.Connection.Strategies for the full resolution chain.
# No custom DOCKER_HOST logic needed here.
