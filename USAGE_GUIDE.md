# AshScylla Usage Guide

This guide provides comprehensive examples and best practices for using AshScylla with ScyllaDB.

## Table of Contents

1. [Getting Started](#getting-started)
2. [Resource Configuration](#resource-configuration)
3. [CRUD Operations](#crud-operations)
4. [Querying](#querying)
5. [Data Modeling Best Practices](#data-modeling-best-practices)
6. [ScyllaDB-Specific Features](#scylladb-specific-features)
7. [Migrations](#migrations)
8. [Performance Optimization](#performance-optimization)
9. [Common Patterns](#common-patterns)
10. [Troubleshooting](#troubleshooting)

---

## Getting Started

### Complete Setup Example

Here's a complete example of setting up a simple application with AshScylla:

**1. Create a Repo (`lib/my_app/repo.ex`):**

```elixir
defmodule MyApp.Repo do
  use AshScylla.Repo,
    otp_app: :my_app
end
```

**2. Configure the Repo (`config/config.exs`):**

```elixir
config :my_app, MyApp.Repo,
  nodes: ["127.0.0.1:9042"],
  keyspace: "my_app_dev",
  pool_size: 10,
  sync_connect: 5000,
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

**4. Define Resources (`lib/my_app/resources/user.ex`):**

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
    attribute :status, :string, constraints: [one_of: ["active", "inactive", "suspended"]]
  end

  actions do
    defaults [:create, :read, :update, :destroy]
  end
end
```

**5. Create Keyspace and Tables:**

```elixir
# In IEx or a setup script
MyApp.Repo.create_keyspace()

# Run migrations (see Migrations section)
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

  # ScyllaDB-specific configuration
  ash_scylla do
    table "products"                    # Override default table name
    keyspace "inventory"                 # Use specific keyspace
    consistency :quorum                  # Set consistency level
    ttl 86400                           # Default TTL: 24 hours
  end

  attributes do
    # Primary key (partition key in ScyllaDB)
    attribute :sku, :string, primary_key?: true

    # Clustering key (if needed, use composite primary key)
    # attribute :version, :integer, primary_key?: true

    attribute :name, :string
    attribute :description, :text
    attribute :price, :decimal
    attribute :category, :string
    attribute :tags, {:array, :string}           # ScyllaDB LIST type
    attribute :metadata, :map                    # ScyllaDB MAP type
    attribute :created_at, :utc_datetime
    attribute :updated_at, :utc_datetime
  end

  # Secondary indexes for non-primary key queries
  ash_scylla do
    secondary_index :category                   # Single column index
    secondary_index [:price, :category]         # Composite index
  end

  actions do
    defaults [:create, :read, :update, :destroy]

    # Custom action with specific fields
    create :register do
      accept [:sku, :name, :price]
      change set_attribute(:status, "active")
    end
  end
end
```

### Composite Primary Keys

```elixir
defmodule MyApp.OrderItem do
  use Ash.Resource,
    data_layer: AshScylla.DataLayer

  attributes do
    # Composite primary key (partition key + clustering key)
    attribute :order_id, :uuid, primary_key?: true
    attribute :product_id, :uuid, primary_key?: true
    attribute :quantity, :integer
    attribute :price, :decimal
  end
end
```

---

## CRUD Operations

### Create Operations

```elixir
# Simple create
{:ok, user} = MyApp.User
  |> Ash.Changeset.for_create(:create, %{
    name: "Alice Johnson",
    email: "alice@example.com",
    age: 28
  })
  |> Ash.create()

# Create with custom action
{:ok, product} = MyApp.Product
  |> Ash.Changeset.for_create(:register, %{
    sku: "PROD-001",
    name: "Widget",
    price: 29.99
  })
  |> Ash.create()

# Bulk create
users_data = [
  %{name: "User1", email: "user1@example.com"},
  %{name: "User2", email: "user2@example.com"},
  %{name: "User3", email: "user3@example.com"}
]

{:ok, users} = users_data
  |> Enum.map(fn attrs ->
    Ash.Changeset.for_create(MyApp.User, :create, attrs)
  end)
  |> Ash.bulk_create(MyApp.User, :create)
```

### Read Operations

```elixir
# Read all
all_users = MyApp.User |> Ash.read()

# Read one by primary key
{:ok, user} = MyApp.User
  |> Ash.Query.filter(id == "some-uuid")
  |> Ash.read_one()

# Read with filters
active_users = MyApp.User
  |> Ash.Query.filter(status == "active")
  |> Ash.read()

# Complex filters
adult_users = MyApp.User
  |> Ash.Query.filter(age >= 18 and status == "active")
  |> Ash.read()

# Read with sorting
sorted_users = MyApp.User
  |> Ash.Query.sort(:name)
  |> Ash.read()

# Multiple sort fields
sorted_users = MyApp.User
  |> Ash.Query.sort([:status, :name])
  |> Ash.read()

# Descending sort
recent_users = MyApp.User
  |> Ash.Query.sort(age: :desc)
  |> Ash.read()

# Limit results
top_10 = MyApp.User
  |> Ash.Query.limit(10)
  |> Ash.read()

# Select specific fields
names_and_emails = MyApp.User
  |> Ash.Query.select([:name, :email])
  |> Ash.read()

# First/Last record
{:ok, first_user} = MyApp.User
  |> Ash.Query.sort(:id)
  |> Ash.read_one()

{:ok, last_user} = MyApp.User
  |> Ash.Query.sort(id: :desc)
  |> Ash.read_one()
```

### Update Operations

```elixir
# Update a record
{:ok, updated_user} = user
  |> Ash.Changeset.for_update(:update, %{
    name: "Alice Smith",
    age: 29
  })
  |> Ash.update()

# Bulk update
MyApp.User
  |> Ash.Query.filter(status == "inactive")
  |> Ash.bulk_update(:update, %{status: "archived"})
```

### Delete Operations

```elixir
# Delete a record
:ok = user |> Ash.destroy()

# Bulk delete
MyApp.User
  |> Ash.Query.filter(status == "archived")
  |> Ash.bulk_destroy()
```

---

## Querying

### Filter Operators

```elixir
# Equality
users = MyApp.User |> Ash.Query.filter(name == "John")

# Inequality
users = MyApp.User |> Ash.Query.filter(age != 30)

# Comparison
users = MyApp.User |> Ash.Query.filter(age > 18)
users = MyApp.User |> Ash.Query.filter(age >= 18)
users = MyApp.User |> Ash.Query.filter(age < 65)
users = MyApp.User |> Ash.Query.filter(age <= 65)

# Membership (in list)
users = MyApp.User |> Ash.Query.filter(status in ["active", "pending"])

# String contains (if supported)
users = MyApp.User |> Ash.Query.filter(contains(name, "John"))

# Is nil
users = MyApp.User |> Ash.Query.filter(email == nil)
```

### Combining Filters

```elixir
# AND conditions
users = MyApp.User
  |> Ash.Query.filter(status == "active" and age >= 18)

# OR conditions (may not be supported in all cases - check ScyllaDB limitations)
# If OR is not supported, use multiple queries and combine results

# Nested conditions
users = MyApp.User
  |> Ash.Query.filter((status == "active" or status == "pending") and age >= 18)
```

---

## Data Modeling Best Practices

### 1. Query-First Design

Design your tables based on how you'll query them:

```elixir
# Bad: Trying to query by non-primary key without index
# This won't work efficiently in ScyllaDB
defmodule MyApp.User do
  attributes do
    uuid_primary_key :id
    attribute :email, :string  # Can't efficiently query by email
  end
end

# Good: Use email as partition key if you query by email
defmodule MyApp.User do
  attributes do
    attribute :email, :string, primary_key?: true  # Partition key
    attribute :name, :string
  end
end

# Or use secondary index if email is not the main query pattern
defmodule MyApp.User do
  attributes do
    uuid_primary_key :id
    attribute :email, :string
  end

  ash_scylla do
    secondary_index :email
  end
end
```

### 2. Denormalization

Duplicate data to support different query patterns:

```elixir
# Table for querying posts by author
defmodule MyApp.PostByAuthor do
  use Ash.Resource,
    data_layer: AshScylla.DataLayer

  attributes do
    attribute :author_id, :uuid, primary_key?: true
    attribute :post_id, :uuid, primary_key?: true  # Clustering key
    attribute :title, :string
    attribute :content, :string
    attribute :author_name, :string  # Denormalized
    attribute :created_at, :utc_datetime
  end
end

# Table for querying posts by date
defmodule MyApp.PostByDate do
  use Ash.Resource,
    data_layer: AshScylla.DataLayer

  attributes do
    attribute :date, :date, primary_key?: true  # Partition key
    attribute :post_id, :uuid, primary_key?: true  # Clustering key
    attribute :title, :string
    attribute :content, :string
    attribute :author_id, :uuid
    attribute :author_name, :string  # Denormalized
  end
end
```

### 3. Choosing Partition Keys

```elixir
# Good partition key: High cardinality, evenly distributed
defmodule MyApp.User do
  attributes do
    attribute :user_id, :uuid, primary_key?: true  # Good: UUIDs are random
  end
end

# Bad partition key: Low cardinality
defmodule MyApp.User do
  attributes do
    attribute :status, :string, primary_key?: true  # Bad: Only few values
  end
end

# Good: Composite partition key for time-series data
defmodule MyApp.Event do
  attributes do
    attribute :date, :date, primary_key?: true      # Partition by date
    attribute :event_id, :uuid, primary_key?: true  # Clustering key
    attribute :event_type, :string
    attribute :data, :map
  end
end
```

---

## ScyllaDB-Specific Features

### Consistency Levels

```elixir
defmodule MyApp.CriticalData do
  use Ash.Resource,
    data_layer: AshScylla.DataLayer

  ash_scylla do
    # Strong consistency for critical data
    consistency :all
  end
end

defmodule MyApp.CachedData do
  use Ash.Resource,
    data_layer: AshScylla.DataLayer

  ash_scylla do
    # Eventual consistency for cached data
    consistency :one
  end
end
```

### TTL (Time To Live)

```elixir
defmodule MyApp.Session do
  use Ash.Resource,
    data_layer: AshScylla.DataLayer

  ash_scylla do
    ttl 3600  # Expire after 1 hour
  end

  attributes do
    uuid_primary_key :id
    attribute :user_id, :uuid
    attribute :token, :string
    attribute :expires_at, :utc_datetime
  end
end

defmodule MyApp.CacheEntry do
  use Ash.Resource,
    data_layer: AshScylla.DataLayer

  ash_scylla do
    ttl 300  # Cache entries expire after 5 minutes
  end

  attributes do
    attribute :key, :string, primary_key?: true
    attribute :value, :string
  end
end
```

### Collections

```elixir
defmodule MyApp.User do
  use Ash.Resource,
    data_layer: AshScylla.DataLayer

  attributes do
    uuid_primary_key :id

    # List (ordered, allows duplicates)
    attribute :tags, {:array, :string}

    # Set (unordered, no duplicates) - requires custom type
    # attribute :unique_tags, {:set, :string}

    # Map (key-value pairs)
    attribute :preferences, :map

    # Nested collections
    attribute :scores, {:map, {:string, :integer}}
  end
end

# Working with collections
{:ok, user} = MyApp.User
  |> Ash.Changeset.for_create(:create, %{
    name: "John",
    tags: ["elixir", "scylladb", "ash"],
    preferences: %{"theme" => "dark", "notifications" => "true"}
  })
  |> Ash.create()
```

---

## Migrations

### Creating Tables

```elixir
# priv/repo/migrations/20240101000000_create_users.exs
defmodule MyApp.Repo.Migrations.CreateUsers do
  use Ecto.Migration

  def change do
    execute """
    CREATE TABLE users (
      id UUID PRIMARY KEY,
      name TEXT,
      email TEXT,
      age INT,
      status TEXT,
      created_at TIMESTAMP
    )
    """

    # Create secondary indexes
    execute "CREATE INDEX IF NOT EXISTS idx_users_status ON users (status)"
    execute "CREATE INDEX IF NOT EXISTS idx_users_email ON users (email)"
  end
end
```

### Using AshScylla.Migration Helpers

```elixir
defmodule MyApp.Repo.Migrations.CreateUsers do
  use Ecto.Migration

  def change do
    # Generate CQL from resource (if DSL is fully implemented)
    AshScylla.Migration.create_table_cql(MyApp.User)
    |> execute()

    # Create secondary indexes
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
      zip_code TEXT,
      country TEXT
    )
    """
  end
end
```

---

## Performance Optimization

### 1. Use Appropriate Consistency Levels

```elixir
# Fast reads for non-critical data
defmodule MyApp.PageView do
  use Ash.Resource,
    data_layer: AshScylla.DataLayer

  ash_scylla do
    consistency :one  # Fast, less consistent
  end
end

# Strong consistency for critical data
defmodule MyApp.FinancialTransaction do
  use Ash.Resource,
    data_layer: AshScylla.DataLayer

  ash_scylla do
    consistency :quorum  # Slower, more consistent
  end
end
```

### 2. Connection Pool Tuning

```elixir
# config/prod.exs
config :my_app, MyApp.Repo,
  nodes: ["scylla-1:9042", "scylla-2:9042", "scylla-3:9042"],
  keyspace: "my_app_prod",
  pool_size: 50,              # Increase for high concurrency
  pool_timeout: 15_000,       # Timeout for checkout
  queue_target: 100_000,      # Target queue time
  request_timeout: 300_000,   # Query timeout (5 minutes)
  connect_timeout: 10_000     # Connection timeout
```

### 3. Avoid Expensive Queries

```elixir
# DON'T: Full table scan without partition key
# This is inefficient in ScyllaDB
all_users = MyApp.User |> Ash.read()

# DO: Query by partition key
user = MyApp.User
  |> Ash.Query.filter(id == user_id)
  |> Ash.read_one()

# DO: Use secondary indexes for specific queries
active_users = MyApp.User
  |> Ash.Query.filter(status == "active")
  |> Ash.read()
```

### 4. Batch Operations

```elixir
# Bulk insert for better performance
entries = Enum.map(1..1000, fn i ->
  %{name: "User #{i}", email: "user#{i}@example.com"}
end)

{:ok, _} = entries
  |> Enum.map(fn attrs ->
    Ash.Changeset.for_create(MyApp.User, :create, attrs)
  end)
  |> Ash.bulk_create(MyApp.User, :create, return_records?: false)
```

---

## Common Patterns

### Time-Series Data

```elixir
defmodule MyApp.Metric do
  use Ash.Resource,
    data_layer: AshScylla.DataLayer

  attributes do
    # Partition by day, cluster by timestamp
    attribute :date, :date, primary_key?: true
    attribute :timestamp, :utc_datetime, primary_key?: true
    attribute :metric_name, :string, primary_key?: true
    attribute :value, :float
    attribute :tags, :map
  end

  actions do
    defaults [:create, :read]

    read :by_date do
      argument :date, :date
      filter expr(date == ^arg(:date))
    end

    read :by_timerange do
      argument :start, :utc_datetime
      argument :end, :utc_datetime
      filter expr(timestamp >= ^arg(:start) and timestamp <= ^arg(:end))
    end
  end
end

# Query metrics for a specific day
metrics = MyApp.Metric
  |> Ash.Query.filter(date == ~D[2024-01-15])
  |> Ash.read()
```

### Counters with Materialized Views

```elixir
# Main table
defmodule MyApp.PageView do
  use Ash.Resource,
    data_layer: AshScylla.DataLayer

  attributes do
    attribute :page_id, :string, primary_key?: true
    attribute :user_id, :uuid, primary_key?: true
    attribute :viewed_at, :utc_datetime, primary_key?: true
  end
end

# Counter table (updated separately or via batch)
defmodule MyApp.PageViewCount do
  use Ash.Resource,
    data_layer: AshScylla.DataLayer

  attributes do
    attribute :page_id, :string, primary_key?: true
    attribute :date, :date, primary_key?: true
    attribute :view_count, :integer
  end

  actions do
    create :increment do
      argument :page_id, :string
      argument :date, :date

      change increment(:view_count, 1)
    end
  end
end
```

---

## Troubleshooting

### Common Issues

**1. "No secondary index" error**

```elixir
# Error: Cannot filter by non-primary key without secondary index
users = MyApp.User |> Ash.Query.filter(email == "test@example.com")

# Solution: Add secondary index
# In your resource:
ash_scylla do
  secondary_index :email
end

# Or create the index in a migration:
execute "CREATE INDEX IF NOT EXISTS idx_users_email ON users (email)"
```

**2. Timeout errors**

```elixir
# Increase request_timeout in config
config :my_app, MyApp.Repo,
  request_timeout: 600_000  # 10 minutes
```

**3. Connection pool exhaustion**

```elixir
# Increase pool_size
config :my_app, MyApp.Repo,
  pool_size: 50  # Increase from default 10
```

**4. Inefficient queries**

```elixir
# Check if your query uses partition key or secondary index
# Use EXPLAIN in cqlsh to analyze query performance
```

### Debugging Tips

```elixir
# Enable query logging
config :my_app, MyApp.Repo,
  log: :debug

# Check generated CQL (if using QueryBuilder directly)
{query, params} = AshScylla.DataLayer.QueryBuilder.build_optimized_query(data_layer_query)
IO.inspect(query, label: "CQL Query")
IO.inspect(params, label: "Parameters")
```

---

## Additional Resources

- [ScyllaDB Documentation](https://docs.scylladb.com/)
- [Ash Framework Documentation](https://ash-hq.org/)
- [Exandra Documentation](https://hexdocs.pm/exandra/)
- [CQL Reference](https://cassandra.apache.org/doc/latest/cql/)
