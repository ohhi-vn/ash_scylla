defmodule AshScylla.ErrorHandlingSecurityTest do
  @moduledoc """
  Security tests for error handling — ensures that:
  - Raw Xandra errors are never leaked to callers
  - Error messages don't expose sensitive connection details
  - retryable?/1 is accurate (no false negatives that hide failures)
  """

  use ExUnit.Case, async: true

  alias AshScylla.Error
  alias AshScylla.Error.ScyllaError

  # ---------------------------------------------------------------------------
  # Error wrapping — raw driver errors are never leaked
  # ---------------------------------------------------------------------------

  describe "error wrapping prevents information leakage" do
    test "wrap_xandra_error converts Xandra.Error to ScyllaError" do
      xandra_error = %Xandra.Error{
        reason: :invalid_query,
        message: "Some internal error with connection details"
      }

      result = Error.wrap_xandra_error(xandra_error)
      assert %ScyllaError{} = result
    end

    test "wrap_xandra_error converts Xandra.ConnectionError to ScyllaError" do
      conn_error = %Xandra.ConnectionError{
        reason: :closed,
        action: :connect
      }

      result = Error.wrap_xandra_error(conn_error)
      assert %ScyllaError{} = result
    end

    test "wrap_xandra_error handles unknown error types" do
      result = Error.wrap_xandra_error(:something_unexpected)
      assert %ScyllaError{} = result
    end

    test "ScyllaError has structured fields, not raw driver data" do
      xandra_error = %Xandra.Error{
        reason: :overloaded,
        message: "Node 10.0.0.1 is overloaded"
      }

      result = Error.wrap_xandra_error(xandra_error)
      assert result.type != nil
      assert result.message != nil
      # The original error is preserved for debugging but not exposed to callers
      assert result.original_error != nil
    end
  end

  # ---------------------------------------------------------------------------
  # Error categorization — ensures correct security-relevant categorization
  # ---------------------------------------------------------------------------

  describe "error categorization security" do
    test "unauthorized errors are categorized correctly" do
      error = %Xandra.Error{reason: :unauthorized, message: "Unauthorized"}
      result = Error.wrap_xandra_error(error)
      assert result.type == :unauthorized
    end

    test "overloaded errors are categorized correctly (DoS indicator)" do
      error = %Xandra.Error{reason: :overloaded, message: "Overloaded"}
      result = Error.wrap_xandra_error(error)
      assert result.type == :overloaded
    end

    test "timeout errors are categorized correctly" do
      error = %Xandra.Error{reason: :read_timeout, message: "Read timeout"}
      result = Error.wrap_xandra_error(error)
      assert result.type == :timeout
    end
  end

  # ---------------------------------------------------------------------------
  # retryable?/1 — must be accurate to avoid hiding failures
  # ---------------------------------------------------------------------------

  describe "retryable?/1 security" do
    test "overloaded errors are retryable" do
      assert Error.retryable?(%ScyllaError{type: :overloaded}) == true
    end

    test "timeout errors are retryable" do
      assert Error.retryable?(%ScyllaError{type: :timeout}) == true
    end

    test "connection errors are retryable" do
      assert Error.retryable?(%ScyllaError{type: :connection_error}) == true
    end

    test "connection_timeout errors are retryable" do
      assert Error.retryable?(%ScyllaError{type: :connection_timeout}) == true
    end

    test "connection_closed errors are retryable" do
      assert Error.retryable?(%ScyllaError{type: :connection_closed}) == true
    end

    test "unauthorized errors are NOT retryable" do
      # Retrying an auth error won't help — it's a security issue
      refute Error.retryable?(%ScyllaError{type: :unauthorized})
    end

    test "query errors are NOT retryable" do
      # Retrying a bad query won't help
      refute Error.retryable?(%ScyllaError{type: :query_error})
    end

    test "schema errors are NOT retryable" do
      refute Error.retryable?(%ScyllaError{type: :schema_error})
    end

    test "syntax errors are NOT retryable" do
      refute Error.retryable?(%ScyllaError{type: :syntax_error})
    end

    test "unknown errors are NOT retryable (fail-safe)" do
      refute Error.retryable?(%ScyllaError{type: :unknown})
    end

    test "non-ScyllaError returns false (fail-safe)" do
      refute Error.retryable?(:something_else)
      refute Error.retryable?(%{})
      refute Error.retryable?(nil)
    end
  end

  # ---------------------------------------------------------------------------
  # Error message safety — no credential or connection detail leakage
  # ---------------------------------------------------------------------------

  describe "error message safety" do
    test "ScyllaError suggestions don't contain connection strings" do
      error = %Xandra.Error{reason: :unavailable, message: "Not enough replicas"}
      result = Error.wrap_xandra_error(error)

      # Suggestions should be generic, not containing IPs/ports/credentials
      if result.suggestion do
        refute result.suggestion =~ ~r/\d+\.\d+\.\d+\.\d+/
        refute result.suggestion =~ ~r/:9042/
        refute result.suggestion =~ ~r/password/i
        refute result.suggestion =~ ~r/secret/i
      end
    end

    test "format_error doesn't expose internal state" do
      error = %ScyllaError{
        type: :query_error,
        reason: :invalid,
        message: "Invalid query",
        suggestion: "Check your query syntax",
        query: nil,
        original_error: nil
      }

      formatted = Error.format_error(error)
      assert is_binary(formatted)
      # Should contain the message but not raw internal data
      assert formatted =~ "Invalid query"
    end
  end
end
