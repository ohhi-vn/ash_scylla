# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- **Multi-word search engine** (`AshScylla.Search`) — Lucene/OpenSearch-style full-text search on top of ScyllaDB's inverted index tables:
  - `AshScylla.Search` — public API: `create_tables/2`, `index/5`, `update/5`, `delete/3`, `search/4`, `search!/4`
  - `AshScylla.Search.Analyzer` — text analysis pipeline coordinator (tokenize → normalize → stop words → stem → count)
  - `AshScylla.Search.Analyzer.Tokenizer` — Unicode-aware word tokenization using `[\p{L}\p{N}][\p{L}\p{N}_]*` regex
  - `AshScylla.Search.Analyzer.Normalizer` — lowercase, NFC normalization, punctuation stripping
  - `AshScylla.Search.Analyzer.StopWords` — 100+ English stop words filter
  - `AshScylla.Search.Analyzer.Stemmer` — Porter stemming algorithm (reduces "running"/"runs"/"runner" → "run")
  - `AshScylla.Search.Indexer` — index management coordinator (delegates to Builder/Updater/Deleter)
  - `AshScylla.Search.Indexer.Builder` — UNLOGGED BATCH writes to `search_post_terms` and `search_post_fields`
  - `AshScylla.Search.Indexer.Updater` — diff-based updates (computes added/removed terms vs stored set)
  - `AshScylla.Search.Indexer.Deleter` — removes all term entries for a document
  - `AshScylla.Search.Query.Parser` — query string parser (AND/OR/NOT/phrase support)
  - `AshScylla.Search.Query.Planner` — sharded term lookups across 16 partitions with boolean logic
  - `AshScylla.Search.Query.BooleanEngine` — two-pointer O(n+m) intersection/union/difference
  - `AshScylla.Search.Query.Ranking` — TF, TF-IDF, and BM25 relevance scoring
  - `AshScylla.Search.Query.Paginator` — paginated results with page metadata
  - `AshScylla.Search.Storage` — CQL schema (`search_post_terms` with sharded `(term, shard)` partition key + `search_post_fields`)
  - Unit tests for all pure search modules (79 test cases)

## [1.5.0]

### Changed
- **BREAKING**: Renamed DSL section from `ash_scylla do` to `scylla do` — matches other Ash data layers' naming convention
- **BREAKING**: Moved DSL from `AshScylla.DataLayer.Dsl` into `AshScylla.DataLayer` — resources still need `import AshScylla.DataLayer.Dsl` (which now re-exports the macro from `AshScylla.DataLayer`)
- **BREAKING**: Removed `allow_filtering` DSL option — `ALLOW FILTERING` is never appended to queries; filter on unindexed columns is rejected at query-plan time with actionable error
- **BREAKING**: Removed `offset/3` callback and `offset` field from query struct — CQL does not support OFFSET; use keyset pagination via `paging_state` instead
- **BREAKING**: Default pagination mode changed from `:offset` to `:token`
- **BREAKING**: Removed `AshScylla.Error.retry_delay/1` — callers should implement their own retry policy using `retryable?/1`
- Moved query struct from `AshScylla.DataLayer` to new `AshScylla.Query` module — single ownership of query data
- Created `AshScylla.DataLayer.SecondaryIndex` struct — replaces ad-hoc maps from `parse_secondary_index/1`
- Added cursor encoding/decoding helpers to `AshScylla.DataLayer.Pagination`: `encode_cursor/1`, `decode_cursor/1`, `page_opts/2`, `extract_paging_state/1`
- Consolidated `handle_scylla_result/1` and `handle_query_result/1` into single `handle_result/1` in DataLayer
- Removed `ALLOW FILTERING` from all generated CQL including aggregate queries and system_schema queries
- Removed `needs_allow_filtering?/2` from QueryBuilder
- Updated `AshScylla.DataLayer.QueryOptimizer` to use `AshScylla.Query` and removed `allow_filtering` option
- Updated all documentation, guides, and error messages to reference `scylla` block instead of `ash_scylla`

