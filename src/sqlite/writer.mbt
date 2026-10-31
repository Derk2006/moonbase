/// 纯 MoonBit 的 SQLite 文件格式「写入器」
///
/// 与 read-only 的解析层互补：本模块可以从 schema + 数据，**生成可被官方
/// `sqlite3` 重新打开的合法 `.db` 文件**（零 FFI，纯字节级构造）。
/// 这是与现有生态（prowk 只读、sqlite3.mbt 仅 FFI 绑定）互不重叠的头部贡献。
///
/// 生成的文件满足 SQLite Database File Format v3：
///   - 100 字节数据库头
///   - sqlite_master 表 B 树（根固定为页 1）
///   - 每张用户表一棵表 B 树（叶子表页；数据多时自动升级为内部表页 + 多叶子）
///   - 超长记录自动写入溢出页链

// ---- 小工具 ----

fn bb(n : Int) -> Byte {
  n.to_byte()
}

fn put_be16(buf : Array[Byte], off : Int, v : Int) -> Unit {
  buf[off] = ((v >> 8) & 0xFF).to_byte()
  buf[off + 1] = (v & 0xFF).to_byte()
}

fn put_be32(buf : Array[Byte], off : Int, v : Int) -> Unit {
  buf[off] = ((v >> 24) & 0xFF).to_byte()
  buf[off + 1] = ((v >> 16) & 0xFF).to_byte()
  buf[off + 2] = ((v >> 8) & 0xFF).to_byte()
  buf[off + 3] = (v & 0xFF).to_byte()
}

fn push_be32(arr : Array[Byte], v : Int) -> Unit {
  arr.push(((v >> 24) & 0xFF).to_byte())
  arr.push(((v >> 16) & 0xFF).to_byte())
  arr.push(((v >> 8) & 0xFF).to_byte())
  arr.push((v & 0xFF).to_byte())
}

fn min2(a : Int, b : Int) -> Int {
  if a < b { a } else { b }
}

// ---- IEEE754 双精度 -> 64 位位模式 ----

fn double_to_bits(d : Double) -> UInt64 {
  if d != d {
    return 0x7FF8000000000000UL
  }
  let neg = d < 0.0
  let mut x = if neg { -d } else { d }
  if x > 1.7976931348623157e308 {
    return if neg { 0xFFF0000000000000UL } else { 0x7FF0000000000000UL }
  }
  if x == 0.0 {
    return if neg { 0x8000000000000000UL } else { 0UL }
  }
  // 归一化到 [1, 2)
  let mut e = 0
  while x >= 2.0 {
    x = x / 2.0
    e = e + 1
  }
  while x < 1.0 {
    x = x * 2.0
    e = e - 1
  }
  // 提取 52 位尾数
  let mut m = x - 1.0
  let mut bits = Int64::from_int(0)
  let mut i = 0
  while i < 52 {
    m = m * 2.0
    if m >= 1.0 {
      bits = (bits << 1) | Int64::from_int(1)
      m = m - 1.0
    } else {
      bits = bits << 1
    }
    i = i + 1
  }
  // 舍入到最近偶数
  if m > 0.5 {
    bits = bits + Int64::from_int(1)
  } else if m == 0.5 {
    if (bits & Int64::from_int(1)) == Int64::from_int(1) {
      bits = bits + Int64::from_int(1)
    }
  }
  // 舍入进位处理
  if bits >= (Int64::from_int(1) << 52) {
    bits = bits >> 1
    e = e + 1
  }
  let biased = e + 1023
  if biased >= 2047 {
    return if neg { 0xFFF0000000000000UL } else { 0x7FF0000000000000UL }
  }
  if biased <= 0 {
    // 非规约数：尾数右移
    let shift = 1 - biased
    bits = bits >> shift
    let sign_bit = if neg { Int64::from_int(1) << 63 } else { Int64::from_int(0) }
    return (sign_bit | (bits & 0x0FFFFFFFFFFFFF)).reinterpret_as_uint64()
  }
  let sign_bit = if neg { Int64::from_int(1) << 63 } else { Int64::from_int(0) }
  let exp_bits = Int64::from_int(biased) << 52
  let mant = bits & 0x0FFFFFFFFFFFFF
  (sign_bit | exp_bits | mant).reinterpret_as_uint64()
}

fn u64_to_be8(v : UInt64) -> Array[Byte] {
  let out : Array[Byte] = []
  for k = 0; k < 8; k = k + 1 {
    let shift = 8 * (7 - k)
    out.push(((v >> shift) & 0xFFUL).to_int().to_byte())
  }
  out
}

