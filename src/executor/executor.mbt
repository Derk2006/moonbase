/// MoonBase 查询执行器

pub(all) struct Executor {
  storage : @storage.Storage
}

pub fn Executor::new(storage : @storage.Storage) -> Executor {
  { storage, }
}

/// 执行 SQL 语句
pub fn Executor::execute(self : Executor, stmt : @types.Statement) -> Result {
  match stmt {
    @types.Statement::Create(c) => self.exec_create(c)
    @types.Statement::Insert(i) => self.exec_insert(i)
    @types.Statement::Select(s) => self.exec_select(s)
    @types.Statement::Delete(d) => self.exec_delete(d)
  }
}

pub(all) enum Result {
  Ok(String)
  Rows(Array[@types.Row], Array[String]) // rows, column names
  Err(String)
} derive(Debug)

fn Executor::exec_create(self : Executor, stmt : @types.CreateStmt) -> Result {
  let schema = @types.TableSchema::{ name: stmt.table, columns: stmt.columns }
  self.storage.create_table(schema)
  Ok("Table '" + stmt.table + "' created.")
}

fn Executor::exec_insert(self : Executor, stmt : @types.InsertStmt) -> Result {
  let mut count = 0
  for row_values in stmt.values {
    let row = @types.Row::{ values: row_values }
    if self.storage.insert(stmt.table, row) {
      count = count + 1
    }
  }
  Ok("Inserted " + count.to_string() + " row(s) into '" + stmt.table + "'.")
}

fn Executor::exec_select(self : Executor, stmt : @types.SelectStmt) -> Result {
  run_select(self.storage, stmt)
}

fn Executor::exec_delete(self : Executor, stmt : @types.DeleteStmt) -> Result {
  run_delete(self.storage, stmt)
}

/// 将结果格式化为字符串
pub fn format_result(result : Result) -> String {
  match result {
    Ok(msg) => msg
    Err(msg) => "ERROR: " + msg
    Rows(rows, cols) => {
      let mut s = ""
      for col in cols { s = s + col + "\t" }
      s = s + "\n"
      for row in rows {
        for i = 0; i < row.values.length(); i = i + 1 {
          s = s + value_to_string(row.values[i]) + "\t"
        }
        s = s + "\n"
      }
      s + "(" + rows.length().to_string() + " row(s))"
    }
  }
}

fn value_to_string(v : @types.Value) -> String {
  match v {
    @types.Value::Null => "NULL"
    @types.Value::IntVal(n) => n.to_string()
    @types.Value::DoubleVal(d) => d.to_string()
    @types.Value::TextVal(t) => t
    @types.Value::BoolVal(b) => b.to_string()
  }
}
