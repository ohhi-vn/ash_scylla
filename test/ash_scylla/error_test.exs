defmodule AshScylla.ErrorTest do
  @moduledoc """
  Tests for the AshScylla error handling module.

  These tests verify that ScyllaDB-specific errors are properly
  categorized and transformed into user-friendly error messages.
  """

  use ExUnit.Case, async: true

  alias AshScylla.Error
  alias AshScylla.Error.ScyllaError

  describe "wrap_xandra_error/1" do
    test "wraps Xandra.Error with syntax error" do
      xandra_error = %Xandra.Error{
        reason: "SyntaxException: line 1:8 no viable alternative at input 'SELEC' (SELEC...)"
      }

      result = Error.wrap_xandra_error(xandra_error)

      assert %ScyllaError{type: :syntax_error} = result
      assert result.message =~ "CQL syntax error"
      assert result.suggestion != nil
    end

    test "wraps Xandra.Error with query error" do
      xandra_error = %Xandra.Error{
        reason: "InvalidRequestException: unconfigured table my_table"
      }

      result = Error.wrap_xandra_error(xandra_error)

      assert %ScyllaError{type: :schema_error} = result
      assert result.message =~ "Schema error"
    end

    test "wraps Xandra.Error with overloaded error" do
      xandra_error = %Xandra.Error{
        reason: "OverloadedException: Too many requests"
      }

      result = Error.wrap_xandra_error(xandra_error)

      assert %ScyllaError{type: :overloaded} = result
      assert result.message =~ "overloaded"
      assert result.suggestion =~ "timeout"
    end

    test "wraps Xandra.ConnectionError" do
      conn_error = %Xandra.ConnectionError{reason: :econnrefused}

      result = Error.wrap_xandra_error(conn_error)

      assert %ScyllaError{type: :connection_refused} = result
      assert result.message =~ "refused"
      assert result.suggestion =~ "running"
    end

    test "wraps generic errors" do
      result = Error.wrap_xandra_error("some random error")

      assert %ScyllaError{type: :generic_error} = result
    end
  end

  describe "retryable?/1" do
    test "connection errors are retryable" do
      error = %ScyllaError{type: :connection_timeout}
      assert Error.retryable?(error) == true

      error = %ScyllaError{type: :connection_closed}
      assert Error.retryable?(error) == true

      error = %ScyllaError{type: :overloaded}
      assert Error.retryable?(error) == true
    end

    test "schema errors are not retryable" do
      error = %ScyllaError{type: :schema_error}
      assert Error.retryable?(error) == false

      error = %ScyllaError{type: :syntax_error}
      assert Error.retryable?(error) == false
    end
  end

  describe "retry_delay/1" do
    test "returns appropriate delays based on error type" do
      assert Error.retry_delay(%ScyllaError{type: :overloaded}) == 1000
      assert Error.retry_delay(%ScyllaError{type: :timeout}) == 500
      assert Error.retry_delay(%ScyllaError{type: :connection_timeout}) == 2000
      assert Error.retry_delay(%ScyllaError{type: :syntax_error}) == 500
    end
  end

  describe "format_error/1" do
    test "formats ScyllaError with suggestion" do
      error = %ScyllaError{
        type: :timeout,
        message: "Query timeout: timed out",
        suggestion: "Increase the request_timeout"
      }

      formatted = Error.format_error(error)
      assert formatted =~ "[timeout]"
      assert formatted =~ "Query timeout"
      assert formatted =~ "Suggestion:"
    end

    test "formats generic errors" do
      formatted = Error.format_error("some error")
      assert formatted == "\"some error\""
    end
  end

  describe "ScyllaError categorization" do
    test "categorizes timeout errors" do
      error = %Xandra.Error{reason: "ReadTimeoutException: Operation timed out"}
      result = ScyllaError.from_xandra_error(error)

      assert result.type == :timeout
      assert result.suggestion =~ "request_timeout"
    end

    test "categorizes consistency errors" do
      error = %Xandra.Error{
        reason: "UnavailableException: Cannot achieve consistency level QUORUM"
      }

      result = ScyllaError.from_xandra_error(error)

      assert result.type == :consistency_error
      assert result.suggestion =~ "consistency level"
    end

    test "categorizes not found errors" do
      error = %Xandra.Error{reason: "NotFoundException: Column family not found"}
      result = ScyllaError.from_xandra_error(error)

      assert result.type == :not_found
    end

    test "categorizes already exists errors" do
      error = %Xandra.Error{reason: "AlreadyExistsException: Table already exists"}
      result = ScyllaError.from_xandra_error(error)

      assert result.type == :already_exists
      assert result.suggestion =~ "IF NOT EXISTS"
    end
  end
end
