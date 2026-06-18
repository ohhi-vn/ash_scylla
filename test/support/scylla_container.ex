defmodule AshScylla.ScyllaContainer do
  @moduledoc """
  Shim module that provides a ScyllaDB container configuration over the
  testcontainer_ex 0.7 backend.

  Uses the built-in `TestcontainerEx.ScyllaContainer` (which uses `nodetool status`
  to wait for readiness) with random container names to avoid conflicts.

  > Uses `TestcontainerEx` 0.7+ (`start_container/1`, `stop_container/2`, `get_host/1`, `get_port/2`).
  """

  require Logger

  alias TestcontainerEx.Container.Config

  @default_cql_port 9042

  @doc """
  Creates a new ScyllaDB container configuration with a random name.
  Delegates to `TestcontainerEx.ScyllaContainer.new/0`.
  """
  @spec new() :: TestcontainerEx.ScyllaContainer.t()
  def new do
    name = random_container_name()

    Logger.info(
      "ScyllaDB container config: name='#{name}', image='#{TestcontainerEx.ScyllaContainer.default_image()}', exposed_port=#{@default_cql_port}"
    )

    TestcontainerEx.ScyllaContainer.new()
    |> with_name(name)
  end

  @doc """
  Sets the container image.
  """
  @spec with_image(TestcontainerEx.ScyllaContainer.t(), String.t()) ::
          TestcontainerEx.ScyllaContainer.t()
  def with_image(%TestcontainerEx.ScyllaContainer{} = config, image) when is_binary(image) do
    Logger.info("ScyllaDB container image set to: #{image}")
    TestcontainerEx.ScyllaContainer.with_image(config, image)
  end

  @doc """
  Sets the container command.
  """
  @spec with_cmd(TestcontainerEx.ScyllaContainer.t(), [String.t()]) ::
          TestcontainerEx.ScyllaContainer.t()
  def with_cmd(%TestcontainerEx.ScyllaContainer{} = config, cmd) when is_list(cmd) do
    Logger.info("ScyllaDB container cmd: #{inspect(cmd)}")
    Map.put(config, :cmd_override, cmd)
  end

  @doc """
  Sets the wait timeout in milliseconds.
  """
  @spec with_wait_timeout(TestcontainerEx.ScyllaContainer.t(), pos_integer()) ::
          TestcontainerEx.ScyllaContainer.t()
  def with_wait_timeout(%TestcontainerEx.ScyllaContainer{} = config, timeout)
      when is_integer(timeout) and timeout > 0 do
    Logger.info("ScyllaDB container wait timeout: #{timeout}ms")
    TestcontainerEx.ScyllaContainer.with_wait_timeout(config, timeout)
  end

  @doc """
  Sets the container name.
  """
  @spec with_name(TestcontainerEx.ScyllaContainer.t(), String.t()) ::
          TestcontainerEx.ScyllaContainer.t()
  def with_name(%TestcontainerEx.ScyllaContainer{} = config, name) when is_binary(name) do
    Map.put(config, :container_name, name)
  end

  @doc """
  Returns the mapped host port for the CQL port (9042) from a started
  container (Config struct).
  """
  @spec port(Config.t()) :: integer() | nil
  def port(%Config{} = container) do
    TestcontainerEx.get_port(container, @default_cql_port)
  end

  @doc """
  Convenience: starts the container with `TestcontainerEx.start_container/1`.
  """
  @spec start(TestcontainerEx.ScyllaContainer.t(), atom()) ::
          {:ok, Config.t()} | {:error, term()}
  def start(config, _name \\ :default) do
    container_name = Map.get(config, :container_name) || "unnamed"
    Logger.info("Starting ScyllaDB container '#{container_name}'...")

    {elapsed, result} =
      :timer.tc(fn ->
        TestcontainerEx.start_container(config)
      end)

    case result do
      {:ok, started} ->
        host_port = port(started)

        Logger.info(
          "ScyllaDB container '#{container_name}' started in #{div(elapsed, 1000)}ms, host_port=#{host_port}, id=#{started.container_id}"
        )

        {:ok, started}

      {:error, reason} ->
        Logger.error(
          "ScyllaDB container '#{container_name}' failed after #{div(elapsed, 1000)}ms: #{inspect(reason)}"
        )

        {:error, reason}

      {:error, reason, _extra} ->
        Logger.error(
          "ScyllaDB container '#{container_name}' failed after #{div(elapsed, 1000)}ms: #{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  @doc """
  Convenience: stops the container via `TestcontainerEx.stop_container/2`.
  """
  @spec stop(binary(), atom()) :: :ok
  def stop(container_id, _name \\ :default) do
    Logger.info("Stopping ScyllaDB container #{container_id}...")
    TestcontainerEx.stop_container(container_id)
  end

  @doc """
  Convenience: returns the host via `TestcontainerEx.get_host/1`.
  """
  @spec host(Config.t()) :: String.t()
  def host(%Config{} = container) do
    TestcontainerEx.get_host(container)
  end

  # --- Private helpers ---

  defp random_container_name do
    suffix = :crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)
    "scylla_test_#{suffix}"
  end
end
