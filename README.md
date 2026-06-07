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

AshScylla enables you to use **ScyllaDB** or **Apache Cassandra** as a persistence layer for your [Ash Framework](https://ash-hq.org/) resources. It implements the `Ash.DataLayer` behaviour using [Exandra](https://github.com/lexhide/exandra) (an Ecto adapter for ScyllaDB/Cassandra) to communicate via CQL (Cassandra Query Language).

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
    {:ash_scylla, "~> 0.2.0"}
  ]
end
```

### Minimal Setup

**1. Configure a Repo:**

```elixir
# lib/my_app/repo.ex
defmodule MyApp.Repo do
  use Ecto.Repo,
    otp_app: :my_app,
    adapter: Exandra
end
```

**2. Configure the Repo in `config/config.exs`:**

```elixir
config :my_app, MyApp.Repo,
  nodes: ["127.0.0.1:9042"],
  keyspace: "my_app_dev",
  pool_size: 10
```

**3. Define a Resource:**

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

**4. Create a Domain:**

```elixir
# lib/my_app/domain.ex
defmodule MyApp.Domain do
  use Ash.Domain

  resources do
    resource MyApp.User
  end
end
```

**5. Create Keyspace and Tables:**

```elixir
# Create keyspace
MyApp.Repo.create_keyspace()

# Run migrations (if using Ecto migrations)
mix ecto.migrate
```

**6. Start Using It:**

```elixir
# Create
{:ok, user} = MyApp.User
  |> Ash.Changeset.for_create(:create, %{name: "John", email: "john@example.com"})
  |> Ash.create()

# Read
users = MyApp.User
  |> Ash.Query.filter(email == "john@example.com")
  |> Ash.read()

# Update
{:ok, updated} = user
  |> Ash.Changeset.for_update(:update, %{name: "John Doe"})
  |> Ash.update()

# Delete
:ok = user |> Ash.destroy()
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
| Sort | ✅ | ORDER BY support |
| Limit/Offset | ✅ | Pagination (see [limitations](#limitations)) |
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
  pool_timeout: 15_000,
  request_timeout: 300_000,                     # Query timeout (ms)
  connect_timeout: 10_000
```

**Pool Size Guidelines:**
- Development: 5-10
- Production: 25-100 (based on concurrent queries)

---

## Limitations

Since ScyllaDB/Cassandra is a NoSQL wide-column store, some features are not supported:

| Limitation | Reason | Workaround |
|------------|--------|------------|
| **No JOINs** | No relational joins | Denormalize or application-side joins |
| **No complex aggregations** | No GROUP BY, COUNT across partitions | Materialized views or custom aggregation |
| **No ACID transactions** | Only lightweight transactions (LWT) | Use LWT for single-partition operations |
| **No complex WHERE clauses** | Without indexes, only PK queries | Create secondary indexes or materialized views |
| **No OR conditions** | CQL limitation | Multiple queries or UNION-like patterns |
| **No foreign keys** | No relational integrity | Application-level validation |
| **OFFSET inefficiency** | Token-based pagination preferred | Use token-based pagination |

---

## Documentation

For detailed documentation, see:

- **[Usage Guide](USAGE_GUIDE.md)** - Comprehensive guide with examples
- **[Implementation Summary](IMPLEMENTATION_SUMMARY.md)** - Technical details
- **[Error Handling](ERROR_HANDLING.md)** - Error types and handling strategies
- **[API Documentation](https://hexdocs.pm/ash_scylla)** - Module documentation (when published)

### Quick Links

- [Secondary Indexes](USAGE_GUIDE.md#secondary-indexes)
- [Materialized Views](USAGE_GUIDE.md#materialized-views)
- [Batch Operations](USAGE_GUIDE.md#batch-operations)
- [Consistency Levels](USAGE_GUIDE.md#consistency-levels)
- [TTL Support](USAGE_GUIDE.md#ttl-time-to-live)
- [Performance Optimization](USAGE_GUIDE.md#performance-optimization)

---

## Testing

Run the test suite:

```bash
# Unit tests (no ScyllaDB required)
mix test --exclude integration

# All tests including integration (requires Docker for testcontainers)
mix test

# Integration tests only
mix test test/scylla_integration_test.exs
```

### Test Structure

| File | Description |
|------|-------------|
| `test/ash_scylla_test.exs` | Core DataLayer and DSL unit tests |
| `test/edge_cases_test.exs` | Edge cases for QueryBuilder, Batch, Pagination, MaterializedView, Migration |
| `test/error_edge_cases_test.exs` | Comprehensive error handling edge cases |
| `test/ash_scylla/error_test.exs` | Error wrapping, retry logic, and formatting tests |
| `test/ash_scylla/dsl_repo_migration_test.exs` | DSL configuration, Repo, and Migration tests |
| `test/ash_scylla/query_builder_test.exs` | QueryBuilder and Pagination unit tests |
| `test/ash_scylla/batch_materialized_view_test.exs` | Batch operations and MaterializedView tests |
| `test/integration_test.exs` | Integration test placeholder |
| `test/scylla_integration_test.exs` | Full integration tests with testcontainers |

Integration tests use [testcontainers](https://github.com/testcontainers/testcontainers-elixir) to spin up a ScyllaDB instance automatically.

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

# Start ScyllaDB via Docker (for integration tests)
docker run -p 9042:9042 scylladb/scylla:latest

# Run tests
mix test
```

---

## License

This project is licensed under the **Apache License 2.0** - see the [LICENSE](LICENSE) file for details.

---

## Acknowledgments

- [Ash Framework](https://ash-hq.org/) - The Elixir framework this data layer integrates with
- [Exandra](https://github.com/lexhide/exandra) - Ecto adapter for ScyllaDB/Cassandra
- [ScyllaDB](https://www.scylladb.com/) - High-performance NoSQL database

---

<p align="center">
  Made with ❤️ for the Elixir and Ash communities
</p>
