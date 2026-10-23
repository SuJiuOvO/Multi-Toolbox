import 'dart:convert';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import '../models/plugin_manifest.dart';
import 'tool_engine_service.dart';

/// Windows 开放扩展工坊独立进程调度引擎
/// 负责外部独立可执行文件 (.exe)、脚本 (.bat, .ps1, .py) 的依赖拉取、动态参数组装与实时终端日志捕获
class WindowsExtensionRunnerService {
  static Process? _activeProcess;
  static bool _wasKilled = false;

  /// 强制中止当前正在运行的外部进程
  static void killActiveProcess() {
    if (_activeProcess != null) {
      _wasKilled = true;
      try {
        _activeProcess?.kill(ProcessSignal.sigkill);
      } catch (e) {
        debugPrint('中止进程异常: $e');
      }
      _activeProcess = null;
    }
  }

  /// 执行 Windows 开放扩展插件
  static Future<ProcessingResult> execute({
    required PluginManifest plugin,
    required Map<String, dynamic> formValues,
    required List<String> inputFiles,
    required String outputDir,
    required void Function(double progress, String status) onProgress,
    required void Function(String line, bool isError) onLog,
  }) async {
    _wasKilled = false;

    if (!Platform.isWindows) {
      return ProcessingResult(
        success: false,
        message: '当前扩展工具仅支持在 Windows 操作系统中运行',
      );
    }

    final runner = plugin.nativeRunner;
    if (runner == null && plugin.action == null) {
      return ProcessingResult(
        success: false,
        message: '插件未配置 nativeRunner 运行描述',
      );
    }

    final entrySpec = runner?.entry ?? 'bin/tool.exe';
    final pluginDir = plugin.localDir ?? '';

    onProgress(0.05, '正在检查扩展运行环境与依赖...');
    onLog('【Windows 开放工坊】准备初始化: ${plugin.name} (v${plugin.version})', false);

    // 1. 查找并解析可执行程序路径
    String? resolvedExePath = await _resolveExecutable(
      plugin: plugin,
      entry: entrySpec,
      pluginDir: pluginDir,
      onProgress: onProgress,
      onLog: onLog,
    );

    if (resolvedExePath == null) {
      return ProcessingResult(
        success: false,
        message: '未找到可执行程序或组件下载失败: $entrySpec',
      );
    }

    onLog('>>> 目标启动程序: $resolvedExePath', false);

    // 2. 组装并替换命令行参数模板
    final resolvedArgs = _assembleArguments(
      rawArgs: runner?.args ?? [],
      formValues: formValues,
      inputFiles: inputFiles,
      outputDir: outputDir,
      pluginDir: pluginDir,
    );

    onLog('>>> 命令行执行参数: ${resolvedArgs.join(' ')}', false);

    // 3. 记录执行前输出目录的文件快照 (用于识别新生成的文件)
    final preExecutionFiles = _scanDirectory(outputDir);

    // 4. 启动子进程
    onProgress(0.15, '正在启动独立外部进程...');
    final workDir = runner?.workingDir != null
        ? (p.isAbsolute(runner!.workingDir!) ? runner.workingDir! : p.join(pluginDir, runner.workingDir!))
        : (pluginDir.isNotEmpty ? pluginDir : outputDir);

    try {
      final isShellRequired = runner?.shell != null ||
          entrySpec.endsWith('.bat') ||
          entrySpec.endsWith('.cmd') ||
          entrySpec.endsWith('.ps1') ||
          entrySpec.endsWith('.py');

      String executableToSpawn = resolvedExePath;
      List<String> argsToSpawn = resolvedArgs;

      // 如果是 PowerShell 脚本
      if (entrySpec.endsWith('.ps1') || runner?.shell == 'powershell') {
        executableToSpawn = 'powershell.exe';
        argsToSpawn = ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', resolvedExePath, ...resolvedArgs];
      }
      // 如果是 Python 脚本
      else if (entrySpec.endsWith('.py') || runner?.shell == 'python') {
        executableToSpawn = 'python.exe';
        argsToSpawn = [resolvedExePath, ...resolvedArgs];
      }
      // 如果是 CMD/Batch 批处理
      else if (entrySpec.endsWith('.bat') || entrySpec.endsWith('.cmd') || runner?.shell == 'cmd') {
        executableToSpawn = 'cmd.exe';
        argsToSpawn = ['/c', resolvedExePath, ...resolvedArgs];
      }

      onLog('>>> [Process.start] $executableToSpawn ${argsToSpawn.join(' ')}', false);

      final process = await Process.start(
        executableToSpawn,
        argsToSpawn,
        workingDirectory: workDir,
        runInShell: isShellRequired,
      );

      _activeProcess = process;
      onLog('>>> 进程已创建，PID: ${process.pid}', false);
      onProgress(0.25, '进程正在后台运行，实时捕获终端日志...');

      // 实时流式捕获标准输出与标准错误
      process.stdout.listen((bytes) {
        final decoded = _decodeConsoleBytes(bytes);
        for (var line in decoded.split(RegExp(r'\r?\n'))) {
          if (line.isNotEmpty) {
            onLog(line, false);
            _detectProgressFromLog(line, onProgress);
          }
        }
      });

      process.stderr.listen((bytes) {
        final decoded = _decodeConsoleBytes(bytes);
        for (var line in decoded.split(RegExp(r'\r?\n'))) {
          if (line.isNotEmpty) {
            onLog(line, true);
          }
        }
      });

      // 等待进程退出
      final exitCode = await process.exitCode;
      _activeProcess = null;

      if (_wasKilled) {
        onLog('>>> 任务已被用户手动中止', true);
        return ProcessingResult(
          success: false,
          message: '用户已手动中止进程',
        );
      }

      onLog('>>> 进程执行结束，返回码: $exitCode', exitCode != 0);

      // 5. 校验新生成的文件
      final postExecutionFiles = _scanDirectory(outputDir);
      final generatedFiles = postExecutionFiles.difference(preExecutionFiles).toList();

      final isSuccess = exitCode == 0;
      final msg = isSuccess
          ? (generatedFiles.isNotEmpty
              ? '处理成功！共生成 ${generatedFiles.length} 个输出文件'
              : '命令已成功执行完成 (ExitCode: 0)')
          : '外部工具执行异常退出，返回码: $exitCode';

      onProgress(1.0, isSuccess ? '执行完成！' : '执行失败');

      return ProcessingResult(
        success: isSuccess,
        message: msg,
        outputFiles: generatedFiles,
      );
    } catch (e) {
      _activeProcess = null;
      onLog('>>> 启动或调度进程异常: $e', true);
      return ProcessingResult(
        success: false,
        message: '无法启动外部可执行程序: $e',
      );
    }
  }

