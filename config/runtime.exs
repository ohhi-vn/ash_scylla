import Config

# Container engine host detection is handled by testcontainer_ex 0.6+.
# It checks CONTAINER_ENGINE_HOST first, then scans Podman socket paths
# (rootless: unix:///run/user/$UID/podman/podman.sock, rootful: unix:///run/podman/podman.sock).
#
# You can also explicitly select an engine via the :engine option or CONTAINER_ENGINE env var:
#   CONTAINER_ENGINE=podman mix test

# When CONTAINER_ENGINE=podman is set, detect the Podman socket and expose it
# via DOCKER_HOST so testcontainer_ex uses the Env strategy (under :auto detection)
# instead of the Socket strategy (which may pick up Colima's socket first).
if Mix.env() in [:test, :dev] do
  engine = System.get_env("CONTAINER_ENGINE", "")

  if engine == "podman" and
       !(System.get_env("CONTAINER_ENGINE_HOST") || System.get_env("DOCKER_HOST")) do
    podman_socket =
      case System.cmd("podman", [
             "machine",
             "inspect",
             "--format",
             "{{.ConnectionInfo.PodmanSocket.Path}}"
           ]) do
        {output, 0} ->
          path = String.trim(output)

          if path != "" and File.exists?(path) do
            path
          else
            # Fallback: check the ~/.podman/ symlink/socket
            home = System.get_env("HOME")
            candidate = Path.join(home, ".podman/podman-machine-default-api.sock")

            if File.exists?(candidate) do
              candidate
            else
              nil
            end
          end

        _ ->
          nil
      end

    if podman_socket do
      System.put_env("DOCKER_HOST", "unix://#{podman_socket}")
      # Remove CONTAINER_ENGINE so testcontainer_ex uses :auto detection,
      # which includes the Env strategy (respects DOCKER_HOST).
      System.delete_env("CONTAINER_ENGINE")
    end
  end
end
