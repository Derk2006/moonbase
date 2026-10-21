/// 写入器（生成合法 .db）的单元测试：重点验证可被本库读回、且格式正确

test "writer: 小表可生成并被读回" {
  let tables : Array[TableSpec] = [
    {
      name: "t",
      sql: "CREATE TABLE t(id integer primary key, name text, score real)",
      rows: [
        { rowid: None, values: [VInt(Int64::from_int(1)), VText("Alice"), VReal(91.5)] },
        { rowid: None, values: [VInt(Int64::from_int(2)), VText("Bob"), VReal(88.0)] },
        { rowid: None, values: [VInt(Int64::from_int(3)), VText("陈小明"), VReal(77.25)] },
      ],
    },
  ]
  let db = Db::open(make_db(tables))
  let t = db.table("t")
  let rows = db.rows(t)
  assert_eq(rows.length(), 3)
  assert_eq(rows[0].values[0].to_display(), "1")
  assert_eq(rows[0].values[1].to_display(), "Alice")
  assert_eq(rows[0].values[2].to_display(), "91.5")
  assert_eq(rows[2].values[1].to_display(), "陈小明")
  assert_eq(rows[2].values[2].to_display(), "77.25")
}

test "writer: 实数按 IEEE754 精确往返" {
  let tables : Array[TableSpec] = [
    {
      name: "r",
      sql: "CREATE TABLE r(id integer primary key, v real)",
      rows: [
        { rowid: None, values: [VInt(Int64::from_int(1)), VReal(91.5)] },
        { rowid: None, values: [VInt(Int64::from_int(2)), VReal(-0.125)] },
        { rowid: None, values: [VInt(Int64::from_int(3)), VReal(3.14159265358979)] },
        { rowid: None, values: [VInt(Int64::from_int(4)), VReal(0.0)] },
      ],
    },
  ]
  let db = Db::open(make_db(tables))
  let t = db.table("r")
  let rows = db.rows(t)
  assert_eq(rows[0].values[1].to_display(), "91.5")
  assert_eq(rows[1].values[1].to_display(), "-0.125")
  assert_eq(rows[2].values[1].to_display(), "3.14159265358979")
  assert_eq(rows[3].values[1].to_display(), "0.0")
}

test "writer: 超长文本触发溢出页链并被正确读回" {
  // 5000 字符 > max_local(4061)，必定走溢出页
  let mut big = ""
  for _i = 0; _i < 5000; _i = _i + 1 {
    big = big + "中"
  }
  let tables : Array[TableSpec] = [
    {
      name: "b",
      sql: "CREATE TABLE b(id integer primary key, s text)",
      rows: [
        { rowid: None, values: [VInt(Int64::from_int(1)), VText("short")] },
        { rowid: None, values: [VInt(Int64::from_int(2)), VText(big)] },
      ],
    },
  ]
  let db = Db::open(make_db(tables))
  let t = db.table("b")
  let rows = db.rows(t)
  assert_eq(rows.length(), 2)
  assert_eq(rows[1].values[1].to_display(), big)
}

test "writer: 大量行生成内部表页（多叶子）并被读回" {
  let rows : Array[RowSpec] = []
  for i = 1; i <= 300; i = i + 1 {
    rows.push({ rowid: None, values: [VInt(Int64::from_int(i)), VText("row" + i.to_string())] })
  }
  let tables : Array[TableSpec] = [
    { name: "big", sql: "CREATE TABLE big(id integer primary key, name text)", rows },
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
  let tables : Array[TableSpec] = [
    {
      name: "a",
      sql: "CREATE TABLE a(id integer primary key, x text)",
      rows: [ { rowid: None, values: [VInt(Int64::from_int(7)), VText("hello")] } ],
    },
    {
      name: "b",
      sql: "CREATE TABLE b(id integer primary key, y real)",
      rows: [ { rowid: None, values: [VInt(Int64::from_int(9)), VReal(2.5)] } ],
    },
  ]
  let db = Db::open(make_db(tables))
  let ta = db.table("a")
  let ra = db.rows(ta)
  assert_eq(ra[0].values[1].to_display(), "hello")
  let tb = db.table("b")
  let rb = db.rows(tb)
  assert_eq(rb[0].values[1].to_display(), "2.5")
}
