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

## Limitations

Since ScyllaDB/Cassandra is a wide-column store (NoSQL), some features are not supported:

- No JOINs (use denormalization or multiple queries)
- Limited aggregation support
- No ACID transactions across partitions (only lightweight transactions)
- No complex WHERE clauses on non-primary key columns without secondary indexes
- No relational integrity constraints

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

```elixir
# Create a user
{:ok, user} = MyApp.User
  |> Ash.Changeset.for_create(:create, %{name: "John", email: "john@example.com"})
  |> Ash.create()

# Read users
users = MyApp.User
  |> Ash.Query.filter(name == "John")
  |> Ash.read()

# Update a user
{:ok, updated_user} = user
  |> Ash.Changeset.for_update(:update, %{name: "John Doe"})
  |> Ash.update()

# Delete a user
:ok = user |> Ash.destroy()
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
  end
end
```

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
