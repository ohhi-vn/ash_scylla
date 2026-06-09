# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.3.0] - 2026-06-09

### Added
- Per-action consistency configuration via `per_action_consistency` DSL option
- Token-based pagination support via `AshScylla.DataLayer.Pagination`
- Prepared statement caching via `AshScylla.PreparedStatementCache` (GenServer + ETS)
- Telemetry integration via `AshScylla.Telemetry` with query/batch span events
- Filter validation to prevent ALLOW FILTERING anti-pattern
- `AshScylla.Error.ScyllaError` structured error types with suggestions
- Retry logic with error-type-specific delays
- `AshScylla.Repo` helper module with `create_keyspace/1`, `drop_keyspace/1`, `recommended_pool_size/0`
- `AshScylla.Migration` helpers for CQL generation from Ash resources
- Materialized view support with CQL generation
- Async partition-aware batch operations via `batch_insert_async/4`
- Dev container support (.devcontainer)
- Testcontainer-based integration tests

## [0.2.0] - 2025-01-01

### Added
- Secondary index support in DSL and migration helpers
- Materialized view DSL configuration
- Batch operations (BATCH INSERT/UPDATE/DELETE)
- Bulk create support via `Ash.bulk_create`
- TTL (Time To Live) support for INSERT statements
- Consistency level configuration per resource
- Comprehensive error handling with Xandra error categorization
- QueryBuilder with filter-to-CQL conversion
- Edge case test suite

## [0.1.0] - 2024-06-01

### Added
- Initial release
- Ash.DataLayer behaviour implementation for ScyllaDB via Exandra
- CRUD operations (create, read, update, destroy)
- Filter, sort, limit, offset, select support
- Multitenancy via keyspace-based tenant isolation
- Basic CQL query generation from Ash queries

[Unreleased]: https://github.com/ohhi-vn/ash_scylla/compare/v0.3.0...HEAD
[0.3.0]: https://github.com/ohhi-vn/ash_scylla/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/ohhi-vn/ash_scylla/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/ohhi-vn/ash_scylla/releases/tag/v0.1.0
