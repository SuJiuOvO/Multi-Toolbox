import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_js/flutter_js.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sync_http/sync_http.dart';
import '../models/plugin_manifest.dart';
import 'tool_engine_service.dart';
import 'archive_universal_service.dart';
import 'wasm_universal_service.dart';

/// Android & 全平台 QuickJS 内存安全沙箱执行引擎与宿主桥接中枢 (Host Bridge)
/// 负责为无原生依赖的社区动态 JavaScript 插件提供高性能运行环境，
/// 并向 JS 沙箱安全注入文件系统 (fs)、网络请求 (http)、加解密 (crypto) 与实时终端日志管道。
class QuickJsBridgeService {
  static JavascriptRuntime? _activeRuntime;
  static Completer<dynamic>? _activeCompleter;
  static bool _wasCancelled = false;

  /// 中止当前正在运行的 JS 脚本
  static void killCurrentExecution() {
    _wasCancelled = true;
    if (_activeCompleter != null && !_activeCompleter!.isCompleted) {
      _activeCompleter!.complete(null);
    }
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

    // 2. 准备输出目录与插件专属持久化数据目录
    final outDir = Directory(outputDir);
    if (!outDir.existsSync()) {
      outDir.createSync(recursive: true);
    }
    final preExecutionFiles = _scanDirectory(outputDir);

    String pluginDataDir;
    try {
      Directory baseDir;
      if (Platform.environment.containsKey('FLUTTER_TEST')) {
        baseDir = Directory.systemTemp;
      } else if (Platform.isWindows) {
        baseDir = await getApplicationSupportDirectory();
      } else {
        baseDir = await getApplicationDocumentsDirectory();
      }
      pluginDataDir = p.join(baseDir.path, 'toolbox_plugin_data', plugin.id);
    } catch (_) {
      pluginDataDir = p.join(Directory.systemTemp.path, 'toolbox_plugin_data', plugin.id);
    }
    final dataDirObj = Directory(pluginDataDir);
    if (!dataDirObj.existsSync()) {
      dataDirObj.createSync(recursive: true);
    }

    // 3. 初始化 JavascriptRuntime (禁用 flutter_js 内部未受权限约束的 XHR 轮询计时器，统一采用 Host Bridge)
    final jsRuntime = getJavascriptRuntime(xhr: false);
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

      final runCompleter = Completer<dynamic>();
      _activeCompleter = runCompleter;

      // 注册脚本执行完成事件管道 (Event-Driven Completion，彻底替代 20ms 密集轮询)
      jsRuntime.onMessage('ToolboxChannel_Done', (dynamic args) {
        if (!runCompleter.isCompleted) {
          runCompleter.complete(args);
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
            inputFiles: inputFiles,
            pluginDirectory: plugin.localDir,
            pluginDataDir: pluginDataDir,
            plugin: plugin,
          );
        } catch (e) {
          result = {'__error': e.toString()};
        }

        final encoded = jsonEncode(result);
        jsRuntime.evaluate("window.__sync_result = $encoded;");
      });

