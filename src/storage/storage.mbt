/// MoonBase 存储层：表管理 + B-tree 索引

pub(all) struct Table {
  schema : @types.TableSchema
  data : @btree.BTree  // 主键索引（假设主键是 Int）
  rows : Array[@types.Row]  // 全量数据（用于无索引扫描）
}

pub(all) struct Storage {
  mut tables : Map[String, Table]
}

pub fn Storage::new() -> Storage {
  { tables: {} }
}

/// 创建表
pub fn Storage::create_table(self : Storage, schema : @types.TableSchema) -> Unit {
  let table = {
    schema,
    data: @btree.BTree::new(order=8),
    rows: []
  }
  self.tables[schema.name] = table
}

/// 获取表
pub fn Storage::get_table(self : Storage, name : String) -> Table? {
  self.tables.get(name)
}

/// 插入行（简化：假设第一列是 Int 主键）
pub fn Storage::insert(self : Storage, table_name : String, row : @types.Row) -> Bool {
  match self.tables.get(table_name) {
    Some(table) => {
      table.rows.push(row)
      // 如果有 Int 主键，同时插入 B-tree
      if row.values.length() > 0 {
        match row.values[0] {
          @types.Value::IntVal(key) => { table.data.insert(key, row) }
          _ => ()
        }
      }
      true
    }
    None => false
  }
}

/// 按主键查找
pub fn Storage::select_by_key(self : Storage, table_name : String, key : Int) -> @types.Row? {
  match self.tables.get(table_name) {
    Some(table) => table.data.get(key)
    None => None
  }
}

/// 全表扫描
pub fn Storage::select_all(self : Storage, table_name : String) -> Array[@types.Row] {
  match self.tables.get(table_name) {
    Some(table) => table.rows
    None => []
  }
}

/// 范围查询（主键范围）
pub fn Storage::select_range(self : Storage, table_name : String, start : Int, end : Int) -> Array[@types.Row] {
  match self.tables.get(table_name) {
    Some(table) => table.data.range(start, end)
    None => []
  }
}

/// 获取所有表名
pub fn Storage::table_names(self : Storage) -> Array[String] {
  let names : Array[String] = []
  for name, _ in self.tables {
    names.push(name)
  }
  names
}
