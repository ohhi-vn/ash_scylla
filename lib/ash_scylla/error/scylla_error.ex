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

  require Logger

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

  # Maps Xandra connection error reason atoms to ScyllaError types
  @connection_error_types %{
    closed: :connection_closed,
    timeout: :connection_timeout,
    econnrefused: :connection_refused,
    ehostunreach: :host_unreachable
  }

  # Maps Xandra error reason atoms to error categories and types
  @error_atom_patterns [
    {:write_timeout, :timeout, %{}},
    {:read_timeout, :timeout, %{}},
    {:read_failure, :timeout, %{}},
    {:write_failure, :timeout, %{}},
    {:unavailable, :consistency_error, %{}},
    {:overloaded, :overloaded, %{}},
    {:prepared_query_mismatch, :query_error, %{}},
    {:already_exists, :already_exists, %{}},
    {:not_found, :not_found, %{}},
    {:authentication_error, :unauthorized, %{}},
    {:protocol_error, :query_error, %{}},
    {:configuration_error, :query_error, %{}},
    {:invalid_query, :query_error, %{}},
    {:syntax_error, :syntax_error, %{}},
    {:unauthorized, :unauthorized, %{}},
    {:is_bootstrapping, :consistency_error, %{}},
    {:truncate_error, :query_error, %{}},
    {:function_failure, :query_error, %{}},
    {:invalid, :schema_error, %{}}
  ]

  # Maps binary reason patterns to error categories and types
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

  @doc """
  Creates a ScyllaError from a Xandra.Error.
  """
  @spec from_xandra_error(Xandra.Error.t()) :: t()
  def from_xandra_error(%Xandra.Error{} = error) do
    reason = error.reason
    {category, type, details} = categorize_xandra_error(reason)

    build_error(type, reason, category, details, error)
  end

  @doc """
  Creates a ScyllaError from a Xandra.ConnectionError.
  """
  @spec from_xandra_connection_error(Xandra.ConnectionError.t()) :: t()
  def from_xandra_connection_error(%Xandra.ConnectionError{} = error) do
    reason = error.reason

    case classify_connection_error(reason) do
      {:ok, type, message, suggestion} ->
        %ScyllaError{
          type: type,
          reason: reason,
          message: message,
          suggestion: suggestion,
          original_error: error
        }

      {:fallback, _reason} ->
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
  @spec from_error(term()) :: t()
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
  @spec to_string(t()) :: String.t()
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

  @doc """
  Creates a ScyllaError with query context.

  Convenience function for wrapping an error that includes the query
  that caused it.
  """
  @spec with_query(t(), String.t()) :: t()
  def with_query(%ScyllaError{} = error, query) when is_binary(query) do
    %ScyllaError{error | query: query}
  end

  @doc """
  Creates a ScyllaError from a Xandra.Error with query context.
  """
  @spec from_xandra_error(Xandra.Error.t(), String.t() | nil) :: t()
  def from_xandra_error(%Xandra.Error{} = error, query) when is_binary(query) do
    error
    |> from_xandra_error()
    |> with_query(query)
  end

  def from_xandra_error(%Xandra.Error{} = error, nil) do
    from_xandra_error(error)
  end

  @doc """
  Creates a ScyllaError from a Xandra.ConnectionError with query context.
  """
  @spec from_xandra_connection_error(Xandra.ConnectionError.t(), String.t() | nil) :: t()
  def from_xandra_connection_error(%Xandra.ConnectionError{} = error, query)
      when is_binary(query) do
    error
    |> from_xandra_connection_error()
    |> with_query(query)
  end

  def from_xandra_connection_error(%Xandra.ConnectionError{} = error, nil) do
    from_xandra_connection_error(error)
  end

  # Private functions

  # --- Connection error classification ---

  @spec classify_connection_error(atom() | {:unreachable, term()} | term()) ::
          {:ok, atom(), String.t(), String.t()} | {:fallback, term()}
  defp classify_connection_error(reason) when is_atom(reason) do
    case Map.fetch(@connection_error_types, reason) do
      {:ok, type} ->
        {message, suggestion} = connection_error_message(type)
        {:ok, type, message, suggestion}

      :error ->
        classify_connection_error_fallback(reason)
    end
  end

  @spec classify_connection_error({:unreachable, term()}) :: {:ok, atom(), String.t(), String.t()}
  defp classify_connection_error({:unreachable, _host}) do
    {:ok, :host_unreachable, "ScyllaDB host is unreachable",
     "Check network connectivity and that the ScyllaDB node is online."}
  end

  @spec classify_connection_error(term()) ::
          {:ok, atom(), String.t(), String.t()} | {:fallback, term()}
  defp classify_connection_error(reason) do
    classify_connection_error_fallback(reason)
  end

  @spec classify_connection_error_fallback(term()) :: {:fallback, term()}
  defp classify_connection_error_fallback(reason) do
    Logger.warning("Unknown Xandra connection error reason: #{inspect(reason)}")
    {:fallback, reason}
  end

  @spec connection_error_message(atom()) :: {String.t(), String.t()}
  defp connection_error_message(:connection_closed) do
    {"Connection to ScyllaDB was closed",
     "Check if ScyllaDB is running and network connectivity is available."}
  end

  defp connection_error_message(:connection_timeout) do
    {"Connection to ScyllaDB timed out",
     "Increase connection timeout in repo config or check network latency to ScyllaDB nodes."}
  end

  defp connection_error_message(:connection_refused) do
    {"Connection to ScyllaDB was refused",
     "Check if ScyllaDB is running on the configured host/port and firewall rules allow connections."}
  end

  defp connection_error_message(:host_unreachable) do
    {"ScyllaDB host is unreachable",
     "Check network connectivity and that the ScyllaDB node is online."}
  end

  # --- Xandra error categorization ---

  @spec categorize_xandra_error(atom() | binary() | term()) :: {atom(), atom(), map()}
  defp categorize_xandra_error(reason) when is_atom(reason) do
    case List.keyfind(@error_atom_patterns, reason, 0) do
      {^reason, type, details} ->
        {type, type, details}

      nil ->
        Logger.warning("Unknown Xandra error atom reason: #{inspect(reason)}")
        {:unknown, :unknown, %{reason: reason}}
    end
  end

  @spec categorize_xandra_error(binary()) :: {atom(), atom(), map()}
  defp categorize_xandra_error(reason) when is_binary(reason) do
    Enum.find_value(@error_patterns, {:unknown, :unknown, %{reason: reason}}, fn
      {pattern, type, sub_patterns} ->
        if String.contains?(reason, pattern) do
          case sub_patterns do
            [{sub_pattern, sub_type}] ->
              if String.contains?(reason, sub_pattern) do
                {sub_type, sub_type, %{type: :table_not_found, reason: reason}}
              else
                {type, type, %{reason: reason}}
              end

            [] ->
              {type, type, %{reason: reason}}
          end
        end
    end)
  end

  @spec categorize_xandra_error(term()) :: {atom(), atom(), map()}
  defp categorize_xandra_error(reason) do
    Logger.warning("Unknown Xandra error reason type: #{inspect(reason)}")
    {:unknown, :unknown, %{reason: reason}}
  end

  # --- Error builder ---

  @spec build_error(atom(), term(), atom(), map(), term()) :: t()
  defp build_error(:query_error, reason, _category, details, error) do
    %ScyllaError{
      type: :query_error,
      reason: reason,
      message: "Query execution failed: #{format_reason(reason)}",
      suggestion: query_error_suggestion(details),
      original_error: error
    }
  end

  @spec build_error(:syntax_error, term(), atom(), map(), term()) :: t()
  defp build_error(:syntax_error, reason, _category, _details, error) do
    %ScyllaError{
      type: :syntax_error,
      reason: reason,
      message: "CQL syntax error: #{format_reason(reason)}",
      suggestion: syntax_error_suggestion(),
      original_error: error
    }
  end

  @spec build_error(:schema_error, term(), atom(), map(), term()) :: t()
  defp build_error(:schema_error, reason, _category, details, error) do
    message =
      if is_map(error) and Map.has_key?(error, :message) and error.message != "" do
        "Schema error: #{error.message}"
      else
        "Schema error: #{format_reason(reason)}"
      end

    # Try to detect table-not-found from the error message even when reason is a generic atom
    details =
      if is_map(error) and is_binary(error.message) and
           String.contains?(error.message, "unconfigured table") do
        Map.put(details, :type, :table_not_found)
      else
        details
      end

    %ScyllaError{
      type: :schema_error,
      reason: reason,
      message: message,
      suggestion: schema_error_suggestion(details),
      original_error: error
    }
  end

  @spec build_error(:unauthorized, term(), atom(), map(), term()) :: t()
  defp build_error(:unauthorized, reason, _category, _details, error) do
    %ScyllaError{
      type: :unauthorized,
      reason: reason,
      message: "Unauthorized: #{format_reason(reason)}",
      suggestion: unauthorized_suggestion(),
      original_error: error
    }
  end

  @spec build_error(:overloaded, term(), atom(), map(), term()) :: t()
  defp build_error(:overloaded, reason, _category, _details, error) do
    %ScyllaError{
      type: :overloaded,
      reason: reason,
      message: "ScyllaDB node is overloaded: #{format_reason(reason)}",
      suggestion: overloaded_suggestion(),
      original_error: error
    }
  end

  @spec build_error(:timeout, term(), atom(), map(), term()) :: t()
  defp build_error(:timeout, reason, _category, _details, error) do
    %ScyllaError{
      type: :timeout,
      reason: reason,
      message: "Query timeout: #{format_reason(reason)}",
      suggestion: timeout_suggestion(),
      original_error: error
    }
  end

  @spec build_error(:already_exists, term(), atom(), map(), term()) :: t()
  defp build_error(:already_exists, reason, _category, _details, error) do
    %ScyllaError{
      type: :already_exists,
      reason: reason,
      message: "Resource already exists: #{format_reason(reason)}",
      suggestion: already_exists_suggestion(),
      original_error: error
    }
  end

  @spec build_error(:not_found, term(), atom(), map(), term()) :: t()
  defp build_error(:not_found, reason, _category, _details, error) do
    %ScyllaError{
      type: :not_found,
      reason: reason,
      message: "Resource not found: #{format_reason(reason)}",
      suggestion: not_found_suggestion(),
      original_error: error
    }
  end

  @spec build_error(:consistency_error, term(), atom(), map(), term()) :: t()
  defp build_error(:consistency_error, reason, _category, _details, error) do
    %ScyllaError{
      type: :consistency_error,
      reason: reason,
      message: "Consistency level not met: #{format_reason(reason)}",
      suggestion: consistency_error_suggestion(),
      original_error: error
    }
  end

  @spec build_error(:unknown, term(), atom(), map(), term()) :: t()
  defp build_error(:unknown, reason, _category, _details, error) do
    %ScyllaError{
      type: :unknown,
      reason: reason,
      message: "Unknown ScyllaDB error: #{format_reason(reason)}",
      suggestion: "Check ScyllaDB logs for more details.",
      original_error: error
    }
  end

  @spec build_error(atom(), term(), atom(), map(), term()) :: t()
  defp build_error(type, reason, _category, _details, error) do
    %ScyllaError{
      type: type,
      reason: reason,
      message: "ScyllaDB error: #{format_reason(reason)}",
      suggestion: "Check ScyllaDB logs for more details.",
      original_error: error
    }
  end

  # --- Formatting ---

  @spec format_reason(binary() | term()) :: String.t()
  defp format_reason(reason) when is_binary(reason) do
    reason
    |> String.replace(~r/^\w+:/, "")
    |> String.trim()
  end

  @spec format_reason(term()) :: String.t()
  defp format_reason(reason) do
    inspect(reason)
  end

  # --- Suggestion helpers ---

  @spec query_error_suggestion(map()) :: String.t()
  defp query_error_suggestion(%{reason: reason}) when is_binary(reason) do
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

  @spec query_error_suggestion(map()) :: String.t()
  defp query_error_suggestion(_details) do
    "Review the CQL query syntax and ensure all referenced columns exist."
  end

  @spec syntax_error_suggestion() :: String.t()
  defp syntax_error_suggestion do
    "Check the CQL syntax. Common issues:\n" <>
      "- Missing or extra commas\n" <>
      "- Incorrect keyword usage\n" <>
      "- Unmatched parentheses"
  end

  @spec schema_error_suggestion(map()) :: String.t()
  defp schema_error_suggestion(%{type: :table_not_found}) do
    "The table doesn't exist. You may need to:\n" <>
      "1. Run migrations to create the table\n" <>
      "2. Check the table name in your resource configuration\n" <>
      "3. Verify you're using the correct keyspace"
  end

  @spec schema_error_suggestion(map()) :: String.t()
  defp schema_error_suggestion(_details) do
    "Check that all referenced tables, columns, and keyspaces exist and are properly configured."
  end

  @spec unauthorized_suggestion() :: String.t()
  defp unauthorized_suggestion do
    "Check that:\n" <>
      "1. The user has the necessary permissions\n" <>
      "2. Authentication credentials are correct\n" <>
      "3. Role-based access control is properly configured"
  end

  @spec overloaded_suggestion() :: String.t()
  defp overloaded_suggestion do
    "The ScyllaDB node is overloaded. Consider:\n" <>
      "1. Increasing the request timeout\n" <>
      "2. Reducing the query load\n" <>
      "3. Scaling your ScyllaDB cluster\n" <>
      "4. Checking for inefficient queries"
  end

  @spec timeout_suggestion() :: String.t()
  defp timeout_suggestion do
    "Query timed out. Consider:\n" <>
      "1. Increasing the request_timeout in repo configuration\n" <>
      "2. Optimizing the query (add more specific WHERE clauses)\n" <>
      "3. Using pagination for large result sets\n" <>
      "4. Checking ScyllaDB node performance"
  end

  @spec already_exists_suggestion() :: String.t()
  defp already_exists_suggestion do
    "The resource already exists. Consider:\n" <>
      "1. Using IF NOT EXISTS in your CQL\n" <>
      "2. Checking if the record already exists before inserting\n" <>
      "3. Using UPDATE instead of INSERT if appropriate"
  end

  @spec not_found_suggestion() :: String.t()
  defp not_found_suggestion do
    "The resource was not found. Check that:\n" <>
      "1. The table/keyspace exists\n" <>
      "2. You're using the correct names\n" <>
      "3. The resource hasn't been dropped"
  end

  @spec consistency_error_suggestion() :: String.t()
  defp consistency_error_suggestion do
    "The required consistency level was not met. Consider:\n" <>
      "1. Lowering the consistency level (e.g., from QUORUM to ONE)\n" <>
      "2. Ensuring enough replicas are available\n" <>
      "3. Checking the replication factor configuration"
  end
end
