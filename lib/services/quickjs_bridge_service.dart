import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_js/flutter_js.dart';
import 'package:path/path.dart' as p;
import 'package:sync_http/sync_http.dart';
import '../models/plugin_manifest.dart';
import 'tool_engine_service.dart';

/// Android & 全平台 QuickJS 内存安全沙箱执行引擎与宿主桥接中枢 (Host Bridge)
/// 负责为无原生依赖的社区动态 JavaScript 插件提供高性能运行环境，
/// 并向 JS 沙箱安全注入文件系统 (fs)、网络请求 (http)、加解密 (crypto) 与实时终端日志管道。
class QuickJsBridgeService {
  static JavascriptRuntime? _activeRuntime;
  static bool _wasCancelled = false;

  /// 中止当前正在运行的 JS 脚本
  static void killCurrentExecution() {
    _wasCancelled = true;
    try {
      _activeRuntime?.dispose();
    } catch (e) {
      debugPrint('QuickJS 终止异常: $e');
    }
    _activeRuntime = null;
  }

  /// 执行 QuickJS 动态插件
  static Future<ProcessingResult> execute({
    required PluginManifest plugin,
    required Map<String, dynamic> formValues,
    required List<String> inputFiles,
    required String outputDir,
    required void Function(double progress, String status) onProgress,
    required void Function(String line, bool isError) onLog,
  }) async {
    _wasCancelled = false;
    onProgress(0.05, '正在初始化 QuickJS 引擎沙箱...');
    onLog('【QuickJS 引擎】初始化沙箱环境: ${plugin.name} (v${plugin.version})', false);

    // 1. 获取目标 JavaScript 代码
    final scriptSource = await _resolveScriptSource(plugin);
    if (scriptSource == null || scriptSource.trim().isEmpty) {
      return ProcessingResult(
        success: false,
        message: '未找到插件可执行脚本 (entry.js 或 action.script 缺失)',
      );
    }

    // 2. 准备输出目录并建立执行前快照
    final outDir = Directory(outputDir);
    if (!outDir.existsSync()) {
      outDir.createSync(recursive: true);
    }
    final preExecutionFiles = _scanDirectory(outputDir);

    // 3. 初始化 JavascriptRuntime
    final jsRuntime = getJavascriptRuntime();
    _activeRuntime = jsRuntime;

    try {
      // 注册实时日志与终端回显管道
      jsRuntime.onMessage('ToolboxChannel_Log', (dynamic args) {
        if (args is Map) {
          final isError = args['isError'] == true;
          final msg = args['message']?.toString() ?? '';
          if (msg.isNotEmpty) {
            onLog(msg, isError);
          }
        } else if (args != null) {
          onLog(args.toString(), false);
        }
      });

      // 注册任务进度更新管道
      jsRuntime.onMessage('ToolboxChannel_Progress', (dynamic args) {
        if (args is Map) {
          final pct = (args['progress'] as num?)?.toDouble() ?? 0.0;
          final status = args['status']?.toString() ?? '';
          onProgress(pct.clamp(0.0, 1.0), status);
        }
      });

      // 注册双向同步桥接调度中枢 (Sync Host Bridge)
      jsRuntime.onMessage('ToolboxSync', (dynamic args) {
        if (args is! Map) return;
        final action = args['action']?.toString() ?? '';
        final payload = (args['payload'] as Map?) ?? {};

        dynamic result;
        try {
          result = _handleHostBridgeCall(
            action: action,
            payload: payload,
            outputDir: outputDir,
          );
        } catch (e) {
          result = {'__error': e.toString()};
        }

        final encoded = jsonEncode(result);
        jsRuntime.evaluate("window.__sync_result = $encoded;");
      });

      // 4. 注入 Host Bridge 宿主 API (Toolbox.*) 与全局环境
      onProgress(0.15, '正在装载宿主能力接口...');
      final bootstrapScript = _buildBootstrapScript(
        outputDir: outputDir,
        inputFiles: inputFiles,
        formValues: formValues,
      );
      jsRuntime.evaluate(bootstrapScript);

      // 5. 执行插件 JavaScript 代码
      onProgress(0.3, '正在执行插件逻辑...');
      onLog('>>> 开始执行 JavaScript 逻辑...', false);

      final wrappedRunner = """
      (async function() {
        try {
          $scriptSource
          ;
          if (typeof run === 'function') {
            return await run({
              inputFiles: Toolbox.env.inputFiles,
              outputDir: Toolbox.env.outputDir,
              params: Toolbox.env.params
            });
          }
          return { success: true, message: '执行完成' };
        } catch(err) {
          return { success: false, message: (err && err.stack) ? err.stack : String(err) };
        }
      })();
      """;

      final evalResult = jsRuntime.evaluate(wrappedRunner);

      if (_wasCancelled) {
        onLog('>>> 任务已被用户手动中止', true);
        return ProcessingResult(success: false, message: '任务已被用户手动中止');
      }

      onProgress(0.9, '正在校验产物...');

      // 6. 检测产物文件
      final postExecutionFiles = _scanDirectory(outputDir);
      final generatedFiles = postExecutionFiles.difference(preExecutionFiles).toList();

      bool isSuccess = true;
      String message = '脚本执行完成';

      if (evalResult.isError) {
        isSuccess = false;
        message = 'JavaScript 执行异常: ${evalResult.stringResult}';
        onLog('>>> $message', true);
      } else {
        onLog('>>> 脚本执行返回: ${evalResult.stringResult}', false);
        if (generatedFiles.isNotEmpty) {
          message = '处理成功！共生成 ${generatedFiles.length} 个输出文件';
        }
      }

      onProgress(1.0, isSuccess ? '执行完成！' : '执行失败');

      return ProcessingResult(
        success: isSuccess,
        message: message,
        outputFiles: generatedFiles,
      );
    } catch (e, stack) {
      onLog('>>> 运行时异常: $e\n$stack', true);
      return ProcessingResult(
        success: false,
        message: 'QuickJS 沙箱运行异常: $e',
      );
    } finally {
      _activeRuntime = null;
      try {
        jsRuntime.dispose();
      } catch (_) {}
    }
  }

