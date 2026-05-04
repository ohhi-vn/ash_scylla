# AshScylla

An Ash Framework data layer for ScyllaDB using Exandra (Ecto adapter for Cassandra/ScyllaDB).

## Overview

AshScylla allows you to use ScyllaDB as a persistence layer for your Ash resources. It implements the `Ash.DataLayer` behaviour and uses Exandra to communicate with ScyllaDB/Cassandra using CQL (Cassandra Query Language).

## Features

- **CRUD Operations**: Create, Read, Update, Delete records
- **Filtering**: Filter queries using Ash's powerful filter syntax
- **Sorting**: Sort results by one or more fields
- **Pagination**: Limit and offset support (use with caution in Cassandra)
- **Multitenancy**: Keyspace-based multitenancy support
- **Consistency Levels**: Configure consistency levels for reads/writes

## ScyllaDB-Specific Considerations

### Data Modeling

ScyllaDB is a wide-column store optimized for specific query patterns. Keep these principles in mind:

1. **Query-First Design**: Design your tables around your queries, not the other way around.
2. **Denormalization is Normal**: Duplicate data across tables to support different query patterns.
3. **Partition Keys Matter**: Choose partition keys that distribute data evenly and support your queries.

```elixir
# Good: Query by email (partition key)
defmodule MyApp.User do
  use Ash.Resource,
    data_layer: AshScylla.DataLayer

  attributes do
    attribute :email, :string, primary_key?: true  # Partition key
    attribute :name, :string
  end
end

# Query by partition key (efficient)
user = MyApp.User
  |> Ash.Query.filter(email == "user@example.com")
  |> Ash.read_one()
```

### Secondary Indexes

Secondary indexes allow querying on non-primary key columns, but have limitations:

- **Use for low-cardinality columns**: Avoid indexing high-cardinality columns like email.
- **Equality only**: Secondary indexes work best with equality checks (`==`), not range queries.
- **Performance impact**: Indexes add overhead to writes and may slow down reads.

```elixir
# Define secondary index
defmodule MyApp.User do
  use Ash.Resource,
    data_layer: AshScylla.DataLayer

  ash_scylla do
    secondary_index :status  # For filtering by status
  end

  attributes do
    uuid_primary_key :id
    attribute :status, :string  # Low cardinality: "active", "inactive"
  end
end

# This uses the secondary index
active_users = MyApp.User
  |> Ash.Query.filter(status == "active")
  |> Ash.read()
```

### Consistency Levels

ScyllaDB offers tunable consistency. Configure based on your needs:

```elixir
defmodule MyApp.User do
  use Ash.Resource,
    data_layer: AshScylla.DataLayer

  ash_scylla do
    consistency :quorum  # Options: :any, :one, :two, :three, :quorum, :all, :local_quorum
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

ScyllaDB supports TTL for automatic data expiration:

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
  end
end
```

### Batch Operations

For multiple operations, use batches to reduce network round-trips:

```elixir
# Create multiple records in a batch
users_data = [
  %{name: "Alice", email: "alice@example.com"},
  %{name: "Bob", email: "bob@example.com"},
  %{name: "Charlie", email: "charlie@example.com"}
]

{:ok, users} = users_data
  |> Enum.map(fn attrs ->
    Ash.Changeset.for_create(MyApp.User, :create, attrs)
  end)
  |> Ash.bulk_create(MyApp.User, :create)
```

### Pagination Considerations

ScyllaDB doesn't support traditional OFFSET-based pagination efficiently. Use these alternatives:

1. **Token-based pagination** (recommended):
```elixir
# Use a paging state token (requires custom implementation)
# This is more efficient than OFFSET in ScyllaDB
```

2. **Limit with ordering**:
```elixir
# Get first 10 users
users = MyApp.User
  |> Ash.Query.sort(:id)
  |> Ash.Query.limit(10)
  |> Ash.read()
```

3. **Avoid large offsets**:
```elixir
# DON'T do this for large datasets:
users = MyApp.User
  |> Ash.Query.offset(10000)  # Inefficient in ScyllaDB
  |> Ash.Query.limit(10)
  |> Ash.read()
```

