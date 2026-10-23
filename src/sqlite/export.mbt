/// 把数据库导出为 SQL 脚本（兼容官方 `sqlite3 .dump` 的输出习惯）
///
/// 顺序：先 `CREATE TABLE` / `CREATE VIEW`，再逐表 `INSERT`，最后 `CREATE INDEX`。
/// 生成结果可直接喂给官方 sqlite3：
///   moonbase-cli dump-sql demo.db > demo.sql
///   sqlite3 restored.db < demo.sql
///
/// 这也是「读侧 + 写侧」能力的自然衔接：从任意真实 `.db` 读出结构与数据，
/// 再产出一份可被官方工具重放的 SQL 脚本。

/// 文本字面量：单引号包裹，内部单引号写成两个（SQL 标准转义）
fn sql_text(s : String) -> String {
  "'" + s.replace_all(old="'", new="''") + "'"
}

/// 标识符：双引号包裹，内部双引号写成两个
fn sql_ident(name : String) -> String {
  "\"" + name.replace_all(old="\"", new="\"\"") + "\""
}

/// 单个值 → SQL 字面量
pub fn sql_literal(v : Value) -> String {
  match v {
    VNull => "NULL"
    VInt(i) => i.to_string()
    VReal(d) =>
      if d.is_nan() {
        "NULL"
      } else if d > 1.7976931348623157e308 {
        "9e999"
      } else if d < -1.7976931348623157e308 {
        "-9e999"
      } else {
        format_real(d)
      }
    VText(s) => sql_text(s)
    // to_display 对 BLOB 已输出 X'..' 形式，正是 SQLite 的 BLOB 字面量
    VBlob(_) => v.to_display()
  }
}

fn sql_values(vals : Array[Value]) -> String {
  let parts : Array[String] = []
  for v in vals {
    parts.push(sql_literal(v))
  }
  "(" + parts.join(", ") + ")"
}

fn sql_columns(cols : Array[String]) -> String {
  let parts : Array[String] = []
  for c in cols {
    parts.push(sql_ident(c))
  }
  "(" + parts.join(", ") + ")"
}

/// 导出整库为 SQL 文本
pub fn export_sql(db : Db) -> String raise DbError {
  let schema = db.schema()
  let tables = schema.tables()
  let mut out = "-- MoonBase SQL dump\n"
  out = out + "PRAGMA foreign_keys=OFF;\n"
  out = out + "BEGIN TRANSACTION;\n"
  // 1) 表 / 视图定义（保留 sqlite_master 里的原始 DDL）
  for t in tables {
    if t.sql.length() > 0 {
      out = out + t.sql + ";\n"
    }
  }
  // 2) 数据
  for t in tables {
    if t.is_view {
      continue
    }
    let cols = t.column_names()
    if cols.length() == 0 {
      continue
    }
    let rows = db.rows(t)
    if rows.length() == 0 {
      continue
    }
    let head = "INSERT INTO " + sql_ident(t.name) + " " + sql_columns(cols) + " VALUES "
    for r in rows {
      out = out + head + sql_values(r.values) + ";\n"
    }
  }
  // 3) 索引
  for idx in schema.indexes() {
    if idx.sql.length() > 0 {
      out = out + idx.sql + ";\n"
    }
  }
  out = out + "COMMIT;\n"
  out
}
