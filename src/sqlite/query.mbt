/// SELECT 查询层
///
/// 支持的语法子集（与 README 的兼容性矩阵一致）：
///   SELECT * | col, ...
///   SELECT COUNT(*)
///   FROM t
///   [WHERE 表达式]   -- = <> < <= > >= 、AND / OR / NOT / IS NULL、字符串与数字字面量
///   [ORDER BY col [ASC|DESC]]
///   [LIMIT n]

pub(all) enum Op2 {
  OEq
  ONe
  OLt
  OLe
  OGt
  OGe
}

pub(all) enum QExpr {
  QLit(Value)
  QCol(String)
  QCmp(Op2, QExpr, QExpr)
  QAnd(QExpr, QExpr)
  QOr(QExpr, QExpr)
  QNot(QExpr)
  QIsNull(QExpr, Bool)
}

pub(all) enum SelectItem {
  Star
  One(String)
  CountStar
  CountOne(String)
}

pub struct SelectQ {
  items : Array[SelectItem]
  table : String
  cond : QExpr?
  order_col : String?
  order_desc : Bool
  limit : Int?
}

pub struct ResultSet {
  columns : Array[String]
  rows : Array[Array[Value]]
}

pub fn ResultSet::columns(self : ResultSet) -> Array[String] {
  self.columns
}

pub fn ResultSet::rows(self : ResultSet) -> Array[Array[Value]] {
  self.rows
}

priv struct Cursor {
  toks : Array[Tok]
  mut pos : Int
}

fn Cursor::peek(self : Cursor) -> Tok {
  self.toks[self.pos]
}

fn Cursor::advance(self : Cursor) -> Tok {
  let t = self.toks[self.pos]
  if self.pos < self.toks.length() - 1 {
    self.pos = self.pos + 1
  }
  t
}

fn Cursor::at_word(self : Cursor, w : String) -> Bool {
  self.peek().is_word(w)
}

fn Cursor::take_word(self : Cursor, w : String) -> Bool {
  if self.at_word(w) {
    ignore(self.advance())
    true
  } else {
    false
  }
}

fn Cursor::expect_word(self : Cursor, w : String) -> Unit raise DbError {
  if !self.take_word(w) {
    raise BadSql("期望关键字 \{w}")
  }
}

fn Cursor::at_sym(self : Cursor, s : String) -> Bool {
  is_sym(self.peek(), s)
}

fn Cursor::take_sym(self : Cursor, s : String) -> Bool {
  if self.at_sym(s) {
    ignore(self.advance())
    true
  } else {
    false
  }
}

fn Cursor::expect_sym(self : Cursor, s : String) -> Unit raise DbError {
  if !self.take_sym(s) {
    raise BadSql("期望符号 \{s}")
  }
}

fn Cursor::word(self : Cursor) -> String raise DbError {
  self.advance().word()
}

fn parse_number_tok(s : String) -> Value {
  if s.contains(".") || s.contains("e") || s.contains("E") {
    let d = try @string.parse_double(s[:]) catch { _ => 0.0 }
    VReal(d)
  } else {
    let i = try @string.parse_int64(s[:]) catch { _ => Int64::from_int(0) }
    VInt(i)
  }
}

fn parse_q_primary(c : Cursor) -> QExpr raise DbError {
  let t = c.peek()
  match t {
    TNumber(s) => {
      ignore(c.advance())
      QLit(parse_number_tok(s))
    }
    TString(s) => {
      ignore(c.advance())
      QLit(VText(s))
    }
    TWord(w) => {
      let up = w.to_upper()
      if up == "NULL" {
        ignore(c.advance())
        QLit(VNull)
      } else if up == "TRUE" {
        ignore(c.advance())
        QLit(VInt(Int64::from_int(1)))
      } else if up == "FALSE" {
        ignore(c.advance())
        QLit(VInt(Int64::from_int(0)))
      } else {
        ignore(c.advance())
        QCol(w)
      }
    }
    TSym("(") => {
      ignore(c.advance())
      let e = parse_q_expr(c)
      c.expect_sym(")")
      e
    }
    _ => raise BadSql("无法解析的表达式")
  }
}

