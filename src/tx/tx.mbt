/// MoonBase 事务管理（简化版）
/// 支持 BEGIN / COMMIT / ROLLBACK 语义，基于写前日志（WAL）

pub(all) enum TxState {
  Active;
  Committed;
  Aborted;
} derive(Debug, Eq)

pub(all) struct Transaction {
  id : Int
  mut state : TxState
  writes : Array[WriteOp]
}

pub(all) enum WriteOp {
  InsertRow(String, @types.Row)  // table_name, row
}

pub(all) struct TxManager {
  mut next_id : Int
  mut active : Transaction?
  storage : @storage.Storage
}

pub fn TxManager::new(storage : @storage.Storage) -> TxManager {
  { next_id: 1, active: None, storage }
}

/// 开始新事务
pub fn TxManager::begin(self : TxManager) -> Transaction? {
  match self.active {
    Some(_) => None  // 不支持嵌套事务
    None => {
      let tx = { id: self.next_id, state: TxState::Active, writes: [] }
      self.next_id = self.next_id + 1
      self.active = Some(tx)
      Some(tx)
    }
  }
}

/// 在事务中插入行（先记日志，暂不写存储）
pub fn TxManager::insert(self : TxManager, table : String, row : @types.Row) -> Bool {
  match self.active {
    Some(tx) => {
      tx.writes.push(InsertRow(table, row))
      true
    }
    None => false
  }
}

/// 提交事务：把所有写操作应用到存储
pub fn TxManager::commit(self : TxManager) -> Bool {
  match self.active {
    Some(tx) => {
      if tx.state != TxState::Active { return false }
      for op in tx.writes {
        match op {
          InsertRow(table, row) => { self.storage.insert(table, row) |> ignore }
        }
      }
      tx.state = TxState::Committed
      self.active = None
      true
    }
    None => false
  }
}

/// 回滚事务：丢弃所有写操作
pub fn TxManager::rollback(self : TxManager) -> Bool {
  match self.active {
    Some(tx) => {
      if tx.state != TxState::Active { return false }
      tx.writes.clear()
      tx.state = TxState::Aborted
      self.active = None
      true
    }
    None => false
  }
}

/// 获取当前活跃事务
pub fn TxManager::current(self : TxManager) -> Transaction? {
  self.active
}
