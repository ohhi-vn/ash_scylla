# Contributing to AshScylla

Contributions are welcome! Here's how to get started.

## Development Setup

```bash
# Install dependencies
mix deps.get

# Start ScyllaDB via Docker Compose
docker compose up -d

# Run tests
mix test

# Run unit tests only (no ScyllaDB required)
mix test --exclude integration

# Run integration tests (requires Docker)
mix test test/scylla_integration_test.exs
```

## Code Quality

```bash
# Check formatting
mix format --check-formatted

# Run static analysis
mix credo --strict

# Run type checking
mix dialyzer
```

## Lockfile Policy

We commit `mix.lock` for CI reproducibility. The lockfile does not affect consumers (they resolve their own dependencies). Periodically update with:

```bash
mix deps.update --all
```

## Running Benchmarks

```bash
mix run benchmarks/run_benchmarks.exs
```

Benchmarks measure query building performance, not actual database operations.
```
