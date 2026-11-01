# QuickJS 调度与二进制传输基线

本记录依据 `lib/services/quickjs_bridge_service.dart` 和项目当前解析的 `flutter_js 0.8.7` 源码，记录 2026-11-01 的实现约束，并附本机测试模式下的一次完整传输基准。结果只适用于所列环境与测量方式。

## 完成事件与微任务调度

`ToolboxChannel_Done` 在插件包装函数完成后发送最终结果，由 Dart `Completer` 接收，已经替代了旧版反复求值 `window.__runFinished` 的完成状态查询。但执行器仍在等待结果时，每隔 5ms 调用一次 `executePendingJob()`。因此当前实现有定时唤醒，不能据此声称“完全事件驱动”或“等待时 CPU 为零”。

当前 Windows / Android 的 QuickJsRuntime2 在 `evaluate()` 后不会自动排空 Promise jobs。宿主已在首次脚本求值和异步 Bridge 完成后手动排空队列；依赖内置的 `setTimeout` 只在 Dart Timer 到期时求值 JS 回调，不会随后排空 Promise jobs。直接删除 5ms 循环、只等待完成事件，会让 `await new Promise(resolve => setTimeout(resolve, 10))` 的后续逻辑无法继续。

若后续改为真正由事件触发的调度，需要同时处理：

- 首次求值、每次异步宿主完成和每次定时器回调之后的微任务排空；不能用 `executePendingJob()` 的返回值推断是否空闲，当前 QuickJsRuntime2 固定返回 `0`。
- 每次执行独立的生命周期状态；取消后关闭请求、清理受控计时器，并阻止迟到回调再次调用旧 runtime。当前依赖并不跟踪、取消它创建的 Dart Timer。
- 避免旧执行的清理覆盖新执行的静态状态。目前 `killCurrentExecution()` 的取消是协作式的，不能保证中止占据同一 isolate 的纯同步无限 JS 循环。

依赖已有的 `SetTimeout` 通道不能通过再次注册同名 `onMessage` 来覆盖；QuickJsRuntime2 会拒绝重复注册。若在项目内接管定时器，应使用新的宿主通道及受控 JS 定时器包装，或单独评估依赖适配。

新增的调度回归覆盖已完成 Promise、定时器后的 `.then()`、嵌套定时器、定时器拒绝、未决 Promise 的显式取消以及下一次执行恢复。取消用例刻意不留下依赖自建的 Timer：取消后迟到的 Timer / HTTP 回调与并发执行隔离仍需要运行时生命周期改造和专门测试，不能由当前用例推断已经安全。

## 二进制接口契约与复制路径

| API | 同步返回值 | 当前传输路径 |
| --- | --- | --- |
| `Toolbox.fs.readBytes(path)` / `readFile(path, true)` | Base64 `string` | Dart 整文件读取 → Base64 → JSON/JS 求值 → JS 字符串 |
| `Toolbox.fs.readBinary(path)` | `Uint8Array` | 与 Base64 读取相同，再由 JS 解码并分配字节数组 |
| `Toolbox.fs.writeFile(path, base64, true)` | `true` | JS 字符串 → JSON 宿主桥 → Dart Base64 解码 → 文件 |
| `Toolbox.fs.writeBinary(path, bytes)` | `true` | JS 字节数组 → Base64 → JSON 宿主桥 → Dart Base64 解码 → 文件 |

长度为 `n` 的二进制内容，Base64 字符数为 `4 * ceil(n / 3)`，编码体积约增加三分之一；这不是进程峰值内存估算，因为同时还可能存在原始字节、字符串、JSON 和解码数组等副本。给同步文件调用添加 `await` 不会使其在后台执行。

大文件优先通过文件路径交给图像、归档或 WASM 原生管道。`flutter_js` 的底层桥虽有 `Uint8List` / ArrayBuffer 转换能力，但实现仍包含内存复制；它不能直接作为零拷贝方案宣传。若以后使用专门的二进制通道，应保留 `readBytes` 的 Base64 契约，验证平台兼容性、错误处理和数据生命周期，再比较性能。

## 手动基准

`tools/quickjs_transfer_benchmark.dart` 不在默认测试目录中。它创建 1 / 10 / 50 MiB 的确定性文件，分别执行以下完整往返，并在 Dart 端对源文件和产物流式计算 SHA-256，验证字节一致性：

