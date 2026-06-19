
[![Hex.pm](https://img.shields.io/hexpm/v/ash_scylla.svg)](https://hex.pm/packages/ash_scylla)

> **Note:** This library is under active development and the API may change.

# AshScylla

<p align="center">
  <strong>An Ash Framework data layer for ScyllaDB/Apache Cassandra</strong>
</p>

<p align="center">
  <a href="#quick-start">Quick Start</a> •
  <a href="#features">Features</a> •
  <a href="#documentation">Documentation</a> •
  <a href="#contributing">Contributing</a> •
  <a href="#license">License</a>
</p>

---

## Overview

AshScylla enables you to use **ScyllaDB** or **Apache Cassandra** as a persistence layer for your [Ash Framework](https://ash-hq.org/) resources. It implements the `Ash.DataLayer` behaviour using [Xandra](https://github.com/whatyouhide/xandra) (a native Elixir CQL driver) to communicate via CQL (Cassandra Query Language).

### Key Benefits

- **Seamless Ash Integration**: Use familiar Ash resources, actions, and queries
- **ScyllaDB Performance**: Leverage ScyllaDB's high-performance, low-latency architecture
- **Cassandra Compatibility**: Works with Apache Cassandra and ScyllaDB
- **Rich Feature Set**: TTL, consistency levels, secondary indexes, materialized views, batch operations

---

## Quick Start

### Prerequisites

- Elixir 1.17+
- Running ScyllaDB or Cassandra instance
- Basic knowledge of Ash Framework

### Installation

Add `ash_scylla` to your dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:ash_scylla, "~> 0.7.0"}
  ]
end
```

### Minimal Setup

**1. Configure a Repo:**

```elixir
# lib/my_app/repo.ex
defmodule MyApp.Repo do
  use AshScylla.Repo,
    otp_app: :my_app
end
```

**2. Configure the Repo in `config/config.exs`:**

```elixir
config :my_app, MyApp.Repo,
  nodes: ["127.0.0.1:9042"],
  keyspace: "my_app_dev",
  pool_size: 10
```

**3. Add the Repo to your supervision tree:**

```elixir
# lib/my_app/application.ex
children = [
  MyApp.Repo,
  # ...
]
```

**4. Generate a Resource Template:**

```bash
# Simple resource
mix ash_scylla.new_template User name:string, email:string

# Resource with domain (auto-prefixes module name)
mix ash_scylla.new_template User name:string --domain MyApp.Domain

# Resource with fully-qualified module name
mix ash_scylla.new_template User name:string --resource MyApp.Domain.User
```

This creates `lib/my_app/resources/user.ex` with a starter template. Or define it manually:

```elixir
# lib/my_app/resources/user.ex
defmodule MyApp.User do
  use Ash.Resource,
    data_layer: AshScylla.DataLayer,
    repo: MyApp.Repo

  attributes do
    uuid_primary_key :id
    attribute :name, :string
    attribute :email, :string
  end

  actions do
    defaults [:create, :read, :update, :destroy]
  end
end
```

**5. Create a Domain:**

```elixir
# lib/my_app/domain.ex
defmodule MyApp.Domain do
  use Ash.Domain

  resources do
    resource MyApp.User
  end
end
```

**6. Create Keyspace and Tables:**

```elixir
# Create keyspace (using the mix task)
mix ash_scylla.setup

# Or programmatically
MyApp.Repo.create_keyspace()

# Run migrations (includes schema files from priv/migrations)
mix ash_scylla.migrate

# Or run only schema files
mix ash_scylla.migrate --schemas-only

# Or run resource migrations only (skip schema files)
mix ash_scylla.migrate --resource MyApp.User
```

**6a. Generate Schema Migrations from Ash DSL:**

```bash
# Auto-generate schema file from all AshScylla resources
mix ash_scylla.gen --dev

# Generate with a specific schema module name
mix ash_scylla.gen AddUserTable

# Generate for a specific resource only
mix ash_scylla.gen --resource MyApp.User
```

This scans your project for Ash resources using `AshScylla.DataLayer` and produces
a `priv/migrations/<timestamp>_schema.ex` file containing `CREATE TABLE` and
`CREATE INDEX` CQL statements derived from each resource's attributes and
secondary indexes.

Schema migration files in `priv/migrations` use `AshScylla.Schema` and implement
`change/0` to return a list of CQL statements. They are executed before
resource-driven migrations when running `mix ash_scylla.migrate`.

**7. Start Using It:**

```elixir
# Create
{:ok, user} = Ash.create(MyApp.User, %{name: "John", email: "john@example.com"})

# Read
users = MyApp.User
  |> Ash.Query.filter(email == "john@example.com")
  |> Ash.read!()

# Update
{:ok, updated} = user
  |> Ash.Changeset.for_update(:update, %{name: "John Doe"})
  |> Ash.update()

# Delete
:ok = Ash.destroy(user)
```

Or using the domain directly:

```elixir
# Create via domain
{:ok, user} = MyApp.Domain.create_user(%{name: "John", email: "john@example.com"})

# Read via domain
users = MyApp.Domain.read_users!()
```

---

## Features

### Core Ash Features ✅

| Feature | Status | Description |
|---------|--------|-------------|
| Create | ✅ | Insert records with TTL support |
| Read | ✅ | Query with filtering and sorting |
| Update | ✅ | Update existing records |
| Destroy | ✅ | Delete records |
| Filter | ✅ | Powerful filter syntax with CQL WHERE conversion |
| Sort | ⚠️ | ORDER BY on clustering columns only (within a partition) |
| Keyset pagination | ✅ | Token-based pagination via paging_state (preferred over OFFSET) |
| Limit | ✅ | LIMIT is natively supported |
| Offset | ⚠️ | Not natively supported in ScyllaDB; results silently truncated. Use keyset pagination instead. |
| Select | ✅ | Select specific fields |
| Multitenancy | ✅ | Keyspace-based multitenancy |
| Bulk Create | ✅ | Batch INSERT operations |

### ScyllaDB-Specific Features 🚀

#### **TTL (Time To Live)**
Automatically expire data after a specified time:

```elixir
defmodule MyApp.Session do
  use Ash.Resource,
    data_layer: AshScylla.DataLayer

  ash_scylla do
    ttl 3600  # Expire after 1 hour
  end
end
```

#### **Consistency Levels**
Configure read/write consistency per resource:

```elixir
ash_scylla do
  consistency :quorum  # :any, :one, :two, :three, :quorum, :all, :local_quorum
end
```

#### **Secondary Indexes**
Query non-primary key columns efficiently:

```elixir
ash_scylla do
  secondary_index :email          # Single column
  secondary_index [:name, :age]   # Composite index
end
```

#### **Materialized Views**
Create alternative query patterns with automatic view maintenance:

```elixir
ash_scylla do
  materialized_view :users_by_email,
    primary_key: [:email, :id],
    include_columns: [:name, :age]
end
```

#### **Batch Operations**
Reduce network round-trips with BATCH statements:

```elixir
# Bulk create (uses BATCH internally)
{:ok, users} = user_data_list
  |> Ash.bulk_create(MyApp.User, :create)

# Async partition-aware batching for large datasets
AshScylla.DataLayer.Batch.batch_insert_async(repo, statements, resource: MyApp.User, max_concurrency: 8)
```

#### **Token-Based Pagination**
Efficient pagination without OFFSET:

```elixir
ash_scylla do
  pagination :token  # Use token-based pagination instead of OFFSET
end
```

#### **Per-Action Consistency**
Configure consistency levels per action:

```elixir
ash_scylla do
  consistency :quorum              # Default consistency
  per_action_consistency read: :one, create: :quorum  # Per-action overrides
end
```

---

## Data Modeling Best Practices

ScyllaDB is a wide-column store optimized for specific query patterns. Follow these principles:

### 1. Query-First Design 🎯

Design your tables around your queries, not the other way around:

```elixir
# Good: Partition key supports your main query
defmodule MyApp.User do
  attributes do
    attribute :email, :string, primary_key?: true  # Partition key
    attribute :name, :string
  end
end

# Query by partition key (efficient)
MyApp.User
  |> Ash.Query.filter(email == "user@example.com")
  |> Ash.read_one()
```

### 2. Denormalization is Normal 📦

Duplicate data across tables to support different query patterns:

```elixir
# Table for querying posts by author
defmodule MyApp.PostByAuthor do
  attributes do
    attribute :author_id, :uuid, primary_key?: true
    attribute :post_id, :uuid, primary_key?: true
    attribute :title, :string
    attribute :content, :string
  end
end

# Table for querying posts by date
defmodule MyApp.PostByDate do
  attributes do
    attribute :date, :date, primary_key?: true
    attribute :post_id, :uuid, primary_key?: true
    attribute :title, :string
    attribute :author_name, :string  # Denormalized
  end
end
```

### 3. Choose Partition Keys Wisely 🔑

- **High cardinality**: Distribute data evenly across nodes
- **Query patterns**: Support your most common queries
- **Avoid hotspots**: Don't use low-cardinality partition keys

```elixir
# Good: User ID has high cardinality
attribute :user_id, :uuid, primary_key?: true

# Avoid: Status has low cardinality (creates hotspots)
attribute :status, :string, primary_key?: true  # Don't do this
```

---

## Configuration

### Resource Configuration

```elixir
defmodule MyApp.User do
  use Ash.Resource,
    data_layer: AshScylla.DataLayer

  ash_scylla do
    table "users"                    # Override table name
    keyspace "custom_keyspace"        # Override keyspace
    consistency :quorum               # Consistency level
    ttl 3600                          # Default TTL (seconds)

    # Secondary indexes
    secondary_index :email
    secondary_index [:name, :age]

    # Materialized views
    materialized_view :users_by_email,
      primary_key: [:email, :id],
      include_columns: [:name, :age]
  end
end
```

### Repo Configuration

```elixir
config :my_app, MyApp.Repo,
  nodes: ["scylla-1:9042", "scylla-2:9042"],  # Cluster nodes
  keyspace: "my_app_prod",
  pool_size: 50,                                # Connections per node
  request_timeout: 300_000,                     # Query timeout (ms)
  connect_timeout: 10_000
```

**Pool Size Guidelines:**
- Development: 5-10
- Production: 25-100 (based on concurrent queries)

ScyllaDB works best with a connections-per-shard approach:
`pool_size = num_nodes * num_cores_per_node`

---

## Limitations

Since ScyllaDB/Cassandra is a NoSQL wide-column store, some features are not supported:

| Limitation | Reason | Workaround |
|------------|--------|------------|
| **No JOINs** | No relational joins | Denormalize or application-side joins |
| **No complex aggregations** | No GROUP BY, COUNT across partitions | Materialized views or custom aggregation |
| **No ACID transactions** | Only lightweight transactions (LWT) | Use LWT for single-partition operations |
| **Limited WHERE clauses** | Without indexes, only PK queries are efficient; filtering on non-indexed columns raises errors | Create secondary indexes or materialized views for non-PK query patterns |
| **No OR conditions** | CQL limitation | Multiple queries or UNION-like patterns |
| **No foreign keys** | No relational integrity | Application-level validation |
| **OFFSET not supported** | ScyllaDB has no native OFFSET; it would require full table scan | Use keyset pagination with `pagination :token`. The data layer silently drops OFFSET to prevent performance disasters. |

---

## Observability

### Telemetry

AshScylla emits standard `:telemetry` events for all query and batch operations,
enabling integration with LiveDashboard, Datadog, OpenTelemetry, and other
observability tools.

**Query events:**
- `[:ash_scylla, :query, :start]` - Query begins execution
- `[:ash_scylla, :query, :stop]` - Query finishes successfully
- `[:ash_scylla, :query, :exception]` - Query raises an error

**Batch events:**
- `[:ash_scylla, :batch, :start]` - Batch operation begins
- `[:ash_scylla, :batch, :stop]` - Batch operation finishes

**Attaching a handler:**

```elixir
:telemetry.attach(
  "ash_scylla-logger",
  [:ash_scylla, :query, :stop],
  &MyApp.Telemetry.handle_event/4,
  nil
)
```

### Prepared Statement Caching

For high-throughput workloads, enable the prepared statement cache to eliminate
repeated query parsing overhead on ScyllaDB:

```elixir
# In your supervision tree
children = [
  AshScylla.PreparedStatementCache,
  # ... other children
]
```

---

## Documentation

For detailed documentation, see:

- **[Usage Guide](guides/USAGE_GUIDE.md)** - Comprehensive guide with examples (resource generation, domain flags, CRUD, querying, migrations)
- **[Changelog](guides/CHANGELOG.md)** - Version history and release notes
- **[Development Guide](guides/DEV_GUIDE.md)** - Dev container setup and development workflow
- **[Production Guide](guides/PRODUCTION_GUIDE.md)** - Multi-node cluster deployment and operations
- **[Implementation Summary](guides/IMPLEMENTATION_SUMMARY.md)** - Technical details
- **[Error Handling](guides/ERROR_HANDLING.md)** - Error types and handling strategies
- **[API Documentation](https://hexdocs.pm/ash_scylla)** - Module documentation (when published)

### Quick Links

- [Secondary Indexes](guides/USAGE_GUIDE.md#secondary-indexes)
- [Materialized Views](guides/USAGE_GUIDE.md#materialized-views)
- [Batch Operations](guides/USAGE_GUIDE.md#batch-operations)
- [Consistency Levels](guides/USAGE_GUIDE.md#consistency-levels)
- [TTL Support](guides/USAGE_GUIDE.md#ttl-time-to-live)
- [Performance Optimization](guides/USAGE_GUIDE.md#performance-optimization)

---

## Testing

Run the test suite:

```bash
# All tests (unit + integration; requires Podman for testcontainers)
mix test

# Unit tests only (no ScyllaDB required)
mix test --exclude integration

# Integration tests only (requires Podman)
mix test --only integration

# CI pipeline (unit tests + credo)
mix test.ci
```

### Test Structure

Tests are organized by feature domain under `test/unit/` and `test/integration/`.

#### Unit Tests (`test/unit/`)

No ScyllaDB instance required. All tests use fake/mock repos or inline resources.

| Directory | Feature |
|-----------|---------|
| `unit/autogenerate/` | UUID autogeneration |
| `unit/batch/` | Batch operations, bulk create, partition grouping |
| `unit/connection/` | Xandra connection, prepared statement cache |
| `unit/data_layer/` | CRUD, callbacks, feature flags, upsert |
| `unit/dsl/` | DSL options, resource definition, repo/migration |
| `unit/error/` | Error handling, edge cases |
| `unit/filter/` | Filter validation, edge cases |
| `unit/identifier/` | Identifier sanitization consistency |
| `unit/mix_helpers/` | Mix helper utilities |
| `unit/query/` | Query builder, optimizer, edge cases |
| `unit/schema/` | Schema behaviour, schema loader |
| `unit/security/` | CQL injection prevention |
| `unit/source_cache/` | Table name resolution, caching |
| `unit/telemetry/` | Span/batch_span telemetry |
| `unit/types/` | Type conversion, type pipeline |
| `unit/workload/` | Concurrent workload stress tests |

#### Integration Tests (`test/integration/`)

Require a running ScyllaDB instance. Can use either testcontainers (Podman) or a direct connection.

| File | Description | Multi-node? |
|------|-------------|-------------|
| `integration/scylla_integration_test.exs` | Full ScyllaDB integration (CRUD, secondary indexes, clustering keys, consistency levels, concurrent operations) | No |
| `integration/data_layer_integration_test.exs` | DataLayer pipeline against real ScyllaDB | No |
| `integration/pipeline_integration_test.exs` | DSL → DataLayer → QueryBuilder → ScyllaDB end-to-end | No |
| `integration/basic_integration_test.exs` | Basic integration placeholder | No |
| `integration/cluster_integration_test.exs` | Multi-node cluster topology, cluster formation, cross-node reads/writes | **Yes** |

### Running Integration Tests With a Local ScyllaDB

Integration tests can run against a pre-existing ScyllaDB instance — no container runtime needed. Set the `SCYLLA_DIRECT` environment variable and optionally override the host/port:

```bash
# Connect to ScyllaDB at localhost:9042 (defaults)
SCYLLA_DIRECT=1 mix test --only integration

# Connect to a remote ScyllaDB instance
SCYLLA_DIRECT=1 SCYLLA_HOST=db.example.com SCYLLA_PORT=9042 mix test --only integration

# Run a specific integration test file
SCYLLA_DIRECT=1 mix test test/integration/scylla_integration_test.exs
SCYLLA_DIRECT=1 mix test test/integration/data_layer_integration_test.exs
```

> **Note:** The cluster integration test (`cluster_integration_test.exs`) is automatically skipped when `SCYLLA_DIRECT` is set. It requires multi-node container orchestration and cannot run against a single ScyllaDB instance.

#### ScyllaDB Configuration for Direct Connection

| Env Var | Default | Description |
|---------|---------|-------------|
| `SCYLLA_DIRECT` | — | Set to `1` to enable direct connection mode |
| `SCYLLA_HOST` | `127.0.0.1` | ScyllaDB hostname or IP address |
| `SCYLLA_PORT` | `9042` | ScyllaDB CQL transport port |

If you have authentication enabled on your ScyllaDB cluster, configure the repo in your `config/test.exs`:

```elixir
config :my_app, MyApp.Repo,
  nodes: ["db.example.com:9042"],
  keyspace: "my_app_test",
  authentication: {Xandra.Auth.Password, username: "cassandra", password: "cassandra"}
```

### Running Cluster Integration Tests

The cluster integration test supports two modes:

#### Container Mode (default)

Spins up a 3-node ScyllaDB cluster using testcontainers (Podman). Tests cluster formation, cross-node reads/writes, and concurrent operations.

```bash
# Run cluster integration test (requires Podman)
mix test test/integration/cluster_integration_test.exs --only integration

# Run with increased timeout (first run may take longer to pull images)
MIX_ENV=test mix test test/integration/cluster_integration_test.exs --only integration --timeout 300_000
```

**Prerequisites:**
- Podman installed and running
- `testcontainer_ex` will automatically pull the `scylladb/scylla:latest` image
- Sufficient resources: 3 ScyllaDB nodes × ~1 GB RAM each

#### Cluster Mode (multi-node)

Connects to an already-running multi-node ScyllaDB cluster. Requires `SCYLLA_NODES` with comma-separated `host:port` pairs.

```bash
# Connect to a multi-node cluster
TEST_CLUSTER=true SCYLLA_NODES="node1:9042,node2:9042,node3:9042" \
  mix test test/integration/cluster_integration_test.exs --only integration
```

#### Single-Node Direct Mode

Connects to a single ScyllaDB instance at `SCYLLA_HOST:SCYLLA_PORT`.

```bash
# Connect to a single-node at localhost:9042 (defaults)
SCYLLA_DIRECT=1 mix test test/integration/cluster_integration_test.exs --only integration

# Connect to a single-node with custom host/port
SCYLLA_DIRECT=1 SCYLLA_HOST=db.example.com SCYLLA_PORT=9042 \
  mix test test/integration/cluster_integration_test.exs --only integration
```

**Configuration:**

| Env Var | Default | Description |
|---------|---------|-------------|
| `TEST_CLUSTER` | `false` | Set to `true` for multi-node cluster mode |
| `SCYLLA_DIRECT` | — | Set to `1` for single-node direct connection |
| `SCYLLA_NODES` | — | Comma-separated `host:port` pairs (cluster mode) |
| `SCYLLA_HOST` | `127.0.0.1` | Single host (single-node mode) |
| `SCYLLA_PORT` | `9042` | Single port (single-node mode) |

> **Note:** `TEST_CLUSTER=true` connects to each node directly for concurrent multi-node operations. `SCYLLA_DIRECT=1` without `TEST_CLUSTER` connects to a single node only.

**What it tests:**
- Cluster keyspace creation with `replication_factor: 3`
- Table creation across the cluster
- CRUD operations against the cluster
- Secondary index queries across nodes
- Clustering key queries with `CLUSTERING ORDER BY`
- Concurrent inserts and reads across multiple nodes
- Consistency levels (`LOCAL_QUORUM`)

Integration tests use [testcontainer_ex](https://github.com/manhvu/testcontainers-elixir) to spin up ScyllaDB instances automatically via Podman (container mode).

---

## Contributing

Contributions are welcome! Here's how to get started:

1. **Fork** the repository
2. **Clone** your fork: `git clone https://github.com/your-username/ash_scylla.git`
3. **Create** a feature branch: `git checkout -b feature/my-feature`
4. **Make** your changes
5. **Run** tests: `mix test`
6. **Commit** your changes: `git commit -am 'Add some feature'`
7. **Push** to the branch: `git push origin feature/my-feature`
8. **Create** a Pull Request

### Development Setup

```bash
# Install dependencies
mix deps.get

# Start ScyllaDB via Podman Compose (includes health checks)
podman-compose -f podman-compose.yml up -d

# Or start ScyllaDB manually
podman run -p 9042:9042 docker.io/scylladb/scylla:latest

# Run tests
mix test
```

### Dev Container

A `.devcontainer/devcontainer.json` is provided for VS Code Dev Containers.
It brings up both Elixir and ScyllaDB together via Podman Compose.

### Integration Test

```Elixir
export CONTAINER_ENGINE=podman
export CONTAINER_ENGINE_HOST='unix:///private/var/folders/76/xt0kl9zj2ks6wsl1q13513h40000gn/T/podman/podman-machine-default-api.sock'
MIX_ENV=test mix test.integration
```

Note: For socket host need to check in your local machine. Auto detect feature will be added in the future.


---

## License

This project is licensed under the **Apache License 2.0** - see the [LICENSE](LICENSE) file for details.

---

## Acknowledgments

- [Ash Framework](https://ash-hq.org/) - The Elixir framework this data layer integrates with
- [Xandra](https://github.com/whatyouhide/xandra) - Native Elixir CQL driver for ScyllaDB/Cassandra
- [ScyllaDB](https://www.scylladb.com/) - High-performance NoSQL database

---

<p align="center">
  Made with ❤️ for the Elixir and Ash communities
</p>
