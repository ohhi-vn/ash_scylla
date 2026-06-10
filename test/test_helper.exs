# Configure Podman socket for testcontainer_ex before any application starts.
# The testcontainer_ex application auto-starts during Mix test setup and needs
# DOCKER_HOST to find the Podman gvproxy socket (Podman machine runs in a VM on macOS).
# We detect the socket from the TMPDIR/podman directory created by podman machine.
case System.get_env("DOCKER_HOST") do
  nil ->
    tmpdir = System.get_env("TMPDIR") || "/tmp"
    podman_dir = Path.join(tmpdir, "podman")

    socket =
      case File.ls(podman_dir) do
        {:ok, entries} ->
          entries
          |> Enum.find(&String.ends_with?(&1, "-api.sock"))
          |> case do
            nil -> nil
            name -> Path.join(podman_dir, name)
          end

        {:error, _} ->
          nil
      end

    if socket != nil and File.exists?(socket) do
      System.put_env("DOCKER_HOST", "unix://#{socket}")
    end

  _ ->
    :ok
end

System.put_env("TESTCONTAINERS_PULL_POLICY", "always")

# Load test support files
Code.require_file("test/support/test_repo.ex")
Code.require_file("test/support/test_resource.ex")
Code.require_file("test/support/test_resource_with_indexes.ex")

ExUnit.start()
