/// SQLite record（行）格式解码
///
/// 一个 record = header + body：
///   header = varint(header 字节数) + 每个字段的 serial type(varint)
///   body   = 按 serial type 依次排列的字段内容
/// serial type 的含义见官方文档 2.1 节。

pub fn serial_type_size(t : Int) -> Int {
  match t {
    0 => 0
    1 => 1
    2 => 2
    3 => 3
    4 => 4
    5 => 6
    6 => 8
    7 => 8
    8 => 0
    9 => 0
    10 => 0
    11 => 0
    _ => if t % 2 == 0 { (t - 12) / 2 } else { (t - 13) / 2 }
  }
}

fn read_signed(b : Bytes, pos : Int, len : Int) -> Int64 {
  let mut v : Int64 = Int64::from_int(0)
  for i = 0; i < len; i = i + 1 {
    v = (v << 8) | Int64::from_int(byte_at(b, pos + i))
  }
  let shift = 64 - 8 * len
  if shift > 0 {
    (v << shift) >> shift
  } else {
    v
  }
}

fn read_f64(b : Bytes, pos : Int) -> Double {
  let mut bits : UInt64 = 0UL
  for i = 0; i < 8; i = i + 1 {
    bits = (bits << 8) | byte_at(b, pos + i).to_uint64()
  }
  bits.reinterpret_as_double()
}

fn decode_text(b : Bytes, pos : Int, len : Int, enc : Int) -> String {
  let view = b[pos:pos + len]
  match enc {
    2 => @utf16.decode_lossy(view, endianness=@utf16.Endian::Little)
    3 => @utf16.decode_lossy(view, endianness=@utf16.Endian::Big)
    _ => @utf8.decode_lossy(view)
  }
}

/// 解码单个字段，返回 (值, 消耗字节数)
pub fn decode_field(
  b : Bytes,
  pos : Int,
  t : Int,
  enc : Int
) -> (Value, Int) raise DbError {
  let size = serial_type_size(t)
  if pos + size > b.length() {
    raise Corrupt("record 字段越过 payload 边界")
  }
  let v = match t {
    0 => VNull
    1 => VInt(read_signed(b, pos, 1))
    2 => VInt(read_signed(b, pos, 2))
    3 => VInt(read_signed(b, pos, 3))
    4 => VInt(read_signed(b, pos, 4))
    5 => VInt(read_signed(b, pos, 6))
    6 => VInt(read_signed(b, pos, 8))
    7 => VReal(read_f64(b, pos))
    8 => VInt(Int64::from_int(0))
    9 => VInt(Int64::from_int(1))
    10 | 11 => VNull
    _ =>
      if t % 2 == 0 {
        VBlob(b[pos:pos + size].to_owned())
      } else {
        VText(decode_text(b, pos, size, enc))
      }
  }
  (v, size)
}

/// 解码一条完整 record
pub fn decode_record(payload : Bytes, enc : Int) -> Array[Value] raise DbError {
  if payload.length() == 0 {
    return []
  }
  let (hs, hs_len) = read_varint(payload, 0)
  let header_size = hs.to_int()
  if header_size > payload.length() || header_size < hs_len {
    raise Corrupt("record header 长度非法：\{header_size}")
  }
  let types : Array[Int] = []
  let mut pos = hs_len
  while pos < header_size {
    let (t, n) = read_varint(payload, pos)
    types.push(t.to_int())
    pos = pos + n
  }
  let out : Array[Value] = []
  let mut body = header_size
  for t in types {
    let (v, n) = decode_field(payload, body, t, enc)
    out.push(v)
    body = body + n
  }
  out
}

/// 由 serial type 反推该字段占用的字节数（供测试与调试）
pub fn record_field_count(payload : Bytes) -> Int raise DbError {
  if payload.length() == 0 {
    return 0
  }
  let (hs, hs_len) = read_varint(payload, 0)
  let header_size = hs.to_int()
  let mut pos = hs_len
  let mut n = 0
  while pos < header_size {
    let (_, step) = read_varint(payload, pos)
    pos = pos + step
    n = n + 1
  }
  n
}
