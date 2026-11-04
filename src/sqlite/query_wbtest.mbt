/// 查询层扩展（LIKE / IN / BETWEEN / 聚合 / OFFSET / 多列排序）的单元测试

/// 构造一张包含可排序数据的表，供查询测试复用
fn query_test_db() -> Db raise DbError {
  let rows : Array[RowSpec] = [
    RowSpec::new(None, [VInt(Int64::from_int(1)), VText("Alice"), VReal(91.5)]),
    RowSpec::new(None, [VInt(Int64::from_int(2)), VText("Bob"), VReal(88.0)]),
    RowSpec::new(None, [VInt(Int64::from_int(3)), VText("alice"), VReal(77.25)]),
    RowSpec::new(None, [VInt(Int64::from_int(4)), VText("Charlie"), VReal(88.0)]),
    RowSpec::new(None, [VInt(Int64::from_int(5)), VText("陈小明"), VReal(95.0)]),
  ]
  let tables : Array[TableSpec] = [
    TableSpec::new(
      "users",
      "CREATE TABLE users(id integer primary key, name text, score real)",
      rows,
    ),
  ]
  Db::open(make_db(tables))
}

test "query: LIKE 通配匹配" {
  let db = query_test_db()
  let rs = query(db, "SELECT name FROM users WHERE name LIKE 'A%' ORDER BY id")
  assert_eq(rs.rows().length(), 2)
  assert_eq(rs.rows()[0][0].to_display(), "Alice")
  assert_eq(rs.rows()[1][0].to_display(), "alice")
}

test "query: LIKE 单字符通配与 NOT LIKE" {
  let db = query_test_db()
  let rs = query(db, "SELECT name FROM users WHERE name LIKE 'B_b'")
  assert_eq(rs.rows().length(), 1)
  assert_eq(rs.rows()[0][0].to_display(), "Bob")
  let rs2 = query(db, "SELECT name FROM users WHERE name NOT LIKE 'A%' ORDER BY id")
  assert_eq(rs2.rows().length(), 3)
}

test "query: IN 列表过滤" {
  let db = query_test_db()
  let rs = query(db, "SELECT id FROM users WHERE id IN (2, 4, 9) ORDER BY id")
  assert_eq(rs.rows().length(), 2)
  assert_eq(rs.rows()[0][0].to_display(), "2")
  assert_eq(rs.rows()[1][0].to_display(), "4")
}

test "query: NOT IN 过滤" {
  let db = query_test_db()
  let rs = query(db, "SELECT id FROM users WHERE id NOT IN (2, 4) ORDER BY id")
  assert_eq(rs.rows().length(), 3)
  assert_eq(rs.rows()[0][0].to_display(), "1")
}

test "query: BETWEEN 闭区间过滤" {
  let db = query_test_db()
  let rs = query(db, "SELECT id FROM users WHERE id BETWEEN 2 AND 4 ORDER BY id")
  assert_eq(rs.rows().length(), 3)
  assert_eq(rs.rows()[0][0].to_display(), "2")
  assert_eq(rs.rows()[2][0].to_display(), "4")
}

test "query: SUM 聚合" {
  let db = query_test_db()
  let rs = query(db, "SELECT SUM(score) FROM users")
  assert_eq(rs.rows()[0][0].to_display(), "439.75")
}

test "query: AVG 聚合" {
  let db = query_test_db()
  let rs = query(db, "SELECT AVG(score) FROM users")
  assert_eq(rs.rows()[0][0].to_display(), "87.95")
}

test "query: MIN / MAX 聚合" {
  let db = query_test_db()
  let rs = query(db, "SELECT MIN(score) FROM users")
  assert_eq(rs.rows()[0][0].to_display(), "77.25")
  let rs2 = query(db, "SELECT MAX(score) FROM users")
  assert_eq(rs2.rows()[0][0].to_display(), "95.0")
}

test "query: LIMIT OFFSET 分页" {
  let db = query_test_db()
  let rs = query(db, "SELECT id FROM users ORDER BY id LIMIT 2 OFFSET 1")
  assert_eq(rs.rows().length(), 2)
  assert_eq(rs.rows()[0][0].to_display(), "2")
  assert_eq(rs.rows()[1][0].to_display(), "3")
}

test "query: 多列 ORDER BY" {
  let db = query_test_db()
  // 按 score 降序、同分按 name 升序（BINARY 序，大写在小写前）
  let rs = query(db, "SELECT name FROM users ORDER BY score DESC, name ASC")
  assert_eq(rs.rows()[0][0].to_display(), "陈小明") // 95.0
  assert_eq(rs.rows()[1][0].to_display(), "Alice") // 91.5
  // 88.0 有两个：Bob / Charlie，按 name 升序 Bob < Charlie
  assert_eq(rs.rows()[2][0].to_display(), "Bob")
  assert_eq(rs.rows()[3][0].to_display(), "Charlie")
  assert_eq(rs.rows()[4][0].to_display(), "alice") // 77.25
}

test "query: 聚合与 WHERE 组合" {
  let db = query_test_db()
  let rs = query(db, "SELECT COUNT(*) FROM users WHERE score >= 88")
  assert_eq(rs.rows()[0][0].to_display(), "4")
}
