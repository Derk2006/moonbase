test "DataType equality" {
  assert_eq(@types.DataType::Int, @types.DataType::Int)
  assert_false(@types.DataType::Int == @types.DataType::Text)
}

test "Value creation and equality" {
  let v1 = @types.Value::IntVal(42)
  let v2 = @types.Value::IntVal(42)
  let v3 = @types.Value::TextVal("hello")
  assert_eq(v1, v2)
  assert_false(v1 == v3)
}

test "Column creation" {
  let col = @types.Column::{ name: "id", ty: @types.DataType::Int, nullable: false, primary_key: true }
  assert_eq(col.name, "id")
  assert_eq(col.primary_key, true)
}

test "Row creation" {
  let row = @types.Row::{ values: [@types.Value::IntVal(1), @types.Value::TextVal("Alice")] }
  assert_eq(row.values.length(), 2)
}

test "TableSchema creation" {
  let schema = @types.TableSchema::{
    name: "users",
    columns: [
      @types.Column::{ name: "id", ty: @types.DataType::Int, nullable: false, primary_key: true },
      @types.Column::{ name: "name", ty: @types.DataType::Text, nullable: false, primary_key: false }
    ]
  }
  assert_eq(schema.name, "users")
  assert_eq(schema.columns.length(), 2)
}

test "Expr construction" {
  let expr = @types.Expr::Binary(
    @types.Op::Eq,
    @types.Expr::ColumnRef("id"),
    @types.Expr::Literal(@types.Value::IntVal(1))
  )
  match expr {
    @types.Expr::Binary(op, _, _) => assert_true(op == @types.Op::Eq)
    _ => panic()
  }
}
