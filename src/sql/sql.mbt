/// MoonBase SQL 解析器（手写递归下降）

pub(all) struct Token {
  kind : TokenKind
  text : String
}

pub(all) enum TokenKind {
  IDENT;
  NUMBER;
  STRING;
  KEYWORD;
  COMMA;
  LPAREN;
  RPAREN;
  SEMI;
  STAR;
  EQ;
  NE;
  LT;
  LE;
  GT;
  GE;
  AND;
  OR;
  NOT;
  EOF;
} derive(Debug, Eq)

fn is_keyword(s : String) -> Bool {
  match s {
    "SELECT" | "FROM" | "WHERE" | "INSERT" | "INTO" | "VALUES"
    | "CREATE" | "TABLE" | "INT" | "DOUBLE" | "TEXT" | "BOOL"
    | "NULL" | "PRIMARY" | "KEY" | "NOT" | "AND" | "OR" => true
    _ => false
  }
}

pub fn tokenize(input : String) -> Array[Token] {
  let tokens : Array[Token] = []
  let mut i = 0
  let n = input.length()
  while i < n {
    let c = input[i]
    if c == ' ' || c == '\t' || c == '\n' || c == '\r' {
      i = i + 1
      continue
    }
    if c == ',' { tokens.push({ kind: TokenKind::COMMA, text: "," }); i = i + 1; continue }
    if c == '(' { tokens.push({ kind: TokenKind::LPAREN, text: "(" }); i = i + 1; continue }
    if c == ')' { tokens.push({ kind: TokenKind::RPAREN, text: ")" }); i = i + 1; continue }
    if c == ';' { tokens.push({ kind: TokenKind::SEMI, text: ";" }); i = i + 1; continue }
    if c == '*' { tokens.push({ kind: TokenKind::STAR, text: "*" }); i = i + 1; continue }
    if c == '=' { tokens.push({ kind: TokenKind::EQ, text: "=" }); i = i + 1; continue }
    if c == '<' {
      if i + 1 < n && input[i + 1] == '=' {
        tokens.push({ kind: TokenKind::LE, text: "<=" }); i = i + 2
      } else if i + 1 < n && input[i + 1] == '>' {
        tokens.push({ kind: TokenKind::NE, text: "<>" }); i = i + 2
      } else {
        tokens.push({ kind: TokenKind::LT, text: "<" }); i = i + 1
      }
      continue
    }
    if c == '>' {
      if i + 1 < n && input[i + 1] == '=' {
        tokens.push({ kind: TokenKind::GE, text: ">=" }); i = i + 2
      } else {
        tokens.push({ kind: TokenKind::GT, text: ">" }); i = i + 1
      }
      continue
    }
    if c == '\'' {
      let mut j = i + 1
      while j < n && input[j] != '\'' { j = j + 1 }
      let text = input[i + 1:j].to_owned()
      tokens.push({ kind: TokenKind::STRING, text: text })
      i = j + 1
      continue
    }
    if (c >= '0' && c <= '9') || c == '-' {
      let mut j = i
      if c == '-' { j = j + 1 }
      while j < n && input[j] >= '0' && input[j] <= '9' { j = j + 1 }
      if j < n && input[j] == '.' {
        j = j + 1
        while j < n && input[j] >= '0' && input[j] <= '9' { j = j + 1 }
      }
      tokens.push({ kind: TokenKind::NUMBER, text: input[i:j].to_owned() })
      i = j
      continue
    }
    if (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_' {
      let mut j = i + 1
      while j < n {
        let ch = input[j]
        if (ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') || (ch >= '0' && ch <= '9') || ch == '_' {
          j = j + 1
        } else {
          break
        }
      }
      let text = input[i:j].to_owned()
      let kind = if is_keyword(text.to_upper()) { TokenKind::KEYWORD } else { TokenKind::IDENT }
      tokens.push({ kind, text })
      i = j
      continue
    }
    i = i + 1
  }
  tokens.push({ kind: TokenKind::EOF, text: "" })
  tokens
}