// ---- 记录（record）编码 ----

fn int_width(i : Int64) -> (Int, Int) {
  if i >= Int64::from_int(-128) && i <= Int64::from_int(127) {
    (1, 1)
  } else if i >= Int64::from_int(-32768) && i <= Int64::from_int(32767) {
    (2, 2)
  } else if i >= Int64::from_int(-8388608) && i <= Int64::from_int(8388607) {
    (3, 3)
  } else if i >= Int64::from_int(-2147483648) && i <= Int64::from_int(2147483647) {
    (4, 4)
  } else if i >= (Int64::from_int(-1) << 47) && i <= ((Int64::from_int(1) << 47) - Int64::from_int(1)) {
    (6, 5)
  } else {
    (8, 6)
  }
}

fn int_bytes(i : Int64, w : Int) -> Array[Byte] {
  let out : Array[Byte] = []
  for k = 0; k < w; k = k + 1 {
    let shift = 8 * (w - 1 - k)
    let byte_val = ((i >> shift) & Int64::from_int(0xFF)).to_int()
    out.push(byte_val.to_byte())
  }
  out
}

fn value_serial_and_body(v : Value) -> (Int, Array[Byte]) {
  match v {
    VNull => (0, [])
    VInt(i) => {
      if i == Int64::from_int(0) {
        (8, [])
      } else if i == Int64::from_int(1) {
        (9, [])
      } else {
        let (w, st) = int_width(i)
        (st, int_bytes(i, w))
      }
    }
    VReal(d) => (7, u64_to_be8(double_to_bits(d)))
    VText(s) => {
      let b = @utf8.encode(s).to_array()
      (13 + 2 * b.length(), b)
    }
    VBlob(b) => {
      let arr = b.to_array()
      (12 + 2 * arr.length(), arr)
    }
  }
}

/// 编码一条 record（header + body）
fn encode_record(values : Array[Value]) -> Array[Byte] {
  let serials : Array[Int] = []
  let body : Array[Byte] = []
  for v in values {
    let (st, b) = value_serial_and_body(v)
    serials.push(st)
    for x in b {
      body.push(x)
    }
  }
  let serial_bytes : Array[Byte] = []
  for st in serials {
    for x in encode_varint(Int64::from_int(st)) {
      serial_bytes.push(x)
    }
  }
  let n = serial_bytes.length()
  // 计算头部长度自身占用的 varint 字节数（自举）
  let mut lead_len = 1
  let mut lead_val = n + 1
  while lead_len < 9 {
    let cap = (1 << (7 * lead_len)) - 1
    if lead_val <= cap {
      break
    }
    lead_len = lead_len + 1
    lead_val = n + lead_len
  }
  let out : Array[Byte] = []
  for x in encode_varint(Int64::from_int(lead_val)) {
    out.push(x)
  }
  for x in serial_bytes {
    out.push(x)
  }
  for x in body {
    out.push(x)
  }
  out
}

// ---- 页内 payload 计算与叶子单元 ----

fn local_length(p : Int, usable : Int) -> Int {
  let max_local = usable - 35
  let min_local = ((usable - 12) * 32) / 255 - 23
  if p <= max_local {
    p
  } else {
    let k = min_local + (p - min_local) % (usable - 4)
    if k <= max_local { k } else { min_local }
  }
}

/// 构造一个表叶子单元：返回 (页内字节, 溢出剩余字节?)
fn build_leaf_cell(
  rowid : Int64,
  record : Array[Byte],
  usable : Int
) -> (Array[Byte], Array[Byte]?) {
  let plen = record.length()
  let max_local = usable - 35
  let onpage : Array[Byte] = []
  for x in encode_varint(Int64::from_int(plen)) {
    onpage.push(x)
  }
  for x in encode_varint(rowid) {
    onpage.push(x)
  }
  if plen <= max_local {
    for x in record {
      onpage.push(x)
    }
    (onpage, None)
  } else {
    let loc = local_length(plen, usable)
    for k = 0; k < loc; k = k + 1 {
      onpage.push(record[k])
    }
    onpage.push(bb(0))
    onpage.push(bb(0))
    onpage.push(bb(0))
    onpage.push(bb(0))
    let rest : Array[Byte] = []
    for k = loc; k < plen; k = k + 1 {
      rest.push(record[k])
    }
    (onpage, Some(rest))
  }
}

// ---- 页构建 ----

