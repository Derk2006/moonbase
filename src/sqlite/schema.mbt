/// sqlite_master 解析与 schema 构建
///
/// sqlite_master 本身是一张表 B 树（根页固定为 1），字段为：
///   type, name, tbl_name, rootpage, sql

pub struct ColDef {
  name : String
  decl_type : String
  is_pk : Bool
  /// INTEGER PRIMARY KEY 是 rowid 的别名，record 里对应位置存 NULL
  is_rowid_alias : Bool
}

pub struct TableDef {
  name : String
  rootpage : Int
  columns : Array[ColDef]
  without_rowid : Bool
  is_view : Bool
  sql : String
}

pub struct IndexDef {
  name : String
  table : String
  rootpage : Int
  is_unique : Bool
  sql : String
}

pub struct Schema {
  tables : Array[TableDef]
  indexes : Array[IndexDef]
}

pub struct MasterRow {
  kind : String
  name : String
  tbl_name : String
  rootpage : Int
  sql : String
}

pub fn Schema::tables(self : Schema) -> Array[TableDef] {
  self.tables
}

pub fn Schema::indexes(self : Schema) -> Array[IndexDef] {
  self.indexes
}

fn same_name(a : String, b : String) -> Bool {
  text_compare(a, b) == 0
}

pub fn Schema::find(self : Schema, name : String) -> TableDef? {
  for t in self.tables {
    if same_name(t.name, name) {
      return Some(t)
    }
  }
  let lower = name.to_lower()
  for t in self.tables {
    if same_name(t.name.to_lower(), lower) {
      return Some(t)
    }
  }
  None
}

fn is_sym(t : Tok, s : String) -> Bool {
  match t {
    TSym(x) => x == s
    _ => false
  }
}

/// 读取 sqlite_master
pub fn read_master(pager : Pager) -> Array[MasterRow] raise DbError {
  let rows = scan_table(pager, 1)
  let enc = pager.text_encoding()
  let out : Array[MasterRow] = []
  for r in rows {
    let vals = decode_record(r.payload, enc)
    if vals.length() >= 5 {
      let kind = match vals[0] {
        VText(s) => s
        _ => ""
      }
      let name = match vals[1] {
        VText(s) => s
        _ => ""
      }
      let tbl = match vals[2] {
        VText(s) => s
        _ => ""
      }
      let root = match vals[3] {
        VInt(i) => i.to_int()
        _ => 0
      }
      let sql = match vals[4] {
        VText(s) => s
        _ => ""
      }
      out.push({ kind, name, tbl_name: tbl, rootpage: root, sql })
    }
  }
  out
}

fn is_constraint_start(w : String) -> Bool {
  match w.to_upper() {
    "PRIMARY" | "NOT" | "NULL" | "UNIQUE" | "CHECK" | "REFERENCES" | "COLLATE"
    | "DEFAULT" | "GENERATED" | "AS" | "CONSTRAINT" => true
    _ => false
  }
}

/// 把括号内的定义按顶层逗号切开
fn split_top_level(toks : Array[Tok], from : Int, to : Int) -> Array[Array[Tok]] {
  let out : Array[Array[Tok]] = []
  let mut cur : Array[Tok] = []
  let mut depth = 0
  for i = from; i < to; i = i + 1 {
    let t = toks[i]
    if is_sym(t, "(") {
      depth = depth + 1
      cur.push(t)
    } else if is_sym(t, ")") {
      depth = depth - 1
      cur.push(t)
    } else if is_sym(t, ",") && depth == 0 {
      out.push(cur)
      cur = []
    } else {
      cur.push(t)
    }
  }
  if cur.length() > 0 {
    out.push(cur)
  }
  out
}

fn parse_column(item : Array[Tok]) -> ColDef raise DbError {
  let name = item[0].word()
  let types : Array[String] = []
  let mut is_pk = false
  let mut i = 1
  while i < item.length() {
    let t = item[i]
    let w = match t {
      TWord(w) => w
      _ => ""
    }
    if w == "" {
      break
    }
    if is_constraint_start(w) {
      if w.to_upper() == "PRIMARY" {
        is_pk = true
      }
      break
    }
    types.push(w)
    i = i + 1
  }
  let decl_type = types.join(" ")
  { name, decl_type, is_pk, is_rowid_alias: false }
}

