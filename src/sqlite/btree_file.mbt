/// 文件内 B 树页的解析与遍历
///
/// SQLite 的页类型：
///   2  内部索引页   5  内部表页
///   10 叶子索引页   13 叶子表页
/// 表 B 树的 key 是 rowid，索引 B 树的 key 是记录本身。

pub const PAGE_INTERIOR_INDEX : Int = 2
pub const PAGE_INTERIOR_TABLE : Int = 5
pub const PAGE_LEAF_INDEX : Int = 10
pub const PAGE_LEAF_TABLE : Int = 13

fn is_btree_page_type(t : Int) -> Bool {
  match t {
    2 | 5 | 10 | 13 => true
    _ => false
  }
}

pub fn page_type_name(t : Int) -> String {  match t {
    2 => "interior-index"
    5 => "interior-table"
    10 => "leaf-index"
    13 => "leaf-table"
    _ => "unknown"
  }
}

pub struct BtreePage {
  no : Int
  data : Bytes
  /// 页内 b-tree header 起点：页 1 要跳过头 100 字节
  base : Int
  page_type : Int
  ncell : Int
  content_start : Int
  right_child : Int
  usable : Int
}

pub fn BtreePage::parse(pager : Pager, no : Int) -> BtreePage raise DbError {
  let data = pager.page(no)
  let base = if no == 1 { HEADER_SIZE } else { 0 }
  if base + 8 > data.length() {
    raise Truncated("第 \{no} 页放不下页头")
  }
  let t = byte_at(data, base)
  if !is_btree_page_type(t) {
    raise Corrupt("第 \{no} 页页类型非法：\{t}")
  }
  let ncell = be16(data, base + 3)
  let mut content_start = be16(data, base + 5)
  if content_start == 0 {
    content_start = 65536
  }
  let right_child = if t == PAGE_INTERIOR_INDEX || t == PAGE_INTERIOR_TABLE {
    be32(data, base + 8)
  } else {
    0
  }
  {
    no,
    data,
    base,
    page_type: t,
    ncell,
    content_start,
    right_child,
    usable: pager.usable(),
  }
}

pub fn BtreePage::is_leaf(self : BtreePage) -> Bool {
  self.page_type == PAGE_LEAF_TABLE || self.page_type == PAGE_LEAF_INDEX
}

pub fn BtreePage::is_table(self : BtreePage) -> Bool {
  self.page_type == PAGE_LEAF_TABLE || self.page_type == PAGE_INTERIOR_TABLE
}

fn header_bytes(t : Int) -> Int {
  if t == PAGE_INTERIOR_INDEX || t == PAGE_INTERIOR_TABLE {
    12
  } else {
    8
  }
}

/// 第 i 个单元在页内的偏移
pub fn BtreePage::cell_offset(self : BtreePage, i : Int) -> Int raise DbError {
  if i < 0 || i >= self.ncell {
    raise Corrupt("单元下标越界：\{i}/\{self.ncell}")
  }
  let p = self.base + header_bytes(self.page_type) + 2 * i
  let off = be16(self.data, p)
  if off < self.content_start || off >= self.usable {
    // content_start 为 65536 是空页的哨兵值，此时任何偏移都非法
    raise Corrupt("单元偏移非法：\{off}")
  }
  off
}

fn min_int(a : Int, b : Int) -> Int {
  if a < b { a } else { b }
}

/// 计算页内直接存放的 payload 长度（其余部分在溢出页）
fn local_payload_size(usable : Int, payload_len : Int, is_table_leaf : Bool) -> Int {
  let max_local = if is_table_leaf {
    usable - 35
  } else {
    ((usable - 12) * 64) / 255 - 23
  }
  let min_local = ((usable - 12) * 32) / 255 - 23
  if payload_len <= max_local {
    payload_len
  } else {
    let k = min_local + (payload_len - min_local) % (usable - 4)
    if k <= max_local { k } else { min_local }
  }
}

/// 读取一个单元的 payload，自动拼接溢出页链
fn read_payload(
  pager : Pager,
  data : Bytes,
  offset : Int,
  payload_len : Int,
  is_table_leaf : Bool
) -> Bytes raise DbError {
  if payload_len == 0 {
    return Bytes::new(0)
  }
  let usable = pager.usable()
  let local_len = local_payload_size(usable, payload_len, is_table_leaf)
  if offset + local_len > data.length() {
    raise Corrupt("payload 越过页边界")
  }
  if local_len == payload_len {
    return data[offset:offset + local_len].to_owned()
  }
  let out : Array[Byte] = []
  for i = 0; i < local_len; i = i + 1 {
    out.push(data[offset + i])
  }
  let mut next = be32(data, offset + local_len)
  let mut steps = 0
  while next != 0 && out.length() < payload_len {
    steps = steps + 1
    if steps > 100000 {
      raise Corrupt("溢出页链成环")
    }
    let ov = pager.page(next)
    let remain = payload_len - out.length()
    let take = min_int(usable - 4, remain)
    for i = 0; i < take; i = i + 1 {
      out.push(ov[4 + i])
    }
    next = be32(ov, 0)
  }
  if out.length() != payload_len {
    raise Truncated("溢出页链长度不足：期望 \{payload_len}，实得 \{out.length()}")
  }
  Bytes::from_array(out)
}

