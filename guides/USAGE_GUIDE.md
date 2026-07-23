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
7. [Full-Text Search](#full-text-search)
8. [ScyllaDB Features](#scylladb-features)
9. [Migrations](#migrations)
10. [Ash Extension Callbacks](#ash-extension-callbacks)
11. [Performance Tips](#performance-tips)
12. [Common Patterns](#common-patterns)
13. [Troubleshooting](#troubleshooting)
14. [Additional Resources](#additional-resources)

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

  scylla do
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
# Generate migrations from your Ash resources (writes .exs files to priv/<repo>/migrations)
mix ash_scylla.generate_migrations --dev

# Or use the standard Ash tasks (AshScylla.DataLayer is auto-discovered as the extension):
mix ash.codegen --dev

# Run migrations (includes migration files from priv/<repo>/migrations)
mix ash_scylla.migrate
# or: mix ash.migrate
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

  scylla do
    table "products"
    keyspace "custom_keyspace"
    consistency :quorum
    ttl 3600
    lwt true

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

  scylla do
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

  scylla do
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

# Keyset pagination using paging_state token (recommended for large datasets)
MyApp.User
|> Ash.Query.limit(10)
|> Ash.read!(paging_state: last_paging_state)
```

> **Note:** ScyllaDB/Cassandra does not support `OFFSET` pagination. AshScylla defaults to keyset/`paging_state` token-based pagination for efficient, scalable result traversal.

---

## Aggregates

AshScylla supports `COUNT`, `SUM`, `AVG`, `MIN`, and `MAX` aggregates at the query level and via relationship `aggregates do` blocks.

### Query-Level Aggregates

Use `Ash.count/2`, `Ash.sum/2`, `Ash.avg/2`, `Ash.min/2`, `Ash.max/2` on a query:

```elixir
# COUNT
count =
  MyApp.User
  |> Ash.Query.filter(status == "active")
  |> Ash.count!()

# SUM
total =
  MyApp.Order
  |> Ash.Query.filter(user_id == user_id)
  |> Ash.sum!(:amount)

# AVG / MIN / MAX
avg = MyApp.Order |> Ash.avg!(:amount)
min = MyApp.Order |> Ash.min!(:amount)
max = MyApp.Order |> Ash.max!(:amount)
```

### Resource-Level Aggregates (`aggregates do`)

Define aggregates on a resource that traverse `belongs_to` relationships:

```elixir
defmodule MyApp.Redeem do
  use Ash.Resource,
    domain: MyApp.Domain,
    data_layer: AshScylla.DataLayer

  attributes do
    uuid_primary_key(:id)
    attribute(:redeemed, :boolean)
    attribute(:amount, :integer)
    attribute(:deal_id, :uuid)
  end

  relationships do
    belongs_to(:deal, MyApp.Deal,
      source_attribute: :deal_id,
      primary_key?: true
    )
  end

  aggregates do
    sum :saved_money, [:deal], :amount do
      # where the redeem is redeemed
      filter expr(redeemed == true)

      # where the `deal` is active
      join_filter :deal, expr(active == true)
    end
  end
end
```

Then load them on read:

```elixir
MyApp.Deal
|> Ash.read!(load: [:saved_money])
```

### Unrelated Aggregates

Aggregate over a different resource using `Ash.Query.aggregate/4`:

```elixir
User
|> Ash.Query.aggregate(
  :matching_profiles,
  :count,
  Profile,
  query: [
    filter: expr(name == parent(name))
  ]
)
|> Ash.read!()
```

> **Note:** `has_many` and `many_to_many` relationship aggregates are not yet implemented. Use denormalization or materialized views for those patterns. `:first`, `:list`, `:exists`, and `:custom` aggregate kinds are also not supported.

---

## Full-Text Search

AshScylla includes a built-in inverted-index search engine (`AshScylla.Search`) that enables Lucene/OpenSearch-style multi-word search without `LIKE`, `ALLOW FILTERING`, or secondary indexes.

### Architecture

The search engine stores analyzed terms in two tables:

| Table | Purpose |
|-------|---------|
| `search_post_terms` | Inverted index mapping `(term, shard)` → post_id + term frequency |
| `search_post_fields` | Raw term sets per post/field for diff-based updates |

Terms are sharded across 16 partitions to prevent hotspot partitions for common words.

### Setup

Create the search tables in your keyspace:

```elixir
AshScylla.Search.create_tables(MyApp.Repo, "my_keyspace")
```

### Indexing Documents

```elixir
# Index a document with multiple text fields
AshScylla.Search.index(MyApp.Repo, "my_keyspace", post_id, %{
  title: "Learning Elixir Phoenix Framework",
  body: "Phoenix is a distributed web framework built on Elixir."
})
#=> :ok
```

Each field is run through the full analysis pipeline:
tokenize → lowercased → unicode-normalized → stop words removed → stemmed → written to index.

### Updating Documents

When a document's text changes, compute only the diff:

```elixir
AshScylla.Search.update(MyApp.Repo, "my_keyspace", post_id, %{
  title: "Updated Title",
  body: "New body content"
})
#=> :ok
```

The updater reads the stored term set from `search_post_fields`, computes added/removed terms, and applies only the necessary inserts and deletes. Fields omitted from the map are left unchanged.

### Deleting Documents

```elixir
AshScylla.Search.delete(MyApp.Repo, "my_keyspace", post_id)
#=> :ok
```

### Searching

```elixir
# Basic multi-word AND search
{:ok, page} = AshScylla.Search.search(MyApp.Repo, "my_keyspace", "learning phoenix")
#=> {:ok, %{
#     entries: [{"post-uuid", 2.0}, ...],
#     page_number: 1,
#     page_size: 20,
#     total_count: 1,
#     total_pages: 1,
#     has_next?: false,
#     has_prev?: false
#   }}

# OR search
{:ok, page} = AshScylla.Search.search(repo, keyspace, "elixir OR phoenix")

# NOT search
{:ok, page} = AshScylla.Search.search(repo, keyspace, "phoenix NOT framework")

# Bang variant (raises on error)
page = AshScylla.Search.search!(repo, keyspace, "phoenix")
```

### Search Options

| Option | Default | Description |
|--------|---------|-------------|
| `:page` | `1` | Page number (1-based) |
| `:page_size` | `20` | Results per page |
| `:strategy` | `:tf` | Ranking: `:tf`, `:tfidf`, or `:bm25` |
| `:num_shards` | `16` | Shards per term partition |
| `:analyzer_opts` | `[]` | Passed to the analyzer (`stem`, `remove_stop_words`, `min_length`) |

### Ranking Strategies

```elixir
# Simple TF (Term Frequency) scoring
AshScylla.Search.search(repo, keyspace, "distributed web", strategy: :tf)

# TF-IDF (needs document stats)
AshScylla.Search.search(repo, keyspace, "distributed web",
  strategy: :tfidf,
  total_docs: 100_000,
  doc_freqs: %{"distributed" => 500, "web" => 2000}
)

# BM25 (Okapi BM25)
AshScylla.Search.search(repo, keyspace, "distributed web",
  strategy: :bm25,
  total_docs: 100_000,
  doc_freqs: %{"distributed" => 500, "web" => 2000},
  avg_doc_length: 50.0
)
```

### Text Analysis Pipeline

The default analysis pipeline:

```
Document → Tokenizer → Lowercase → NFC Normalize → Stop Words → Stemmer → Index
```

```elixir
# Analyze text manually to see terms
AshScylla.Search.Analyzer.analyze("The quick brown fox jumps over the lazy dog")
#=> [{"brown", 1}, {"dog", 1}, {"fox", 1}, {"jump", 1}, {"lazi", 1}, {"quick", 1}]

# Analyze with options
AshScylla.Search.Analyzer.analyze("The Running Cats", stem: false, remove_stop_words: false)
#=> [{"cat", 1}, {"run", 1}, {"the", 1}]

# Analyze a query (preserves term order for phrase search)
AshScylla.Search.Analyzer.analyze_query("learning phoenix framework")
#=> ["learn", "phoenix", "framework"]
```

### Integrating with Ash Resources

For a complete integration, call the search functions from custom Ash actions or a search context module:

```elixir
defmodule MyApp.SearchContext do
  alias AshScylla.Search

  @repo MyApp.Repo
  @keyspace "my_app"

  def index_post(post) do
    Search.index(@repo, @keyspace, post.id, %{
      title: post.title,
      body: post.body
    })
  end

  def search(query, opts \\ []) do
    Search.search(@repo, @keyspace, query, opts)
  end
end
```

### Search Tables Schema

```sql
-- Inverted index (sharded to prevent hotspot partitions)
CREATE TABLE search_post_terms (
  term text,
  shard smallint,
  post_id uuid,
  field tinyint,
  tf smallint,
  PRIMARY KEY ((term, shard), post_id)
);

-- Stored term sets for diff-based updates
CREATE TABLE search_post_fields (
  post_id uuid,
  field tinyint,
  terms set<text>,
  PRIMARY KEY (post_id, field)
);
```

### Performance Characteristics

| Stage | Complexity | Notes |
|-------|-----------|-------|
| Tokenization | O(n) | Linear in document length |
| Index Write | O(t) | Linear in unique terms; uses UNLOGGED BATCH |
| Term Lookup | O(1) | Single partition lookup per term/shard |
| AND Merge | O(n+m) | Two-pointer algorithm |
| Ranking | O(k log k) | Sort by score |
| Fetch Posts | O(k) | Linear in matched documents |

Where: **n** = document length, **t** = unique terms, **k** = matched documents.

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
  scylla do
    consistency :quorum  # Strong consistency
  end
end

defmodule MyApp.CachedData do
  scylla do
    consistency :one  # Fast, eventual consistency
  end
end
```

Available levels: `:any`, `:one`, `:two`, `:three`, `:quorum`, `:all`, `:local_quorum`

### TTL (Time To Live)

```elixir
defmodule MyApp.Session do
  scylla do
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
  scylla do
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
  scylla do
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

Use `mix ash_scylla.generate_migrations` (or the standard `mix ash.codegen`) to
generate migration files from your Ash DSL. AshScylla's data layer is
discovered automatically as an Ash extension, so `mix ash.codegen` routes to it:

```bash
# Auto-generate with timestamp-based name (writes .exs files)
mix ash_scylla.generate_migrations --dev

# Or via the standard Ash task:
mix ash.codegen --dev

# With specific migration name
mix ash_scylla.generate_migrations add_user_table

# For a specific domain
mix ash_scylla.generate_migrations --domains MyApp.Domain
```

This creates `.exs` files in `priv/<repo>/migrations/`:

```elixir
# priv/<repo>/migrations/20260615155440_migrate_resources1.exs
defmodule MyApp.Migrations.MigrateResources1 do
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

### Generating Migrations from DSL

Run `mix ash_scylla.generate_migrations` to introspect your Ash resources and generate CQL migration files:

```bash
mix ash_scylla.generate_migrations
# Generated migration: priv/repo/migrations/20240101120000_migration.cql
```

The generated file contains plain CQL:

```sql
-- 20240101120000_migration.cql

CREATE TABLE IF NOT EXISTS users (
  id uuid,
  email text,
  name text,
  age int,
  created_at timestamp,
  PRIMARY KEY (id)
);

CREATE INDEX IF NOT EXISTS idx_users_email ON users (email);
```

You can also generate for a specific name:

```bash
mix ash_scylla.generate_migrations --name add_users
# Generated migration: priv/repo/migrations/20240101120000_add_users.cql
```

### Ash Extension Callbacks

AshScylla implements the `Ash.Extension` behaviour, enabling standard Ash Mix tasks:

```bash
# Install AshScylla for a resource (generates migration files)
mix ash.install AshScylla --resource MyApp.User

# Reset the database (drop keyspace, recreate, re-run migrations)
mix ash.reset AshScylla

# Rollback migrations (note: CQL has no transactional DDL rollback)
mix ash.rollback AshScylla --version 20240101000000

# Tear down (drop keyspace)
mix ash.tear_down AshScylla
```

All callbacks support `--dry-run` to preview actions without executing them.

---

## Performance Tips

### 1. Use Appropriate Consistency Levels

```elixir
defmodule MyApp.PageView do
  scylla do
    consistency :one  # Fast writes, eventual consistency is fine
  end
end

defmodule MyApp.FinancialTransaction do
  scylla do
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
- Avoid unfiltered queries on non-indexed columns (raises error by default); add a `secondary_index` instead
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

  scylla do
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

  scylla do
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
| `Invalid filter` | Non-indexed column filter | Add `secondary_index` to the resource |
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
