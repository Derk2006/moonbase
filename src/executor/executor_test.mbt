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
    where_clause: None
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
    where_clause: Some(where_expr)
  }))
  match result {
    @executor.Result::Rows(rows, _) => {
      assert_eq(rows.length(), 3) // id 3,4,5
    }
    _ => panic()
  }
}
