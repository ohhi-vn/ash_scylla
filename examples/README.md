# Examples

This directory contains example applications demonstrating how to use AshScylla with ScyllaDB.

## Basic App (`basic_app/`)

A simple blog-like application that demonstrates the core features of AshScylla:

### Features Demonstrated

1. **Basic CRUD Operations** - Create, Read, Update, Delete with Ash resources
2. **Secondary Indexes** - Efficient querying on non-primary key columns
3. **TTL (Time To Live)** - Automatic expiration of records (posts expire after 30 days)
4. **Denormalization** - Author data duplicated in posts and comments (ScyllaDB pattern)
5. **Collection Types** - Using lists (`tags`) and maps (`metadata`)
6. **Composite Indexes** - Multi-column indexes on comments table
7. **Code Interface** - Convenience functions for common operations
8. **Custom Actions** - `register`, `publish`, `increment_views`, `add_comment`
9. **Consistency Levels** - Different consistency settings for different resources
10. **Bulk Operations** - Creating multiple records efficiently

### Structure

```
basic_app/
├── mix.exs                          # Project configuration with dependencies
├── config/
│   └── config.exs                  # ScyllaDB connection configuration
├── lib/
│   └── basic_app/
│       ├── application.ex          # OTP Application definition
│       ├── repo.ex                 # ScyllaDB Repo configuration
│       ├── domain.ex               # Ash Domain with resources
│       ├── migrations.ex           # Helper to create/drop tables
│       └── resources/
│           ├── user.ex             # User resource with secondary indexes
│           ├── post.ex              # Post resource with TTL
│           └── comment.ex           # Comment resource with composite index
└── README.md                       # Detailed usage instructions
```

### Quick Start

```bash
cd examples/basic_app
mix deps.get
iex -S mix
```

Then in the Elixir shell:

```elixir
# Create tables
BasicApp.Migrations.create_tables()

# Start using the app
{:ok, user} = BasicApp.Resources.User.register(
  name: "Alice",
  email: "alice@example.com"
)
```

### Prerequisites

- ScyllaDB running on localhost:9042
- Or use Podman: `podman run --name scylla -p 9042:9042 -d scylladb/scylla:latest`
- Or use Podman: `podman run --name scylla -p 9042:9042 -d docker.io/scylladb/scylla:latest`

## Running Examples

Each example in this directory is a standalone Mix project. To run an example:

1. Navigate to the example directory
2. Run `mix deps.get` to install dependencies
3. Start an interactive shell with `iex -S mix`
4. Follow the instructions in the example's README.md

## Contributing Examples

Feel free to add more examples demonstrating:

- Multitenancy with keyspaces
- Complex data modeling patterns
- Performance optimization techniques
- Integration with Phoenix or other frameworks
- Migration strategies
- Error handling patterns
