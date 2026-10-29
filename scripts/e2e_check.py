#!/usr/bin/env python3
"""End-to-end interop check for MoonBase.

Proves that MoonBase's writer produces *real* SQLite files:

1. The generated `.db` opens in the *official* SQLite (via Python's `sqlite3`),
   its rows match what MoonBase claims, and `PRAGMA integrity_check = ok`.
2. The index B-tree written by MoonBase is a valid index: it is listed in
   `PRAGMA index_list`, the query planner picks it, and its entry count matches
   the table (this is what catches a wrong split between leaf and interior pages).
3. The SQL script exported by MoonBase (`dump-sql`) replays through official
   SQLite into an identical database.
4. A larger database (many rows -> multi-page index with an interior page) also
   passes `integrity_check`, which validates the promoted separator keys.

Usage:
    python3 e2e_check.py <generated.db> <exported.sql> [generated_big.db]
"""

import sqlite3
import sys

DEMO_ROWS = [
    (1, "Alice", 89.5, b"\xde\xad\xbe\xef"),
    (2, "Bob", 89.0, b""),
    (3, "陈小明", 88.5, b""),
]


def check_demo(db_path: str, sql_path: str) -> None:
    con = sqlite3.connect(db_path)
    rows = con.execute(
        "SELECT id, name, score, memo FROM users ORDER BY id"
    ).fetchall()
    integrity = con.execute("PRAGMA integrity_check").fetchone()
    index_list = con.execute("PRAGMA index_list(users)").fetchall()
    con.close()
    assert rows == DEMO_ROWS, f"generated db rows mismatch:\n{rows}"
    assert integrity == ("ok",), f"generated db integrity: {integrity}"
    assert any(r[1] == "idx_users_name" for r in index_list), f"index missing: {index_list}"

    con2 = sqlite3.connect(":memory:")
    with open(sql_path, encoding="utf-8") as fh:
        con2.executescript(fh.read())
    con2.commit()
    rows2 = con2.execute(
        "SELECT id, name, score, memo FROM users ORDER BY id"
    ).fetchall()
    integrity2 = con2.execute("PRAGMA integrity_check").fetchone()
    con2.close()
    assert rows2 == DEMO_ROWS, f"replayed sql rows mismatch:\n{rows2}"
    assert integrity2 == ("ok",), f"replayed sql integrity: {integrity2}"


def check_big(db_path: str, n: int) -> None:
    con = sqlite3.connect(db_path)
    integrity = con.execute("PRAGMA integrity_check").fetchone()
    total = con.execute("SELECT count(*) FROM users").fetchone()
    via_index = con.execute("SELECT count(*) FROM users INDEXED BY idx_users_name").fetchone()
    plan = " ".join(str(r[3]) for r in con.execute(
        "EXPLAIN QUERY PLAN SELECT id FROM users WHERE name=?", ("user-200",)
    ))
    hit = con.execute("SELECT id FROM users WHERE name=?", ("user-200",)).fetchall()
    con.close()
    assert integrity == ("ok",), f"big db integrity: {integrity}"
    assert total == (n,), f"big db row count: {total} != {n}"
    assert via_index == (n,), f"index entry count: {via_index} != {n}"
    assert "idx_users_name" in plan, f"index not used by planner: {plan}"
    assert hit == [(200,)], f"indexed lookup mismatch: {hit}"


def main() -> int:
    if len(sys.argv) not in (3, 4):
        print(
            "usage: e2e_check.py <generated.db> <exported.sql> [generated_big.db]",
            file=sys.stderr,
        )
        return 2

    check_demo(sys.argv[1], sys.argv[2])
    if len(sys.argv) == 4:
        check_big(sys.argv[3], 400)

    print("end-to-end interop OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
