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
  /// LIKE 模式匹配：QLike(expr, 模式字面量, 是否 NOT)
  QLike(QExpr, String, Bool)
  /// IN 列表：QIn(expr, 候选值列表)
  QIn(QExpr, Array[Value])
  /// BETWEEN：QBetween(expr, 下界, 上界)
  QBetween(QExpr, QExpr, QExpr)
}

pub(all) enum AggKind {
  CountStar
  CountOne
  CountDistinct
  Sum
  Avg
  Min
  Max
}

pub(all) enum SelectItem {
  Star
  One(String)
  Agg(AggKind, String)
}

/// NULL 在 ORDER BY 中的位置：默认（升序时 NULL 在前，SQLite 默认）、
/// 显式 FIRST、显式 LAST
pub(all) enum NullsOrder {
  Default
  First
  Last
}

pub(all) enum OrderSpec {
  OrderBy(String, Bool, NullsOrder)
}

pub struct SelectQ {
  items : Array[SelectItem]
  table : String
  cond : QExpr?
  order : Array[OrderSpec]
  limit : Int?
  offset : Int?
  distinct : Bool
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
        // NOT LIKE / NOT IN / NOT NULL
        if c.at_word("NULL") {
          ignore(c.advance())
          QIsNull(left, true)
        } else if c.at_word("LIKE") {
          ignore(c.advance())
          let pat = parse_q_primary(c)
          let pat_str = match pat {
            QLit(VText(s)) => s
            _ => raise BadSql("LIKE 需要文本模式")
          }
          QLike(left, pat_str, true)
        } else if c.at_word("IN") {
          ignore(c.advance())
          let vals = parse_in_list(c)
          QIn(left, vals) |> q_not
        } else {
          left
        }
      } else if w.to_upper() == "LIKE" {
        ignore(c.advance())
        let pat = parse_q_primary(c)
        let pat_str = match pat {
          QLit(VText(s)) => s
          _ => raise BadSql("LIKE 需要文本模式")
        }
        QLike(left, pat_str, false)
      } else if w.to_upper() == "IN" {
        ignore(c.advance())
        QIn(left, parse_in_list(c))
      } else if w.to_upper() == "BETWEEN" {
        ignore(c.advance())
        let lo = parse_q_primary(c)
        c.expect_word("AND")
        let hi = parse_q_primary(c)
        QBetween(left, lo, hi)
      } else {
        left
      }
    _ => left
  }
}

/// 解析 IN 后的括号列表，返回候选值
fn parse_in_list(c : Cursor) -> Array[Value] raise DbError {
  c.expect_sym("(")
  let vals : Array[Value] = []
  while !c.at_sym(")") {
    let p = parse_q_primary(c)
    let v = match p {
      QLit(x) => x
      _ => raise BadSql("IN 列表需要字面量")
    }
    vals.push(v)
    if !c.take_sym(",") {
      break
    }
  }
  c.expect_sym(")")
  vals
}

/// 对布尔表达式取 NOT（用于 NOT IN）
fn q_not(e : QExpr) -> QExpr {
  QNot(e)
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
      return Agg(CountStar, "*")
    }
    if c.take_word("DISTINCT") {
      let col = c.word()
      c.expect_sym(")")
      return Agg(CountDistinct, col)
    }
    let col = c.word()
    c.expect_sym(")")
    return Agg(CountOne, col)
  }
  if c.at_word("SUM") {
    ignore(c.advance())
    c.expect_sym("(")
    let col = c.word()
    c.expect_sym(")")
    return Agg(Sum, col)
  }
  if c.at_word("AVG") {
    ignore(c.advance())
    c.expect_sym("(")
    let col = c.word()
    c.expect_sym(")")
    return Agg(Avg, col)
  }
  if c.at_word("MIN") {
    ignore(c.advance())
    c.expect_sym("(")
    let col = c.word()
    c.expect_sym(")")
    return Agg(Min, col)
  }
  if c.at_word("MAX") {
    ignore(c.advance())
    c.expect_sym("(")
    let col = c.word()
    c.expect_sym(")")
    return Agg(Max, col)
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
  let mut distinct = false
  if c.at_word("DISTINCT") {
    ignore(c.advance())
    distinct = true
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
    // 暂不支持多表 JOIN / GROUP BY / HAVING，明确报错而非静默误解
    if c.at_word("JOIN") || c.at_word("INNER") || c.at_word("LEFT") || c.at_word("RIGHT") {
      raise Unsupported("JOIN")
    }
    if c.at_word("GROUP") {
      raise Unsupported("GROUP BY")
    }
  }
  let mut cond : QExpr? = None
  if c.take_word("WHERE") {
    cond = Some(parse_q_expr(c))
  }
  let order : Array[OrderSpec] = []
  if c.take_word("ORDER") {
    c.expect_word("BY")
    order.push(parse_order_spec(c))
    while c.take_sym(",") {
      order.push(parse_order_spec(c))
    }
  }
  let mut limit : Int? = None
  if c.take_word("LIMIT") {
    match c.advance() {
      TNumber(s) => limit = Some(try @string.parse_int(s[:]) catch { _ => 0 })
      _ => raise BadSql("LIMIT 后需要整数")
    }
  }
  let mut offset : Int? = None
  if c.take_word("OFFSET") {
    match c.advance() {
      TNumber(s) => offset = Some(try @string.parse_int(s[:]) catch { _ => 0 })
      _ => raise BadSql("OFFSET 后需要整数")
    }
  }
  { items, table, cond, order, limit, offset, distinct }
}

