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
  Helper to ensure a container engine is running for test containers.

  Supports Podman (primary) and Apple Container (fallback).

  Provides `ensure_running/0` which:
  1. Checks if the engine is reachable via `TestcontainerEx` resolver.
  2. If not reachable, attempts to start the engine machine.
  3. Retries the connection after restart.
  4. Returns `:ok` if reachable, `{:error, reason}` if not.
  """

  require Logger

  @max_retries 3
  @retry_delay_ms 5_000

  @doc """
  Ensures the container engine is running.

  Returns `:ok` if reachable, or `{:error, reason}` if it
  could not be started after attempting recovery.
  """
  @spec ensure_running() :: :ok | {:error, term()}
  def ensure_running do
    engine = engine_type()
    Logger.info("Container engine detected: #{inspect(engine)}")

    case reachable?() do
      true ->
        Logger.info("Container engine is already running and reachable.")
        :ok

      false ->
        Logger.warning("Container engine not reachable, attempting to start...")
        attempt_start(engine)
    end
  end

  @doc """
  Checks if the container engine is currently reachable.

  Tries `TestcontainerEx.connected?()` first. For Podman on macOS, also checks
  via `podman system connection list` since the socket lives inside the VM.
  """
  @spec reachable?() :: boolean()
  def reachable? do
    ensure_app_started()
    TestcontainerEx.connected?() or podman_reachable?()
  end

  defp ensure_app_started do
    case Application.start(:testcontainer_ex) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
      _ -> :ok
    end
  end

  defp podman_reachable? do
    cond do
      podman_installed?() ->
        # On macOS with Podman machine, the socket is inside the VM.
        # Use `podman info` to check if the engine is actually reachable.
        case System.cmd("podman", ["info", "--format", "{{.Host.Socket}}"],
               stderr_to_stdout: true
             ) do
          {output, 0} ->
            trimmed = String.trim(output)
            trimmed != "" and not String.contains?(trimmed, "cannot connect")

          _ ->
            false
        end

      true ->
        false
    end
  rescue
    _ -> false
  end

  @doc """
  Returns the detected container engine type.

  Podman is the default and preferred engine. The `CONTAINER_ENGINE` environment
  variable can override:
  - `CONTAINER_ENGINE=apple_container` forces Apple Container
  - `CONTAINER_ENGINE=podman` forces Podman (default)
  - Unset or empty auto-detects (Podman first, then Apple Container).

  Returns `:podman`, `:apple_container`, or `nil`.
  """
  @spec engine_type() :: :podman | :apple_container | nil
  def engine_type do
    case System.get_env("CONTAINER_ENGINE") do
      "apple_container" ->
        Logger.info("CONTAINER_ENGINE=apple_container set, selecting Apple Container")
        :apple_container

      _ ->
        # Default to Podman — check it first, then fall back to Apple Container
        auto_detect_engine()
    end
  end

  defp auto_detect_engine do
    cond do
      podman_installed?() -> :podman
      apple_container_installed?() -> :apple_container
      true -> nil
    end
  end

  # --- Start strategies ---

  defp attempt_start(:podman) do
    Logger.info("Selected engine: Podman")
    start_podman()
  end

  defp attempt_start(:apple_container) do
    Logger.info("Selected engine: Apple Container")
    start_apple_container()
  end

  defp attempt_start(nil) do
    Logger.warning("No container engine found. Install Podman or Apple Container.")
    {:error, :no_container_engine}
  end

  # --- Podman ---

  defp podman_installed?, do: not is_nil(System.find_executable("podman"))

  defp start_podman do
    machine = podman_default_machine()

    # Ensure DOCKER_HOST is set so TestcontainerEx can find the Podman socket
    configure_docker_host(machine)

    # Check if the machine is already running before attempting to start
    case podman_machine_running?(machine) do
      true ->
        Logger.info("Podman machine '#{machine}' is already running.")
        wait_for_reachable(@max_retries)

      false ->
        Logger.info("Attempting to start Podman machine '#{machine}'...")

        task =
          Task.async(fn ->
            System.cmd("podman", ["machine", "start", machine], stderr_to_stdout: true)
          end)

        case Task.yield(task, 120_000) || Task.shutdown(task, :brutal_kill) do
          {:ok, {output, 0}} ->
            trimmed = String.trim(output)
            Logger.info("Podman machine '#{machine}' started successfully.")
            Logger.info("Podman machine output: #{trimmed}")
            configure_docker_host(machine)
            wait_for_reachable(@max_retries)

          {:ok, {output, exit_code}} ->
            trimmed = String.trim(output)

            if exit_code == 125 and String.contains?(trimmed, "already running") do
              Logger.info("Podman machine '#{machine}' is already running.")
              wait_for_reachable(@max_retries)
            else
              Logger.error(
                "Failed to start Podman machine '#{machine}' (exit #{exit_code}): #{trimmed}"
              )

              {:error, :podman_start_failed}
            end

          nil ->
            Logger.error("Podman machine '#{machine}' start timed out after 120s")
            {:error, :podman_start_timeout}
        end
    end
  end

  defp configure_docker_host(machine) do
    # If DOCKER_HOST or CONTAINER_ENGINE_HOST is already set, don't override
    if System.get_env("DOCKER_HOST") || System.get_env("CONTAINER_ENGINE_HOST") do
      Logger.info("DOCKER_HOST or CONTAINER_ENGINE_HOST already set, skipping auto-detection.")
      :ok
    else
      # On macOS with Podman machine, the socket path returned by `podman machine inspect`
      # is inside the VM and not directly accessible from the host.
      # Instead, rely on `podman system connection` which sets up the SSH tunnel.
      # TestcontainerEx should be able to connect via the `podman` CLI.
      #
      # If TestcontainerEx still can't connect, users should set DOCKER_HOST manually:
      #   export DOCKER_HOST="unix:///Users/<user>/.local/share/containers/podman/machine/<machine>/podman.sock"
      Logger.info(
        "Using Podman machine '#{machine}'. If TestcontainerEx cannot connect, " <>
          "set DOCKER_HOST or CONTAINER_ENGINE_HOST manually."
      )

      :ok
    end
  end

  defp podman_machine_running?(machine) do
    case System.cmd("podman", ["machine", "list", "--format", "{{.Name}} {{.Running}}"],
           stderr_to_stdout: true
         ) do
      {output, 0} ->
        output
        |> String.split("\n", trim: true)
        |> Enum.any?(fn line ->
          String.starts_with?(line, machine <> " ") and String.contains?(line, "true")
        end)

      _ ->
        false
    end
  rescue
    _ -> false
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
          nil ->
            Logger.info("No Podman machine found, using default name 'podman-machine-default'")
            "podman-machine-default"

          name ->
            trimmed = name |> String.trim() |> String.trim_trailing("*")
            Logger.info("Found Podman machine: '#{trimmed}'")
            trimmed
        end

      {_, exit_code} ->
        Logger.warning("Failed to list Podman machines (exit #{exit_code}), using default name")
        "podman-machine-default"
    end
  end

  # --- Apple Container ---

  defp apple_container_installed?, do: not is_nil(System.find_executable("container"))

  defp start_apple_container do
    Logger.info("Attempting to start Apple Container...")

    task =
      Task.async(fn ->
        System.cmd("container", ["system", "start"], stderr_to_stdout: true)
      end)

    case Task.yield(task, 120_000) || Task.shutdown(task, :brutal_kill) do
      {:ok, {output, 0}} ->
        trimmed = String.trim(output)
        Logger.info("Apple Container started successfully.")
        Logger.info("Apple Container output: #{trimmed}")
        wait_for_reachable(@max_retries)

      {:ok, {output, exit_code}} ->
        trimmed = String.trim(output)
        Logger.error("Failed to start Apple Container (exit #{exit_code}): #{trimmed}")
        {:error, :apple_container_start_failed}

      nil ->
        Logger.error("Apple Container start timed out after 120s")
        {:error, :apple_container_start_timeout}
    end
  end

  # --- Retry loop ---

  defp wait_for_reachable(0) do
    Logger.error("Container engine still not reachable after all start attempts.")
    {:error, :not_reachable_after_restart}
  end

  defp wait_for_reachable(retries) do
    Logger.info("Waiting for container engine to become reachable... (#{retries} retries left)")
    Process.sleep(@retry_delay_ms)

    case reachable?() do
      true ->
        Logger.info("Container engine is now reachable.")
        :ok

      false ->
        Logger.warning("Container engine not yet reachable, retrying... (#{retries - 1} left)")
        wait_for_reachable(retries - 1)
    end
  end
end
