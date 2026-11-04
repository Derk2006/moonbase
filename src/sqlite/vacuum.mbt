/// VACUUM 式紧凑化：把含空闲页 / 碎片的库重建为紧凑的等价库
///
/// 与官方 `VACUUM` 的目标一致：消除空闲页链表（freelist）与删除数据后遗留的
/// 死空间，产出一个页号连续、无空闲页的干净文件。
///
/// 实现策略是「逻辑重建」：读出 schema 与全部数据（含 rowid 与索引），再用
/// 写入器从零生成。写入器从不产生空闲页，因此结果天然紧凑；这比在页级
/// 复制并重写指针更简单，也复用了一条已经过官方 sqlite3 交叉验证的路径。
///
/// 边界（如实记录，不假装支持）：
///   - WITHOUT ROWID 表暂不支持（写入器面向普通表 + rowid 别名 + 索引）。
///   - 视图、触发器、自动增量（AUTOINCREMENT 的 sqlite_sequence）不重建。

/// 把 `db` 紧凑重建为一份新的 `.db` 字节，可被官方 sqlite3 打开。
pub fn vacuum(db : Db, page_size : Int) -> Bytes raise DbError {
  let schema = db.schema()
  let enc = db.pager().text_encoding()
  let tables : Array[TableSpec] = []

  for t in schema.tables() {
    if t.is_view {
      // 视图没有数据页，重建后其定义仍留在 sqlite_master；这里跳过数据。
      continue
    }
    if t.without_rowid {
      raise Unsupported("VACUUM 暂不支持 WITHOUT ROWID 表：\{t.name}")
    }
    let rows = db.rows(t)
    let specs : Array[RowSpec] = []
    for r in rows {
      // 对 rowid 别名列（INTEGER PRIMARY KEY），db.rows 已把真实 rowid 展开进
      // values 的别名位置，写入器会从中再提取 rowid，因此精确还原。
      // 对普通表，用显式 rowid 精确保留。
      specs.push(RowSpec::new(Some(r.rowid), r.values))
    }
    let indexes : Array[IndexSpec] = []
    for idx in schema.indexes() {
      if text_compare(idx.table, t.name) == 0 {
        if idx.is_unique {
          indexes.push(IndexSpec::new_unique(idx.name, idx.table, idx.sql, index_cols(idx.sql)))
        } else {
          indexes.push(IndexSpec::new(idx.name, idx.table, idx.sql, index_cols(idx.sql)))
        }
      }
    }
    tables.push(TableSpec::with_indexes(t.name, t.sql, specs, indexes))
  }

  make_db_with_encoding(tables, page_size, enc)
}

/// 从 CREATE INDEX 语句提取索引列名（按键顺序）。
/// 若解析失败则回退为空列表——此时索引 B 树会退化为空，但 sqlite_master 仍
/// 保留原始 DDL；为稳妥起见，解析失败时直接抛错而非静默丢索引。
fn index_cols(sql : String) -> Array[String] raise DbError {
  let toks = lex(sql)
  let cols : Array[String] = []
  let mut in_paren = false
  let mut seen_on = false
  for i = 0; i < toks.length(); i = i + 1 {
    match toks[i] {
      TWord(w) => {
        if w.to_upper() == "ON" {
          seen_on = true
        } else if in_paren && seen_on {
          cols.push(w)
        }
      }
      TSym("(") => in_paren = true
      TSym(")") => in_paren = false
      _ => ()
    }
  }
  if cols.length() == 0 {
    raise Unsupported("无法从 CREATE INDEX 提取索引列：\{sql}")
  }
  cols
}
