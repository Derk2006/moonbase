/// MoonBase CLI — 交互式 SQL 执行器

fn main {
  let storage = @storage.Storage::new()
  let exec = @executor.Executor::new(storage)
  let _txm = @tx.TxManager::new(storage)

  println("MoonBase v0.1.0 — Lightweight embedded database kernel")
  println("Type SQL statements, or 'quit' to exit.")
  println("")

  // 演示：直接执行一组 SQL
  let demo_statements = [
    "CREATE TABLE users (id INT PRIMARY KEY, name TEXT NOT NULL)",
    "INSERT INTO users (id, name) VALUES (1, 'Alice'), (2, 'Bob'), (3, 'Charlie')",
    "SELECT * FROM users",
    "SELECT * FROM users WHERE id = 2",
  ]

  for sql in demo_statements {
    println("> " + sql)
    match @sql.parse(sql) {
      Some(stmt) => {
        let result = exec.execute(stmt)
        println(@executor.format_result(result))
      }
      None => println("ERROR: Failed to parse SQL")
    }
    println("")
  }

  println("Demo complete. In a full CLI, this would read from stdin interactively.")
}
