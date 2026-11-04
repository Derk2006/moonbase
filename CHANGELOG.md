# Changelog

All notable changes to this project are documented here.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

- **Query engine extensions**: `LIKE` / `NOT LIKE` (with `%` and `_` wildcards,
  ASCII case-insensitive), `IN (...)` / `NOT IN (...)`, and `BETWEEN … AND …`
  predicates in `WHERE`; aggregates `SUM`, `AVG`, `MIN`, `MAX` (in addition to
  `COUNT(*)` / `COUNT(col)`); `LIMIT n OFFSET m` pagination; and multi-column
  `ORDER BY`. All are covered by 11 new unit tests.
- **Writer text encoding**: `make_db_with_encoding(tables, page_size, enc)` and
  the CLI `make <out.db> [rows] [page] [enc]` generate UTF-8 / UTF-16LE /
  UTF-16BE databases. The encoding is written to header byte 56 and drives the
  serial-type-13 text bodies. Output re-opens in the official `sqlite3` with the
  correct `PRAGMA encoding` and `PRAGMA integrity_check = ok`.
- **UNIQUE indexes**: `IndexSpec::new_unique(...)` emits a `UNIQUE` index; the
  `unique` flag is recognised by `parse_index` on read-back. Composite
  (multi-column) indexes were already supported via `IndexSpec::new` with a
  multi-element `columns` list and are now documented and covered by tests.

### Fixed

- **Stale documentation**: `docs/USAGE.md` still claimed the writer was limited to
  a 4096-byte page size, UTF-8 text and a single interior level per B-tree. Those
  limits were removed in earlier releases (configurable page size, multi-level
  trees); the limitation section is now corrected to reflect the actual
  capabilities.

## [0.1.0] - 2026-10-21

### Added

- Pure-MoonBit SQLite file-format **reader**: 100-byte header, varints, record
  serial types, B-tree pages (table/index, leaf/interior), overflow chains,
  `sqlite_master` schema extraction and a tolerant `CREATE TABLE` parser
  (`INTEGER PRIMARY KEY` rowid alias, `WITHOUT ROWID`).
- Schema-aware read-only query engine: projection, `AS`, `COUNT(*)`, `WHERE`
  (three-valued logic), `ORDER BY`, `LIMIT`; SQLite BINARY collation
  (code-point-wise) and `NULL < number < text < BLOB` ordering.
- Pure-MoonBit SQLite **writer** (`make_db`): generate a valid `.db` from scratch
  — header, leaf/interior table B-trees, records, overflow chains and
  `sqlite_master` rows; rowid aliasing, auto rowid and multiple tables.
- CLI (`header`, `schema`, `tree`, `query`, `dump`, `make`) and 15 unit tests.
- Zero FFI in the library; cross-compiles to js / wasm-gc / wasm / native.
- Apache-2.0 license.
