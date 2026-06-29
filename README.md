
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

Current version: **0.13.1**

### Key Benefits

- **Seamless Ash Integration**: Use familiar Ash resources, actions, and queries
- **ScyllaDB Performance**: Leverage ScyllaDB's high-performance, low-latency architecture
- **Cassandra Compatibility**: Works with Apache Cassandra and ScyllaDB
- **Rich Feature Set**: TTL, consistency levels, secondary indexes, materialized views, batch operations, lightweight transactions

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
    {:ash_scylla, "~> 0.13"}
  ]
end
```

### Minimal Setup

```elixir
# 1. Configure a Repo
defmodule MyApp.Repo do
  use AshScylla.Repo, otp_app: :my_app
end

# 2. Configure in config/config.exs
config :my_app, MyApp.Repo,
  nodes: ["127.0.0.1:9042"],
  keyspace: "my_app_dev",
  pool_size: 10

# 3. Add to your supervision tree
# lib/my_app/application.ex
children = [MyApp.Repo, ...]

# 4. Create a resource
defmodule MyApp.User do
  use Ash.Resource,
    data_layer: AshScylla.DataLayer,
    domain: MyApp.Domain

  ash_scylla do
    table "users"
    consistency :quorum
  end

  attributes do
    uuid_primary_key :id
    attribute :name, :string
    attribute :email, :string
  end

  actions do
    defaults [:create, :read, :update, :destroy]
  end
end

# 5. Create a Domain
defmodule MyApp.Domain do
  use Ash.Domain

  resources do
    resource MyApp.User
  end
end

# 6. Create keyspace and run migrations
# mix ash_scylla.setup
# mix ash_scylla.migrate

# 7. Use it
{:ok, user} = Ash.create(MyApp.User, %{name: "John", email: "john@example.com"})
users = MyApp.User |> Ash.read!()
```

For a complete step-by-step guide, see the **[Usage Guide](guides/USAGE_GUIDE.md)**.

---

## Features

### Core Ash Features

| Feature | Status | Description |
|---------|--------|-------------|
| Create | ✅ | Insert records with TTL support |
| Read | ✅ | Query with filtering and sorting |
| Update | ✅ | Update existing records |
| Destroy | ✅ | Delete records |
| Filter | ✅ | Powerful filter syntax with CQL WHERE conversion |
| Sort | ✅ | ORDER BY on clustering columns (within partition) |
| Keyset pagination | ✅ | Token-based pagination via paging_state (default mode) |
| Limit | ✅ | LIMIT is natively supported |
| Offset | ❌ | Raises error — use keyset pagination instead |
| Select | ✅ | Select specific fields |
| Multitenancy | ✅ | Keyspace-based multitenancy |
| Bulk Create | ✅ | Batch INSERT operations |
| Upsert | ✅ | INSERT with lightweight transactions (LWT) |
| Update Query | ✅ | Bulk update via filtered queries |
| Destroy Query | ✅ | Bulk delete via filtered queries |
| Distinct | ✅ | DISTINCT on partition key columns |
| Calculate | ✅ | In-memory calculations |
| Aggregate (count) | ✅ | Per-partition COUNT |

### ScyllaDB-Specific Features

| Feature | Description |
|---------|-------------|
| **TTL** | Auto-expire data after a specified time |
| **Consistency Levels** | Per-resource or per-action consistency (`:one`, `:quorum`, `:all`, etc.) |
| **Secondary Indexes** | Query non-primary key columns efficiently |
| **Materialized Views** | Alternative query patterns with automatic view maintenance |
| **Batch Operations** | BATCH INSERT/UPDATE/DELETE, including async partition-aware batching |
| **Token-Based Pagination** | Efficient pagination via Xandra's native paging_state |
| **Lightweight Transactions** | `IF NOT EXISTS` on create, `IF` clauses on update |
| **Compression** | Application-level compression (LZ4, Snappy, Deflate, Zstd) |
| **User Defined Types** | Full UDT encoding/decoding and CQL generation |
| **Collection Types** | LIST, SET, MAP with CONTAINS filter support |
| **Prepared Statement Caching** | ETS-based cache for high-throughput workloads |

---

## Configuration

### Resource Configuration

```elixir
defmodule MyApp.User do
  use Ash.Resource,
    data_layer: AshScylla.DataLayer,
    domain: MyApp.Domain

  ash_scylla do
    table "users"
    consistency :quorum
    ttl 3600
    lwt true

    secondary_index :email
    secondary_index [:name, :age]

    materialized_view :users_by_email,
      primary_key: [:email, :id],
      include_columns: [:name, :age]

    per_action_consistency read: :one, create: :quorum
  end
