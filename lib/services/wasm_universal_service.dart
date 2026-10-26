import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
// ignore: implementation_imports
import 'package:wasm_run/src/rust/api.dart' show parseWatFormat;
import 'package:wasm_run/wasm_run.dart';
import 'tool_engine_service.dart';

/// WebAssembly 模块导出的条目信息
class WasmExportInfo {
  final String name;
  final String type; // func, memory, table, global
  final List<String> paramTypes;
  final List<String> returnTypes;

  WasmExportInfo({
    required this.name,
    required this.type,
    this.paramTypes = const [],
    this.returnTypes = const [],
  });

  Map<String, dynamic> toJson() => {
    'name': name,
    'type': type,
    if (paramTypes.isNotEmpty) 'params': paramTypes,
    if (returnTypes.isNotEmpty) 'returns': returnTypes,
  };
}

/// WebAssembly 模块导入的条目信息
class WasmImportInfo {
  final String module;
  final String name;
  final String type;

  WasmImportInfo({
    required this.module,
    required this.name,
    required this.type,
  });

  Map<String, dynamic> toJson() => {
    'module': module,
    'name': name,
    'type': type,
  };
}

/// WebAssembly 模块检查报告
class WasmInspectionReport {
  final int byteLength;
  final List<WasmExportInfo> exports;
  final List<WasmImportInfo> imports;
  final bool hasWasi;
  final bool hasMemory;
  final bool hasStart;

  WasmInspectionReport({
    required this.byteLength,
    required this.exports,
    required this.imports,
    required this.hasWasi,
    required this.hasMemory,
    this.hasStart = false,
  });

  Map<String, dynamic> toJson() => {
    'byteLength': byteLength,
    'hasWasi': hasWasi,
    'hasMemory': hasMemory,
    'hasStart': hasStart,
    'exports': exports.map((e) => e.toJson()).toList(),
    'imports': imports.map((i) => i.toJson()).toList(),
  };
}

/// 预打开虚拟目录挂载信息
class WasmDirectoryMapping {
  final String hostPath;
  final String wasmGuestPath;

  const WasmDirectoryMapping({
    required this.hostPath,
    required this.wasmGuestPath,
  });

  Map<String, dynamic> toJson() => {
    'hostPath': hostPath,
    'wasmGuestPath': wasmGuestPath,
  };
}

/// 跨平台 WebAssembly (WASM) 微内核解释与沙箱调度服务
/// 统一调度 C/C++/Rust 编译的 .wasm 与 .wat 二进制/文本字节码模块
/// 深度打通 WASI 虚拟文件系统 (VFS) 磁盘映射、标准 CLI 调度与内存流式管道
class WasmUniversalService {
  static bool _initialized = false;

  /// 内置的高性能数学与算法演示 WAT 源码 (包含加法与斐波那契数列高效递归)
  static const String builtinDemoWat = r'''
(module
  (func $add (export "add") (param i32 i32) (result i32)
    local.get 0
    local.get 1
    i32.add
  )
  (func $fib (export "fib") (param i32) (result i32)
    local.get 0
    local.get 1
    i32.lt_s
    if (result i32)
      local.get 0
    else
      local.get 0
      i32.const 1
      i32.sub
      call $fib
      local.get 0
      i32.const 2
      i32.sub
      call $fib
      i32.add
    end
  )
  (func $square (export "square") (param i32) (result i32)
    local.get 0
    local.get 0
    i32.mul
  )
)
''';

  /// 内置预编译好的纯正 WASM 二进制字节码 (包含 add、递归 fib、square 算法，零等待、零编译)
  static final Uint8List builtinDemoWasmBytes = Uint8List.fromList([
    0, 97, 115, 109, 1, 0, 0, 0, 1, 12, 2, 96, 2, 127, 127, 1, 127, 96, 1, 127, 1, 127, 3, 4, 3, 0, 1, 1, 7, 22, 3, 3, 97, 100, 100, 0, 0, 3, 102, 105, 98, 0, 1, 6, 115, 113, 117, 97, 114, 101, 0, 2, 10, 46, 3, 7, 0, 32, 0, 32, 1, 106, 11, 28, 0, 32, 0, 65, 2, 72, 4, 127, 32, 0, 5, 32, 0, 65, 1, 107, 16, 1, 32, 0, 65, 2, 107, 16, 1, 106, 11, 11, 7, 0, 32, 0, 32, 0, 108, 11, 0, 26, 4, 110, 97, 109, 101, 1, 19, 3, 0, 3, 97, 100, 100, 1, 3, 102, 105, 98, 2, 6, 115, 113, 117, 97, 114, 101
  ]);

  /// 内置 WASI CLI 演示模块：演示从 WASI 标准输出流实时回传日志，并在虚拟挂载输出目录下安全创建落盘文件
  static const String builtinDemoWasiWat = r'''
(module
  (import "wasi_snapshot_preview1" "fd_write"
    (func $fd_write (param i32 i32 i32 i32) (result i32))
  )
  (import "wasi_snapshot_preview1" "path_open"
    (func $path_open (param i32 i32 i32 i32 i32 i64 i64 i32 i32) (result i32))
  )
  (import "wasi_snapshot_preview1" "fd_close"
    (func $fd_close (param i32) (result i32))
  )
  (memory (export "memory") 1)
  ;; 文件名位于 100: "wasi_output_demo.txt" (len=20)
  (data (i32.const 100) "wasi_output_demo.txt")
  ;; 文件内容与终端日志位于 200 (len=97)
  (data (i32.const 200) "[WASI VFS Engine] Success! WebAssembly wrote this file directly into host disk output directory.\n")
  ;; iovec 结构体位于 400: ptr=200, len=97 (0x61)
  (data (i32.const 400) "\c8\00\00\00\61\00\00\00")
  (func (export "_start")
    (local $fd i32)
    ;; 1. 打印问候到 stdout (fd=1)
    (call $fd_write (i32.const 1) (i32.const 400) (i32.const 1) (i32.const 300))
    drop
    ;; 2. 打开/创建 /output 目录中的 wasi_output_demo.txt (fd=3 为第一个 preopened 目录)
    (call $path_open
      (i32.const 3)
      (i32.const 0)
      (i32.const 100)
      (i32.const 20)
      (i32.const 9) ;; creat | trunc
      (i64.const 268435455)
      (i64.const 268435455)
      (i32.const 0)
      (i32.const 352)
    )
    drop
    (local.set $fd (i32.load (i32.const 352)))
    ;; 3. 向新创建的文件写入内容
    (call $fd_write (local.get $fd) (i32.const 400) (i32.const 1) (i32.const 300))
    drop
    ;; 4. 安全关闭文件句柄
    (call $fd_close (local.get $fd))
    drop
  )
)
''';

