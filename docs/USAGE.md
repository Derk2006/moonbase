# MoonBase Usage Guide

MoonBase is a zero-FFI, pure-MoonBit library and CLI for the **SQLite database file
format (version 3)**. It can:

- **read** an existing `.db` file: header, B-tree pages, records, `sqlite_master`
  schema, and schema-aware read-only `SELECT` queries;
- **write** a brand-new `.db` file from scratch (header, B-trees, records, overflow
  chains, `sqlite_master`);
- **export** a whole database as a SQL script that the official `sqlite3` replays
  exactly.

There is **no FFI** in the library. It cross-compiles to `js`, `wasm-gc`, `wasm`,
and `native`.

---

## 1. Requirements

- MoonBit toolchain (`moon version` should work).
- Optional, for verification interoperability: the official `sqlite3` CLI, or
  Python's built-in `sqlite3` module.

```bash
# check the toolchain
moon version
```

## 2. Install / depend on MoonBase

The module name is `Derk2006/moonbase`. Add the `src/sqlite` package to your
`moon.pkg` imports:

```
import {
  "Derk2006/moonbase/src/sqlite" @sqlite,
}
```

Then use the API through the `@sqlite` alias.

## 3. Build and run the CLI

```bash
# unit tests (default backend, no FFI needed)
moon test

# the CLI needs the JavaScript backend because it uses Node's fs for real file I/O
moon build --target js
node _build/js/debug/build/cmd/moonbase-cli/moonbase-cli.js
```

## 4. CLI reference

```
moonbase-cli header   <file.db>               print the 100-byte database header
moonbase-cli schema   <file.db>               list tables / indexes / columns
moonbase-cli tree     <file.db> <table>       show the table B-tree root + row count
moonbase-cli query    <file.db> "SELECT ..."  run a read-only query
moonbase-cli dump     <file.db> <table>       export one table (pipe-separated)
moonbase-cli dump-sql <file.db>               export the whole database as SQL
moonbase-cli index    <file.db> <index>       list every entry of an index (key… + rowid)
moonbase-cli check    <file.db>               structural self-check, no sqlite3 required
moonbase-cli make     <out.db> [rows] [page]  generate a legal .db from scratch, with an index
```

### Examples

```bash
# 1) inspect an existing database
node .../moonbase-cli.js header demo.db
node .../moonbase-cli.js schema demo.db
node .../moonbase-cli.js tree   demo.db users

# 2) run a read-only query
node .../moonbase-cli.js query demo.db \
  "SELECT name, score FROM users WHERE score > 80 ORDER BY score DESC"

# 3) generate a brand-new database (pure MoonBit writer, no sqlite3 involved)
node .../moonbase-cli.js make generated.db
#    with 400 rows, which forces the index into a multi-page B-tree
node .../moonbase-cli.js make generated_big.db 400
#    20 000 rows on 512-byte pages: 3-level table tree, 4-level index tree
node .../moonbase-cli.js make generated_deep.db 20000 512
#    structural self-check (works on official sqlite3 files as well)
node .../moonbase-cli.js check generated_deep.db
#    read an index back (works on files written by official sqlite3 too)
node .../moonbase-cli.js index generated.db idx_users_name

# 4) dump the whole database as a replayable SQL script
node .../moonbase-cli.js dump-sql demo.db > demo.sql
sqlite3 restored.db < demo.sql
```

## 5. Library API

### 5.1 Read side

```moonbit
fn dump_users(bytes : Bytes) -> Unit {
  try {
    let db = @sqlite.Db::open(bytes)          // parse the .db bytes
    let t = db.table("users")                 // resolve a table from sqlite_master
    for row in db.rows(t) {                   // full table scan
      let cells : Array[String] = []
      for v in row.values {                   // row.values : Array[Value]
        cells.push(v.to_display())
      }
      println(cells.join("|"))
    }
  } catch {
    e => println("error: \{e.message()}")
  }
}
```

Schema introspection:

```moonbit
let db = @sqlite.Db::open(bytes)
for t in db.schema().tables() {
  println("\{t.name} root=\{(t.rootpage)} cols=\{(t.columns.length())}")
  for c in t.columns {
    println("  \{c.name} \{c.decl_type} pk=\{c.is_pk} alias=\{c.is_rowid_alias}")
  }
}
```

Read-only SQL queries (projection, `AS`, `COUNT(*)`, `WHERE` with 3-valued logic,
`ORDER BY`, `LIMIT`):

```moonbit
let rs = @sqlite.query(db, "SELECT name, score FROM users ORDER BY score DESC LIMIT 3")
println(rs.columns().join("|"))
for r in rs.rows() {          // r : Array[Value]
  println(r.map(fn(v) { v.to_display() }).join("|"))
}
```

`Value` is SQLite's storage-class model:

