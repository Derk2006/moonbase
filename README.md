# MoonBase — Pure-MoonBit SQLite File-Format Reader & Writer

[![CI](https://github.com/Derk2006/moonbase/actions/workflows/ci.yml/badge.svg)](https://github.com/Derk2006/moonbase/actions/workflows/ci.yml)
[![License: Apache-2.0](https://img.shields.io/badge/license-Apache--2.0-blue.svg)](LICENSE)
[![MoonBit](https://img.shields.io/badge/MoonBit-zero%20FFI-purple.svg)](https://www.moonbitlang.com/)

**A zero-FFI, byte-level reader *and* writer for the real SQLite database file format (version 3), written entirely in MoonBit.**

MoonBase does **not** reimplement a database engine. Instead it speaks the SQLite
on-disk binary format *directly* — the same `.db` files produced by the official
`sqlite3` tool. It can **both** parse existing database files (headers, B-tree
pages, record serial types, the `sqlite_master` schema, schema-aware read-only
SQL queries) **and** *generate* brand-new `.db` files from scratch in pure
MoonBit — no FFI, no C library, no private storage format. The writer is the
inverse of the parser and reuses it for self-verification. MoonBase is a
*format interop layer*, not another engine.

> Pivot note: the project originally started as a from-scratch embedded SQL
> engine (see git history, 22 early commits). After review feedback about
> overlap with existing pure-MoonBit engines, it was redirected to the concrete,
> well-specified SQLite file-format compatibility problem, which is verifiable
> byte-for-byte against the reference implementation.

---

## Status

| Area | State |
|---|---|
| Reader — header / varint / records / B-tree / schema / query | ✅ implemented, unit-tested |
| Writer — `make_db`, overflow chains, leaf→interior upgrade, multi-table | ✅ implemented, opens in official `sqlite3` |
| Writer — index B-trees (leaf type 10 / interior type 2) | ✅ implemented, `PRAGMA integrity_check = ok` + planner uses the index |
| Writer — multi-level B-trees (interior pages of interior pages) | ✅ implemented, 100 000 rows verify `integrity_check = ok` |
| Writer — configurable page size (512 … 65536) | ✅ implemented, incl. the 65536 → `1` header special case |
| Structure self-check — `verify_db` / CLI `check` | ✅ implemented, catches broken pages / duplicated page refs / orphan pages |
| SQL export — `dump-sql` | ✅ implemented, replay-verified by official `sqlite3` |
| Unit tests | ✅ 35 passing (`moon test`) |
| CI | ✅ GitHub Actions (`moon check` / `moon test` / js + wasm-gc builds) |
| License | ✅ Apache-2.0 (`LICENSE`) |
| Cross-backend | ✅ pure MoonBit, zero FFI (js / wasm-gc / wasm / native) |

## Why this direction

| Reviewer concern | How MoonBase answers it |
|---|---|
| **Compatibility target too vague** | The target is precisely the *SQLite Database File Format, version 3* — a documented, versioned binary format (header magic `SQLite format 3\0`, `schema_format` 1–4, `text_encoding` UTF-8/16). We verify against real `sqlite3` output, and our writer's output opens in the official `sqlite3`. |
| **Transaction / persistence boundary unclear** | MoonBase is a *format* tool. The reader operates over committed pages (no WAL/rollback/durability). The writer *materialises* a fresh, fully-committed single-file database in one pass — there is no half-written state and no durability claim. The boundary is crisp. |
| **Overlap with existing engines** | Unlike FFI bindings (`sqlite3.mbt`, which shells out to the C library) we use **zero FFI**. Unlike self-format engines (`otter`/`moonlake`, which invent their own file layout) we target the *industry-standard* SQLite format. Unlike the pure-MoonBit read-only inspector `prowk/MoonSQLiteFile` (which explicitly states it does *not* write files / does not run SQL) MoonBase is **write-capable** — generating valid `.db` files is our headline non-overlapping contribution. The broader pure-MoonBit binary-format ecosystem (BSON, MsgPack, OCaml Marshal, CAN DBC, TTF, CSV) proves the ecosystem values zero-FFI format libraries, but **none of them cover the SQLite on-disk format, let alone generating valid `.db`** — MoonBase fills that gap. We are an interop layer, not a competing engine. See `查重报告_MoonBase.md` for the full cross-version audit. |

---

## Architecture

```
moonbase/
├── src/sqlite/            Pure-MoonBit SQLite file-format layer (zero FFI)
│   ├── value.mbt          Value model, DbError, SQLite collation (NULL<num<text<blob)
│   ├── varint.mbt         SQLite varint encode/decode (7-bit groups, ≤9 bytes)
│   ├── pager.mbt          100-byte DB header + page slicing / usable size
│   ├── record.mbt         Record serial types: int(1..6), float64, text(UTF-8/16), blob, const 0/1
│   ├── btree_file.mbt     B-tree page parse (leaf/interior table & index), overflow chains
│   ├── lexer.mbt          Tolerant DDL lexer for schema text inside the file
│   ├── schema.mbt         sqlite_master scan + CREATE TABLE parser (rowid alias, WITHOUT ROWID)
│   ├── db.mbt             Db facade: open, table lookup, row materialisation
│   ├── query.mbt          Read-only SELECT: projection, COUNT(*), WHERE, ORDER BY, LIMIT (3-valued logic)
│   ├── writer.mbt         **Writer**: make_db — generate valid .db from scratch (header, records, leaves, overflow chains, sqlite_master)
│   ├── writer_tree.mbt    Writer: bottom-up multi-level table & index B-tree construction, page arena, page-size fan-out
│   ├── verify.mbt         Structure self-check: page ownership, page types, key ordering, overflow chains, freelist
│   ├── export.mbt         Export a whole database as a replayable SQL script (export_sql)
│   ├── value_wbtest.mbt   10 reader unit tests
│   ├── writer_wbtest.mbt  14 writer tests (round-trip, float64, overflow, multi-leaf, multi-table, index ordering/separators, 3-level trees, page sizes)
│   ├── verify_wbtest.mbt  5 self-check tests (clean db, overflow, multi-level, two corruption cases)
│   └── export_wbtest.mbt  6 export / SQL-literal tests
└── cmd/moonbase-cli/      CLI demo (js backend; Node fs for real file I/O)
```

## Features

| Component | Feature | Status |
|---|---|---|
| **Header** | 100-byte header: page_size (1→65536), versions, encodings, schema_cookie, sqlite_version | ✅ |
| **Varint** | Decode + encode, 9-byte edge case (`1<<56`) round-trips | ✅ |
| **Record** | Serial types 0/1–6/7/8/9, signed ints, float64, UTF-8 & UTF-16 text, BLOB | ✅ |
| **B-tree** | leaf-table / interior-table / leaf-index / interior-index; local-payload formula; overflow chains with cycle guard | ✅ |
| **Schema** | `sqlite_master` scan; `CREATE TABLE` parser tolerant of constraints; `INTEGER PRIMARY KEY` → rowid alias; `WITHOUT ROWID` | ✅ |
| **Query** | `SELECT *`, column projection + `AS`, `COUNT(*)`, `WHERE` (`= <> < <= > >= AND OR NOT IS [NOT] NULL`), `ORDER BY … ASC|DESC`, `LIMIT` | ✅ |
| **Collation** | Code-point-wise text compare (matches SQLite, *not* MoonBit's length-first order) | ✅ |
| **Writer** | `make_db(Tables)` materialises a valid `.db` **from scratch** in pure MoonBit: 100-byte header, leaf/interior table B-trees, records, overflow-page chains, `sqlite_master` rows; `INTEGER PRIMARY KEY` rowid aliasing, auto rowid, multi-table. Output re-opens in official `sqlite3`. | ✅ |
| **Writer — indexes** | `IndexSpec` / `TableSpec::with_indexes` emit real index B-trees (leaf type 10, interior type 2): keys sorted with SQLite semantics (`NULL < number < text < BLOB`, rowid tie-break), separators promoted out of leaves, payload overflow supported. Verified by `PRAGMA integrity_check` and by the planner choosing the index. | ✅ |
| **Writer — multi-level trees** | Tables and indexes are packed bottom-up into as many interior levels as needed; a separator key is always *removed* from the page below (index B-trees) or *copied* (table B-trees), matching SQLite's two different key semantics. 20 000 rows on 512-byte pages produce a 3-level table tree and a 4-level index tree, still `integrity_check = ok`. | ✅ |
| **Writer — page size** | `make_db_with_page_size(tables, 512…65536)` — header, usable space, overflow thresholds and fan-out all follow the chosen page size; 65536 is encoded as `1` in the 2-byte header field, as the spec requires. | ✅ |
| **Writer — sorting** | Row and index ordering uses a stable bottom-up merge sort (`O(n log n)`), so 100 000-row files build in ~1 s instead of degrading quadratically. | ✅ |
| **Self-check** | `verify_db(db)` / `moonbase-cli check`: walks every tree itself and validates file length vs page count, page ownership (no page referenced twice), page types vs tree kind, strict key/rowid ordering, overflow-chain completeness, freelist and orphan pages. Works on files produced by *official* `sqlite3` too (freelist, overflow, `WITHOUT ROWID`). | ✅ |
| **Export** | `export_sql` / CLI `dump-sql`: dump a whole database as a SQL script (`CREATE` + `INSERT` + `CREATE INDEX` + `COMMIT`); the official `sqlite3` replays it to identical rows (`PRAGMA integrity_check = ok`). | ✅ |
| **FFI** | **None** — pure MoonBit, cross-compiles to js / wasm / native | ✅ |
| **Tests** | 35 unit tests (10 reader + 14 writer + 5 self-check + 6 export); writer output verified re-readable by the in-tree reader **and** by official `sqlite3` fixtures | ✅ |

## Repository

- GitHub (primary): https://github.com/Derk2006/moonbase
- Gitee (mirror): https://gitee.com/EchoDerk/moonbase

## Quick Start

```bash
# Run the test suite (works on default backend — no FFI needed)
moon test

# Build the CLI demo (JavaScript backend, runs on Node.js — real file I/O via Node fs)
moon build --target js
node _build/js/debug/build/cmd/moonbase-cli/moonbase-cli.js

# Build for other backends (CLI uses a stub there; the library is fully cross-target)
moon build            # default backend, builds & tests clean
```

### CLI usage

```
moonbase-cli header <file.db>               print the 100-byte database header
moonbase-cli schema <file.db>               list tables / indexes / columns
moonbase-cli tree   <file.db> <table>       show the table B-tree root + row count
moonbase-cli query  <file.db> "SELECT ..."  run a read-only query
moonbase-cli dump   <file.db> <table>       export the whole table (pipe-separated)
moonbase-cli dump-sql <file.db>             export the whole database as a SQL script
moonbase-cli index  <file.db> <index>       list every entry of an index (key… + rowid)
moonbase-cli check  <file.db>               structural self-check (no sqlite3 needed)
moonbase-cli make   <out.db> [rows] [page]  generate a legal .db from scratch, with an index
```

## Library usage

Add `Derk2006/moonbase/src/sqlite` to your `moon.pkg` imports, then:

```moonbit
// ---- read ----
let db = @sqlite.Db::open(bytes)                       // bytes: Bytes of a .db file
let t  = db.table("users")
for row in db.rows(t) { /* row.values : Array[Value] */ }
let rs = @sqlite.query(db, "SELECT name FROM users ORDER BY name")

// ---- write: generate a brand-new .db from scratch ----
let rows : Array[@sqlite.RowSpec] = [
  @sqlite.RowSpec::new(None, [
    @sqlite.VInt(Int64::from_int(1)),
    @sqlite.VText("Alice"),
  ]),
]
let tables : Array[@sqlite.TableSpec] = [
  @sqlite.TableSpec::new(
    "users",
    "CREATE TABLE users(id integer primary key, name text)",
    rows,
  ),
]
let out_bytes = @sqlite.make_db(tables)                  // page size 4096
let small     = @sqlite.make_db_with_page_size(tables, 512)  // 512 .. 65536

// ---- self-check: walk the file structure without sqlite3 ----
let report = @sqlite.verify_db(db)
if !report.passed() { for p in report.problems() { println(p) } }

// ---- export: dump the whole DB as a replayable SQL script ----
let sql = @sqlite.export_sql(db)
```

See **[docs/USAGE.md](docs/USAGE.md)** for the full API, the supported format/SQL
subset, limitations, and verification steps.

## Documentation

| Document | Contents |
|---|---|
| [docs/USAGE.md](docs/USAGE.md) | Full usage guide: CLI, read API, writer API, self-check, export, limitations |
| [docs/FORMAT_NOTES.md](docs/FORMAT_NOTES.md) | Byte-level notes: page layout, cell formats, separator semantics, multi-level packing, self-check invariants |
| [CHANGELOG.md](CHANGELOG.md) | Release history and notable fixes |

## Example (against a real `sqlite3`-generated file)

```bash
# create a fixture with the official tool
python -c "import sqlite3; c=sqlite3.connect('demo.db'); \
  c.execute('create table t(id integer primary key, name text, score real)'); \
  c.executemany('insert into t values(?,?,?)', [(1,'Alice',91.5),(2,'Bob',88.0),(3,'陈小明',77.25)]); \
  c.commit()"

node _build/js/debug/build/cmd/moonbase-cli/moonbase-cli.js schema demo.db
# table t (root=2, 3 列)
#     id  integer  [INTEGER PRIMARY KEY -> rowid 别名]
#     name  text
#     score  real

node _build/js/debug/build/cmd/moonbase-cli/moonbase-cli.js query demo.db \
  "SELECT name, score FROM t WHERE score > 80 ORDER BY score DESC"
# name|score
# Alice|91.5
# Bob|88
```

The output matches the official `sqlite3` CLI exactly.

## Verification methodology

**Reader side**
1. Generate fixtures with the **official** `sqlite3` (via Python's `sqlite3` module) across
   page sizes, encodings and schemas.
2. Parse the same files with MoonBase and compare header fields, schema and dumped rows
   **byte-for-byte** with `sqlite3` output.
3. Unit tests cover the tricky format corners: 9-byte varint (`2^56`), signed-integer
   serial types, float64, UTF-8/16 text, BLOB, the NULL<number<text<BLOB ordering, and
   code-point text collation.

**Writer side (the headline contribution — generation, not just parsing)**
1. `make_db(...)` produces a `.db` **from scratch** (no `sqlite3` involved in creation).
2. The *same* in-tree parser re-opens the generated bytes and asserts every value decodes
   exactly (round-trip). This is `writer_wbtest.mbt`.
3. The generated file is then opened by the **official** `sqlite3` and queried — proving it
   is a *real* SQLite database, not a private format. Verified across: small tables, exact
   IEEE-754 float64 round-trip (incl. `-0.125`, `π`, `0.0`), >4 KB overflow-page chains,
   300-row trees that force a leaf→interior-page upgrade, and multiple tables in one file.
3a. **Multi-level verification**: `make deep.db 20000 512` builds a database whose
   table tree is 3 levels deep and whose index tree is 4 levels deep. `integrity_check`
   still returns `ok`, `count(*)` matches, and the check script walks the pages itself
   and asserts `depth >= 3` for both trees — a wrong separator promotion at the second
   interior level would either lose keys or duplicate them.
3b. **Index verification**: `make out.db 400` produces an index that needs an interior page.
   `PRAGMA integrity_check` must return `ok` (this catches a wrong leaf/interior split),
   `PRAGMA index_list` must list it, `SELECT count(*) ... INDEXED BY` must equal the row
   count, and `EXPLAIN QUERY PLAN` must report `USING COVERING INDEX`. MoonBase also reads
   indexes written by *official* `sqlite3` (`moonbase-cli index`) and returns the same
   entries in the same order.
3c. **Structural self-check**: `moonbase-cli check` is an independent walker (it does not
   reuse the query path). It is also run against files created by *official* `sqlite3`
   (with a freelist, overflow pages and a `WITHOUT ROWID` table) and must report
   `结构自检通过`; deliberately corrupted copies (illegal page type, page referenced twice,
   `ncell` beyond page capacity) must be rejected.
4. **Export round-trip**: `dump-sql` emits a SQL script from that database, which the
   **official** `sqlite3` replays into a fresh file. Every row is compared value-by-value
   and `PRAGMA integrity_check` must return `ok`. This also covers 64-bit integer extremes
   (`±2^63`) and multi-column records containing `REAL` followed by `BLOB`.

## Example — generate a `.db` with the pure-MoonBit writer

```bash
# Build the CLI (js backend) and generate a legal .db from scratch
moon build --target js
node _build/js/debug/build/cmd/moonbase-cli/moonbase-cli.js make demo_out.db
# generated demo_out.db (users: id INTEGER PK, name TEXT, score REAL, memo BLOB)

# (a) the in-tree reader can read it back
node _build/js/debug/build/cmd/moonbase-cli/moonbase-cli.js query demo_out.db \
  "SELECT name, score FROM users ORDER BY score DESC"

# (b) the OFFICIAL sqlite3 can open it too — proof it is a real SQLite file
python -c "import sqlite3; c=sqlite3.connect('demo_out.db'); \
  print(c.execute('SELECT name, score FROM users ORDER BY score DESC').fetchall())"
```

The writer output is byte-compatible with the SQLite format spec, so any tool that
speaks SQLite — including the reference `sqlite3` — can consume it.

## License

Licensed under the [Apache License, Version 2.0](LICENSE). See [`LICENSE`](LICENSE) for
the full text.
