/// 基础类型与编解码的单元测试

test "value: 实数显示带小数点" {
  assert_eq(VReal(88.0).to_display(), "88.0")
  assert_eq(VReal(91.5).to_display(), "91.5")
  assert_eq(VInt(Int64::from_int(42)).to_display(), "42")
  assert_eq(VNull.to_display(), "NULL")
}

test "value: 排序语义 NULL < 数值 < 文本 < BLOB" {
  assert_true(VNull.compare(VInt(Int64::from_int(0))) < 0)
  assert_true(VInt(Int64::from_int(9)).compare(VText("a")) < 0)
  assert_true(VText("z").compare(VBlob(Bytes::from_array([b'a']))) < 0)
}

test "value: 跨类型数值比较" {
  assert_eq(VInt(Int64::from_int(3)).compare(VReal(3.0)), 0)
  assert_true(VInt(Int64::from_int(2)).compare(VReal(2.5)) < 0)
  assert_true(VReal(2.5).compare(VInt(Int64::from_int(2))) > 0)
}

test "text: 按码点而非长度比较" {
  // 标准库的 String::compare 先比长度，这里必须按字典序
  assert_true(text_compare("Alice", "Bob") < 0)
  assert_true(text_compare("Zoe", "alice") < 0)
  assert_true(text_compare("app", "apple") < 0)
  assert_eq(text_compare("同", "同"), 0)
  assert_true(text_compare("陈", "马") < 0)
}

test "varint: 单字节与多字节往返" {
  let cases : Array[Int64] = [
    Int64::from_int(0),
    Int64::from_int(1),
    Int64::from_int(127),
    Int64::from_int(128),
    Int64::from_int(16383),
    Int64::from_int(16384),
    Int64::from_int(2097151),
    Int64::from_int(1000000),
  ]
  for v in cases {
    let enc = encode_varint(v)
    let bytes = Bytes::from_array(enc)
    let (decoded, used) = read_varint(bytes, 0)
    assert_eq(decoded, v)
    assert_eq(used, bytes.length())
  }
}

test "varint: 9 字节大整数" {
  let v = Int64::from_int(1) << 56
  let bytes = Bytes::from_array(encode_varint(v))
  let (decoded, used) = read_varint(bytes, 0)
  assert_eq(decoded, v)
  assert_eq(used, bytes.length())
}

test "record: 解码手工构造的行" {
  // 三个字段：整数 1、文本 "hi"、NULL
  // header: size=4, serial types = 1 (int8), 17 (text, 2 bytes), 0 (null)
  let payload = Bytes::from_array([
    b'\x04', b'\x01', b'\x11', b'\x00', // header
    b'\x01', // int 1
    b'h', b'i', // "hi"
  ])
  let vals = decode_record(payload, 1)
  assert_eq(vals.length(), 3)
  assert_eq(vals[0].to_display(), "1")
  assert_eq(vals[1].to_display(), "hi")
  assert_eq(vals[2].to_display(), "NULL")
}

test "record: serial type 8/9 表示常量 0 和 1" {
  let payload = Bytes::from_array([b'\x03', b'\x08', b'\x09', b'\x09'])
  let vals = decode_record(payload, 1)
  assert_eq(vals.length(), 2)
  assert_eq(vals[0].to_display(), "0")
  assert_eq(vals[1].to_display(), "1")
}

test "record: 实数按 IEEE754 大端解码" {
  // 91.5 = 0x4056E00000000000
  let payload = Bytes::from_array([
    b'\x02', b'\x07',
    b'\x40', b'\x56', b'\xE0', b'\x00', b'\x00', b'\x00', b'\x00', b'\x00',
  ])
  let vals = decode_record(payload, 1)
  assert_eq(vals[0].to_display(), "91.5")
}

test "record: 负整数符号扩展" {
  // int8 -1
  let payload = Bytes::from_array([b'\x02', b'\x01', b'\xFF'])
  let vals = decode_record(payload, 1)
  assert_eq(vals[0].to_display(), "-1")
}
