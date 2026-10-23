/// 导出模块的单元测试

test "export: 文本字面量按 SQL 标准转义单引号" {
  assert_eq(sql_literal(VText("O'Brien")), "'O''Brien'")
  assert_eq(sql_literal(VText("")), "''")
  assert_eq(sql_literal(VText("正常文本")), "'正常文本'")
}

test "export: 各类值生成合法 SQL 字面量" {
  assert_eq(sql_literal(VNull), "NULL")
  assert_eq(sql_literal(VInt(Int64::from_int(-42))), "-42")
  assert_eq(sql_literal(VReal(1.5)), "1.5")
  assert_eq(sql_literal(VReal(2.0)), "2.0")
  assert_eq(
    sql_literal(VBlob(Bytes::from_array([b'\x00', b'\xAB']))),
    "X'00AB'",
  )
  assert_eq(sql_literal(VBlob(Bytes::new(0))), "X''")
}

test "export: 整库导出包含建表、数据与事务边界" {
  let db = Db::open(make_demo_db())
  let sql = export_sql(db)
  assert_true(sql.contains("BEGIN TRANSACTION;"))
  assert_true(sql.contains("CREATE TABLE users"))
  assert_true(sql.contains("INSERT INTO \"users\""))
  assert_true(sql.contains("COMMIT;"))
  // 中文文本应原样出现在字面量中
  assert_true(sql.contains("'陈小明'"))
  // BLOB 应以 X'..' 形式出现
  assert_true(sql.contains("X'DEADBEEF'"))
}

/// 回归：serial type 7（float64）未被计入字段宽度，会让其后的字段整体错位。
/// demo 表的 score(real) 后面紧跟 memo(blob)，正好覆盖这个位置。
test "export: 浮点列之后的字段不偏移（回归）" {
  let db = Db::open(make_demo_db())
  let t = db.table("users")
  let rows = db.rows(t)
  assert_eq(rows[0].values[2].to_display(), "91.5")
  assert_eq(rows[0].values[3].to_display(), "X'DEADBEEF'")
}

test "export: 每行数据都产出一条 INSERT" {
  let db = Db::open(make_demo_db())
  let sql = export_sql(db)
  let t = db.table("users")
  let rows = db.rows(t)
  let mut count = 0
  for line in sql.split("\n") {
    if line.contains("INSERT INTO") {
      count = count + 1
    }
  }
  assert_eq(count, rows.length())
}
