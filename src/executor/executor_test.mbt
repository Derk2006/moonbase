test "Executor CREATE TABLE" {
  let storage = @storage.Storage::new()
  let exec = @executor.Executor::new(storage)
  let stmt = @types.Statement::Create(@types.CreateStmt::{
    table: "users",
    columns: [
      @types.Column::{ name: "id", ty: @types.DataType::Int, nullable: false, primary_key: true },
      @types.Column::{ name: "name", ty: @types.DataType::Text, nullable: false, primary_key: false }
    ]
  })
  let result = exec.execute(stmt)
  match result {
    @executor.Result::Ok(msg) => assert_true(msg.contains("created"))
    _ => panic()
  }
}

test "Executor INSERT and SELECT" {
  let storage = @storage.Storage::new()
  let exec = @executor.Executor::new(storage)
  // CREATE
  ignore(exec.execute(@types.Statement::Create(@types.CreateStmt::{
    table: "users",
    columns: [
      @types.Column::{ name: "id", ty: @types.DataType::Int, nullable: false, primary_key: true },
      @types.Column::{ name: "name", ty: @types.DataType::Text, nullable: false, primary_key: false }
    ]
  })))
  // INSERT
  ignore(exec.execute(@types.Statement::Insert(@types.InsertStmt::{
    table: "users",
    columns: ["id", "name"],
    values: [[@types.Value::IntVal(1), @types.Value::TextVal("Alice")]]
  })))
  // SELECT *
  let result = exec.execute(@types.Statement::Select(@types.SelectStmt::{
    columns: ["*"],
    table: "users",
    where_clause: None,
    order_by: None,
    limit: None
  }))
  match result {
    @executor.Result::Rows(rows, cols) => {
      assert_eq(rows.length(), 1)
      assert_eq(cols.length(), 2)
    }
    _ => panic()
  }
}

test "Executor SELECT with WHERE" {
  let storage = @storage.Storage::new()
  let exec = @executor.Executor::new(storage)
  ignore(exec.execute(@types.Statement::Create(@types.CreateStmt::{
    table: "scores",
    columns: [
      @types.Column::{ name: "id", ty: @types.DataType::Int, nullable: false, primary_key: true },
      @types.Column::{ name: "score", ty: @types.DataType::Int, nullable: false, primary_key: false }
    ]
  })))
  for i = 1; i <= 5; i = i + 1 {
    ignore(exec.execute(@types.Statement::Insert(@types.InsertStmt::{
      table: "scores",
      columns: ["id", "score"],
      values: [[@types.Value::IntVal(i), @types.Value::IntVal(i * 10)]]
    })))
  }
  let where_expr = @types.Expr::Binary(
    @types.Op::Gt,
    @types.Expr::ColumnRef("id"),
    @types.Expr::Literal(@types.Value::IntVal(2))
  )
  let result = exec.execute(@types.Statement::Select(@types.SelectStmt::{
    columns: ["*"],
    table: "scores",
    where_clause: Some(where_expr),
    order_by: None,
    limit: None
  }))
  match result {
    @executor.Result::Rows(rows, _) => {
      assert_eq(rows.length(), 3) // id 3,4,5
    }
    _ => panic()
  }
}

/// 建一张三列的表并插入三行，供后续用例复用
fn seed_scores(exec : @executor.Executor) -> Unit {
  ignore(exec.execute(@types.Statement::Create(@types.CreateStmt::{
    table: "scores",
    columns: [
      @types.Column::{ name: "id", ty: @types.DataType::Int, nullable: false, primary_key: true },
      @types.Column::{ name: "name", ty: @types.DataType::Text, nullable: false, primary_key: false },
      @types.Column::{ name: "score", ty: @types.DataType::Int, nullable: false, primary_key: false }
    ]
  })))
  ignore(exec.execute(@types.Statement::Insert(@types.InsertStmt::{
    table: "scores",
    columns: ["id", "name", "score"],
    values: [
      [@types.Value::IntVal(1), @types.Value::TextVal("Alice"), @types.Value::IntVal(70)],
      [@types.Value::IntVal(2), @types.Value::TextVal("Bob"), @types.Value::IntVal(88)],
      [@types.Value::IntVal(3), @types.Value::TextVal("Carol"), @types.Value::IntVal(95)]
    ]
  })))
}

fn select_all(exec : @executor.Executor) -> @executor.Result {
  exec.execute(@types.Statement::Select(@types.SelectStmt::{
    columns: ["*"],
    table: "scores",
    where_clause: None,
    order_by: None,
    limit: None
  }))
}