  /// 调度同步宿主桥接请求
  static dynamic _handleHostBridgeCall({
    required String action,
    required Map payload,
    required String outputDir,
  }) {
    switch (action) {
      // --- 文件系统 (fs) ---
      case 'fs_read':
        final filePath = payload['path']?.toString() ?? '';
        final file = File(filePath);
        if (!file.existsSync()) throw Exception('文件不存在: $filePath');
        return file.readAsStringSync();

      case 'fs_write':
        final filePath = payload['path']?.toString() ?? '';
        final content = payload['content']?.toString() ?? '';
        final isBase64 = payload['isBase64'] == true;
        final file = File(filePath);
        file.parent.createSync(recursive: true);
        if (isBase64) {
          file.writeAsBytesSync(base64Decode(content));
        } else {
          file.writeAsStringSync(content);
        }
        return true;

      case 'fs_exists':
        final target = payload['path']?.toString() ?? '';
        return File(target).existsSync() || Directory(target).existsSync();

      case 'fs_list':
        final dirPath = payload['path']?.toString() ?? '';
        final d = Directory(dirPath);
        if (!d.existsSync()) return [];
        return d.listSync().map((e) => e.path).toList();

      case 'fs_mkdir':
        final dirPath = payload['path']?.toString() ?? '';
        Directory(dirPath).createSync(recursive: true);
        return true;

      case 'fs_size':
        final target = payload['path']?.toString() ?? '';
        final f = File(target);
        return f.existsSync() ? f.lengthSync() : 0;

      // --- 加解密与哈希 (crypto) ---
      case 'crypto_md5':
        final text = payload['text']?.toString() ?? '';
        return md5.convert(utf8.encode(text)).toString();

      case 'crypto_sha256':
        final text = payload['text']?.toString() ?? '';
        return sha256.convert(utf8.encode(text)).toString();

      case 'crypto_b64encode':
        final text = payload['text']?.toString() ?? '';
        return base64Encode(utf8.encode(text));

      case 'crypto_b64decode':
        final b64 = payload['text']?.toString() ?? '';
        return utf8.decode(base64Decode(b64));

      // --- 网络请求 (http) ---
      case 'http_get':
        final urlStr = payload['url']?.toString() ?? '';
        final req = SyncHttpClient.getUrl(Uri.parse(urlStr));
        final headers = (payload['headers'] as Map?) ?? {};
        headers.forEach((k, v) {
          req.headers.add(k.toString(), v.toString());
        });
        final resp = req.close();
        return {
          'statusCode': resp.statusCode,
          'body': resp.body,
        };

      case 'http_post':
        final urlStr = payload['url']?.toString() ?? '';
        final req = SyncHttpClient.postUrl(Uri.parse(urlStr));
        final headers = (payload['headers'] as Map?) ?? {};
        headers.forEach((k, v) {
          req.headers.add(k.toString(), v.toString());
        });
        final body = payload['body']?.toString() ?? '';
        if (body.isNotEmpty) {
          req.write(body);
        }
        final resp = req.close();
        return {
          'statusCode': resp.statusCode,
          'body': resp.body,
        };

      default:
        throw Exception('未知宿主桥接动作: $action');
    }
  }

