defmodule AshScylla.ScyllaContainer do
  @moduledoc """
  Shim module that provides a ScyllaDB container configuration over the
  testcontainer_ex 0.6 CustomContainer backend.

  > Uses `TestcontainerEx` 0.6+ (`start_container/2`, `stop_container/2`, `get_host/1`, `get_port/2`).
  > For `start_containers/2` (parallel), `monitor_container/4`, and other 0.6 features,
  > call directly on `TestcontainerEx`.
  """

  alias TestcontainerEx.CustomContainer
  alias TestcontainerEx.PortWaitStrategy

  @default_image "scylladb/scylla:5.4"
  @default_cql_port 9042

  @doc """
  Creates a new ScyllaDB container configuration with default image
  "scylladb/scylla:5.4" and exposed CQL port 9042.
  """
  @spec new() :: CustomContainer.t()
  def new do
    CustomContainer.new(@default_image)
    |> CustomContainer.with_exposed_port(@default_cql_port)
  end

  @doc """
  Sets the container image.
  """
  @spec with_image(CustomContainer.t(), String.t()) :: CustomContainer.t()
  def with_image(%CustomContainer{} = container, image) when is_binary(image) do
    CustomContainer.with_image(container, image)
  end

  @doc """
  Sets the container command.
  """
  @spec with_cmd(CustomContainer.t(), [String.t()]) :: CustomContainer.t()
  def with_cmd(%CustomContainer{} = container, cmd) when is_list(cmd) do
    CustomContainer.with_cmd(container, cmd)
  end

  @doc """
  Adds a PortWaitStrategy that waits until the CQL port (9042) is
  accepting TCP connections, with the given timeout in milliseconds.
  """
  @spec with_wait_timeout(CustomContainer.t(), pos_integer()) :: CustomContainer.t()
  def with_wait_timeout(%CustomContainer{} = container, timeout)
      when is_integer(timeout) and timeout > 0 do
    strategy = PortWaitStrategy.new("localhost", @default_cql_port, timeout, 1000)
    CustomContainer.with_wait_strategy(container, strategy)
  end

  @doc """
  Sets the container name.
  """
  @spec with_name(CustomContainer.t(), String.t()) :: CustomContainer.t()
  def with_name(%CustomContainer{} = container, name) when is_binary(name) do
    CustomContainer.with_name(container, name)
  end

  @doc """
  Returns the mapped host port for the CQL port (9042) from a started
  container (Config struct).
  """
  @spec port(TestcontainerEx.Container.Config.t()) :: integer() | nil
  def port(%TestcontainerEx.Container.Config{} = container) do
    TestcontainerEx.get_port(container, @default_cql_port)
  end

  @doc """
  Convenience: starts the container with `TestcontainerEx.start_container/2`.
  """
  @spec start(CustomContainer.t(), atom()) ::
          {:ok, TestcontainerEx.Container.Config.t()} | {:error, term()}
  def start(container, name \\ :default) do
    case name do
      :default -> TestcontainerEx.start_container(container)
      _ -> TestcontainerEx.start_container(container, name)
    end
  end

  @doc """
  Convenience: stops the container via `TestcontainerEx.stop_container/2`.
  """
  @spec stop(binary(), atom()) :: :ok
  def stop(container_id, name \\ :default) do
    case name do
      :default -> TestcontainerEx.stop_container(container_id)
      _ -> TestcontainerEx.stop_container(container_id, name)
    end
  end

  @doc """
  Convenience: returns the host via `TestcontainerEx.get_host/2`.
  """
  @spec host(TestcontainerEx.Container.Config.t(), atom()) :: String.t()
  def host(container, name \\ :default) do
    case name do
      :default -> TestcontainerEx.get_host(container)
      _ -> TestcontainerEx.get_host(container, name)
    end
  end
end
