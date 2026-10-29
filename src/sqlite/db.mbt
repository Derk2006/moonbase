/// 数据库门面：一次打开，多次查询
///
/// 读取路径不修改文件的任何字节：所有解码都在内存中进行，
/// 因此不会因崩溃产生损坏，也不存在写放大。

pub struct RowData {
  rowid : Int64
  values : Array[Value]
}

pub struct Db {
  pager : Pager
  schema : Schema
}

pub fn Db::open(bytes : Bytes) -> Db raise DbError {
  let pager = Pager::open(bytes)
  let schema = build_schema(pager)
  { pager, schema }
}

pub fn Db::pager(self : Db) -> Pager {
  self.pager
}

pub fn Db::schema(self : Db) -> Schema {
  self.schema
}

pub fn Db::table(self : Db, name : String) -> TableDef raise DbError {
  match self.schema.find(name) {
    Some(t) => t
    None => raise NotFound("表不存在：\{name}")
  }
}

/// 读取一张表的全部行
pub fn Db::rows(self : Db, t : TableDef) -> Array[RowData] raise DbError {
  let enc = self.pager.text_encoding()
  let out : Array[RowData] = []
  if t.without_rowid {
    // WITHOUT ROWID 表本身用索引 B 树存储，没有独立 rowid
    let raw = scan_index(self.pager, t.rootpage)
    for r in raw {
      out.push({ rowid: Int64::from_int(0), values: decode_record(r.payload, enc) })
    }
    return out
  }
  let raw = scan_table(self.pager, t.rootpage)
  for r in raw {
    let vals = decode_record(r.payload, enc)
    let full : Array[Value] = []
    for i, c in t.columns {
      if c.is_rowid_alias {
        full.push(VInt(r.rowid))
      } else if i < vals.length() {
        full.push(vals[i])
      } else {
        full.push(VNull)
      }
    }
    out.push({ rowid: r.rowid, values: full })
  }
  out
}

/// 列名解析（大小写不敏感），返回下标；rowid 返回 -1
pub fn TableDef::column_index(self : TableDef, name : String) -> Int? {
  for i, c in self.columns {
    if text_compare(c.name, name) == 0 {
      return Some(i)
    }
  }
  let lower = name.to_lower()
  for i, c in self.columns {
    if text_compare(c.name.to_lower(), lower) == 0 {
      return Some(i)
    }
  }
  None
}

/// 打印用：列名列表
pub fn TableDef::column_names(self : TableDef) -> Array[String] {
  let out : Array[String] = []
  for c in self.columns {
    out.push(c.name)
  }
  out
}

// ---- 索引访问 ----

/// 索引名（结构体字段对包外不可见，外部使用者通过访问器读取）
pub fn IndexDef::index_name(self : IndexDef) -> String {
  self.name
}

/// 索引所属表名
pub fn IndexDef::table_name(self : IndexDef) -> String {
  self.table
}

/// 索引 B 树根页号
pub fn IndexDef::root(self : IndexDef) -> Int {
  self.rootpage
}

/// 库中所有索引名，按 sqlite_master 顺序
pub fn Db::index_names(self : Db) -> Array[String] {
  let out : Array[String] = []
  for idx in self.schema.indexes() {
    out.push(idx.name)
  }
  out
}

fn Db::find_index(self : Db, name : String) -> IndexDef? {
  for idx in self.schema.indexes() {
    if idx.name == name {
      return Some(idx)
    }
  }
  let lower = name.to_lower()
  for idx in self.schema.indexes() {
    if idx.name.to_lower() == lower {
      return Some(idx)
    }
  }
  None
}

/// 读取一只索引的全部条目（按键升序）。
///
/// 每条记录 = 索引列… + rowid，因此最后一项可用于回表。
pub fn Db::index_entries(self : Db, name : String) -> Array[Array[Value]] raise DbError {
  let idx = match self.find_index(name) {
    Some(x) => x
    None => raise NotFound("索引不存在：\{name}")
  }
  let enc = self.pager.text_encoding()
  let out : Array[Array[Value]] = []
  for e in scan_index(self.pager, idx.rootpage) {
    out.push(decode_record(e.payload, enc))
  }
  out
}
