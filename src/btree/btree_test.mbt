test "BTree insert and get" {
  let tree = @btree.BTree::new(order=4)
  let row = @types.Row::{ values: [@types.Value::IntVal(1), @types.Value::TextVal("Alice")] }
  tree.insert(1, row)
  let got = tree.get(1)
  assert_true(got is Some(_))
  assert_eq(got.unwrap().values[1], @types.Value::TextVal("Alice"))
}

test "BTree multiple inserts" {
  let tree = @btree.BTree::new(order=4)
  for i = 1; i <= 10; i = i + 1 {
    let row = @types.Row::{ values: [@types.Value::IntVal(i), @types.Value::TextVal("user_" + i.to_string())] }
    tree.insert(i, row)
  }
  assert_eq(tree.all_keys().length(), 10)
  for i = 1; i <= 10; i = i + 1 {
    let got = tree.get(i)
    assert_true(got is Some(_))
  }
}

test "BTree range scan" {
  let tree = @btree.BTree::new(order=4)
  for i = 1; i <= 20; i = i + 1 {
    let row = @types.Row::{ values: [@types.Value::IntVal(i), @types.Value::TextVal("u" + i.to_string())] }
    tree.insert(i, row)
  }
  let rows = tree.range(5, 10)
  assert_eq(rows.length(), 6)
}

test "BTree split stress test" {
  let tree = @btree.BTree::new(order=4)
  for i = 1; i <= 100; i = i + 1 {
    let row = @types.Row::{ values: [@types.Value::IntVal(i), @types.Value::TextVal("x")] }
    tree.insert(i, row)
  }
  assert_eq(tree.all_keys().length(), 100)
  assert_true(tree.get(50) is Some(_))
  assert_true(tree.get(99) is Some(_))
}
