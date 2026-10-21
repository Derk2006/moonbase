// 仅在 js 后端（node）编译：通过 Node 的 fs 模块读取 / 写入二进制文件。
extern "js" fn read_file(path : String) -> Bytes =
  "(p) => new Uint8Array(require('fs').readFileSync(p))"

extern "js" fn write_file(path : String, data : Bytes) -> Unit =
  "(p, d) => require('fs').writeFileSync(p, Buffer.from(d))"