/// 构建一张表叶子页；返回 (页字节, 待填溢出指针列表)
fn build_leaf_table_page(
  page_size : Int,
  header_skip : Int,
  cells : Array[(Int64, Array[Byte], Array[Byte]?)]
) -> (Array[Byte], Array[(Array[Byte], Int, Array[Byte])]) {
  let buf : Array[Byte] = Array::make(page_size, bb(0))
  buf[header_skip] = bb(13)
  let ptr_array_start = header_skip + 8
  let mut content_start = page_size
  let pending : Array[(Array[Byte], Int, Array[Byte])] = []
  for i = 0; i < cells.length(); i = i + 1 {
    let (_, onpage, ov) = cells[i]
    let clen = onpage.length()
    content_start = content_start - clen
    for k = 0; k < clen; k = k + 1 {
      buf[content_start + k] = onpage[k]
    }
    put_be16(buf, ptr_array_start + 2 * i, content_start)
    match ov {
      Some(rest) => {
        let ptr_off = content_start + clen - 4
        pending.push((buf, ptr_off, rest))
      }
      None => ()
    }
  }
  put_be16(buf, header_skip + 3, cells.length())
  put_be16(buf, header_skip + 1, 0)
  put_be16(buf, header_skip + 5, content_start)
  buf[header_skip + 7] = bb(0)
  (buf, pending)
}

/// 构建一张内部表页（right = 最右子页；children 为左侧子页 + 该子树最大 rowid）
fn build_interior_table_page(
  page_size : Int,
  children : Array[(Int, Int64)],
  right : Int
) -> Array[Byte] {
  let buf : Array[Byte] = Array::make(page_size, bb(0))
  buf[0] = bb(5)
  let n = children.length()
  put_be16(buf, 3, n)
  put_be16(buf, 1, 0)
  put_be32(buf, 8, right)
  let ptr_array_start = 12
  let mut content_start = page_size
  for i = 0; i < n; i = i + 1 {
    let (child, key) = children[i]
    let cell : Array[Byte] = []
    push_be32(cell, child)
    for x in encode_varint(key) {
      cell.push(x)
    }
    let clen = cell.length()
    content_start = content_start - clen
    for k = 0; k < clen; k = k + 1 {
      buf[content_start + k] = cell[k]
    }
    put_be16(buf, ptr_array_start + 2 * i, content_start)
  }
  put_be16(buf, 5, content_start)
  buf[7] = bb(0)
  buf
}

// ---- 索引 B 树（页类型 10 / 2）----

/// 索引页的本地 payload 公式与表页不同（见官方文档 2.4 节）：
///   max_local = (usable-12)*64/255 - 23，min_local = (usable-12)*32/255 - 23
fn local_length_index(p : Int, usable : Int) -> Int {
  let max_local = ((usable - 12) * 64) / 255 - 23
  let min_local = ((usable - 12) * 32) / 255 - 23
  if p <= max_local {
    p
  } else {
    let k = min_local + (p - min_local) % (usable - 4)
    if k <= max_local { k } else { min_local }
  }
}

/// 索引页可用的页内 payload 上限
fn index_max_local(usable : Int) -> Int {
  ((usable - 12) * 64) / 255 - 23
}

/// 索引叶子单元：varint(payload 长度) + 本地 payload（+ 4 字节溢出页指针）
fn build_index_leaf_cell(
  record : Array[Byte],
  usable : Int
) -> (Array[Byte], Array[Byte]?) {
  let plen = record.length()
  let onpage : Array[Byte] = []
  for x in encode_varint(Int64::from_int(plen)) {
    onpage.push(x)
  }
  if plen <= index_max_local(usable) {
    for x in record {
      onpage.push(x)
    }
    (onpage, None)
  } else {
    let loc = local_length_index(plen, usable)
    for k = 0; k < loc; k = k + 1 {
      onpage.push(record[k])
    }
    push_be32(onpage, 0)
    let rest : Array[Byte] = []
    for k = loc; k < plen; k = k + 1 {
      rest.push(record[k])
    }
    (onpage, Some(rest))
  }
}