  /// 内置内存流式处理演示模块：将输入缓冲区中的 ASCII 字符在 WASM 内存中极速转换为大写并写回
  static const String builtinDemoMemoryWat = r'''
(module
  (memory (export "memory") 2)
  (func (export "malloc") (param $size i32) (result i32)
    (i32.const 1024)
  )
  (func (export "process") (param $ptr i32) (param $len i32) (result i32)
    (local $i i32)
    (local $curr i32)
    (local.set $i (i32.const 0))
    (block $break
      (loop $loop
        (br_if $break (i32.ge_u (local.get $i) (local.get $len)))
        (local.set $curr (i32.add (local.get $ptr) (local.get $i)))
        (if (i32.and
              (i32.ge_u (i32.load8_u (local.get $curr)) (i32.const 97))
              (i32.le_u (i32.load8_u (local.get $curr)) (i32.const 122)))
          (then
            (i32.store8 (local.get $curr)
              (i32.sub (i32.load8_u (local.get $curr)) (i32.const 32))
            )
          )
        )
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $loop)
      )
    )
    (local.get $ptr)
  )
  (func (export "get_output_len") (result i32)
    (i32.const 0)
  )
)
''';

  /// 确保底座宿主 Native 库 (`wasm_run_dart.dll` / `libwasm_run_dart.so`) 绑定就绪
  static Future<void> ensureInitialized() async {
    if (_initialized) return;
    try {
      if (Platform.isWindows) {
        final exeDir = File(Platform.resolvedExecutable).parent.path;
        final candidate1 = p.join(exeDir, 'wasm_run_dart.dll');
        final candidate2 = 'wasm_run_dart.dll';
        if (File(candidate1).existsSync()) {
          await WasmRunLibrary.setUp(lib: ExternalLibrary.open(candidate1));
        } else if (File(candidate2).existsSync()) {
          await WasmRunLibrary.setUp(lib: ExternalLibrary.open(File(candidate2).absolute.path));
        } else {
          await WasmRunLibrary.setUp();
        }
      } else if (Platform.isAndroid) {
        try {
          await WasmRunLibrary.setUp(lib: ExternalLibrary.open('libwasm_run_dart.so'));
        } catch (_) {
          try {
            await WasmRunLibrary.setUp(lib: ExternalLibrary.process(iKnowHowToUseIt: true));
          } catch (_) {
            await WasmRunLibrary.setUp();
          }
        }
      } else {
        await WasmRunLibrary.setUp();
      }
      _initialized = true;
    } catch (e) {
      if (e.toString().contains('already configured') || e.toString().contains('already initialized')) {
        _initialized = true;
        return;
      }
      debugPrint('WasmUniversalService 初始化注意: $e');
      throw Exception('WebAssembly (WASM) 底层运行时初始化失败: $e');
    }
  }

  /// 将可能为 `.wat` 文本或 `.wasm` 二进制的数据标准化解析为二进制字节流
  static Future<Uint8List> resolveBytes(dynamic source) async {
    // 1. 如果传入的是内置演示 WAT 代码，直接返回预编译好的 WASM 二进制字节流，零等待、零依赖
    if (source == builtinDemoWat || source == 'builtin' || source == null) {
      return builtinDemoWasmBytes;
    }
    if (source == 'builtin_wasi' || source == builtinDemoWasiWat) {
      await ensureInitialized();
      return await parseWatFormat(wat: builtinDemoWasiWat);
    }
    if (source == 'builtin_memory' || source == builtinDemoMemoryWat) {
      await ensureInitialized();
      return await parseWatFormat(wat: builtinDemoMemoryWat);
    }

    if (source is Uint8List) {
      // 检查是否为 WASM 魔数 (\0asm = 0x00, 0x61, 0x73, 0x6d)
      if (source.length >= 4 &&
          source[0] == 0x00 &&
          source[1] == 0x61 &&
          source[2] == 0x73 &&
          source[3] == 0x6d) {
        return source;
      }
      final text = utf8.decode(source, allowMalformed: true);
      if (text.trim() == builtinDemoWat.trim()) {
        return builtinDemoWasmBytes;
      }
      await ensureInitialized();
      return await parseWatFormat(wat: text);
    } else if (source is String) {
      if (source.trim() == builtinDemoWat.trim()) {
        return builtinDemoWasmBytes;
      }
      final file = File(source);
      if (file.existsSync()) {
        final bytes = file.readAsBytesSync();
        if (bytes.length >= 4 &&
            bytes[0] == 0x00 &&
            bytes[1] == 0x61 &&
            bytes[2] == 0x73 &&
            bytes[3] == 0x6d) {
          return bytes;
        }
        if (source.toLowerCase().endsWith('.wat')) {
          final text = file.readAsStringSync();
          await ensureInitialized();
          return await parseWatFormat(wat: text);
        }
        return bytes;
      }
      // 纯字符串作为 WAT 源码即时编译
      await ensureInitialized();
      return await parseWatFormat(wat: source);
    }
    throw ArgumentError('未知的 WASM 源码类型: $source');
  }

