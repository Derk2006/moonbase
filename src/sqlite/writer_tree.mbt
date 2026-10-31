/// B 树的多层构建
///
/// 旧版写入器只在「一个内部页装得下所有子页」时可用；行数上到十万级后，
/// 内部页本身会溢出，必须把内部页再分层。本模块把「叶子 → 内部页 → 更高层
/// 内部页」的打包抽成通用流程，表 B 树与索引 B 树各一套。
///
/// 两类树的分隔键语义不同（见官方文档 2.2 节）：
///   - 表 B 树（B+ 树语义）：内部键 = 左子树最大 rowid，与该 rowid 在叶子中
///     的存储**重复**，只作路由用，不占条目数。
///   - 索引 B 树（B 树语义）：每个键在整棵树中只出现一次。分片时把边界键
///     **上移**到父页，叶子里不再保留，否则 integrity_check 会报
///     "wrong # of entries in index"。

// ---- 页分配 ----

/// 顺序页分配器：body 页从页 2 起按分配顺序连续编号。
///
/// 页号由「在数组中的下标 + 2」决定，因此分配顺序即页号顺序；B 树的父页
/// 天然分配在子页之后，页号大小与树的层级无关，不必回填。
priv struct PageArena {
  pages : Array[Array[Byte]]
}

fn PageArena::new() -> PageArena {
  { pages: [] }
}

/// 登记一页并返回其页号
fn PageArena::alloc(self : PageArena, page : Array[Byte]) -> Int {
  self.pages.push(page)
  self.pages.length() + 1
}

/// 下一个将要分配的页号
fn PageArena::next(self : PageArena) -> Int {
  self.pages.length() + 2
}

fn varint_size(v : Int64) -> Int {
  if v < (Int64::from_int(1) << 56) {
    let mut x = v
    let mut n = 1
    while x > Int64::from_int(0x7F) {
      x = x >> 7
      n = n + 1
    }
    n
  } else {
    9
  }
}

// ---- 表 B 树 ----

/// 内部表页单元长度：4 字节子页指针 + varint(rowid)
fn table_interior_cell_size(key : Int64) -> Int {
  4 + varint_size(key)
}

/// 把一个层级的子页（页号, 子树最大 rowid）打包成上一层。
///
/// 贪心装填：当前页放不下下一个单元时结算本页——本页最后一个子页退化为
/// 「最右子页指针」，它的键作为本页的最大键上报给更高层。
fn pack_table_level(
  arena : PageArena,
  page_size : Int,
  nodes : Array[(Int, Int64)]
) -> Array[(Int, Int64)] {
  let out : Array[(Int, Int64)] = []
  let mut cur : Array[(Int, Int64)] = []
  let mut content = page_size
  for nd in nodes {
    let clen = table_interior_cell_size(nd.1)
    if cur.length() > 0 && content - clen < 12 + 2 * (cur.length() + 1) {
      flush_table_level(arena, page_size, cur, out)
      cur = []
      content = page_size
    }
    content = content - clen
    cur.push(nd)
  }
  if cur.length() > 0 {
    flush_table_level(arena, page_size, cur, out)
  }
  out
}

fn flush_table_level(
  arena : PageArena,
  page_size : Int,
  cur : Array[(Int, Int64)],
  out : Array[(Int, Int64)]
) -> Unit {
  let n = cur.length()
  if n == 1 {
    // 一个子页独占一层：不建内部页，直接把这个节点上提
    out.push(cur[0])
    return
  }
  let cells : Array[(Int, Int64)] = []
  for i = 0; i < n - 1; i = i + 1 {
    cells.push(cur[i])
  }
  let right = cur[n - 1].0
  let buf = build_interior_table_page(page_size, cells, right)
  let pno = arena.alloc(buf)
  out.push((pno, cur[n - 1].1))
}

