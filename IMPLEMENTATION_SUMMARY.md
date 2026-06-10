# AshScylla Implementation Summary

> **Technical overview of the AshScylla data layer implementation**

---

## Overview

AshScylla is a comprehensive data layer for the Ash Framework that enables persistence with **ScyllaDB** or **Apache Cassandra**. It uses [Exandra](https://github.com/lexhide/exandra) (an Ecto adapter) to communicate via CQL (Cassandra Query Language).

---

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│                    Ash Framework                        │
│  (Resources, Actions, Queries, Filters)               │
└──────────────────┬──────────────────────────────────────┘
                   │
                   ▼
┌─────────────────────────────────────────────────────────┐
│              AshScylla.DataLayer                       │
│  • Implements Ash.DataLayer behaviour                  │
│  • Converts Ash queries to CQL                        │
│  • Handles CRUD operations                            │
└──────────────────┬──────────────────────────────────────┘
                   │
                   ▼
┌─────────────────────────────────────────────────────────┐
│                  AshScylla.QueryBuilder                │
│  • Converts Ash filters to CQL WHERE clauses          │
│  • Builds optimized CQL queries                       │
└──────────────────┬──────────────────────────────────────┘
                   │
                   ▼
┌─────────────────────────────────────────────────────────┐
│                    Exandra (Ecto)                      │
│  • Ecto adapter for ScyllaDB/Cassandra               │
└──────────────────┬──────────────────────────────────────┘
                   │
                   ▼
┌─────────────────────────────────────────────────────────┐
│                   ScyllaDB/Cassandra                   │
└─────────────────────────────────────────────────────────┘
```

---

## Files Structure

### Core Implementation

| File | Purpose |
|------|---------|
| `lib/ash_scylla.ex` | Main module with version info |
| `lib/ash_scylla/data_layer.ex` | Main DataLayer implementation (`Ash.DataLayer` behaviour) |
| `lib/ash_scylla/repo.ex` | Repo configuration helper |
| `lib/ash_scylla/migration.ex` | CQL migration helpers |
| `lib/ash_scylla/error.ex` | Unified error handling interface |
| `lib/ash_scylla/error/scylla_error.ex` | ScyllaDB-specific error types |

### Data Layer Modules

| File | Purpose |
|------|---------|
| `lib/ash_scylla/data_layer/dsl.ex` | DSL extensions for ScyllaDB options |
| `lib/ash_scylla/data_layer/query_builder.ex` | Query building with filter-to-CQL conversion |
| `lib/ash_scylla/data_layer/batch.ex` | Batch operations (BATCH statements) |
| `lib/ash_scylla/data_layer/materialized_view.ex` | Materialized view support |
| `lib/ash_scylla/data_layer/pagination.ex` | Pagination helpers |

### Test Files

| File | Purpose |
|------|---------|
| `test/ash_scylla_test.exs` | Core DataLayer and DSL unit tests |
| `test/edge_cases_test.exs` | Edge cases for all modules |
| `test/error_edge_cases_test.exs` | Error handling edge cases |
| `test/ash_scylla/error_test.exs` | Error wrapping, retry, formatting |
| `test/ash_scylla/dsl_repo_migration_test.exs` | DSL, Repo, Migration tests |
| `test/ash_scylla/query_builder_test.exs` | QueryBuilder and Pagination |
| `test/ash_scylla/batch_materialized_view_test.exs` | Batch and MaterializedView |
| `test/scylla_integration_test.exs` | Integration tests with testcontainers |
| `test/support/test_repo.ex` | Test repo configuration |
| `test/support/test_resource.ex` | Basic test resource |
| `test/support/test_resource_with_indexes.ex` | Test resource with full DSL config |

---

## Features Implemented

### Core Ash.DataLayer Features ✅

| Feature | Status | Notes |
|---------|--------|-------|
| `:create` | ✅ | Create records with TTL support |
| `:read` | ✅ | Read with filtering and sorting |
| `:update` | ✅ | Update existing records |
| `:destroy` | ✅ | Delete records |
| `:filter` | ✅ | Filter queries with CQL WHERE conversion |
| `:sort` | ✅ | ORDER BY support |
| `:limit` | ✅ | LIMIT results |
| `:offset` | ✅ | OFFSET (use with caution) |
| `:select` | ✅ | Select specific fields |
| `:multitenancy` | ✅ | Keyspace-based multitenancy |
| `:bulk_create` | ✅ | Batch INSERT operations |

### ScyllaDB-Specific Features 🚀

#### 1. TTL (Time To Live)
Automatically expire data after a specified time:

```elixir
ash_scylla do
  ttl 3600  # Expire after 1 hour
end
```

- TTL applied to INSERT statements via `USING TTL` clause
- Integration tests for TTL expiration

#### 2. Consistency Levels
Configure read/write consistency per resource:

```elixir
ash_scylla do
  consistency :quorum  # :any, :one, :two, :three, :quorum, :all
end
```

- Consistency passed to repo queries
- Supports all ScyllaDB consistency levels

#### 3. Secondary Indexes
Query non-primary key columns:

```elixir
ash_scylla do
  secondary_index :email              # Single column
  secondary_index [:name, :age]        # Composite index
  secondary_index :status, name: "idx_status"
end
```

- QueryBuilder automatically checks for indexes
- Generates CQL CREATE INDEX statements
- Integration tests for secondary index queries

#### 4. Materialized Views
Alternative query patterns with automatic view maintenance:

```elixir
ash_scylla do
  materialized_view :users_by_email,
    primary_key: [:email, :id],
    include_columns: [:name, :age],
    clustering_order: [id: :desc]
end
```

- Automatic CQL generation for CREATE MATERIALIZED VIEW
- Support for clustering order and custom WHERE clauses
- Integration tests for materialized view queries

#### 5. Batch Operations
Reduce network round-trips with BATCH statements:

```elixir
# Bulk create (uses BATCH internally)
{:ok, users} = user_data_list
  |> Ash.bulk_create(MyApp.User, :create)
```

- `AshScylla.DataLayer.Batch` module
- Supports BATCH INSERT, UPDATE, DELETE
- Integrated with `bulk_create/3`

#### 6. Query Building
Convert Ash queries to optimized CQL:

```elixir
# Builds CQL like:
# SELECT id, name, email FROM users WHERE age > ? AND status = ? ALLOW FILTERING
```

- `QueryBuilder.build_optimized_query/1` - Converts DataLayer struct to CQL
- `QueryBuilder.filter_to_cql/1` - Converts Ash filters to CQL WHERE
- Supports operators: `=`, `!=`, `>`, `>=`, `<`, `<=`, `IN`
- Proper parameter binding with `?` placeholders

---

## Data Layer Query Struct

The DataLayer uses a struct to hold query state:

```elixir
defstruct [
  :resource,
  :repo,
  :table,
  filters: [],
  sorts: [],
  limit: nil,
  offset: nil,
  select: nil,
  tenant: nil
]
```

This struct is passed through the query building pipeline and converted to CQL at execution time.

---

## Error Handling

AshScylla includes comprehensive error handling:

### Error Types

| Error Type | When It Occurs | Suggestion |
|------------|---------------|------------|
| `syntax_error` | Invalid CQL syntax | Check CQL syntax |
| `schema_error` | Table/column not found | Run migrations, verify table names |
| `query_error` | Invalid queries | Check PRIMARY KEY, WHERE clauses |
| `overloaded` | ScyllaDB node overloaded | Increase timeout, reduce load |
| `timeout` | Query timeout | Increase `request_timeout` |
| `connection_*` | Connection issues | Check if ScyllaDB is running |
| `unauthorized` | Permission denied | Check credentials |
| `already_exists` | Resource conflict | Use IF NOT EXISTS |
| `not_found` | Resource missing | Verify table/keyspace exists |

### Retry Logic

```elixir
if AshScylla.Error.retryable?(error) do
  delay = AshScylla.Error.retry_delay(error)
  Process.sleep(delay)
  # retry the operation
end
```

Retry delays are tailored to error types:
- `:overloaded` → 1000ms
- `:connection_timeout` → 2000ms
- `:timeout` → 500ms
- Other errors → 500ms

---

## Dependencies

| Dependency | Version | Purpose |
|------------|---------|---------|
| `ash` | ~> 3.0 | Ash Framework |
| `exandra` | ~> 1.0 | Ecto adapter for ScyllaDB/Cassandra |
| `ecto` | ~> 3.13 | Ecto for database interaction |
| `ecto_sql` | ~> 3.13 | CQL migration helpers (dev/test only) |
| `testcontainer_ex` | ~> 0.3.1 | Integration test containers (dev/test only) |
| `benchee` | ~> 1.5 | Benchmarking (dev only) |
| `benchee_html` | ~> 1.0 | Benchmark HTML reports (dev only) |
| `credo` | ~> 1.7 | Static analysis (dev/test) |
| `dialyxir` | ~> 1.4 | Type checking (dev/test) |
| `ex_doc` | ~> 0.40 | Documentation generation (dev only) |

---

## Current Status

### ✅ Working Features

- Compiles successfully with no errors
- 200+ tests covering core, edge cases, and error handling
- Unit tests pass
- Integration tests with real ScyllaDB (using testcontainers)
- Full CRUD operations
- TTL and consistency level support
- Secondary indexes
- Materialized views
- Batch operations
- Bulk create support
- Comprehensive error handling

### ❌ Not Supported (ScyllaDB Limitations)

- JOINs (use denormalization or multiple queries)
- Complex aggregations (COUNT, SUM across partitions)
- ACID transactions across partitions (only lightweight transactions)
- Complex WHERE clauses without secondary indexes or materialized views
- OFFSET in CQL (requires token-based pagination)
- OR conditions in WHERE clause

---

## Running Tests

### Unit Tests

```bash
mix test
```

### Integration Tests

Integration tests use [testcontainers](https://github.com/testcontainers/testcontainers-elixir) to spin up a ScyllaDB instance automatically:

```bash
# Ensure Docker is running
docker --version

# Run integration tests
mix test test/scylla_integration_test.exs
```

Integration tests will:
1. Start a ScyllaDB container via testcontainers
2. Create keyspace, tables, indexes, and materialized views
3. Run CRUD operations
4. Test TTL expiration
5. Test secondary index queries
6. Test materialized view queries
7. Test batch operations

---

## Future Enhancements

1. **Token-based pagination** (instead of OFFSET)
2. **Lightweight transactions (LWT)** with IF clauses
3. **User Defined Types (UDT)** support
4. **Collection types** optimization (lists, sets, maps)
5. **Query caching** layer
6. **Automatic schema migrations** from Ash resources
7. **Prepared statement** caching
8. **Compression** support for large payloads
9. **Connection pooling** improvements
10. **Query optimization** hints

---

## Performance Considerations

### Connection Pooling

```elixir
config :my_app, MyApp.Repo,
  pool_size: 50,                # Connections per node
  pool_timeout: 15_000,
  request_timeout: 300_000,     # Query timeout (ms)
  connect_timeout: 10_000
```

**Pool Size Calculation:**
```
pool_size = (expected_concurrent_queries / number_of_nodes) * 1.5
```

### Query Optimization

- Use **primary key queries** when possible (most efficient)
- Create **secondary indexes** for non-primary key queries
- Use **materialized views** for alternative query patterns
- Avoid **ALLOW FILTERING** (not supported in this data layer)
- Use **BATCH statements** for multiple operations

---

## Example Usage

```elixir
# Configure Repo
defmodule MyApp.Repo do
  use Ecto.Repo,
    otp_app: :my_app,
    adapter: Exandra
end

# Configure Resource with all features
defmodule MyApp.User do
  use Ash.Resource,
    data_layer: AshScylla.DataLayer

  ash_scylla do
    table "users"
    keyspace "my_keyspace"
    consistency :quorum
    ttl 3600

    # Secondary indexes
    secondary_index :email
    secondary_index [:name, :age]

    # Materialized views
    materialized_view :users_by_email,
      primary_key: [:email, :id],
      include_columns: [:name, :age]
  end

  attributes do
    uuid_primary_key :id
    attribute :name, :string
    attribute :email, :string
    attribute :age, :integer
  end

  actions do
    defaults [:create, :read, :update, :destroy]
  end
end
```

---

## License

Apache License 2.0 - see [LICENSE](LICENSE) file for details.