  /// 解析或按需拉取外部可执行文件
  static Future<String?> _resolveExecutable({
    required PluginManifest plugin,
    required String entry,
    required String pluginDir,
    required void Function(double progress, String status) onProgress,
    required void Function(String line, bool isError) onLog,
  }) async {
    // 1. 如果是系统级命令 (如 powershell.exe, cmd.exe, python.exe, git.exe, curl.exe)
    if (_isSystemCommand(entry)) {
      return entry;
    }

    // 2. 检查本地插件目录是否存在该程序
    if (pluginDir.isNotEmpty) {
      final localCandidate = File(p.join(pluginDir, entry));
      if (localCandidate.existsSync()) {
        return localCandidate.path;
      }
    }

    // 3. 检查全局或同名二进制
    final currentDirCandidate = File(entry);
    if (currentDirCandidate.existsSync()) {
      return currentDirCandidate.path;
    }

    // 4. 若本地不存在，且配置了下载地址，则自动从云端按需拉取
    final runner = plugin.nativeRunner;
    if (runner != null && (runner.downloadUrl != null || runner.downloadUrls.isNotEmpty)) {
      final targetFilePath = p.join(pluginDir, entry);
      final downloadSuccess = await _downloadComponent(
        runner: runner,
        targetPath: targetFilePath,
        onProgress: onProgress,
        onLog: onLog,
      );
      if (downloadSuccess && File(targetFilePath).existsSync()) {
        return targetFilePath;
      }
    }

    // 5. 尝试在系统 PATH 中寻找
    try {
      final whichRes = await Process.run('where.exe', [entry]);
      if (whichRes.exitCode == 0) {
        final lines = whichRes.stdout.toString().split('\n');
        if (lines.isNotEmpty && lines.first.trim().isNotEmpty) {
          return lines.first.trim();
        }
      }
    } catch (_) {}

    return null;
  }