  /// 深入分析并逆向提取 WASM 模块结构清单
  static Future<WasmInspectionReport> inspect(dynamic source) async {
    final bytes = await resolveBytes(source);
    final module = await compileWasmModule(bytes);

    final exportList = <WasmExportInfo>[];
    for (final exp in module.getExports()) {
      final pTypes = <String>[];
      final rTypes = <String>[];
      if (exp.type is ExternalType_Func) {
        final f = (exp.type as ExternalType_Func).field0;
        pTypes.addAll(f.parameters.map((v) => v.name));
        rTypes.addAll(f.results.map((v) => v.name));
      }
      exportList.add(WasmExportInfo(
        name: exp.name,
        type: exp.type.runtimeType.toString().replaceAll('ExternalType_', '').toLowerCase(),
        paramTypes: pTypes,
        returnTypes: rTypes,
      ));
    }

    final importList = <WasmImportInfo>[];
    bool hasWasi = false;
    bool hasMemory = exportList.any((e) => e.type == 'memory');
    bool hasStart = exportList.any((e) => e.name == '_start');

    for (final imp in module.getImports()) {
      if (imp.module.startsWith('wasi_') || imp.module == 'wasi') {
        hasWasi = true;
      }
      importList.add(WasmImportInfo(
        module: imp.module,
        name: imp.name,
        type: imp.type.runtimeType.toString().replaceAll('ExternalType_', '').toLowerCase(),
      ));
    }

    return WasmInspectionReport(
      byteLength: bytes.length,
      exports: exportList,
      imports: importList,
      hasWasi: hasWasi,
      hasMemory: hasMemory,
      hasStart: hasStart,
    );
  }

  /// 解析命令行参数（支持列表或字符串输入、双引号分割，以及表单变量与文件占位符替换）
  static List<String> parseCliArgs(
    dynamic rawArgs, {
    Map<String, dynamic> formValues = const {},
    Map<String, String> replacements = const {},
  }) {
    List<String> rawTokens = [];
    if (rawArgs is List) {
      rawTokens = rawArgs.map((e) => e.toString()).toList();
    } else if (rawArgs is String) {
      final str = rawArgs.trim();
      if (str.isEmpty) return [];
      final sb = StringBuffer();
      bool inQuote = false;
      String quoteChar = '';

      for (int i = 0; i < str.length; i++) {
        final c = str[i];
        if ((c == '"' || c == "'") && !inQuote) {
          inQuote = true;
          quoteChar = c;
        } else if (c == quoteChar && inQuote) {
          inQuote = false;
          quoteChar = '';
        } else if (c == ' ' && !inQuote) {
          if (sb.isNotEmpty) {
            rawTokens.add(sb.toString());
            sb.clear();
          }
        } else {
          sb.write(c);
        }
      }
      if (sb.isNotEmpty) {
        rawTokens.add(sb.toString());
      }
    }

    final result = <String>[];
    for (var token in rawTokens) {
      String resolved = token;

      // 第一级替换：表单控件变量 ${key} 或 {key}
      formValues.forEach((key, val) {
        if (val is List) {
          resolved = resolved.replaceAll('\${$key}', val.join(';'));
          resolved = resolved.replaceAll('{$key}', val.join(';'));
        } else if (val != null) {
          resolved = resolved.replaceAll('\${$key}', val.toString());
          resolved = resolved.replaceAll('{$key}', val.toString());
        }
      });

      // 如果需要多输入文件展开为多个参数: {inputs} 或 {inputFiles}
      if (resolved == '{inputs}' || resolved == '{inputFiles}') {
        final multi = replacements[resolved] ?? replacements['{inputs}'] ?? '';
        if (multi.isNotEmpty) {
          result.addAll(multi.split(' ').where((s) => s.isNotEmpty));
          continue;
        }
      }

      // 第二级替换：沙箱路径与环境占位符 {input}, {outputDir}, {output} 等
      replacements.forEach((key, val) {
        resolved = resolved.replaceAll(key, val);
      });
      result.add(resolved);
    }
    return result;
  }

  /// 构造宿主真实文件系统到 WASI 虚拟沙箱 (VFS) 的完整映射配置
  static WasiConfig buildWasiConfig({
    required String outputDir,
    List<String> inputFiles = const [],
    List<String> cliArgs = const [],
    Map<String, String> env = const {},
    String? pluginDirectory,
    List<PreopenedDir> additionalDirs = const [],
    bool captureStdout = true,
    bool captureStderr = true,
  }) {
    final outDir = Directory(outputDir);
    if (!outDir.existsSync()) {
      outDir.createSync(recursive: true);
    }

    final preopenedDirs = <PreopenedDir>[
      // 1. 宿主输出目录映射为沙箱中的 /output
      PreopenedDir(
        hostPath: outDir.path,
        wasmGuestPath: '/output',
      ),
      // 2. 宿主输出目录同时映射为沙箱工作区根目录 . (便于直接处理相对路径 fopen("output.ext", "w"))
      PreopenedDir(
        hostPath: outDir.path,
        wasmGuestPath: '.',
      ),
    ];

    // 3. 宿主输入文件目录映射为沙箱中的 /input
    if (inputFiles.isNotEmpty) {
      final parentPaths = <String>{};
      for (int i = 0; i < inputFiles.length; i++) {
        final pPath = File(inputFiles[i]).parent.path;
        if (!parentPaths.contains(pPath)) {
          parentPaths.add(pPath);
          final guestPath = parentPaths.length == 1 ? '/input' : '/input_${parentPaths.length - 1}';
          preopenedDirs.add(PreopenedDir(
            hostPath: pPath,
            wasmGuestPath: guestPath,
          ));
        }
      }
    }

    // 4. 插件安装根目录虚拟映射为 /plugin (支持读取插件内置的静态资产、模型权重与配置)
    if (pluginDirectory != null && pluginDirectory.isNotEmpty) {
      final pDir = Directory(pluginDirectory);
      if (pDir.existsSync()) {
        preopenedDirs.add(PreopenedDir(
          hostPath: pDir.path,
          wasmGuestPath: '/plugin',
        ));
      }
    }

    // 5. 系统临时目录映射为沙箱中的 /tmp
    preopenedDirs.add(PreopenedDir(
      hostPath: Directory.systemTemp.path,
      wasmGuestPath: '/tmp',
    ));

    // 6. 补充额外目录
    preopenedDirs.addAll(additionalDirs);

    // 构造环境变量
    final envVars = <EnvVariable>[
      const EnvVariable(name: 'PATH', value: '/output:/input:/plugin:/bin'),
      const EnvVariable(name: 'TEMP', value: '/tmp'),
      const EnvVariable(name: 'TMP', value: '/tmp'),
      ...env.entries.map((e) => EnvVariable(name: e.key, value: e.value)),
    ];

    return WasiConfig(
      captureStdout: captureStdout,
      captureStderr: captureStderr,
      inheritStdin: false,
      inheritEnv: false,
      inheritArgs: false,
      args: cliArgs,
      env: envVars,
      preopenedDirs: preopenedDirs,
      webBrowserFileSystem: const {},
    );
  }