/// 为一张表构建完整的表 B 树，返回根页号。
///
/// `leaves` / `leaf_max` 由 `pack_leaves` 产出（叶子页已建好）。
fn build_table_tree(
  arena : PageArena,
  page_size : Int,
  leaves : Array[Array[Byte]],
  leaf_max : Array[Int64]
) -> Int {
  if leaves.length() == 0 {
    let (buf, _) = build_leaf_table_page(page_size, 0, [])
    return arena.alloc(buf)
  }
  let mut nodes : Array[(Int, Int64)] = []
  for j = 0; j < leaves.length(); j = j + 1 {
    nodes.push((arena.alloc(leaves[j]), leaf_max[j]))
  }
  while nodes.length() > 1 {
    nodes = pack_table_level(arena, page_size, nodes)
  }
  nodes[0].0
}

// ---- 索引 B 树 ----

/// 索引内部页单元长度：4 字节子页指针 + varint(长度) + 本地 payload
/// （+ 4 字节溢出指针，若该键放不下）
fn index_interior_cell_size(record : Array[Byte], usable : Int) -> Int {
  let plen = record.length()
  let body = if plen <= index_max_local(usable) {
    plen
  } else {
    local_length_index(plen, usable) + 4
  }
  4 + varint_size(Int64::from_int(plen)) + body
}

fn pack_index_level(
  arena : PageArena,
  page_size : Int,
  usable : Int,
  nodes : Array[(Int, Array[Byte])],
  pending : Array[(Array[Byte], Int, Array[Byte])]
) -> Array[(Int, Array[Byte])] {
  let out : Array[(Int, Array[Byte])] = []
  let mut cur : Array[(Int, Array[Byte])] = []
  let mut content = page_size
  for nd in nodes {
    let clen = index_interior_cell_size(nd.1, usable)
    if cur.length() > 0 && content - clen < 12 + 2 * (cur.length() + 1) {
      flush_index_level(arena, page_size, cur, out, pending)
      cur = []
      content = page_size
    }
    content = content - clen
    cur.push(nd)
  }
  if cur.length() > 0 {
    flush_index_level(arena, page_size, cur, out, pending)
  }
  out
}

fn flush_index_level(
  arena : PageArena,
  page_size : Int,
  cur : Array[(Int, Array[Byte])],
  out : Array[(Int, Array[Byte])],
  pending : Array[(Array[Byte], Int, Array[Byte])]
) -> Unit {
  let n = cur.length()
  if n == 1 {
    out.push(cur[0])
    return
  }
  let cells : Array[(Int, Array[Byte])] = []
  for i = 0; i < n - 1; i = i + 1 {
    cells.push(cur[i])
  }
  let right = cur[n - 1].0
  let (buf, ov) = build_interior_index_page(page_size, cells, right)
  for p in ov {
    pending.push(p)
  }
  let pno = arena.alloc(buf)
  // 最右子页的键不进本页，继续上提
  out.push((pno, cur[n - 1].1))
}

/// 为一只索引构建完整的索引 B 树，返回根页号。
///
/// `groups` 是每片叶子要写入的键记录（边界键已移出），`group_max` 是每片的
/// 最大键（= 已上移的边界键，末片为叶子中的最后一个键）。
fn build_index_tree(
  arena : PageArena,
  page_size : Int,
  usable : Int,
  groups : Array[Array[Array[Byte]]],
  group_max : Array[Array[Byte]],
  pending : Array[(Array[Byte], Int, Array[Byte])]
) -> Int {
  if groups.length() == 0 {
    let (buf, _) = build_leaf_index_page(page_size, [])
    return arena.alloc(buf)
  }
  let mut nodes : Array[(Int, Array[Byte])] = []
  for j = 0; j < groups.length(); j = j + 1 {
    let cells : Array[(Array[Byte], Array[Byte]?)] = []
    for rec in groups[j] {
      cells.push(build_index_leaf_cell(rec, usable))
    }
    let (buf, ov) = build_leaf_index_page(page_size, cells)
    for p in ov {
      pending.push(p)
    }
    nodes.push((arena.alloc(buf), group_max[j]))
  }
  while nodes.length() > 1 {
    nodes = pack_index_level(arena, page_size, usable, nodes, pending)
  }
  nodes[0].0
}
