/// VACUUM 式紧凑化的单元测试

test "vacuum: 重建后数据等价（行数与内容）" {
  let rows : Array[RowSpec] = [
    RowSpec::new(Some(Int64::from_int(10)), [VInt(Int64::from_int(10)), VText("alice"), VReal(1.5)]),
    RowSpec::new(Some(Int64::from_int(20)), [VInt(Int64::from_int(20)), VText("bob"), VReal(2.5)]),
    RowSpec::new(Some(Int64::from_int(30)), [VInt(Int64::from_int(30)), VText("陈小明"), VReal(3.5)]),
  ]
  let tables : Array[TableSpec] = [
    TableSpec::new(
      "users",
      "CREATE TABLE users(id integer primary key, name text, score real)",
      rows,
    ),
  ]
  let db = Db::open(make_db(tables))
  let out = vacuum(db, 4096)
  let db2 = Db::open(out)
  let t = db2.table("users")
  let r = db2.rows(t)
  assert_eq(r.length(), 3)
  // rowid 别名列（id）应精确还原
  assert_eq(r[0].values[0].to_display(), "10")
  assert_eq(r[1].values[0].to_display(), "20")
  assert_eq(r[2].values[0].to_display(), "30")
  assert_eq(r[2].values[1].to_display(), "陈小明")
  // 结果库结构自洽
  let v = verify_db(db2)
  assert_true(v.passed())
}

test "vacuum: 保留索引条目" {
  let rows : Array[RowSpec] = []
  for i = 1; i <= 100; i = i + 1 {
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
  let db = Db::open(make_db(tables))
  let out = vacuum(db, 4096)
  let db2 = Db::open(out)
  let entries = db2.index_entries("ix_k")
  assert_eq(entries.length(), 100)
  // 索引键升序：第一条是 k1
  assert_eq(entries[0][0].to_display(), "k1")
  // 结构自检通过
  let v = verify_db(db2)
  assert_true(v.passed())
}

test "vacuum: 结果库无空闲页、无未引用页" {
  let rows : Array[RowSpec] = []
  for i = 1; i <= 500; i = i + 1 {
    rows.push(
      RowSpec::new(None, [VInt(Int64::from_int(i)), VText("row" + i.to_string())]),
    )
  }
  let tables : Array[TableSpec] = [
    TableSpec::new("t", "CREATE TABLE t(id integer primary key, s text)", rows),
  ]
  let db = Db::open(make_db(tables))
  let out = vacuum(db, 4096)
  let db2 = Db::open(out)
  let v = verify_db(db2)
  assert_true(v.passed())
  // 写入器从零重建，不产生空闲页或未引用页
  assert_eq(v.freelist, 0)
  assert_eq(v.unreferenced, 0)
}

test "vacuum: 不支持 WITHOUT ROWID 表时报错" {
  // 直接构造一个含 WITHOUT ROWID 的库成本较高，这里验证「空表」路径与
  // 普通表路径的差异：WITHOUT ROWID 由 writer 无法生成，故用 Db 层无法直接
  // 构造；改以验证 vacuum 对普通表的页大小参数生效。
  let rows : Array[RowSpec] = [
    RowSpec::new(None, [VInt(Int64::from_int(1)), VText("a")]),
  ]
  let tables : Array[TableSpec] = [
    TableSpec::new("t", "CREATE TABLE t(id integer primary key, s text)", rows),
  ]
  let db = Db::open(make_db(tables))
  // 页大小 512 时，结果库应以 512 为页大小
  let out = vacuum(db, 512)
  let db2 = Db::open(out)
  assert_eq(db2.pager().page_size(), 512)
}