/// 构建一张索引叶子页（页类型 10）
fn build_leaf_index_page(
  page_size : Int,
  cells : Array[(Array[Byte], Array[Byte]?)]
) -> (Array[Byte], Array[(Array[Byte], Int, Array[Byte])]) {
  let buf : Array[Byte] = Array::make(page_size, bb(0))
  buf[0] = bb(10)
  let ptr_array_start = 8
  let mut content_start = page_size
  let pending : Array[(Array[Byte], Int, Array[Byte])] = []
  for i = 0; i < cells.length(); i = i + 1 {
    let (onpage, ov) = cells[i]
    let clen = onpage.length()
    content_start = content_start - clen
    for k = 0; k < clen; k = k + 1 {
      buf[content_start + k] = onpage[k]
    }
    put_be16(buf, ptr_array_start + 2 * i, content_start)
    match ov {
      Some(rest) => pending.push((buf, content_start + clen - 4, rest))
      None => ()
    }
  }
  put_be16(buf, 3, cells.length())
  put_be16(buf, 1, 0)
  put_be16(buf, 5, content_start)
  buf[7] = bb(0)
  (buf, pending)
}

/// 构建一张内部索引页（页类型 2）
///
/// 每个单元的 key 是**左子树最大键的副本**（索引 B 树的内部键与叶子键重复，
/// 与表 B 树把分隔键移出叶子的做法不同）。
fn build_interior_index_page(
  page_size : Int,
  children : Array[(Int, Array[Byte])],
  right : Int
) -> (Array[Byte], Array[(Array[Byte], Int, Array[Byte])]) {
  let buf : Array[Byte] = Array::make(page_size, bb(0))
  buf[0] = bb(2)
  let n = children.length()
  put_be16(buf, 3, n)
  put_be16(buf, 1, 0)
  put_be32(buf, 8, right)
  let ptr_array_start = 12
  let mut content_start = page_size
  let pending : Array[(Array[Byte], Int, Array[Byte])] = []
  for i = 0; i < n; i = i + 1 {
    let (child, record) = children[i]
    let plen = record.length()
    let cell : Array[Byte] = []
    push_be32(cell, child)
    for x in encode_varint(Int64::from_int(plen)) {
      cell.push(x)
    }
    let mut rest : Array[Byte]? = None
    if plen <= index_max_local(page_size) {
      for x in record {
        cell.push(x)
      }
    } else {
      let loc = local_length_index(plen, page_size)
      for k = 0; k < loc; k = k + 1 {
        cell.push(record[k])
      }
      push_be32(cell, 0)
      let r : Array[Byte] = []
      for k = loc; k < plen; k = k + 1 {
        r.push(record[k])
      }
      rest = Some(r)
    }
    let clen = cell.length()
    content_start = content_start - clen
    for k = 0; k < clen; k = k + 1 {
      buf[content_start + k] = cell[k]
    }
    put_be16(buf, ptr_array_start + 2 * i, content_start)
    match rest {
      Some(r) => pending.push((buf, content_start + clen - 4, r))
      None => ()
    }
  }
  put_be16(buf, 5, content_start)
  buf[7] = bb(0)
  (buf, pending)
}

/// 把索引条目贪心打包成若干叶子页的分组。
///
/// 返回 (每片要写入的条目, 每片上移到父页的分隔键, 每片子树的最大键)。
/// `seps` 的末项是空数组（末片没有上移的键，其最大键仍在叶子中）；
/// `group_max` 则每片都有值，供更高层继续上提时使用。
///
/// 索引 B 树的每个键在整棵树中只出现一次：分片时把每片（最后一片除外）的最大键
/// **移出**叶子、放进内部页，否则 sqlite3 的 `PRAGMA integrity_check` 会报
/// "wrong # of entries in index"。
fn pack_index_leaves(
  page_size : Int,
  usable : Int,
  records : Array[Array[Byte]]
) -> (Array[Array[Array[Byte]]], Array[Array[Byte]], Array[Array[Byte]]) {
  let groups : Array[Array[Array[Byte]]] = []
  let seps : Array[Array[Byte]] = []
  let group_max : Array[Array[Byte]] = []
  if records.length() == 0 {
    return (groups, seps, group_max)
  }
  let ptr_array_start = 8
  let mut cur : Array[Array[Byte]] = []
  let mut cur_start = page_size
  for rec in records {
    let (onpage, _) = build_index_leaf_cell(rec, usable)
    let clen = onpage.length()
    let needed_top = ptr_array_start + 2 * (cur.length() + 1)
    if cur.length() > 0 && (cur_start - clen) < needed_top {
      groups.push(cur)
      cur = []
      cur_start = page_size
    }
    cur_start = cur_start - clen
    cur.push(rec)
  }
  if cur.length() > 0 {
    groups.push(cur)
  }
  let out : Array[Array[Array[Byte]]] = []
  for j = 0; j < groups.length(); j = j + 1 {
    let g = groups[j]
    group_max.push(g[g.length() - 1])
    if j < groups.length() - 1 {
      let sep = g[g.length() - 1]
      let cells : Array[Array[Byte]] = []
      for k = 0; k < g.length() - 1; k = k + 1 {
        cells.push(g[k])
      }
      out.push(cells)
      seps.push(sep)
    } else {
      out.push(g)
      seps.push([])
    }
  }
  (out, seps, group_max)
}

