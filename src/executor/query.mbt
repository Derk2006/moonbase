// MoonBase 查询求值模块：schema 感知的列解析、条件过滤、投影、排序与删除。
// 与 executor.mbt 同属 @executor 包，executor 负责语句分派与本模块的调度。

/// 按列名查列下标；列不存在返回 None
pub fn column_index(schema : @types.TableSchema, name : String) -> Int? {
  for i = 0; i < schema.columns.length(); i = i + 1 {
    if schema.columns[i].name == name {
      return Some(i)
    }
  }
  None
}

/// 取行内第 idx 列的值，越界视为 NULL
fn value_at(row : @types.Row, idx : Int) -> @types.Value {
  if idx < row.values.length() { row.values[idx] } else { @types.Value::Null }
}

/// 值类型排序权重：数值 < 文本 < 布尔 < NULL
fn value_rank(v : @types.Value) -> Int {
  match v {
    @types.Value::Null => 4
    @types.Value::BoolVal(_) => 3
    @types.Value::IntVal(_) => 0
    @types.Value::DoubleVal(_) => 1
    @types.Value::TextVal(_) => 2
  }
}

fn as_double(v : @types.Value) -> Double {
  match v {
    @types.Value::IntVal(n) => n.to_double()
    @types.Value::DoubleVal(d) => d
    @types.Value::BoolVal(b) => if b { 1.0 } else { 0.0 }
    _ => 0.0
  }
}

fn compare_nums(a : Double, b : Double, op : @types.Op) -> Bool {
  match op {
    @types.Op::Eq => a == b
    @types.Op::Ne => a != b
    @types.Op::Lt => a < b
    @types.Op::Le => a <= b
    @types.Op::Gt => a > b
    @types.Op::Ge => a >= b
  }
}

/// 字符串字典序比较（逐码点）。
/// 注意：标准库的 `String::compare` 是「先比长度再比字典序」，不符合 SQL 语义，
/// 因此这里显式逐字符比较码点，长度相同时才以长度定序。
pub fn text_compare(a : String, b : String) -> Int {
  let ca = a.to_array()
  let cb = b.to_array()
  let na = ca.length()
  let nb = cb.length()
  let n = if na < nb { na } else { nb }
  let mut i = 0
  while i < n {
    let x = ca[i].to_int()
    let y = cb[i].to_int()
    if x != y {
      return if x < y { -1 } else { 1 }
    }
    i = i + 1
  }
  if na == nb { 0 } else if na < nb { -1 } else { 1 }
}

/// 三路比较：负数表示 a < b，支持跨数值类型比较
pub fn compare_values(a : @types.Value, b : @types.Value) -> Int {
  let ra = value_rank(a)
  let rb = value_rank(b)
  if ra != rb {
    return if ra < rb { -1 } else { 1 }
  }
  match (a, b) {
    (@types.Value::Null, @types.Value::Null) => 0
    (@types.Value::TextVal(x), @types.Value::TextVal(y)) => text_compare(x, y)
    (@types.Value::BoolVal(x), @types.Value::BoolVal(y)) =>
      if x == y { 0 } else if !x { -1 } else { 1 }
    _ => {
      let d = as_double(a) - as_double(b)
      if d < 0.0 { -1 } else if d > 0.0 { 1 } else { 0 }
    }
  }
}

/// 求值单个表达式；列引用按 schema 中的列名解析
fn eval_value(expr : @types.Expr, row : @types.Row, schema : @types.TableSchema) -> @types.Value {
  match expr {
    @types.Expr::Literal(v) => v
    @types.Expr::ColumnRef(name) => match column_index(schema, name) {
      Some(i) => value_at(row, i)
      None => @types.Value::Null
    }
    _ => @types.Value::Null
  }
}

/// 求值布尔表达式（WHERE 子句）
pub fn eval_expr(expr : @types.Expr, row : @types.Row, schema : @types.TableSchema) -> Bool {
  match expr {
    @types.Expr::Binary(op, left, right) => {
      let lv = eval_value(left, row, schema)
      let rv = eval_value(right, row, schema)
      match (lv, rv) {
        (@types.Value::IntVal(a), @types.Value::IntVal(b)) => match op {
          @types.Op::Eq => a == b
          @types.Op::Ne => a != b
          @types.Op::Lt => a < b
          @types.Op::Le => a <= b
          @types.Op::Gt => a > b
          @types.Op::Ge => a >= b
        }
        (@types.Value::DoubleVal(a), @types.Value::DoubleVal(b)) => match op {
          @types.Op::Eq => a == b
          @types.Op::Ne => a != b
          @types.Op::Lt => a < b
          @types.Op::Le => a <= b
          @types.Op::Gt => a > b
          @types.Op::Ge => a >= b
        }
        // 混合数值类型按 Double 比较
        (@types.Value::IntVal(a), @types.Value::DoubleVal(b)) => compare_nums(a.to_double(), b, op)
        (@types.Value::DoubleVal(a), @types.Value::IntVal(b)) => compare_nums(a, b.to_double(), op)
        (@types.Value::TextVal(a), @types.Value::TextVal(b)) => match op {
          @types.Op::Eq => a == b
          @types.Op::Ne => a != b
          @types.Op::Lt => text_compare(a, b) < 0
          @types.Op::Le => text_compare(a, b) <= 0
          @types.Op::Gt => text_compare(a, b) > 0
          @types.Op::Ge => text_compare(a, b) >= 0
        }
        _ => false
      }
    }
    @types.Expr::And(a, b) => eval_expr(a, row, schema) && eval_expr(b, row, schema)
    @types.Expr::Or(a, b) => eval_expr(a, row, schema) || eval_expr(b, row, schema)
    @types.Expr::Not(e) => !eval_expr(e, row, schema)
    _ => false
  }
}