  /// 从 WASI 标准流读取捕获到的完整输出内容
  static Future<String> _captureStream(
    Stream<Uint8List> stream, {
    Duration timeout = const Duration(milliseconds: 300),
  }) async {
    final buffer = BytesBuilder();
    try {
      await for (final chunk in stream.timeout(timeout)) {
        buffer.add(chunk);
      }
    } catch (_) {}
    return utf8.decode(buffer.takeBytes(), allowMalformed: true);
  }

  /// 在 WASM 沙箱中调用指定导出函数 (支持自动注入 WASI 运行时上下文)
  static Future<Map<String, dynamic>> callFunction({
    required dynamic source,
    required String functionName,
    List<dynamic> arguments = const [],
    WasiConfig? wasiConfig,
  }) async {
    final bytes = await resolveBytes(source);
    final module = await compileWasmModule(bytes);
    final instance = await module.builder(wasiConfig: wasiConfig).build();

    final func = instance.getFunction(functionName);
    if (func == null) {
      final available = module.getExports().map((e) => e.name).toList();
      throw StateError('未在 WASM 模块中找到导出函数: "$functionName"。模块包含可用导出: $available');
    }

    final stopwatch = Stopwatch()..start();
    final callRes = func(arguments);
    stopwatch.stop();

    return {
      'function': functionName,
      'arguments': arguments,
      'result': callRes,
      'elapsedMicroseconds': stopwatch.elapsedMicroseconds,
      'elapsedMilliseconds': stopwatch.elapsedMilliseconds,
    };
  }

  /// 执行单次 WASI 实例
  static Future<({List<String> generatedFiles, String stdout, String stderr, bool success, String? error})> _runSingleWasiInstance({
    required Uint8List wasmBytes,
    required List<String> currentInputs,
    required String outputDir,
    String? pluginDirectory,
    required List<String> cliArgs,
    Map<String, String> env = const {},
    void Function(String line, bool isError)? onLog,
  }) async {
    final outDir = Directory(outputDir);
    if (!outDir.existsSync()) outDir.createSync(recursive: true);

    final beforeFiles = outDir.listSync(recursive: true).whereType<File>().map((f) => f.path).toSet();

    final wasiConfig = buildWasiConfig(
      outputDir: outputDir,
      inputFiles: currentInputs,
      cliArgs: cliArgs,
      env: env,
      pluginDirectory: pluginDirectory,
    );

    String stdoutText = '';
    String stderrText = '';
    String? executionError;

    try {
      final module = await compileWasmModule(wasmBytes);
      final instance = await module.builder(wasiConfig: wasiConfig).build();

      stdoutText = await _captureStream(instance.stdout);
      stderrText = await _captureStream(instance.stderr);
    } catch (e) {
      final errStr = e.toString().toLowerCase();
      // 容错处理：WASI 应用调用 proc_exit(0) 时捕获的退出状态码视同正常退出
      if (errStr.contains('exit status 0') || (errStr.contains('status 0') || (errStr.contains('exit') && errStr.contains(' 0')))) {
        // 正常退出码 0
      } else {
        executionError = e.toString();
      }
    }

    if (stdoutText.trim().isNotEmpty && onLog != null) {
      for (final line in stdoutText.trim().split('\n')) {
        onLog('    $line', false);
      }
    }
    if (stderrText.trim().isNotEmpty && onLog != null) {
      for (final line in stderrText.trim().split('\n')) {
        onLog('    $line', true);
      }
    }

    final afterFiles = outDir.listSync(recursive: true).whereType<File>().toList();
    final newlyGenerated = afterFiles.where((f) => !beforeFiles.contains(f.path)).map((f) => f.path).toList();

    return (
      generatedFiles: newlyGenerated,
      stdout: stdoutText,
      stderr: stderrText,
      success: executionError == null,
      error: executionError,
    );
  }

