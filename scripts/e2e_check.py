#!/usr/bin/env python3
"""End-to-end interop check for MoonBase.

This script proves two things about a MoonBase-generated database:

1. The generated `.db` opens in the *official* SQLite (via Python's `sqlite3`)
   and its rows match what MoonBase claims, with `PRAGMA integrity_check = ok`.
2. The SQL script exported by MoonBase (`dump-sql`) replays through official
   SQLite into an identical database.

Usage:
    python3 e2e_check.py <moonbase_out.db> <moonbase_out.sql>
"""

import sqlite3
import sys


def expected_rows():
    # The demo database built by `moonbase-cli make` (see writer.mbt make_demo_db).
    return [
        (1, "Alice", 91.5, b"\xde\xad\xbe\xef"),
        (2, "Bob", 88.0, b""),
        (3, "陈小明", 77.25, b"\x01\x02"),
    ]


def main() -> int:
    if len(sys.argv) != 3:
        print("usage: e2e_check.py <generated.db> <exported.sql>", file=sys.stderr)
        return 2

    db_path = sys.argv[1]
    sql_path = sys.argv[2]
    expected = expected_rows()

    # 1) official SQLite opens the generated file
    con = sqlite3.connect(db_path)
    rows = con.execute(
        "SELECT id, name, score, memo FROM users ORDER BY id"
    ).fetchall()
    integrity = con.execute("PRAGMA integrity_check").fetchone()
    con.close()
    assert rows == expected, f"generated db rows mismatch:\n{rows}"
    assert integrity == ("ok",), f"generated db integrity: {integrity}"

    # 2) official SQLite replays the exported SQL into an identical database
    con2 = sqlite3.connect(":memory:")
    with open(sql_path, encoding="utf-8") as fh:
        con2.executescript(fh.read())
    con2.commit()
    rows2 = con2.execute(
        "SELECT id, name, score, memo FROM users ORDER BY id"
    ).fetchall()
    integrity2 = con2.execute("PRAGMA integrity_check").fetchone()
    con2.close()
    assert rows2 == expected, f"replayed sql rows mismatch:\n{rows2}"
    assert integrity2 == ("ok",), f"replayed sql integrity: {integrity2}"

    print("end-to-end interop OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
