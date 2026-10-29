/// 写入器（生成合法 .db）的单元测试：重点验证可被本库读回、且格式正确

test "writer: 小表可生成并被读回" {
  let rows : Array[RowSpec] = [
    RowSpec::new(None, [VInt(Int64::from_int(1)), VText("Alice"), VReal(91.5)]),
    RowSpec::new(None, [VInt(Int64::from_int(2)), VText("Bob"), VReal(88.0)]),
    RowSpec::new(None, [VInt(Int64::from_int(3)), VText("陈小明"), VReal(77.25)]),
  ]
  let tables : Array[TableSpec] = [
    TableSpec::new(
      "t",
      "CREATE TABLE t(id integer primary key, name text, score real)",
      rows,
    ),
  ]
  let db = Db::open(make_db(tables))
  let t = db.table("t")
  let got = db.rows(t)
  assert_eq(got.length(), 3)
  assert_eq(got[0].values[0].to_display(), "1")
  assert_eq(got[0].values[1].to_display(), "Alice")
  assert_eq(got[0].values[2].to_display(), "91.5")
  assert_eq(got[2].values[1].to_display(), "陈小明")
  assert_eq(got[2].values[2].to_display(), "77.25")
}

test "writer: 实数按 IEEE754 精确往返" {
  let rows : Array[RowSpec] = [
    RowSpec::new(None, [VInt(Int64::from_int(1)), VReal(91.5)]),
    RowSpec::new(None, [VInt(Int64::from_int(2)), VReal(-0.125)]),
    RowSpec::new(None, [VInt(Int64::from_int(3)), VReal(3.14159265358979)]),
    RowSpec::new(None, [VInt(Int64::from_int(4)), VReal(0.0)]),
  ]
  let tables : Array[TableSpec] = [
    TableSpec::new("r", "CREATE TABLE r(id integer primary key, v real)", rows),
  ]
  let db = Db::open(make_db(tables))
  let t = db.table("r")
  let got = db.rows(t)
  assert_eq(got[0].values[1].to_display(), "91.5")
  assert_eq(got[1].values[1].to_display(), "-0.125")
  assert_eq(got[2].values[1].to_display(), "3.14159265358979")
  assert_eq(got[3].values[1].to_display(), "0.0")
}

test "writer: 超长文本触发溢出页链并被正确读回" {
  // 5000 字符 > max_local(4061)，必定走溢出页
  let mut big = ""
  for _i = 0; _i < 5000; _i = _i + 1 {
    big = big + "中"
  }
  let rows : Array[RowSpec] = [
    RowSpec::new(None, [VInt(Int64::from_int(1)), VText("short")]),
    RowSpec::new(None, [VInt(Int64::from_int(2)), VText(big)]),
  ]
  let tables : Array[TableSpec] = [
    TableSpec::new("b", "CREATE TABLE b(id integer primary key, s text)", rows),
  ]
  let db = Db::open(make_db(tables))
  let t = db.table("b")
  let got = db.rows(t)
  assert_eq(got.length(), 2)
  assert_eq(got[1].values[1].to_display(), big)
}

test "writer: 大量行生成内部表页（多叶子）并被读回" {
  let rows : Array[RowSpec] = []
  for i = 1; i <= 300; i = i + 1 {
    rows.push(
      RowSpec::new(None, [VInt(Int64::from_int(i)), VText("row" + i.to_string())]),
    )
  }
  let tables : Array[TableSpec] = [
    TableSpec::new("big", "CREATE TABLE big(id integer primary key, name text)", rows),
  ]
  let db = Db::open(make_db(tables))
  let t = db.table("big")
  let got = db.rows(t)
  assert_eq(got.length(), 300)
  // 校验首末行
  assert_eq(got[0].values[0].to_display(), "1")
  assert_eq(got[0].values[1].to_display(), "row1")
  assert_eq(got[299].values[0].to_display(), "300")
  assert_eq(got[299].values[1].to_display(), "row300")
}

test "writer: 多表同时生成" {
  let ra : Array[RowSpec] = [
    RowSpec::new(None, [VInt(Int64::from_int(7)), VText("hello")]),
  ]
  let rb : Array[RowSpec] = [
    RowSpec::new(None, [VInt(Int64::from_int(9)), VReal(2.5)]),
  ]
  let tables : Array[TableSpec] = [
    TableSpec::new("a", "CREATE TABLE a(id integer primary key, x text)", ra),
    TableSpec::new("b", "CREATE TABLE b(id integer primary key, y real)", rb),
  ]
  let db = Db::open(make_db(tables))
  let ta = db.table("a")
  let ga = db.rows(ta)
  assert_eq(ga[0].values[1].to_display(), "hello")
  let tb = db.table("b")
  let gb = db.rows(tb)
  assert_eq(gb[0].values[1].to_display(), "2.5")
}

// ---- 索引 B 树 ----

/// 取出索引条目的键值（每条记录的最后一列是 rowid）
fn index_keys(pager : Pager, root : Int) -> Array[Array[Value]] raise DbError {
  let out : Array[Array[Value]] = []
  for e in scan_index(pager, root) {
    out.push(decode_record(e.payload, 1))
  }
  out
}