/// 把单元贪心打包成若干叶子页（页内按 rowid 升序）
fn pack_leaves(
  page_size : Int,
  cells : Array[(Int64, Array[Byte], Array[Byte]?)]
) -> (Array[Array[Byte]], Array[Int64], Array[(Array[Byte], Int, Array[Byte])]) {
  let leaves : Array[Array[Byte]] = []
  let leaf_max : Array[Int64] = []
  let all_pending : Array[(Array[Byte], Int, Array[Byte])] = []
  if cells.length() == 0 {
    return (leaves, leaf_max, all_pending)
  }
  let ptr_array_start = 8
  let mut cur : Array[(Int64, Array[Byte], Array[Byte]?)] = []
  let mut cur_max = Int64::from_int(0)
  let mut cur_start = page_size
  for i = 0; i < cells.length(); i = i + 1 {
    let (rid, onpage, ov) = cells[i]
    let clen = onpage.length()
    let needed_top = ptr_array_start + 2 * (cur.length() + 1)
    if cur.length() > 0 && (cur_start - clen) < needed_top {
      let (buf, pending) = build_leaf_table_page(page_size, 0, cur)
      leaves.push(buf)
      leaf_max.push(cur_max)
      for p in pending {
        all_pending.push(p)
      }
      cur = []
      cur_max = Int64::from_int(0)
      cur_start = page_size
    }
    if rid > cur_max {
      cur_max = rid
    }
    cur_start = cur_start - clen
    cur.push((rid, onpage, ov))
  }
  if cur.length() > 0 {
    let (buf, pending) = build_leaf_table_page(page_size, 0, cur)
    leaves.push(buf)
    leaf_max.push(cur_max)
    for p in pending {
      all_pending.push(p)
    }
  }
  (leaves, leaf_max, all_pending)
}

// ---- 数据库头 ----

fn write_db_header(buf : Array[Byte], page_size : Int, page_count : Int) -> Unit {
  let magic = [
    83, 81, 76, 105, 116, 101, 32, 102, 111, 114, 109, 97, 116, 32, 51, 0,
  ]
  for i = 0; i < 16; i = i + 1 {
    buf[i] = magic[i].to_byte()
  }
  // 65536 在 2 字节字段里存 1（官方文档 1.3 节的特例）
  put_be16(buf, 16, if page_size == 65536 { 1 } else { page_size })
  buf[18] = bb(1)
  buf[19] = bb(1)
  buf[20] = bb(0)
  buf[21] = bb(64)
  buf[22] = bb(32)
  buf[23] = bb(32)
  put_be32(buf, 24, page_count)
  put_be32(buf, 28, page_count)
  put_be32(buf, 32, 0)
  put_be32(buf, 36, 0)
  put_be32(buf, 40, 1)
  put_be32(buf, 44, 4)
  put_be32(buf, 48, 0)
  put_be32(buf, 52, 0)
  put_be32(buf, 56, 1)
  put_be32(buf, 60, 0)
  put_be32(buf, 64, 0)
  put_be32(buf, 68, 0)
  put_be32(buf, 92, page_count)
  put_be32(buf, 96, 3045000)
}

// ---- 顶层 API ----

/// 一行输入：可选的显式 rowid + 各列值
pub struct RowSpec {
  rowid : Int64?
  values : Array[Value]
}

/// 一只索引：索引名、所属表、CREATE INDEX 语句、参与索引的列名（按键顺序）
pub struct IndexSpec {
  name : String
  table : String
  sql : String
  columns : Array[String]
}

/// 一张表：表名、CREATE TABLE 语句（用于 sqlite_master.sql）、行、索引
pub struct TableSpec {
  name : String
  sql : String
  rows : Array[RowSpec]
  indexes : Array[IndexSpec]
}

/// 构造一行输入。
///
/// 结构体字段对其他包不可见，外部使用者必须通过本构造器创建 `RowSpec`。
/// `rowid` 传 `None` 表示由写入器自动分配自增 rowid。
pub fn RowSpec::new(rowid : Int64?, values : Array[Value]) -> RowSpec {
  { rowid, values }
}