  /// WASI CLI 命令行应用执行管道 (支持多文件批处理循环调度与 VFS 目录映射)
  static Future<ProcessingResult> _executeWasiCli({
    required dynamic source,
    required Uint8List wasmBytes,
    required String moduleTitle,
    required WasmInspectionReport report,
    required List<String> inputFiles,
    required String outputDir,
    String? pluginDirectory,
    required Map<String, dynamic> formValues,
    void Function(double progress, String stage)? onProgress,
    void Function(String line, bool isError)? onLog,
  }) async {
    onProgress?.call(0.1, '正在配置 WASI 虚拟沙箱文件系统...');

    final rawArgs = formValues['cliArgsList'] ??
        formValues['cliArgs'] ??
        formValues['args'] ??
        formValues['functionArgs'] ??
        '';

    final rawArgsStr = rawArgs is List ? rawArgs.join(' ') : rawArgs.toString();
    final bool hasMultiToken = rawArgsStr.contains('{inputs}') || rawArgsStr.contains('{inputFiles}');

    // 是否启用批处理模式：
    // 当存在多个输入文件，且清单配置了 batchMode != false，且参数未显式声明全量展开时，启动批处理调度循环
    final bool explicitBatch = formValues['batchMode'] == true || formValues['batchMode'] == 'true';
    final bool autoBatch = inputFiles.length > 1 && !hasMultiToken;
    final bool shouldBatch = (explicitBatch || autoBatch) && inputFiles.length > 1;

    final allGeneratedFiles = <String>[];
    final allStdout = StringBuffer();
    final allStderr = StringBuffer();

    final stopwatch = Stopwatch()..start();

    if (shouldBatch) {
      onLog?.call('【WASI 批处理调度启动】检测到 ${inputFiles.length} 个输入文件，自动启动逐文件循环调度', false);

      for (int i = 0; i < inputFiles.length; i++) {
        final currentFile = inputFiles[i];
        final fileName = p.basename(currentFile);
        final progress = (i / inputFiles.length) * 0.9 + 0.05;
        onProgress?.call(progress, '正在处理 (${i + 1}/${inputFiles.length}): $fileName');
        onLog?.call('>>> 正在调度第 ${i + 1}/${inputFiles.length} 个任务: $fileName', false);

        final replacements = <String, String>{
          '{outputDir}': '/output',
          '{output_dir}': '/output',
          '{tmp}': '/tmp',
          '{pluginDir}': '/plugin',
          '{input}': '/input/$fileName',
          '{input_file}': '/input/$fileName',
          '{input_name}': fileName,
          '{input_base}': p.basenameWithoutExtension(fileName),
          '{output}': '/output/${p.basenameWithoutExtension(fileName)}_out${p.extension(fileName)}',
        };

        final cliArgs = parseCliArgs(
          rawArgs,
          formValues: formValues,
          replacements: replacements,
        );

        final runRes = await _runSingleWasiInstance(
          wasmBytes: wasmBytes,
          currentInputs: [currentFile],
          outputDir: outputDir,
          pluginDirectory: pluginDirectory,
          cliArgs: cliArgs.isNotEmpty ? cliArgs : [moduleTitle, '/input/$fileName'],
          onLog: onLog,
        );

        allGeneratedFiles.addAll(runRes.generatedFiles);
        if (runRes.stdout.isNotEmpty) allStdout.writeln(runRes.stdout);
        if (runRes.stderr.isNotEmpty) allStderr.writeln(runRes.stderr);

        if (!runRes.success) {
          onLog?.call('>>> 警告: 文件 $fileName 处理时发生异常: ${runRes.error}', true);
        }
      }
    } else {
      // 单文件或多输入全量展开模式
      final firstInput = inputFiles.isNotEmpty ? inputFiles.first : '';
      final inputsGuestPaths = inputFiles.map((f) => '/input/${p.basename(f)}').join(' ');

      final replacements = <String, String>{
        '{outputDir}': '/output',
        '{output_dir}': '/output',
        '{tmp}': '/tmp',
        '{pluginDir}': '/plugin',
        '{inputs}': inputsGuestPaths,
        '{inputFiles}': inputsGuestPaths,
        if (firstInput.isNotEmpty) ...{
          '{input}': '/input/${p.basename(firstInput)}',
          '{input_file}': '/input/${p.basename(firstInput)}',
          '{input_name}': p.basename(firstInput),
          '{input_base}': p.basenameWithoutExtension(firstInput),
          '{output}': '/output/${p.basenameWithoutExtension(firstInput)}_out${p.extension(firstInput)}',
        } else ...{
          '{input}': '/input/data.bin',
          '{output}': '/output/output_result',
        },
      };

      List<String> cliArgs = [];
      if (rawArgsStr.trim().isNotEmpty) {
        cliArgs = parseCliArgs(rawArgs, formValues: formValues, replacements: replacements);
      } else {
        cliArgs = [
          moduleTitle,
          if (firstInput.isNotEmpty) '/input/${p.basename(firstInput)}',
          '/output/output_result',
        ];
      }

      onLog?.call('【WASI 虚拟沙箱 VFS 映射就绪】', false);
      onLog?.call('  • 宿主输出目录 [$outputDir] -> 沙箱挂载点 [/output] & [.]', false);
      if (inputFiles.isNotEmpty) {
        onLog?.call('  • 宿主输入目录 [${File(firstInput).parent.path}] -> 沙箱挂载点 [/input]', false);
      }
      if (pluginDirectory != null && pluginDirectory.isNotEmpty) {
        onLog?.call('  • 插件内部资产 [$pluginDirectory] -> 沙箱挂载点 [/plugin]', false);
      }
      onLog?.call('  • 沙箱 CLI 执行参数: ${cliArgs.join(' ')}', false);

      onProgress?.call(0.6, '正在 WASM 沙箱中启动并执行应用程序 (_start)...');

      final runRes = await _runSingleWasiInstance(
        wasmBytes: wasmBytes,
        currentInputs: inputFiles,
        outputDir: outputDir,
        pluginDirectory: pluginDirectory,
        cliArgs: cliArgs,
        onLog: onLog,
      );

      allGeneratedFiles.addAll(runRes.generatedFiles);
      allStdout.write(runRes.stdout);
      allStderr.write(runRes.stderr);

      if (!runRes.success) {
        onLog?.call('>>> WASI 执行中断: ${runRes.error}', true);
        return ProcessingResult(
          success: false,
          message: 'WASI 应用程序运行异常: ${runRes.error}',
        );
      }
    }
    stopwatch.stop();

    for (final nf in allGeneratedFiles) {
      onLog?.call('>>> [沙箱文件落盘]: ${p.basename(nf)} (${File(nf).lengthSync()} 字节)', false);
    }

    final outFiles = <String>[...allGeneratedFiles];

    if (formValues['exportJson']?.toString() != 'no') {
      final jsonFile = File(p.join(outputDir, 'wasm_report.json'));
      final payload = {
        'timestamp': DateTime.now().toIso8601String(),
        'moduleName': moduleTitle,
        'executionMode': 'wasi_cli',
        'isBatch': shouldBatch,
        'totalInputs': inputFiles.length,
        'stdout': allStdout.toString(),
        'stderr': allStderr.toString(),
        'elapsedMilliseconds': stopwatch.elapsedMilliseconds,
        'generatedFiles': allGeneratedFiles.map((p) => File(p).uri.pathSegments.last).toList(),
        'inspection': report.toJson(),
      };
      jsonFile.writeAsStringSync(const JsonEncoder.withIndent('  ').convert(payload));
      outFiles.add(jsonFile.path);
    }

    onProgress?.call(1.0, 'WASI 任务执行完成！耗时: ${stopwatch.elapsedMilliseconds} ms');
    return ProcessingResult(
      success: true,
      message: shouldBatch
          ? '批量转换圆满完成！共处理 ${inputFiles.length} 个文件，生成 ${allGeneratedFiles.length} 个产物。'
          : 'WASI 模块执行成功！已通过沙箱虚拟文件系统生成落盘产物。',
      outputFiles: outFiles,
    );
  }