/// 解析一个 ORDER BY 项：列名 + 可选 ASC/DESC + 可选 NULLS FIRST/LAST
fn parse_order_spec(c : Cursor) -> OrderSpec raise DbError {
  let col = c.word()
  let desc = if c.take_word("DESC") {
    true
  } else {
    ignore(c.take_word("ASC"))
    false
  }
  let nulls = if c.take_word("NULLS") {
    if c.take_word("FIRST") {
      NullsOrder::First
    } else {
      c.expect_word("LAST")
      NullsOrder::Last
    }
  } else {
    NullsOrder::Default
  }
  OrderBy(col, desc, nulls)
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

/// LIKE 模式匹配：% 匹配任意序列，_ 匹配单个字符。
/// 语义与 SQLite 默认一致：大小写不敏感（仅 ASCII），逐字符回溯匹配。
fn like_match(s : String, pat : String) -> Bool {
  let cs = s.to_array()
  let ps = pat.to_array()
  like_match_at(cs, 0, ps, 0)
}

fn lower_ascii(c : Char) -> Char {
  if c >= 'A' && c <= 'Z' {
    Int::unsafe_to_char(c.to_int() + 32)
  } else {
    c
  }
}

fn like_match_at(cs : Array[Char], si : Int, ps : Array[Char], pi : Int) -> Bool {
  // 主循环处理非 * 部分
  let mut s = si
  let mut p = pi
  while p < ps.length() {
    if ps[p] == '%' {
      // 跳过连续的 %
      while p < ps.length() && ps[p] == '%' {
        p = p + 1
      }
      if p >= ps.length() {
        return true
      }
      // 尝试在 s 的每个位置匹配剩余模式
      let mut k = s
      while k <= cs.length() {
        if like_match_at(cs, k, ps, p) {
          return true
        }
        k = k + 1
      }
      return false
    }
    if s >= cs.length() {
      return false
    }
    let pc = ps[p]
    if pc == '_' {
      s = s + 1
      p = p + 1
      continue
    }
    if lower_ascii(cs[s]) != lower_ascii(pc) {
      return false
    }
    s = s + 1
    p = p + 1
  }
  s == cs.length()
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
    QLike(a, pat, negate) => {
      let v = eval_q(a, row, t)
      let m = match v {
        VText(s) => like_match(s, pat)
        _ => false
      }
      let r = if negate { !m } else { m }
      VInt(Int64::from_int(if r { 1 } else { 0 }))
    }
    QIn(a, vals) => {
      let v = eval_q(a, row, t)
      if v.is_null() {
        VNull
      } else {
        let mut found = false
        for cand in vals {
          if v.compare(cand) == 0 {
            found = true
            break
          }
        }
        VInt(Int64::from_int(if found { 1 } else { 0 }))
      }
    }
    QBetween(a, lo, hi) => {
      let v = eval_q(a, row, t)
      let l = eval_q(lo, row, t)
      let h = eval_q(hi, row, t)
      if v.is_null() || l.is_null() || h.is_null() {
        VNull
      } else {
        let r = v.compare(l) >= 0 && v.compare(h) <= 0
        VInt(Int64::from_int(if r { 1 } else { 0 }))
      }
    }
  }
}

