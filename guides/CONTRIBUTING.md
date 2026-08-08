# Contributing to AshScylla

Contributions are welcome!

## Getting Started

See the **[Development Guide](DEV_GUIDE.md)** for a complete walkthrough: dev
container setup, testing, code quality, and project structure.

## Quick Checklist

```bash
# 1. Install dependencies
mix deps.get

# 2. Run unit tests (no ScyllaDB required)
mix test --exclude integration

# 3. Check code quality
mix format --check-formatted
mix credo --strict
mix dialyzer

# 4. Run all three at once
mix quality
```

## Submitting Changes

1. Fork the repository
2. Create a feature branch: `git checkout -b feature/my-feature`
3. Make your changes
4. Run tests: `mix test --exclude integration`
5. Check quality: `mix quality`
6. Commit: `git commit -am 'Add some feature'`
7. Push: `git push origin feature/my-feature`
8. Open a Pull Request

## Code Quality Standards

### Formatting
```bash
mix format                          # Auto-format
mix format --check-formatted        # CI check
```

### Static Analysis (Credo)
```bash
mix credo --strict                  # All checks
mix credo --strict --only refactor  # Refactoring only
mix credo --strict --only warning   # Warnings only
```

### Type Checking (Dialyzer)
```bash
mix dialyzer                        # Full type check
mix dialyzer --no-check             # Faster (skip PLT check)
```

### All Quality Checks
```bash
mix quality                         # Runs format + credo + dialyzer
```

## Testing Standards

### Unit Tests (No Database)
```bash
# All unit tests
mix test --exclude integration

# Specific feature domain
mix test test/unit/data_layer/
mix test test/unit/query_builder/
mix test test/unit/error/

# Single test file
mix test test/unit/data_layer/data_layer_error_handling_test.exs
```

### Integration Tests (Requires ScyllaDB)
```bash
# Against Podman container (dev container default)
mix test --only integration

# Against local ScyllaDB at localhost:9042
SCYLLA_DIRECT=1 mix test --only integration

# Cluster tests (3-node)
mix test test/integration/cluster_integration_test.exs --only integration
```

### Coverage
```bash
mix test --exclude integration --cover
# Opens cover/index.html in browser
```

## Writing Tests

### Error Handling Tests
- Test all error paths route through `handle_result/1`
- Verify centralized `unknown_filter_error!/1` message consistency
- Use mock repos that return controlled Xandra errors
- See `test/unit/data_layer/data_layer_error_handling_test.exs`

### Query Builder Tests
- Test filter-to-CQL conversion for each operator
- Verify `rewrite_or_to_in/2` with various filter shapes
- Check `build_optimized_query/1` output for complex queries
- See `test/unit/query/query_builder_test.exs`

## Lockfile Policy

We commit `mix.lock` for CI reproducibility. The lockfile does not affect
consumers (they resolve their own dependencies). Periodically update with:

```bash
mix deps.update --all
```

## License

Apache License 2.0
