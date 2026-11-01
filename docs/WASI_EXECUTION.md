# WASI CLI 日志与生命周期

`WasmUniversalService` 的 `wasi_cli` 模式使用
`lib/services/native_wasi_runner.dart` 管理原生实例：

1. 编译模块，配置 WASI 挂载、参数与环境变量。
2. 同时订阅 stdout/stderr，等待两路原生输出通道注册完成。
3. 实例化模块，执行无参 `_start`，或回退到 `_initialize`。
4. 无论正常返回、`proc_exit` 还是 trap，都释放原生实例。
5. 等待两路输出流关闭后解码完整 UTF-8，交给日志和执行报告。

程序结束后的日志收集依赖原生 EOF，不再使用 300 毫秒静默超时；
stdout 与 stderr 各自保持顺序，不保证两路之间的交错顺序。
`proc_exit(0)` 视为成功，非零退出和 trap 保留此前输出并报告错误。

## 依赖边界

`wasm_run 0.2.0+2` 的高层 `build()` 在构造实例时自动执行入口，
但生成的 `stdioStream()` 丢弃了异步注册的完成 Future，存在首条日志丢失的竞争。
高层输出流又是广播流，先完整读取 stdout 再读取 stderr 会丢失错误日志。

当前适配层复用该依赖已有的原生调用，保留注册 Future，并显式执行入口。
没有修改依赖缓存或原生 ABI。由于使用生成接口，`wasm_run` 固定在 `0.2.0+2`，
`flutter_rust_bridge` 保持已有的 `2.12.0` 覆盖配置。升级这些依赖时须检查适配层；
上游提供可等待的输出注册和显式入口接口后，可移除此适配层。
其他 WASM 函数调用与内存流模式保持原有执行路径。
原生库在实例化时持有全局写锁，因此 WASM start section 中的标准输出调用
仍有重入锁限制；CLI 应从导出的 `_start` 或 `_initialize` 输出日志。

## 回归验证

`test/wasm_engine_test.dart` 覆盖重复执行时双路多段日志、退出码 0/7、
trap 前输出、两类入口、跨段 UTF-8、空错误流，以及执行后释放 Windows 目录句柄。
原有 WASI 磁盘写入、参数、插件目录挂载与批处理测试继续保留。
