/// 结构自检（verify_db）的单元测试

test "verify: 演示库自检通过" {
  let db = Db::open(make_demo_db())
  let r = verify_db(db)
  assert_true(r.passed())
  assert_eq(r.pages_total, 3)
  assert_eq(r.unreferenced, 0)
  assert_eq(r.overflow, 0)
  assert_eq(r.tables.length(), 1)
  assert_eq(r.tables[0].0, "users")
  assert_eq(r.tables[0].1, 1)
  assert_eq(r.tables[0].2, 3)
  assert_eq(r.indexes.length(), 1)
  assert_eq(r.indexes[0].0, "idx_users_name")
  assert_eq(r.indexes[0].2, 3)
}

test "verify: 含溢出页的库自检通过且溢出页被计入" {
  let mut big = ""
  for _i = 0; _i < 3000; _i = _i + 1 {
    big = big + "文"
  }
  let rows : Array[RowSpec] = [
    RowSpec::new(None, [VInt(Int64::from_int(1)), VText(big)]),
  ]
  let tables : Array[TableSpec] = [
    TableSpec::new("b", "CREATE TABLE b(id integer primary key, s text)", rows),
  ]
  let db = Db::open(make_db(tables))
  let r = verify_db(db)
  assert_true(r.passed())
  assert_true(r.overflow > 0)
  assert_eq(r.unreferenced, 0)
}

test "verify: 多级 B 树自检通过并报出层数" {
  let rows : Array[RowSpec] = []
  for i = 1; i <= 20000; i = i + 1 {
    rows.push(
      RowSpec::new(None, [VInt(Int64::from_int(i)), VText("k" + i.to_string())]),
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
  let db = Db::open(make_db_with_page_size(tables, 512))
  let r = verify_db(db)
  assert_true(r.passed())
  assert_true(r.tables[0].1 >= 3)
  assert_true(r.indexes[0].1 >= 3)
  assert_eq(r.table_rows, 20000)
  assert_eq(r.index_entries, 20000)
}

test "verify: 页类型被破坏时能报出问题" {
  let bytes = make_demo_db()
  let arr = bytes.to_array()
  // 第 2 页是 users 的根页，把页类型改成 0（非法）
  let page_size = 4096
  arr[page_size] = b'\x00'
  let db = Db::open(Bytes::from_array(arr))
  let r = verify_db(db)
  assert_false(r.passed())
}

test "verify: 重复引用同一子页时能报出问题" {
  let rows : Array[RowSpec] = []
  for i = 1; i <= 400; i = i + 1 {
    rows.push(
      RowSpec::new(None, [VInt(Int64::from_int(i)), VText("row" + i.to_string())]),
    )
  }
  let tables : Array[TableSpec] = [
    TableSpec::new("t", "CREATE TABLE t(id integer primary key, s text)", rows),
  ]
  let bytes = make_db(tables)
  let arr = bytes.to_array()
  let page_size = 4096
  // users 的根页是页 2，内部页首个单元的 4 字节是左子页指针；
  // 把它指向根页自己，制造「页被重复引用」
  let root = page_size
  let ncell = (arr[root + 3].to_int() << 8) | arr[root + 4].to_int()
  if ncell > 0 {
    let ptr = (arr[root + 12].to_int() << 8) | arr[root + 13].to_int()
    let self_no = 2
    arr[root + ptr] = (self_no >> 24).to_byte()
    arr[root + ptr + 1] = ((self_no >> 16) & 0xFF).to_byte()
    arr[root + ptr + 2] = ((self_no >> 8) & 0xFF).to_byte()
    arr[root + ptr + 3] = (self_no & 0xFF).to_byte()
  }
  let db = Db::open(Bytes::from_array(arr))
  let r = verify_db(db)
  assert_false(r.passed())
}
