# AshScylla Usage Guide

> **Complete guide to using AshScylla with ScyllaDB/Apache Cassandra**

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

---

## Quick Start

### Complete Setup Example

**1. Create a Repo (`lib/my_app/repo.ex`):**

```elixir
defmodule MyApp.Repo do
  use Ecto.Repo,
    otp_app: :my_app,
    adapter: Exandra
end
```

**2. Configure the Repo (`config/config.exs`):**

```elixir
config :my_app, MyApp.Repo,
  nodes: ["127.0.0.1:9042"],
  keyspace: "my_app_dev",
  pool_size: 10,
  request_timeout: 120_000
```

**3. Create a Domain (`lib/my_app/domain.ex`):**

```elixir
defmodule MyApp.Domain do
  use Ash.Domain

  resources do
    resource MyApp.User
    resource MyApp.Post
  end
end
```

4. Generate a Resource Template:

```bash
mix ash_scylla.gen User user_id:uuid, name:string, age:int
```

This creates `lib/my_app/resources/user.ex` with a starter template. Then customize it:

Or define resources manually (`lib/my_app/resources/user.ex`):

```elixir
defmodule MyApp.User do
  use Ash.Resource,
    data_layer: AshScylla.DataLayer,
    domain: MyApp.Domain

  attributes do
    uuid_primary_key :id
    attribute :name, :string
    attribute :email, :string
    attribute :age, :integer
    attribute :status, :string, constraints: [one_of: ["active", "inactive"]]
  end

  actions do
    defaults [:create, :read, :update, :destroy]
  end
end
```

**5. Initialize Database:**

```elixir
# Create keyspace
MyApp.Repo.create_keyspace()

# Run migrations
mix ecto.migrate
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
    table "products"                    # Custom table name
    keyspace "my_keyspace"               # Custom keyspace
    consistency :quorum                  # Consistency level
    ttl 7200                            # TTL in seconds

    # Secondary indexes
    secondary_index :sku
    secondary_index [:category, :brand]

    # Materialized views
    materialized_view :products_by_category,
      primary_key: [:category, :id],
      include_columns: [:name, :price, :brand]
  end

  attributes do
    uuid_primary_key :id
    attribute :name, :string
    attribute :sku, :string
    attribute :price, :decimal
    attribute :category, :string
    attribute :brand, :string
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
    data_layer: AshScylla.DataLayer

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

AshScylla includes a Mix task to quickly scaffold a new resource:

```bash
mix ash_scylla.gen MyResource user_id:uuid, name:string, age:int
```

This generates a file at `lib/<app>/resources/my_resource.ex` containing:

```elixir
defmodule MyResource do
  use Ash.Resource,
    data_layer: AshScylla.DataLayer,
    repo: MyApp.Repo

  attributes do
    uuid_primary_key :id
    attribute :user_id, :uuid
    attribute :name, :string
    attribute :age, :integer
  end

  actions do
    defaults [:create, :read, :update, :destroy]
  end
end
```

### Command Format

```bash
mix ash_scylla.gen <ResourceName> <attr1>:<type1>, <attr2>:<type2>, ...
```

- **ResourceName** — an Elixir module alias (e.g. `User`, `Blog.Post`)
- **Attributes** — comma-separated `name:type` pairs

### Supported Types

Any valid Ash type is accepted. Common choices:

| Type | CQL mapping |
|------|-------------|
| `:uuid` | UUID |
| `:string` | TEXT |
| `:integer` (or `:int`) | BIGINT |
| `:boolean` | BOOLEAN |
| `:utc_datetime` | TIMESTAMP |
| `:date` | DATE |
| `:float` | DOUBLE |
| `:decimal` | DECIMAL |

### Examples

```bash
# Simple resource
mix ash_scylla.gen User email:string, name:string, age:int

# With module nesting
mix ash_scylla.gen Blog.Post title:string, body:string, published:boolean