priv struct Parser {
  tokens : Array[Token]
  mut pos : Int
}

fn peek(p : Parser) -> Token { p.tokens[p.pos] }
fn advance(p : Parser) -> Token { let t = p.tokens[p.pos]; p.pos = p.pos + 1; t }
fn expect(p : Parser, kind : TokenKind) -> Token {
  let t = peek(p)
  if t.kind != kind { panic() }
  advance(p)
}
fn match_keyword(p : Parser, kw : String) -> Bool {
  let t = peek(p)
  t.kind == TokenKind::KEYWORD && t.text.to_upper() == kw
}

fn parse_expr(p : Parser) -> @types.Expr {
  parse_or(p)
}

fn parse_or(p : Parser) -> @types.Expr {
  let mut left = parse_and(p)
  while match_keyword(p, "OR") {
    ignore(advance(p))
    let right = parse_and(p)
    left = @types.Expr::Or(left, right)
  }
  left
}

fn parse_and(p : Parser) -> @types.Expr {
  let mut left = parse_cmp(p)
  while match_keyword(p, "AND") {
    ignore(advance(p))
    let right = parse_cmp(p)
    left = @types.Expr::And(left, right)
  }
  left
}

fn parse_cmp(p : Parser) -> @types.Expr {
  let left = parse_primary(p)
  let t = peek(p)
  let op = match t.kind {
    TokenKind::EQ => { ignore(advance(p)); @types.Op::Eq }
    TokenKind::NE => { ignore(advance(p)); @types.Op::Ne }
    TokenKind::LT => { ignore(advance(p)); @types.Op::Lt }
    TokenKind::LE => { ignore(advance(p)); @types.Op::Le }
    TokenKind::GT => { ignore(advance(p)); @types.Op::Gt }
    TokenKind::GE => { ignore(advance(p)); @types.Op::Ge }
    _ => return left
  }
  let right = parse_primary(p)
  @types.Expr::Binary(op, left, right)
}

fn parse_primary(p : Parser) -> @types.Expr {
  let t = peek(p)
  match t.kind {
    TokenKind::NUMBER => {
      ignore(advance(p))
      if t.text.contains(".") {
        @types.Expr::Literal(@types.Value::DoubleVal(try @string.parse_double(t.text[:]) catch { _ => panic() }))
      } else {
        @types.Expr::Literal(@types.Value::IntVal(try @string.parse_int(t.text[:]) catch { _ => panic() }))
      }
    }
    TokenKind::STRING => { ignore(advance(p)); @types.Expr::Literal(@types.Value::TextVal(t.text)) }
    TokenKind::IDENT => { ignore(advance(p)); @types.Expr::ColumnRef(t.text) }
    TokenKind::KEYWORD => {
      if t.text.to_upper() == "NULL" { ignore(advance(p)); @types.Expr::Literal(@types.Value::Null) }
      else { panic() }
    }
    _ => panic()
  }
}

fn parse_select(p : Parser) -> @types.Statement {
  ignore(expect(p, TokenKind::KEYWORD)) // SELECT
  let columns : Array[String] = []
  if peek(p).kind == TokenKind::STAR {
    ignore(advance(p))
    columns.push("*")
  } else {
    while true {
      let t = expect(p, TokenKind::IDENT)
      columns.push(t.text)
      if peek(p).kind == TokenKind::COMMA { ignore(advance(p)) } else { break }
    }
  }
  expect_keyword(p, "FROM")
  let table = expect(p, TokenKind::IDENT).text
  let mut where_clause : @types.Expr? = None
  if match_keyword(p, "WHERE") {
    ignore(advance(p))
    where_clause = Some(parse_expr(p))
  }
  @types.Statement::Select(@types.SelectStmt::{ columns, table, where_clause })
}

