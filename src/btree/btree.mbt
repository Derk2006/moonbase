/// MoonBase B-tree 存储引擎（内存版）
/// 支持 Int 键的 B-tree，用于索引和主键查找

struct LeafNode {
  mut keys : Array[Int]
  mut values : Array[@types.Row]
  mut next : Node?
} derive(Debug)

struct InternalNode {
  keys : Array[Int]
  children : Array[Node]
} derive(Debug)

enum Node {
  Leaf(LeafNode)
  Internal(InternalNode)
} derive(Debug)

struct BTree {
  mut root : Node
  order : Int
}

fn new_leaf() -> Node {
  Leaf(LeafNode::{ keys: [], values: [], next: None })
}

fn[T] array_slice(arr : Array[T], start : Int, end : Int) -> Array[T] {
  let result : Array[T] = []
  for i = start; i < end; i = i + 1 {
    result.push(arr[i])
  }
  result
}

/// 创建新的 B-tree，order 为每个节点的最大键数
pub fn BTree::new(order~ : Int = 4) -> BTree {
  { root: new_leaf(), order }
}

/// 在节点中二分查找键的位置（用于叶子节点）
fn find_pos(keys : Array[Int], key : Int) -> Int {
  let mut lo = 0
  let mut hi = keys.length()
  while lo < hi {
    let mid = (lo + hi) / 2
    if keys[mid] < key {
      lo = mid + 1
    } else {
      hi = mid
    }
  }
  lo
}

/// 查找内部节点的子节点索引
fn find_child(keys : Array[Int], key : Int) -> Int {
  let mut pos = 0
  while pos < keys.length() && key >= keys[pos] {
    pos = pos + 1
  }
  pos
}

/// 从 B-tree 中按键查找行
pub fn BTree::get(self : BTree, key : Int) -> @types.Row? {
  let mut node = self.root
  while true {
    match node {
      Leaf(leaf) => {
        let pos = find_pos(leaf.keys, key)
        if pos < leaf.keys.length() && leaf.keys[pos] == key {
          return Some(leaf.values[pos])
        }
        return None
      }
      Internal(internal) => {
        let pos = find_child(internal.keys, key)
        node = internal.children[pos]
      }
    }
  }
  None
}

/// 插入键值对（简化版：允许重复，用于主键时上层保证唯一）
pub fn BTree::insert(self : BTree, key : Int, value : @types.Row) -> Unit {
  self.root = insert_rec(self.root, key, value, self.order)
}

fn insert_rec(node : Node, key : Int, value : @types.Row, order : Int) -> Node {
  match node {
    Leaf(leaf) => {
      let pos = find_pos(leaf.keys, key)
      leaf.keys.insert(pos, key)
      leaf.values.insert(pos, value)
      if leaf.keys.length() > order {
        split_leaf(leaf, order)
      } else {
        Leaf(leaf)
      }
    }
    Internal(internal) => {
      let pos = find_child(internal.keys, key)
      let child = insert_rec(internal.children[pos], key, value, order)
      match child {
        Leaf(_) => { internal.children[pos] = child; Internal(internal) }
        Internal(child_internal) => {
          if child_internal.keys.length() > order {
            let (left, mid_key, right) = split_internal(child_internal)
            internal.children[pos] = left
            let insert_pos = find_pos(internal.keys, mid_key)
            internal.keys.insert(insert_pos, mid_key)
            internal.children.insert(insert_pos + 1, right)
            if internal.keys.length() > order {
              let (left, mid_key, right) = split_internal(internal)
              let parent_keys = [mid_key]
              let parent_children : Array[Node] = [left, right]
              Internal(InternalNode::{ keys: parent_keys, children: parent_children })
            } else {
              Internal(internal)
            }
          } else {
            internal.children[pos] = child
            Internal(internal)
          }
        }
      }
    }
  }
}

fn split_leaf(leaf : LeafNode, order : Int) -> Node {
  let mid = (order + 1) / 2
  let right_keys = array_slice(leaf.keys, mid, leaf.keys.length())
  let right_values = array_slice(leaf.values, mid, leaf.values.length())
  let left_keys = array_slice(leaf.keys, 0, mid)
  let left_values = array_slice(leaf.values, 0, mid)
  let old_next = leaf.next
  leaf.keys = left_keys
  leaf.values = left_values
  let right = Leaf(LeafNode::{ keys: right_keys, values: right_values, next: old_next })
  leaf.next = Some(right)
  let parent_keys = [right_keys[0]]
  let parent_children : Array[Node] = [Leaf(leaf), right]
  Internal(InternalNode::{ keys: parent_keys, children: parent_children })
}

fn split_internal(node : InternalNode) -> (Node, Int, Node) {
  let mid = node.keys.length() / 2
  let mid_key = node.keys[mid]
  let right_keys = array_slice(node.keys, mid + 1, node.keys.length())
  let right_children = array_slice(node.children, mid + 1, node.children.length())
  let left_keys = array_slice(node.keys, 0, mid)
  let left_children = array_slice(node.children, 0, mid + 1)
  (Internal(InternalNode::{ keys: left_keys, children: left_children }), mid_key, Internal(InternalNode::{ keys: right_keys, children: right_children }))
}

/// 范围扫描：返回 [start, end] 范围内的所有行
pub fn BTree::range(self : BTree, start : Int, end : Int) -> Array[@types.Row] {
  let result : Array[@types.Row] = []
  let mut node = self.root
  // 找到最左边的叶子
  while true {
    match node {
      Leaf(_) => break
      Internal(internal) => { node = internal.children[0] }
    }
  }
  // 遍历叶子链表
  while true {
    match node {
      Leaf(leaf) => {
        for i = 0; i < leaf.keys.length(); i = i + 1 {
          let k = leaf.keys[i]
          if k >= start && k <= end {
            result.push(leaf.values[i])
          }
          if k > end { return result }
        }
        match leaf.next {
          Some(next) => { node = next }
          None => break
        }
      }
      _ => break
    }
  }
  result
}

/// 获取所有键（用于测试和调试）
pub fn BTree::all_keys(self : BTree) -> Array[Int] {
  let result : Array[Int] = []
  let mut node = self.root
  while true {
    match node {
      Leaf(_) => break
      Internal(internal) => { node = internal.children[0] }
    }
  }
  while true {
    match node {
      Leaf(leaf) => {
        for i = 0; i < leaf.keys.length(); i = i + 1 {
          result.push(leaf.keys[i])
        }
        match leaf.next {
          Some(next) => { node = next }
          None => break
        }
      }
      _ => break
    }
  }
  result
}
