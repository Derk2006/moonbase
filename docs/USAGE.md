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
moonbase-cli make     <out.db>                generate a legal .db from scratch
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
  automatically upgrade a leaf page into an interior page with multiple leaves.
- Multiple tables can be written into one file.

### 5.3 Export a database as SQL

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