### Lightweight Transactions (LWT)

ScyllaDB supports conditional updates with LWT (compare-and-set):

```elixir
# Use LWT for conditional updates (if supported by your version)
# Note: This requires custom CQL with IF conditions
query = "UPDATE users SET name = ? WHERE id = ? IF name = ?"
MyApp.Repo.query(query, ["New Name", user_id, "Old Name"])
```

### Collections (Lists, Sets, Maps)

ScyllaDB supports collection types:

```elixir
defmodule MyApp.User do
  use Ash.Resource,
    data_layer: AshScylla.DataLayer

  attributes do
    uuid_primary_key :id
    attribute :tags, {:array, :string}  # LIST type
    attribute :scores, :map  # MAP type (requires key/value type configuration)
  end
end
```

### User Defined Types (UDTs)

Define custom types for structured data:

```elixir
# In a migration
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

# Use in resource
defmodule MyApp.User do
  use Ash.Resource,
    data_layer: AshScylla.DataLayer

  attributes do
    uuid_primary_key :id
    attribute :home_address, :udt, type_name: "address"
  end
end
```

## Limitations

Since ScyllaDB/Cassandra is a wide-column store (NoSQL), some features are not supported:

- **No JOINs**: Use denormalization or multiple queries (application-side joins)
- **Limited aggregation**: No GROUP BY, COUNT, SUM across partitions (use materialized views or custom aggregation)
- **No ACID transactions**: Only lightweight transactions (LWT) for single partitions
- **No complex WHERE clauses**: Without secondary indexes, you can only query by primary key
- **No relational integrity**: No foreign keys or constraints
- **No OR conditions**: CQL doesn't support OR in WHERE clauses
- **Limited batch operations**: Batches are for performance, not atomicity

## Installation

Add `ash_scylla` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:ash_scylla, "~> 0.1.0"}
  ]
end
```

## Setup

### 1. Configure a Repo

Create a repo module in your application:

```elixir
# lib/my_app/repo.ex
defmodule MyApp.Repo do
  use AshScylla.Repo,
    otp_app: :my_app
end
```

### 2. Configure the Repo in config/config.exs

```elixir
config :my_app, MyApp.Repo,
  nodes: ["127.0.0.1:9042"],
  keyspace: "my_app_dev",
  pool_size: 10,
  sync_connect: 5000
```

### 3. Create a Keyspace

```elixir
MyApp.Repo.create_keyspace()
```

### 4. Define Your Resource

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

### 5. Create a Domain

```elixir
# lib/my_app/domain.ex
defmodule MyApp.Domain do
  use Ash.Domain

  resources do
    resource MyApp.User
  end
end
```

## Usage

### Basic CRUD Operations

```elixir
# Create a record
{:ok, user} = MyApp.User
  |> Ash.Changeset.for_create(:create, %{name: "John", email: "john@example.com"})
  |> Ash.create()

# Read all records
users = MyApp.User
  |> Ash.read()

# Read with filter
users = MyApp.User
  |> Ash.Query.filter(name == "John")
  |> Ash.read()

# Read with multiple filters
users = MyApp.User
  |> Ash.Query.filter(name == "John" and age > 18)
  |> Ash.read()

# Update a record
{:ok, updated_user} = user
  |> Ash.Changeset.for_update(:update, %{name: "John Doe", age: 31})
  |> Ash.update()

# Delete a record
:ok = user |> Ash.destroy()
```

### Advanced Querying

```elixir
# Sorting results
users = MyApp.User
  |> Ash.Query.sort(:name)
  |> Ash.read()

# Sorting with multiple fields
users = MyApp.User
  |> Ash.Query.sort([:name, :age])
  |> Ash.read()

# Limit results (use with caution in ScyllaDB)
users = MyApp.User
  |> Ash.Query.limit(10)
  |> Ash.read()

# Pagination with limit and offset (not recommended for large datasets)
page1 = MyApp.User
  |> Ash.Query.limit(10)
  |> Ash.Query.offset(0)
  |> Ash.read()