fn is_rowid_alias(is_pk : Bool, without_rowid : Bool, decl : String) -> Bool {
  if !is_pk {
    return false
  }
  if without_rowid {
    return false
  }
  text_compare(decl.to_upper(), "INTEGER") == 0
}

/// 解析 CREATE TABLE 语句
pub fn parse_create_table(sql : String, rootpage : Int) -> TableDef raise DbError {
  let toks = lex(sql)
  let mut open = -1
  let mut depth = 0
  let mut close = -1
  for i = 0; i < toks.length(); i = i + 1 {
    if is_sym(toks[i], "(") {
      if open < 0 {
        open = i
        depth = 1
      } else {
        depth = depth + 1
      }
    } else if is_sym(toks[i], ")") {
      depth = depth - 1
      if depth == 0 && close < 0 {
        close = i
      }
    }
  }
  if open < 0 || close < 0 || open == 0 {
    raise BadSql("CREATE TABLE 缺少列定义")
  }
  let name = toks[open - 1].word()
  let items = split_top_level(toks, open + 1, close)
  let cols : Array[ColDef] = []
  let mut pk_from_table : String? = None
  for item in items {
    if item.length() == 0 {
      continue
    }
    let head = match item[0] {
      TWord(w) => w.to_upper()
      _ => ""
    }
    if head == "CONSTRAINT" || head == "UNIQUE" || head == "CHECK" || head == "FOREIGN" {
      continue
    }
    if head == "PRIMARY" {
      for j = 0; j < item.length(); j = j + 1 {
        if is_sym(item[j], "(") && j + 1 < item.length() {
          match item[j + 1] {
            TWord(c) => pk_from_table = Some(c)
            _ => ()
          }
        }
      }
      continue
    }
    cols.push(parse_column(item))
  }
  // WITHOUT ROWID 判定
  let mut without_rowid = false
  for i = close + 1; i + 1 < toks.length(); i = i + 1 {
    if toks[i].is_word("WITHOUT") && toks[i + 1].is_word("ROWID") {
      without_rowid = true
    }
  }
  // 标记 rowid 别名列
  let out : Array[ColDef] = []
  for c in cols {
    let mut is_pk = c.is_pk
    match pk_from_table {
      Some(p) =>
        if same_name(p, c.name) {
          is_pk = true
        }
      None => ()
    }
    let is_alias = is_rowid_alias(is_pk, without_rowid, c.decl_type)
    out.push({ name: c.name, decl_type: c.decl_type, is_pk, is_rowid_alias: is_alias })
  }
  { name, rootpage, columns: out, without_rowid, is_view: false, sql }
}

fn parse_index(sql : String, rootpage : Int) -> IndexDef {
  let toks = lex(sql) catch { _ => [] }
  let mut is_unique = false
  let mut name = ""
  let mut table = ""
  for i = 0; i < toks.length(); i = i + 1 {
    let w = match toks[i] {
      TWord(w) => w.to_upper()
      _ => ""
    }
    if w == "UNIQUE" {
      is_unique = true
    } else if w == "INDEX" && i + 1 < toks.length() {
      name = match toks[i + 1] {
        TWord(x) => x
        _ => ""
      }
    } else if w == "ON" && i + 1 < toks.length() {
      table = match toks[i + 1] {
        TWord(x) => x
        _ => ""
      }
    }
  }
  { name, table, rootpage, is_unique, sql }
}

pub fn build_schema(pager : Pager) -> Schema raise DbError {
  let master = read_master(pager)
  let tables : Array[TableDef] = []
  let indexes : Array[IndexDef] = []
  for m in master {
    if m.kind == "table" {
      let empty : Array[ColDef] = []
      let t = if m.sql.length() > 0 && m.rootpage > 0 {
        try {
          parse_create_table(m.sql, m.rootpage)
        } catch {
          _ => { name: m.name, rootpage: m.rootpage, columns: empty, without_rowid: false, is_view: false, sql: m.sql }
        }
      } else {
        { name: m.name, rootpage: m.rootpage, columns: empty, without_rowid: false, is_view: false, sql: m.sql }
      }
      tables.push(t)
    } else if m.kind == "index" {
      if m.rootpage > 0 && m.sql.length() > 0 {
        indexes.push(parse_index(m.sql, m.rootpage))
      }
    } else if m.kind == "view" {
      tables.push({ name: m.name, rootpage: 0, columns: [], without_rowid: false, is_view: true, sql: m.sql })
    }
  }
  { tables, indexes }
}