test "writer: 索引写入 sqlite_master 且条目可扫描" {
  let bytes = make_demo_db()
  let pager = Pager::open(bytes)
  let schema = build_schema(pager)
  assert_eq(schema.indexes().length(), 1)
  let idx = schema.indexes()[0]
  assert_eq(idx.name, "idx_users_name")
  assert_eq(idx.table, "users")
  let keys = index_keys(pager, idx.rootpage)
  assert_eq(keys.length(), 3)
  // (name, rowid)，按 name 的码点序：Alice, Bob, 陈小明
  assert_eq(keys[0][0].to_display(), "Alice")
  assert_eq(keys[0][1].to_display(), "1")
  assert_eq(keys[2][0].to_display(), "陈小明")
  assert_eq(keys[2][1].to_display(), "3")
}

test "writer: 索引键遵循 NULL<数值<文本<BLOB 排序" {
  let rows : Array[RowSpec] = [
    RowSpec::new(None, [VInt(Int64::from_int(1)), VBlob(Bytes::from_array([b'\x01']))]),
    RowSpec::new(None, [VInt(Int64::from_int(2)), VText("b")]),
    RowSpec::new(None, [VInt(Int64::from_int(3)), VNull]),
    RowSpec::new(None, [VInt(Int64::from_int(4)), VInt(Int64::from_int(-5))]),
    RowSpec::new(None, [VInt(Int64::from_int(5)), VReal(2.5)]),
    RowSpec::new(None, [VInt(Int64::from_int(6)), VText("a")]),
  ]
  let idxs : Array[IndexSpec] = [
    IndexSpec::new("ix_v", "m", "CREATE INDEX ix_v ON m(v)", ["v"]),
  ]
  let tables : Array[TableSpec] = [
    TableSpec::with_indexes(
      "m",
      "CREATE TABLE m(id integer primary key, v)",
      rows,
      idxs,
    ),
  ]
  let pager = Pager::open(make_db(tables))
  let idx = build_schema(pager).indexes()[0]
  let keys = index_keys(pager, idx.rootpage)
  assert_eq(keys.length(), 6)
  assert_eq(keys[0][0].to_display(), "NULL")
  assert_eq(keys[1][0].to_display(), "-5")
  assert_eq(keys[2][0].to_display(), "2.5")
  assert_eq(keys[3][0].to_display(), "a")
  assert_eq(keys[4][0].to_display(), "b")
  assert_eq(keys[5][0].type_name(), "blob")
}

test "writer: 索引列是 INTEGER PRIMARY KEY 时写入真实 rowid" {
  // 表记录里主键列存 NULL（rowid 别名），索引里必须是真实值，否则 sqlite3 会判为损坏
  let rows : Array[RowSpec] = [
    RowSpec::new(None, [VInt(Int64::from_int(11)), VText("x")]),
    RowSpec::new(None, [VInt(Int64::from_int(22)), VText("y")]),
  ]
  let idxs : Array[IndexSpec] = [
    IndexSpec::new("ix_id", "p", "CREATE INDEX ix_id ON p(id)", ["id"]),
  ]
  let tables : Array[TableSpec] = [
    TableSpec::with_indexes(
      "p",
      "CREATE TABLE p(id integer primary key, v text)",
      rows,
      idxs,
    ),
  ]
  let pager = Pager::open(make_db(tables))
  let idx = build_schema(pager).indexes()[0]
  let keys = index_keys(pager, idx.rootpage)
  assert_eq(keys.length(), 2)
  assert_eq(keys[0][0].to_display(), "11")
  assert_eq(keys[1][0].to_display(), "22")
}

test "writer: 大量行生成内部索引页（多叶子）且键有序" {
  let rows : Array[RowSpec] = []
  // 故意用被 100 取模的键，制造大量重复键，验证 rowid 兜底排序
  for i = 1; i <= 400; i = i + 1 {
    rows.push(
      RowSpec::new(None, [VInt(Int64::from_int(i)), VText("k" + (i % 37).to_string())]),
    )
  }
  let idxs : Array[IndexSpec] = [
    IndexSpec::new("ix_k", "big", "CREATE INDEX ix_k ON big(k)", ["k"]),
  ]
  let tables : Array[TableSpec] = [
    TableSpec::with_indexes(
      "big",
      "CREATE TABLE big(id integer primary key, k text)",
      rows,
      idxs,
    ),
  ]
  let pager = Pager::open(make_db(tables))
  let idx = build_schema(pager).indexes()[0]
  let keys = index_keys(pager, idx.rootpage)
  assert_eq(keys.length(), 400)
  // 全表有序 + 重复键按 rowid 升序
  let mut prev = keys[0]
  for i = 1; i < keys.length(); i = i + 1 {
    let c = cmp_key_vec(prev, keys[i])
    assert_true(c < 0)
    prev = keys[i]
  }
  // 确实生成了内部索引页（页类型 2）
  let mut interior_index_pages = 0
  for no = 2; no <= pager.page_count(); no = no + 1 {
    let page = BtreePage::parse(pager, no)
    if page.page_type == PAGE_INTERIOR_INDEX {
      interior_index_pages = interior_index_pages + 1
    }
  }
  assert_true(interior_index_pages > 0)
}