fn parse_q_cmp(c : Cursor) -> QExpr raise DbError {
  let left = parse_q_primary(c)
  let t = c.peek()
  match t {
    TOp(op) => {
      ignore(c.advance())
      let right = parse_q_primary(c)
      let o = match op {
        "=" => OEq
        "<>" => ONe
        "<" => OLt
        "<=" => OLe
        ">" => OGt
        _ => OGe
      }
      QCmp(o, left, right)
    }
    TWord(w) =>
      if w.to_upper() == "IS" {
        ignore(c.advance())
        let negate = c.take_word("NOT")
        c.expect_word("NULL")
        QIsNull(left, negate)
      } else if w.to_upper() == "NOT" {
        ignore(c.advance())
        ignore(c.take_word("NULL"))
        QIsNull(left, true)
      } else if w.to_upper() == "LIKE" {
        raise Unsupported("暂不支持 LIKE")
      } else {
        left
      }
    _ => left
  }
}

fn parse_q_and(c : Cursor) -> QExpr raise DbError {
  let mut left = parse_q_cmp(c)
  while c.take_word("AND") {
    let right = parse_q_cmp(c)
    left = QAnd(left, right)
  }
  left
}

fn parse_q_expr(c : Cursor) -> QExpr raise DbError {
  let mut left = parse_q_and(c)
  while c.take_word("OR") {
    let right = parse_q_and(c)
    left = QOr(left, right)
  }
  left
}

fn parse_select_item(c : Cursor) -> SelectItem raise DbError {
  if c.take_sym("*") {
    return Star
  }
  if c.at_word("COUNT") {
    ignore(c.advance())
    c.expect_sym("(")
    if c.take_sym("*") {
      c.expect_sym(")")
      return CountStar
    }
    let col = c.word()
    c.expect_sym(")")
    return CountOne(col)
  }
  let name = c.word()
  // 忽略别名：col AS x / col x
  if c.take_word("AS") {
    ignore(c.word())
  }
  One(name)
}

pub fn parse_select(sql : String) -> SelectQ raise DbError {
  let toks = lex(sql)
  let c : Cursor = { toks, pos: 0 }
  c.expect_word("SELECT")
  let items : Array[SelectItem] = []
  if c.at_word("DISTINCT") {
    ignore(c.advance())
  }
  while true {
    items.push(parse_select_item(c))
    if !c.take_sym(",") {
      break
    }
  }
  let mut table = ""
  if c.take_word("FROM") {
    table = c.word()
  }
  let mut cond : QExpr? = None
  if c.take_word("WHERE") {
    cond = Some(parse_q_expr(c))
  }
  let mut order_col : String? = None
  let mut order_desc = false
  if c.take_word("ORDER") {
    c.expect_word("BY")
    order_col = Some(c.word())
    if c.take_word("DESC") {
      order_desc = true
    } else {
      ignore(c.take_word("ASC"))
    }
  }
  let mut limit : Int? = None
  if c.take_word("LIMIT") {
    match c.advance() {
      TNumber(s) => limit = Some(try @string.parse_int(s[:]) catch { _ => 0 })
      _ => raise BadSql("LIMIT 后需要整数")
    }
  }
  { items, table, cond, order_col, order_desc, limit }
}

/// 三值逻辑：None 表示 NULL
fn truthy(v : Value) -> Bool? {
  match v {
    VNull => None
    VInt(i) => Some(i != Int64::from_int(0))
    VReal(d) => Some(d != 0.0)
    VText(s) => Some(s.length() > 0)
    VBlob(b) => Some(b.length() > 0)
  }
}

fn eval_col(name : String, row : RowData, t : TableDef) -> Value raise DbError {
  let lower = name.to_lower()
  if lower == "rowid" || lower == "_rowid_" || lower == "oid" {
    return VInt(row.rowid)
  }
  match t.column_index(name) {
    Some(i) =>
      if i < row.values.length() {
        row.values[i]
      } else {
        VNull
      }
    None => raise NotFound("列不存在：\{name}")
  }
}

