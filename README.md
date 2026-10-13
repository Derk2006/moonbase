# MoonBase

**A lightweight embedded database kernel written in MoonBit.**

MoonBase is a from-scratch embedded SQL database engine implementing core relational database concepts: recursive-descent SQL parser, B-tree storage engine with range scans, query executor with WHERE evaluation, ORDER BY / LIMIT, DELETE with index rebuild, and transaction support via write-ahead logging.

This project demonstrates that MoonBit is capable of systems programming traditionally done in C/Rust — memory-safe database kernels with predictable performance.

---

## Architecture

```
moonbase/
├── src/
│   ├── types/     Core type system (DataType, Value, Row, Column, Expr, Statement)
│   ├── sql/       Hand-written recursive-descent SQL parser (tokenizer + parser)
│   ├── btree/     B-tree index engine (insert, point lookup, range scan, node splitting)
│   ├── storage/   Table manager (schema + B-tree index + row store)
│   ├── executor/  Query executor (CREATE, INSERT, SELECT, DELETE, projection, sort)
│   └── tx/        Transaction manager (BEGIN, COMMIT, ROLLBACK with WAL)
└── cmd/moonbase-cli/  CLI demo
```

## Features

| Component | Feature | Status |
|---|---|---|
| **SQL Parser** | `CREATE TABLE`, `INSERT`, `SELECT`, `DELETE` | ✅ |
| **SQL Parser** | `WHERE` with `= <> < <= > >= AND OR` | ✅ |
| **SQL Parser** | `ORDER BY <col> [ASC\|DESC]`, `LIMIT n` | ✅ |
| **SQL Parser** | Multi-row `INSERT ... VALUES (...), (...)` | ✅ |
| **Storage** | B-tree index (order-4 to order-N configurable) | ✅ |
| **Storage** | Point lookup by primary key | ✅ |
| **Storage** | Range scan `[start, end]` | ✅ |
| **Storage** | Node splitting (leaf + internal) | ✅ |
| **Storage** | `replace_rows` — rebuilds the primary index after DELETE | ✅ |
| **Executor** | Full-table `SELECT *` | ✅ |
| **Executor** | Column projection `SELECT col1, col2` | ✅ |
| **Executor** | Column-name resolution against the schema | ✅ |
| **Executor** | `DELETE FROM t [WHERE ...]` (index rebuild) | ✅ |
| **Executor** | Mixed-type comparison (Int / Double / Text / Bool / Null) | ✅ |
| **Tx** | `BEGIN` / `COMMIT` / `ROLLBACK` | ✅ |
| **Tx** | Write-ahead log (in-memory) | ✅ |
| **Tests** | 31 unit tests across all packages | ✅ |

## Repository

- GitHub（主仓库）：https://github.com/Derk2006/moonbase
- 码云 Gitee（镜像）：https://gitee.com/EchoDerk/moonbase

## Quick Start

```bash
# Run the test suite
moon test

# Build the CLI demo (JavaScript backend, runs on Node.js)
moon build --target js cmd/moonbase-cli
node _build/js/debug/build/cmd/moonbase-cli/moonbase-cli.js

# WebAssembly backend is also supported
moon build --target wasm cmd/moonbase-cli
```

## Example

```sql
CREATE TABLE users (id INT PRIMARY KEY, name TEXT NOT NULL);
INSERT INTO users (id, name) VALUES (1, 'Alice'), (2, 'Bob'), (3, 'Charlie');

SELECT name FROM users WHERE id = 2;
-- name
-- Bob
-- (1 row)

SELECT * FROM users ORDER BY name DESC LIMIT 2;
-- id    name
-- 3     Charlie
-- 1     Alice
-- (2 row(s))

DELETE FROM users WHERE id = 2;
-- Deleted 1 row(s) from 'users'.
```

## CLI demo output

```
> SELECT * FROM users ORDER BY name DESC
id	name
3	Charlie
1	Alice
2	Bob
(3 row(s))

> DELETE FROM users WHERE id = 2
Deleted 1 row(s) from 'users'.
```

## Design Highlights

- **Zero external dependencies**: Pure MoonBit, no FFI to SQLite or other engines
- **B-tree from scratch**: Leaf/internal node splitting, leaf-level linked list for range scans
- **Type-safe SQL AST**: `Statement` enum with `Select`/`Insert`/`Create`/`Delete` variants
- **Schema-aware executor**: column references resolve by name, projection is a real index remap
- **Reindex-on-write**: DELETE rebuilds the primary-key B-tree so point lookups stay consistent
- **Composable executor**: `Executor` takes a `Statement` and returns a `Result`; easy to extend

## License

Apache-2.0
