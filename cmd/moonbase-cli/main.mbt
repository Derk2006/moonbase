/// moonbase-cli：直接打开 / 生成真实的 SQLite 数据库文件
///
/// 用法：
///   moonbase-cli header <file.db>              打印文件头
///   moonbase-cli schema <file.db>              列出表 / 索引 / 列
///   moonbase-cli tree   <file.db> <table>      打印表 B 树结构
///   moonbase-cli query  <file.db> "<sql>"      执行只读查询
///   moonbase-cli dump   <file.db> <table>      导出整表（竖线分隔）
///   moonbase-cli dump-sql <file.db>            导出整库为 SQL 脚本（可直接喂给 sqlite3）
///   moonbase-cli make   <out.db>               用纯 MoonBit 生成一份合法 .db

fn usage() -> Unit {
  println("MoonBase —— 纯 MoonBit 实现的 SQLite 文件格式读取 / 生成器")
  println("")
  println("用法：")
  println("  moonbase-cli header <file.db>")
  println("  moonbase-cli schema <file.db>")
  println("  moonbase-cli tree   <file.db> <table>")
  println("  moonbase-cli query  <file.db> \"SELECT ...\"")
  println("  moonbase-cli dump   <file.db> <table>")
  println("  moonbase-cli dump-sql <file.db>           导出整库为 SQL 脚本（> out.sql）")
  println("  moonbase-cli make   <out.db>              用纯 MoonBit 生成一份合法 .db")
}

fn row_to_line(vals : Array[@sqlite.Value]) -> String {
  let parts : Array[String] = []
  for v in vals {
    parts.push(v.to_display())
  }
  parts.join("|")
}

fn cmd_header(db : @sqlite.Db) -> Unit {
  let h = db.pager().header()
  println("page_size           \{h.page_size}")
  println("page_count          \{h.page_count}")
  println("journal_mode        \{h.journal_mode_name()}")
  println("text_encoding       \{h.encoding_name()}")
  println("reserved_bytes      \{h.reserved}")
  println("file_change_counter \{h.file_change_counter}")
  println("schema_cookie       \{h.schema_cookie}")
  println("schema_format       \{h.schema_format}")
  println("freelist_trunk      \{h.freelist_trunk}")
  println("freelist_count      \{h.freelist_count}")
  println("largest_root        \{h.largest_root}")
  println("user_version        \{h.user_version}")
  println("application_id      \{h.application_id}")
  println("sqlite_version      \{h.sqlite_version}")
}

fn cmd_schema(db : @sqlite.Db) -> Unit {
  let schema = db.schema()
  for t in schema.tables() {
    if t.is_view {
      println("view \{t.name}")
    } else {
      let flags = if t.without_rowid { " WITHOUT ROWID" } else { "" }
      println("table \{t.name} (root=\{t.rootpage}, \{t.columns.length()} 列)\{flags}")
      for c in t.columns {
        let pk = if c.is_rowid_alias {
          "  [INTEGER PRIMARY KEY -> rowid 别名]"
        } else if c.is_pk {
          "  [PK]"
        } else {
          ""
        }
        println("    \{c.name}  \{c.decl_type}\{pk}")
      }
    }
  }
  for idx in schema.indexes() {
    let u = if idx.is_unique { "UNIQUE " } else { "" }
    println("\{u}index \{idx.name} on \{idx.table} (root=\{idx.rootpage})")
  }
}

fn cmd_tree(db : @sqlite.Db, table : String) -> Unit {
  let t = db.table(table) catch {
    e => {
      println(e.message())
      return
    }
  }
  let pager = db.pager()
  let root = @sqlite.BtreePage::parse(pager, t.rootpage) catch {
    e => {
      println(e.message())
      return
    }
  }
  println("表 \{t.name}：root page \{t.rootpage}，类型 \{@sqlite.page_type_name(root.page_type)}，单元数 \{root.ncell}")
  let rows = db.rows(t) catch {
    e => {
      println(e.message())
      return
    }
  }
  println("行数：\{rows.length()}")
}

fn cmd_query(db : @sqlite.Db, sql : String) -> Unit {
  let rs = @sqlite.query(db, sql) catch {
    e => {
      println(e.message())
      return
    }
  }
  println(rs.columns().join("|"))
  for r in rs.rows() {
    println(row_to_line(r))
  }
}

