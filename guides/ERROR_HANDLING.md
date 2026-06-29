# Error Handling Guide

> **Comprehensive error handling for AshScylla**

---

## Overview

AshScylla provides structured error handling for ScyllaDB-specific errors. It categorizes Xandra errors into meaningful types and provides actionable suggestions for developers.

---

## Error Architecture

```
┌──────────────────────────────────────────────────────┐
│          AshScylla.DataLayer                        │
│  (wraps Xandra errors with wrap_xandra_error/1)    │
└──────────────────┬───────────────────────────────────┘
                   │
                   ▼
┌──────────────────────────────────────────────────────┐
│          AshScylla.Error                            │
│  • wrap_xandra_error/1  - Convert errors           │
│  • format_error/1      - Format for display        │
│  • retryable?/1        - Check if retryable        │
└──────────────────┬───────────────────────────────────┘
                   │
                   ▼
┌──────────────────────────────────────────────────────┐
│    AshScylla.Error.ScyllaError                      │
│  • Categorizes errors by type                       │
│  • Provides user-friendly suggestions               │
│  • Structured error information                     │
└──────────────────────────────────────────────────────┘
```

---

## Error Types

| Error Type | Description | When It Occurs |
|------------|-------------|----------------|
| `:syntax_error` | Invalid CQL syntax | Malformed CQL queries |
| `:query_error` | General query execution error | Invalid queries |
| `:schema_error` | Schema-related error | Table/keyspace/column not found |
| `:overloaded` | ScyllaDB node overloaded | High load on cluster |
| `:timeout` | Query timeout | Read/write timeout |
| `:consistency_error` | Consistency level not met | Insufficient replicas |
| `:unauthorized` | Permission denied | Invalid credentials/permissions |
| `:already_exists` | Resource conflict | Table/keyspace already exists |
| `:not_found` | Resource missing | Table/keyspace doesn't exist |
| `:connection_timeout` | Connection timeout | Network issues |
| `:connection_closed` | Connection closed | Node unavailable |
| `:connection_error` | General connection error | Network/configuration issues |

---

## Using Error Handling

### Basic Error Handling

```elixir
case AshScylla.DataLayer.run_query(query, resource) do
  {:ok, results} ->
    {:ok, results}

  {:error, %AshScylla.Error.ScyllaError{} = error} ->
    # Log the detailed error
    Logger.error("Database error: #{AshScylla.Error.format_error(error)}")

    # Check if we should retry
      if AshScylla.Error.retryable?(error) do
        {:retry, error}
      else
        {:error, error}
      end

  {:error, error} ->
    # Handle other errors
    {:error, error}
end
```

### Error Struct Fields

```elixir
%AshScylla.Error.ScyllaError{
  type: :overloaded,           # Error category (atom)
  reason: "...",               # Original error reason
  message: "...",              # Human-readable message
  suggestion: "...",           # Actionable suggestion
  original_error: %Xandra...   # Original Xandra error
}
```

---

## Retry Logic

### Checking Retryability

```elixir
error = %AshScylla.Error.ScyllaError{type: :overloaded}

if AshScylla.Error.retryable?(error) do
  IO.puts("This error is retryable")
else
  IO.puts("This error is NOT retryable")
end
```

### Retryable Errors

| Error Type | Retryable? |
|------------|-------------|
| `:overloaded` | ✅ Yes |
| `:connection_timeout` | ✅ Yes |
| `:timeout` | ✅ Yes |
| `:connection_closed` | ✅ Yes |
| `:connection_error` | ✅ Yes |
| `:syntax_error` | ❌ No |
| `:schema_error` | ❌ No |
| `:unauthorized` | ❌ No |
| `:already_exists` | ❌ No |
| `:not_found` | ❌ No |

### Implementing Retry with Backoff

```elixir
defmodule MyApp.Database do
  @max_retries 3
  @base_delays %{
    overloaded: 1000,
    timeout: 500,
    connection_timeout: 2000,
    connection_closed: 1000,
    connection_error: 2000
  }

  def execute_with_retry(operation, retries \\ 0) do
    case operation.() do
      {:ok, result} ->
        {:ok, result}

      {:error, %AshScylla.Error.ScyllaError{} = error} ->
        if AshScylla.Error.retryable?(error) and retries < @max_retries do
          delay = Map.get(@base_delays, error.type, 500)
          sleep_time = delay * :math.pow(2, retries)
          Process.sleep(round(sleep_time))
          execute_with_retry(operation, retries + 1)
        else
          {:error, error}
        end

      {:error, error} ->
        {:error, error}
    end
  end
end
```

---

## Error Formatting

### Formatting Errors for Display

```elixir
error = %AshScylla.Error.ScyllaError{
  type: :overloaded,
  message: "ScyllaDB node is overloaded",
  suggestion: "Increase timeout, reduce load, or scale your cluster"
}

formatted = AshScylla.Error.format_error(error)
IO.puts(formatted)

# Output:
# ScyllaDB Error (overloaded): ScyllaDB node is overloaded
# Suggestion: Increase timeout, reduce load, or scale your cluster
```

---

## Common Error Scenarios

### 1. Connection Refused

```elixir
%AshScylla.Error.ScyllaError{
  type: :connection_error,
  message: "Connection refused",
  suggestion: "Check if ScyllaDB is running and accessible at the configured address"
}
```