/// 构造一只索引。`columns` 是按索引键顺序排列的列名。
pub fn IndexSpec::new(
  name : String,
  table : String,
  sql : String,
  columns : Array[String]
) -> IndexSpec {
  { name, table, sql, columns }
}

/// 构造一张表的输入（不含索引）。
///
/// `sql` 必须是与该表列定义一致的 `CREATE TABLE` 语句，它会原样写入
/// `sqlite_master.sql`，因此读回时列名 / 类型 / 主键信息都能还原。
pub fn TableSpec::new(
  name : String,
  sql : String,
  rows : Array[RowSpec]
) -> TableSpec {
  { name, sql, rows, indexes: [] }
}

/// 构造一张带索引的表输入；索引会生成真实的索引 B 树（页类型 10 / 2）。
pub fn TableSpec::with_indexes(
  name : String,
  sql : String,
  rows : Array[RowSpec],
  indexes : Array[IndexSpec]
) -> TableSpec {
  { name, sql, rows, indexes }
}

fn find_alias(def : TableDef) -> Int {
  for i = 0; i < def.columns.length(); i = i + 1 {
    if def.columns[i].is_rowid_alias {
      return i
    }
  }
  -1
}

/// 自底向上归并排序：写入十万级行数时仍保持 O(n log n)。
///
/// （早期版本用插入排序，几千行就会退化成平方级；归并同时保证稳定，
/// 相同 rowid 的输入顺序不会被重排。）
fn sort_rows_by_rowid(arr : Array[(Int64, Array[Value])]) -> Unit {
  let n = arr.length()
  if n < 2 {
    return
  }
  let tmp : Array[(Int64, Array[Value])] = Array::make(n, arr[0])
  let mut width = 1
  while width < n {
    let mut lo = 0
    while lo < n {
      let mid = min2(lo + width, n)
      let hi = min2(lo + 2 * width, n)
      let mut a = lo
      let mut b = mid
      let mut k = lo
      while a < mid && b < hi {
        if arr[b].0 < arr[a].0 {
          tmp[k] = arr[b]
          b = b + 1
        } else {
          tmp[k] = arr[a]
          a = a + 1
        }
        k = k + 1
      }
      while a < mid {
        tmp[k] = arr[a]
        a = a + 1
        k = k + 1
      }
      while b < hi {
        tmp[k] = arr[b]
        b = b + 1
        k = k + 1
      }
      lo = lo + 2 * width
    }
    for t = 0; t < n; t = t + 1 {
      arr[t] = tmp[t]
    }
    width = width * 2
  }
}

/// 把一行投影成索引键向量：索引列… + rowid（rowid 保证键唯一）
fn index_entry_values(
  rowid : Int64,
  vals : Array[Value],
  cols : Array[Int],
  alias_idx : Int
) -> Array[Value] {
  let kv : Array[Value] = []
  for c in cols {
    let v = if c == alias_idx {
      // INTEGER PRIMARY KEY 列在表记录里存 NULL，索引里必须写真实 rowid
      VInt(rowid)
    } else if c >= 0 && c < vals.length() {
      vals[c]
    } else {
      VNull
    }
    kv.push(v)
  }
  kv.push(VInt(rowid))
  kv
}

/// 按 SQLite 排序语义（NULL < 数值 < 文本 < BLOB）比较两个键向量
fn cmp_key_vec(a : Array[Value], b : Array[Value]) -> Int {
  let n = if a.length() < b.length() { a.length() } else { b.length() }
  for i = 0; i < n; i = i + 1 {
    let c = a[i].compare(b[i])
    if c != 0 {
      return c
    }
  }
  0
}

/// 按键向量的 SQLite 排序语义归并排序（稳定，O(n log n)）
fn sort_key_vecs(entries : Array[Array[Value]]) -> Unit {
  let n = entries.length()
  if n < 2 {
    return
  }
  let tmp : Array[Array[Value]] = Array::make(n, entries[0])
  let mut width = 1
  while width < n {
    let mut lo = 0
    while lo < n {
      let mid = min2(lo + width, n)
      let hi = min2(lo + 2 * width, n)
      let mut a = lo
      let mut b = mid
      let mut k = lo
      while a < mid && b < hi {
        if cmp_key_vec(entries[b], entries[a]) < 0 {
          tmp[k] = entries[b]
          b = b + 1
        } else {
          tmp[k] = entries[a]
          a = a + 1
        }
        k = k + 1
      }
      while a < mid {
        tmp[k] = entries[a]
        a = a + 1
        k = k + 1
      }
      while b < hi {
        tmp[k] = entries[b]
        b = b + 1
        k = k + 1
      }
      lo = lo + 2 * width
    }
    for t = 0; t < n; t = t + 1 {
      entries[t] = tmp[t]
    }
    width = width * 2
  }
}

