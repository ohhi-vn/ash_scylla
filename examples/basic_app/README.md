# Basic App - AshScylla Example

This is a simple example application demonstrating how to use AshScylla with ScyllaDB.

## Prerequisites

- Elixir 1.19 or later
- ScyllaDB running on localhost:9042 (or update the config)
- Podman or Docker (optional, for running ScyllaDB)

## Quick Start with Podman

If you don't have ScyllaDB installed, you can run it with Podman:

```bash
podman run --name scylla -p 9042:9042 -d scylladb/scylla:latest
```

Or use the docker-compose file from the main project with Podman Compose:

```bash
cd ../..
podman-compose up -d
```

Or with Docker / Docker Compose:

```bash
docker run --name scylla -p 9042:9042 -d scylladb/scylla:latest
cd ../..
docker compose up -d
```

## Setup

1. **Install dependencies:**

```bash
mix deps.get
```

2. **Create the keyspace:**

```bash
iex -S mix
```

Then in the Elixir shell:

```elixir
BasicApp.Repo.create_keyspace()
```

3. **Create the tables:**

You'll need to create the tables manually or via migrations. Here's the CQL:

```sql
CREATE KEYSPACE IF NOT EXISTS basic_app_dev
  WITH REPLICATION = {
    'class': 'SimpleStrategy',
    'replication_factor': 1
  };

USE basic_app_dev;

CREATE TABLE IF NOT EXISTS users (
  id UUID PRIMARY KEY,
  name TEXT,
  email TEXT,
  status TEXT,
  age INT,
  tags LIST<TEXT>,
  metadata MAP<TEXT, TEXT>,
  created_at TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_users_email ON users (email);
CREATE INDEX IF NOT EXISTS idx_users_status ON users (status);

CREATE TABLE IF NOT EXISTS posts (
  id UUID PRIMARY KEY,
  title TEXT,
  content TEXT,
  status TEXT,
  author_id UUID,
  author_name TEXT,
  author_email TEXT,
  tags LIST<TEXT>,
  view_count INT,
  published_at TIMESTAMP,
  created_at TIMESTAMP
) WITH default_time_to_live = 2592000;

CREATE INDEX IF NOT EXISTS idx_posts_author_id ON posts (author_id);
CREATE INDEX IF NOT EXISTS idx_posts_status ON posts (status);

CREATE TABLE IF NOT EXISTS comments (
  id UUID PRIMARY KEY,
  content TEXT,
  post_id UUID,
  author_id UUID,
  author_name TEXT,
  post_title TEXT,
  status TEXT,
  created_at TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_comments_post_id_status ON comments (post_id, status);
```

## Usage Examples

Start an interactive shell:

```bash
iex -S mix
```

### Creating Users

```elixir
# Register a new user
{:ok, user} = BasicApp.Resources.User.register(
  name: "Alice Johnson",
  email: "alice@example.com",
  age: 30
)

# Create user with metadata
{:ok, user2} = Ash.Changeset.for_create(BasicApp.Resources.User, :create, %{
  name: "Bob Smith",
  email: "bob@example.com",
  age: 25,
  tags: ["elixir", "scylladb"],
  metadata: %{"role" => "admin", "department" => "engineering"}
})
|> Ash.create()
```

### Querying Users

```elixir
# Get all users
{:ok, users} = Ash.read(BasicApp.Resources.User)

# Find user by email (uses secondary index)
{:ok, user} = BasicApp.Resources.User.by_email("alice@example.com")

# Get active users (uses secondary index)
{:ok, active_users} = BasicApp.Resources.User.active_users("active")

# Filter with multiple conditions
{:ok, users} = BasicApp.Resources.User
  |> Ash.Query.filter(age > 25 and status == "active")
  |> Ash.read()

# Sort results
{:ok, users} = BasicApp.Resources.User
  |> Ash.Query.sort(:name)
  |> Ash.read()
```

### Creating Posts

