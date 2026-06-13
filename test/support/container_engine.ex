# Copyright [2024] AshScylla Contributors
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

defmodule AshScylla.Test.ContainerEngine do
  @moduledoc """
  Helper to ensure the container engine (Docker/Podman/Colima) is running.

  Provides `ensure_running/0` which:
  1. Checks if the container engine is reachable via `TestcontainerEx` resolver.
  2. If not reachable, attempts to restart it using known strategies:
     - Colima: `colima start`
     - Podman: `podman machine start`
     - Docker: logs a warning (Docker Desktop must be started manually)
  3. Retries the connection after restart.
  4. Returns `:ok` if reachable, `{:error, reason}` if not.
  """

  require Logger

  @max_retries 3
  @retry_delay_ms 5_000

  @doc """
  Ensures the container engine is running.

  Returns `:ok` if the engine is reachable, or `{:error, reason}` if it
  could not be started after attempting recovery.
  """
  @spec ensure_running() :: :ok | {:error, term()}
  def ensure_running do
    case reachable?() do
      true ->
        :ok

      false ->
        Logger.warning("Container engine not reachable, attempting to restart...")
        attempt_restart()
    end
  end

  @doc """
  Checks if the container engine is currently reachable.
  """
  @spec reachable?() :: boolean()
  def reachable? do
    case TestcontainerEx.Connection.Resolver.resolve() do
      {:ok, _url} -> true
      {:error, _} -> false
    end
  end

  # --- Restart strategies ---

  defp attempt_restart do
    cond do
      colima_installed?() ->
        restart_colima()

      podman_installed?() ->
        restart_podman()

      docker_installed?() ->
        Logger.warning(
          "Docker detected but not reachable. Docker Desktop must be started manually."
        )

        {:error, :docker_not_reachable}

      true ->
        Logger.warning("No container engine (Docker/Podman/Colima) found on this system.")
        {:error, :no_container_engine}
    end
  end

  # --- Colima ---

  defp colima_installed?, do: not is_nil(System.find_executable("colima"))

  defp restart_colima do
    Logger.info("Attempting to start Colima...")

    case System.cmd("colima", ["start"], stderr_to_stdout: true, timeout: 120_000) do
      {output, 0} ->
        Logger.info("Colima started successfully: #{String.trim(output)}")
        wait_for_reachable(@max_retries)

      {output, _} ->
        Logger.error("Failed to start Colima: #{String.trim(output)}")
        {:error, :colima_start_failed}
    end
  end

  # --- Podman ---

  defp podman_installed?, do: not is_nil(System.find_executable("podman"))

  defp restart_podman do
    Logger.info("Attempting to start Podman machine...")

    # Try to get the default machine name, fall back to "podman-machine-default"
    machine = podman_default_machine()

    case System.cmd("podman", ["machine", "start", machine],
           stderr_to_stdout: true,
           timeout: 120_000
         ) do
      {output, 0} ->
        Logger.info("Podman machine '#{machine}' started: #{String.trim(output)}")
        wait_for_reachable(@max_retries)

      {output, _} ->
        Logger.error("Failed to start Podman machine '#{machine}': #{String.trim(output)}")
        {:error, :podman_start_failed}
    end
  end

  defp podman_default_machine do
    case System.cmd("podman", ["machine", "list", "--format", "{{.Name}}"],
           stderr_to_stdout: true
         ) do
      {output, 0} ->
        output
        |> String.split("\n", trim: true)
        |> List.first()
        |> case do
          nil -> "podman-machine-default"
          name -> String.trim(name)
        end

      _ ->
        "podman-machine-default"
    end
  end

  # --- Docker ---

  defp docker_installed?, do: not is_nil(System.find_executable("docker"))

  # --- Retry loop ---

  defp wait_for_reachable(0) do
    Logger.error("Container engine still not reachable after restart attempts.")
    {:error, :not_reachable_after_restart}
  end

  defp wait_for_reachable(retries) do
    Process.sleep(@retry_delay_ms)

    case reachable?() do
      true ->
        Logger.info("Container engine is now reachable.")
        :ok

      false ->
        Logger.warning("Container engine not yet reachable, retrying... (#{retries} left)")
        wait_for_reachable(retries - 1)
    end
  end
end