/// 比较两行的多个排序列：返回 -1/0/1。
/// `specs` 为 (列下标, 是否降序, NULL 位置)；-1 表示 rowid。
fn cmp_row_by(
  a : RowData,
  b : RowData,
  specs : Array[(Int, Bool, NullsOrder)]
) -> Int {
  for (idx, desc, nulls) in specs {
    let c = if idx < 0 {
      if a.rowid < b.rowid {
        -1
      } else if a.rowid > b.rowid {
        1
      } else {
        0
      }
    } else {
      let va = if idx < a.values.length() { a.values[idx] } else { VNull }
      let vb = if idx < b.values.length() { b.values[idx] } else { VNull }
      va.compare(vb)
    }
    // NULL 排序单独处理：位置语义已含升降序，直接返回，不再经 desc 翻转。
    if idx >= 0 {
      let va = if idx < a.values.length() { a.values[idx] } else { VNull }
      let vb = if idx < b.values.length() { b.values[idx] } else { VNull }
      match (va.is_null(), vb.is_null()) {
        (true, true) => continue
        (true, false) => {
          let first = match nulls {
            NullsOrder::First => true
            NullsOrder::Last => false
            NullsOrder::Default => !desc
          }
          return if first { -1 } else { 1 }
        }
        (false, true) => {
          let first = match nulls {
            NullsOrder::First => true
            NullsOrder::Last => false
            NullsOrder::Default => !desc
          }
          return if first { 1 } else { -1 }
        }
        (false, false) => ()
      }
    }
    if c != 0 {
      return if desc { -c } else { c }
    }
  }
  0
}

/// 稳定的自底向上归并排序（多列 ORDER BY，含 NULLS FIRST/LAST）
fn sort_rows_multi(rows : Array[RowData], specs : Array[(Int, Bool, NullsOrder)]) -> Unit {
  let n = rows.length()
  if n < 2 {
    return
  }
  let tmp : Array[RowData] = Array::make(n, rows[0])
  let mut width = 1
  while width < n {
    let mut lo = 0
    while lo < n {
      let mid = if lo + width < n { lo + width } else { n }
      let hi = if lo + 2 * width < n { lo + 2 * width } else { n }
      let mut a = lo
      let mut b = mid
      let mut k = lo
      while a < mid && b < hi {
        if cmp_row_by(rows[b], rows[a], specs) < 0 {
          tmp[k] = rows[b]
          b = b + 1
        } else {
          tmp[k] = rows[a]
          a = a + 1
        }
        k = k + 1
      }
      while a < mid {
        tmp[k] = rows[a]
        a = a + 1
        k = k + 1
      }
      while b < hi {
        tmp[k] = rows[b]
        b = b + 1
        k = k + 1
      }
      lo = lo + 2 * width
    }
    for i = 0; i < n; i = i + 1 {
      rows[i] = tmp[i]
    }
    width = width * 2
  }
}

/// 把聚合列解析为下标；rowid 返回 -1，找不到抛错
fn resolve_order_col(t : TableDef, name : String) -> Int raise DbError {
  let lower = name.to_lower()
  if lower == "rowid" || lower == "_rowid_" || lower == "oid" {
    return -1
  }
  match t.column_index(name) {
    Some(i) => i
    None => raise NotFound("ORDER BY 列不存在：\{name}")
  }
}

/// 聚合求值：对一列的值求 SUM/AVG/MIN/MAX。
/// 语义对齐 SQLite：忽略 NULL；SUM 全 NULL 得 NULL，AVG 同理；空集得 NULL。
fn agg_value(kind : AggKind, rows : Array[RowData], idx : Int) -> Value {
  match kind {
    Sum => {
      let mut sum_i : Int64 = Int64::from_int(0)
      let mut sum_d : Double = 0.0
      let mut is_real = false
      let mut any = false
      for r in rows {
        let v = if idx < r.values.length() { r.values[idx] } else { VNull }
        match v {
          VInt(i) => {
            any = true
            sum_i = sum_i + i
          }
          VReal(d) => {
            any = true
            is_real = true
            sum_d = sum_d + d
          }
          _ => ()
        }
      }
      if !any {
        VNull
      } else if is_real {
        VReal(sum_i.to_double() + sum_d)
      } else {
        VInt(sum_i)
      }
    }
    Avg => {
      let mut sum : Double = 0.0
      let mut cnt = 0
      for r in rows {
        let v = if idx < r.values.length() { r.values[idx] } else { VNull }
        match v {
          VInt(i) => {
            sum = sum + i.to_double()
            cnt = cnt + 1
          }
          VReal(d) => {
            sum = sum + d
            cnt = cnt + 1
          }
          _ => ()
        }
      }
      if cnt == 0 {
        VNull
      } else {
        VReal(sum / cnt.to_double())
      }
    }
    Min => {
      let mut best : Value? = None
      for r in rows {
        let v = if idx < r.values.length() { r.values[idx] } else { VNull }
        match v {
          VNull => ()
          _ =>
            match best {
              None => best = Some(v)
              Some(b) =>
                if v.compare(b) < 0 {
                  best = Some(v)
                }
            }
        }
      }
      match best {
        Some(x) => x
        None => VNull
      }
    }
    Max => {
      let mut best : Value? = None
      for r in rows {
        let v = if idx < r.values.length() { r.values[idx] } else { VNull }
        match v {
          VNull => ()
          _ =>
            match best {
              None => best = Some(v)
              Some(b) =>
                if v.compare(b) > 0 {
                  best = Some(v)
                }
            }
        }
      }
      match best {
        Some(x) => x
        None => VNull
      }
    }
    CountOne => {
      let mut cnt = 0
      for r in rows {
        let v = if idx < r.values.length() { r.values[idx] } else { VNull }
        match v {
          VNull => ()
          _ => cnt = cnt + 1
        }
      }
      VInt(Int64::from_int(cnt))
    }
    CountDistinct => {
      let seen : Array[Value] = []
      for r in rows {
        let v = if idx < r.values.length() { r.values[idx] } else { VNull }
        if v.is_null() {
          continue
        }
        let mut dup = false
        for s in seen {
          if s.same(v) {
            dup = true
            break
          }
        }
        if !dup {
          seen.push(v)
        }
      }
      VInt(Int64::from_int(seen.length()))
    }
    CountStar => VInt(Int64::from_int(rows.length()))
  }
}

