test "tokenize SELECT" {
  let tokens = @sql.tokenize("SELECT id, name FROM users")
  assert_eq(tokens.length(), 7) // SELECT, id, ,, name, FROM, users, EOF
}

test "parse CREATE TABLE" {
  let stmt = @sql.parse("CREATE TABLE users (id INT PRIMARY KEY, name TEXT NOT NULL)")
  assert_true(stmt is Some(_))
  match stmt.unwrap() {
    @types.Statement::Create(c) => {
      assert_eq(c.table, "users")
      assert_eq(c.columns.length(), 2)
      assert_eq(c.columns[0].name, "id")
      assert_eq(c.columns[0].primary_key, true)
      assert_eq(c.columns[1].name, "name")
      assert_eq(c.columns[1].nullable, false)
    }
    _ => panic()
  }
}

test "parse INSERT" {
  let stmt = @sql.parse("INSERT INTO users (id, name) VALUES (1, 'Alice'), (2, 'Bob')")
  assert_true(stmt is Some(_))
  match stmt.unwrap() {
    @types.Statement::Insert(i) => {
      assert_eq(i.table, "users")
      assert_eq(i.values.length(), 2)
      assert_eq(i.values[0].length(), 2)
    }
    _ => panic()
  }
}

test "parse SELECT with WHERE" {
  let stmt = @sql.parse("SELECT id, name FROM users WHERE id = 1")
  assert_true(stmt is Some(_))
  match stmt.unwrap() {
    @types.Statement::Select(s) => {
      assert_eq(s.table, "users")
      assert_eq(s.columns.length(), 2)
      assert_true(s.where_clause is Some(_))
    }
    _ => panic()
  }
}

test "parse SELECT star" {
  let stmt = @sql.parse("SELECT * FROM users")
  assert_true(stmt is Some(_))
  match stmt.unwrap() {
    @types.Statement::Select(s) => {
      assert_eq(s.columns[0], "*")
    }
    _ => panic()
  }
}