1. `readBytes` → Base64 字符串 → `writeFile(..., true)`。
2. `readBinary` → `Uint8Array` → `writeBinary`。

在客户端根目录手动执行：

```powershell
flutter test tools/quickjs_transfer_benchmark.dart --reporter expanded --concurrency=1
```

只运行较小输入进行冒烟检查：

```powershell
flutter test tools/quickjs_transfer_benchmark.dart --reporter expanded --concurrency=1 --dart-define=QUICKJS_BENCHMARK_SIZES=1
```

输出每个场景的 JSON 记录，包含宿主完整执行耗时、JS 内部同步读取和写入耗时、运行前后进程 RSS 以及进程累计最大 RSS。完整耗时包含 runtime 初始化、宿主桥、结果处理与产物扫描，排除文件生成和 SHA-256 验证；JS `Date.now()` 只有毫秒精度。RSS 前后值是快照，`maxRss` 是整个测试进程的累计峰值，并非当前场景独立峰值；测试模式、OS 缓存、执行顺序与前一场景 GC 都会影响结果。

基准强制要求原生 QuickJS 成功加载并完成基础求值，不会在缺少原生库时静默通过。每个大小和路径只测一次、顺序固定，不作为 CI 耗时门槛，也不直接代表 Release 客户端性能。正式比较应在相同环境下多次运行、交换场景顺序，并用独立进程/性能分析器采集峰值内存和 CPU。50 MiB 输入可能产生显著瞬时内存使用，先从 1 MiB 验证环境。

## 本机测量：2026-11-01

2026-11-01 18:15（UTC+08:00）在 Windows 11 家庭版 `10.0.26300`、Intel Core i7-12650H（10 核 / 16 线程）、15.78 GiB 内存上执行上述完整命令。Flutter `3.47.7` stable、Dart `3.13.5`、`flutter_js 0.8.7`；使用 `flutter test` 的宿主测试模式，未编译 Release 应用。原生引擎探测成功，整个基准约 43 秒结束，结果为 `All tests passed`。

“完整耗时”对应 `QuickJsBridgeService.execute`；读写列为 JS 内部时间。RSS 统一换算为 MiB（1,048,576 字节），累计峰值属于整个测试进程。

| 输入 MiB | 往返路径 | 完整耗时 ms | JS 读 ms | JS 写 ms | RSS 前 MiB | RSS 后 MiB | 进程累计峰值 MiB |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | Base64 | 60.278 | 26 | 20 | 215.9 | 230.9 | 233.0 |
| 1 | readBinary | 803.036 | 284 | 515 | 232.2 | 220.5 | 251.0 |
| 10 | Base64 | 322.059 | 179 | 138 | 240.9 | 246.5 | 345.1 |
| 10 | readBinary | 6692.187 | 2557 | 4130 | 251.2 | 253.5 | 365.9 |
| 50 | Base64 | 1635.213 | 863 | 766 | 262.2 | 396.5 | 816.0 |
| 50 | readBinary | 32105.298 | 12573 | 19525 | 400.4 | 403.1 | 915.9 |

六个产物的长度与 SHA-256 均与对应源文件一致；每个文件由 `0x00` 至 `0xff` 重复填充，两个传输路径得到相同散列：

| 输入 MiB | SHA-256 |
| --- | --- |
| 1 | `fbbab289f7f94b25736c58be46a994c441fd02552cc6022352e3d86d2fab7c83` |
| 10 | `aecf3c2ab8aca74852bca07b54136cecb3fdafdc35540068ed952c0b89538e0d` |
| 50 | `624bbe3f61588f97cfaad1af50360bb8c5fc94774d3c15dbf471dcd42b9bea8e` |

本次 `readBinary` / `writeBinary` 往返比 Base64 字符串直接往返耗时明显更高；该路径额外执行 JS Base64 解码与编码，表中 JS 读写时间显示了此成本。50 MiB 输入在该路径耗时约 32.11 秒，说明它适合需要在 JS 内访问字节的场景，大文件透传应优先使用文件路径管道。这里未隔离其他测试或系统负载、未做独立预热或重复采样，也未测 CPU、Android 或 Release；累计 915.9 MiB 峰值不能解释为单个文件所需内存，更不能视为稳定的跨设备性能指标。