  /// 内存流式处理模式 (将宿主输入文件载入 WASM 内存缓冲区，计算后自动回写落盘)
  static Future<ProcessingResult> _executeMemoryStream({
    required dynamic source,
    required Uint8List wasmBytes,
    required String moduleTitle,
    required WasmInspectionReport report,
    required List<String> inputFiles,
    required String outputDir,
    String? pluginDirectory,
    required Map<String, dynamic> formValues,
    void Function(double progress, String stage)? onProgress,
    void Function(String line, bool isError)? onLog,
  }) async {
    if (inputFiles.isEmpty) {
      return ProcessingResult(
        success: false,
        message: '内存流处理模式需要至少选择一个输入文件作为流数据源。',
      );
    }

    final outDir = Directory(outputDir);
    if (!outDir.existsSync()) outDir.createSync(recursive: true);

    final outFiles = <String>[];
    final stopwatch = Stopwatch()..start();

    for (int i = 0; i < inputFiles.length; i++) {
      final curPath = inputFiles[i];
      final inputFile = File(curPath);
      if (!inputFile.existsSync()) continue;

      final pct = (i / inputFiles.length) * 0.9 + 0.05;
      onProgress?.call(pct, '正在载入并处理 (${i + 1}/${inputFiles.length}): ${p.basename(curPath)}');

      final inputBytes = inputFile.readAsBytesSync();
      onLog?.call('>>> 载入输入流 (${i + 1}/${inputFiles.length}): ${p.basename(curPath)} (${inputBytes.length} 字节)', false);

      final module = await compileWasmModule(wasmBytes);
      final wasiConfig = report.hasWasi
          ? buildWasiConfig(outputDir: outputDir, inputFiles: [curPath], pluginDirectory: pluginDirectory)
          : null;
      final instance = await module.builder(wasiConfig: wasiConfig).build();

      final memory = instance.getMemory('memory');
      if (memory == null) {
        return ProcessingResult(
          success: false,
          message: '该 WebAssembly 模块未导出 memory 线性内存区，无法进行内存流式处理。',
        );
      }

      // 动态扩容内存
      final requiredBytes = inputBytes.length + 8192;
      if (memory.lengthInBytes < requiredBytes) {
        final pagesNeeded = ((requiredBytes - memory.lengthInBytes) + 65535) ~/ 65536;
        memory.grow(pagesNeeded);
      }

      // 申请内存指针
      final mallocFunc = instance.getFunction('malloc') ??
          instance.getFunction('alloc') ??
          instance.getFunction('allocate');
      int inPtr = 1024;
      if (mallocFunc != null) {
        final allocRes = mallocFunc([inputBytes.length]);
        if (allocRes.isNotEmpty && allocRes.first is int) {
          inPtr = allocRes.first as int;
        }
      }

      // 将输入文件直接写入 WASM 线性内存 view
      memory.view.setRange(inPtr, inPtr + inputBytes.length, inputBytes);

      // 调用核心处理函数
      final targetFunc = formValues['functionName']?.toString().trim() ?? 'process';
      final func = instance.getFunction(targetFunc);
      if (func == null) {
        return ProcessingResult(
          success: false,
          message: '未在 WASM 模块中找到数据流处理函数: "$targetFunc"',
        );
      }

      final execRes = func([inPtr, inputBytes.length]);

      int outPtr = inPtr;
      int outLen = inputBytes.length;

      if (execRes.isNotEmpty && execRes.first is int) {
        outPtr = execRes.first as int;
      }

      final getLenFunc = instance.getFunction('get_output_len') ??
          instance.getFunction('out_len') ??
          instance.getFunction('output_len');
      if (getLenFunc != null) {
        final lenRes = getLenFunc([]);
        if (lenRes.isNotEmpty && lenRes.first is int && (lenRes.first as int) > 0) {
          outLen = lenRes.first as int;
        }
      } else if (execRes.length >= 2 && execRes[1] is int && (execRes[1] as int) > 0) {
        outLen = execRes[1] as int;
      }

      // 从内存 view 读取处理后字节流并落盘
      final outputBytes = Uint8List.fromList(memory.view.sublist(outPtr, outPtr + outLen));
      final outFileName = '${p.basenameWithoutExtension(inputFile.path)}_wasm_out${p.extension(inputFile.path)}';
      final outFile = File(p.join(outputDir, outFileName));
      outFile.writeAsBytesSync(outputBytes);
      outFiles.add(outFile.path);

      onLog?.call('>>> 文件转换完成并落盘: ${outFile.path} (${outputBytes.length} 字节)', false);

      // 尝试释放内存
      final freeFunc = instance.getFunction('free') ?? instance.getFunction('dealloc');
      if (freeFunc != null) {
        try {
          freeFunc([inPtr]);
          if (outPtr != inPtr) freeFunc([outPtr]);
        } catch (_) {}
      }
    }
    stopwatch.stop();
    onLog?.call('>>> 内存流处理完成！耗时: ${stopwatch.elapsedMilliseconds} ms，共生成 ${outFiles.length} 个产物', false);

    if (formValues['exportJson']?.toString() != 'no') {
      final jsonFile = File(p.join(outputDir, 'wasm_report.json'));
      final payload = {
        'timestamp': DateTime.now().toIso8601String(),
        'moduleName': moduleTitle,
        'executionMode': 'memory_stream',
        'totalFiles': inputFiles.length,
        'elapsedMilliseconds': stopwatch.elapsedMilliseconds,
        'generatedFiles': outFiles.map((p) => File(p).uri.pathSegments.last).toList(),
        'inspection': report.toJson(),
      };
      jsonFile.writeAsStringSync(const JsonEncoder.withIndent('  ').convert(payload));
      outFiles.add(jsonFile.path);
    }

    onProgress?.call(1.0, '内存流处理圆满完成！');
    return ProcessingResult(
      success: true,
      message: 'WASM 内存流处理成功！已落盘 ${outFiles.length} 个产物。',
      outputFiles: outFiles,
    );
  }

