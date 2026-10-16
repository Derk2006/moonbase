/// MoonBase 核心类型系统

/// 数据类型枚举
pub(all) enum DataType {
  Int;
  Double;
  Text;
  Bool;
} derive(Debug, Eq)

/// 单元格值
pub(all) enum Value {
  Null;
  IntVal(Int);
  DoubleVal(Double);
  TextVal(String);
  BoolVal(Bool);
} derive(Debug, Eq)

/// 列定义
pub(all) struct Column {
  name : String
  ty : DataType
  nullable : Bool
  primary_key : Bool
} derive(Debug, Eq)

/// 行数据
pub(all) struct Row {
  values : Array[Value]
} derive(Debug, Eq)

/// 表模式
pub(all) struct TableSchema {
  name : String
  columns : Array[Column]
} derive(Debug, Eq)

/// 比较操作符
pub(all) enum Op {
  Eq;
  Ne;
  Lt;
  Le;
  Gt;
  Ge;
} derive(Debug, Eq)

/// 表达式（用于 WHERE 子句）
pub(all) enum Expr {
  Literal(Value);
  ColumnRef(String);
  Binary(Op, Expr, Expr);
  And(Expr, Expr);
  Or(Expr, Expr);
  Not(Expr);
} derive(Debug, Eq)

/// SELECT 语句
pub(all) struct SelectStmt {
  columns : Array[String]
  table : String
  where_clause : Expr?
  order_by : OrderBy?
  limit : Int?
} derive(Debug, Eq)

/// 排序方式（ORDER BY 子句）
pub(all) struct OrderBy {
  column : String
  desc : Bool
} derive(Debug, Eq)

/// DELETE 语句
pub(all) struct DeleteStmt {
  table : String
  where_clause : Expr?
} derive(Debug, Eq)

/// INSERT 语句
pub(all) struct InsertStmt {
  table : String
  columns : Array[String]
  values : Array[Array[Value]]
} derive(Debug, Eq)

/// CREATE TABLE 语句
pub(all) struct CreateStmt {
  table : String
  columns : Array[Column]
} derive(Debug, Eq)

/// SQL 语句顶层枚举
pub(all) enum Statement {
  Select(SelectStmt);
  Insert(InsertStmt);
  Create(CreateStmt);
  Delete(DeleteStmt);
} derive(Debug, Eq)
