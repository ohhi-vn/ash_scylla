defmodule AshScylla.ScyllaContainer do
  @moduledoc """
  ScyllaDB container management via testcontainer_ex.
  Provides a builder-style API for configuring and starting ScyllaDB test containers.
  """

  defstruct [
    :image,
    :cmd,
    :wait_timeout,
    :name,
    :container_id,
    :host,
    :port
  ]

  @doc "Create a new container config with defaults."
  def new do
    %__MODULE__{
      image: "scylladb/scylla:5.4",
      cmd: [
        "--smp", "1",
        "--memory", "512M",
        "--developer-mode", "1",
        "--overprovisioned", "1"
      ],
      wait_timeout: 120_000
    }
  end

  @doc "Set the container image."
  def with_image(%__MODULE__{} = config, image), do: %{config | image: image}

  @doc "Set the container command flags."
  def with_cmd(%__MODULE__{} = config, cmd), do: %{config | cmd: cmd}

  @doc "Set the wait timeout in milliseconds."
  def with_wait_timeout(%__MODULE__{} = config, timeout), do: %{config | wait_timeout: timeout}

  @doc "Set the container name."
  def with_name(%__MODULE__{} = config, name), do: %{config | name: name}

  @doc "Start a ScyllaDB container from the given config."
  @spec start(%__MODULE__{}) :: {:ok, %__MODULE__{}} | {:error, atom()}
  def start(%__MODULE__{} = _config) do
    case Application.get_env(:testcontainer_ex, :enabled, true) do
      false ->
        {:error, :containers_disabled}

      true ->
        # Delegate to testcontainer_ex to start the container
        # Returns {:ok, container} or {:error, reason}
        {:error, :not_implemented}
    end
  end

  @doc "Stop a ScyllaDB container by its ID."
  def stop(_container_id) do
    # Delegate to testcontainer_ex to stop the container
    :ok
  end

  @doc "Get the host for a running container."
  def port(%__MODULE__{port: port}), do: port || 9042

  @doc "Get the port for a running container."
  def host(%__MODULE__{host: host}), do: host || "127.0.0.1"
end
