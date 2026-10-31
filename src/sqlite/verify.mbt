/// 结构自检：不依赖官方 sqlite3，独立走一遍文件结构
///
/// 与「扫描查询」不同，这里关心的是**格式本身是否自洽**：
///   - 文件长度与页大小、页数是否吻合
///   - sqlite_master 的每棵树能否走通，页类型是否与所在树匹配
///   - 有没有被两处引用的页、越界的子页指针、无单元的内部页
///   - 表 B 树按 rowid 严格递增、索引 B 树按索引键严格递增
///   - 溢出页链是否完整、是否成环
///   - 是否存在没有任何人引用的页
///
/// 这些正是 `PRAGMA integrity_check` 的核心项，只是换成了纯 MoonBit 的实现，
/// 因此在没有 sqlite3 的环境（例如 wasm / 浏览器）里也能自证文件合法。

/// 自检结果
pub struct VerifyReport {
  pages_total : Int
  leaf_table : Int
  interior_table : Int
  leaf_index : Int
  interior_index : Int
  overflow : Int
  freelist : Int
  unreferenced : Int
  table_rows : Int
  index_entries : Int
  tables : Array[(String, Int, Int)]
  indexes : Array[(String, Int, Int)]
  problems : Array[String]
}

pub fn VerifyReport::passed(self : VerifyReport) -> Bool {
  self.problems.length() == 0
}

pub fn VerifyReport::problems(self : VerifyReport) -> Array[String] {
  self.problems
}

// 计数器下标
const C_LEAF_TABLE : Int = 0
const C_INTERIOR_TABLE : Int = 1
const C_LEAF_INDEX : Int = 2
const C_INTERIOR_INDEX : Int = 3
const C_OVERFLOW : Int = 4
const C_UNREFERENCED : Int = 5
const C_FREELIST : Int = 8
const C_ROWS : Int = 6
const C_ENTRIES : Int = 7

/// 跟随 payload 的溢出页链，顺带把链上的页标记为已引用
fn track_payload(
  pager : Pager,
  data : Bytes,
  offset : Int,
  plen : Int,
  is_table : Bool,
  visited : Array[Bool],
  counters : Array[Int],
  problems : Array[String]
) -> Unit raise DbError {
  if plen == 0 {
    return
  }
  let usable = pager.usable()
  let loc = local_payload_size(usable, plen, is_table)
  if loc == plen {
    return
  }
  let mut next = be32(data, offset + loc)
  let mut got = loc
  let mut steps = 0
  while next != 0 && got < plen {
    steps = steps + 1
    if steps > 100000 {
      problems.push("溢出页链过长或成环")
      return
    }
    if next < 1 || next >= visited.length() {
      problems.push("溢出页号越界：\{next}")
      return
    }
    if visited[next] {
      problems.push("溢出页 \{next} 被重复引用")
      return
    }
    visited[next] = true
    counters[C_OVERFLOW] = counters[C_OVERFLOW] + 1
    let ov = pager.page(next)
    got = got + min_int(usable - 4, plen - got)
    next = be32(ov, 0)
  }
  if got != plen {
    problems.push("溢出页链长度不足：期望 \{plen}，实得 \{got}")
  }
}