# Select specific fields
names = MyApp.User
  |> Ash.Query.select([:name, :email])
  |> Ash.read()
```

### Working with Relationships (Denormalized)

Since ScyllaDB doesn't support JOINs, you need to denormalize data or make multiple queries:

```elixir
# Approach 1: Denormalize data in the resource
defmodule MyApp.Post do
  use Ash.Resource,
    data_layer: AshScylla.DataLayer,
    repo: MyApp.Repo

  attributes do
    uuid_primary_key :id
    attribute :title, :string
    attribute :content, :string
    # Denormalized author data
    attribute :author_id, :uuid
    attribute :author_name, :string
    attribute :author_email, :string
  end
end

# Approach 2: Multiple queries (application-side join)
defmodule MyApp.Blog do
  use Ash.Domain

  # First query the author
  {:ok, author} = MyApp.User
    |> Ash.Query.filter(id == author_id)
    |> Ash.read_one()

  # Then query their posts
  posts = MyApp.Post
    |> Ash.Query.filter(author_id == author_id)
    |> Ash.read()
end
```

### Multitenancy with Keyspaces

```elixir
# Configure different keyspaces per tenant
defmodule MyApp.User do
  use Ash.Resource,
    data_layer: AshScylla.DataLayer,
    repo: MyApp.Repo

  multitenancy do
    strategy :context
    attribute :tenant_id
  end

  attributes do
    uuid_primary_key :id
    attribute :name, :string
    attribute :tenant_id, :string
  end
end

# Set tenant context
tenant_users = MyApp.User
  |> Ash.set_tenant("tenant_123")
  |> Ash.read()
```

## Secondary Index Support

AshScylla supports ScyllaDB/Cassandra secondary indexes for filtering on non-primary key columns.

### Defining Secondary Indexes

Use the `secondary_index` DSL option in your resource:

```elixir
defmodule MyApp.User do
  use Ash.Resource,
    data_layer: AshScylla.DataLayer

  ash_scylla do
    table "users"
    keyspace "my_app_prod"
    consistency :quorum

    # Single column index
    secondary_index :email

    # Composite index (multiple columns)
    secondary_index [:name, :age]

    # Custom index name
    secondary_index :status, name: "idx_user_status"
  end

  attributes do
    uuid_primary_key :id
    attribute :name, :string
    attribute :email, :string
    attribute :status, :string
    attribute :age, :integer
  end
end
```

### Creating Indexes in Migrations

Generate CQL CREATE INDEX statements using the Migration module:

```elixir
# In your migration file
defmodule MyApp.Repo.Migrations.CreateUserIndexes do
  use Ecto.Migration

  def change do
    AshScylla.Migration.create_secondary_indexes_cql(MyApp.User)
    |> Enum.each(&execute/1)
  end
end
```

This generates CQL like:
```sql
CREATE INDEX IF NOT EXISTS idx_users_email ON users (email);
CREATE INDEX IF NOT EXISTS idx_users_name_age ON users (name, age);
CREATE INDEX IF NOT EXISTS idx_user_status ON users (status);
```

### Filtering with Secondary Indexes

Once indexes are created, you can filter on indexed columns:

```elixir
# This will use the secondary index on email
users = MyApp.User
  |> Ash.Query.filter(email == "john@example.com")
  |> Ash.read()

# This will use the composite index on name and age
users = MyApp.User
  |> Ash.Query.filter(name == "John" and age == 30)
  |> Ash.read()
```

### Important Limitations

1. **Equality checks only**: Secondary indexes work best with equality (`==`) filters. Range queries (`>`, `<`, etc.) on secondary indexes are not recommended.

2. **Performance**: Secondary indexes in ScyllaDB/Cassandra have performance implications. For high-cardinality columns (like email), consider if a secondary index is appropriate.

3. **Multiple indexes**: When filtering on multiple columns, ensure you have a composite index defined, or individual indexes on each column.

4. **Query builder support**: The `AshScylla.DataLayer.QueryBuilder` includes a `can_use_secondary_index?/2` helper to check if your filters can leverage indexes.

```elixir
# Check if filters can use secondary indexes
filters = [%Ash.Filter.Predicate{...}]
case AshScylla.DataLayer.QueryBuilder.can_use_secondary_index?(MyApp.User, filters) do
  {:ok, indexed_columns} ->
    IO.puts("Filters can use indexes: #{inspect(indexed_columns)}")
  {:error, {:missing_indexes, non_indexed}} ->
    IO.puts("Missing indexes for: #{inspect(non_indexed)}")
