# MoonBase — Pure-MoonBit SQLite File-Format Reader

**A zero-FFI, byte-level reader/writer for the real SQLite database file format (version 3), written entirely in MoonBit.**

MoonBase does **not** reimplement a database engine. Instead it speaks the SQLite
on-disk binary format *directly* — the same `.db` files produced by the official
`sqlite3` tool. It parses database headers, B-tree pages, record serial types and
the `sqlite_master` schema, then answers read-only SQL queries against existing
database files. There is **no FFI** to `libsqlite3` and **no custom storage
format** — MoonBase is a *format interop layer*, not another engine.

> Pivot note: the project originally started as a from-scratch embedded SQL
> engine (see git history, 22 early commits). After review feedback about
> overlap with existing pure-MoonBit engines, it was redirected to the concrete,
> well-specified SQLite file-format compatibility problem, which is verifiable
> byte-for-byte against the reference implementation.

---

## Why this direction

| Reviewer concern | How MoonBase answers it |
|---|---|
| **Compatibility target too vague** | The target is precisely the *SQLite Database File Format, version 3* — a documented, versioned binary format (header magic `SQLite format 3\0`, `schema_format` 1–4, `text_encoding` UTF-8/16). We verify against real `sqlite3` output. |
| **Transaction / persistence boundary unclear** | MoonBase is **read-only** over committed pages. It does not implement WAL, rollback or durability — so there is no ambiguous persistence claim. The boundary is crisp: parse committed pages, answer queries. |
| **Overlap with existing engines** | Unlike FFI bindings (`sqlite3.mbt`, which shells out to the C library) we use **zero FFI**. Unlike self-format engines (`otter`/`moonlake`, which invent their own file layout) we target the *industry-standard* SQLite format. We are an interop layer, not a competing engine. |

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
│   └── value_wbtest.mbt   10 unit tests
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
| **FFI** | **None** — pure MoonBit, cross-compiles to js / wasm / native | ✅ |
| **Tests** | 10 unit tests; verified against official `sqlite3` fixtures | ✅ |

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
```

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

1. Generate fixtures with the **official** `sqlite3` (via Python's `sqlite3` module) across
   page sizes, encodings and schemas.
2. Parse the same files with MoonBase and compare header fields, schema and dumped rows
   **byte-for-byte** with `sqlite3` output.
3. Unit tests cover the tricky format corners: 9-byte varint (`2^56`), signed-integer
   serial types, float64, UTF-8/16 text, BLOB, the NULL<number<text<BLOB ordering, and
   code-point text collation.

## License

Apache-2.0