      // 注册双向异步桥接调度中枢 (Async Host Bridge)
      jsRuntime.onMessage('ToolboxAsyncCall', (dynamic args) async {
        if (args is! Map) return;
        final callId = args['callId']?.toString() ?? '';
        final action = args['action']?.toString() ?? '';
        final payload = (args['payload'] as Map?) ?? {};

        dynamic result;
        try {
          if (action == 'http_get' || action == 'http_post' || action == 'http_request') {
            if (!plugin.hasPermission('network')) {
              throw Exception('沙箱安全拦截: 插件未在 manifest.json 中声明 "network" 权限，已阻止发起外部网络请求');
            }
            final urlStr = payload['url']?.toString() ?? '';
            final uri = Uri.parse(urlStr);
            final method = (payload['method']?.toString() ?? (action == 'http_post' ? 'POST' : 'GET')).toUpperCase();
            final headers = (payload['headers'] as Map?) ?? {};
            final body = payload['body']?.toString();

            final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
            final HttpClientRequest request;
            switch (method) {
              case 'POST':
                request = await client.postUrl(uri);
                break;
              case 'PUT':
                request = await client.putUrl(uri);
                break;
              case 'DELETE':
                request = await client.deleteUrl(uri);
                break;
              case 'HEAD':
                request = await client.headUrl(uri);
                break;
              default:
                request = await client.getUrl(uri);
            }

            headers.forEach((k, v) {
              request.headers.set(k.toString(), v.toString());
            });

            if (body != null && body.isNotEmpty) {
              request.write(body);
            }

            final response = await request.close().timeout(const Duration(seconds: 30));
            final responseBody = await response.transform(utf8.decoder).join();
            final responseHeaders = <String, String>{};
            response.headers.forEach((k, v) {
              responseHeaders[k] = v.join('; ');
            });
            client.close();

            result = {
              'statusCode': response.statusCode,
              'body': responseBody,
              'headers': responseHeaders,
            };
          } else if (action == 'archive_extract') {
            final archivePath = payload['archivePath']?.toString() ?? '';
            final destDir = payload['outputDir']?.toString() ?? outputDir;
            final pwd = payload['password']?.toString();
            final res = await ArchiveUniversalService.extract(
              archivePath: archivePath,
              outputDir: destDir,
              password: pwd,
              onProgress: (p, s) => onProgress(p, s),
              onLog: (l, e) => onLog(l, e),
            );
            result = {
              'success': res.success,
              'message': res.message,
              'outputFiles': res.outputFiles,
            };
          } else if (action == 'archive_compress') {
            final inputPaths = (payload['inputPaths'] as List?)?.map((e) => e.toString()).toList() ?? [];
            final outPath = payload['outputPath']?.toString() ?? p.join(outputDir, 'archive.zip');
            final format = payload['format']?.toString() ?? 'zip';
            final res = await ArchiveUniversalService.compress(
              inputPaths: inputPaths,
              outputPath: outPath,
              format: format,
              onProgress: (p, s) => onProgress(p, s),
              onLog: (l, e) => onLog(l, e),
            );
            result = {
              'success': res.success,
              'message': res.message,
              'outputFiles': res.outputFiles,
            };
          } else if (action == 'wasm_inspect') {
            final source = payload['source'];
            final rep = await WasmUniversalService.inspect(source);
            result = rep.toJson();
          } else if (action == 'wasm_call') {
            final source = payload['source'];
            final funcName = payload['function']?.toString() ?? 'run';
            final args = (payload['args'] as List?) ?? [];
            final execRes = await WasmUniversalService.callFunction(
              source: source,
              functionName: funcName,
              arguments: args,
            );
            result = execRes;
          } else if (action == 'image_pipeline') {
            final steps = payload['steps'];
            final files = (payload['inputFiles'] as List?)?.map((e) => e.toString()).toList() ?? inputFiles;
            final res = await ToolEngineService.execute(
              handler: 'image_pipeline',
              inputFiles: files,
              params: {'steps': steps},
              outputDir: outputDir,
              onProgress: onProgress,
              onLog: onLog,
            );
            result = {
              'success': res.success,
              'message': res.message,
              'outputFiles': res.outputFiles,
            };
          } else {
            result = {'__error': '未知异步宿主动作: $action'};
          }
        } catch (e) {
          result = {'__error': e.toString()};
        }

        final encoded = jsonEncode(result);
        jsRuntime.evaluate("window.__resolveAsyncCall('$callId', $encoded);");
        jsRuntime.executePendingJob();
      });

      // 4. 注入 Host Bridge 宿主 API (Toolbox.*) 与全局环境
      onProgress(0.15, '正在装载宿主能力接口...');
      final bootstrapScript = _buildBootstrapScript(
        outputDir: outputDir,
        inputFiles: inputFiles,
        formValues: formValues,
        hasNetworkPermission: plugin.hasPermission('network'),
      );
      jsRuntime.evaluate(bootstrapScript);

      // 5. 执行插件 JavaScript 代码
      onProgress(0.3, '正在执行插件逻辑...');
      onLog('>>> 开始执行 JavaScript 逻辑...', false);

