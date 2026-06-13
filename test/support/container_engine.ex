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
  Helper to ensure Podman is running for test containers.

  Provides `ensure_running/0` which:
  1. Checks if Podman is reachable via `TestcontainerEx` resolver.
  2. If not reachable, attempts to start the Podman machine.
  3. Retries the connection after restart.
  4. Returns `:ok` if reachable, `{:error, reason}` if not.
  """

  require Logger

  @max_retries 3
  @retry_delay_ms 5_000

  @doc """
  Ensures Podman is running.

  Returns `:ok` if reachable, or `{:error, reason}` if it
  could not be started after attempting recovery.
  """
  @spec ensure_running() :: :ok | {:error, term()}
  def ensure_running do
    case reachable?() do
      true ->
        :ok

      false ->
        Logger.warning("Podman not reachable, attempting to start machine...")
        attempt_start()
    end
  end

  @doc """
  Checks if Podman is currently reachable.
  """
  @spec reachable?() :: boolean()
  def reachable? do
    TestcontainerEx.connected?()
  end

  # --- Start strategies ---

  defp attempt_start do
    cond do
      podman_installed?() ->
        start_podman()

      true ->
        Logger.warning("Podman not found on this system.")
        {:error, :no_container_engine}
    end
  end

  # --- Podman ---

  defp podman_installed?, do: not is_nil(System.find_executable("podman"))

  defp start_podman do
    Logger.info("Attempting to start Podman machine...")

    machine = podman_default_machine()

    task =
      Task.async(fn ->
        System.cmd("podman", ["machine", "start", machine], stderr_to_stdout: true)
      end)

    case Task.yield(task, 120_000) || Task.shutdown(task, :brutal_kill) do
      {:ok, {output, 0}} ->
        Logger.info("Podman machine '#{machine}' started: #{String.trim(output)}")
        wait_for_reachable(@max_retries)

      {:ok, {output, _}} ->
        Logger.error("Failed to start Podman machine '#{machine}': #{String.trim(output)}")
        {:error, :podman_start_failed}

      nil ->
        Logger.error("Podman machine start timed out after 120s")
        {:error, :podman_start_timeout}
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
          name -> name |> String.trim() |> String.trim_trailing("*")
        end

      _ ->
        "podman-machine-default"
    end
  end

  # --- Retry loop ---

  defp wait_for_reachable(0) do
    Logger.error("Podman still not reachable after start attempts.")
    {:error, :not_reachable_after_restart}
  end

  defp wait_for_reachable(retries) do
    Process.sleep(@retry_delay_ms)

    case reachable?() do
      true ->
        Logger.info("Podman is now reachable.")
        :ok

      false ->
        Logger.warning("Podman not yet reachable, retrying... (#{retries} left)")
        wait_for_reachable(retries - 1)
    end
  end
end
