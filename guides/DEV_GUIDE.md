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
8. [Common Development Tasks](#common-development-tasks)
9. [Troubleshooting](#troubleshooting)

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
  IO.inspect(result.rows, label: "ScyllaDB version")
'
```

### 3. Run the Test Suite

```bash
# Unit tests (no database needed)
mix test --exclude integration
# → 587 tests, 0 failures

# Integration tests (uses the ScyllaDB container)
mix test test/scylla_integration_test.exs
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
│   ├── ash_scylla.ex              # Main module (version)
│   └── ash_scylla/
│       ├── data_layer.ex          # Core CRUD implementation
│       ├── data_layer/
│       │   ├── batch.ex           # Batch operations
│       │   ├── dsl.ex             # Resource DSL (table, keyspace, etc.)
│       │   ├── filter_validator.ex
│       │   ├── materialized_view.ex
│       │   ├── pagination.ex
│       │   └── query_builder.ex
│       ├── error.ex               # Error handling
│       ├── error/
│       │   └── scylla_error.ex    # Structured ScyllaDB errors
│       ├── migration.ex           # CQL schema generation helpers
│       ├── prepared_statement_cache.ex
│       ├── repo.ex                # Repo helpers (keyspace management)
│       ├── resource_generator.ex   # Resource template generator
│       ├── schema.ex               # AshScylla.Schema behaviour for priv/migrations
│       ├── schema_loader.ex        # Schema file discovery and loading
│       └── telemetry.ex
├── lib/mix/tasks/
│   ├── ash_scylla.gen.ex          # mix ash_scylla.gen task (schema migrations from Ash DSL)
│   ├── ash_scylla.new_template.ex # mix ash_scylla.new_template task (resource templates)
│   ├── ash_scylla.migrate.ex      # mix ash_scylla.migrate task (schema + resource migrations)
│   └── ash_scylla.setup.ex        # mix ash_scylla.setup task
├── test/
│   ├── support/                   # Test resources and repos
│   ├── data_layer_crud_test.exs   # New: CRUD unit tests with fake repo
│   └── ...
├── guides/
│   ├── USAGE_GUIDE.md
│   ├── DEV_GUIDE.md
│   ├── PRODUCTION_GUIDE.md
│   ├── ERROR_HANDLING.md
│   ├── IMPLEMENTATION_SUMMARY.md
│   ├── CHANGELOG.md
│   └── CONTRIBUTING.md
├── podman-compose.yml            # ScyllaDB + Elixir container
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

Use the built-in generator to scaffold a resource template:

```bash
mix ash_scylla.gen User name:string, email:string, age:int
```

This creates `lib/my_app/resources/user.ex` with a starter template. Then customize it with ScyllaDB-specific options:

```elixir
# lib/my_app/resources/user.ex
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

### 5. Initialize and Test

```bash
# Create the keyspace
mix run -e 'MyApp.Repo.create_keyspace()'

# Start IEx and play
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

### Test Categories

| Command | What it runs | Needs ScyllaDB? |
|---------|-------------|-----------------|
| `mix test --exclude integration` | All unit tests | No |
| `mix test test/scylla_integration_test.exs` | Integration tests | Yes |
| `mix test test/data_layer_crud_test.exs` | CRUD unit tests | No |
| `mix test --cover` | Unit tests + coverage report | No |

### Test Output

```
$ mix test --exclude integration

.........................
Finished in 1.8 seconds
587 tests, 1 skipped, 60 excluded
```

### Coverage Report

```bash
mix test --exclude integration --cover
```

Generates `cover/index.html` — open it in a browser to see line-by-line coverage.

---

## Common Development Tasks

### Reset the Database

```bash
# Drop and recreate the keyspace
mix run -e '
  MyApp.Repo.drop_keyspace()
  MyApp.Repo.create_keyspace()
'
```

### Inspect Generated CQL

```elixir
# In IEx
alias AshScylla.DataLayer.QueryBuilder

# Build a query struct and inspect
query = %AshScylla.DataLayer{
  resource: MyApp.User,
  repo: MyApp.Repo,
  table: "users",
  filters: [%{operator: :eq, left: %{name: :status}, right: %{value: "active"}}],
  limit: 10
}

{cql, params} = QueryBuilder.build_optimized_query(query)
IO.puts(cql)
# → SELECT * FROM users WHERE status = ? LIMIT ?
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

```elixir
# In IEx
MyApp.Repo.create_keyspace()
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