  /// 智能解析待装载的 WASM 模块二进制（支持插件安装目录、私有 bin/ 寻址、表单指定及内置回退）
  static Future<({Uint8List bytes, String title})> _resolveModuleSource({
    required Map<String, dynamic> formValues,
    required List<String> inputFiles,
    required List<String> dataFilesOut,
    String? pluginDirectory,
    String sourceMode = 'demo',
    String executionMode = 'call_func',
    void Function(String line, bool isError)? onLog,
  }) async {
    // 1. 尝试从清单或参数中声明的 wasmPath / entry 寻址
    final wasmPathSpec = formValues['wasmPath']?.toString() ??
        formValues['entry']?.toString() ??
        formValues['wasmFile']?.toString();

    String? foundWasmFile;
    if (wasmPathSpec != null && wasmPathSpec.isNotEmpty) {
      if (p.isAbsolute(wasmPathSpec) && File(wasmPathSpec).existsSync()) {
        foundWasmFile = wasmPathSpec;
      } else if (pluginDirectory != null && pluginDirectory.isNotEmpty) {
        final c1 = p.join(pluginDirectory, wasmPathSpec);
        if (File(c1).existsSync()) {
          foundWasmFile = c1;
        }
      }
      if (foundWasmFile == null && File(wasmPathSpec).existsSync()) {
        foundWasmFile = wasmPathSpec;
      }
    }

    // 2. 插件安装目录自省：自动扫描 bin/*.wasm 或根目录 *.wasm
    if (foundWasmFile == null && pluginDirectory != null && pluginDirectory.isNotEmpty) {
      final pDir = Directory(pluginDirectory);
      if (pDir.existsSync()) {
        final binDir = Directory(p.join(pluginDirectory, 'bin'));
        if (binDir.existsSync()) {
          final wasms = binDir.listSync().whereType<File>().where((f) => f.path.toLowerCase().endsWith('.wasm')).toList();
          if (wasms.isNotEmpty) foundWasmFile = wasms.first.path;
        }
        if (foundWasmFile == null) {
          final wasms = pDir.listSync().whereType<File>().where((f) => f.path.toLowerCase().endsWith('.wasm')).toList();
          if (wasms.isNotEmpty) foundWasmFile = wasms.first.path;
        }
      }
    }

    // 3. 检查表单控件 explicit wasmInput (用于算力工坊用户手动选取外部 .wasm)
    if (foundWasmFile == null) {
      final explicitWasmPath = formValues['wasmInput']?.toString();
      if (explicitWasmPath != null && explicitWasmPath.isNotEmpty && File(explicitWasmPath).existsSync()) {
        foundWasmFile = explicitWasmPath;
        dataFilesOut.removeWhere((f) => f == explicitWasmPath);
      }
    }

    // 4. 从输入文件列表中自动拆分出 .wasm / .wat 模块
    if (foundWasmFile == null && sourceMode == 'custom') {
      final wasmCandidates = inputFiles.where((f) {
        final lower = f.toLowerCase();
        return lower.endsWith('.wasm') || lower.endsWith('.wat');
      }).toList();
      if (wasmCandidates.isNotEmpty) {
        foundWasmFile = wasmCandidates.first;
        dataFilesOut.remove(foundWasmFile);
      }
    }

    if (foundWasmFile != null) {
      final title = p.basename(foundWasmFile);
      onLog?.call('>>> 成功定位并加载插件 WASM 模块: $title (${File(foundWasmFile).lengthSync()} 字节)', false);
      final bytes = await resolveBytes(foundWasmFile);
      return (bytes: bytes, title: title);
    }

    if (sourceMode == 'custom' && inputFiles.isNotEmpty) {
      final filePath = inputFiles.first;
      final title = p.basename(filePath);
      onLog?.call('>>> 正在尝试加载外部模块文件: $title', false);
      dataFilesOut.remove(filePath);
      final bytes = await resolveBytes(filePath);
      return (bytes: bytes, title: title);
    }

    // 5. 回退至底座内置演示模块
    if (executionMode == 'wasi_cli') {
      onLog?.call('>>> 采用底座内置 WASI VFS 演示内核 (包含 stdout 与磁盘文件写入)', false);
      final bytes = await resolveBytes(builtinDemoWasiWat);
      return (bytes: bytes, title: '内置 WASI VFS 磁盘流式文件写入演示模块');
    } else if (executionMode == 'memory_stream') {
      onLog?.call('>>> 采用底座内置内存流演示内核 (高效内存指针文本转换)', false);
      final bytes = await resolveBytes(builtinDemoMemoryWat);
      return (bytes: bytes, title: '内置 WASM 内存流大写转换演示模块');
    } else {
      onLog?.call('>>> 采用底座内置 WASM 算法演示内核 (包含 add, fib, square)', false);
      final bytes = await resolveBytes(builtinDemoWat);
      return (bytes: bytes, title: '内置高算力数学/算法演示模块');
    }
  }