      final wrappedRunner = """
      window.__runFinished = false;
      window.__runResult = null;

      (async function() {
        var res = null;
        try {
          var fetch = window.fetch;
          $scriptSource
          ;
          if (typeof run === 'function') {
            res = await run({
              inputFiles: Toolbox.env.inputFiles,
              outputDir: Toolbox.env.outputDir,
              params: Toolbox.env.params,
              inputs: Toolbox.env.params
            });
          } else {
            res = { success: true, message: '执行完成' };
          }
        } catch(err) {
          res = { success: false, message: (err && err.stack) ? err.stack : String(err) };
        } finally {
          window.__runResult = res;
          window.__runFinished = true;
          try {
            sendMessage('ToolboxChannel_Done', JSON.stringify(res));
          } catch(e) {}
        }
      })();
      """;

      jsRuntime.evaluate(wrappedRunner);
      jsRuntime.executePendingJob();

      // 纯事件驱动驱动循环，免除旧版 evaluate("window.__runFinished") 每次 20ms 的 JS 字符串重编译与求值开销
      while (!runCompleter.isCompleted && !_wasCancelled) {
        await Future.delayed(const Duration(milliseconds: 5));
        jsRuntime.executePendingJob();
      }

      dynamic completionData;
      if (runCompleter.isCompleted) {
        completionData = await runCompleter.future;
      }

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
      dynamic resultData;
      String? resultText;

      dynamic decoded = completionData;
      if (decoded is String) {
        try {
          decoded = jsonDecode(decoded);
        } catch (_) {}
      }
      if (decoded == null) {
        final fallback = jsRuntime.evaluate("JSON.stringify(window.__runResult)");
        if (!fallback.isError && fallback.stringResult.isNotEmpty && fallback.stringResult != 'null') {
          try {
            decoded = jsonDecode(fallback.stringResult);
          } catch (_) {}
        }
      }

      if (decoded is Map) {
        onLog('>>> 脚本执行返回: ${jsonEncode(decoded)}', false);
        if (decoded['success'] == false) {
          isSuccess = false;
        }
        if (decoded['message'] != null) {
          message = decoded['message'].toString();
        }
        if (decoded.containsKey('data')) {
          resultData = decoded['data'];
        }
        if (decoded.containsKey('text')) {
          resultText = decoded['text']?.toString();
        } else if (resultData != null && resultData is! String) {
          resultText = const JsonEncoder.withIndent('  ').convert(resultData);
        } else if (resultData is String) {
          resultText = resultData;
        }
      } else if (decoded != null) {
        resultData = decoded;
        resultText = decoded.toString();
        onLog('>>> 脚本执行返回: $decoded', false);
      } else {
        isSuccess = false;
        message = 'JavaScript 执行异常或无返回值';
        onLog('>>> $message', true);
      }

        if (generatedFiles.isNotEmpty && isSuccess && (message == '脚本执行完成' || message.isEmpty)) {
          message = '处理成功！共生成 ${generatedFiles.length} 个输出文件';
        }

      onProgress(1.0, isSuccess ? '执行完成！' : '执行失败');

