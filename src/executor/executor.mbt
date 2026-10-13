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
  match self.storage.get_table(stmt.table) {
    Some(table) => {
      let all_rows = self.storage.select_all(stmt.table)
      let filtered = match stmt.where_clause {
        Some(expr) => filter_rows(all_rows, expr)
        None => all_rows
      }
      let col_names = if stmt.columns[0] == "*" {
        let names : Array[String] = []
        for col in table.schema.columns { names.push(col.name) }
        names
      } else {
        stmt.columns
      }
      Rows(filtered, col_names)
    }
    None => Err("Table '" + stmt.table + "' not found.")
  }
}

fn filter_rows(rows : Array[@types.Row], expr : @types.Expr) -> Array[@types.Row] {
  let result : Array[@types.Row] = []
  for row in rows {
    if eval_expr(expr, row) {
      result.push(row)
    }
  }
  result
}

fn eval_expr(expr : @types.Expr, row : @types.Row) -> Bool {
  match expr {
    @types.Expr::Binary(op, left, right) => {
      let lv = eval_value(left, row)
      let rv = eval_value(right, row)
      match (lv, rv) {
        (@types.Value::IntVal(a), @types.Value::IntVal(b)) => match op {
          @types.Op::Eq => a == b
          @types.Op::Ne => a != b
          @types.Op::Lt => a < b
          @types.Op::Le => a <= b
          @types.Op::Gt => a > b
          @types.Op::Ge => a >= b
        }
        (@types.Value::TextVal(a), @types.Value::TextVal(b)) => match op {
          @types.Op::Eq => a == b
          @types.Op::Ne => a != b
          _ => false
        }
        _ => false
      }
    }
    @types.Expr::And(a, b) => eval_expr(a, row) && eval_expr(b, row)
    @types.Expr::Or(a, b) => eval_expr(a, row) || eval_expr(b, row)
    @types.Expr::Not(e) => !eval_expr(e, row)
    _ => false
  }
}

fn eval_value(expr : @types.Expr, row : @types.Row) -> @types.Value {
  match expr {
    @types.Expr::Literal(v) => v
    @types.Expr::ColumnRef(_name) => {
      // 简化：按位置查找（假设列顺序固定）
      // 实际应该根据 schema 映射，这里用索引 0 兜底
      if row.values.length() > 0 { row.values[0] } else { @types.Value::Null }
    }
    _ => @types.Value::Null
  }
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