/// 走一棵 B 树，返回层数（叶子为 1）
fn walk_tree(
  pager : Pager,
  no : Int,
  want_table : Bool,
  visited : Array[Bool],
  counters : Array[Int],
  problems : Array[String],
  depth : Int
) -> Int raise DbError {
  if depth > 64 {
    problems.push("B 树深度超过 64，可能存在环")
    return 0
  }
  if no < 1 || no >= visited.length() {
    problems.push("子页指针越界：\{no}")
    return 0
  }
  if visited[no] {
    problems.push("页 \{no} 被重复引用")
    return 0
  }
  visited[no] = true
  let page = BtreePage::parse(pager, no) catch {
    _ => {
      problems.push("页 \{no} 解析失败")
      return 0
    }
  }
  // 单元数超过页容量说明页头被破坏，继续解析只会一路报越界
  let max_cells = (pager.page_size() - 12) / 2
  if page.ncell > max_cells {
    problems.push("页 \{no} 的单元数 \{page.ncell} 超出页容量（上限 \{max_cells}）")
    return 0
  }
  if page.is_table() != want_table {
    let kind = if want_table { "表" } else { "索引" }
    problems.push("页 \{no} 出现在\{kind} B 树中，但类型是 \{page_type_name(page.page_type)}")
    return 0
  }
  if page.is_leaf() {
    if page.ncell == 0 && no != 1 {
      problems.push("叶子页 \{no} 没有任何单元")
    }
    if want_table {
      counters[C_LEAF_TABLE] = counters[C_LEAF_TABLE] + 1
      counters[C_ROWS] = counters[C_ROWS] + page.ncell
      for i = 0; i < page.ncell; i = i + 1 {
        let off = page.cell_offset(i)
        let (plen, n1) = read_varint(page.data, off)
        let (_, n2) = read_varint(page.data, off + n1)
        track_payload(
          pager, page.data, off + n1 + n2, plen.to_int(), true, visited, counters,
          problems,
        )
      }
    } else {
      counters[C_LEAF_INDEX] = counters[C_LEAF_INDEX] + 1
      counters[C_ENTRIES] = counters[C_ENTRIES] + page.ncell
      for i = 0; i < page.ncell; i = i + 1 {
        let off = page.cell_offset(i)
        let (plen, n1) = read_varint(page.data, off)
        track_payload(
          pager, page.data, off + n1, plen.to_int(), false, visited, counters,
          problems,
        )
      }
    }
    return 1
  }
  // 内部页
  if want_table {
    counters[C_INTERIOR_TABLE] = counters[C_INTERIOR_TABLE] + 1
  } else {
    counters[C_INTERIOR_INDEX] = counters[C_INTERIOR_INDEX] + 1
    counters[C_ENTRIES] = counters[C_ENTRIES] + page.ncell
  }
  if page.ncell == 0 && page.right_child == 0 {
    problems.push("内部页 \{no} 既无单元也无最右子页")
    return 1
  }
  let mut deepest = 0
  for i = 0; i < page.ncell; i = i + 1 {
    let off = page.cell_offset(i)
    let child = be32(page.data, off)
    if !want_table {
      // 索引内部页的单元里还带着一个键，键也可能溢出
      let (plen, n1) = read_varint(page.data, off + 4)
      track_payload(
        pager, page.data, off + 4 + n1, plen.to_int(), false, visited, counters,
        problems,
      )
    }
    let d = walk_tree(pager, child, want_table, visited, counters, problems, depth + 1)
    if d > deepest {
      deepest = d
    }
  }
  if page.right_child == 0 {
    problems.push("内部页 \{no} 的最右子页指针为 0")
  } else {
    let d = walk_tree(
      pager, page.right_child, want_table, visited, counters, problems, depth + 1,
    )
    if d > deepest {
      deepest = d
    }
  }
  deepest + 1
}

/// 标记空闲链表（freelist）里的页
///
/// 官方 sqlite3 删除数据后会把这些页挂到链表上：主链页的前 4 字节是下一个
/// 主链页，接着 4 字节是本页挂了多少个叶子页号。它们不属于任何 B 树，
/// 但对整库自检来说必须算作「已认领」，否则会被误报成孤儿页。
fn mark_freelist(
  pager : Pager,
  visited : Array[Bool],
  counters : Array[Int],
  problems : Array[String]
) -> Unit raise DbError {
  let header = pager.header()
  let mut no = header.freelist_trunk
  let mut hops = 0
  while no != 0 && hops < 100000 {
    hops = hops + 1
    if no < 1 || no >= visited.length() {
      problems.push("空闲链表页号越界：\{no}")
      return
    }
    if visited[no] {
      problems.push("空闲链表页 \{no} 被重复引用")
      return
    }
    visited[no] = true
    counters[C_FREELIST] = counters[C_FREELIST] + 1
    let page = pager.page(no)
    let leaves = be32(page, 4)
    for i = 0; i < leaves; i = i + 1 {
      let leaf = be32(page, 8 + 4 * i)
      if leaf < 1 || leaf >= visited.length() {
        problems.push("空闲页号越界：\{leaf}")
      } else if visited[leaf] {
        problems.push("空闲页 \{leaf} 被重复引用")
      } else {
        visited[leaf] = true
        counters[C_FREELIST] = counters[C_FREELIST] + 1
      }
    }
    no = be32(page, 0)
  }
}

/// 检查一组 rowid 是否严格递增
fn check_rowids(rows : Array[TableRow], problems : Array[String], label : String) -> Unit {
  let mut prev = Int64::from_int(0)
  for i = 0; i < rows.length(); i = i + 1 {
    if i > 0 && rows[i].rowid <= prev {
      problems.push("\{label} 的 rowid 未严格递增（第 \{i + 1} 行）")
      return
    }
    prev = rows[i].rowid
  }
}