/// 条件过滤
pub fn filter_rows(
  rows : Array[@types.Row],
  expr : @types.Expr,
  schema : @types.TableSchema
) -> Array[@types.Row] {
  let result : Array[@types.Row] = []
  for row in rows {
    if eval_expr(expr, row, schema) {
      result.push(row)
    }
  }
  result
}

/// 按列下标裁剪行（SELECT col1, col2 的投影语义）
pub fn project_rows(rows : Array[@types.Row], indices : Array[Int]) -> Array[@types.Row] {
  let out : Array[@types.Row] = []
  for row in rows {
    let values : Array[@types.Value] = []
    for i in indices {
      values.push(value_at(row, i))
    }
    out.push(@types.Row::{ values })
  }
  out
}

/// LIMIT n：取前 n 行
pub fn take_rows(rows : Array[@types.Row], n : Int) -> Array[@types.Row] {
  if n <= 0 {
    return []
  }
  let out : Array[@types.Row] = []
  let mut i = 0
  while i < rows.length() && i < n {
    out.push(rows[i])
    i = i + 1
  }
  out
}

/// ORDER BY：列不存在时保持原顺序
pub fn sort_rows(
  rows : Array[@types.Row],
  ob : @types.OrderBy,
  schema : @types.TableSchema
) -> Array[@types.Row] {
  match column_index(schema, ob.column) {
    None => rows
    Some(idx) => {
      let sorted = rows.copy()
      sorted.sort_by(fn(a, b) {
        let cmp = compare_values(value_at(a, idx), value_at(b, idx))
        if ob.desc { -cmp } else { cmp }
      })
      sorted
    }
  }
}

/// 解析 SELECT 的输出列，返回 (列下标, 列名)
fn resolve_columns(
  stmt : @types.SelectStmt,
  schema : @types.TableSchema
) -> (Array[Int], Array[String])? {
  let indices : Array[Int] = []
  let names : Array[String] = []
  if stmt.columns[0] == "*" {
    for i = 0; i < schema.columns.length(); i = i + 1 {
      indices.push(i)
      names.push(schema.columns[i].name)
    }
    return Some((indices, names))
  }
  for name in stmt.columns {
    match column_index(schema, name) {
      Some(i) => {
        indices.push(i)
        names.push(schema.columns[i].name)
      }
      None => return None
    }
  }
  Some((indices, names))
}

/// 执行 SELECT：过滤 → 排序 → 截断 → 投影
pub fn run_select(storage : @storage.Storage, stmt : @types.SelectStmt) -> Result {
  match storage.get_table(stmt.table) {
    None => Err("Table '" + stmt.table + "' not found.")
    Some(table) => {
      let schema = table.schema
      let all_rows = storage.select_all(stmt.table)
      let filtered = match stmt.where_clause {
        Some(expr) => filter_rows(all_rows, expr, schema)
        None => all_rows
      }
      let ordered = match stmt.order_by {
        Some(ob) => sort_rows(filtered, ob, schema)
        None => filtered
      }
      let limited = match stmt.limit {
        Some(n) => take_rows(ordered, n)
        None => ordered
      }
      match resolve_columns(stmt, schema) {
        None => Err("Unknown column in table '" + stmt.table + "'.")
        Some((indices, names)) => Rows(project_rows(limited, indices), names)
      }
    }
  }
}

/// 执行 DELETE：按条件保留未命中行，并重建主键索引
pub fn run_delete(storage : @storage.Storage, stmt : @types.DeleteStmt) -> Result {
  match storage.get_table(stmt.table) {
    None => Err("Table '" + stmt.table + "' not found.")
    Some(table) => {
      let schema = table.schema
      let all_rows = storage.select_all(stmt.table)
      let total = all_rows.length()
      let kept = match stmt.where_clause {
        None => []
        Some(expr) => {
          let keep : Array[@types.Row] = []
          for row in all_rows {
            if !eval_expr(expr, row, schema) {
              keep.push(row)
            }
          }
          keep
        }
      }
      ignore(storage.replace_rows(stmt.table, kept))
      Ok("Deleted " + (total - kept.length()).to_string() + " row(s) from '" + stmt.table + "'.")
    }
  }
}
