import Config

# Configure DOCKER_HOST for testcontainer_ex before it starts.
# This file is loaded at runtime, before applications are started.
# We prefer Podman socket over Colima (which may have a stale socket file).

if Mix.env() == :test do
  docker_host = System.get_env("DOCKER_HOST")

  if is_nil(docker_host) or docker_host == "" do
    # Search Podman socket locations first.
    tmpdir = System.get_env("TMPDIR")
    system_tmp = if tmpdir, do: Path.dirname(tmpdir)

    podman_dir =
      [Path.join(tmpdir || "/tmp", "podman"), system_tmp && Path.join(system_tmp, "podman")]
      |> Enum.reject(&is_nil/1)
      |> Enum.find(fn dir ->
        case File.ls(dir) do
          {:ok, entries} -> Enum.any?(entries, &String.ends_with?(&1, "-api.sock"))
          {:error, _} -> false
        end
      end)

    socket =
      if podman_dir do
        podman_dir
        |> File.ls!()
        |> Enum.find(&String.ends_with?(&1, "-api.sock"))
        |> then(&Path.join(podman_dir, &1))
      else
        Enum.find(
          [
            "/var/run/docker.sock",
            Path.join(System.get_env("HOME"), ".colima/default/docker.sock")
          ],
          &File.exists?/1
        )
      end

    if socket do
      System.put_env("DOCKER_HOST", "unix://#{socket}")
    end
  end
end