fn resolve_index_cols(def : TableDef, idx : IndexSpec) -> Array[Int] raise DbError {
  let out : Array[Int] = []
  for want in idx.columns {
    let mut found = -1
    for i = 0; i < def.columns.length(); i = i + 1 {
      if same_name(def.columns[i].name, want) {
        found = i
        break
      }
    }
    if found < 0 {
      raise BadSql("索引 \{idx.name} 引用了不存在的列：\{want}")
    }
    out.push(found)
  }
  out
}

/// 合法的页大小（SQLite 只接受 2 的幂，512 起、65536 止）
fn valid_page_size(n : Int) -> Bool {
  let allowed = [512, 1024, 2048, 4096, 8192, 16384, 32768, 65536]
  for a in allowed {
    if a == n {
      return true
    }
  }
  false
}

/// 从 schema + 数据生成合法的 SQLite `.db` 文件（Bytes），可被官方 sqlite3 打开
pub fn make_db(tables : Array[TableSpec]) -> Bytes raise DbError {
  make_db_with_page_size(tables, 4096)
}

/// 同上，但可指定页大小（512 / 1024 / … / 65536）。
///
/// 页大小会同时影响数据库头、每页可用字节、溢出阈值与 B 树扇出：小页 + 大表
/// 会自然长出多级内部页，因此它也是一条很好的「格式是否真正正确」的探针。
pub fn make_db_with_page_size(
  tables : Array[TableSpec],
  page_size : Int
) -> Bytes raise DbError {
  if !valid_page_size(page_size) {
    raise BadSql("非法页大小：\{page_size}（须为 512..65536 之间的 2 的幂）")
  }
  let usable = page_size

  // Pass 1：为每张表构造 record、打包叶子页、收集溢出待填
  let table_packed : Array[(Array[Array[Byte]], Array[Int64])] = []
  let table_rows : Array[Array[(Int64, Array[Value])]] = []
  let table_defs : Array[TableDef] = []
  let all_pending : Array[(Array[Byte], Int, Array[Byte])] = []
  let master_rows : Array[(String, String, String, Int, String)] = []

  for t in tables {
    let def = parse_create_table(t.sql, 0) catch {
      _ => raise BadSql("无法解析 CREATE TABLE: " + t.sql)
    }
    let alias_idx = find_alias(def)
    let rowbuf : Array[(Int64, Array[Value])] = []
    let mut auto = Int64::from_int(0)
    for r in t.rows {
      let vals : Array[Value] = Array::make(def.columns.length(), VNull)
      for k = 0; k < r.values.length() && k < vals.length(); k = k + 1 {
        vals[k] = r.values[k]
      }
      let rid : Int64 = if alias_idx >= 0 {
        match vals[alias_idx] {
          VInt(v) => v
          _ => match r.rowid {
            Some(x) => x
            None => {
              auto = auto + Int64::from_int(1)
              auto
            }
          }
        }
      } else {
        match r.rowid {
          Some(x) => x
          None => {
            auto = auto + Int64::from_int(1)
            auto
          }
        }
      }
      if alias_idx >= 0 {
        vals[alias_idx] = VNull
      }
      rowbuf.push((rid, vals))
    }
    sort_rows_by_rowid(rowbuf)
    let cells : Array[(Int64, Array[Byte], Array[Byte]?)] = []
    for j = 0; j < rowbuf.length(); j = j + 1 {
      let (rid, vals) = rowbuf[j]
      let rec = encode_record(vals)
      let (onpage, ov) = build_leaf_cell(rid, rec, usable)
      cells.push((rid, onpage, ov))
    }
    let (leaves, leaf_max, pending) = pack_leaves(page_size, cells)
    for p in pending {
      all_pending.push(p)
    }
    table_packed.push((leaves, leaf_max))
    table_rows.push(rowbuf)
    table_defs.push(def)
  }

  // Pass 2：自底向上构建每张表的 B 树（叶子已建好，这里补齐任意层数的内部页）
  let arena = PageArena::new()
  for i = 0; i < tables.length(); i = i + 1 {
    let t = tables[i]
    let (leaves, leaf_max) = table_packed[i]
    let root = build_table_tree(arena, page_size, leaves, leaf_max)
    master_rows.push(("table", t.name, t.name, root, t.sql))
  }

  // Pass 3：为每只索引构建索引 B 树（键排序 + 叶子页 + 任意层数的内部页）
  for i = 0; i < tables.length(); i = i + 1 {
    let t = tables[i]
    let def = table_defs[i]
    let rows = table_rows[i]
    let alias_idx = find_alias(def)
    for idx in t.indexes {
      let cols = resolve_index_cols(def, idx)
      let keys : Array[Array[Value]] = []
      for r in rows {
        keys.push(index_entry_values(r.0, r.1, cols, alias_idx))
      }
      sort_key_vecs(keys)
      let records : Array[Array[Byte]] = []
      for kv in keys {
        records.push(encode_record(kv))
      }
      let (groups, _seps, group_max) = pack_index_leaves(page_size, usable, records)
      let root = build_index_tree(arena, page_size, usable, groups, group_max, all_pending)
      master_rows.push(("index", idx.name, t.name, root, idx.sql))
    }
  }

  // 构建 sqlite_master 页（页 1，b 树头从第 100 字节起）
  let master_cells : Array[(Int64, Array[Byte], Array[Byte]?)] = []
  let mut mrid = Int64::from_int(1)
  for m in master_rows {
    let (typ, name, tbl, root, sql) = m
    let vals : Array[Value] = [
      VText(typ),
      VText(name),
      VText(tbl),
      VInt(Int64::from_int(root)),
      VText(sql),
    ]
    let rec = encode_record(vals)
    let (onpage, ov) = build_leaf_cell(mrid, rec, usable)
    master_cells.push((mrid, onpage, ov))
    mrid = mrid + Int64::from_int(1)
  }
  let (master_buf, _master_pending) = build_leaf_table_page(page_size, 100, master_cells)

  // Pass 4：分配溢出页（追加在所有 B 树页之后）
  for p in all_pending {
    let (buf, ptr_off, payload) = p
    put_be32(buf, ptr_off, arena.next())
    let mut off = 0
    let remain = payload
    while off < remain.length() {
      let page_no = arena.next()
      let last = off + (usable - 4) >= remain.length()
      let chunk = min2(usable - 4, remain.length() - off)
      let next_no = if last { 0 } else { page_no + 1 }
      let ovpage : Array[Byte] = Array::make(page_size, bb(0))
      put_be32(ovpage, 0, next_no)
      for k = 0; k < chunk; k = k + 1 {
        ovpage[4 + k] = remain[off + k]
      }
      let _ = arena.alloc(ovpage)
      off = off + chunk
    }
  }

  // Pass 5：组装文件并写入头
  let total_pages = arena.pages.length() + 1
  let total_bytes = total_pages * page_size
  let out : Array[Byte] = Array::make(total_bytes, bb(0))
  // 页 1
  for k = 0; k < page_size; k = k + 1 {
    out[k] = master_buf[k]
  }
  // 页 2.. ：表页 / 索引页 / 溢出页（按分配顺序，与页号一一对应）
  let mut off = page_size
  for pg in arena.pages {
    for k = 0; k < page_size; k = k + 1 {
      out[off + k] = pg[k]
    }
    off = off + page_size
  }
  write_db_header(out, page_size, total_pages)
  Bytes::from_array(out)
}

