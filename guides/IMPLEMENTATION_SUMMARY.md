# AshScylla Implementation Summary

> **Technical overview of the AshScylla data layer implementation**

---

## Overview

AshScylla is a comprehensive data layer for the Ash Framework that enables persistence with **ScyllaDB** or **Apache Cassandra**. It uses [Xandra](https://github.com/whatyouhide/xandra) (a native Elixir CQL driver) to communicate via CQL (Cassandra Query Language).

Current version: **0.13.1**

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
│                  AshScylla.Query                        │
│  • Owns the query struct                              │
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
│                    Xandra (direct)                      │
│  • Native Elixir CQL driver               │
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
| `lib/ash_scylla.ex` | Main module with `verify/2`, `migrate/2`, `create_keyspace/2`, `version/0` |
| `lib/ash_scylla/query.ex` | Query struct (moved from DataLayer) |
| `lib/ash_scylla/application.ex` | Application callback, creates `:ash_scylla_repo_cache` ETS table |
| `lib/ash_scylla/data_layer.ex` | Main DataLayer implementation (`Ash.DataLayer` behaviour) |
| `lib/ash_scylla/connection.ex` | GenServer wrapping Xandra connections |
| `lib/ash_scylla/repo.h` | Repo behaviour and `__using__` macro |
| `lib/ash_scylla/migrator.ex` | CQL schema migration runner via Xandra |
| `lib/ash_scylla/migration.ex` | CQL DDL generation helpers (CREATE TABLE, INDEX, TYPE) |
| `lib/ash_scylla/error.ex` | Unified error handling interface |
| `lib/ash_scylla/error/scylla_error.ex` | ScyllaDB-specific error types and categorization |
| `lib/ash_scylla/telemetry.ex` | Telemetry span helpers for queries and batches |
| `lib/ash_scylla/prepared_statement_cache.ex` | ETS-based prepared statement cache (GenServer) |
| `lib/ash_scylla/schema.ex` | Schema migration behaviour for `priv/migrations` |
| `lib/ash_scylla/schema_loader.ex` | Schema file discovery and loading |
| `lib/ash_scylla/resource_generator.ex` | Resource template generator |
| `lib/ash_scylla/identifier.ex` | CQL identifier sanitization |
| `lib/ash_scylla/mix_helpers.ex` | Shared Mix task helpers (resource/repo discovery) |
| `lib/ash_scylla/release.ex` | Release task helpers for production migrations |

### Data Layer Modules

| File | Purpose |
|------|---------|
| `lib/ash_scylla/data_layer/dsl.ex` | `scylla` DSL macro and config accessors |
| `lib/ash_scylla/data_layer/secondary_index.ex` | SecondaryIndex struct and parsing |
| `lib/ash_scylla/data_layer/query_builder.ex` | Query building with filter-to-CQL conversion |
| `lib/ash_scylla/data_layer/query_optimizer.ex` | Query optimization hints (consistency, timeout, paging) |
| `lib/ash_scylla/data_layer/filter_validator.ex` | Filter validation (prevents ALLOW FILTERING anti-pattern) |
| `lib/ash_scylla/data_layer/batch.ex` | Batch operations (BATCH INSERT/UPDATE/DELETE, async partition-aware) |
| `lib/ash_scylla/data_layer/pagination.ex` | Token-based pagination via Xandra paging state |
| `lib/ash_scylla/data_layer/materialized_view.ex` | Materialized view CQL generation |
| `lib/ash_scylla/data_layer/schema_migration.ex` | Automatic schema diff and migration |
| `lib/ash_scylla/data_layer/types.ex` | Canonical Ash type → CQL type mapping |
| `lib/ash_scylla/data_layer/collection.ex` | Collection type (LIST, SET, MAP) encoding/CQL |
| `lib/ash_scylla/data_layer/compression.ex` | Application-level compression for large payloads |
| `lib/ash_scylla/data_layer/udt.ex` | User Defined Type encoding/decoding |

### Mix Tasks

| File | Purpose |
|------|---------|
| `lib/mix/tasks/ash_scylla.gen.ex` | Generate schema migration files from Ash DSL |
| `lib/mix/tasks/ash_scylla.new_template.ex` | Generate Ash resource templates |
| `lib/mix/tasks/ash_scylla.migrate.ex` | Run schema migrations |
| `lib/mix/tasks/ash_scylla.setup.ex` | Create ScyllaDB keyspace |
| `lib/mix/tasks/ash_scylla.gen.repo.ex` | Generate AshScylla Repo module |

### Test Files

| File | Purpose |
|------|---------|
| `test/test_helper.exs` | Test setup (ETS, support files, ExUnit) |
| `test/support/test_repo.ex` | Test repo (`AshScylla.TestRepo`) |
| `test/support/test_resource.ex` | Basic test resource |
| `test/support/test_resource_with_indexes.ex` | Test resource with full DSL config |
| `test/support/test_domain.ex` | Test domain |
| `test/support/schema_fixtures.ex` | Schema migration fixtures |
| `test/support/scylla_container.ex` | ScyllaDB container management |
| `test/support/container_engine.ex` | Container engine (Podman) integration |

---

## Features Implemented

### Core Ash.DataLayer Features

| Feature | Status | Notes |
|---------|--------|-------|
| `:create` | ✅ | Create records with TTL support |
| `:read` | ✅ | Read with filtering |
| `:update` | ✅ | Update existing records |
| `:destroy` | ✅ | Delete records |
| `:filter` | ✅ | Filter queries with CQL WHERE conversion |
| `:sort` / `{:sort, _}` | ✅ | ORDER BY on clustering columns (within partition) |
| `:limit` | ✅ | LIMIT is natively supported |
| `:offset` | ❌ | ScyllaDB has no OFFSET — use keyset pagination |
| `:select` | ✅ | Select specific fields |
| `:multitenancy` | ✅ | Keyspace-based multitenancy |
| `:bulk_create` | ✅ | Batch INSERT operations |
| `:upsert` | ✅ | Upsert records (INSERT with LWT) |
| `:update_query` | ✅ | Bulk update via filtered queries |
| `:destroy_query` | ✅ | Bulk delete via filtered queries |
| `:distinct` | ✅ | DISTINCT on partition key columns |
| `:keyset` | ✅ | Token-based keyset pagination (default mode) |
| `:boolean_filter` | ✅ | OR filter rewriting to IN where possible |
| `:nested_expressions` | ✅ | Nested filter expressions |
| `{:filter_expr, _}` | ✅ | Filter expression support |
| `:composite_primary_key` | ✅ | Composite PK support |
| `:changeset_filter` | ✅ | Changeset-based filtering |
| `:calculate` | ✅ | In-memory calculations |
| `:action_select` | ✅ | Action-specific select |
| `:async_engine` | ✅ | Async engine support |
| `{:aggregate, :count}` | ✅ | Per-partition COUNT |
| `{:aggregate, :sum}` / `:avg` / `:min` / `:max` | ✅ | SUM, AVG, MIN, MAX aggregates |
| `{:query_aggregate, :count}` / `:sum` / `:avg` / `:min` / `:max` | ✅ | Query-level aggregates (`Ash.count/2`, etc.) |
| `{:aggregate_relationship, _}` | ✅ | Relationship aggregates via `belongs_to` (per-record subqueries) |
| `{:atomic, :update}` | ✅ | Atomic updates via LWT (IF clauses) |
| `{:atomic, :upsert}` | ✅ | Atomic upserts via LWT |
| `{:atomic, :create}` | ✅ | Atomic creates |
| `:transact` | ✅ | Transaction wrapper (no-op for CWT, function-based for LWT) |

### Features NOT Supported

| Feature | Reason |
|---------|--------|
| `:offset` | ScyllaDB has no OFFSET; use keyset pagination |
| `:expr_error` | Expression error handling not implemented |
| `:expression_calculation` | Expression calculations done in Elixir post-processing |
| `:expression_calculation_sort` | Not supported |
| `:aggregate_filter` | Aggregate filtering not supported |
| `:aggregate_sort` | Aggregate sorting not supported |
| `:bulk_create_with_partial_success` | Bulk create is all-or-nothing |
| `:update_many` | Update-many not implemented |
| `:composite_type` | Composite types not supported |
| `:through_relationship` | Through relationships not supported |
| `:bulk_upsert_return_skipped` | Not supported |
| `:distinct_sort` | Not supported |
| `{:combine, :union}` | No combination queries (UNION/INTERSECT) |
| `{:combine, :union_all}` | No combination queries |
| `{:combine, :intersection}` | No combination queries |
| `{:lock, :for_update}` | Locking is a no-op; use LWT for conditional operations |
| `{:join, _}` | No JOINs; use denormalization or multiple queries |
| `{:lateral_join, _}` | No lateral joins |
| `{:filter_relationship, _}` | Relationship filtering not supported |
| `{:exists, :unrelated}` | Exists queries not supported |
| `{:aggregate, :unrelated}` | Unrelated aggregates not supported |
| `{:aggregate, :first}` / `:list` / `:exists` / `:custom` | Only COUNT, SUM, AVG, MIN, MAX are supported |
| `:has_many` / `:many_to_many` relationship aggregates | Not yet implemented (use denormalization) |

### ScyllaDB-Specific Features

#### 1. TTL (Time To Live)
```elixir
scylla do
  ttl 3600  # Expire after 1 hour
end
```
- TTL applied to INSERT statements via `USING TTL` clause

#### 2. Consistency Levels
```elixir
scylla do
  consistency :quorum  # :any, :one, :two, :three, :quorum, :all, :local_quorum
end
```
- Supports all ScyllaDB consistency levels

#### 3. Secondary Indexes
```elixir
scylla do
  secondary_index :email              # Single column
  secondary_index [:name, :age]        # Composite index (multi-column)
  secondary_index :status, name: "idx_status"
end
```
- ScyllaDB OSS doesn't support multi-column secondary indexes — generates separate single-column indexes

#### 4. Materialized Views
```elixir
scylla do
    primary_key: [:email, :id],
    include_columns: [:name, :age],
    clustering_order: [id: :desc]
end
```
- Automatic CQL generation for CREATE MATERIALIZED VIEW

#### 5. Batch Operations
```elixir
# Synchronous batch
AshScylla.DataLayer.Batch.batch_insert(repo, statements)

# Async partition-aware batching
AshScylla.DataLayer.Batch.batch_insert_async(repo, statements, max_concurrency: 8)
```
- Supports BATCH INSERT, UPDATE, DELETE
- Async mode groups by partition key for safety

#### 6. Token-Based Pagination
```elixir
# First page
{:ok, records, next_token} =
  AshScylla.DataLayer.Pagination.fetch_page(repo, table, filters, nil, 10)

# Subsequent pages
{:ok, records, next_token} =
  AshScylla.DataLayer.Pagination.fetch_page(repo, table, filters, next_token, 10)
```
- Uses Xandra's native paging_state mechanism
- Default page size: 50, max: 1000

#### 7. Prepared Statement Caching
```elixir
children = [
  AshScylla.PreparedStatementCache,
  # ...
]
```
- GenServer + ETS cache
- Automatic prepared statement reuse
- Max 10,000 entries, cleanup every 5 minutes

#### 8. Per-Action Consistency
```elixir
scylla do
  consistency :quorum
  per_action_consistency read: :one, create: :quorum
end
```

#### 9. Lightweight Transactions (LWT)
```elixir
scylla do
  lwt true
end
```
- Enables `IF NOT EXISTS` on create, `IF` clauses on update

#### 10. Query Optimization
- Filter validation prevents ALLOW FILTERING anti-pattern
- In-memory sort compensation when ORDER BY is dropped due to secondary index scan
- Query optimizer hints (consistency, timeout, paging, speculative retry)

#### 11. Application-Level Compression
- Supports LZ4, Snappy, Deflate, Zstd
- Table-level compression CQL generation
- Transparent field-level compression

#### 12. User Defined Types (UDT)
- Full encoding/decoding for Xandra
- CQL generation for CREATE/ALTER/DROP TYPE

#### 13. Collection Types
- LIST, SET, MAP encoding for Xandra
- CONTAINS/CONTAINS KEY filter support
- Frozen collection support

---

## Data Layer Query Struct

```elixir
# AshScylla.Query struct (lib/ash_scylla/query.ex)
defstruct [
  :resource,
  :repo,
  :table,
  limit: nil,
  select: nil,
  distinct: nil,
  tenant: nil,
  context: %{},
  atomic: nil,
  upsert?: false,
  upsert_fields: [],
  upsert_identity: nil,
  keyset: nil,
  aggregates: [],
  group_by: nil,
  filters: [],
  sorts: []
]
```

---

## Error Handling

AshScylla provides structured error handling for ScyllaDB-specific errors:

### Error Types

| Error Type | When It Occurs | Retryable? |
|------------|---------------|------------|
| `:syntax_error` | Invalid CQL syntax | ❌ |
| `:query_error` | General query execution error | ❌ |
| `:schema_error` | Table/keyspace/column not found | ❌ |
| `:overloaded` | ScyllaDB node overloaded | ✅ |
| `:timeout` | Query timeout | ✅ |
| `:consistency_error` | Consistency level not met | ❌ |
| `:unauthorized` | Permission denied | ❌ |
| `:already_exists` | Resource conflict | ❌ |
| `:not_found` | Resource missing | ❌ |
| `:connection_timeout` | Connection timeout | ✅ |
| `:connection_closed` | Connection closed | ✅ |
| `:connection_error` | General connection error | ✅ |

### Using Error Handling

```elixir
case AshScylla.DataLayer.run_query(query, resource) do
  {:ok, results} ->
    {:ok, results}

  {:error, %AshScylla.Error.ScyllaError{} = error} ->
    Logger.error("Database error: #{AshScylla.Error.format_error(error)}")

    if AshScylla.Error.retryable?(error) do
      {:retry, error}
    else
      {:error, error}
    end
end
```

---

## Dependencies

| Dependency | Version | Purpose |
|------------|---------|---------|
| `ash` | ~> 3.0 | Ash Framework |
| `xandra` | ~> 0.19 | Native Elixir CQL driver |

Dev/test dependencies:

| Dependency | Version | Purpose |
|------------|---------|---------|
| `testcontainer_ex` | ~> 0.3.1 | Integration test containers |
| `benchee` | ~> 1.5 | Benchmarking |
| `benchee_html` | ~> 1.0 | Benchmark HTML reports |
| `credo` | ~> 1.7 | Static analysis |
| `dialyxir` | ~> 1.4 | Type checking |
| `ex_doc` | ~> 0.40 | Documentation generation |

---

## Current Status

### Working Features

- Compiles successfully with no errors
- 1000+ unit tests across 19 feature domains
- Integration tests with real ScyllaDB (via Podman/testcontainers)
- Full CRUD operations with TTL, consistency, LWT
- Secondary indexes, materialized views, UDTs
- Batch operations (sync + async partition-aware)
- Token-based pagination
- Prepared statement caching
- Comprehensive error handling with retry logic
- Telemetry integration
- Schema migration system (AshScylla.Schema)
- Resource template generation
- Compression and collection type support
- Aggregate support: COUNT, SUM, AVG, MIN, MAX (query + relationship aggregates)

### Not Supported (ScyllaDB Limitations)

- JOINs (use denormalization)
- Complex aggregations across partitions (only per-partition COUNT)
- ACID transactions across partitions (only lightweight transactions)
- ALLOW FILTERING (rejected at query-plan time — add secondary indexes instead)
- OR conditions in WHERE clause (rewritten to IN where possible)
- Foreign keys
- `has_many` / `many_to_many` relationship aggregates (use denormalization or materialized views)
- `:first`, `:list`, `:exists`, `:custom` aggregate kinds

---

## Running Tests

### Unit Tests

```bash
mix test --exclude integration
```

### Integration Tests

```bash
# With Podman container (default)
mix test --only integration

# Against local ScyllaDB
SCYLLA_DIRECT=1 mix test --only integration

# Cluster tests (3-node, requires Podman)
mix test test/integration/cluster_integration_test.exs --only integration

# Specific test file
mix test test/integration/scylla_integration_test.exs
mix test test/unit/data_layer/data_layer_crud_test.exs
```

### Coverage

```bash
mix test --exclude integration --cover
```

Generates `cover/index.html`.

---

## Example Usage

```elixir
# Configure Repo
defmodule MyApp.Repo do
  use AshScylla.Repo,
    otp_app: :my_app
end

# Configure Resource with all features
defmodule MyApp.User do
  use Ash.Resource,
    data_layer: AshScylla.DataLayer,
    domain: MyApp.Domain


  scylla do
    table "users"
    consistency :quorum
    ttl 3600
    lwt true

    secondary_index :email

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
