# Byte-level format notes

Implementation notes for the writer (`writer.mbt` + `writer_tree.mbt`) and the
self-check (`verify.mbt`). Everything here follows the
[SQLite Database File Format](https://www.sqlite.org/fileformat2.html), version 3;
the section numbers refer to that document.

## 1. File layout

```
page 1            sqlite_master (a table B-tree; its b-tree header starts at byte 100)
page 2 … k         user table B-trees (leaves, then interior pages on top)
page k+1 … m       index B-trees
page m+1 … n       overflow pages (allocated last)
```

Pages are numbered strictly in allocation order by a single cursor (`PageArena`).
Because the writer builds trees bottom-up, a parent page always has a **higher**
page number than its children. SQLite does not constrain root page numbers to be
low — only page 1 is fixed — so this is legal and keeps the writer one-pass: a
child's page number is known before the parent that points at it is built.

There is no freelist; the file is fully packed.

## 2. Page header

| Offset | Size | Field | Value used |
|---|---|---|---|
| 0 | 1 | page type | 2 / 5 / 10 / 13 |
| 1–2 | 2 | first freeblock | 0 |
| 3–4 | 2 | cell count | actual |
| 5–6 | 2 | cell content start | grows down from `page_size` |
| 7 | 1 | fragmented free bytes | 0 |
| 8–11 | 4 | right-most child | interior pages only |

Page 1 has the same header, shifted by 100 bytes. Cells are laid out from the end
of the page downwards; the cell pointer array grows upwards from offset 8
(leaf) or 12 (interior). A page is considered full when the pointer array would
collide with the cell content.

## 3. Cells

| Page type | Cell layout |
|---|---|
| 13 (table leaf) | `varint(payload_len)`, `varint(rowid)`, payload (+ 4-byte overflow page number) |
| 5 (table interior) | 4-byte left child page, `varint(rowid)` |
| 10 (index leaf) | `varint(payload_len)`, payload (+ 4-byte overflow page number) |
| 2 (index interior) | 4-byte left child page, `varint(payload_len)`, payload (+ 4-byte overflow page number) |

Payloads longer than the page-local limit are split: the first `local_len` bytes
stay on the page, followed by a 4-byte pointer to an overflow page. Each overflow
page starts with a 4-byte pointer to the next page (0 = last), then up to
`usable - 4` payload bytes.

Local payload length (section 2.4):

```
table pages:  max_local = usable - 35
              min_local = (usable - 12) * 32 / 255 - 23
index pages:  max_local = (usable - 12) * 64 / 255 - 23
              min_local = (usable - 12) * 32 / 255 - 23

if payload <= max_local: local = payload
else:                    local = min_local + (payload - min_local) % (usable - 4)
                         (clamped to max_local, else min_local)
```

The index formula differs because index cells have no rowid field, so the
threshold is derived from `usable - 12` instead of `usable - 35`. Using the table
formula for index pages makes SQLite report corruption as soon as a key is long
enough to spill.

## 4. Separator keys — the one place the two tree kinds differ

**Table B-trees** (B+ semantics). The interior key is the maximum rowid of the
left subtree. It is a routing key only: the same rowid is still stored in the
leaf cell, and `PRAGMA integrity_check` does not count interior rowids as rows.
So the writer *copies* it.

**Index B-trees** (B-tree semantics). The interior key is a real index entry. It
must exist exactly once in the whole tree, so the writer *moves* it out of the
leaf. Copying it makes `PRAGMA integrity_check` report
`wrong # of entries in index` — which is exactly how the original bug surfaced.

Consequence for packing: when a run of children `c0 … ck` is packed into one
interior page, the page holds cells for `c0 … ck-1` and uses `ck` as its
right-most child. The key of `ck` is not written on this page; it is promoted to
the next level. At the top, the final promoted key is simply dropped — it is the
maximum key of the whole index and is still stored in the right-most leaf.

## 5. Multi-level packing

`pack_table_level` / `pack_index_level` each take the current level's nodes and
emit the next level:

```
cur = []
for node in level:
    if cur is non-empty and adding node would overflow the page:
        flush(cur)          # last node becomes the right-most child
        cur = []
    cur.push(node)
flush(cur)
repeat until one node remains -> that is the root
```

`flush` also handles the degenerate case of a single child by promoting it
without allocating a page (a page with zero cells and only a right pointer is
valid but pointless).

Termination is guaranteed: every level has strictly fewer nodes than the one
below it, because an interior page holds at least two children (the smallest
possible cell is 5 bytes and the largest page holds hundreds).

## 6. Record encoding

A record is `varint(header_len)` followed by one serial type per column, then the
body. The header length includes its own varint, so it is computed by
self-bootstrapping: start with 1 byte, and if the value no longer fits in the
7/14/21… bits promised by that length, increment and retry.

| Value | Serial type | Body bytes |
|---|---|---|
| `NULL` | 0 | 0 |
| integer | 1, 2, 3, 4, 5, 6 | 1, 2, 3, 4, 6, 8 |
| `0` / `1` | 8 / 9 | 0 |
| float64 | 7 | 8 (big-endian IEEE 754) |
| text (UTF-8) | 13 + 2n | n |
| blob | 12 + 2n | n |

Integer widths follow section 2.6: the *declared* serial type must match the
physical width, otherwise every following field in the record is misread. A
missing case for serial type 7 (float64) originally produced `-3` from the
odd/even fallback and shifted the body — the symptom was a BLOB read back as
`X'69636540'`, i.e. the bytes of the text `"ice@"` appearing one field late.

`INTEGER PRIMARY KEY` columns are stored as `NULL` in the table record and keyed
by the B-tree rowid; an index over such a column must store the real rowid value.

## 7. Page size

`make_db_with_page_size(tables, n)` accepts 512 … 65536. The value drives the
header field, the usable bytes per page, the overflow thresholds and the fan-out
of every level, so it is a good end-to-end probe of the format code: running the
same table at 512 and 65536 exercises very different code paths.

`65536` cannot be stored in the 2-byte header field, so the spec requires the
value `1`; `Pager::open` maps `1` back to 65536.

## 8. Self-check invariants

`verify_db` walks the file from the raw bytes and checks:

1. `file_length == page_size × page_count`.
2. Every page is claimed by at most one owner (a B-tree, an overflow chain, or
   the freelist). A page claimed twice is reported with both roles.
3. Page type matches the kind of tree being walked (table vs index). This is what
   distinguishes a `WITHOUT ROWID` table (stored as an index B-tree) from a rowid
   table.
4. `ncell` does not exceed what a page of this size could hold — a single
   corrupted header byte otherwise produces thousands of cascading errors.
5. Table B-trees yield strictly increasing rowids; index B-trees yield strictly
   increasing keys (using the same collation as the writer).
6. Overflow chains reach the declared payload length, never leave the file and
   never loop.
7. Pages that nobody references are reported as orphans.

The walk intentionally does not reuse `scan_table` / `scan_index`: those are the
code paths under test, so the checker implements its own traversal.

## 9. Known limits

- `WITHOUT ROWID` tables can be *read* and *checked*, but not yet generated.
- Only ascending, BINARY-collation indexes are generated; `DESC` and `COLLATE
  NOCASE` index keys would need direction/collation metadata in `IndexSpec`.
- No schema objects other than tables and indexes (no views, triggers, virtual
  tables).
- No journal/WAL output: the writer emits a fully materialised, committed file.
