# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed
- Credo checks updated to use new module names (Credo.Check.Refactor.*, Credo.Check.Warning.Dbg, etc.)
- Unit tests no longer require Docker/container runtime (lazy-loaded container support)
- Prepared statement cache now uses `{repo, cql, keyspace, opts}` key instead of `phash2(cql)` for safer cross-keyspace isolation
- `mix ash_scylla.migrate` now discovers and executes schema files from `priv/migrations` before resource migrations
- **`mix ash_scylla.gen` repurposed** — now generates schema migration files from Ash DSL resource definitions (was resource template generator). Scans project for `AshScylla.DataLayer` resources and produces `priv/migrations/` files with `CREATE TABLE`/`CREATE INDEX` CQL
- **`mix ash_scylla.new_template`** — new name for the old `mix ash_scylla.gen` resource template generation (`mix ash_scylla.new_template User name:string`)

### Fixed
- MaterializedView tests now match quoted identifier output
- `schema_migration.ex` formatting fixes
- `offset/3` now raises with clear error instead of silently dropping
- Fixed `AshScylla.Test.ContainerEngine.ensure_running/0` being undefined when running integration tests (removed env guard on `container_engine.ex` loading)
- Fixed duplicate function clauses and unused default args in `data_layer_pipeline_test.exs`
- Fixed dialyzer type warnings on `rows[0]` access after `length(rows)` check in `scylla_integration_test.exs`
- Fixed unused variable warning in `data_layer_crud_test.exs`
- Fixed dialyzer type mismatch in `edge_cases_test.exs` for `filter_to_cql!(:bad)`

### Added
- `invalidate/4` with repo/opts context for targeted cache invalidation
- `cache_key/4` helper for repo+keyspace-scoped statement caching
- **`AshScylla.Schema`** — behaviour for schema migration modules in `priv/migrations`. Schema files implement `change/0` returning CQL statement lists
- **`AshScylla.SchemaLoader`** — discovers and loads schema migration files from `priv/migrations`
- **`mix ash_scylla.gen --dev`** — auto-generates schema migration from all AshScylla resources with timestamp-based name
- **`mix ash_scylla.gen AddUserTable`** — generates schema migration with a specific module name
- **`mix ash_scylla.gen --resource MyApp.User`** — generates schema for a specific resource only
- **`mix ash_scylla.new_template`** — generates Ash resource templates (old `mix ash_scylla.gen` behavior)
- **`mix ash_scylla.migrate --schemas-only`** — runs only schema files from `priv/migrations` without resource migrations
- `ResourceGenerator.render_create_table/3` — generates `CREATE TABLE IF NOT EXISTS` and `CREATE INDEX IF NOT EXISTS` CQL from attribute lists
- Test coverage for `AshScylla.Schema` behaviour, `AshScylla.SchemaLoader`, `ResourceGenerator.render_create_table/3`, `Mix.Tasks.AshScylla.Gen`, and `Mix.Tasks.AshScylla.NewTemplate`

## [0.10.0]
- Comprehensive test suite (`data_layer_comprehensive_test.exs`) covering 65+ test cases for gaps in existing coverage:
  - `run_query/2` edge cases (empty results, multiple rows, select, distinct, keyset pagination, AND/OR filters, sort+limit, nil content)
  - `filter/3` OR rewriting edge cases (triple OR, different columns, nested AND/OR, single filter)
  - `sort/3` edge cases (empty list, multiple items, map format, tuple format)
  - `bulk_create/3` scenarios (empty list, batch_size, return_records?, error handling, map opts)
  - `source/1` edge cases (empty string table, @table attribute, caching)
  - `repo/1` edge cases (@repo attribute, caching, resource without DSL)
  - `upsert/4` delegation to `upsert/3`
  - `run_aggregate_query/3` (multiple aggregates, COUNT(field), empty aggregates, WHERE clause)
  - `distinct/3` (multiple PK columns, mixed PK/non-PK, empty list)
  - `calculate/3` (multiple calculations, module without calculate/2)
  - `handle_scylla_result/1` (all 6 error paths)
  - `sanitize_identifier/1` (valid/invalid identifiers)
  - `maybe_rewrite_or_to_in/1` (4-way OR, nested AND, single equality)
  - DataLayer struct defaults verification
  - Exhaustive `can?/2` feature testing (supported, unsupported, tuples, nil/string/integer)

### Fixed
- `Mix.Tasks.AshScylla.Setup`: Fixed `ArgumentError: invalid switch types/modifiers: :atom` by changing `OptionParser` switch type from `:atom` to `:string` with runtime module resolution
- `Mix.Tasks.AshScylla.Setup`: Fixed hardcoded `:storage_service` app reference — now dynamically detects the OTP app from `Mix.Project.config()`
- `Mix.Tasks.AshScylla.Setup`: Now runs `mix compile` before resolving the repo module, ensuring the module is available when passed as `--repo`
- `Mix.Tasks.AshScylla.Setup`: Improved error message when no repo is found — now suggests running `mix ash_scylla.gen.repo` first
- `run_aggregate_query/3`: Handle empty page content (`[]` and `nil`) gracefully by returning `0` instead of crashing with `MatchError`
- `fetch_by_primary_key/3`: Return structured `ScyllaError` for empty results instead of crashing with `MatchError`
- Updated README test structure documentation
- Updated error handling guide with record-not-found and aggregate empty result scenarios