test "Executor 按列名解析非首列条件" {
  let storage = @storage.Storage::new()
  let exec = @executor.Executor::new(storage)
  seed_scores(exec)
  // 条件落在第 3 列 score 上，回归验证列名解析（不再固定取第 0 列）
  let where_expr = @types.Expr::Binary(
    @types.Op::Ge,
    @types.Expr::ColumnRef("score"),
    @types.Expr::Literal(@types.Value::IntVal(88))
  )
  let result = exec.execute(@types.Statement::Select(@types.SelectStmt::{
    columns: ["*"],
    table: "scores",
    where_clause: Some(where_expr),
    order_by: None,
    limit: None
  }))
  match result {
    @executor.Result::Rows(rows, _) => assert_eq(rows.length(), 2) // Bob, Carol
    _ => panic()
  }
}

test "Executor 列投影只返回所选列" {
  let storage = @storage.Storage::new()
  let exec = @executor.Executor::new(storage)
  seed_scores(exec)
  let result = exec.execute(@types.Statement::Select(@types.SelectStmt::{
    columns: ["name"],
    table: "scores",
    where_clause: None,
    order_by: None,
    limit: None
  }))
  match result {
    @executor.Result::Rows(rows, cols) => {
      assert_eq(cols.length(), 1)
      assert_eq(cols[0], "name")
      assert_eq(rows[0].values.length(), 1)
      assert_true(rows[0].values[0] == @types.Value::TextVal("Alice"))
    }
    _ => panic()
  }
}

test "Executor 查询不存在的列返回错误" {
  let storage = @storage.Storage::new()
  let exec = @executor.Executor::new(storage)
  seed_scores(exec)
  let result = exec.execute(@types.Statement::Select(@types.SelectStmt::{
    columns: ["nope"],
    table: "scores",
    where_clause: None,
    order_by: None,
    limit: None
  }))
  match result {
    @executor.Result::Err(msg) => assert_true(msg.contains("Unknown column"))
    _ => panic()
  }
}

test "Executor ORDER BY 降序" {
  let storage = @storage.Storage::new()
  let exec = @executor.Executor::new(storage)
  seed_scores(exec)
  let result = exec.execute(@types.Statement::Select(@types.SelectStmt::{
    columns: ["id"],
    table: "scores",
    where_clause: None,
    order_by: Some(@types.OrderBy::{ column: "score", desc: true }),
    limit: None
  }))
  match result {
    @executor.Result::Rows(rows, _) => {
      assert_true(rows[0].values[0] == @types.Value::IntVal(3)) // Carol 95
      assert_true(rows[2].values[0] == @types.Value::IntVal(1)) // Alice 70
    }
    _ => panic()
  }
}

test "Executor ORDER BY 升序" {
  let storage = @storage.Storage::new()
  let exec = @executor.Executor::new(storage)
  seed_scores(exec)
  let result = exec.execute(@types.Statement::Select(@types.SelectStmt::{
    columns: ["name"],
    table: "scores",
    where_clause: None,
    order_by: Some(@types.OrderBy::{ column: "name", desc: false }),
    limit: None
  }))
  match result {
    @executor.Result::Rows(rows, _) => {
      assert_true(rows[0].values[0] == @types.Value::TextVal("Alice"))
      assert_true(rows[1].values[0] == @types.Value::TextVal("Bob"))
      assert_true(rows[2].values[0] == @types.Value::TextVal("Carol"))
    }
    _ => panic()
  }
}

test "Executor 文本排序按字典序，不受长度影响" {
  let storage = @storage.Storage::new()
  let exec = @executor.Executor::new(storage)
  ignore(exec.execute(@types.Statement::Create(@types.CreateStmt::{
    table: "t",
    columns: [
      @types.Column::{ name: "id", ty: @types.DataType::Int, nullable: false, primary_key: true },
      @types.Column::{ name: "name", ty: @types.DataType::Text, nullable: false, primary_key: false }
    ]
  })))
  // 标准库的 String 比较先比长度，这里用长短不一的名字验证字典序仍然正确
  ignore(exec.execute(@types.Statement::Insert(@types.InsertStmt::{
    table: "t",
    columns: ["id", "name"],
    values: [
      [@types.Value::IntVal(1), @types.Value::TextVal("Charlotte")],
      [@types.Value::IntVal(2), @types.Value::TextVal("Bob")]
    ]
  })))
  let result = exec.execute(@types.Statement::Select(@types.SelectStmt::{
    columns: ["name"],
    table: "t",
    where_clause: None,
    order_by: Some(@types.OrderBy::{ column: "name", desc: false }),
    limit: None
  }))
  match result {
    @executor.Result::Rows(rows, _) => {
      assert_true(rows[0].values[0] == @types.Value::TextVal("Bob"))
      assert_true(rows[1].values[0] == @types.Value::TextVal("Charlotte"))
    }
    _ => panic()
  }
  assert_true(@executor.text_compare("Alice", "Bob") < 0)
  assert_true(@executor.text_compare("Bob", "Alice") > 0)
  assert_true(@executor.text_compare("ab", "abc") < 0)
}

