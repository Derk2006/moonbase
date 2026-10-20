/// 字节读取与 SQLite varint 编解码
///
/// SQLite 的 varint 是「大端 + 7 位一组」的变长整数：
/// 前 8 个字节各贡献 7 位，第 9 个字节贡献完整 8 位，因此 64 位整数最多 9 字节。

pub fn byte_at(b : Bytes, pos : Int) -> Int {
  b[pos].to_int() & 0xFF
}

pub fn be16(b : Bytes, pos : Int) -> Int {
  (byte_at(b, pos) << 8) | byte_at(b, pos + 1)
}

pub fn be32(b : Bytes, pos : Int) -> Int {
  let v = (Int64::from_int(byte_at(b, pos)) << 24)
    | (Int64::from_int(byte_at(b, pos + 1)) << 16)
    | (Int64::from_int(byte_at(b, pos + 2)) << 8)
    | Int64::from_int(byte_at(b, pos + 3))
  v.to_int()
}

/// 读取一个 varint，返回 (值, 消耗的字节数)
pub fn read_varint(b : Bytes, pos : Int) -> (Int64, Int) raise DbError {
  if pos >= b.length() {
    raise Truncated("varint 越过页边界")
  }
  let mut v : Int64 = Int64::from_int(0)
  let mut i = 0
  while i < 8 {
    let c = byte_at(b, pos + i)
    v = (v << 7) | Int64::from_int(c & 0x7F)
    i = i + 1
    if (c & 0x80) == 0 {
      return (v, i)
    }
  }
  // 第 9 字节：8 位全用
  v = (v << 8) | Int64::from_int(byte_at(b, pos + 8))
  (v, 9)
}

/// 计算某个 varint 的长度（不解析值），用于跳过
pub fn varint_len(b : Bytes, pos : Int) -> Int raise DbError {
  let (_, n) = read_varint(b, pos)
  n
}

/// 整数转 varint 字节（仅用于非负值：rowid、长度、serial type）
///
/// 不足 2^56 的值按 7 位一组编码；达到 2^56 时启用 SQLite 的第 9 字节形式
/// （前 8 字节各 7 位，第 9 字节 8 位）。
pub fn encode_varint(v : Int64) -> Array[Byte] {
  let out : Array[Byte] = []
  if v < (Int64::from_int(1) << 56) {
    let groups : Array[Int] = []
    let mut x = v
    while x > Int64::from_int(0x7F) {
      groups.push((x & Int64::from_int(0x7F)).to_int())
      x = x >> 7
    }
    groups.push(x.to_int())
    let n = groups.length()
    for i = n - 1; i >= 0; i = i - 1 {
      let mut b = groups[i]
      if i != 0 {
        b = b | 0x80
      }
      out.push(b.to_byte())
    }
  } else {
    let last = (v & Int64::from_int(0xFF)).to_int()
    let mut x = v >> 8
    let groups : Array[Int] = []
    for _i = 0; _i < 8; _i = _i + 1 {
      groups.push((x & Int64::from_int(0x7F)).to_int())
      x = x >> 7
    }
    for i = 7; i >= 0; i = i - 1 {
      out.push((groups[i] | 0x80).to_byte())
    }
    out.push(last.to_byte())
  }
  out
}
