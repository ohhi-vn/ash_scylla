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

  alias AshScylla.Error.ScyllaError

  @doc """
  Wraps a Xandra error into a structured AshScylla error.
  """
  def wrap_xandra_error(%Xandra.Error{} = error) do
    ScyllaError.from_xandra_error(error)
  end

  def wrap_xandra_error(%Xandra.ConnectionError{} = error) do
    ScyllaError.from_xandra_connection_error(error)
  end

  def wrap_xandra_error(error) do
    ScyllaError.from_error(error)
  end

  @doc """
  Formats an error for display to the user.
  """
  def format_error(%ScyllaError{} = error) do
    ScyllaError.to_string(error)
  end

  def format_error(error) do
    inspect(error)
  end

  @doc """
  Checks if an error is retryable.
  """
  def retryable?(%ScyllaError{type: type}) do
    type in [:connection_timeout, :connection_closed, :overloaded, :timeout, :connection_error]
  end

  def retryable?(_), do: false

  @doc """
  Returns a suggested retry delay in milliseconds.
  """
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

  def retry_delay(_), do: 500
end
