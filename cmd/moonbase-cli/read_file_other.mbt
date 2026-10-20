// 在非 js 后端（native / wasm 等）提供占位实现：
// 命令行工具依赖 Node 的文件系统，因此仅 js 后端真正可用。
// 这里给出清晰的错误，保证 `moon build` 在默认后端也能通过编译。
fn read_file(_path : String) -> Bytes {
  abort(
    "read_file 仅在 js 后端（node）下可用；请用 `moon build --target js` 构建后通过 node 运行",
  )
}
