# AshScylla Usage Guide

> **Comprehensive usage guide for AshScylla**

---

## Table of Contents

1. [Quick Start](#quick-start)
2. [Resource Configuration](#resource-configuration)
3. [Generating Resources](#generating-resources)
4. [CRUD Operations](#crud-operations)
5. [Querying](#querying)
6. [Data Modeling Best Practices](#data-modeling-best-practices)
7. [ScyllaDB Features](#scylladb-features)
8. [Migrations](#migrations)
9. [Performance Tips](#performance-tips)
10. [Common Patterns](#common-patterns)
11. [Troubleshooting](#troubleshooting)
12. [Additional Resources](#additional-resources)

---

## Quick Start

### Complete Setup Example

**1. Add to your dependencies:**

```elixir
# mix.exs
def deps do
  [
    {:ash_scylla, "~> 0.12.0"}
  ]
end
```

**2. Create a Repo:**

```elixir
# lib/my_app/repo.ex
defmodule MyApp.Repo do
  use AshScylla.Repo,
    otp_app: :my_app
end
```

**3. Configure the Repo:**

```elixir
# config/config.exs
import Config

config :my_app, MyApp.Repo,
  nodes: ["127.0.0.1:9042"],
  keyspace: "my_app_dev",
  pool_size: 10
```

**4. Add to supervision tree:**

```elixir
# lib/my_app/application.ex
children = [
  MyApp.Repo,
  # ...
]
```

**5. Generate a Resource:**

```bash
mix ash_scylla.new_template User name:string, email:string
```

Or define it manually:

```elixir
# lib/my_app/resources/user.ex
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
```

**6. Create a Domain:**

```elixir
# lib/my_app/domain.ex
defmodule MyApp.Domain do
  use Ash.Domain

  resources do
    resource MyApp.User
  end
end
```

**7. Create Keyspace and Tables:**

```bash
# Generate schema migration from Ash DSL
mix ash_scylla.gen --dev

# Run migrations (includes schema files from priv/migrations)
mix ash_scylla.migrate
```

**8. Start Using It:**

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

---

## Resource Configuration

### Basic Resource with All Options

```elixir
defmodule MyApp.Product do
  use Ash.Resource,
    data_layer: AshScylla.DataLayer,
    domain: MyApp.Domain

  ash_scylla do
    table "products"
    keyspace "custom_keyspace"
    consistency :quorum
    ttl 3600
    lwt true
    allow_filtering false

    # Secondary indexes
    secondary_index :category
    secondary_index [:brand, :price]

    # Materialized views
    materialized_view :products_by_category,
      primary_key: [:category, :id],
      include_columns: [:name, :price]

    # Per-action consistency
    per_action_consistency read: :one, create: :quorum
  end

  attributes do
    uuid_primary_key :id
    attribute :name, :string
    attribute :category, :string
    attribute :brand, :string
    attribute :price, :decimal
  end

  actions do
    defaults [:create, :read, :update, :destroy]
  end
end
```

### Composite Primary Keys

```elixir
defmodule MyApp.OrderItem do
  use Ash.Resource,
    data_layer: AshScylla.DataLayer,
    domain: MyApp.Domain

  ash_scylla do
    table "order_items"
  end

  attributes do
    attribute :order_id, :uuid, primary_key?: true
    attribute :product_id, :uuid, primary_key?: true
    attribute :quantity, :integer
    attribute :price, :decimal
  end
end
```

---

## Generating Resources

### Command Format

```bash
mix ash_scylla.new_template ResourceName field1:type1, field2:type2
```

### Options

| Option | Description |
|--------|-------------|
| `--domain` | Domain module (auto-prefixes resource name) |
| `--resource` | Fully-qualified resource module name |

### Supported Types

| Ash Type | CQL Type |
|----------|----------|
| `:string` | TEXT |
| `:integer` | BIGINT |
| `:uuid` | UUID |
| `:boolean` | BOOLEAN |
| `:float` | DOUBLE |
| `:decimal` | DECIMAL |
| `:date` | DATE |
| `:time` | TIME |
| `:utc_datetime` | TIMESTAMP |
| `:naive_datetime` | TIMESTAMP |
| `:binary` | BLOB |

### Examples

```bash
# Simple resource
mix ash_scylla.new_template User user_id:uuid, name:string, age:int

# With domain
mix ash_scylla.new_template User name:string --domain MyApp.Domain

# Fully-qualified name
mix ash_scylla.new_template User name:string --resource MyApp.Domain.User
```

### Generated Output with `--domain`

```ruby
# lib/my_app/resources/user.ex
defmodule MyApp.Domain.User do
  use Ash.Resource,
    data_layer: AshScylla.DataLayer,
    domain: MyApp.Domain

  ash_scylla do
    table "users"
  end

  attributes do
    uuid_primary_key :id
    attribute :name, :string
  end

  actions do
    defaults [:create, :read, :update, :destroy]
  end
end
```

---

## CRUD Operations

### Create

```elixir
# Single record
{:ok, user} = Ash.create(MyApp.User, %{name: "Alice", email: "alice@example.com"})

# With changeset
{:ok, user} =
  MyApp.User
  |> Ash.Changeset.for_create(:create, %{name: "Alice", email: "alice@example.com"})
  |> Ash.create()

# Bulk create (uses BATCH)
{:ok, users} = Ash.bulk_create(user_data_list, MyApp.User, :create)
```

### Read

```elixir
# All records
users = Ash.read(MyApp.User)

# With filter
{:ok, user} =
  MyApp.User
  |> Ash.Query.filter(email == "alice@example.com")
  |> Ash.read_one()

# With domain
users = MyApp.Domain.read_users!()
```

### Update

```elixir
# Single record
{:ok, updated} =
  user
  |> Ash.Changeset.for_update(:update, %{name: "Alice Smith"})
  |> Ash.update()

# Bulk update (via query)
MyApp.User
|> Ash.Query.filter(status: "pending")
|> Ash.update!(%{status: "active"})
```

### Delete

```elixir
# Single record
:ok = Ash.destroy(user)

# Bulk delete (via query)
MyApp.User
|> Ash.Query.filter(status: "inactive")
|> Ash.destroy!()
```

---

## Querying

### Filter Operators

| Operator | Example |
|----------|---------|
| `==` | `Ash.Query.filter(email == "user@example.com")` |
| `!=` | `Ash.Query.filter(status != "inactive")` |
| `>` | `Ash.Query.filter(age > 18)` |
| `>=` | `Ash.Query.filter(price >= 100)` |
| `<` | `Ash.Query.filter(age < 65)` |
| `<=` | `Ash.Query.filter(price <= 50)` |
| `in` | `Ash.Query.filter(status in ["active", "pending"])` |
| `contains` | `Ash.Query.filter(tags contains "elixir")` |
| `is_nil` | `Ash.Query.filter(email is_nil true)` |

### Combining Filters

```elixir
# AND (default)
MyApp.User
|> Ash.Query.filter(status: "active")
|> Ash.Query.filter(age > 18)

# OR (rewritten to IN where possible)
import Ash.Query
MyApp.User
|> Ash.Query.filter(status == "active" or status == "pending")
```

### Sorting and Pagination

```elixir
# Sort by clustering column (within partition)
MyApp.User
|> Ash.Query.sort(:name, :asc)
|> Ash.read!()

# Keyset pagination (default, recommended)
MyApp.User
|> Ash.Query.limit(10)
|> Ash.read!()

# Offset raises an error
MyApp.User
|> Ash.Query.offset(10)
# => ** (RuntimeError) OFFSET is not supported in ScyllaDB/Cassandra. Use keyset pagination instead.
```

---

## Data Modeling Best Practices

### 1. Query-First Design

Design your tables around your queries:

```elixir
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

### 2. Denormalization is Normal

Duplicate data across tables for different query patterns:

```elixir
defmodule MyApp.PostByAuthor do
  attributes do
    attribute :author_id, :uuid, primary_key?: true
    attribute :post_id, :uuid, primary_key?: true
    attribute :title, :string
    attribute :content, :string
  end
end

defmodule MyApp.PostByDate do
  attributes do
    attribute :date, :date, primary_key?: true
    attribute :post_id, :uuid, primary_key?: true
    attribute :title, :string
    attribute :author_name, :string  # Denormalized
  end
end
```

### 3. Choosing Partition Keys

- **High cardinality**: Distribute data evenly
- **Query patterns**: Support your most common queries
- **Avoid hotspots**: Don't use low-cardinality partition keys

```elixir
# Good: User ID has high cardinality
attribute :user_id, :uuid, primary_key?: true

# Avoid: Status has low cardinality (creates hotspots)
attribute :status, :string, primary_key?: true  # Don't do this
```

---

## ScyllaDB Features

### Consistency Levels

```elixir
defmodule MyApp.CriticalData do
  ash_scylla do
    consistency :quorum  # Strong consistency
  end
end

defmodule MyApp.CachedData do
  ash_scylla do
    consistency :one  # Fast, eventual consistency
  end
end
```

Available levels: `:any`, `:one`, `:two`, `:three`, `:quorum`, `:all`, `:local_quorum`

### TTL (Time To Live)

```elixir
defmodule MyApp.Session do
  ash_scylla do
    ttl 3600  # Expire after 1 hour
  end

  attributes do
    attribute :user_id, :uuid, primary_key?: true
    attribute :data, :string
  end
end
```

### Collections

```elixir
defmodule MyApp.User do
  attributes do
    attribute :tags, {:array, :string}  # LIST<TEXT>
    attribute :scores, {:array, :integer}  # LIST<BIGINT>
    attribute :metadata, :map  # MAP<TEXT, TEXT>
  end
end
```

### Secondary Indexes

```elixir
defmodule MyApp.User do
  ash_scylla do
    secondary_index :email                    # Single column
    secondary_index [:name, :age]             # Multi-column (separate indexes)
    secondary_index :status, name: "idx_status"  # Custom name
  end
end
```

> **Note:** ScyllaDB OSS doesn't support multi-column secondary indexes. AshScylla generates separate single-column indexes.

### Materialized Views

```elixir
defmodule MyApp.User do
  ash_scylla do
    materialized_view :users_by_email,
      primary_key: [:email, :id],
      include_columns: [:name, :age],
      clustering_order: [id: :desc]
  end
end
```

Generates:
```sql
CREATE MATERIALIZED VIEW IF NOT EXISTS users_by_email
AS SELECT id, email, name, age
FROM users
WHERE email IS NOT NULL AND id IS NOT NULL
PRIMARY KEY (email, id)
WITH CLUSTERING ORDER BY (id DESC)
```

---

## Migrations

### Creating Tables

Use `mix ash_scylla.gen` to generate schema migrations from your Ash DSL:

```bash
# Auto-generate with timestamp-based name
mix ash_scylla.gen --dev

# With specific module name
mix ash_scylla.gen AddUserTable

# For a specific resource
mix ash_scylla.gen --resource MyApp.User
```

This creates files in `priv/migrations/`:

```elixir
# priv/migrations/20260615155440_schema.ex
defmodule MyApp.Migrations.Schema20260615155440 do
  use AshScylla.Schema

  def change do
    [
      %AshScylla.Schema{
        domain: MyApp.Domain,
        resources: [
          %AshScylla.Schema.Resource{
            name: :users,
            statements: [
              "CREATE TABLE IF NOT EXISTS users (id UUID PRIMARY KEY, name TEXT, email TEXT)",
              "CREATE INDEX IF NOT EXISTS idx_users_email ON users (email)"
            ]
          }
        ]
      }
    ]
  end
end
```

### Using AshScylla.Migration Helpers

```elixir
defmodule MyApp.Repo.Migrations.CreateUsers do
  def change do
    AshScylla.Migration.create_table_cql(MyApp.User)
    |> then(&AshScylla.Migrator.run!/3)
  end
end
```

### Creating User Defined Types

```elixir
defmodule MyApp.Repo.Migrations.CreateAddressType do
  def change do
    AshScylla.Migration.create_type("address",
      city: :text,
      street: :text,
      zip: :text
    )
    |> then(&AshScylla.Migrator.run!/3)
  end
end
```

### Running Migrations

```bash
# Migrate all resources and schema files
mix ash_scylla.migrate

# Migrate specific resource
mix ash_scylla.migrate --resource MyApp.User

# Dry run (show statements without executing)
mix ash_scylla.migrate --dry-run

# Only schema files from priv/migrations
mix ash_scylla.migrate --schemas-only
```

---

## Performance Tips

### 1. Use Appropriate Consistency Levels

```elixir
defmodule MyApp.PageView do
  ash_scylla do
    consistency :one  # Fast writes, eventual consistency is fine
  end
end

defmodule MyApp.FinancialTransaction do
  ash_scylla do
    consistency :quorum  # Strong consistency required
  end
end
```

### 2. Connection Pool Tuning

```elixir
config :my_app, MyApp.Repo,
  pool_size: 50,                # Connections per node
  request_timeout: 300_000,     # Query timeout (ms)
  connect_timeout: 10_000
```

**Pool Size Formula:**
```
pool_size = num_nodes * num_cores_per_node
```

### 3. Avoid Expensive Queries

- Use primary key queries when possible
- Create secondary indexes for non-primary key queries
- Use materialized views for alternative query patterns
- Avoid ALLOW FILTERING (raises error by default)
- Use BATCH statements for multiple operations

### 4. Batch Operations

```elixir
# Synchronous batch
statements = [
  {"INSERT INTO users (id, name) VALUES (?, ?)", [id1, "Alice"]},
  {"INSERT INTO users (id, name) VALUES (?, ?)", [id2, "Bob"]}
]
AshScylla.DataLayer.Batch.batch_insert(repo, statements)

# Async partition-aware batch (recommended for large datasets)
AshScylla.DataLayer.Batch.batch_insert_async(repo, statements, max_concurrency: 8)
```

### 5. Prepared Statement Caching

Enable for high-throughput workloads:

```elixir
children = [
  AshScylla.PreparedStatementCache,
  # ...
]
```

---

## Common Patterns

### Time-Series Data

```elixir
defmodule MyApp.Metric do
  use Ash.Resource,
    data_layer: AshScylla.DataLayer,
    domain: MyApp.Domain

  ash_scylla do
    table "metrics"
  end

  attributes do
    attribute :sensor_id, :uuid, primary_key?: true
    attribute :timestamp, :utc_datetime, primary_key?: true
    attribute :value, :float
    attribute :unit, :string
  end
end

# Query recent metrics
MyApp.Metric
|> Ash.Query.filter(sensor_id: sensor_id)
|> Ash.Query.sort(timestamp: :desc)
|> Ash.Query.limit(100)
|> Ash.read!()
```

### Counters with Materialized Views

```elixir
defmodule MyApp.PageView do
  attributes do
    attribute :page_id, :uuid, primary_key?: true
    attribute :user_id, :uuid
    attribute :viewed_at, :utc_datetime
  end
end

defmodule MyApp.PageViewCount do
  use Ash.Resource,
    data_layer: AshScylla.DataLayer,
    domain: MyApp.Domain

  ash_scylla do
    table "page_view_counts"
  end

  attributes do
    attribute :page_id, :uuid, primary_key?: true
    attribute :count, :integer
  end
end
```

---

## Troubleshooting

### Common Issues

| Issue | Cause | Solution |
|-------|-------|----------|
| `Connection refused` | ScyllaDB not running | `podman-compose -f podman-compose.yml up -d` |
| `Keyspace does not exist` | Keyspace not created | `mix ash_scylla.setup` or `mix ash_scylla.migrate --create-keyspace` |
| `Table not found` | Migration not run | `mix ash_scylla.migrate` |
| `Invalid filter` | Non-indexed column filter | Add `secondary_index` or enable `allow_filtering` |
| `OFFSET not supported` | Used offset query | Use keyset pagination instead |
| `timeout` | Query too slow | Increase `request_timeout`, add indexes, optimize query |

### Debugging Tips

```bash
# Check ScyllaDB is running
podman ps

# Check ScyllaDB logs
podman logs ash_scylla_test

# Verify connection
iex -S mix
iex> {:ok, conn} = Xandra.start_link(nodes: ["scylla:9042"])
iex> Xandra.execute(conn, "SELECT release_version FROM system.local")

# Inspect generated CQL
iex> alias AshScylla.DataLayer.QueryBuilder
iex> query = %AshScylla.DataLayer{resource: MyApp.User, repo: MyApp.Repo, table: "users", filters: [%{operator: :eq, left: %{name: :email}, right: %{value: "test@example.com"}}]}
iex> QueryBuilder.build_optimized_query(query)
```

---

## Additional Resources

- **[Development Guide](DEV_GUIDE.md)** — Dev container setup and development workflow
- **[Production Guide](PRODUCTION_GUIDE.md)** — Multi-node cluster deployment and operations
- **[Implementation Summary](IMPLEMENTATION_SUMMARY.md)** — Technical architecture details
- **[Error Handling](ERROR_HANDLING.md)** — Error types and handling strategies
- **[Changelog](CHANGELOG.md)** — Version history and release notes
- **[API Documentation](https://hexdocs.pm/ash_scylla)** — Module documentation

---

## License

Apache License 2.0 - see [LICENSE](LICENSE) file for details.
