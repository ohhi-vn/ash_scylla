# Development Guide: AshScylla with Dev Container

> Get up and running with AshScylla in minutes using VS Code Dev Containers and a single-node ScyllaDB.

---

## Table of Contents

1. [Overview](#overview)
2. [Prerequisites](#prerequisites)
3. [Quick Start](#quick-start)
4. [Project Structure](#project-structure)
5. [Working with the Dev Container](#working-with-the-dev-container)
6. [Your First Resource](#your-first-resource)
7. [Running Tests](#running-tests)
8. [Type Mapping](#type-mapping)
9. [Common Development Tasks](#common-development-tasks)
10. [Troubleshooting](#troubleshooting)

---

## Overview

This guide walks through setting up a complete AshScylla development environment using:

- **VS Code Dev Containers** — reproducible, zero-host-dependency workspace
- **Podman Compose** — single-node ScyllaDB instance with health checks
- **Elixir 1.17** — pre-installed in the container image

The dev container mounts your local source code, so all edits happen on your host machine while compilation and tests run inside the container.

---

## Prerequisites

| Tool | Version | Purpose |
|------|---------|---------|
| [Podman](https://podman.io/) | 4.0+ | Runs the ScyllaDB container |
| [VS Code](https://code.visualstudio.com/) | 1.85+ | IDE with remote container support |
| [Dev Containers extension](https://marketplace.visualstudio.com/items?itemName=ms-vscode-remote.remote-containers) | latest | VS Code → container bridge |

> The `podman-compose.yml` file is at the project root.

---

## Quick Start

### 1. Open in Dev Container

```bash
# Clone the repository
git clone https://github.com/ohhi-vn/ash_scylla.git
cd ash_scylla

# Open in VS Code
code .
```

When VS Code prompts: **"Reopen in Container"** → click **Reopen**.

The first build takes ~2 minutes (downloads Elixir image, installs deps, starts ScyllaDB).

### 2. Verify the Environment

Open a terminal inside VS Code (`` Ctrl+` ``) and run:

```bash
# Check Elixir version
elixir --version
# → Elixir 1.17.x

# Verify ScyllaDB is running
podman ps
# → ash_scylla_test  ...  healthy

# Test the connection
mix run -e '
  {:ok, conn} = Xandra.start_link(nodes: ["scylla:9042"])
  {:ok, result} = Xandra.execute(conn, "SELECT release_version FROM system.local")
  IO.inspect(result, label: "ScyllaDB version")
'
```

### 3. Run the Test Suite

```bash
# Unit tests (no database needed)
mix test --exclude integration

# Integration tests (uses the ScyllaDB container)
mix test test/scylla_integration_test.exs

# Run ScyllaDB config
SCYLLA_DIRECT=1 SCYLLA_HOST=127.0.0.1 SCYLLA_PORT=9042 MIX_ENV=test mix test test/integration --only integration
```

---

## Project Structure

```
ash_scylla/
├── .devcontainer/
│   └── devcontainer.json          # VS Code container config
├── config/
│   ├── config.exs                 # Repo configuration examples
│   ├── dev.exs                    # Development settings
│   └── test.exs                   # Test settings
├── lib/
│   ├── ash_scylla.ex              # Main module (verify, migrate, version)
│   └── ash_scylla/
│       ├── application.ex         # Application callback
│       ├── connection.ex          # Xandra connection GenServer
│       ├── data_layer.ex          # Core CRUD, query building, bulk ops
│       ├── data_layer/
│       │   ├── batch.ex           # Batch operations
│       │   ├── collection.ex      # Collection type support
│       │   ├── compression.ex     # Compression support
│       │   ├── dsl.ex             # Resource DSL (table, keyspace, etc.)
│       │   ├── filter_validator.ex
│       │   ├── materialized_view.ex
│       │   ├── pagination.ex
│       │   ├── query_builder.ex
│       │   ├── query_optimizer.ex
│       │   ├── schema_migration.ex
│       │   ├── types.ex           # Type mapping
│       │   └── udt.ex             # User Defined Types
│       ├── error.ex               # Error handling
│       ├── error/
│       │   └── scylla_error.ex    # Structured ScyllaDB errors
│       ├── identifier.ex          # CQL identifier sanitization
│       ├── migration.ex           # CQL schema generation helpers
│       ├── migrator.ex            # CQL migration runner
│       ├── mix_helpers.ex         # Mix task helpers
│       ├── prepared_statement_cache.ex
│       ├── release.ex             # Release task helpers
│       ├── repo.ex                # Repo behaviour
│       ├── resource_generator.ex  # Resource template generator
│       ├── schema.ex              # Schema migration behaviour
│       ├── schema_loader.ex       # Schema file discovery
│       └── telemetry.ex           # Telemetry integration
├── lib/mix/tasks/
│   ├── ash_scylla.gen.ex          # mix ash_scylla.gen
│   ├── ash_scylla.gen.repo.ex     # mix ash_scylla.gen.repo
│   ├── ash_scylla.migrate.ex      # mix ash_scylla.migrate
│   ├── ash_scylla.new_template.ex # mix ash_scylla.new_template
│   └── ash_scylla.setup.ex        # mix ash_scylla.setup
├── test/
│   ├── test_helper.exs
│   ├── support/                   # Test resources, repos, containers
│   ├── unit/                      # Unit tests by feature domain
│   └── integration/               # Integration tests (need ScyllaDB)
├── guides/                        # Documentation
├── podman-compose.yml             # ScyllaDB + Elixir container
├── mix.exs
└── README.md
```

---

## Working with the Dev Container

### Container Architecture

```
┌─────────────────────────────────────────────────────┐
│  Podman Network (default)                         │
│                                                     │
│  ┌──────────────┐          ┌────────────────────┐  │
│  │   scylla     │◄────────►│       app          │  │
│  │   :9042      │  CQL     │  Elixir 1.17       │  │
│  │              │          │  + deps compiled    │  │
│  └──────────────┘          └────────────────────┘  │
│         ▲                          ▲                │
│         │ healthcheck              │ volume mount   │
│         │ (cqlsh probe)            │ ./ → /workspace│
└─────────────────────────────────────────────────────┘
```

- **`scylla` service**: ScyllaDB single-node, 1 CPU, 1 GB RAM, persistent volume
- **`app` service**: Elixir container with your source code mounted at `/workspace`
- **Health check**: ScyllaDB must pass `cqlsh` probe before `app` starts

### Connecting from the App Container

Use the service name as hostname:

```elixir
# In config/dev.exs or test setup
config :my_app, MyApp.Repo,
  nodes: ["scylla:9042"],   # ← service name, not localhost
  keyspace: "my_app_dev"
```

> **Note:** From your host machine, ScyllaDB is at `localhost:9042`. From inside the `app` container, it's at `scylla:9042`.

### Rebuilding After Dependency Changes

```bash
# Inside the container terminal
mix deps.get
mix compile

# Or rebuild the entire container:
# VS Code → Ctrl+Shift+P → "Rebuild Container"
```

---

## Your First Resource

Create a complete example inside the dev container:

### 1. Create the Repo

```elixir
# lib/my_app/repo.ex
defmodule MyApp.Repo do
  use AshScylla.Repo, otp_app: :my_app
end
```

### 2. Configure

```elixir
# config/config.exs
import Config

config :my_app, MyApp.Repo,
  nodes: ["scylla:9042"],
  keyspace: "my_app_dev",
  pool_size: 5
```

### 3. Generate a Resource

```bash
mix ash_scylla.new_template User name:string, email:string
```

This creates `lib/my_app/resources/user.ex` with a starter template. Then customize it:

```elixir
# lib/my_app/resources/user.ex
defmodule MyApp.User do
  use Ash.Resource,
    data_layer: AshScylla.DataLayer,
    domain: MyApp.Domain


  scylla do
    table "users"
    consistency :quorum
    secondary_index :email
  end

  attributes do
    uuid_primary_key :id
    attribute :name, :string
    attribute :email, :string
    attribute :age, :integer
    attribute :status, :string, default: "active"
  end

  actions do
    defaults [:create, :read, :update, :destroy]
  end
end
```

### 4. Create the Domain

```elixir
# lib/my_app/domain.ex
defmodule MyApp.Domain do
  use Ash.Domain

  resources do
    resource MyApp.User
  end
end
```

### 5. Generate Schema and Migrate

```bash
# Generate schema migration from Ash DSL
mix ash_scylla.gen --dev

# Create the keyspace
mix ash_scylla.setup

# Run migrations
mix ash_scylla.migrate
```

### 6. Start Using It

```bash
iex -S mix
```

```elixir
# In IEx:
alias MyApp.User

# Create
{:ok, user} =
  User
  |> Ash.Changeset.for_create(:create, %{
    name: "Alice",
    email: "alice@example.com",
    age: 30
  })
  |> Ash.create()

# Read
users = User |> Ash.read()

# Query by secondary index
{:ok, found} =
  User
  |> Ash.Query.filter(email == "alice@example.com")
  |> Ash.read_one()

# Update
{:ok, updated} =
  user
  |> Ash.Changeset.for_update(:update, %{age: 31})
  |> Ash.update()

# Delete
:ok = updated |> Ash.destroy()
```

---

## Running Tests

### Quick Reference

```bash
# ── Unit tests ──────────────────────────────────────────────────────────────
# Fast, no database needed. Uses fake/mock repos.
mix test --exclude integration

# With coverage report → cover/index.html
mix test --exclude integration --cover

# ── Integration tests ────────────────────────────────────────────────────────
# Need a running ScyllaDB instance.

# Against the Podman container (dev container default):
mix test --only integration

# Against a local ScyllaDB at localhost:9042:
SCYLLA_DIRECT=1 mix test --only integration

# A single integration file:
SCYLLA_DIRECT=1 mix test test/integration/scylla_integration_test.exs

# ── Cluster integration tests ────────────────────────────────────────────────
# Require a multi-node ScyllaDB (Podman or existing cluster).

# Podman mode (spins up a 3-node cluster via testcontainers):
mix test test/integration/cluster_integration_test.exs --only integration

# Direct mode (connect to an existing multi-node cluster):
TEST_CLUSTER=true SCYLLA_NODES="node1:9042,node2:9042,node3:9042" \
  mix test test/integration/cluster_integration_test.exs --only integration

# Single-node direct mode (connect to one node, multi-node tests skipped):
SCYLLA_DIRECT=1 mix test test/integration/cluster_integration_test.exs --only integration


# ── Benchmarks ───────────────────────────────────────────────────────────────
mix run benchmarks/run_benchmarks.exs
```

### Unit Tests

Unit tests live under `test/unit/` and are organised by feature domain. They use
inline or fake repos — no ScyllaDB instance is required.

```bash
# All unit tests (~1000+)
mix test --exclude integration

# A specific feature domain
mix test test/unit/query/
mix test test/unit/data_layer/
mix test test/unit/batch/

# A single file
mix test test/unit/query/query_builder_test.exs
```

### Integration Tests

Integration tests need a real ScyllaDB instance. They are tagged with `@moduletag :integration`.

```bash
# All integration tests (excludes unit tests)
mix test --only integration

# Against a pre-existing ScyllaDB at localhost:9042
SCYLLA_DIRECT=1 mix test --only integration

# A specific file
SCYLLA_DIRECT=1 mix test test/integration/scylla_integration_test.exs
SCYLLA_DIRECT=1 mix test test/integration/data_layer_integration_test.exs
SCYLLA_DIRECT=1 mix test test/integration/pipeline_integration_test.exs
SCYLLA_DIRECT=1 mix test test/integration/type_roundtrip_integration_test.exs
```

> **Tip:** When `SCYLLA_DIRECT` is set, the cluster integration test
> (`cluster_integration_test.exs`) is automatically skipped because it requires
> multi-node orchestration.

### Cluster Integration Tests

The cluster tests spin up a 3-node ScyllaDB cluster and verify cross-node reads,
writes, and concurrent operations.

```bash
# Podman mode (default — starts containers via testcontainers)
mix test test/integration/cluster_integration_test.exs --only integration

# Direct mode (connect to an existing cluster)
TEST_CLUSTER=true SCYLLA_NODES="node1:9042,node2:9042,node3:9042" \
  mix test test/integration/cluster_integration_test.exs --only integration
```

### Benchmarks

Benchmarks measure query-building performance (not actual database operations).

```bash
mix run benchmarks/run_benchmarks.exs
```

### Coverage Report

```bash
mix test --exclude integration --cover
```

Generates `cover/index.html` — open it in a browser to see line-by-line coverage.

### Running Tests in the Dev Container

The dev container includes a single-node ScyllaDB instance. All tests work out
of the box:

```bash
# Unit tests only (fast, no database needed)
mix test --exclude integration

# Integration tests against the containerized ScyllaDB
mix test --only integration
```

### Running Tests Against a Local ScyllaDB (No Container)

```bash
SCYLLA_DIRECT=1 mix test --only integration
```

---

## Type Mapping

AshScylla maps Elixir types to CQL types via `AshScylla.DataLayer.Types/2`.
The canonical mapping is used across `AshScylla.Migration`, `AshScylla.DataLayer.Udt`,
and `AshScylla.DataLayer.Collection`.

### Ash → CQL Type Mapping

| Ash DSL Type | CQL Type | Notes |
|--------------|----------|-------|
| `:string` | `TEXT` | |
| `:integer` | `BIGINT` | 64-bit; ScyllaDB `INT` is 32-bit |
| `:uuid` | `UUID` | |
| `:boolean` | `BOOLEAN` | |
| `:float` | `DOUBLE` | 8-byte float; ScyllaDB `FLOAT` is 4-byte |
| `:decimal` | `DECIMAL` | |
| `:utc_datetime` | `TIMESTAMP` | |
| `:naive_datetime` | `TIMESTAMP` | |
| `:date` | `DATE` | |
| `:time` | `TIME` | |
| `:binary` | `BLOB` | |
| `:map` | `MAP<K, V>` | Key/value types inferred from attributes |
| `{:array, :string}` | `LIST<TEXT>` | |
| `{:array, :integer}` | `LIST<BIGINT>` | |

Unknown or custom types fall back to `TEXT`.

### Query-Builder Parameter Tagging

When building CQL queries, `AshScylla.DataLayer.QueryBuilder` tags each parameter
with its CQL type to avoid marshalling errors:

| Elixir Value | Tagged As | Reason |
|--------------|-----------|--------|
| Integer (limit, offset) | `{"int", value}` | ScyllaDB `LIMIT` expects 4-byte int, not 8-byte bigint |
| String | `{"text", value}` | |
| UUID binary | `{"uuid", value}` | |
| Float | `{"double", value}` | |
| Boolean | `{"boolean", value}` | |
| `nil` | `nil` | Passed through unchanged |

These tagged tuples are passed to `Xandra.execute/3` directly. When writing tests
that inspect `params` returned by `QueryBuilder.build_optimized_query/1`, assert
against the tagged form:

```elixir
{cql, params} = QueryBuilder.build_optimized_query(query)
assert {"int", 10} in params   # ✅ correct
# assert 10 in params          # ❌ will fail
```

### Collection Types

| Elixir Type | Xandra Encoding | CQL Type |
|-------------|----------------|----------|
| List | Elixir list (preserves order, allows duplicates) | `LIST<T>` |
| MapSet | Elixir `MapSet` (unordered, unique) | `SET<T>` |
| Map | Elixir map | `MAP<K, V>` |
| Frozen | Tuple (immutable, stored as single blob) | `FROZEN<T>` |

### User Defined Types (UDTs)

UDTs are encoded as tuples ordered by their schema field definition. The schema is
derived from the resource's `@dsl` UDT configuration.

```elixir
# Encoding: map → tuple ordered by schema fields
AshScylla.DataLayer.Udt.encode(%{city: "Hanoi", street: "123"}, MyApp.Address)
# → {"Hanoi", "123"}
```

## Common Development Tasks

### Reset the Database

```bash
# Drop and recreate the keyspace
mix run -e '
  MyApp.Repo.drop_keyspace()
  MyApp.Repo.create_keyspace()
'

# Or use the Ash extension callback
mix ash.reset AshScylla
```

### Ash Extension Callbacks

AshScylla implements the full `Ash.Extension` behaviour. The `AshScylla.Extension` module provides:

| Callback | Mix Task | Description |
|----------|----------|-------------|
| `codegen/1` | `mix ash.codegen` | Generate CQL migration files from resources |
| `setup/1` | `mix ash.setup` | Create keyspace and run migrations |
| `migrate/1` | `mix ash.migrate` | Run migration files |
| `install/5` | `mix ash.install` | Install AshScylla for a resource |
| `reset/1` | `mix ash.reset` | Drop keyspace, recreate, re-run migrations |
| `rollback/1` | `mix ash.rollback` | Rollback to a version (logs warning - no CQL DDL rollback) |
| `tear_down/1` | `mix ash.tear_down` | Drop the keyspace |

All callbacks support `--dry-run` flag and handle missing repo gracefully.

### Building CQL Queries from Ash

AshScylla converts Ash queries into optimized CQL via `AshScylla.DataLayer.QueryBuilder`.
The pipeline has three stages:

```
Ash.Resource / Ash.Query
        │
        ▼
AshScylla.DataLayer          # builds the struct
        │
        ▼
QueryBuilder                 # converts filters → CQL WHERE
        │
        ▼
{ cql, params }              # final query + typed parameters
```

#### Stage 1 — Build the Query struct

For resources, let Ash build the struct from the DSL:

```elixir
alias AshScylla.Query

query = Query.from_resource(MyApp.User, MyApp.Domain)
# %AshScylla.Query{resource: MyApp.User, repo: MyApp.Repo, table: "users", ...}
```

For ad-hoc queries (tests, scripts), build the struct manually:

```elixir
query = %AshScylla.Query{
  resource: MyApp.User,     # or nil for resource-less queries
  repo: MyApp.Repo,         # or nil
  table: "users",            # required
  filters: [],
  sorts: [],
  limit: nil,
  select: nil,
  tenant: nil
}
```

#### Stage 2 — Add filters, sorts, limit

Filters use Ash `filter/3` format. Each filter is a map with `operator`,
`left`, and `right` keys:

```elixir
# Equality
%{operator: :eq, left: %{name: :status}, right: %{value: "active"}}

# Comparison
%{operator: :gt, left: %{name: :age}, right: %{value: 18}}
%{operator: :>=, left: %{name: :age}, right: %{value: 18}}
%{operator: :<, left: %{name: :age}, right: %{value: 65}}
%{operator: :<=, left: %{name: :age}, right: %{value: 65}}

# IN clause
%{operator: :in, left: %{name: :status}, right: %{value: ["active", "pending"]}}

# IS NULL
%{operator: :is_nil, left: %{name: :email}, right: true}

# AND / OR (nested)
%{
  op: :and,
  left: %{operator: :eq, left: %{name: :status}, right: %{value: "active"}},
  right: %{operator: :>=, left: %{name: :age}, right: %{value: 18}}
}

%{
  op: :or,
  left: %{operator: :eq, left: %{name: :status}, right: %{value: "active"}},
  right: %{operator: :eq, left: %{name: :status}, right: %{value: "pending"}}
}
```

Add to the query struct:

```elixir
query = query
|> DataLayer.filter(%{operator: :eq, left: %{name: :status}, right: %{value: "active"}})
|> DataLayer.filter(email == "user@example.com")   # Ash DSL syntax also works
|> DataLayer.sort(:name, :asc)
|> DataLayer.limit(10)
|> DataLayer.select([:id, :name, :email])
```

#### Stage 3 — Build and inspect the CQL

```elixir
alias AshScylla.DataLayer.QueryBuilder

{cql, params} = QueryBuilder.build_optimized_query(query)
IO.puts(cql)
# → SELECT id, name, email FROM users WHERE status = ? AND email = ? ORDER BY name ASC LIMIT ?
IO.inspect(params)
# → [{"text", "active"}, {"text", "user@example.com"}, {"int", 10}]
```

#### Execute the query

Pass the `{cql, params}` result directly to `Xandra.execute/4`:

```elixir
{:ok, conn} = Xandra.start_link(nodes: ["127.0.0.1:9042"])

{cql, params} = QueryBuilder.build_optimized_query(query)
{:ok, %Xandra.Page{content: rows}} = Xandra.execute(conn, cql, params, consistency: :one)

Xandra.stop(conn)
```

#### Common query patterns

```elixir
# ── Primary key lookup (most efficient) ────────────────────────────────────
query = %AshScylla.Query{
  table: "users",
  filters: [%{operator: :eq, left: %{name: :id}, right: %{value: user_id}}]
}
# → SELECT * FROM users WHERE id = ?

# ── Secondary index lookup ──────────────────────────────────────────────────
query = %AshScylla.Query{
  table: "users",
  filters: [%{operator: :eq, left: %{name: :email}, right: %{value: "a@b.com"}}]
}
# → SELECT * FROM users WHERE email = ?

# ── Range query on clustering columns ───────────────────────────────────────
query = %AshScylla.Query{
  table: "events",
  filters: [
    %{operator: :eq, left: %{name: :user_id}, right: %{value: user_id}},
    %{operator: :>=, left: %{name: :event_id}, right: %{value: ~U[2024-01-01 00:00:00Z]}}
  ]
}
# → SELECT * FROM events WHERE user_id = ? AND event_id >= ?

# ── COUNT aggregate ────────────────────────────────────────────────────────
query = %AshScylla.Query{
  table: "users",
  filters: [%{operator: :eq, left: %{name: :status}, right: %{value: "active"}}],
  aggregates: [%{kind: :count, name: :total}]
}
# → SELECT COUNT(*) FROM users WHERE status = ?

# ── DISTINCT on partition key ───────────────────────────────────────────────
query = %AshScylla.Query{
  table: "users",
  distinct: [:status]
}
# → SELECT DISTINCT status FROM users

# ── Token-based keyset pagination ───────────────────────────────────────────
query = %AshScylla.Query{
  table: "users",
  keyset: page_token,     # opaque token from previous page
  limit: 25
}
# → SELECT * FROM users LIMIT ?  (with page_state sent to Xandra)

# ── IN clause ───────────────────────────────────────────────────────────────
query = %AshScylla.Query{
  table: "users",
  filters: [%{operator: :in, left: %{name: :id}, right: %{value: [id1, id2, id3]}}]
}
# → SELECT * FROM users WHERE id IN (?, ?, ?)
```

#### Using the full Ash pipeline

The most common path is through Ash actions, which handle everything:

```elixir
# Create — generates INSERT CQL internally
{:ok, user} = Ash.create(MyApp.User, %{name: "Alice", email: "alice@example.com"})

# Read with filters — generates SELECT CQL
users =
  MyApp.User
  |> Ash.Query.filter(status == "active")
  |> Ash.Query.sort(:name)
  |> Ash.Query.limit(10)
  |> Ash.read!()

# Update — generates UPDATE CQL
{:ok, updated} =
  user
  |> Ash.Changeset.for_update(:update, %{name: "Alice Smith"})
  |> Ash.update()

# Delete — generates DELETE CQL
:ok = Ash.destroy(user)
```

To see the CQL that Ash generates, enable debug logging or use the
`AshScylla.Telemetry` span handler:

```elixir
:telemetry.attach(
  "ash-scylla-logger",
  [:ash_scylla, :query, :stop],
  fn _event, measure, _meta, _config ->
    IO.puts("Query took #{System.convert_time_unit(measure.duration, :native, :millisecond)}ms")
  end,
  nil
)
```

### Run Benchmarks

```bash
mix run benchmarks/run_benchmarks.exs
```

### Check Code Quality

```bash
mix format --check-formatted  # Formatting
mix credo --strict            # Static analysis
mix dialyzer                  # Type checking
```

---

## Troubleshooting

### Container won't start

```bash
# Check ScyllaDB logs
podman logs ash_scylla_test

# Common issue: port 9042 already in use
lsof -i :9042
# Kill the conflicting process or change the port in podman-compose.yml
```

### "Connection refused" errors

```bash
# Verify ScyllaDB is healthy
podman ps
# → ash_scylla_test  ...  healthy

# If "starting", wait for health check (up to 60s)
podman inspect --format='{{.State.Health.Status}}' ash_scylla_test
```

### "Keyspace does not exist"

```bash
mix ash_scylla.setup
```

### "OFFSET not supported"

OFFSET is not supported — use keyset pagination via paging_state instead:

```elixir
# Instead of offset
MyApp.User |> Ash.Query.offset(10)  # ❌ Raises error

# Use keyset pagination with limit
MyApp.User |> Ash.Query.limit(10)  # ✅
```

### Tests fail with timeout

ScyllaDB may need more time on first start. Wait 30 seconds and retry:

```bash
sleep 30 && mix test --exclude integration
```

### Rebuild from scratch

```bash
# Remove all containers and volumes
podman-compose -f podman-compose.yml down -v

# Reopen in VS Code → "Reopen in Container"
```
