# Contributing to AshScylla

Contributions are welcome!

## Getting Start

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

## Lockfile Policy

We commit `mix.lock` for CI reproducibility. The lockfile does not affect
consumers (they resolve their own dependencies). Periodically update with:

```bash
mix deps.update --all
```

## License

Apache License 2.0
