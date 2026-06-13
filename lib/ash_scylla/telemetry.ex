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

defmodule AshScylla.Telemetry do
  @moduledoc """
  Telemetry integration for AshScylla.

  Emits standard `:telemetry` events for query execution, enabling
  integration with LiveDashboard, Datadog, OpenTelemetry, and other
  observability tools.

  ## Events

  - `[:ash_scylla, :query, :start]` - Emitted when a query begins execution.
    Measurements: `%{system_time: integer()}`
    Metadata: `%{resource: module(), operation: atom(), query: String.t()}`

  - `[:ash_scylla, :query, :stop]` - Emitted when a query finishes.
    Measurements: `%{duration: integer()}`
    Metadata: `%{resource: module(), operation: atom(), query: String.t()}`

  - `[:ash_scylla, :query, :exception]` - Emitted when a query raises.
    Measurements: `%{duration: integer()}`
    Metadata: `%{resource: module(), operation: atom(), query: String.t(), kind: atom(), reason: term()}`

  - `[:ash_scylla, :batch, :start]` - Emitted when a batch operation begins.
    Measurements: `%{system_time: integer()}`
    Metadata: `%{resource: module(), operation: atom(), batch_size: integer()}`

  - `[:ash_scylla, :batch, :stop]` - Emitted when a batch operation finishes.
    Measurements: `%{duration: integer()}`
    Metadata: `%{resource: module(), operation: atom(), batch_size: integer()}`

  ## Attaching a Handler

      :telemetry.attach(
        "ash_scylla-logger",
        [:ash_scylla, :query, :stop],
        &MyApp.Telemetry.handle_event/4,
        nil
      )
  """

  @doc """
  Executes a function within a telemetry span.

  Emits `[:ash_scylla, :query, :start]` before execution and
  `[:ash_scylla, :query, :stop]` after. If the function raises,
  `[:ash_scylla, :query, :exception]` is emitted.

  Returns the function's return value.
  """
  @spec span(module(), atom(), String.t(), (-> result)) :: result when result: var
  def span(resource, operation, query, fun) do
    metadata = %{resource: resource, operation: operation, query: query}
    emit_span(:query, metadata, fn -> fun.() end)
  end

  @doc """
  Executes a batch operation within a telemetry span.

  Emits `[:ash_scylla, :batch, :start]` before execution and
  `[:ash_scylla, :batch, :stop]` after.
  """
  @spec batch_span(module(), atom(), integer(), (-> result)) :: result when result: var
  def batch_span(resource, operation, batch_size, fun) do
    metadata = %{resource: resource, operation: operation, batch_size: batch_size}
    emit_span(:batch, metadata, fn -> fun.() end)
  end

  @doc """
  Formats a duration in nanoseconds to a human-readable string.
  """
  @spec format_duration(integer()) :: String.t()
  def format_duration(nanoseconds) do
    cond do
      nanoseconds < 1_000 -> "#{nanoseconds}ns"
      nanoseconds < 1_000_000 -> "#{div(nanoseconds, 1_000)}µs"
      nanoseconds < 1_000_000_000 -> "#{div(nanoseconds, 1_000_000)}ms"
      true -> "#{Float.round(nanoseconds / 1_000_000_000, 2)}s"
    end
  end

  # ---------------------------------------------------------------------------
  # Private functions
  # ---------------------------------------------------------------------------

  defp emit_span(prefix, metadata, fun) do
    start_time = System.monotonic_time()

    :telemetry.execute(
      [:ash_scylla, prefix, :start],
      %{system_time: System.system_time()},
      metadata
    )

    try do
      result = fun.()
      duration = System.monotonic_time() - start_time
      :telemetry.execute([:ash_scylla, prefix, :stop], %{duration: duration}, metadata)
      result
    rescue
      exception ->
        duration = System.monotonic_time() - start_time
        exception_metadata = Map.put(metadata, :kind, :error)

        :telemetry.execute(
          [:ash_scylla, prefix, :exception],
          %{duration: duration},
          exception_metadata
        )

        reraise exception, __STACKTRACE__
    end
  end
end