/// 表叶子页单元：varint(payload 长度) + varint(rowid) + payload
pub fn table_leaf_cell(
  pager : Pager,
  page : BtreePage,
  i : Int
) -> (Int64, Bytes) raise DbError {
  let off = page.cell_offset(i)
  let (plen, n1) = read_varint(page.data, off)
  let (rowid, n2) = read_varint(page.data, off + n1)
  let payload = read_payload(pager, page.data, off + n1 + n2, plen.to_int(), true)
  (rowid, payload)
}

/// 表内部页单元：4 字节左子页 + varint(rowid)
pub fn table_interior_cell(
  _pager : Pager,
  page : BtreePage,
  i : Int
) -> (Int, Int64) raise DbError {
  let off = page.cell_offset(i)
  let child = be32(page.data, off)
  let (rowid, _) = read_varint(page.data, off + 4)
  (child, rowid)
}

/// 索引叶子页单元：varint(payload 长度) + payload
pub fn index_leaf_cell(
  pager : Pager,
  page : BtreePage,
  i : Int
) -> Bytes raise DbError {
  let off = page.cell_offset(i)
  let (plen, n1) = read_varint(page.data, off)
  read_payload(pager, page.data, off + n1, plen.to_int(), false)
}

/// 索引内部页单元：4 字节左子页 + varint(payload 长度) + payload
pub fn index_interior_cell(
  pager : Pager,
  page : BtreePage,
  i : Int
) -> (Int, Bytes) raise DbError {
  let off = page.cell_offset(i)
  let child = be32(page.data, off)
  let (plen, n1) = read_varint(page.data, off + 4)
  let payload = read_payload(pager, page.data, off + 4 + n1, plen.to_int(), false)
  (child, payload)
}

/// 一行：rowid + 未解码的 record
pub struct TableRow {
  rowid : Int64
  payload : Bytes
}

fn collect_table_rows(
  pager : Pager,
  page_no : Int,
  out : Array[TableRow],
  depth : Int
) -> Unit raise DbError {
  if depth > 64 {
    raise Corrupt("B 树深度异常，可能存在环")
  }
  let page = BtreePage::parse(pager, page_no)
  match page.page_type {
    PAGE_LEAF_TABLE => {
      for i = 0; i < page.ncell; i = i + 1 {
        let (rowid, payload) = table_leaf_cell(pager, page, i)
        out.push({ rowid, payload })
      }
    }
    PAGE_INTERIOR_TABLE => {
      for i = 0; i < page.ncell; i = i + 1 {
        let (child, _) = table_interior_cell(pager, page, i)
        collect_table_rows(pager, child, out, depth + 1)
      }
      collect_table_rows(pager, page.right_child, out, depth + 1)
    }
    _ => raise Corrupt("表根页 \{page_no} 不是表 B 树")
  }
}

/// 按 rowid 升序扫描整棵表 B 树
pub fn scan_table(pager : Pager, root : Int) -> Array[TableRow] raise DbError {
  let out : Array[TableRow] = []
  collect_table_rows(pager, root, out, 0)
  out
}

pub struct IndexRow {
  payload : Bytes
}

fn collect_index_rows(
  pager : Pager,
  page_no : Int,
  out : Array[IndexRow],
  depth : Int
) -> Unit raise DbError {
  if depth > 64 {
    raise Corrupt("B 树深度异常，可能存在环")
  }
  let page = BtreePage::parse(pager, page_no)
  match page.page_type {
    PAGE_LEAF_INDEX => {
      for i = 0; i < page.ncell; i = i + 1 {
        out.push({ payload: index_leaf_cell(pager, page, i) })
      }
    }
    PAGE_INTERIOR_INDEX => {
      for i = 0; i < page.ncell; i = i + 1 {
        let (child, _) = index_interior_cell(pager, page, i)
        collect_index_rows(pager, child, out, depth + 1)
      }
      collect_index_rows(pager, page.right_child, out, depth + 1)
    }
    _ => raise Corrupt("索引根页 \{page_no} 不是索引 B 树")
  }
}

/// 扫描整棵索引 B 树
pub fn scan_index(pager : Pager, root : Int) -> Array[IndexRow] raise DbError {
  let out : Array[IndexRow] = []
  collect_index_rows(pager, root, out, 0)
  out
}
