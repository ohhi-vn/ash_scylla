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

defmodule AshScylla.Error do
  @moduledoc """
  Common error types and utilities for AshScylla.

  This module provides a unified interface for error handling across the AshScylla
  library, including ScyllaDB-specific errors, configuration errors, and query errors.
  """

  require Logger

  alias AshScylla.Error.ScyllaError

  @doc """
  Wraps a Xandra error into a structured AshScylla error.
  """
  @spec wrap_xandra_error(Xandra.Error.t()) :: ScyllaError.t()
  def wrap_xandra_error(%Xandra.Error{} = error) do
    Logger.warning("Wrapping Xandra.Error: #{inspect(error)}")
    ScyllaError.from_xandra_error(error)
  end

  @spec wrap_xandra_error(Xandra.ConnectionError.t()) :: ScyllaError.t()
  def wrap_xandra_error(%Xandra.ConnectionError{} = error) do
    Logger.warning("Wrapping Xandra.ConnectionError: #{inspect(error)}")
    ScyllaError.from_xandra_connection_error(error)
  end

  @spec wrap_xandra_error(term()) :: ScyllaError.t()
  def wrap_xandra_error(error) do
    Logger.warning("Wrapping unknown error: #{inspect(error)}")
    ScyllaError.from_error(error)
  end

  @doc """
  Formats an error for display to the user.
  """
  @spec format_error(ScyllaError.t()) :: String.t()
  def format_error(%ScyllaError{} = error) do
    ScyllaError.to_string(error)
  end

  @spec format_error(term()) :: String.t()
  def format_error(error) do
    inspect(error)
  end

  @doc """
  Checks if an error is retryable.
  """
  @spec retryable?(ScyllaError.t() | term()) :: boolean()
  def retryable?(%ScyllaError{type: type}) do
    type in [:connection_timeout, :connection_closed, :overloaded, :timeout, :connection_error]
  end

  def retryable?(error) do
    Logger.warning("retryable?/1 called with unknown error type: #{inspect(error)}")
    false
  end

  @doc """
  Returns a suggested retry delay in milliseconds.
  """
  @spec retry_delay(ScyllaError.t() | term()) :: non_neg_integer()
  def retry_delay(%ScyllaError{type: type}) do
    case type do
      :overloaded -> 1000
      :timeout -> 500
      :connection_timeout -> 2000
      :connection_closed -> 1000
      :connection_error -> 2000
      _ -> 500
    end
  end

  def retry_delay(error) do
    Logger.warning("retry_delay/1 called with unknown error type: #{inspect(error)}")
    500
  end
end