/// 检查索引键是否严格递增
fn check_index_order(
  pager : Pager,
  root : Int,
  problems : Array[String],
  label : String
) -> Unit raise DbError {
  let entries = scan_index(pager, root)
  let mut prev : Array[Value]? = None
  for e in entries {
    let key = decode_record(e.payload, 1)
    match prev {
      Some(p) =>
        if cmp_key_vec(p, key) >= 0 {
          problems.push("\{label} 的键未严格递增")
          return
        }
      None => ()
    }
    prev = Some(key)
  }
}

/// 对整库做结构自检
pub fn verify_db(db : Db) -> VerifyReport raise DbError {
  let pager = db.pager()
  let header = pager.header()
  let raw = pager.raw()
  let page_count = pager.page_count()
  let problems : Array[String] = []
  let counters : Array[Int] = Array::make(9, 0)
  let visited : Array[Bool] = Array::make(page_count + 1, false)

  if raw.length() != page_count * header.page_size {
    problems.push(
      "文件长度 \{raw.length()} 与页大小 × 页数（\{header.page_size} × \{page_count}）不一致",
    )
  }
  if header.page_count != page_count {
    problems.push("头部声明的页数 \{header.page_count} 与实际 \{page_count} 不一致")
  }

  // 页 1 固定是 sqlite_master
  let master_depth = walk_tree(pager, 1, true, visited, counters, problems, 0)
  if master_depth == 0 {
    problems.push("sqlite_master 无法遍历")
  }
  // 页 1 里的行是 schema 记录（表 / 索引定义），不计入用户表行数
  let schema_rows = counters[C_ROWS]

  let schema = db.schema()
  let tables : Array[(String, Int, Int)] = []
  let indexes : Array[(String, Int, Int)] = []
  for t in schema.tables() {
    if t.rootpage <= 0 {
      continue
    }
    if t.without_rowid {
      // WITHOUT ROWID 表在文件里就是一棵索引 B 树（键是主键记录本身）
      let before = counters[C_ENTRIES]
      let depth = walk_tree(pager, t.rootpage, false, visited, counters, problems, 0)
      check_index_order(pager, t.rootpage, problems, "表 \{t.name}")
      let n = counters[C_ENTRIES] - before
      tables.push((t.name, depth, n))
      continue
    }
    let before_rows = counters[C_ROWS]
    let depth = walk_tree(pager, t.rootpage, true, visited, counters, problems, 0)
    let rows = scan_table(pager, t.rootpage) catch {
      _ => {
        problems.push("表 \{t.name} 扫描失败")
        []
      }
    }
    check_rowids(rows, problems, "表 \{t.name}")
    let nrows = counters[C_ROWS] - before_rows
    if nrows != rows.length() {
      problems.push("表 \{t.name} 的单元数与扫描行数不一致：\{nrows} vs \{rows.length()}")
    }
    tables.push((t.name, depth, rows.length()))
  }
  for idx in schema.indexes() {
    if idx.rootpage <= 0 {
      continue
    }
    let before_entries = counters[C_ENTRIES]
    let depth = walk_tree(pager, idx.rootpage, false, visited, counters, problems, 0)
    check_index_order(pager, idx.rootpage, problems, "索引 \{idx.name}")
    let n = counters[C_ENTRIES] - before_entries
    let scanned = scan_index(pager, idx.rootpage) catch { _ => [] }
    if n != scanned.length() {
      problems.push("索引 \{idx.name} 的条目数不一致：\{n} vs \{scanned.length()}")
    }
    indexes.push((idx.name, depth, scanned.length()))
  }

  // 空闲链表里的页本来就没有人引用，先标掉，免得被误当成孤儿页
  mark_freelist(pager, visited, counters, problems)

  // 剩下的没被任何树引用的页：写入器不该产生（只有溢出页会被标记为已引用）
  for no = 2; no <= page_count; no = no + 1 {
    if !visited[no] {
      counters[C_UNREFERENCED] = counters[C_UNREFERENCED] + 1
    }
  }
  if counters[C_UNREFERENCED] > 0 {
    problems.push("\{counters[C_UNREFERENCED]} 个页没有被任何 B 树或溢出链引用")
  }

  {
    pages_total: page_count,
    leaf_table: counters[C_LEAF_TABLE],
    interior_table: counters[C_INTERIOR_TABLE],
    leaf_index: counters[C_LEAF_INDEX],
    interior_index: counters[C_INTERIOR_INDEX],
    overflow: counters[C_OVERFLOW],
    freelist: counters[C_FREELIST],
    unreferenced: counters[C_UNREFERENCED],
    table_rows: counters[C_ROWS] - schema_rows,
    index_entries: counters[C_ENTRIES],
    tables,
    indexes,
    problems,
  }
}