# Many attributes
mix ash_scylla.gen Sensor sensor_id:uuid, temperature:float, location:string, recorded_at:utc_datetime
```

After generating, add the resource to your domain and customize with primary keys, actions, and ScyllaDB-specific options:

```elixir
defmodule MyApp.User do
  use Ash.Resource,
    data_layer: AshScylla.DataLayer,
    domain: MyApp.Domain

  ash_scylla do
    table "users"
    consistency :quorum
    secondary_index :email
  end

  attributes do
    uuid_primary_key :id
    attribute :email, :string
    attribute :name, :string
    attribute :age, :integer
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
# Simple create
{:ok, user} = MyApp.User
  |> Ash.Changeset.for_create(:create, %{
    name: "John Doe",
    email: "john@example.com",
    age: 30
  })
  |> Ash.create()

# Bulk create (uses BATCH internally)
users_data = [
  %{name: "Alice", email: "alice@example.com"},
  %{name: "Bob", email: "bob@example.com"}
]

{:ok, users} = users_data
  |> Enum.map(fn attrs -> Ash.Changeset.for_create(MyApp.User, :create, attrs) end)
  |> Ash.bulk_create(MyApp.User, :create)
```

### Read

```elixir
# Read all
users = MyApp.User |> Ash.read()

# Read one by primary key
{:ok, user} = MyApp.User
  |> Ash.Query.filter(id == "some-uuid")
  |> Ash.read_one()

# Read with filters
active_users = MyApp.User
  |> Ash.Query.filter(status == "active" and age >= 18)
  |> Ash.read()

# Select specific fields
names = MyApp.User
  |> Ash.Query.select([:name, :email])
  |> Ash.read()
```

### Update

```elixir
{:ok, updated_user} = user
  |> Ash.Changeset.for_update(:update, %{
    name: "John Smith",
    age: 31
  })
  |> Ash.update()
```

### Delete

```elixir
:ok = user |> Ash.destroy()
```

---

## Querying

### Filter Operators

| Operator | Description | Example |
|----------|-------------|---------|
| `==` | Equality | `age == 30` |
| `!=` | Not equal | `status != "inactive"` |
| `>` | Greater than | `age > 18` |
| `>=` | Greater or equal | `age >= 21` |
| `<` | Less than | `price < 100` |
| `<=` | Less or equal | `price <= 50` |
| `in` | In list | `status in ["active", "pending"]` |

### Combining Filters

```elixir
# AND conditions
users = MyApp.User
  |> Ash.Query.filter(status == "active" and age >= 18)
  |> Ash.read()

# OR conditions (use multiple queries for complex cases)
active_or_admin = MyApp.User
  |> Ash.Query.filter(status == "active" or role == "admin")
  |> Ash.read()
```

### Sorting and Pagination

```elixir
# Sort by single field
users = MyApp.User
  |> Ash.Query.sort(:name)
  |> Ash.read()

# Sort by multiple fields
users = MyApp.User
  |> Ash.Query.sort([:status, :name])
  |> Ash.read()

# Limit results
recent_users = MyApp.User
  |> Ash.Query.sort(inserted_at: :desc)
  |> Ash.Query.limit(10)
  |> Ash.read()
```

---

## Data Modeling Best Practices

### 1. Query-First Design 🎯

Design tables around your queries, not the other way around:

```elixir
# Query: "Get all posts by author"
defmodule MyApp.Post do
  attributes do
    attribute :author_id, :uuid, primary_key?: true  # Partition key
    attribute :post_id, :uuid, primary_key?: true     # Clustering key
    attribute :title, :string
    attribute :content, :string
  end
end

# Efficient query by partition key
posts = MyApp.Post
  |> Ash.Query.filter(author_id == "author-uuid")
  |> Ash.read()
```

### 2. Denormalization is Normal 📦

Duplicate data to support different query patterns:

```elixir
# Table 1: Posts by author
defmodule MyApp.PostByAuthor do
  attributes do
    attribute :author_id, :uuid, primary_key?: true
    attribute :post_id, :uuid, primary_key?: true
    attribute :title, :string
    attribute :author_name, :string  # Denormalized
  end
end