  /// 构建注入到 QuickJS 沙箱内部的全局 Toolbox 宿主环境代码
  static String _buildBootstrapScript({
    required String outputDir,
    required List<String> inputFiles,
    required Map<String, dynamic> formValues,
  }) {
    final platformName = Platform.isAndroid ? 'android' : (Platform.isWindows ? 'windows' : 'other');
    final envJson = jsonEncode({
      'outputDir': outputDir.replaceAll(r'\', '/'),
      'inputFiles': inputFiles.map((f) => f.replaceAll(r'\', '/')).toList(),
      'params': formValues,
      'platform': platformName,
    });

    return """
    var window = this;
    var global = this;

    function __Toolbox_syncCall(action, payload) {
      window.__sync_result = undefined;
      sendMessage('ToolboxSync', JSON.stringify({ action: action, payload: payload || {} }));
      if (window.__sync_result && window.__sync_result.__error) {
        throw new Error(window.__sync_result.__error);
      }
      return window.__sync_result;
    }

    var Toolbox = {
      platform: '$platformName',
      version: '1.0.0',
      env: $envJson,
      log: function() {
        var msg = Array.prototype.slice.call(arguments).map(function(item) {
          return (typeof item === 'object') ? JSON.stringify(item) : String(item);
        }).join(' ');
        sendMessage('ToolboxChannel_Log', JSON.stringify({ isError: false, message: msg }));
      },
      error: function() {
        var msg = Array.prototype.slice.call(arguments).map(function(item) {
          return (typeof item === 'object') ? JSON.stringify(item) : String(item);
        }).join(' ');
        sendMessage('ToolboxChannel_Log', JSON.stringify({ isError: true, message: msg }));
      },
      setProgress: function(pct, status) {
        sendMessage('ToolboxChannel_Progress', JSON.stringify({ progress: Number(pct), status: String(status || '') }));
      },
      fs: {
        readFile: function(path) {
          return __Toolbox_syncCall('fs_read', { path: path });
        },
        writeFile: function(path, content, isBase64) {
          return __Toolbox_syncCall('fs_write', { path: path, content: content, isBase64: !!isBase64 });
        },
        exists: function(path) {
          return __Toolbox_syncCall('fs_exists', { path: path });
        },
        listFiles: function(path) {
          return __Toolbox_syncCall('fs_list', { path: path });
        },
        mkdir: function(path) {
          return __Toolbox_syncCall('fs_mkdir', { path: path });
        },
        fileSize: function(path) {
          return __Toolbox_syncCall('fs_size', { path: path });
        }
      },
      crypto: {
        md5: function(text) {
          return __Toolbox_syncCall('crypto_md5', { text: text });
        },
        sha256: function(text) {
          return __Toolbox_syncCall('crypto_sha256', { text: text });
        },
        base64Encode: function(text) {
          return __Toolbox_syncCall('crypto_b64encode', { text: text });
        },
        base64Decode: function(text) {
          return __Toolbox_syncCall('crypto_b64decode', { text: text });
        }
      },
      http: {
        get: function(url, headers) {
          return __Toolbox_syncCall('http_get', { url: url, headers: headers });
        },
        post: function(url, body, headers) {
          return __Toolbox_syncCall('http_post', { url: url, body: body, headers: headers });
        }
      }
    };

    console.log = Toolbox.log;
    console.error = Toolbox.error;
    console.warn = Toolbox.log;
    """;
  }

  /// 解析插件执行脚本内容
  static Future<String?> _resolveScriptSource(PluginManifest plugin) async {
    // 1. 若 action params 中直接内联了 script
    final inlineScript = plugin.action?.params['script']?.toString();
    if (inlineScript != null && inlineScript.trim().isNotEmpty) {
      return inlineScript;
    }

    // 2. 若 localDir 存在，优先查找 entry.js / index.js / main.js
    final localDir = plugin.localDir;
    if (localDir != null && localDir.isNotEmpty) {
      for (var fileName in ['entry.js', 'index.js', 'main.js', 'tool.js']) {
        final f = File(p.join(localDir, fileName));
        if (f.existsSync()) {
          return f.readAsStringSync();
        }
      }
    }

    return null;
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