  /// 从网络按需下载便携组件
  static Future<bool> _downloadComponent({
    required PluginNativeRunnerDef runner,
    required String targetPath,
    required void Function(double progress, String status) onProgress,
    required void Function(String line, bool isError) onLog,
  }) async {
    final dio = Dio();
    final urls = <String>[
      if (runner.downloadUrl != null) runner.downloadUrl!,
      ...runner.downloadUrls.values,
    ];

    final targetFile = File(targetPath);
    targetFile.parent.createSync(recursive: true);

    for (var url in urls) {
      try {
        onLog('>>> 正在按需拉取必要组件: $url', false);
        onProgress(0.1, '正在下载依赖组件...');
        await dio.download(
          url,
          targetPath,
          onReceiveProgress: (received, total) {
            if (total > 0) {
              final pct = 0.1 + (received / total) * 0.7;
              onProgress(pct, '正在下载组件: ${(received / 1024 / 1024).toStringAsFixed(1)}MB / ${(total / 1024 / 1024).toStringAsFixed(1)}MB');
            }
          },
        );

        if (targetFile.existsSync() && targetFile.lengthSync() > 0) {
          onLog('>>> 组件下载成功并就绪: $targetPath', false);
          return true;
        }
      } catch (e) {
        onLog('>>> 线路下载异常 ($url): $e', true);
      }
    }

    return false;
  }

  /// 替换与组装命令行参数模板
  static List<String> _assembleArguments({
    required List<String> rawArgs,
    required Map<String, dynamic> formValues,
    required List<String> inputFiles,
    required String outputDir,
    required String pluginDir,
  }) {
    final result = <String>[];
    final firstInput = inputFiles.isNotEmpty ? inputFiles.first : '';

    for (var arg in rawArgs) {
      String processed = arg;

      // 基础通用占位符
      processed = processed.replaceAll('{outputDir}', outputDir);
      processed = processed.replaceAll('{pluginDir}', pluginDir);
      processed = processed.replaceAll('{input}', firstInput);
      processed = processed.replaceAll('{inputFile}', firstInput);

      // 表单输入值替换: {fieldId}
      for (var entry in formValues.entries) {
        final key = entry.key;
        final val = entry.value;
        if (val is List) {
          processed = processed.replaceAll('{$key}', val.join(';'));
        } else if (val != null) {
          processed = processed.replaceAll('{$key}', val.toString());
        }
      }

      // 如果参数是多个输入文件展开
      if (processed.contains('{inputs}') || processed.contains('{inputFiles}')) {
        for (var f in inputFiles) {
          result.add(f);
        }
        continue;
      }

      result.add(processed);
    }

    return result;
  }

  /// 安全解码控制台输出 (兼容 Windows GBK 与 UTF-8 编码，防止中文乱码)
  static String _decodeConsoleBytes(List<int> bytes) {
    try {
      // 优先尝试 UTF-8 解码
      return utf8.decode(bytes);
    } catch (_) {
      try {
        // 若失败，尝试 Windows 系统本地区域编码 (GBK)
        return systemEncoding.decode(bytes);
      } catch (_) {
        return String.fromCharCodes(bytes);
      }
    }
  }

  /// 从终端日志中尝试提取进度百分比 (例如 yt-dlp 或 ffmpeg 的 [download] 54.2%)
  static void _detectProgressFromLog(String line, void Function(double, String) onProgress) {
    try {
      final pctMatch = RegExp(r'(\d{1,3}(?:\.\d+)?)%').firstMatch(line);
      if (pctMatch != null) {
        final pctVal = double.tryParse(pctMatch.group(1) ?? '');
        if (pctVal != null && pctVal >= 0 && pctVal <= 100) {
          onProgress(pctVal / 100.0, line);
        }
      }
    } catch (_) {}
  }

  static bool _isSystemCommand(String cmd) {
    final lower = cmd.toLowerCase();
    return lower == 'powershell.exe' ||
        lower == 'powershell' ||
        lower == 'cmd.exe' ||
        lower == 'cmd' ||
        lower == 'python.exe' ||
        lower == 'python' ||
        lower == 'curl.exe' ||
        lower == 'curl' ||
        lower == 'git.exe' ||
        lower == 'git';
  }

  static Set<String> _scanDirectory(String dirPath) {
    final d = Directory(dirPath);
    if (!d.existsSync()) return {};
    try {
      return d.listSync(recursive: false).whereType<File>().map((e) => e.path).toSet();
    } catch (_) {
      return {};
    }
  }
}