fn cmd_dump(db : @sqlite.Db, table : String) -> Unit {
  let t = db.table(table) catch {
    e => {
      println(e.message())
      return
    }
  }
  println(t.column_names().join("|"))
  let rows = db.rows(t) catch {
    e => {
      println(e.message())
      return
    }
  }
  for r in rows {
    println(row_to_line(r.values))
  }
}

fn cmd_dump_sql(db : @sqlite.Db) -> Unit {
  let sql = @sqlite.export_sql(db) catch {
    e => {
      println(e.message())
      return
    }
  }
  // 直接输出到 stdout，便于 `> out.sql` 重定向
  println(sql)
}

fn is_command(s : String) -> Bool {
  s == "header" || s == "schema" || s == "tree" || s == "query" || s == "dump" || s == "dump-sql" || s == "make"
}

fn cmd_make(path : String) -> Unit {
  // 通过「外部包可用的公开 API」构造数据：RowSpec::new / TableSpec::new。
  // 这既是 CLI 演示，也是写入器库 API 的可用性验证。
  let rows : Array[@sqlite.RowSpec] = [
    @sqlite.RowSpec::new(
      None,
      [
        @sqlite.VInt(Int64::from_int(1)),
        @sqlite.VText("Alice"),
        @sqlite.VReal(91.5),
        @sqlite.VBlob(Bytes::from_array([b'\xDE', b'\xAD', b'\xBE', b'\xEF'])),
      ],
    ),
    @sqlite.RowSpec::new(
      None,
      [
        @sqlite.VInt(Int64::from_int(2)),
        @sqlite.VText("Bob"),
        @sqlite.VReal(88.0),
        @sqlite.VBlob(Bytes::new(0)),
      ],
    ),
    @sqlite.RowSpec::new(
      None,
      [
        @sqlite.VInt(Int64::from_int(3)),
        @sqlite.VText("陈小明"),
        @sqlite.VReal(77.25),
        @sqlite.VBlob(Bytes::from_array([b'\x01', b'\x02'])),
      ],
    ),
  ]
  let tables : Array[@sqlite.TableSpec] = [
    @sqlite.TableSpec::new(
      "users",
      "CREATE TABLE users(id integer primary key, name text, score real, memo blob)",
      rows,
    ),
  ]
  let bytes = @sqlite.make_db(tables) catch {
    e => {
      println("生成数据库失败：\{e.message()}")
      return
    }
  }
  write_file(path, bytes)
  println("已生成 \{path}（\{bytes.length()} 字节）")
  // 立即用本库读回，验证自洽
  let db = @sqlite.Db::open(bytes) catch {
    e => {
      println("读写自洽校验失败：\{e.message()}")
      return
    }
  }
  let t = db.table("users") catch {
    e => {
      println("读写自洽校验失败：\{e.message()}")
      return
    }
  }
  let rows = db.rows(t) catch {
    e => {
      println("读写自洽校验失败：\{e.message()}")
      return
    }
  }
  println("自洽校验通过：users 表共 \{rows.length()} 行")
  for r in rows {
    println("  " + row_to_line(r.values))
  }
  println("可用官方 sqlite3 打开验证：sqlite3 \{path} \"SELECT * FROM users\"")
}

fn main {
  let args = @env.args()
  // 不同后端对 argv[0] 的处理不一致，这里直接定位第一个子命令
  let mut at = -1
  for i = 0; i < args.length(); i = i + 1 {
    if is_command(args[i]) {
      at = i
      break
    }
  }
  if at < 0 || at + 1 >= args.length() {
    usage()
    return
  }
  let cmd = args[at]
  let path = args[at + 1]
  if cmd == "make" {
    // make 的输出文件尚不存在，跳过读取，直接交给 cmd_make 生成
    cmd_make(path)
    return
  }
  let bytes = read_file(path)
  let db = @sqlite.Db::open(bytes) catch {
    e => {
      println(e.message())
      return
    }
  }
  if cmd == "header" {
    cmd_header(db)
  } else if cmd == "schema" {
    cmd_schema(db)
  } else if cmd == "tree" && at + 2 < args.length() {
    cmd_tree(db, args[at + 2])
  } else if cmd == "query" && at + 2 < args.length() {
    cmd_query(db, args[at + 2])
  } else if cmd == "dump" && at + 2 < args.length() {
    cmd_dump(db, args[at + 2])
  } else if cmd == "dump-sql" {
    cmd_dump_sql(db)
  } else {
    usage()
  }
}