      return ProcessingResult(
        success: isSuccess,
        message: message,
        outputFiles: generatedFiles,
        resultData: resultData,
        resultText: resultText,
      );
    } catch (e, stack) {
      onLog('>>> 运行时异常: $e\n$stack', true);
      return ProcessingResult(
        success: false,
        message: 'QuickJS 沙箱运行异常: $e',
      );
    } finally {
      _activeCompleter = null;
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
    required List<String> inputFiles,
    String? pluginDirectory,
    required String pluginDataDir,
    required PluginManifest plugin,
  }) {
    final isUnrestricted = plugin.hasUnrestrictedFsPermission;
    final allowParentDir = plugin.hasReadParentDirPermission;

    switch (action) {
      // --- 文件系统 (fs) ---
      case 'fs_read':
        final filePath = payload['path']?.toString() ?? '';
        _assertPathInJail(
          filePath,
          outputDir: outputDir,
          inputFiles: inputFiles,
          pluginDirectory: pluginDirectory,
          pluginDataDir: pluginDataDir,
          isWrite: false,
          isUnrestricted: isUnrestricted,
          allowParentDir: allowParentDir,
        );
        final isBase64 = payload['isBase64'] == true || payload['encoding'] == 'base64';
        final file = File(filePath);
        if (!file.existsSync()) throw Exception('文件不存在: $filePath');
        if (isBase64) {
          return base64Encode(file.readAsBytesSync());
        }
        return file.readAsStringSync();

      case 'fs_write':
        final filePath = payload['path']?.toString() ?? '';
        _assertPathInJail(
          filePath,
          outputDir: outputDir,
          inputFiles: inputFiles,
          pluginDirectory: pluginDirectory,
          pluginDataDir: pluginDataDir,
          isWrite: true,
          isUnrestricted: isUnrestricted,
        );
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
        _assertPathInJail(
          target,
          outputDir: outputDir,
          inputFiles: inputFiles,
          pluginDirectory: pluginDirectory,
          pluginDataDir: pluginDataDir,
          isWrite: false,
          isUnrestricted: isUnrestricted,
          allowParentDir: allowParentDir,
        );
        return File(target).existsSync() || Directory(target).existsSync();

      case 'fs_list':
        final dirPath = payload['path']?.toString() ?? '';
        _assertPathInJail(
          dirPath,
          outputDir: outputDir,
          inputFiles: inputFiles,
          pluginDirectory: pluginDirectory,
          pluginDataDir: pluginDataDir,
          isWrite: false,
          isUnrestricted: isUnrestricted,
          allowParentDir: allowParentDir,
        );
        final d = Directory(dirPath);
        if (!d.existsSync()) return [];
        return d.listSync().map((e) => e.path).toList();

      case 'fs_mkdir':
        final dirPath = payload['path']?.toString() ?? '';
        _assertPathInJail(
          dirPath,
          outputDir: outputDir,
          inputFiles: inputFiles,
          pluginDirectory: pluginDirectory,
          pluginDataDir: pluginDataDir,
          isWrite: true,
          isUnrestricted: isUnrestricted,
        );
        Directory(dirPath).createSync(recursive: true);
        return true;

      case 'fs_delete':
      case 'fs_remove':
        final target = payload['path']?.toString()?.trim() ?? '';
        if (target.isEmpty) return false;
        _assertPathInJail(
          target,
          outputDir: outputDir,
          inputFiles: inputFiles,
          pluginDirectory: pluginDirectory,
          pluginDataDir: pluginDataDir,
          isWrite: true,
          isUnrestricted: isUnrestricted,
        );
        final file = File(target);
        if (file.existsSync()) {
          file.deleteSync();
          return true;
        }
        final dir = Directory(target);
        if (dir.existsSync()) {
          dir.deleteSync(recursive: true);
          return true;
        }
        return false;

      case 'fs_size':
        final target = payload['path']?.toString() ?? '';
        _assertPathInJail(
          target,
          outputDir: outputDir,
          inputFiles: inputFiles,
          pluginDirectory: pluginDirectory,
          pluginDataDir: pluginDataDir,
          isWrite: false,
          isUnrestricted: isUnrestricted,
          allowParentDir: allowParentDir,
        );
        final f = File(target);
        return f.existsSync() ? f.lengthSync() : 0;

      // --- 插件专属持久化存储 (storage) ---
      case 'storage_get':
        final key = payload['key']?.toString() ?? '';
        final storageFile = File(p.join(pluginDataDir, 'storage.json'));
        if (!storageFile.existsSync()) return null;
        try {
          final map = jsonDecode(storageFile.readAsStringSync()) as Map?;
          return map?[key];
        } catch (_) {
          return null;
        }

      case 'storage_set':
        final key = payload['key']?.toString() ?? '';
        final val = payload['value'];
        final storageFile = File(p.join(pluginDataDir, 'storage.json'));
        storageFile.parent.createSync(recursive: true);
        Map<String, dynamic> map = {};
        if (storageFile.existsSync()) {
          try {
            map = Map<String, dynamic>.from(jsonDecode(storageFile.readAsStringSync()) as Map);
          } catch (_) {}
        }
        map[key] = val;
        storageFile.writeAsStringSync(jsonEncode(map));
        return true;

      case 'storage_delete':
        final key = payload['key']?.toString() ?? '';
        final storageFile = File(p.join(pluginDataDir, 'storage.json'));
        if (!storageFile.existsSync()) return true;
        try {
          final map = Map<String, dynamic>.from(jsonDecode(storageFile.readAsStringSync()) as Map);
          map.remove(key);
          storageFile.writeAsStringSync(jsonEncode(map));
        } catch (_) {}
        return true;

      case 'storage_getAll':
        final storageFile = File(p.join(pluginDataDir, 'storage.json'));
        if (!storageFile.existsSync()) return {};
        try {
          return jsonDecode(storageFile.readAsStringSync());
        } catch (_) {
          return {};
        }

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
        if (!plugin.hasPermission('network')) {
          throw Exception('沙箱安全拦截: 插件未在 manifest.json 中声明 "network" 权限，已阻止发起外部 HTTP 请求');
        }
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
        if (!plugin.hasPermission('network')) {
          throw Exception('沙箱安全拦截: 插件未在 manifest.json 中声明 "network" 权限，已阻止发起外部 HTTP 请求');
        }
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
    bool hasNetworkPermission = false,
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

    window.__pendingAsyncCalls = {};
    window.__resolveAsyncCall = function(callId, result) {
      if (window.__pendingAsyncCalls[callId]) {
        var handler = window.__pendingAsyncCalls[callId];
        delete window.__pendingAsyncCalls[callId];
        if (result && result.__error) {
          handler.reject(new Error(result.__error));
        } else {
          handler.resolve(result);
        }
      }
    };

    function __wrapResponse(res) {
      if (!res) return res;
      res.status = res.statusCode || 200;
      res.ok = (res.status >= 200 && res.status < 300);
      res.statusText = res.ok ? 'OK' : 'Error';
      res.text = function() { return Promise.resolve(res.body || ''); };
      res.json = function() {
        try {
          return Promise.resolve(JSON.parse(res.body || ''));
        } catch (e) {
          return Promise.reject(e);
        }
      };
      return res;
    }

    function __Toolbox_asyncCall(action, payload) {
      return new Promise(function(resolve, reject) {
        var callId = 'call_' + Math.random().toString(36).substring(2);
        window.__pendingAsyncCalls[callId] = { resolve: resolve, reject: reject };
        sendMessage('ToolboxAsyncCall', JSON.stringify({ callId: callId, action: action, payload: payload || {} }));
      });
    }

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
        readFile: function(path, isBase64) {
          return __Toolbox_syncCall('fs_read', { path: path, isBase64: !!isBase64 });
        },
        readBytes: function(path) {
          return __Toolbox_syncCall('fs_read', { path: path, isBase64: true });
        },
        readBinary: function(path) {
          var b64 = __Toolbox_syncCall('fs_read', { path: path, isBase64: true });
          return Toolbox.utils.base64ToBytes(b64);
        },
        readText: function(path) {
          return __Toolbox_syncCall('fs_read', { path: path, isBase64: false });
        },
        writeFile: function(path, content, isBase64) {
          if (content && typeof content === 'object' && (content instanceof Uint8Array || (content.buffer && content.buffer instanceof ArrayBuffer))) {
            content = Toolbox.utils.bytesToBase64(content);
            isBase64 = true;
          }
          return __Toolbox_syncCall('fs_write', { path: path, content: content, isBase64: !!isBase64 });
        },
        writeBinary: function(path, bytes) {
          var b64 = (bytes && typeof bytes === 'object' && (bytes instanceof Uint8Array || (bytes.buffer && bytes.buffer instanceof ArrayBuffer)))
            ? Toolbox.utils.bytesToBase64(bytes)
            : String(bytes || '');
          return __Toolbox_syncCall('fs_write', { path: path, content: b64, isBase64: true });
        },
        exists: function(path) {
          return __Toolbox_syncCall('fs_exists', { path: path });
        },
        listFiles: function(path) {
          return __Toolbox_syncCall('fs_list', { path: path });
        },
        readDir: function(path) {
          return __Toolbox_syncCall('fs_list', { path: path });
        },
        list: function(path) {
          return __Toolbox_syncCall('fs_list', { path: path });
        },
        mkdir: function(path) {
          return __Toolbox_syncCall('fs_mkdir', { path: path });
        },
        remove: function(path) {
          return __Toolbox_syncCall('fs_delete', { path: path });
        },
        delete: function(path) {
          return __Toolbox_syncCall('fs_delete', { path: path });
        },
        fileSize: function(path) {
          return __Toolbox_syncCall('fs_size', { path: path });
        }
      },
      storage: {
        get: function(key, defaultValue) {
          var res = __Toolbox_syncCall('storage_get', { key: key });
          return (res !== undefined && res !== null) ? res : defaultValue;
        },
        set: function(key, value) {
          return __Toolbox_syncCall('storage_set', { key: key, value: value });
        },
        remove: function(key) {
          return __Toolbox_syncCall('storage_delete', { key: key });
        },
        delete: function(key) {
          return __Toolbox_syncCall('storage_delete', { key: key });
        },
        getAll: function() {
          return __Toolbox_syncCall('storage_getAll', {}) || {};
        }
      },
      utils: {
        base64ToBytes: function(b64) {
          var b64Chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
          var lookup = new Uint8Array(256);
          for (var i = 0; i < b64Chars.length; i++) lookup[b64Chars.charCodeAt(i)] = i;
          var raw = String(b64 || '').trim();
          var pad = 0;
          if (raw.endsWith('==')) pad = 2;
          else if (raw.endsWith('=')) pad = 1;
          var clean = raw.replace(/[^A-Za-z0-9+/]/g, '');
          var totalChars = clean.length + pad;
          var arrLen = Math.floor(totalChars * 3 / 4) - pad;
          if (arrLen < 0) arrLen = 0;
          var bytes = new Uint8Array(arrLen);
          var curByte = 0;
          for (var j = 0; j < clean.length; j += 4) {
            var enc1 = lookup[clean.charCodeAt(j)];
            var enc2 = (j + 1 < clean.length) ? lookup[clean.charCodeAt(j + 1)] : 0;
            var enc3 = (j + 2 < clean.length) ? lookup[clean.charCodeAt(j + 2)] : 0;
            var enc4 = (j + 3 < clean.length) ? lookup[clean.charCodeAt(j + 3)] : 0;
            if (curByte < arrLen) bytes[curByte++] = (enc1 << 2) | (enc2 >> 4);
            if (curByte < arrLen) bytes[curByte++] = ((enc2 & 15) << 4) | (enc3 >> 2);
            if (curByte < arrLen) bytes[curByte++] = ((enc3 & 3) << 6) | enc4;
          }
          return bytes;
        },
        bytesToBase64: function(bytes) {
          var b64Chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
          var len = bytes ? (bytes.length || bytes.byteLength || 0) : 0;
          if (len === 0) return '';
          var parts = [];
          var chunk = '';
          for (var i = 0; i < len; i += 3) {
            var b1 = bytes[i];
            var b2 = i + 1 < len ? bytes[i + 1] : 0;
            var b3 = i + 2 < len ? bytes[i + 2] : 0;
            chunk += b64Chars.charAt(b1 >> 2);
            chunk += b64Chars.charAt(((b1 & 3) << 4) | (b2 >> 4));
            chunk += (i + 1 < len) ? b64Chars.charAt(((b2 & 15) << 2) | (b3 >> 6)) : '=';
            chunk += (i + 2 < len) ? b64Chars.charAt(b3 & 63) : '=';
            if (chunk.length >= 8192) {
              parts.push(chunk);
              chunk = '';
            }
          }
          if (chunk.length > 0) parts.push(chunk);
          return parts.join('');
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
      archive: {
        extract: function(archivePath, outputDir, password) {
          return __Toolbox_asyncCall('archive_extract', { archivePath: archivePath, outputDir: outputDir, password: password });
        },
        compress: function(inputPaths, outputPath, format) {
          return __Toolbox_asyncCall('archive_compress', { inputPaths: inputPaths, outputPath: outputPath, format: format || 'zip' });
        }
      },
      image: {
        pipeline: function(steps, inputFiles) {
          return __Toolbox_asyncCall('image_pipeline', { steps: steps, inputFiles: inputFiles || [] });
        }
      },
      wasm: {
        inspect: function(wasmSource) {
          return __Toolbox_asyncCall('wasm_inspect', { source: wasmSource });
        },
        call: function(wasmSource, functionName, args) {
          return __Toolbox_asyncCall('wasm_call', {
            source: wasmSource,
            function: functionName,
            args: args || []
          });
        }
      },
      http: {
        // 现代标准异步非阻塞网络接口 (Promise-based)
        getAsync: function(url, headers) {
          return __Toolbox_asyncCall('http_get', { url: url, headers: headers || {} }).then(__wrapResponse);
        },
        postAsync: function(url, body, headers) {
          return __Toolbox_asyncCall('http_post', { url: url, body: body || '', headers: headers || {} }).then(__wrapResponse);
        },
        fetch: function(url, options) {
          options = options || {};
          var method = (options.method || 'GET').toUpperCase();
          var body = options.body;
          if (body && typeof body === 'object') {
            body = JSON.stringify(body);
          }
          return __Toolbox_asyncCall('http_request', {
            url: url,
            method: method,
            headers: options.headers || {},
            body: body || ''
          }).then(__wrapResponse);
        },
        // 向后兼容同步方法
        get: function(url, headers) {
          return __Toolbox_syncCall('http_get', { url: url, headers: headers || {} });
        },
        post: function(url, body, headers) {
          return __Toolbox_syncCall('http_post', { url: url, body: body || '', headers: headers || {} });
        }
      }
    };

    if ($hasNetworkPermission) {
      fetch = Toolbox.http.fetch;
      window.fetch = Toolbox.http.fetch;
      global.fetch = Toolbox.http.fetch;
    } else {
      var __blockNet = function() {
        throw new Error('沙箱安全拦截: 插件未在 manifest.json 中声明 "network" 权限，已阻止发起网络请求');
      };
      fetch = __blockNet;
      window.fetch = __blockNet;
      global.fetch = __blockNet;
      XMLHttpRequest = __blockNet;
      window.XMLHttpRequest = __blockNet;
      global.XMLHttpRequest = __blockNet;
    }

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

  /// 校验目标路径是否受限于沙箱合法目录 (Path Jail)
  /// 严禁任意越权访问用户系统敏感目录 (如 .ssh, 操作系统关键文件等)
  static void _assertPathInJail(
    String targetPath, {
    required String outputDir,
    required List<String> inputFiles,
    String? pluginDirectory,
    required String pluginDataDir,
    bool isWrite = false,
    bool isUnrestricted = false,
    bool allowParentDir = false,
  }) {
    if (isUnrestricted) return;
    final trimmed = targetPath.trim();
    if (trimmed.isEmpty) {
      throw Exception('沙箱安全拦截: 路径不能为空');
    }

    final allowedRoots = <String>[];
    allowedRoots.add(outputDir);
    allowedRoots.add(p.join(Directory.systemTemp.path, 'toolbox_temp'));
    allowedRoots.add(pluginDataDir);

    if (!isWrite) {
      if (pluginDirectory != null && pluginDirectory.isNotEmpty) {
        allowedRoots.add(pluginDirectory);
      }
      if (allowParentDir) {
        for (final f in inputFiles) {
          allowedRoots.add(File(f).parent.path);
        }
      }
    }

    final canonicalTarget = p.canonicalize(trimmed);
    final isWithinAllowedRoot = allowedRoots.any((root) => _isPathWithinRoot(canonicalTarget, root));
    if (isWithinAllowedRoot) return;

    // 只读访问模式下，严格允许读取用户显式传入的具体输入文件，或者显式传入目录内的文件
    if (!isWrite) {
      final isInputFileOrInSelectedDir = inputFiles.any((f) {
        final canF = p.canonicalize(f);
        if (Directory(canF).existsSync()) {
          return _isPathWithinRoot(canonicalTarget, canF);
        }
        return Platform.isWindows
            ? canF.toLowerCase() == canonicalTarget.toLowerCase()
            : canF == canonicalTarget;
      });
      if (isInputFileOrInSelectedDir) return;
    }

    throw Exception('沙箱安全拦截: 目标路径超出插件合法沙箱范围: $trimmed');
  }

  static bool _isPathWithinRoot(String canonicalTarget, String rawRoot) {
    final canonicalRoot = p.canonicalize(rawRoot);
    if (Platform.isWindows) {
      final targetLower = canonicalTarget.toLowerCase();
      final rootLower = canonicalRoot.toLowerCase();
      return targetLower == rootLower ||
          targetLower.startsWith(rootLower.endsWith('\\') ? rootLower : '$rootLower\\');
    } else {
      return canonicalTarget == canonicalRoot ||
          canonicalTarget.startsWith(canonicalRoot.endsWith('/') ? canonicalRoot : '$canonicalRoot/');
    }
  }
}
