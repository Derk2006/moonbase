test "Storage create and insert" {
  let storage = @storage.Storage::new()
  let schema = @types.TableSchema::{
    name: "users",
    columns: [
      @types.Column::{ name: "id", ty: @types.DataType::Int, nullable: false, primary_key: true },
      @types.Column::{ name: "name", ty: @types.DataType::Text, nullable: false, primary_key: false }
    ]
  }
  storage.create_table(schema)
  let row = @types.Row::{ values: [@types.Value::IntVal(1), @types.Value::TextVal("Alice")] }
  assert_true(storage.insert("users", row))
  assert_eq(storage.select_all("users").length(), 1)
}

test "Storage select by key" {
  let storage = @storage.Storage::new()
  let schema = @types.TableSchema::{
    name: "users",
    columns: [
      @types.Column::{ name: "id", ty: @types.DataType::Int, nullable: false, primary_key: true },
      @types.Column::{ name: "name", ty: @types.DataType::Text, nullable: false, primary_key: false }
    ]
  }
  storage.create_table(schema)
  ignore(storage.insert("users", @types.Row::{ values: [@types.Value::IntVal(1), @types.Value::TextVal("Alice")] }))
  ignore(storage.insert("users", @types.Row::{ values: [@types.Value::IntVal(2), @types.Value::TextVal("Bob")] }))
  let got = storage.select_by_key("users", 2)
  assert_true(got is Some(_))
  assert_eq(got.unwrap().values[1], @types.Value::TextVal("Bob"))
}

test "Storage range query" {
  let storage = @storage.Storage::new()
  let schema = @types.TableSchema::{
    name: "scores",
    columns: [
      @types.Column::{ name: "id", ty: @types.DataType::Int, nullable: false, primary_key: true },
      @types.Column::{ name: "score", ty: @types.DataType::Int, nullable: false, primary_key: false }
    ]
  }
  storage.create_table(schema)
  for i = 1; i <= 20; i = i + 1 {
    ignore(storage.insert("scores", @types.Row::{ values: [@types.Value::IntVal(i), @types.Value::IntVal(i * 10)] }))
  }
  let rows = storage.select_range("scores", 5, 10)
  assert_eq(rows.length(), 6)
}