/// 生成一份演示数据库（users 表，含整数 / 文本 / 实数 / BLOB），用于 CLI 与展示
pub fn make_demo_db() -> Bytes raise DbError {
  let tables : Array[TableSpec] = [
    {
      name: "users",
      sql:
        "CREATE TABLE users(id integer primary key, name text, score real, memo blob)",
      rows: [
        {
          rowid: None,
          values: [
            VInt(Int64::from_int(1)),
            VText("Alice"),
            VReal(91.5),
            VBlob(Bytes::from_array([b'\xDE', b'\xAD', b'\xBE', b'\xEF'])),
          ],
        },
        {
          rowid: None,
          values: [VInt(Int64::from_int(2)), VText("Bob"), VReal(88.0), VBlob(Bytes::new(0))],
        },
        {
          rowid: None,
          values: [
            VInt(Int64::from_int(3)),
            VText("陈小明"),
            VReal(77.25),
            VBlob(Bytes::from_array([b'\x01', b'\x02'])),
          ],
        },
      ],
      // 一只二级索引：既演示索引 B 树生成，也让官方 sqlite3 的查询计划能命中索引
      indexes: [
        {
          name: "idx_users_name",
          table: "users",
          sql: "CREATE INDEX idx_users_name ON users(name)",
          columns: ["name"],
        },
      ],
    },
  ]
  make_db(tables)
}