# Table 2: Posts by date (different query pattern)
defmodule MyApp.PostByDate do
  attributes do
    attribute :date, :date, primary_key?: true
    attribute :post_id, :uuid, primary_key?: true
    attribute :title, :string
    attribute :author_name, :string
  end
end
```

### 3. Choosing Partition Keys 🔑

**Good partition keys:**
- High cardinality (many unique values)
- Evenly distributed
- Match your query patterns

```elixir
# Good: UUID has high cardinality
attribute :user_id, :uuid, primary_key?: true

# Good: email is unique and high cardinality
attribute :email, :string, primary_key?: true
```

**Avoid:**
- Low cardinality (status, type, boolean)
- Timestamps (creates hotspots)

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

**Consistency Level Guide:**

| Level | Description | Use Case |
|-------|-------------|----------|
| `:any` | Any node response | Fastest, lowest consistency |
| `:one` | At least one replica | Fast reads/writes |
| `:quorum` | Majority of replicas | Balanced speed/consistency |
| `:all` | All replicas | Strongest consistency, slowest |

### TTL (Time To Live)

```elixir
defmodule MyApp.Session do
  use Ash.Resource,
    data_layer: AshScylla.DataLayer

  ash_scylla do
    ttl 3600  # Expire after 1 hour (in seconds)
  end

  attributes do
    uuid_primary_key :id
    attribute :token, :string
    attribute :user_id, :uuid
  end
end
```

### Collections

```elixir
defmodule MyApp.User do
  attributes do
    uuid_primary_key :id
    attribute :name, :string
    attribute :tags, {:array, :string}      # LIST type
    attribute :metadata, :map               # MAP type
  end
end
```

### Secondary Indexes

```elixir
defmodule MyApp.User do
  ash_scylla do
    # Single column index
    secondary_index :email

    # Composite index
    secondary_index [:name, :age]

    # Custom index name
    secondary_index :status, name: "idx_user_status"
  end
end
```

**Important Notes:**
- Best for low-cardinality columns
- Equality checks only (`==`)
- Adds overhead to writes

### Materialized Views

```elixir
defmodule MyApp.User do
  ash_scylla do
    materialized_view :users_by_email,
      primary_key: [:email, :id],
      include_columns: [:name, :age],
      clustering_order: [id: :desc]

    materialized_view :users_by_age,
      primary_key: [:age, :id],
      include_columns: [:name, :email]
  end
end
```

---

## Migrations

### Creating Tables

```elixir
defmodule MyApp.Repo.Migrations.CreateUsers do
  use Ecto.Migration

  def change do
    create table("users", primary_key: false) do
      add :id, :uuid, primary_key: true
      add :name, :string
      add :email, :string
      add :age, :integer
      add :status, :string

      # Collections
      add :tags, {:array, :string}
      add :metadata, :map
    end

    # Secondary indexes
    create index("users", [:email], name: "idx_users_email")
    create index("users", [:status], name: "idx_users_status")
  end
end
```

### Using AshScylla.Migration Helpers

```elixir
defmodule MyApp.Repo.Migrations.CreateUsers do
  use Ecto.Migration

  def change do
    AshScylla.Migration.create_table_cql(MyApp.User)
    |> Enum.each(&execute/1)

    AshScylla.Migration.create_secondary_indexes_cql(MyApp.User)
    |> Enum.each(&execute/1)
  end
end
```

### Creating User Defined Types

```elixir
defmodule MyApp.Repo.Migrations.CreateAddressType do
  use Ecto.Migration

  def change do
    execute """
    CREATE TYPE IF NOT EXISTS address (
      street TEXT,
      city TEXT,
      state TEXT,
      zip TEXT
    )
    """
  end
end
```

---

## Performance Tips

### 1. Use Appropriate Consistency Levels

```elixir
# Fast reads for non-critical data
defmodule MyApp.PageView do
  ash_scylla do
    consistency :one
  end
end

# Strong consistency for critical data
defmodule MyApp.FinancialTransaction do
  ash_scylla do
    consistency :quorum
  end
