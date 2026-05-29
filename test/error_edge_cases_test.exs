defmodule AshScylla.ErrorEdgeCasesTest do
  @moduledoc """
  Comprehensive error handling edge cases for AshScylla.
  Covers all Xandra error types, connection errors, formatting,
  retry logic, and the Error module wrapper functions.
  """

  use ExUnit.Case, async: false

  alias AshScylla.{Error, Error.ScyllaError}

  # ── Xandra atom reason errors ────────────────────────────────────────────

  describe "ScyllaError.from_xandra_error with atom reasons" do
    test "write_timeout" do
      e = %Xandra.Error{reason: :write_timeout, message: nil, warnings: []}
      r = ScyllaError.from_xandra_error(e)
      assert r.type == :timeout
      assert r.original_error == e
    end

    test "read_timeout" do
      e = %Xandra.Error{reason: :read_timeout, message: nil, warnings: []}
      r = ScyllaError.from_xandra_error(e)
      assert r.type == :timeout
    end

    test "read_failure" do
      e = %Xandra.Error{reason: :read_failure, message: nil, warnings: []}
      r = ScyllaError.from_xandra_error(e)
      assert r.type == :timeout
    end

    test "write_failure" do
      e = %Xandra.Error{reason: :write_failure, message: nil, warnings: []}
      r = ScyllaError.from_xandra_error(e)
      assert r.type == :timeout
    end

    test "unavailable" do
      e = %Xandra.Error{reason: :unavailable, message: nil, warnings: []}
      r = ScyllaError.from_xandra_error(e)
      assert r.type == :consistency_error
    end

    test "overloaded" do
      e = %Xandra.Error{reason: :overloaded, message: nil, warnings: []}
      r = ScyllaError.from_xandra_error(e)
      assert r.type == :overloaded
    end

    test "prepared_query_mismatch" do
      e = %Xandra.Error{reason: :prepared_query_mismatch, message: nil, warnings: []}
      r = ScyllaError.from_xandra_error(e)
      assert r.type == :query_error
    end

    test "already_exists" do
      e = %Xandra.Error{reason: :already_exists, message: nil, warnings: []}
      r = ScyllaError.from_xandra_error(e)
      assert r.type == :already_exists
    end

    test "not_found" do
      e = %Xandra.Error{reason: :not_found, message: nil, warnings: []}
      r = ScyllaError.from_xandra_error(e)
      assert r.type == :not_found
    end

    test "authentication_error" do
      e = %Xandra.Error{reason: :authentication_error, message: nil, warnings: []}
      r = ScyllaError.from_xandra_error(e)
      assert r.type == :unauthorized
    end

    test "protocol_error" do
      e = %Xandra.Error{reason: :protocol_error, message: nil, warnings: []}
      r = ScyllaError.from_xandra_error(e)
      assert r.type == :query_error
    end

    test "configuration_error" do
      e = %Xandra.Error{reason: :configuration_error, message: nil, warnings: []}
      r = ScyllaError.from_xandra_error(e)
      assert r.type == :query_error
    end

    test "invalid_query" do
      e = %Xandra.Error{reason: :invalid_query, message: nil, warnings: []}
      r = ScyllaError.from_xandra_error(e)
      assert r.type == :query_error
    end

    test "syntax_error" do
      e = %Xandra.Error{reason: :syntax_error, message: nil, warnings: []}
      r = ScyllaError.from_xandra_error(e)
      assert r.type == :syntax_error
    end

    test "unauthorized" do
      e = %Xandra.Error{reason: :unauthorized, message: nil, warnings: []}
      r = ScyllaError.from_xandra_error(e)
      assert r.type == :unauthorized
    end

    test "is_bootstrapping" do
      e = %Xandra.Error{reason: :is_bootstrapping, message: nil, warnings: []}
      r = ScyllaError.from_xandra_error(e)
      assert r.type == :consistency_error
    end

    test "truncate_error" do
      e = %Xandra.Error{reason: :truncate_error, message: nil, warnings: []}
      r = ScyllaError.from_xandra_error(e)
      assert r.type == :query_error
    end

    test "function_failure" do
      e = %Xandra.Error{reason: :function_failure, message: nil, warnings: []}
      r = ScyllaError.from_xandra_error(e)
      assert r.type == :query_error
    end

    test "unknown atom reason" do
      e = %Xandra.Error{reason: :some_new_error, message: nil, warnings: []}
      r = ScyllaError.from_xandra_error(e)
      assert r.type == :unknown
      assert r.reason == :some_new_error
    end

    test "nil reason" do
      e = %Xandra.Error{reason: nil, message: nil, warnings: []}
      r = ScyllaError.from_xandra_error(e)
      assert r.type == :unknown
    end

    test "integer reason" do
      e = %Xandra.Error{reason: 42, message: nil, warnings: []}
      r = ScyllaError.from_xandra_error(e)
      assert r.type == :unknown
    end
  end

  # ── Xandra binary reason errors ──────────────────────────────────────────

  describe "ScyllaError.from_xandra_error with binary reasons" do
    test "SyntaxException" do
      e = %Xandra.Error{
        reason: "SyntaxException: line 1:8 no viable alternative",
        message: nil,
        warnings: []
      }

      r = ScyllaError.from_xandra_error(e)
      assert r.type == :syntax_error
    end

    test "InvalidRequestException with unconfigured table" do
      e = %Xandra.Error{
        reason: "InvalidRequestException: unconfigured table my_table",
        message: nil,
        warnings: []
      }

      r = ScyllaError.from_xandra_error(e)
      assert r.type == :schema_error
    end

    test "InvalidRequestException without unconfigured table" do
      e = %Xandra.Error{reason: "InvalidRequestException: bad input", message: nil, warnings: []}
      r = ScyllaError.from_xandra_error(e)
      assert r.type == :query_error
    end

    test "AlreadyExistsException" do
      e = %Xandra.Error{
        reason: "AlreadyExistsException: Table already exists",
        message: nil,
        warnings: []
      }

      r = ScyllaError.from_xandra_error(e)
      assert r.type == :already_exists
    end

    test "NotFoundException" do
      e = %Xandra.Error{reason: "NotFoundException: Item not found", message: nil, warnings: []}
      r = ScyllaError.from_xandra_error(e)
      assert r.type == :not_found
    end

    test "UnauthorizedException" do
      e = %Xandra.Error{
        reason: "UnauthorizedException: User lacks permission",
        message: nil,
        warnings: []
      }

      r = ScyllaError.from_xandra_error(e)
      assert r.type == :unauthorized
    end

    test "OverloadedException" do
      e = %Xandra.Error{
        reason: "OverloadedException: Too many requests",
        message: nil,
        warnings: []
      }

      r = ScyllaError.from_xandra_error(e)
      assert r.type == :overloaded
    end

    test "ReadTimeoutException" do
      e = %Xandra.Error{reason: "ReadTimeoutException: timeout", message: nil, warnings: []}
      r = ScyllaError.from_xandra_error(e)
      assert r.type == :timeout
    end

    test "WriteTimeoutException" do
      e = %Xandra.Error{reason: "WriteTimeoutException: timeout", message: nil, warnings: []}
      r = ScyllaError.from_xandra_error(e)
      assert r.type == :timeout
    end

    test "UnavailableException" do
      e = %Xandra.Error{
        reason: "UnavailableException: Not enough replicas",
        message: nil,
        warnings: []
      }

      r = ScyllaError.from_xandra_error(e)
      assert r.type == :consistency_error
    end

    test "completely unknown binary reason" do
      e = %Xandra.Error{
        reason: "SomeNewException: something unexpected",
        message: nil,
        warnings: []
      }

      r = ScyllaError.from_xandra_error(e)
      assert r.type == :unknown
    end
  end

  # ── Connection errors ────────────────────────────────────────────────────

  describe "ScyllaError.from_xandra_connection_error" do
    test ":closed" do
      e = %Xandra.ConnectionError{reason: :closed, action: nil}
      r = ScyllaError.from_xandra_connection_error(e)
      assert r.type == :connection_closed
    end

    test ":timeout" do
      e = %Xandra.ConnectionError{reason: :timeout, action: nil}
      r = ScyllaError.from_xandra_connection_error(e)
      assert r.type == :connection_timeout
    end

    test ":econnrefused" do
      e = %Xandra.ConnectionError{reason: :econnrefused, action: nil}
      r = ScyllaError.from_xandra_connection_error(e)
      assert r.type == :connection_refused
    end

    test ":ehostunreach" do
      e = %Xandra.ConnectionError{reason: :ehostunreach, action: nil}
      r = ScyllaError.from_xandra_connection_error(e)
      assert r.type == :host_unreachable
    end

    test "{:unreachable, host}" do
      e = %Xandra.ConnectionError{reason: {:unreachable, {"127.0.0.1", 9042}}, action: nil}
      r = ScyllaError.from_xandra_connection_error(e)
      assert r.type == :host_unreachable
    end

    test "unknown atom reason" do
      e = %Xandra.ConnectionError{reason: :some_unknown_reason, action: nil}
      r = ScyllaError.from_xandra_connection_error(e)
      assert r.type == :connection_error
    end

    test "unknown tuple reason" do
      e = %Xandra.ConnectionError{reason: {:unknown, "data"}, action: nil}
      r = ScyllaError.from_xandra_connection_error(e)
      assert r.type == :connection_error
    end
  end

  # ── Generic errors ───────────────────────────────────────────────────────

  describe "ScyllaError.from_error" do
    test "map error" do
      r = ScyllaError.from_error(%{custom: "error"})
      assert r.type == :generic_error
      assert r.original_error == %{custom: "error"}
    end

    test "string error" do
      r = ScyllaError.from_error("something went wrong")
      assert r.type == :generic_error
    end

    test "nil error" do
      r = ScyllaError.from_error(nil)
      assert r.type == :generic_error
    end

    test "integer error" do
      r = ScyllaError.from_error(42)
      assert r.type == :generic_error
    end

    test "atom error" do
      r = ScyllaError.from_error(:oops)
      assert r.type == :generic_error
    end
  end

  # ── Error formatting ─────────────────────────────────────────────────────

  describe "ScyllaError.to_string" do
    test "includes type and message" do
      e = %ScyllaError{
        type: :timeout,
        reason: :write_timeout,
        message: "Query timeout",
        suggestion: "Try again",
        query: nil,
        original_error: nil
      }

      s = ScyllaError.to_string(e)
      assert String.contains?(s, "[timeout]")
      assert String.contains?(s, "Query timeout")
      assert String.contains?(s, "Suggestion: Try again")
    end

    test "includes query when present" do
      e = %ScyllaError{
        type: :query_error,
        reason: :invalid,
        message: "Bad query",
        suggestion: nil,
        query: "SELECT * FROM missing_table",
        original_error: nil
      }

      s = ScyllaError.to_string(e)
      assert String.contains?(s, "Query: SELECT * FROM missing_table")
    end

    test "omits suggestion when nil" do
      e = %ScyllaError{
        type: :unknown,
        reason: :mystery,
        message: "Unknown",
        suggestion: nil,
        query: nil,
        original_error: nil
      }

      s = ScyllaError.to_string(e)
      refute String.contains?(s, "Suggestion")
    end

    test "omits query when nil" do
      e = %ScyllaError{
        type: :unknown,
        reason: :mystery,
        message: "Unknown",
        suggestion: nil,
        query: nil,
        original_error: nil
      }

      s = ScyllaError.to_string(e)
      refute String.contains?(s, "Query:")
    end
  end

  # ── Query context helpers ────────────────────────────────────────────────

  describe "query context helpers" do
    test "with_query attaches query" do
      e = %ScyllaError{
        type: :query_error,
        reason: :bad,
        message: "err",
        suggestion: nil,
        query: nil,
        original_error: nil
      }

      u = ScyllaError.with_query(e, "SELECT 1")
      assert u.query == "SELECT 1"
    end

    test "from_xandra_error/2 with query" do
      xe = %Xandra.Error{reason: :overloaded, message: nil, warnings: []}
      r = ScyllaError.from_xandra_error(xe, "INSERT INTO users ...")
      assert r.type == :overloaded
      assert r.query == "INSERT INTO users ..."
    end

    test "from_xandra_error/2 with nil query" do
      xe = %Xandra.Error{reason: :overloaded, message: nil, warnings: []}
      r = ScyllaError.from_xandra_error(xe, nil)
      assert r.type == :overloaded
      assert r.query == nil
    end

    test "from_xandra_connection_error/2 with query" do
      ce = %Xandra.ConnectionError{reason: :closed, action: nil}
      r = ScyllaError.from_xandra_connection_error(ce, "SELECT * FROM users")
      assert r.type == :connection_closed
      assert r.query == "SELECT * FROM users"
    end

    test "from_xandra_connection_error/2 with nil query" do
      ce = %Xandra.ConnectionError{reason: :closed, action: nil}
      r = ScyllaError.from_xandra_connection_error(ce, nil)
      assert r.type == :connection_closed
      assert r.query == nil
    end
  end

  # ── Error module wrapper ─────────────────────────────────────────────────

  describe "Error.wrap_xandra_error" do
    test "wraps Xandra.Error" do
      e = %Xandra.Error{reason: :overloaded, message: nil, warnings: []}
      r = Error.wrap_xandra_error(e)
      assert %ScyllaError{} = r
      assert r.type == :overloaded
    end

    test "wraps Xandra.ConnectionError" do
      e = %Xandra.ConnectionError{reason: :closed, action: nil}
      r = Error.wrap_xandra_error(e)
      assert %ScyllaError{} = r
      assert r.type == :connection_closed
    end

    test "wraps generic error" do
      r = Error.wrap_xandra_error("something")
      assert %ScyllaError{} = r
      assert r.type == :generic_error
    end

    test "wraps nil" do
      r = Error.wrap_xandra_error(nil)
      assert %ScyllaError{} = r
      assert r.type == :generic_error
    end
  end

  describe "Error.format_error" do
    test "formats ScyllaError" do
      e = %ScyllaError{
        type: :timeout,
        reason: :write_timeout,
        message: "Timed out",
        suggestion: "Retry",
        query: nil,
        original_error: nil
      }

      s = Error.format_error(e)
      assert String.contains?(s, "[timeout]")
    end

    test "formats string" do
      assert "\"simple error\"" = Error.format_error("simple error")
    end

    test "formats nil" do
      assert "nil" = Error.format_error(nil)
    end

    test "formats integer" do
      assert "42" = Error.format_error(42)
    end

    test "formats map" do
      s = Error.format_error(%{a: 1})
      assert String.contains?(s, "%{a: 1}")
    end
  end

  describe "Error.retryable?" do
    test "all retryable types return true" do
      for type <- [
            :connection_timeout,
            :connection_closed,
            :overloaded,
            :timeout,
            :connection_error
          ] do
        assert Error.retryable?(%ScyllaError{type: type}) == true
      end
    end

    test "all non-retryable types return false" do
      for type <- [
            :query_error,
            :syntax_error,
            :schema_error,
            :unauthorized,
            :already_exists,
            :not_found,
            :unknown,
            :generic_error
          ] do
        assert Error.retryable?(%ScyllaError{type: type}) == false
      end
    end

    test "non-ScyllaError struct returns false" do
      assert Error.retryable?(%{}) == false
    end

    test "nil returns false" do
      assert Error.retryable?(nil) == false
    end

    test "atom returns false" do
      assert Error.retryable?(:timeout) == false
    end

    test "string returns false" do
      assert Error.retryable?("timeout") == false
    end
  end

  describe "Error.retry_delay" do
    test "known types return correct delays" do
      assert Error.retry_delay(%ScyllaError{type: :overloaded}) == 1000
      assert Error.retry_delay(%ScyllaError{type: :timeout}) == 500
      assert Error.retry_delay(%ScyllaError{type: :connection_timeout}) == 2000
      assert Error.retry_delay(%ScyllaError{type: :connection_closed}) == 1000
      assert Error.retry_delay(%ScyllaError{type: :connection_error}) == 2000
    end

    test "unknown type returns default 500" do
      assert Error.retry_delay(%ScyllaError{type: :query_error}) == 500
      assert Error.retry_delay(%ScyllaError{type: :unknown}) == 500
      assert Error.retry_delay(%ScyllaError{type: :generic_error}) == 500
    end

    test "non-ScyllaError returns default 500" do
      assert Error.retry_delay(%{}) == 500
      assert Error.retry_delay(nil) == 500
      assert Error.retry_delay("error") == 500
    end
  end

  # ── Error struct field access ────────────────────────────────────────────

  describe "ScyllaError struct field access" do
    test "all fields accessible" do
      e = %ScyllaError{
        type: :timeout,
        reason: :write_timeout,
        message: "msg",
        suggestion: "sug",
        query: "q",
        original_error: %Xandra.Error{reason: :write_timeout, message: nil, warnings: []}
      }

      assert e.type == :timeout
      assert e.reason == :write_timeout
      assert e.message == "msg"
      assert e.suggestion == "sug"
      assert e.query == "q"
      assert e.original_error.reason == :write_timeout
    end
  end
end