```elixir
# Publish a new post
{:ok, post} = BasicApp.Resources.Post.publish(
  title: "Getting Started with AshScylla",
  content: "AshScylla is a data layer for Ash that works with ScyllaDB...",
  author_id: user.id,
  author_name: "Alice Johnson",
  author_email: "alice@example.com",
  tags: ["elixir", "ash", "scylladb"]
)

# Create another post
{:ok, post2} = Ash.Changeset.for_create(BasicApp.Resources.Post, :create, %{
  title: "Advanced ScyllaDB Patterns",
  content: "When working with ScyllaDB, it's important to...",
  author_id: user.id,
  author_name: "Alice Johnson",
  author_email: "alice@example.com",
  tags: ["scylladb", "performance"]
})
|> Ash.create()
```

### Querying Posts

```elixir
# Get all posts by an author (uses secondary index)
{:ok, posts} = BasicApp.Resources.Post.by_author(user.id)

# Get published posts only
{:ok, published} = BasicApp.Resources.Post.published("published")

# Filter posts by author
{:ok, posts} = BasicApp.Resources.Post
  |> Ash.Query.filter(author_id == user.id)
  |> Ash.read()

# Increment view count
{:ok, updated_post} = post
  |> Ash.Changeset.for_update(:increment_views, %{})
  |> Ash.update()
```

### Creating Comments

```elixir
# Add a comment to a post
{:ok, comment} = BasicApp.Resources.Comment.add_comment(
  content: "Great article! Very helpful.",
  post_id: post.id,
  author_id: user2.id,
  author_name: "Bob Smith",
  post_title: "Getting Started with AshScylla"
)

# Get all comments for a post (uses composite index)
{:ok, comments} = BasicApp.Resources.Comment.by_post(post.id)

# Get approved comments for a post
{:ok, approved} = BasicApp.Resources.Comment.by_post_and_status(post.id, "approved")
```

### Bulk Operations

```elixir
# Create multiple users in bulk
users_data = [
  %{name: "Charlie Brown", email: "charlie@example.com", age: 35},
  %{name: "Diana Prince", email: "diana@example.com", age: 28},
  %{name: "Edward Smith", email: "edward@example.com", age: 42}
]

{:ok, users} = users_data
  |> Enum.map(fn attrs ->
    Ash.Changeset.for_create(BasicApp.Resources.User, :create, attrs)
  end)
  |> Ash.bulk_create(BasicApp.Resources.User, :create)
```

### Working with TTL

Posts in this example have a TTL of 30 days (2,592,000 seconds). After that time, they will be automatically deleted by ScyllaDB.

You can also set TTL on individual records:

```elixir
# Create a post with custom TTL (1 hour)
{:ok, temp_post} = Ash.Changeset.for_create(BasicApp.Resources.Post, :create, %{
  title: "Temporary Post",
  content: "This will expire in 1 hour",
  author_id: user.id,
  author_name: "Alice Johnson"
})
|> Ash.create()

# Note: Custom TTL per record requires custom CQL with USING TTL clause
```

## Key Concepts Demonstrated

1. **Secondary Indexes**: Used on `email`, `status`, `author_id` for efficient querying
2. **TTL (Time To Live)**: Posts automatically expire after 30 days
3. **Denormalization**: Author data is duplicated in posts and comments
4. **Composite Indexes**: Comments have a composite index on `(post_id, status)`
5. **Collection Types**: Using lists (tags) and maps (metadata)
6. **Code Interface**: Convenience functions like `register`, `by_email`, `publish`
7. **Custom Actions**: `register`, `publish`, `increment_views`, `add_comment`
8. **Consistency Levels**: Different consistency levels for different resources

## Cleanup

To remove the keyspace and all data:

```elixir
# In iex
BasicApp.Repo.query("DROP KEYSPACE basic_app_dev")
```

## Next Steps

- Read the main [README.md](../../README.md) for more details
- Check out the [USAGE_GUIDE.md](../../USAGE_GUIDE.md) for advanced patterns
- Explore the [ERROR_HANDLING.md](../../ERROR_HANDLING.md) for error handling strategies
