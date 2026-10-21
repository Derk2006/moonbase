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
  put_be16(buf, 16, page_size)
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

/// 一张表：表名、CREATE TABLE 语句（用于 sqlite_master.sql）、行
pub struct TableSpec {
  name : String
  sql : String
  rows : Array[RowSpec]
}

fn find_alias(def : TableDef) -> Int {
  for i = 0; i < def.columns.length(); i = i + 1 {
    if def.columns[i].is_rowid_alias {
      return i
    }
  }
  -1
}

fn insertion_sort(arr : Array[(Int64, Array[Value])]) -> Unit {
  for i = 1; i < arr.length(); i = i + 1 {
    let key = arr[i]
    let mut j = i - 1
    while j >= 0 && arr[j].0 > key.0 {
      arr[j + 1] = arr[j]
      j = j - 1
    }
    arr[j + 1] = key
  }
}

/// 从 schema + 数据生成合法的 SQLite `.db` 文件（Bytes），可被官方 sqlite3 打开
pub fn make_db(tables : Array[TableSpec]) -> Bytes raise DbError {
  let page_size = 4096
  let reserved = 0
  let usable = page_size - reserved

  // Pass 1：为每张表构造 record、打包叶子页、收集溢出待填
  let table_packed : Array[(Array[Array[Byte]], Array[Int64])] = []
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
    insertion_sort(rowbuf)
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
  }

  // Pass 2：分配页号、构建内部页与 sqlite_master 行
  let mut pageno = 2
  let table_pages : Array[Array[Byte]] = []
  for i = 0; i < tables.length(); i = i + 1 {
    let t = tables[i]
    let (leaves, leaf_max) = table_packed[i]
    if leaves.length() == 0 {
      let empty_cells : Array[(Int64, Array[Byte], Array[Byte]?)] = []
      let (ebuf, _) = build_leaf_table_page(page_size, 0, empty_cells)
      table_pages.push(ebuf)
      master_rows.push(("table", t.name, t.name, pageno, t.sql))
      pageno = pageno + 1
    } else if leaves.length() == 1 {
      table_pages.push(leaves[0])
      master_rows.push(("table", t.name, t.name, pageno, t.sql))
      pageno = pageno + 1
    } else {
      let root = pageno
      let child_start = pageno + 1
      let cellcount = leaves.length() - 1
      let children : Array[(Int, Int64)] = []
      for j = 0; j < cellcount; j = j + 1 {
        children.push((child_start + j, leaf_max[j]))
      }
      let right = child_start + (leaves.length() - 1)
      let interior = build_interior_table_page(page_size, children, right)
      table_pages.push(interior)
      for j = 0; j < leaves.length(); j = j + 1 {
        table_pages.push(leaves[j])
      }
      master_rows.push(("table", t.name, t.name, root, t.sql))
      pageno = pageno + 1 + leaves.length()
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

  // Pass 3：分配溢出页
  let overflow_pages : Array[Array[Byte]] = []
  for p in all_pending {
    let (buf, ptr_off, payload) = p
    let ov_no = pageno
    put_be32(buf, ptr_off, ov_no)
    let mut off = 0
    let remain = payload
    while off < remain.length() {
      let last = off + (usable - 4) >= remain.length()
      let chunk = min2(usable - 4, remain.length() - off)
      let next_no = if last { 0 } else { pageno + 1 }
      let ovpage : Array[Byte] = Array::make(page_size, bb(0))
      put_be32(ovpage, 0, next_no)
      for k = 0; k < chunk; k = k + 1 {
        ovpage[4 + k] = remain[off + k]
      }
      overflow_pages.push(ovpage)
      pageno = pageno + 1
      off = off + chunk
    }
  }

  // Pass 4：组装文件并写入头
  let total_pages = pageno - 1
  let total_bytes = total_pages * page_size
  let out : Array[Byte] = Array::make(total_bytes, bb(0))
  // 页 1
  for k = 0; k < page_size; k = k + 1 {
    out[k] = master_buf[k]
  }
  // 表页 2..
  let mut off = page_size
  for pg in table_pages {
    for k = 0; k < page_size; k = k + 1 {
      out[off + k] = pg[k]
    }
    off = off + page_size
  }
  // 溢出页
  for pg in overflow_pages {
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
    },
  ]
  make_db(tables)
}