end
```

### Repo Configuration

```elixir
# Single-node
config :my_app, MyApp.Repo,
  nodes: ["127.0.0.1:9042"],
  keyspace: "my_app_dev"

# Multi-node cluster (all nodes must use the same port)
config :my_app, MyApp.Repo,
  nodes: ["scylla-1:9042", "scylla-2:9042", "scylla-3:9042"],
  keyspace: "my_app_prod",
  pool_size: 50
```

**Pool Size Formula:** `pool_size = num_nodes * num_cores_per_node`

---

## Limitations

| Limitation | Workaround |
|------------|------------|
| **No JOINs** | Denormalize or application-side joins |
| **No complex aggregations** | Materialized views or custom aggregation |
| **No ACID transactions** | Use LWT for single-partition operations |
| **Limited WHERE without indexes** | Create secondary indexes or materialized views |
| **No OFFSET** | Use keyset pagination (`data_layer_keyset_by_default?/0` returns `true`) |
| **Cluster requires same port** | Configure all nodes on the same port, or use single-node connection |

---

## Observability

### Telemetry

AshScylla emits standard `:telemetry` events for all query and batch operations:

```elixir
:telemetry.attach(
  "ash_scylla-logger",
  [:ash_scylla, :query, :stop],
  &MyApp.Telemetry.handle_event/4,
  nil
)
```

**Events:** `[:ash_scylla, :query, :start|stop|exception]`, `[:ash_scylla, :batch, :start|stop]`

### Prepared Statement Caching

```elixir
children = [
  AshScylla.PreparedStatementCache,
  # ...
]
```

---

## Documentation

| Document | Description |
|----------|-------------|
| **[Usage Guide](guides/USAGE_GUIDE.md)** | Comprehensive guide: setup, CRUD, querying, data modeling, migrations |
| **[Development Guide](guides/DEV_GUIDE.md)** | Dev container setup, testing, type mapping, CQL query building |
| **[Production Guide](guides/PRODUCTION_GUIDE.md)** | Multi-node cluster deployment, monitoring, backup, rolling upgrades |
| **[Implementation Summary](guides/IMPLEMENTATION_SUMMARY.md)** | Technical architecture and module reference |
| **[Error Handling](guides/ERROR_HANDLING.md)** | Error types, retry logic, common scenarios |
| **[Changelog](guides/CHANGELOG.md)** | Version history and release notes |
| **[API Documentation](https://hexdocs.pm/ash_scylla)** | Module documentation (when published) |

---

## Common Commands

```bash
# ── Testing ──────────────────────────────────────────────────────────────────
mix test --exclude integration              # Unit tests only (no database)
mix test --only integration                 # Integration tests (needs ScyllaDB)
SCYLLA_DIRECT=1 mix test --only integration # Integration tests against local DB
mix test test/integration/cluster_integration_test.exs --only integration  # Cluster tests
mix test --exclude integration --cover      # Unit tests + coverage report

# ── Code Quality ─────────────────────────────────────────────────────────────
mix format --check-formatted                # Check formatting
mix credo --strict                          # Static analysis
mix dialyzer                                # Type checking
mix quality                                 # All three above

# ── Benchmarks ───────────────────────────────────────────────────────────────
mix run benchmarks/run_benchmarks.exs

# ── Database ─────────────────────────────────────────────────────────────────
mix ash_scylla.setup                        # Create keyspace
mix ash_scylla.migrate                      # Run all migrations
mix ash_scylla.migrate --schemas-only       # Run only schema files
mix ash_scylla.migrate --resource MyApp.User # Run migrations for one resource
mix ash_scylla.gen --dev                    # Generate schema migration from DSL

# ── Ash Extension Callbacks ──────────────────────────────────────────────────
mix ash.install AshScylla --resource MyApp.User  # Install for a resource
mix ash.reset AshScylla                           # Reset database
mix ash.rollback AshScylla --version 20240101     # Rollback (logs warning)
mix ash.tear_down AshScylla                       # Drop keyspace
```

---

## Contributing

Contributions are welcome!

1. **Fork** the repository
2. **Clone** your fork
3. **Create** a feature branch: `git checkout -b feature/my-feature`
4. **Make** your changes
5. **Run** tests: `mix test --exclude integration`
6. **Check** quality: `mix quality`
7. **Commit** and push
8. **Open** a Pull Request

### Development Setup

```bash
mix deps.get
podman-compose -f podman-compose.yml up -d
mix test
```

A `.devcontainer/devcontainer.json` is provided for VS Code Dev Containers.

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
