/// SQLite 存储层的值模型与错误类型
///
/// 与 SQL 层的 Value 不同，这里必须能表达 BLOB，并且整数是 64 位，
/// 因为 SQLite 的 record 里 serial type 7/8/9 描述的正是 64 位整数。

pub(all) enum Value {
  VNull
  VInt(Int64)
  VReal(Double)
  VText(String)
  VBlob(Bytes)
}

/// 打开 / 解析数据库文件时可能遇到的错误
pub suberror DbError {
  /// 文件头前 16 字节不是 "SQLite format 3\0"
  BadMagic
  /// 文件长度不足以容纳声明的页
  Truncated(String)
  /// 合法但本实现暂不支持的特性
  Unsupported(String)
  /// 页结构自相矛盾
  Corrupt(String)
  /// 找不到表或列
  NotFound(String)
  /// SQL 语法错误
  BadSql(String)
}

pub fn Value::is_null(self : Value) -> Bool {
  match self {
    VNull => true
    _ => false
  }
}

/// 类型名，对应 SQLite 的 storage class
pub fn Value::type_name(self : Value) -> String {
  match self {
    VNull => "null"
    VInt(_) => "integer"
    VReal(_) => "real"
    VText(_) => "text"
    VBlob(_) => "blob"
  }
}

/// 把实数格式化成 SQLite 命令行风格：整数形态的实数补 ".0"
fn format_real(d : Double) -> String {
  if d.is_nan() {
    return "NULL"
  }
  let s = d.to_string()
  if s.contains(".") || s.contains("e") || s.contains("E") || s.contains("n") || s.contains("i") {
    s
  } else {
    s + ".0"
  }
}

/// 面向终端输出的文本形态
pub fn Value::to_display(self : Value) -> String {
  match self {
    VNull => "NULL"
    VInt(i) => i.to_string()
    VReal(d) => format_real(d)
    VText(s) => s
    VBlob(b) => {
      let mut out = "X'"
      for i = 0; i < b.length(); i = i + 1 {
        out = out + hex_digit(b[i].to_int() / 16) + hex_digit(b[i].to_int() % 16)
      }
      out + "'"
    }
  }
}

fn hex_digit(n : Int) -> String {
  match n {
    0 => "0"
    1 => "1"
    2 => "2"
    3 => "3"
    4 => "4"
    5 => "5"
    6 => "6"
    7 => "7"
    8 => "8"
    9 => "9"
    10 => "A"
    11 => "B"
    12 => "C"
    13 => "D"
    14 => "E"
    _ => "F"
  }
}

/// 字符串按码点比较。
///
/// 不能用 String::compare —— MoonBit 标准库的字符串比较是「先比长度再比内容」，
/// 与 SQL 的 BINARY collation 不一致。UTF-8 的字节序恰好等于码点序，
/// 所以逐码点比较等价于 SQLite 的 BINARY 排序规则。
pub fn text_compare(a : String, b : String) -> Int {
  let ca = a.to_array()
  let cb = b.to_array()
  let n = if ca.length() < cb.length() { ca.length() } else { cb.length() }
  for i = 0; i < n; i = i + 1 {
    let x = ca[i].to_int()
    let y = cb[i].to_int()
    if x < y {
      return -1
    }
    if x > y {
      return 1
    }
  }
  if ca.length() < cb.length() {
    -1
  } else if ca.length() > cb.length() {
    1
  } else {
    0
  }
}

fn compare_int_real(i : Int64, d : Double) -> Int {
  let di = i.to_double()
  if di < d {
    -1
  } else if di > d {
    1
  } else {
    // 浮点无法精确表示时退化为逐位比较
    if d == di {
      0
    } else {
      let s = d - di
      if s < 0.0 {
        1
      } else {
        -1
      }
    }
  }
}

/// SQLite 的排序语义：NULL < 数值 < 文本 < BLOB
pub fn Value::compare(self : Value, other : Value) -> Int {
  let ra = self.rank()
  let rb = other.rank()
  if ra != rb {
    return if ra < rb { -1 } else { 1 }
  }
  match (self, other) {
    (VNull, VNull) => 0
    (VInt(a), VInt(b)) => if a < b { -1 } else if a > b { 1 } else { 0 }
    (VReal(a), VReal(b)) => if a < b { -1 } else if a > b { 1 } else { 0 }
    (VInt(a), VReal(b)) => compare_int_real(a, b)
    (VReal(a), VInt(b)) => -compare_int_real(b, a)
    (VText(a), VText(b)) => text_compare(a, b)
    (VBlob(a), VBlob(b)) => {
      let n = if a.length() < b.length() { a.length() } else { b.length() }
      let mut r = 0
      for i = 0; i < n; i = i + 1 {
        let x = a[i].to_int()
        let y = b[i].to_int()
        if x != y {
          r = if x < y { -1 } else { 1 }
          break
        }
      }
      if r != 0 {
        r
      } else if a.length() < b.length() {
        -1
      } else if a.length() > b.length() {
        1
      } else {
        0
      }
    }
    _ => 0
  }
}

fn Value::rank(self : Value) -> Int {
  match self {
    VNull => 0
    VInt(_) => 1
    VReal(_) => 1
    VText(_) => 2
    VBlob(_) => 3
  }
}

/// 值相等（用于 WHERE 的 =）
pub fn Value::same(self : Value, other : Value) -> Bool {
  self.compare(other) == 0
}

/// 面向用户的错误描述
pub fn DbError::message(self : DbError) -> String {
  match self {
    BadMagic => "不是 SQLite 数据库文件：文件头 magic 不匹配"
    Truncated(s) => "文件被截断：\{s}"
    Unsupported(s) => "暂不支持：\{s}"
    Corrupt(s) => "页结构损坏：\{s}"
    NotFound(s) => "找不到对象：\{s}"
    BadSql(s) => "SQL 语法错误：\{s}"
  }
}
