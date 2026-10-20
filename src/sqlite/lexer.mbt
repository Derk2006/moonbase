/// 面向 SQLite 方言的轻量词法器
///
/// 与通用的 SQL 解析器不同，这里的输入是真实数据库文件里的 DDL 文本，
/// 需要容忍双引号/方括号/反引号包裹的标识符、多词类型名、以及各种约束。

pub(all) enum Tok {
  /// 标识符或关键字（保留原始大小写）
  TWord(String)
  /// 单引号字符串字面量（已去掉引号并还原 ''）
  TString(String)
  /// 数字（整数或实数，保留原文）
  TNumber(String)
  /// 符号：( ) , . * ; =
  TSym(String)
  /// 比较运算符：<> < <= > >=
  TOp(String)
  TEof
}

fn is_word_start(c : Char) -> Bool {
  (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_' || c > '\u{7F}'
}

fn is_word_char(c : Char) -> Bool {
  is_word_start(c) || (c >= '0' && c <= '9') || c == '$'
}

fn is_digit(c : Char) -> Bool {
  c >= '0' && c <= '9'
}

pub fn lex(sql : String) -> Array[Tok] raise DbError {
  let out : Array[Tok] = []
  let chars = sql.to_array()
  let n = chars.length()
  let mut i = 0
  while i < n {
    let c = chars[i]
    if c == ' ' || c == '\t' || c == '\n' || c == '\r' {
      i = i + 1
      continue
    }
    // 注释：-- 到行尾
    if c == '-' && i + 1 < n && chars[i + 1] == '-' {
      while i < n && chars[i] != '\n' {
        i = i + 1
      }
      continue
    }
    // 注释：/* ... */
    if c == '/' && i + 1 < n && chars[i + 1] == '*' {
      i = i + 2
      while i + 1 < n && !(chars[i] == '*' && chars[i + 1] == '/') {
        i = i + 1
      }
      i = i + 2
      continue
    }
    if c == '\'' {
      let buf = ""
      let mut j = i + 1
      let mut s = ""
      while j < n {
        if chars[j] == '\'' {
          if j + 1 < n && chars[j + 1] == '\'' {
            s = s + "'"
            j = j + 2
            continue
          }
          break
        }
        s = s + chars[j].to_string()
        j = j + 1
      }
      if j >= n {
        raise BadSql("字符串字面量未闭合")
      }
      ignore(buf)
      out.push(TString(s))
      i = j + 1
      continue
    }
    if c == '"' || c == '`' || c == '[' {
      let close = if c == '[' { ']' } else { c }
      let mut j = i + 1
      let mut s = ""
      while j < n && chars[j] != close {
        s = s + chars[j].to_string()
        j = j + 1
      }
      if j >= n {
        raise BadSql("标识符引号未闭合")
      }
      out.push(TWord(s))
      i = j + 1
      continue
    }
    if is_digit(c) || (c == '.' && i + 1 < n && is_digit(chars[i + 1])) {
      let mut j = i
      let mut seen_dot = false
      let mut seen_e = false
      while j < n {
        let ch = chars[j]
        if is_digit(ch) {
          j = j + 1
        } else if ch == '.' && !seen_dot && !seen_e {
          seen_dot = true
          j = j + 1
        } else if (ch == 'e' || ch == 'E') && !seen_e {
          seen_e = true
          j = j + 1
          if j < n && (chars[j] == '+' || chars[j] == '-') {
            j = j + 1
          }
        } else {
          break
        }
      }
      out.push(TNumber(sql[i:j].to_owned()))
      i = j
      continue
    }
    if is_word_start(c) {
      let mut j = i + 1
      while j < n && is_word_char(chars[j]) {
        j = j + 1
      }
      out.push(TWord(sql[i:j].to_owned()))
      i = j
      continue
    }
    if c == '<' {
      if i + 1 < n && chars[i + 1] == '=' {
        out.push(TOp("<="))
        i = i + 2
      } else if i + 1 < n && chars[i + 1] == '>' {
        out.push(TOp("<>"))
        i = i + 2
      } else {
        out.push(TOp("<"))
        i = i + 1
      }
      continue
    }
    if c == '>' {
      if i + 1 < n && chars[i + 1] == '=' {
        out.push(TOp(">="))
        i = i + 2
      } else {
        out.push(TOp(">"))
        i = i + 1
      }
      continue
    }
    if c == '=' {
      if i + 1 < n && chars[i + 1] == '=' {
        out.push(TOp("="))
        i = i + 2
      } else {
        out.push(TOp("="))
        i = i + 1
      }
      continue
    }
    if c == '!' && i + 1 < n && chars[i + 1] == '=' {
      out.push(TOp("<>"))
      i = i + 2
      continue
    }
    if c == '(' || c == ')' || c == ',' || c == '.' || c == '*' || c == ';' {
      out.push(TSym(c.to_string()))
      i = i + 1
      continue
    }
    // 其他字符（如 | & + -）忽略，交给上层按需处理
    i = i + 1
  }
  out.push(TEof)
  out
}

pub fn Tok::is_word(self : Tok, w : String) -> Bool {
  match self {
    TWord(s) => s.to_upper() == w
    _ => false
  }
}

pub fn Tok::word(self : Tok) -> String raise DbError {
  match self {
    TWord(s) => s
    _ => raise BadSql("期望标识符")
  }
}