**Solution:**
- Verify ScyllaDB is running: `podman ps`
- Check `nodes` configuration in `config/config.exs`
- Ensure firewall allows connections

### 2. Syntax Error

```elixir
%AshScylla.Error.ScyllaError{
  type: :syntax_error,
  message: "Invalid CQL syntax at line 1: SELECT * FROM",
  suggestion: "Check CQL syntax, ensure proper commas, parentheses, and keywords"
}
```

**Solution:**
- Review CQL query syntax
- Check for missing commas, parentheses
- Validate table/column names

### 3. Schema Error (Table Not Found)

```elixir
%AshScylla.Error.ScyllaError{
  type: :schema_error,
  message: "Table 'users' not found",
  suggestion: "Run migrations to create the table, or verify the table name and keyspace"
}
```

**Solution:**
- Run migrations: `mix ash_scylla.migrate`
- Verify table name in resource configuration
- Check keyspace configuration

### 4. Overloaded Node

```elixir
%AshScylla.Error.ScyllaError{
  type: :overloaded,
  message: "ScyllaDB node is overloaded",
  suggestion: "Increase timeout, reduce load, or scale your cluster"
}
```

**Solution:**
- Increase `request_timeout` in repo config
- Scale ScyllaDB cluster (add nodes)
- Optimize queries
- Use retry logic with backoff

### 5. Timeout

```elixir
%AshScylla.Error.ScyllaError{
  type: :timeout,
  message: "Query timed out after 120000ms",
  suggestion: "Increase request_timeout in repo config, optimize query, or use pagination"
}
```

**Solution:**
- Increase `request_timeout`: `config :my_app, MyApp.Repo, request_timeout: 300_000`
- Optimize slow queries
- Use pagination for large result sets

### 6. Record Not Found

When `fetch_by_primary_key` returns an empty result set (no matching record), AshScylla returns a structured `ScyllaError` instead of crashing:

```elixir
{:error, %AshScylla.Error.ScyllaError{
  type: :query_error,
  message: "Record not found in table users with primary key %{id: \"uuid\"}"
}}
```

This prevents `MatchError` crashes when a record is deleted between operations.

### 7. Aggregate Query Empty Results

When `run_aggregate_query` returns an empty result set from ScyllaDB, it gracefully returns `0` for the count instead of crashing:

```elixir
# Empty result from COUNT query returns 0
{:ok, %{total: 0}} = DataLayer.run_aggregate_query(query, [%{kind: :count, name: :total}], resource)
```

### 8. Non-Indexed Column Filter

```
%AshScylla.Error.ScyllaError{
  type: :schema_error,
  message: "Cannot execute this query as it might involve data filtering... use ALLOW FILTERING"
}
```

AshScylla rejects such queries at query-plan time when a query filters on a column that is neither part of the primary key nor has a secondary index.

**Solution A (Recommended): Add a secondary index**
```elixir
scylla do
  secondary_index :game_id
end
```

**Solution B: Use a materialized view** for the query pattern.

### 9. Consistency Level Not Met

```elixir
%AshScylla.Error.ScyllaError{
  type: :consistency_error,
  message: "Consistency level QUORUM not met",
  suggestion: "Lower consistency level, check replica availability, or increase replication factor"
}
```

**Solution:**
- Lower consistency level: `scylla do consistency :one end`
- Check if replicas are available
- Verify replication factor in keyspace

### 10. CQL Injection Prevention

AshScylla sanitizes all CQL identifiers through `AshScylla.Identifier`:

```elixir
AshScylla.Identifier.sanitize!("users; DROP TABLE users")
# => ** (ArgumentError) Invalid CQL identifier: "users; DROP TABLE users"
```

All table names, column names, keyspace names, and index names are validated before interpolation into CQL strings.

---

## Testing Error Handling

AshScylla includes comprehensive tests for error handling:

```bash
# Run error handling tests
mix test test/unit/error/
```

### Test Coverage

- All error types and categorization
- Retryability classification
- Error formatting
- Connection error subclassification
- Filter validation (unindexed column rejection)
- CQL injection prevention (identifier sanitization)

---

## Best Practices

### 1. Always Handle Errors

```elixir
# Bad: Not handling errors
Ash.create(resource)

# Good: Proper error handling
case Ash.create(resource) do
  {:ok, result} -> result
  {:error, error} -> handle_error(error)
end
```

### 2. Use Retry for Transient Errors

```elixir
# Retry connection and timeout errors
if AshScylla.Error.retryable?(error) do
  # Implement your own delay logic based on error.type
  Process.sleep(1000)
  # retry
end
```

### 3. Log Errors with Context

```elixir
Logger.error("""
Database error occurred:
- Error: #{AshScylla.Error.format_error(error)}
- Resource: #{inspect(resource)}
- Operation: #{operation}
""")
```

### 4. Provide User-Friendly Messages

```elixir
def handle_database_error(%AshScylla.Error.ScyllaError{} = error) do
  %{message: message, suggestion: suggestion} = error

  """
  A database error occurred: #{message}

  What you can do: #{suggestion}
  """
end
```

---

## Module Documentation

For detailed API documentation, see:

- `AshScylla.Error` — Unified error handling interface
- `AshScylla.Error.ScyllaError` — ScyllaDB-specific error types

```elixir
# Get help in IEx
h AshScylla.Error
h AshScylla.Error.ScyllaError
```

---

## License

Apache License 2.0 - see [LICENSE](LICENSE) file for details.