  /// 核心工具引擎处理入口 (对接 tool_engine_service)
  static Future<ProcessingResult> execute({
    required Map<String, dynamic> formValues,
    required List<String> inputFiles,
    required String outputDir,
    String? pluginDirectory,
    void Function(double progress, String stage)? onProgress,
    void Function(String line, bool isError)? onLog,
  }) async {
    await ensureInitialized();

    final sourceMode = formValues['sourceMode']?.toString() ??
        (formValues['wasmPath'] != null || formValues['entry'] != null ? 'custom' : 'demo');
    final executionMode = formValues['executionMode']?.toString() ?? 'call_func';
    final targetFunc = formValues['functionName']?.toString().trim() ?? 'fib';
    final rawArgs = formValues['functionArgs']?.toString().trim() ?? '10';
    final exportJson = formValues['exportJson']?.toString() != 'no';
    final resolvedPluginDir = pluginDirectory ?? formValues['pluginDirectory']?.toString();

    onLog?.call('【Wasm 微内核引擎】沙箱准备就绪...', false);
    onProgress?.call(0.1, '正在加载 WebAssembly 模块...');

    final dataFiles = [...inputFiles];
    final resolved = await _resolveModuleSource(
      formValues: formValues,
      inputFiles: inputFiles,
      dataFilesOut: dataFiles,
      pluginDirectory: resolvedPluginDir,
      sourceMode: sourceMode,
      executionMode: executionMode,
      onLog: onLog,
    );

    final wasmBytes = resolved.bytes;
    final moduleTitle = resolved.title;

    onLog?.call('>>> 模块字节大小: ${wasmBytes.length} 字节', false);
    onProgress?.call(0.2, '正在解析 WASM 模块结构...');

    final report = await inspect(wasmBytes);
    onLog?.call('>>> 模块导出表检测完毕: 共 ${report.exports.length} 个导出条目', false);
    for (final exp in report.exports) {
      if (exp.type == 'func') {
        onLog?.call('    • 函数: ${exp.name}(${exp.paramTypes.join(', ')}) -> [${exp.returnTypes.join(', ')}]', false);
      } else {
        onLog?.call('    • ${exp.type.toUpperCase()}: ${exp.name}', false);
      }
    }

    // 1. 结构自检逆向模式
    if (executionMode == 'inspect') {
      onProgress?.call(1.0, '模块逆向结构解析完成！');
      onLog?.call('>>> 模块结构已全面逆向分析完毕', false);

      final outFiles = <String>[];
      if (exportJson) {
        final outDir = Directory(outputDir);
        if (!outDir.existsSync()) outDir.createSync(recursive: true);
        final jsonFile = File(p.join(outputDir, 'wasm_report.json'));
        final payload = {
          'timestamp': DateTime.now().toIso8601String(),
          'moduleName': moduleTitle,
          'inspection': report.toJson(),
        };
        jsonFile.writeAsStringSync(const JsonEncoder.withIndent('  ').convert(payload));
        outFiles.add(jsonFile.path);
        onLog?.call('>>> 结构报告已落盘至: ${jsonFile.path}', false);
      }
      return ProcessingResult(
        success: true,
        message: 'WebAssembly 模块结构解析完成！',
        outputFiles: outFiles,
      );
    }

    // 2. WASI 命令行执行模式 (映射宿主 VFS 目录与 CLI 参数，支持逐文件批处理循环)
    if (executionMode == 'wasi_cli' || (report.hasWasi && report.hasStart && executionMode != 'memory_stream' && executionMode != 'call_func')) {
      return await _executeWasiCli(
        source: wasmBytes,
        wasmBytes: wasmBytes,
        moduleTitle: moduleTitle,
        report: report,
        inputFiles: dataFiles,
        outputDir: outputDir,
        pluginDirectory: resolvedPluginDir,
        formValues: formValues,
        onProgress: onProgress,
        onLog: onLog,
      );
    }

    // 3. 内存流管道模式 (缓冲区直读直写落盘，支持多选批量转换)
    if (executionMode == 'memory_stream') {
      return await _executeMemoryStream(
        source: wasmBytes,
        wasmBytes: wasmBytes,
        moduleTitle: moduleTitle,
        report: report,
        inputFiles: dataFiles,
        outputDir: outputDir,
        pluginDirectory: resolvedPluginDir,
        formValues: formValues,
        onProgress: onProgress,
        onLog: onLog,
      );
    }

    // 4. 标准函数调用模式 (自动按需注入 WASI VFS 上下文)
    onProgress?.call(0.6, '正在初始化 WASM 实例与内存沙箱...');

    final outDir = Directory(outputDir);
    if (!outDir.existsSync()) outDir.createSync(recursive: true);
    final beforeFiles = outDir.listSync(recursive: true).whereType<File>().map((f) => f.path).toSet();

    final parsedArgs = <dynamic>[];
    if (rawArgs.isNotEmpty) {
      if (rawArgs.startsWith('[') && rawArgs.endsWith(']')) {
        try {
          final decoded = jsonDecode(rawArgs);
          if (decoded is List) parsedArgs.addAll(decoded);
        } catch (_) {}
      } else {
        final tokens = rawArgs.split(',');
        for (final t in tokens) {
          final trimmed = t.trim();
          final intVal = int.tryParse(trimmed);
          if (intVal != null) {
            parsedArgs.add(intVal);
            continue;
          }
          final doubleVal = double.tryParse(trimmed);
          if (doubleVal != null) {
            parsedArgs.add(doubleVal);
            continue;
          }
          parsedArgs.add(trimmed);
        }
      }
    }

    onLog?.call('>>> 准备执行函数: $targetFunc(${parsedArgs.join(', ')})', false);
    onProgress?.call(0.8, '正在 WASM 沙箱中执行机器码...');

    // 若模块导入了 WASI 规范，自动挂载宿主目录与环境，防止内部文件/系统调用崩溃
    final wasiConfig = report.hasWasi
        ? buildWasiConfig(outputDir: outputDir, inputFiles: dataFiles, pluginDirectory: resolvedPluginDir)
        : null;

    Map<String, dynamic> execRes;
    try {
      execRes = await callFunction(
        source: wasmBytes,
        functionName: targetFunc,
        arguments: parsedArgs,
        wasiConfig: wasiConfig,
      );
      onLog?.call('>>> 执行成功！返回值: ${execRes['result']}', false);
      onLog?.call('>>> 耗时: ${execRes['elapsedMicroseconds']} 微秒 (${execRes['elapsedMilliseconds']} ms)', false);
    } catch (e) {
      onLog?.call('>>> WASM 执行异常: $e', true);
      return ProcessingResult(
        success: false,
        message: 'WASM 执行失败: $e',
      );
    }

    // 扫描是否在执行函数期间通过 WASI 生成了落盘文件
    final afterFiles = outDir.listSync(recursive: true).whereType<File>().toList();
    final newlyGeneratedFiles = afterFiles.where((f) => !beforeFiles.contains(f.path)).map((f) => f.path).toList();
    final outFiles = <String>[...newlyGeneratedFiles];

    if (exportJson) {
      final jsonFile = File(p.join(outputDir, 'wasm_report.json'));
      final payload = {
        'timestamp': DateTime.now().toIso8601String(),
        'moduleName': moduleTitle,
        'inspection': report.toJson(),
        'execution': execRes,
        if (newlyGeneratedFiles.isNotEmpty)
          'generatedFiles': newlyGeneratedFiles.map((p) => File(p).uri.pathSegments.last).toList(),
      };
      jsonFile.writeAsStringSync(const JsonEncoder.withIndent('  ').convert(payload));
      outFiles.add(jsonFile.path);
      onLog?.call('>>> 执行报告与元数据已落盘至: ${jsonFile.path}', false);
    }

    onProgress?.call(1.0, 'WASM 任务执行完成！');
    return ProcessingResult(
      success: true,
      message: 'WebAssembly 模块执行成功！',
      outputFiles: outFiles,
    );
  }
}