end
```

## Configuration Options

You can configure ScyllaDB-specific options using the `ash_scylla` DSL section:

```elixir
defmodule MyApp.User do
  use Ash.Resource,
    data_layer: AshScylla.DataLayer

  ash_scylla do
    table "users"              # Override default table name
    keyspace "custom_keyspace"  # Override default keyspace
    consistency :quorum         # Set consistency level
    ttl 3600                    # Default TTL in seconds

    # Define secondary indexes for non-primary key columns
    secondary_index :email
    secondary_index [:name, :age]
  end
end
```

## Connection Pool Tuning

AshScylla uses Ecto's connection pooling through Exandra. Proper pool tuning is essential for performance and reliability.

### Quick Configuration Examples

**Development:**

```elixir
config :my_app, MyApp.Repo,
  nodes: ["127.0.0.1:9042"],
  keyspace: "my_app_dev",
  pool_size: 5,
  sync_connect: 5_000,
  request_timeout: 60_000
```

**Production:**

```elixir
config :my_app, MyApp.Repo,
  nodes: ["scylla-1:9042", "scylla-2:9042", "scylla-3:9042"],
  keyspace: "my_app_prod",
  pool_size: 50,
  sync_connect: 30_000,
  pool_timeout: 15_000,
  queue_target: 100_000,
  queue_interval: 2_000,
  connect_timeout: 10_000,
  request_timeout: 300_000
```

### Pool Configuration Options

| Option | Description | Default | Recommended |
|--------|-------------|---------|-------------|
| `:pool_size` | Number of connections per node | 10 | 5-10 (dev), 25-100 (prod) |
| `:sync_connect` | Initial connection timeout (ms) | 5000 | 5000 (dev), 30000 (prod) |
| `:pool_timeout` | Timeout to checkout connection (ms) | 5000 | 5000-15000 |
| `:queue_target` | Max queue wait time (μs) | 50_000 | 50_000-200_000 |
| `:queue_interval` | Queue measurement window (ms) | 1000 | 1000-5000 |
| `:connect_timeout` | TCP connection timeout (ms) | 5000 | 5000-10000 |
| `:request_timeout` | Query execution timeout (ms) | 120_000 | 60000-600000 |

### Tuning Guidelines

**Pool Size Calculation:**
```
pool_size = (expected_concurrent_queries / number_of_nodes) * 1.5
```

**For High-Throughput Applications:**
- Increase `pool_size` to 75-100
- Set `queue_target` to 150_000-200_000 for burst tolerance
- Monitor pool checkout times and adjust accordingly

**For Simple Queries:**
- `request_timeout`: 60_000 (1 minute)
- `pool_timeout`: 5_000

**For Complex Queries/Batches:**
- `request_timeout`: 300_000-600_000 (5-10 minutes)
- `pool_timeout`: 15_000-20_000

### Example Configurations

See `config/` directory for complete examples:
- `config/dev.exs` - Development configuration
- `config/prod.exs` - Production configuration  
- `config/test.exs` - Test configuration

For detailed explanations of each option, see the documentation in `lib/ash_scylla/repo.ex`.

## Testing

Run the test suite:

```bash
mix test
```

## Documentation

Documentation can be generated with [ExDoc](https://github.com/elixir-lang/ex_doc) and published on [HexDocs](https://hexdocs.pm). Once published, the docs can be found at <https://hexdocs.pm/ash_scylla>.

## Contributing

1. Fork it
2. Create your feature branch (`git checkout -b feature/my-feature`)
3. Commit your changes (`git commit -am 'Add some feature'`)
4. Push to the branch (`git push origin feature/my-feature`)
5. Create a new Pull Request

## License

This project is licensed under the MIT License - see the LICENSE file for details.
