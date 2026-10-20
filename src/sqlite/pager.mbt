/// 数据库文件头（偏移 0~99）与页访问
///
/// 参考 SQLite 官方文档 «Database File Format» 1.3 节。

pub const HEADER_SIZE : Int = 100

pub struct DbHeader {
  page_size : Int
  /// 18: 写格式版本，1=rollback journal，2=WAL
  write_version : Int
  /// 19: 读格式版本
  read_version : Int
  /// 20: 每页尾部保留字节数
  reserved : Int
  /// 24: 文件变更计数器
  file_change_counter : Int
  /// 28: 数据库页数
  page_count : Int
  /// 32: 空闲页链表头
  freelist_trunk : Int
  /// 36: 空闲页数量
  freelist_count : Int
  /// 40: schema cookie，DDL 变更时自增
  schema_cookie : Int
  /// 44: schema 格式号（1~4）
  schema_format : Int
  /// 52: 最大根页（auto-vacuum 使用）
  largest_root : Int
  /// 56: 文本编码 1=UTF-8 2=UTF-16le 3=UTF-16be
  text_encoding : Int
  user_version : Int
  incremental_vacuum : Int
  application_id : Int
  /// 92: version-valid-for
  version_valid_for : Int
  /// 96: 写入该文件的 SQLite 版本号，如 3045000
  sqlite_version : Int
}

pub fn DbHeader::encoding_name(self : DbHeader) -> String {
  match self.text_encoding {
    1 => "UTF-8"
    2 => "UTF-16le"
    3 => "UTF-16be"
    _ => "unknown"
  }
}

pub fn DbHeader::journal_mode_name(self : DbHeader) -> String {
  match self.write_version {
    1 => "rollback journal"
    2 => "WAL"
    _ => "unknown"
  }
}

pub struct Pager {
  bytes : Bytes
  header : DbHeader
}

fn magic_ok(b : Bytes) -> Bool {
  if b.length() < HEADER_SIZE {
    return false
  }
  let magic = [83, 81, 76, 105, 116, 101, 32, 102, 111, 114, 109, 97, 116, 32, 51, 0]
  for i = 0; i < 16; i = i + 1 {
    if byte_at(b, i) != magic[i] {
      return false
    }
  }
  true
}

fn is_power_of_two(n : Int) -> Bool {
  n > 0 && (n & (n - 1)) == 0
}

fn valid_encoding(e : Int) -> Bool {
  match e {
    0 | 1 | 2 | 3 => true
    _ => false
  }
}

pub fn Pager::open(bytes : Bytes) -> Pager raise DbError {
  if !magic_ok(bytes) {
    raise BadMagic
  }
  let mut page_size = be16(bytes, 16)
  if page_size == 1 {
    page_size = 65536
  }
  if page_size < 512 || page_size > 65536 || !is_power_of_two(page_size) {
    raise Corrupt("页大小非法：\{page_size}")
  }
  let reserved = byte_at(bytes, 20)
  if page_size - reserved < 480 {
    raise Corrupt("可用页空间过小：\{page_size - reserved}")
  }
  let declared = be32(bytes, 28)
  let file_pages = bytes.length() / page_size
  let page_count = if declared > 0 && declared <= file_pages {
    declared
  } else {
    file_pages
  }
  let header : DbHeader = {
    page_size,
    write_version: byte_at(bytes, 18),
    read_version: byte_at(bytes, 19),
    reserved,
    file_change_counter: be32(bytes, 24),
    page_count,
    freelist_trunk: be32(bytes, 32),
    freelist_count: be32(bytes, 36),
    schema_cookie: be32(bytes, 40),
    schema_format: be32(bytes, 44),
    largest_root: be32(bytes, 52),
    text_encoding: be32(bytes, 56),
    user_version: be32(bytes, 60),
    incremental_vacuum: be32(bytes, 64),
    application_id: be32(bytes, 68),
    version_valid_for: be32(bytes, 92),
    sqlite_version: be32(bytes, 96),
  }
  if !valid_encoding(header.text_encoding) {
    raise Corrupt("文本编码非法：\{header.text_encoding}")
  }
  { bytes, header }
}

pub fn Pager::header(self : Pager) -> DbHeader {
  self.header
}

pub fn Pager::page_size(self : Pager) -> Int {
  self.header.page_size
}

pub fn Pager::page_count(self : Pager) -> Int {
  self.header.page_count
}

pub fn Pager::usable(self : Pager) -> Int {
  self.header.page_size - self.header.reserved
}

pub fn Pager::text_encoding(self : Pager) -> Int {
  self.header.text_encoding
}

/// 取第 no 页（1 基），返回整页切片
pub fn Pager::page(self : Pager, no : Int) -> Bytes raise DbError {
  if no < 1 || no > self.header.page_count {
    raise Corrupt("页号越界：\{no}（共 \{self.header.page_count} 页）")
  }
  let off = (no - 1) * self.header.page_size
  if off + self.header.page_size > self.bytes.length() {
    raise Truncated("第 \{no} 页超出文件长度")
  }
  self.bytes[off:off + self.header.page_size].to_owned()
}

pub fn Pager::raw(self : Pager) -> Bytes {
  self.bytes
}
