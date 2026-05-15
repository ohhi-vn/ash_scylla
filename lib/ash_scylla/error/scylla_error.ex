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

defmodule AshScylla.Error.ScyllaError do
  @moduledoc """
  Comprehensive error handling for ScyllaDB-specific errors.

  This module provides structured error types for ScyllaDB/Cassandra errors,
  user-friendly error messages, and suggestions for resolving common issues.

  ## Error Categories

  - **Connection Errors**: Issues connecting to ScyllaDB nodes
  - **Query Errors**: Invalid CQL syntax, type mismatches
  - **Consistency Errors**: Write/read consistency failures
  - **Schema Errors**: Table, keyspace, or column not found
  - **Rate Limiting**: Overloaded nodes, timeout errors
  - **Configuration Errors**: Invalid configuration options

  ## Usage

      case repo.query(query, params) do
        {:ok, result} ->
          {:ok, result}

        {:error, %Xandra.Error{} = error} ->
          {:error, AshScylla.Error.ScyllaError.from_xandra_error(error)}

        {:error, %Xandra.ConnectionError{} = error} ->
          {:error, AshScylla.Error.ScyllaError.from_xandra_connection_error(error)}
      end
  """

  alias __MODULE__

  @type t :: %__MODULE__{
          type: atom(),
          reason: term(),
          message: String.t(),
          suggestion: String.t() | nil,
          query: String.t() | nil,
          original_error: term()
        }

  defstruct [
    :type,
    :reason,
    :message,
    :suggestion,
    :query,
    :original_error
  ]

  @doc """
  Creates a ScyllaError from a Xandra.Error.
  """
  def from_xandra_error(%Xandra.Error{} = error) do
    reason = error.reason

    case categorize_xandra_error(reason) do
      {:query_error, details} ->
        %ScyllaError{
          type: :query_error,
          reason: reason,
          message: "Query execution failed: #{format_reason(reason)}",
          suggestion: query_error_suggestion(details),
          original_error: error
        }

      {:syntax_error, details} ->
        %ScyllaError{
          type: :syntax_error,
          reason: reason,
          message: "CQL syntax error: #{format_reason(reason)}",
          suggestion: syntax_error_suggestion(details),
          original_error: error
        }

      {:schema_error, details} ->
        %ScyllaError{
          type: :schema_error,
          reason: reason,
          message: "Schema error: #{format_reason(reason)}",
          suggestion: schema_error_suggestion(details),
          original_error: error
        }

      {:unauthorized, details} ->
        %ScyllaError{
          type: :unauthorized,
          reason: reason,
          message: "Unauthorized: #{format_reason(reason)}",
          suggestion: unauthorized_suggestion(details),
          original_error: error
        }

      {:overloaded, details} ->
        %ScyllaError{
          type: :overloaded,
          reason: reason,
          message: "ScyllaDB node is overloaded: #{format_reason(reason)}",
          suggestion: overloaded_suggestion(details),
          original_error: error
        }

      {:timeout, details} ->
        %ScyllaError{
          type: :timeout,
          reason: reason,
          message: "Query timeout: #{format_reason(reason)}",
          suggestion: timeout_suggestion(details),
          original_error: error
        }

      {:already_exists, details} ->
        %ScyllaError{
          type: :already_exists,
          reason: reason,
          message: "Resource already exists: #{format_reason(reason)}",
          suggestion: already_exists_suggestion(details),
          original_error: error
        }

      {:not_found, details} ->
        %ScyllaError{
          type: :not_found,
          reason: reason,
          message: "Resource not found: #{format_reason(reason)}",
          suggestion: not_found_suggestion(details),
          original_error: error
        }

      {:consistency_error, details} ->
        %ScyllaError{
          type: :consistency_error,
          reason: reason,
          message: "Consistency level not met: #{format_reason(reason)}",
          suggestion: consistency_error_suggestion(details),
          original_error: error
        }

      {:unknown, _} ->
        %ScyllaError{
          type: :unknown,
          reason: reason,
          message: "Unknown ScyllaDB error: #{format_reason(reason)}",
          suggestion: "Check ScyllaDB logs for more details.",
          original_error: error
        }
    end
  end

  @doc """
  Creates a ScyllaError from a Xandra.ConnectionError.
  """
  def from_xandra_connection_error(%Xandra.ConnectionError{} = error) do
    reason = error.reason

    case reason do
      :closed ->
        %ScyllaError{
          type: :connection_closed,
          reason: reason,
          message: "Connection to ScyllaDB was closed",
          suggestion: "Check if ScyllaDB is running and network connectivity is available.",
          original_error: error
        }

      :timeout ->
        %ScyllaError{
          type: :connection_timeout,
          reason: reason,
          message: "Connection to ScyllaDB timed out",
          suggestion:
            "Increase connection timeout in repo config or check network latency to ScyllaDB nodes.",
          original_error: error
        }

      :econnrefused ->
        %ScyllaError{
          type: :connection_refused,
          reason: reason,
          message: "Connection to ScyllaDB was refused",
          suggestion:
            "Check if ScyllaDB is running on the configured host/port and firewall rules allow connections.",
          original_error: error
        }

      :ehostunreach ->
        %ScyllaError{
          type: :host_unreachable,
          reason: reason,
          message: "ScyllaDB host is unreachable",
          suggestion: "Check network connectivity and that the ScyllaDB node is online.",
          original_error: error
        }

      {:unreachable, _host} ->
        %ScyllaError{
          type: :host_unreachable,
          reason: reason,
          message: "ScyllaDB host is unreachable: #{inspect(reason)}",
          suggestion: "Check network connectivity and that the ScyllaDB node is online.",
          original_error: error
        }

      _ ->
        %ScyllaError{
          type: :connection_error,
          reason: reason,
          message: "Failed to connect to ScyllaDB: #{format_reason(reason)}",
          suggestion: "Verify ScyllaDB configuration and network connectivity.",
          original_error: error
        }
    end
  end

  @doc """
  Creates a ScyllaError from a generic error.
  """
  def from_error(error) do
    %ScyllaError{
      type: :generic_error,
      reason: error,
      message: "Database error: #{inspect(error)}",
      suggestion: "Check the error details and ScyllaDB logs.",
      original_error: error
    }
  end

  @doc """
  Converts the error to a human-readable string.
  """
  def to_string(%ScyllaError{} = error) do
    base_message = "[#{error.type}] #{error.message}"

    suggestion_text =
      if error.suggestion do
        "\nSuggestion: #{error.suggestion}"
      else
        ""
      end

    query_text =
      if error.query do
        "\nQuery: #{error.query}"
      else
        ""
      end

    base_message <> suggestion_text <> query_text
  end

  # Private functions

  @error_patterns [
    {"SyntaxException", :syntax_error, []},
    {"InvalidRequestException", :query_error, [{"unconfigured table", :schema_error}]},
    {"AlreadyExistsException", :already_exists, []},
    {"NotFoundException", :not_found, []},
    {"UnauthorizedException", :unauthorized, []},
    {"OverloadedException", :overloaded, []},
    {"ReadTimeoutException", :timeout, []},
    {"WriteTimeoutException", :timeout, []},
    {"UnavailableException", :consistency_error, []}
  ]

  defp categorize_xandra_error(reason) when is_binary(reason) do
    Enum.find_value(@error_patterns, {:unknown, %{reason: reason}}, fn
      {pattern, type, sub_patterns} ->
        if String.contains?(reason, pattern) do
          case sub_patterns do
            [{sub_pattern, sub_type}] ->
              if String.contains?(reason, sub_pattern) do
                {sub_type, %{type: :table_not_found, reason: reason}}
              else
                {type, %{reason: reason}}
              end

            [] ->
              {type, %{reason: reason}}
          end
        end
    end)
  end

  defp categorize_xandra_error(reason) do
    {:unknown, %{reason: reason}}
  end

  defp format_reason(reason) when is_binary(reason) do
    # Clean up the reason string
    reason
    |> String.replace(~r/^\w+:/, "")
    |> String.trim()
  end

  defp format_reason(reason) do
    inspect(reason)
  end

  # Suggestion helpers

  defp query_error_suggestion(%{reason: reason}) do
    cond do
      String.contains?(reason, "PRIMARY KEY") ->
        "Check that you're providing all primary key columns in your query."

      String.contains?(reason, "WHERE") ->
        "Verify your WHERE clause syntax and ensure you're filtering on indexed columns."

      String.contains?(reason, "type") ->
        "Check that the data types in your query match the column types in the schema."

      true ->
        "Review the CQL query syntax and ensure all referenced columns exist."
    end
  end

  defp syntax_error_suggestion(_details) do
    "Check the CQL syntax. Common issues:\n" <>
      "- Missing or extra commas\n" <>
      "- Incorrect keyword usage\n" <>
      "- Unmatched parentheses"
  end

  defp schema_error_suggestion(%{type: :table_not_found}) do
    "The table doesn't exist. You may need to:\n" <>
      "1. Run migrations to create the table\n" <>
      "2. Check the table name in your resource configuration\n" <>
      "3. Verify you're using the correct keyspace"
  end

  defp schema_error_suggestion(_details) do
    "Check that all referenced tables, columns, and keyspaces exist and are properly configured."
  end

  defp unauthorized_suggestion(_details) do
    "Check that:\n" <>
      "1. The user has the necessary permissions\n" <>
      "2. Authentication credentials are correct\n" <>
      "3. Role-based access control is properly configured"
  end

  defp overloaded_suggestion(_details) do
    "The ScyllaDB node is overloaded. Consider:\n" <>
      "1. Increasing the request timeout\n" <>
      "2. Reducing the query load\n" <>
      "3. Scaling your ScyllaDB cluster\n" <>
      "4. Checking for inefficient queries"
  end

  defp timeout_suggestion(_details) do
    "Query timed out. Consider:\n" <>
      "1. Increasing the request_timeout in repo configuration\n" <>
      "2. Optimizing the query (add more specific WHERE clauses)\n" <>
      "3. Using pagination for large result sets\n" <>
      "4. Checking ScyllaDB node performance"
  end

  defp already_exists_suggestion(_details) do
    "The resource already exists. Consider:\n" <>
      "1. Using IF NOT EXISTS in your CQL\n" <>
      "2. Checking if the record already exists before inserting\n" <>
      "3. Using UPDATE instead of INSERT if appropriate"
  end

  defp not_found_suggestion(_details) do
    "The resource was not found. Check that:\n" <>
      "1. The table/keyspace exists\n" <>
      "2. You're using the correct names\n" <>
      "3. The resource hasn't been dropped"
  end

  defp consistency_error_suggestion(_details) do
    "The required consistency level was not met. Consider:\n" <>
      "1. Lowering the consistency level (e.g., from QUORUM to ONE)\n" <>
      "2. Ensuring enough replicas are available\n" <>
      "3. Checking the replication factor configuration"
  end
end