### Added
- `AshScylla.Query` module — owns the query struct, provides `new/1` and `new/2`
- `AshScylla.DataLayer.SecondaryIndex` module — struct with `parse/1`, `default_name/2`, `effective_name/3`
- `AshScylla.DataLayer.Pagination.encode_cursor/1` — base64url encoding of paging_state
- `AshScylla.DataLayer.Pagination.decode_cursor/1` — base64url decoding of cursor
- `AshScylla.DataLayer.Pagination.page_opts/2` — build query options from paging_state
- `AshScylla.DataLayer.Pagination.extract_paging_state/1` — extract paging_state from result
- Security test suite (130 tests): filter validation, query builder injection prevention, pagination safety, error handling safety, DataLayer security, DSL security, migration security
- **Aggregate support**: `COUNT`, `SUM`, `AVG`, `MIN`, `MAX` aggregates
  - Query-level aggregates via `Ash.count/2`, `Ash.sum/2`, `Ash.avg/2`, `Ash.min/2`, `Ash.max/2`
  - Resource-level `aggregates do` blocks with `belongs_to` relationship traversal
  - Unrelated aggregates via `Ash.Query.aggregate/4`
  - `run_aggregate_query/3` handles all five kinds with field support and `default_value` fallback
  - `attach_aggregates/5` attaches per-record aggregate values during `run_query/2`
- Unit tests for aggregate support (48 tests in `test/unit/data_layer/data_layer_aggregate_test.exs`)

### Fixed
- **Schema migrations never saw the live schema** — `SchemaMigration.fetch_table_schema/2`,
  `fetch_indexes/2`, and `fetch_materialized_views/2` now read `Xandra.Page.content`
  instead of the non-existent `:rows` key, so `diff/2` correctly emits `ALTER TABLE ADD`
  for new attributes on existing tables (previously it silently re-issued a no-op
  `CREATE TABLE IF NOT EXISTS`).
- **`qualified_table/1` crashed for reserved-word table names** (e.g. `order`, `set`,
  `index`) — it now derives the raw, validated table name and quotes only CQL reserved
  words via `QueryBuilder.cql_identifier/1`, matching `source/1`. Write paths no longer
  raise `ArgumentError` for such resources.
- **Writing a `MapSet`/`set<>` attribute crashed** — `Connection.type_value/1` now matches
  `%MapSet{}` before the catch-all `%_{}` struct clause, so SET values are tagged as
  `set<text>` instead of raising `Protocol.UndefinedError`.
- **`Compression.table_compression_cql/2` crashed when options were passed** — dropped the
  redundant second `Enum.map_join` that destructured already-rendered strings; `compression_clause/2`
  inherits the fix.
- **`materialized_view` DSL macro didn't match its documented two-argument form**
  (`materialized_view :name, primary_key: [...], include_columns: [...]`) — added the
  missing clause so the documented syntax compiles.
- **Boolean `false` became `nil` after create/upsert/bulk_create** — `to_ash_record/3` now uses
  `Map.fetch/2` instead of `||` so `false` is preserved.
- **PreparedStatementCache eviction was a no-op** — the ETS match-spec now binds and returns
  the real key (`:"$1"`) instead of the literal `true`, so `evict_oldest/2` actually deletes
  entries and the cache no longer grows unbounded past `@max_cache_size`.
- **`attach_aggregates/5` crashed on timed-out tasks** — now handles `{:exit, reason}` from
  `Task.async_stream` (with `on_timeout: :kill_task`) and tolerates failures by falling back to
  each aggregate's `default_value` instead of failing the whole read.
- **`Batch.batch_insert_async/3` wasn't reliably partition-aware** — grouping now uses the
  resource's real partition-key columns (via `partition_key_columns/1`) instead of assuming the
  first bound parameter is the partition key.
- **In-memory sort fallback sorted by the wrong key** — `maybe_apply_in_memory_sort/3` now
  extracts the field from `{field, direction}` tuples (and `%{field: field}`), matching
  `QueryBuilder.build_order_by/1`'s format, so the secondary-index-scan fallback sort works.
- **Empty `IN ()` lists produced opaque ScyllaDB syntax errors** — `validate_filters/2` now calls
  the previously-dead `validate_in_filters/2`, raising a clear error for empty IN lists (and IN
  on non-queryable columns) before CQL generation.
- **`Connection.query/4` interpolated keyspace without quoting** — `USE <keyspace>` now uses
  `Identifier.quote_name/1` for consistency with other identifier handling.
- **`Codegen.merge_codegen_meta/3` was O(n²)** — precomputes a `MapSet` of current keys instead
  of calling `Map.keys/1` per element inside `Enum.reject/1`.
