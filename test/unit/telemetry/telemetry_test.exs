defmodule AshScylla.TelemetryTest do
  @moduledoc """
  Tests for AshScylla.Telemetry.
  """

  use ExUnit.Case, async: true

  alias AshScylla.Telemetry

  # Module-captured telemetry handlers (avoid the "local function" warning).
  def handle_start(event, measurements, metadata, _config) do
    send(self(), {:start_event, event, measurements, metadata})
  end

  def handle_stop(event, measurements, metadata, _config) do
    send(self(), {:stop_event, event, measurements, metadata})
  end

  def handle_exception(event, measurements, metadata, _config) do
    send(self(), {:exception_event, event, measurements, metadata})
  end

  def handle_batch_start(event, measurements, metadata, _config) do
    send(self(), {:batch_start, event, measurements, metadata})
  end

  def handle_batch_stop(event, measurements, metadata, _config) do
    send(self(), {:batch_stop, event, measurements, metadata})
  end

  # ---------------------------------------------------------------------------
  # span/4
  # ---------------------------------------------------------------------------

  describe "span/4" do
    test "returns the result of the wrapped function" do
      result = Telemetry.span(MyModule, :read, "SELECT * FROM t", fn -> {:ok, [1, 2, 3]} end)
      assert result == {:ok, [1, 2, 3]}
    end

    test "returns the result when function returns a simple value" do
      result = Telemetry.span(MyModule, :read, "SELECT 1", fn -> 42 end)
      assert result == 42
    end

    test "emits start and stop telemetry events on success" do
      :telemetry.attach(
        "test-span-success",
        [:ash_scylla, :query, :start],
        &__MODULE__.handle_start/4,
        nil
      )

      :telemetry.attach(
        "test-span-stop",
        [:ash_scylla, :query, :stop],
        &__MODULE__.handle_stop/4,
        nil
      )

      Telemetry.span(MyModule, :read, "SELECT * FROM users", fn -> :ok end)

      assert_receive {:start_event, [:ash_scylla, :query, :start], %{system_time: _}, metadata}
      assert metadata.resource == MyModule
      assert metadata.operation == :read
      assert metadata.query == "SELECT * FROM users"

      assert_receive {:stop_event, [:ash_scylla, :query, :stop], %{duration: duration}, _metadata}
      assert is_integer(duration)
      assert duration >= 0

      :telemetry.detach("test-span-success")
      :telemetry.detach("test-span-stop")
    end

    test "emits exception event when function raises" do
      :telemetry.attach(
        "test-span-exception",
        [:ash_scylla, :query, :exception],
        &__MODULE__.handle_exception/4,
        nil
      )

      assert_raise RuntimeError, ~r/test error/, fn ->
        Telemetry.span(MyModule, :read, "SELECT * FROM t", fn ->
          raise "test error"
        end)
      end

      assert_receive {:exception_event, [:ash_scylla, :query, :exception], %{duration: duration},
                      metadata}

      assert is_integer(duration)
      assert duration >= 0
      assert metadata.resource == MyModule
      assert metadata.operation == :read
      assert metadata.kind == :error

      :telemetry.detach("test-span-exception")
    end

    test "re-raises the original exception" do
      assert_raise ArgumentError, ~r/badarg/, fn ->
        Telemetry.span(MyModule, :write, "INSERT INTO t", fn ->
          raise ArgumentError, "badarg"
        end)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # batch_span/4
  # ---------------------------------------------------------------------------

  describe "batch_span/4" do
    test "returns the result of the wrapped function" do
      result = Telemetry.batch_span(MyModule, :insert, 10, fn -> {:ok, :completed} end)
      assert result == {:ok, :completed}
    end

    test "emits batch start and stop telemetry events" do
      :telemetry.attach(
        "test-batch-start",
        [:ash_scylla, :batch, :start],
        &__MODULE__.handle_batch_start/4,
        nil
      )

      :telemetry.attach(
        "test-batch-stop",
        [:ash_scylla, :batch, :stop],
        &__MODULE__.handle_batch_stop/4,
        nil
      )

      Telemetry.batch_span(MyModule, :insert, 25, fn -> :ok end)

      assert_receive {:batch_start, [:ash_scylla, :batch, :start], %{system_time: _}, metadata}
      assert metadata.resource == MyModule
      assert metadata.operation == :insert
      assert metadata.batch_size == 25

      assert_receive {:batch_stop, [:ash_scylla, :batch, :stop], %{duration: duration}, _metadata}
      assert is_integer(duration)
      assert duration >= 0

      :telemetry.detach("test-batch-start")
      :telemetry.detach("test-batch-stop")
    end
  end

  # ---------------------------------------------------------------------------
  # format_duration/1
  # ---------------------------------------------------------------------------

  describe "format_duration/1" do
    test "formats nanoseconds" do
      assert Telemetry.format_duration(500) == "500ns"
    end

    test "formats microseconds" do
      assert Telemetry.format_duration(999_999) == "999µs"
    end

    test "formats milliseconds" do
      assert Telemetry.format_duration(1_500_000) == "1ms"
    end

    test "formats seconds" do
      assert Telemetry.format_duration(2_000_000_000) == "2.0s"
    end

    test "formats fractional seconds" do
      result = Telemetry.format_duration(1_500_000_000)
      assert result == "1.5s"
    end

    test "handles zero" do
      assert Telemetry.format_duration(0) == "0ns"
    end

    test "handles large values" do
      result = Telemetry.format_duration(60_000_000_000)
      assert result == "60.0s"
    end
  end
end