## [0.6.0] - 2026-06-11

### Changed
- **BREAKING**: Migrated from Exandra/Ecto.Repo pattern to direct Xandra connections. `AshScylla.Repo` now wraps `AshScylla.Connection` (a GenServer around `Xandra.start_link/1`) instead of using Ecto.Repo.
- `AshScylla.Connection` replaces the Exandra/Ecto.Repo pattern for direct Xandra connection management.
- `AshScylla.Migrator` now uses `AshScylla.Connection` instead of Ecto SQL migrations.
- Resource definitions now use `domain:` instead of `repo:` (Ash Framework best practice).
- Relaxed Ash dependency from `~> 3.28` to `~> 3.0` for broader compatibility.

### Added
- `AshScylla.Connection` — direct Xandra connection wrapper with `query/4`, `query!/4`, `prepare/3`, `prepare!/3`, `stop/1`.
- `AshScylla.Migrator.run_on/2` and `run_on!/2` — execute CQL on an existing named connection.
- Prepared statement caching via `AshScylla.PreparedStatementCache`.
- Telemetry integration via `AshScylla.Telemetry`.
- Token-based pagination via `AshScylla.DataLayer.Pagination`.
- Async partition-aware batch operations via `AshScylla.DataLayer.Batch.batch_insert_async/3`.

### Fixed
- All documentation and examples updated to reflect Xandra migration (no more Ecto.Repo, Ecto.Migration, or Exandra references in user-facing code).
- Mock repos in tests now return proper `Xandra.Page` structs instead of plain maps.

## [0.5.0] - 2026-06-11

### Added
- `@spec` annotations across all public and private API modules.
- `dialyxir` for CI type checking.
- Filter validation to prevent ALLOW FILTERING anti-pattern.
- `AshScylla.ResourceGenerator` — `mix ash_scylla.gen` task for scaffolding resources.
- Dev container support (.devcontainer).

### Fixed
- Integration tests can now be run with `mix test test/scylla_integration_test.exs --only integration`.
- Removed unused `require Logger` from several modules.
- Updated README feature/limitation tables for ScyllaDB accuracy.

## [0.4.0] - 2026-06-10

### Changed
- **BREAKING**: Removed `:sort` and `:offset` from `@supported_features` — these are not natively supported by ScyllaDB and were causing silent failures. `can?(:sort)` and `can?(:offset)` now return `false`.
- Added `data_layer_keyset_by_default?/0` returning `true` — keyset pagination is now the default pagination mode.
- Added runtime `Logger.warning` in `sort/3` and `offset/3` callbacks to alert callers about ScyllaDB limitations.
- Relaxed Ash dependency from `~> 3.24` to `~> 3.0` for broader compatibility.
- Moved `AshScylla.Repo` and `AshScylla.Migration` out of the Core ExDoc group into "Repo Helpers" and "Schema Helpers" respectively.
- Clarified `AshScylla.Migration` docs — it generates raw CQL DDL strings, not Ecto SQL migrations.
- Updated `IMPLEMENTATION_SUMMARY.md` dependency table to remove incorrect `reactor` and `testcontainers` entries, add missing dev deps.

### Fixed
- Removed unused `require Logger` from `FilterValidator`, `Dsl`, `Telemetry` and `require Xandra` from `DataLayer`.
- Updated test assertions to match new `can?/2` behavior and current version `0.4.0`.

## [0.3.0] - 2026-06-09

### Added
- Per-action consistency configuration via `per_action_consistency` DSL option
- Token-based pagination support via `AshScylla.DataLayer.Pagination`
- Prepared statement caching via `AshScylla.PreparedStatementCache` (GenServer + ETS)
- Telemetry integration via `AshScylla.Telemetry` with query/batch span events
- `AshScylla.Error.ScyllaError` structured error types with suggestions
- Retry logic with error-type-specific delays
- `AshScylla.Repo` helper module with `create_keyspace/1`, `drop_keyspace/1`, `recommended_pool_size/0`
- `AshScylla.Migration` helpers for CQL generation from Ash resources
- Materialized view support with CQL generation
- Async partition-aware batch operations via `batch_insert_async/4`
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
- Ash.DataLayer behaviour implementation for ScyllaDB via Xandra
- CRUD operations (create, read, update, destroy)
- Filter, sort, limit, offset, select support
- Multitenancy via keyspace-based tenant isolation
- Basic CQL query generation from Ash queries

[Unreleased]: https://github.com/ohhi-vn/ash_scylla/compare/v0.6.0...HEAD
[0.6.0]: https://github.com/ohhi-vn/ash_scylla/compare/v0.4.0...v0.6.0
[0.5.0]: https://github.com/ohhi-vn/ash_scylla/compare/v0.4.0...v0.5.0
[0.4.0]: https://github.com/ohhi-vn/ash_scylla/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/ohhi-vn/ash_scylla/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/ohhi-vn/ash_scylla/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/ohhi-vn/ash_scylla/releases/tag/v0.1.0