test "Executor 文本条件比较按字典序" {
  let storage = @storage.Storage::new()
  let exec = @executor.Executor::new(storage)
  ignore(exec.execute(@types.Statement::Create(@types.CreateStmt::{
    table: "t",
    columns: [
      @types.Column::{ name: "id", ty: @types.DataType::Int, nullable: false, primary_key: true },
      @types.Column::{ name: "name", ty: @types.DataType::Text, nullable: false, primary_key: false }
    ]
  })))
  ignore(exec.execute(@types.Statement::Insert(@types.InsertStmt::{
    table: "t",
    columns: ["id", "name"],
    values: [
      [@types.Value::IntVal(1), @types.Value::TextVal("Alpha")],
      [@types.Value::IntVal(2), @types.Value::TextVal("Beta")]
    ]
  })))
  let where_expr = @types.Expr::Binary(
    @types.Op::Gt,
    @types.Expr::ColumnRef("name"),
    @types.Expr::Literal(@types.Value::TextVal("Alpha"))
  )
  let result = exec.execute(@types.Statement::Select(@types.SelectStmt::{
    columns: ["id"],
    table: "t",
    where_clause: Some(where_expr),
    order_by: None,
    limit: None
  }))
  match result {
    @executor.Result::Rows(rows, _) => {
      assert_eq(rows.length(), 1)
      assert_true(rows[0].values[0] == @types.Value::IntVal(2))
    }
    _ => panic()
  }
}

test "Executor LIMIT 截断结果集" {
  let storage = @storage.Storage::new()
  let exec = @executor.Executor::new(storage)
  seed_scores(exec)
  let result = exec.execute(@types.Statement::Select(@types.SelectStmt::{
    columns: ["*"],
    table: "scores",
    where_clause: None,
    order_by: Some(@types.OrderBy::{ column: "score", desc: false }),
    limit: Some(2)
  }))
  match result {
    @executor.Result::Rows(rows, _) => {
      assert_eq(rows.length(), 2)
      assert_true(rows[0].values[0] == @types.Value::IntVal(1))
      assert_true(rows[1].values[0] == @types.Value::IntVal(2))
    }
    _ => panic()
  }
}

test "Executor DELETE 带条件删除并重建索引" {
  let storage = @storage.Storage::new()
  let exec = @executor.Executor::new(storage)
  seed_scores(exec)
  let where_expr = @types.Expr::Binary(
    @types.Op::Lt,
    @types.Expr::ColumnRef("score"),
    @types.Expr::Literal(@types.Value::IntVal(88))
  )
  match exec.execute(@types.Statement::Delete(@types.DeleteStmt::{
    table: "scores",
    where_clause: Some(where_expr)
  })) {
    @executor.Result::Ok(msg) => assert_true(msg.contains("1 row(s)"))
    _ => panic()
  }
  match select_all(exec) {
    @executor.Result::Rows(rows, _) => assert_eq(rows.length(), 2)
    _ => panic()
  }
  // 删除后主键索引应已重建
  assert_true(storage.select_by_key("scores", 1) is None)
  assert_true(storage.select_by_key("scores", 3) is Some(_))
}

test "Executor DELETE 不带条件清空整表" {
  let storage = @storage.Storage::new()
  let exec = @executor.Executor::new(storage)
  seed_scores(exec)
  ignore(exec.execute(@types.Statement::Delete(@types.DeleteStmt::{
    table: "scores",
    where_clause: None
  })))
  match select_all(exec) {
    @executor.Result::Rows(rows, _) => assert_eq(rows.length(), 0)
    _ => panic()
  }
  assert_true(storage.select_by_key("scores", 1) is None)
}

test "Executor SELECT 混合数值类型比较" {
  let storage = @storage.Storage::new()
  let exec = @executor.Executor::new(storage)
  ignore(exec.execute(@types.Statement::Create(@types.CreateStmt::{
    table: "m",
    columns: [
      @types.Column::{ name: "id", ty: @types.DataType::Int, nullable: false, primary_key: true },
      @types.Column::{ name: "ratio", ty: @types.DataType::Double, nullable: false, primary_key: false }
    ]
  })))
  ignore(exec.execute(@types.Statement::Insert(@types.InsertStmt::{
    table: "m",
    columns: ["id", "ratio"],
    values: [
      [@types.Value::IntVal(1), @types.Value::DoubleVal(1.5)],
      [@types.Value::IntVal(2), @types.Value::DoubleVal(3.25)]
    ]
  })))
  let where_expr = @types.Expr::Binary(
    @types.Op::Gt,
    @types.Expr::ColumnRef("ratio"),
    @types.Expr::Literal(@types.Value::IntVal(2))
  )
  let result = exec.execute(@types.Statement::Select(@types.SelectStmt::{
    columns: ["id"],
    table: "m",
    where_clause: Some(where_expr),
    order_by: None,
    limit: None
  }))
  match result {
    @executor.Result::Rows(rows, _) => {
      assert_eq(rows.length(), 1)
      assert_true(rows[0].values[0] == @types.Value::IntVal(2))
    }
    _ => panic()
  }
}