fn agg_label(kind : AggKind, col : String) -> String {
  match kind {
    CountStar => "COUNT(*)"
    CountOne => "COUNT(\{col})"
    CountDistinct => "COUNT(DISTINCT \{col})"
    Sum => "SUM(\{col})"
    Avg => "AVG(\{col})"
    Min => "MIN(\{col})"
    Max => "MAX(\{col})"
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
  // 聚合：若选择项里有聚合，则整条查询走聚合路径（单行结果）
  for it in q.items {
    match it {
      Agg(kind, col) => {
        let idx = match kind {
          CountStar => -1
          _ => resolve_order_col(t, col)
        }
        let val = agg_value(kind, rows, idx)
        return { columns: [agg_label(kind, col)], rows: [[val]] }
      }
      _ => ()
    }
  }
  // ORDER BY（支持多列 + NULLS FIRST/LAST）
  if q.order.length() > 0 {
    let specs : Array[(Int, Bool, NullsOrder)] = []
    for o in q.order {
      match o {
        OrderBy(col, desc, nulls) => specs.push((resolve_order_col(t, col), desc, nulls))
      }
    }
    sort_rows_multi(rows, specs)
  }
  // OFFSET + LIMIT
  let start = match q.offset {
    Some(o) => if o > 0 { o } else { 0 }
    None => 0
  }
  match q.limit {
    Some(n) => {
      let trimmed : Array[RowData] = []
      let mut i = start
      let mut taken = 0
      while i < rows.length() && taken < n {
        trimmed.push(rows[i])
        i = i + 1
        taken = taken + 1
      }
      rows = trimmed
    }
    None =>
      if start > 0 {
        let trimmed : Array[RowData] = []
        for i = start; i < rows.length(); i = i + 1 {
          trimmed.push(rows[i])
        }
        rows = trimmed
      }
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
  // DISTINCT：按整行去重（语义对齐 SQLite，作用于投影后的行）
  if q.distinct {
    let dedup : Array[Array[Value]] = []
    for row in out_rows {
      let mut dup = false
      for seen in dedup {
        if row_same(seen, row) {
          dup = true
          break
        }
      }
      if !dup {
        dedup.push(row)
      }
    }
    return { columns: out_cols, rows: dedup }
  }
  { columns: out_cols, rows: out_rows }
}

/// 判断两行值是否逐列相等（NULL 与 NULL 相等）
fn row_same(a : Array[Value], b : Array[Value]) -> Bool {
  if a.length() != b.length() {
    return false
  }
  for i = 0; i < a.length(); i = i + 1 {
    let (va, vb) = (a[i], b[i])
    match (va.is_null(), vb.is_null()) {
      (true, true) => continue
      (true, false) => return false
      (false, true) => return false
      (false, false) =>
        if va.compare(vb) != 0 {
          return false
        }
    }
  }
  true
}

/// 一步执行：解析 + 查询
pub fn query(db : Db, sql : String) -> ResultSet raise DbError {
  let q = parse_select(sql)
  run_select(db, q)
}