- Added regression tests covering the above fixes in `test/unit/data_layer/data_layer_bug_fixes_2_test.exs`
  and `test/unit/connection/prepared_statement_cache_test.exs`.

## [1.4.1]

### Changed
- **BREAKING**: Moved DSL from `AshScylla.DataLayer.Dsl` into `AshScylla.DataLayer` — resources still need `import AshScylla.DataLayer.Dsl` (which now re-exports the macro from `AshScylla.DataLayer`)

## [0.13.1]

### Added
- **`AshScylla.Extension` callbacks** — full `Ash.Extension` behaviour implementation with `install/5`, `reset/1`, `rollback/1`, and `tear_down/1` callbacks, enabling `mix ash.install`, `mix ash.reset`, `mix ash.rollback`, and `mix ash.tear_down` support

## [0.13.0]

### Changed
- Credo checks updated to use new module names (Credo.Check.Refactor.*, Credo.Check.Warning.Dbg, etc.)
- Unit tests no longer require Docker/container runtime (lazy-loaded container support)
- Prepared statement cache now uses `{repo, cql, keyspace, opts}` key instead of `phash2(cql)` for safer cross-keyspace isolation
- `mix ash_scylla.migrate` now discovers and executes schema files from `priv/migrations` before resource migrations
- **`mix ash_scylla.gen` repurposed** — now generates schema migration files from Ash DSL resource definitions (was resource template generator). Scans project for `AshScylla.DataLayer` resources and produces `priv/migrations/` files with `CREATE TABLE`/`CREATE INDEX` CQL
- **`mix ash_scylla.new_template`** — new name for the old `mix ash_scylla.gen` resource template generation (`mix ash_scylla.new_template User name:string`)
- Added `AshScylla.DataLayer.QueryOptimizer` module with per-query consistency, timeout, paging hints, and speculative retry policy configuration
- Added `AshScylla.DataLayer.Collection` module for LIST/SET/MAP encoding, CQL generation, and CONTAINS filters
- Added `AshScylla.DataLayer.Compression` module for application-level compression (LZ4, Snappy, Deflate, Zstd)
- Added `AshScylla.DataLayer.Udt` module for User Defined Type encoding/decoding
- Added `AshScylla.DataLayer.SchemaMigration` for automatic schema diff and migration
- Added `AshScylla.Release` module for production migration tasks without Mix installed
- Added `AshScylla.MixHelpers` for shared resource/repo discovery across Mix tasks
- Added `mix ash_scylla.gen.repo` task for generating Repo modules
- Added `AshScylla.Application` module with `:ash_scylla_repo_cache` ETS table

### Fixed
- `run_query/2`: `FilterValidator` is now skipped when `allow_filtering` is enabled on the resource — previously the validator raised before the query builder could append `ALLOW FILTERING`, making the DSL option dead code
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
- **`mix ash_scylla.new_template --domain MyApp.Domain`** — auto-prefixes resource name with domain module (e.g. `User` → `MyApp.Domain.User`)
- **`mix ash_scylla.new_template --resource MyApp.Domain.User`** — uses a fully-qualified resource module name, overriding the positional name
- **`mix ash_scylla.migrate --schemas-only`** — runs only schema files from `priv/migrations` without resource migrations
- **Multi-domain support** — `project_domains/0` and `find_all_resources/0` now gracefully skip invalid/non-DSL domain modules instead of crashing, enabling umbrella apps with mixed domain configurations
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

[Unreleased]: https://github.com/ohhi-vn/ash_scylla/compare/v1.4.1...HEAD
[1.4.1]: https://github.com/ohhi-vn/ash_scylla/compare/v0.13.1...v1.4.1
[0.13.1]: https://github.com/ohhi-vn/ash_scylla/compare/v0.13.0...v0.13.1
[0.13.0]: https://github.com/ohhi-vn/ash_scylla/compare/v0.6.0...v0.13.0
[0.6.0]: https://github.com/ohhi-vn/ash_scylla/compare/v0.4.0...v0.6.0
[0.5.0]: https://github.com/ohhi-vn/ash_scylla/compare/v0.4.0...v0.5.0
[0.4.0]: https://github.com/ohhi-vn/ash_scylla/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/ohhi-vn/ash_scylla/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/ohhi-vn/ash_scylla/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/ohhi-vn/ash_scylla/releases/tag/v0.1.0
