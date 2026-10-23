# Changelog

All notable changes to this project are documented here.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

- **SQL export**: `export_sql(db)` / CLI `dump-sql` dumps a whole database as a
  replayable SQL script (`CREATE` + `INSERT` + `CREATE INDEX` + `COMMIT`). Verified
  by replaying the output through the official `sqlite3` and comparing every row.
- **Public writer constructors**: `TableSpec::new(...)` and `RowSpec::new(...)`,
  so the writer is usable from other packages (struct fields are read-only outside
  the defining package). The CLI now builds its demo database through this public
  API, serving as a usage example.
- `docs/USAGE.md`: a complete usage guide covering the CLI, the read API, the
  writer API, export, the supported subset, limitations and verification steps.
- Continuous integration: `moon check`, `moon test` and `moon build --target js`
  on every push and pull request.

### Fixed

- **Record decoding of 64-bit values**: `serial_type_size` was missing the
  `serial type 7` (float64) branch, so it fell through to the text/BLOB width
  formula and returned a negative width. Every field *after* a `REAL` column was
  therefore read at a wrong offset. `serial type 6` (8-byte integer) was also
  reported as 7 bytes instead of 8. Both are fixed and covered by a regression
  test (`export: 浮点列之后的字段不偏移`).

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
