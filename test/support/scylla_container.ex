defmodule AshScylla.ScyllaContainer do
  @moduledoc """
  ScyllaDB container management via testcontainer_ex.
  Provides a builder-style API for configuring and starting ScyllaDB test containers.
  """

  require Logger

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
        "--smp",
        "1",
        "--memory",
        "512M",
        "--developer-mode",
        "1",
        "--overprovisioned",
        "1"
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
  @spec start(%__MODULE__{}) :: {:ok, %__MODULE__{}} | {:error, term()}
  def start(%__MODULE__{} = config) do
    case Application.get_env(:testcontainer_ex, :enabled, true) do
      false ->
        {:error, :containers_disabled}

      true ->
        with :ok <- ensure_testcontainer_ex() do
          do_start(config)
        end
    end
  end

  defp ensure_testcontainer_ex do
    case Process.whereis(TestcontainerEx) do
      nil ->
        Logger.info("Starting TestcontainerEx GenServer...")
        old_flag = Process.flag(:trap_exit, true)

        result =
          try do
            case TestcontainerEx.start_link(name: TestcontainerEx) do
              {:ok, _pid} ->
                Logger.info("TestcontainerEx started successfully")
                :ok

              {:error, {:already_started, _pid}} ->
                :ok

              {:error, reason} ->
                Logger.warning("TestcontainerEx failed to start: #{inspect(reason)}")
                {:error, reason}
            end
          catch
            :exit, reason ->
              Logger.warning("TestcontainerEx init crashed: #{inspect(reason)}")
              {:error, {:container_engine_unavailable, reason}}
          after
            Process.flag(:trap_exit, old_flag)
            flush_exit_messages()
          end

        result

      _pid ->
        :ok
    end
  end

  defp flush_exit_messages do
    receive do
      {:EXIT, _pid, _reason} -> flush_exit_messages()
    after
      0 -> :ok
    end
  end

  defp do_start(config) do
    tc_config =
      TestcontainerEx.custom_container(config.image)
      |> TestcontainerEx.CustomContainer.with_exposed_port(9042)
      |> TestcontainerEx.CustomContainer.with_env("SCYLLA_SKIP_WAIT_FOR_GOSPEL_TO_SETTLE", "0")
      |> TestcontainerEx.CustomContainer.with_cmd(config.cmd)
      |> TestcontainerEx.CustomContainer.with_wait_strategy(
        TestcontainerEx.Wait.command(["nodetool", "status"], config.wait_timeout)
      )
      |> then(fn cc ->
        if config.name,
          do: TestcontainerEx.CustomContainer.with_name(cc, config.name),
          else: cc
      end)

    case TestcontainerEx.start_container(tc_config) do
      {:ok, container} ->
        {:ok,
         %{config
           | container_id: container.container_id,
             host: TestcontainerEx.get_host(container),
             port: TestcontainerEx.get_port(container, 9042)
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Stop a ScyllaDB container by its ID."
  def stop(container_id) when is_binary(container_id) do
    TestcontainerEx.stop_container(container_id)
  end

  def stop(_), do: :ok

  @doc "Get the CQL port for a running container."
  def port(%__MODULE__{port: port}), do: port || 9042

  @doc "Get the host for a running container."
  def host(%__MODULE__{host: host}), do: host || "127.0.0.1"
end