fn eval_q(e : QExpr, row : RowData, t : TableDef) -> Value raise DbError {
  match e {
    QLit(v) => v
    QCol(n) => eval_col(n, row, t)
    QCmp(op, a, b) => {
      let va = eval_q(a, row, t)
      let vb = eval_q(b, row, t)
      if va.is_null() || vb.is_null() {
        return VNull
      }
      let c = va.compare(vb)
      let r = match op {
        OEq => c == 0
        ONe => c != 0
        OLt => c < 0
        OLe => c <= 0
        OGt => c > 0
        OGe => c >= 0
      }
      VInt(Int64::from_int(if r { 1 } else { 0 }))
    }
    QAnd(a, b) => {
      let ta = truthy(eval_q(a, row, t))
      let tb = truthy(eval_q(b, row, t))
      match (ta, tb) {
        (Some(false), _) => VInt(Int64::from_int(0))
        (_, Some(false)) => VInt(Int64::from_int(0))
        (Some(true), Some(true)) => VInt(Int64::from_int(1))
        _ => VNull
      }
    }
    QOr(a, b) => {
      let ta = truthy(eval_q(a, row, t))
      let tb = truthy(eval_q(b, row, t))
      match (ta, tb) {
        (Some(true), _) => VInt(Int64::from_int(1))
        (_, Some(true)) => VInt(Int64::from_int(1))
        (Some(false), Some(false)) => VInt(Int64::from_int(0))
        _ => VNull
      }
    }
    QNot(a) => {
      match truthy(eval_q(a, row, t)) {
        Some(b) => VInt(Int64::from_int(if b { 0 } else { 1 }))
        None => VNull
      }
    }
    QIsNull(a, negate) => {
      let is_null = eval_q(a, row, t).is_null()
      let r = if negate { !is_null } else { is_null }
      VInt(Int64::from_int(if r { 1 } else { 0 }))
    }
  }
}

fn sort_rows(rows : Array[RowData], idx : Int, desc : Bool) -> Unit {
  // 插入排序：行数通常不大，且无需引入额外依赖
  let n = rows.length()
  for i = 1; i < n; i = i + 1 {
    let cur = rows[i]
    let mut j = i - 1
    while j >= 0 {
      let a = rows[j].values[idx]
      let b = cur.values[idx]
      let c = a.compare(b)
      let should_shift = if desc { c < 0 } else { c > 0 }
      if should_shift {
        rows[j + 1] = rows[j]
        j = j - 1
      } else {
        break
      }
    }
    rows[j + 1] = cur
  }
}

pub fn run_select(db : Db, q : SelectQ) -> ResultSet raise DbError {
  let t = db.table(q.table)
  let mut rows = db.rows(t)
  // WHERE
  match q.cond {
    Some(expr) => {
      let kept : Array[RowData] = []
      for r in rows {
        match truthy(eval_q(expr, r, t)) {
          Some(true) => kept.push(r)
          _ => ()
        }
      }
      rows = kept
    }
    None => ()
  }
  // 聚合
  for it in q.items {
    match it {
      CountStar | CountOne(_) => {
        let label = match it {
          CountStar => "COUNT(*)"
          CountOne(c) => "COUNT(\{c})"
          _ => "COUNT"
        }
        return { columns: [label], rows: [[VInt(Int64::from_int(rows.length()))]] }
      }
      _ => ()
    }
  }
  // ORDER BY
  match q.order_col {
    Some(col) => {
      let lower = col.to_lower()
      if lower == "rowid" {
        // 按 rowid 排序
        let n = rows.length()
        for i = 1; i < n; i = i + 1 {
          let cur = rows[i]
          let mut j = i - 1
          while j >= 0 {
            let c = rows[j].rowid - cur.rowid
            let should_shift = if q.order_desc { c < Int64::from_int(0) } else { c > Int64::from_int(0) }
            if should_shift {
              rows[j + 1] = rows[j]
              j = j - 1
            } else {
              break
            }
          }
          rows[j + 1] = cur
        }
      } else {
        match t.column_index(col) {
          Some(idx) => sort_rows(rows, idx, q.order_desc)
          None => raise NotFound("ORDER BY 列不存在：\{col}")
        }
      }
    }
    None => ()
  }
  // LIMIT
  match q.limit {
    Some(n) =>
      if n >= 0 && n < rows.length() {
        let trimmed : Array[RowData] = []
        for i = 0; i < n; i = i + 1 {
          trimmed.push(rows[i])
        }
        rows = trimmed
      }
    None => ()
  }
  // 投影
  let out_cols : Array[String] = []
  let out_rows : Array[Array[Value]] = []
  for it in q.items {
    match it {
      Star => {
        for c in t.columns {
          out_cols.push(c.name)
        }
      }
      One(n) => out_cols.push(n)
      _ => ()
    }
  }
  for r in rows {
    let vals : Array[Value] = []
    for it in q.items {
      match it {
        Star =>
          for v in r.values {
            vals.push(v)
          }
        One(n) => vals.push(eval_col(n, r, t))
        _ => ()
      }
    }
    out_rows.push(vals)
  }
  { columns: out_cols, rows: out_rows }
}

/// 一步执行：解析 + 查询
pub fn query(db : Db, sql : String) -> ResultSet raise DbError {
  let q = parse_select(sql)
  run_select(db, q)
}