end
```

### 2. Connection Pool Tuning

```elixir
config :my_app, MyApp.Repo,
  nodes: ["scylla-1:9042", "scylla-2:9042"],
  pool_size: 50,                    # Connections per node
  pool_timeout: 15_000,
  request_timeout: 300_000,         # 5 minutes for complex queries
  connect_timeout: 10_000
```

**Pool Size Guidelines:**
- Development: 5-10
- Production: 25-100 (based on load)

### 3. Avoid Expensive Queries

```elixir
# DON'T: Full table scan without partition key
MyApp.User |> Ash.read()  # Inefficient

# DO: Query by partition key
MyApp.User
  |> Ash.Query.filter(email == "user@example.com")
  |> Ash.read()
```

### 4. Batch Operations

```elixir
# Use bulk_create for multiple inserts
{:ok, _users} = user_data_list
  |> Ash.bulk_create(MyApp.User, :create)
```

---

## Common Patterns

### Time-Series Data

```elixir
defmodule MyApp.Metric do
  use Ash.Resource,
    data_layer: AshScylla.DataLayer

  attributes do
    attribute :metric_name, :string, primary_key?: true
    attribute :timestamp, :utc_datetime, primary_key?: true
    attribute :value, :float
    attribute :tags, :map
  end

  actions do
    defaults [:create, :read, :update, :destroy]
  end
end

# Query last 24 hours
metrics = MyApp.Metric
  |> Ash.Query.filter(
    metric_name == "cpu_usage" and
    timestamp >= ~U[2024-01-01 00:00:00Z] and
    timestamp <= ~U[2024-01-02 00:00:00Z]
  )
  |> Ash.Query.sort(timestamp: :desc)
  |> Ash.read()
```

### Counters with Materialized Views

```elixir
# Main table
defmodule MyApp.PageView do
  attributes do
    attribute :page_id, :string, primary_key?: true
    attribute :view_date, :date, primary_key?: true
    attribute :count, :integer
  end
end

# Aggregated view
defmodule MyApp.PageViewCount do
  attributes do
    attribute :page_id, :string, primary_key?: true
    attribute :total_views, :integer
  end
end
```

---

## Troubleshooting

### Common Issues

**1. Connection Refused**
```
** (RuntimeError) Could not connect to ScyllaDB at 127.0.0.1:9042
```
- Ensure ScyllaDB is running: `docker ps`
- Check connection settings in `config/config.exs`
- Verify firewall/network settings

**2. NoHostAvailableError**
```
** (Xandra.NoHostAvailableError) All hosts down
```
- Check if ScyllaDB node is accessible
- Verify `nodes` configuration
- Check ScyllaDB logs: `docker logs <container_id>`

**3. Invalid Query / Syntax Error**
```
** (Xandra.Error) Invalid syntax in CQL query
```
- Check CQL syntax in custom queries
- Verify table/column names exist
- Run migrations: `mix ecto.migrate`

**4. Read Timeout**
```
** (Xandra.Error) Request timed out
```
- Increase `request_timeout` in repo config
- Optimize slow queries
- Check ScyllaDB performance

**5. Secondary Index Not Used**
```
Query filtering on non-indexed column
```
- Create secondary index in resource DSL
- Run migration to create index
- Verify index exists: `DESCRIBE INDEX idx_name;`

### Debugging Tips

**Enable Query Logging:**

```elixir
# In config/dev.exs
config :logger, level: :debug

# Or in IEx
Logger.configure(level: :debug)
```

**Check Generated CQL:**

```elixir
# Use AshScylla.DataLayer.QueryBuilder to inspect queries
query = AshScylla.DataLayer.QueryBuilder.build_optimized_query(data_layer_struct)
IO.inspect(query, label: "Generated CQL")
```

**Test Connection:**

```elixir
# In IEx
MyApp.Repo.query("SELECT release_version FROM system.local")
```

---

## Additional Resources

- [Ash Framework Documentation](https://ash-hq.org/docs)
- [ScyllaDB Documentation](https://docs.scylladb.com/)
- [Exandra GitHub](https://github.com/lexhide/exandra)
- [CQL Reference](https://docs.scylladb.com/cql/)