```moonbit
enum Value {
  VNull
  VInt(Int64)
  VReal(Double)
  VText(String)
  VBlob(Bytes)
}
```

### 5.2 Write side — generate a new `.db`

`TableSpec` and `RowSpec` fields are read-only outside this package, so construct
them through the public factory functions:

```moonbit
let rows : Array[@sqlite.RowSpec] = [
  @sqlite.RowSpec::new(None, [                 // None => auto rowid
    @sqlite.VInt(Int64::from_int(1)),
    @sqlite.VText("Alice"),
    @sqlite.VReal(91.5),
    @sqlite.VBlob(Bytes::from_array([b'\xDE', b'\xAD', b'\xBE', b'\xEF'])),
  ]),
]

let tables : Array[@sqlite.TableSpec] = [
  @sqlite.TableSpec::new(
    "users",
    "CREATE TABLE users(id integer primary key, name text, score real, memo blob)",
    rows,
  ),
]

let bytes = @sqlite.make_db(tables)              // : Bytes
```

Notes:

- `sql` is written verbatim into `sqlite_master.sql`, so the reader can restore
  column names, declared types, `INTEGER PRIMARY KEY` rowid aliasing and
  `WITHOUT ROWID`.
- An `INTEGER PRIMARY KEY` column is stored as `NULL` in the record and keyed by
  the B-tree rowid, exactly as SQLite does.
- `rowid: None` assigns an auto-incrementing rowid; pass `Some(id)` to control it.
- Long records automatically spill into overflow-page chains; many rows
  automatically upgrade a leaf page into an interior page with multiple leaves,
  and — when even the interior page is full — into further interior levels.
  There is no row-count ceiling besides memory.
- Multiple tables can be written into one file.

#### Page size

```moonbit
let bytes = @sqlite.make_db_with_page_size(tables, 512)   // 512, 1024, … 65536
```

The page size drives everything downstream: the header field, the usable bytes per
page, the overflow threshold (`max_local`) and the fan-out of every B-tree. Small
pages therefore exercise the multi-level code path with comparatively few rows —
20 000 rows on 512-byte pages already produce a 3-level table tree and a 4-level
index tree. `65536` is a special case in the format: it is written as `1` into the
2-byte page-size field, and `Pager::open` maps it back.

Any other value is rejected with `BadSql`.

#### Indexes

`TableSpec::with_indexes` adds real index B-trees (leaf page type 10, interior
page type 2) instead of only declaring them in `sqlite_master`:

```moonbit
let idxs : Array[@sqlite.IndexSpec] = [
  @sqlite.IndexSpec::new(
    "idx_users_name",                  // index name
    "users",                           // table name
    "CREATE INDEX idx_users_name ON users(name)",
    ["name"],                          // key columns, in order
  ),
]

let tables : Array[@sqlite.TableSpec] = [
  @sqlite.TableSpec::with_indexes("users", create_sql, rows, idxs),
]
```

Semantics that match SQLite:

- Entries are `(key columns…, rowid)`; the trailing rowid is what makes a
  non-unique index's keys unique.
- Ordering follows SQLite's type order `NULL < number < text < BLOB`, with text
  compared code-point-wise (`BINARY` collation) and ties broken by rowid.
- When an index needs more than one leaf page, the largest key of each leaf is
  **moved up** into the interior page as the separator. It appears exactly once
  in the tree — duplicating it makes `PRAGMA integrity_check` report
  `wrong # of entries in index`.
- Index payloads that exceed the page-local limit spill into overflow pages, just
  like table records.
- An index on an `INTEGER PRIMARY KEY` column stores the real rowid value (the
  table record stores `NULL` there).

Reading side: `Db::index_entries(name)` returns every entry in key order, and
`scan_index` walks interior keys too, so databases written by official `sqlite3`
enumerate correctly.

#### Multi-level trees

B-tree pages are packed bottom-up, level by level, until a single root remains:

- Character (table) B-trees: an interior key is the **maximum rowid of the left
  subtree**. It is a routing key and is *copied*, which is legal because table
  interior keys are not counted as entries.
- Index B-trees: an interior key is a real index entry. It is **moved out** of
  the page below (never copied), so every key exists exactly once in the tree.
  This is the invariant behind `integrity_check`'s `wrong # of entries in index`.

Because each level is built only from the previous level's pages, the number of
levels is unbounded in principle and grows automatically with the data.

### 5.3 Structure self-check

`verify_db` walks the file on its own (it does not go through the query path) and
reports what it finds:

```moonbit
let report = @sqlite.verify_db(db)
if report.passed() {
  println(report.pages_total)      // total pages
  println(report.tables[0].1)      // levels of the first table's B-tree
} else {
  for p in report.problems() { println(p) }
}
```

What it checks:

| Check | Why it matters |
|---|---|
| file length vs `page_size × page_count` | a truncated or mis-declared file must be caught early |
| page ownership: every page used at most once | duplicate references silently corrupt the tree |
| page type vs tree kind (table tree vs index tree) | catches a `WITHOUT ROWID` table misread as a rowid table |
| strict rowid / index-key ordering | catches a wrong separator at any level |
| overflow chains complete and cycle-free | long records |
| freelist pages | official `sqlite3` files after `DELETE` |
| pages nobody references | orphan pages left by a buggy writer |

The CLI wrapper is `moonbase-cli check`; the same command also works on files
produced by the official `sqlite3` (including `WITHOUT ROWID` tables and
overflow pages) and on deliberately corrupted copies, which it rejects.

### 5.4 Export a database as SQL

```moonbit
let sql = @sqlite.export_sql(db)     // CREATE + INSERT + CREATE INDEX + COMMIT
```

The output follows the conventions of `sqlite3 .dump` and is replayable by the
official tool:

```bash
node .../moonbase-cli.js dump-sql demo.db > demo.sql
sqlite3 restored.db < demo.sql
```

Text is escaped per the SQL standard (single quotes doubled), BLOBs are emitted as
`X'..'`, and `NaN` is emitted as `NULL`.

## 6. Supported format / SQL subset

**File format**

- 100-byte header: `page_size` (including the `1 == 65536` encoding), read/write
  versions, `text_encoding` (UTF-8 / UTF-16LE / UTF-16BE), `schema_cookie`,
  `schema_format`, `sqlite_version`.
- Varints: 7-bit groups, up to 9 bytes, including the `2^56` boundary.
- Record serial types: `NULL`, 1/2/3/4/6/8-byte signed integers, float64,
  UTF-8/UTF-16 text, BLOB, and the constants `0` / `1`.
- B-tree pages: leaf table, interior table, leaf index, interior index; local
  payload formula; overflow-page chains with cycle detection.
- `sqlite_master`: table / index / view rows; tolerant `CREATE TABLE` parsing;
  `INTEGER PRIMARY KEY` rowid alias; `WITHOUT ROWID`.

**Queries**

- `SELECT` with column projection and `AS` aliases, `COUNT(*)`;
- `WHERE` with `= <> < <= > >= AND OR NOT IS [NOT] NULL` (three-valued logic);
- `ORDER BY … ASC|DESC` (SQLite BINARY collation, code-point-wise);
- `LIMIT`.

**Writer**

- Databases with one or more tables; leaf → interior B-tree upgrade; overflow
  chains; rowid aliasing; auto rowid.

## 7. Limitations

- The reader is **read-only** over committed pages. It does not implement WAL,
  rollback journals, or crash recovery. Uncommitted / WAL-only pages are out of
  scope.
- `UPDATE` and `DELETE` are not executed against files; MoonBase is a format
  interop layer, not an engine.
- The writer materialises a **fresh, fully committed** single-file database in one
  pass; it does not append to or modify an existing file.
- The writer always uses a 4096-byte page size and UTF-8 text, and builds at most
  one interior level per B-tree (enough for tens of thousands of rows). Deeper
  trees and other page sizes are read correctly but are not generated yet.
- Free-page reuse / `VACUUM` are not implemented.
- Loading extensions, triggers, and virtual tables are out of scope.

## 8. Error handling

All fallible APIs raise `DbError`:

```moonbit
pub suberror DbError {
  BadMagic                 // not a SQLite file
  Truncated(String)
  Unsupported(String)
  Corrupt(String)
  NotFound(String)
  BadSql(String)
}
```

Use `e.message()` for a human-readable description, or `try { … } catch { … }`
to recover.

## 9. Cross-backend notes

The `src/sqlite` package is pure MoonBit and has no backend-specific code. The
**CLI only** uses a tiny `write_file` / `read_file` FFI, implemented with Node's
`fs` on the `js` backend and as a stub elsewhere, so that `moon build` stays green
on every backend.

## 10. Reproducing the verification

```bash
moon test          # 20 unit tests: 10 reader + 5 writer round-trip + 5 export

# writer -> official sqlite3
moon build --target js
node _build/js/debug/build/cmd/moonbase-cli/moonbase-cli.js make out.db
python -c "import sqlite3; c=sqlite3.connect('out.db'); \
  print(c.execute('SELECT * FROM users').fetchall()); \
  print(c.execute('PRAGMA integrity_check').fetchone())"

# export -> official sqlite3 replay
node _build/js/debug/build/cmd/moonbase-cli/moonbase-cli.js dump-sql out.db > out.sql
python -c "import sqlite3; c=sqlite3.connect('restored.db'); \
  c.executescript(open('out.sql').read()); \
  print(c.execute('SELECT * FROM users').fetchall())"
```

Both the generated database and the SQL-replayed database should return identical
rows and `PRAGMA integrity_check` should report `ok`.