fn expect_keyword(p : Parser, kw : String) -> Unit {
  let t = peek(p)
  if t.kind != TokenKind::KEYWORD || t.text.to_upper() != kw { panic() }
  ignore(advance(p))
}

fn parse_insert(p : Parser) -> @types.Statement {
  ignore(expect(p, TokenKind::KEYWORD)) // INSERT
  expect_keyword(p, "INTO")
  let table = expect(p, TokenKind::IDENT).text
  let columns : Array[String] = []
  if peek(p).kind == TokenKind::LPAREN {
    ignore(advance(p))
    while true {
      columns.push(expect(p, TokenKind::IDENT).text)
      if peek(p).kind == TokenKind::COMMA { ignore(advance(p)) } else { break }
    }
    ignore(expect(p, TokenKind::RPAREN))
  }
  expect_keyword(p, "VALUES")
  let values : Array[Array[@types.Value]] = []
  while true {
    ignore(expect(p, TokenKind::LPAREN))
    let row : Array[@types.Value] = []
    while true {
      let t = advance(p)
      let v = match t.kind {
        TokenKind::NUMBER => if t.text.contains(".") { @types.Value::DoubleVal(try @string.parse_double(t.text[:]) catch { _ => panic() }) } else { @types.Value::IntVal(try @string.parse_int(t.text[:]) catch { _ => panic() }) }
        TokenKind::STRING => @types.Value::TextVal(t.text)
        TokenKind::KEYWORD => if t.text.to_upper() == "NULL" { @types.Value::Null } else { panic() }
        _ => panic()
      }
      row.push(v)
      if peek(p).kind == TokenKind::COMMA { ignore(advance(p)) } else { break }
    }
    ignore(expect(p, TokenKind::RPAREN))
    values.push(row)
    if peek(p).kind == TokenKind::COMMA { ignore(advance(p)) } else { break }
  }
  @types.Statement::Insert(@types.InsertStmt::{ table, columns, values })
}

fn parse_create(p : Parser) -> @types.Statement {
  ignore(expect(p, TokenKind::KEYWORD)) // CREATE
  expect_keyword(p, "TABLE")
  let table = expect(p, TokenKind::IDENT).text
  ignore(expect(p, TokenKind::LPAREN))
  let cols : Array[@types.Column] = []
  while true {
    let name = expect(p, TokenKind::IDENT).text
    let ty_token = expect(p, TokenKind::KEYWORD)
    let ty = match ty_token.text.to_upper() {
      "INT" => @types.DataType::Int
      "DOUBLE" => @types.DataType::Double
      "TEXT" => @types.DataType::Text
      "BOOL" => @types.DataType::Bool
      _ => panic()
    }
    let mut nullable = true
    let mut primary_key = false
    if match_keyword(p, "NOT") {
      ignore(advance(p))
      expect_keyword(p, "NULL")
      nullable = false
    }
    if match_keyword(p, "PRIMARY") {
      ignore(advance(p))
      expect_keyword(p, "KEY")
      primary_key = true
      nullable = false
    }
    cols.push(@types.Column::{ name, ty, nullable, primary_key })
    if peek(p).kind == TokenKind::COMMA { ignore(advance(p)) } else { break }
  }
  ignore(expect(p, TokenKind::RPAREN))
  @types.Statement::Create(@types.CreateStmt::{ table, columns: cols })
}

/// 解析 SQL 字符串，返回顶层语句
pub fn parse(sql : String) -> @types.Statement? {
  let tokens = tokenize(sql)
  let p = { tokens, pos: 0 }
  let t = peek(p)
  if t.kind != TokenKind::KEYWORD { return None }
  let stmt = match t.text.to_upper() {
    "SELECT" => parse_select(p)
    "INSERT" => parse_insert(p)
    "CREATE" => parse_create(p)
    _ => return None
  }
  Some(stmt)
}
