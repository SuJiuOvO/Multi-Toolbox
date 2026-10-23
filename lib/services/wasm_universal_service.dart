import 'dart:convert';
import 'dart:io';
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

  WasmInspectionReport({
    required this.byteLength,
    required this.exports,
    required this.imports,
    required this.hasWasi,
    required this.hasMemory,
  });

  Map<String, dynamic> toJson() => {
    'byteLength': byteLength,
    'hasWasi': hasWasi,
    'hasMemory': hasMemory,
    'exports': exports.map((e) => e.toJson()).toList(),
    'imports': imports.map((i) => i.toJson()).toList(),
  };
}

/// 跨平台 WebAssembly (WASM) 微内核解释与沙箱调度服务
/// 统一调度 C/C++/Rust 编译的 .wasm 与 .wat 二进制/文本字节码模块
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
    i32.const 2
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
          await WasmRunLibrary.setUp();
        }
      } else {
        await WasmRunLibrary.setUp();
      }
      _initialized = true;
    } catch (e) {
      debugPrint('WasmUniversalService 初始化注意: $e');
      _initialized = true;
    }
  }

  /// 将可能为 `.wat` 文本或 `.wasm` 二进制的数据标准化解析为二进制字节流
  static Future<Uint8List> resolveBytes(dynamic source) async {
    await ensureInitialized();
    if (source is Uint8List) {
      // 检查是否为 WASM 魔数 (\0asm = 0x00, 0x61, 0x73, 0x6d)
      if (source.length >= 4 &&
          source[0] == 0x00 &&
          source[1] == 0x61 &&
          source[2] == 0x73 &&
          source[3] == 0x6d) {
        return source;
      }
      // 否则尝试当做 WAT 文本解析
      final text = utf8.decode(source, allowMalformed: true);
      return await parseWatFormat(wat: text);
    } else if (source is String) {
      final file = File(source);
      if (file.existsSync()) {
        final bytes = file.readAsBytesSync();
        if (source.toLowerCase().endsWith('.wat')) {
          final text = file.readAsStringSync();
          return await parseWatFormat(wat: text);
        }
        return bytes;
      }
      // 纯字符串作为 WAT 源码即时编译
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

    for (final imp in module.getImports()) {
      if (imp.module.startsWith('wasi_')) {
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
    );
  }

  /// 在 WASM 沙箱中调用指定导出函数
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

  /// 核心工具引擎处理入口 (对接 tool_engine_service)
  static Future<ProcessingResult> execute({
    required Map<String, dynamic> formValues,
    required List<String> inputFiles,
    required String outputDir,
    void Function(double progress, String stage)? onProgress,
    void Function(String line, bool isError)? onLog,
  }) async {
    await ensureInitialized();

    final sourceMode = formValues['sourceMode']?.toString() ?? 'demo';
    final executionMode = formValues['executionMode']?.toString() ?? 'call_func';
    final targetFunc = formValues['functionName']?.toString().trim() ?? 'fib';
    final rawArgs = formValues['functionArgs']?.toString().trim() ?? '10';
    final exportJson = formValues['exportJson']?.toString() != 'no';

    onLog?.call('【Wasm 微内核引擎】沙箱准备就绪...', false);
    onProgress?.call(0.1, '正在加载 WebAssembly 模块...');

    Uint8List wasmBytes;
    String moduleTitle = '内置高算力数学/算法演示模块';

    if (sourceMode == 'custom' && inputFiles.isNotEmpty) {
      final filePath = inputFiles.first;
      moduleTitle = p.basename(filePath);
      onLog?.call('>>> 正在加载自选模块文件: $moduleTitle', false);
      wasmBytes = await resolveBytes(filePath);
    } else {
      onLog?.call('>>> 采用底座内置 WASM 算法演示内核 (包含 add, fib, square)', false);
      wasmBytes = await resolveBytes(builtinDemoWat);
    }

    onLog?.call('>>> 模块字节大小: ${wasmBytes.length} 字节', false);
    onProgress?.call(0.3, '正在解析 WASM 模块结构...');

    final report = await inspect(wasmBytes);
    onLog?.call('>>> 模块导出表检测完毕: 共 ${report.exports.length} 个导出条目', false);
    for (final exp in report.exports) {
      if (exp.type == 'func') {
        onLog?.call('    • 函数: ${exp.name}(${exp.paramTypes.join(', ')}) -> [${exp.returnTypes.join(', ')}]', false);
      } else {
        onLog?.call('    • ${exp.type.toUpperCase()}: ${exp.name}', false);
      }
    }

    Map<String, dynamic> executionPayload = {
      'timestamp': DateTime.now().toIso8601String(),
      'moduleName': moduleTitle,
      'inspection': report.toJson(),
    };

    if (executionMode == 'inspect') {
      onProgress?.call(1.0, '模块逆向结构解析完成！');
      onLog?.call('>>> 模块结构已全面逆向分析完毕', false);
    } else {
      onProgress?.call(0.6, '正在初始化 WASM 实例与内存沙箱...');

      // 解析调用参数
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

      try {
        final execRes = await callFunction(
          source: wasmBytes,
          functionName: targetFunc,
          arguments: parsedArgs,
        );
        executionPayload['execution'] = execRes;
        onLog?.call('>>> 执行成功！返回值: ${execRes['result']}', false);
        onLog?.call('>>> 耗时: ${execRes['elapsedMicroseconds']} 微秒 (${execRes['elapsedMilliseconds']} ms)', false);
      } catch (e) {
        onLog?.call('>>> WASM 执行异常: $e', true);
        return ProcessingResult(
          success: false,
          message: 'WASM 执行失败: $e',
        );
      }
    }

    final outFiles = <String>[];
    if (exportJson) {
      final outDir = Directory(outputDir);
      if (!outDir.existsSync()) outDir.createSync(recursive: true);
      final jsonFile = File(p.join(outputDir, 'wasm_report.json'));
      jsonFile.writeAsStringSync(const JsonEncoder.withIndent('  ').convert(executionPayload));
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
