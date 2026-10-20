/// 数据库门面：一次打开，多次查询
///
/// 本版本以「只读」为核心约束：不修改文件的任何字节，
/// 因此不存在写放大，也不会因崩溃产生损坏——所有恢复动作都发生在内存镜像里。

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
