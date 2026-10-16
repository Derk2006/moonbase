test "TxManager begin and commit" {
  let storage = @storage.Storage::new()
  let schema = @types.TableSchema::{
    name: "users",
    columns: [
      @types.Column::{ name: "id", ty: @types.DataType::Int, nullable: false, primary_key: true },
      @types.Column::{ name: "name", ty: @types.DataType::Text, nullable: false, primary_key: false }
    ]
  }
  storage.create_table(schema)
  let txm = @tx.TxManager::new(storage)
  let tx = txm.begin()
  assert_true(tx is Some(_))
  assert_true(txm.insert("users", @types.Row::{ values: [@types.Value::IntVal(1), @types.Value::TextVal("Alice")] }))
  assert_true(txm.commit())
  assert_eq(storage.select_all("users").length(), 1)
}

test "TxManager rollback" {
  let storage = @storage.Storage::new()
  let schema = @types.TableSchema::{
    name: "users",
    columns: [
      @types.Column::{ name: "id", ty: @types.DataType::Int, nullable: false, primary_key: true },
      @types.Column::{ name: "name", ty: @types.DataType::Text, nullable: false, primary_key: false }
    ]
  }
  storage.create_table(schema)
  let txm = @tx.TxManager::new(storage)
  let tx = txm.begin()
  assert_true(tx is Some(_))
  assert_true(txm.insert("users", @types.Row::{ values: [@types.Value::IntVal(1), @types.Value::TextVal("Alice")] }))
  assert_true(txm.rollback())
  assert_eq(storage.select_all("users").length(), 0)
}

test "TxManager no nested tx" {
  let storage = @storage.Storage::new()
  let txm = @tx.TxManager::new(storage)
  let tx1 = txm.begin()
  assert_true(tx1 is Some(_))
  let tx2 = txm.begin()
  assert_true(tx2 is None) // 不支持嵌套
}
