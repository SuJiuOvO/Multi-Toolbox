import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:window_manager/window_manager.dart';

import '../models/plugin_manifest.dart';
import '../services/plugin_manager_service.dart';
import '../services/webview_bridge_service.dart';

/// 动态富交互 (WebView) 运行容器页面
class WebviewToolRunnerPage extends StatefulWidget {
  final PluginManifest plugin;

  const WebviewToolRunnerPage({super.key, required this.plugin});

  @override
  State<WebviewToolRunnerPage> createState() => _WebviewToolRunnerPageState();
}

class _WebviewToolRunnerPageState extends State<WebviewToolRunnerPage> {
  InAppWebViewController? _webViewController;
  WebviewBridgeService? _bridgeService;
  HttpServer? _localServer;
  String? _serverUrl;
  bool _isLoading = true;
  String? _errorMessage;
  bool _isFullscreen = false;
  bool? _originalDesktopFullscreen;
  bool _isPluginDark = false;

  static const Map<String, String> _mimeTypes = {
    '.html': 'text/html; charset=utf-8',
    '.htm': 'text/html; charset=utf-8',
    '.js': 'application/javascript; charset=utf-8',
    '.mjs': 'application/javascript; charset=utf-8',
    '.css': 'text/css; charset=utf-8',
    '.json': 'application/json; charset=utf-8',
    '.wasm': 'application/wasm',
    '.png': 'image/png',
    '.jpg': 'image/jpeg',
    '.jpeg': 'image/jpeg',
    '.gif': 'image/gif',
    '.svg': 'image/svg+xml',
    '.webp': 'image/webp',
    '.ico': 'image/x-icon',
    '.woff': 'font/woff',
    '.woff2': 'font/woff2',
    '.ttf': 'font/ttf',
    '.txt': 'text/plain; charset=utf-8',
  };

  @override
  void initState() {
    super.initState();
    _initContainer();
  }

  Future<void> _initContainer() async {
    try {
      final pluginDir = widget.plugin.localDir ??
          await PluginManagerService().getPluginDir(widget.plugin.id);
      if (pluginDir == null || !await Directory(pluginDir).exists()) {
        throw Exception('插件安装目录未找到，请先重新安装该插件。');
      }

      final appSupport = await getApplicationSupportDirectory();
      final pluginDataDir = p.join(appSupport.path, 'plugin_data', widget.plugin.id);
      await Directory(pluginDataDir).create(recursive: true);

      _isPluginDark = widget.plugin.webViewRunner?.initialTheme == 'dark';

      _bridgeService = WebviewBridgeService(
        plugin: widget.plugin,
        pluginLocalDir: pluginDir,
        pluginDataDir: pluginDataDir,
        onShowToast: _handleToast,
        onConfirmDialog: _handleConfirmDialog,
        onSetFullscreen: _toggleFullscreen,
        onThemeChanged: (isDark) {
          if (mounted && _isPluginDark != isDark) {
            setState(() {
              _isPluginDark = isDark;
            });
          }
        },
        onEmitEvent: (event, payload) {
          if (!mounted) return;
          _webViewController?.evaluateJavascript(
            source: 'window.Toolbox && window.Toolbox.emit(${jsonEncode(event)}, ${jsonEncode(payload)});',
          );
        },
      );

      // 启动轻量环回 HTTP 服务器以避开 file:// 域的同源与模块限制
      _localServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      _localServer!.listen((HttpRequest request) => _handleHttpRequest(request, pluginDir));

      final entryRel = widget.plugin.webViewRunner?.entry.replaceAll(r'\', '/') ?? 'dist/index.html';
      final cleanEntry = entryRel.startsWith('/') ? entryRel.substring(1) : entryRel;
      _serverUrl = 'http://127.0.0.1:${_localServer!.port}/$cleanEntry';

      // 常亮配置
      if (widget.plugin.webViewRunner?.keepScreenOn == true) {
        await WakelockPlus.enable();
      }

      // 启动时全屏配置
      if (widget.plugin.webViewRunner?.fullscreenOnStart == true) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _toggleFullscreen(true);
        });
      }

      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _errorMessage = e.toString();
        });
      }
    }
  }

  void _handleHttpRequest(HttpRequest request, String pluginDir) async {
    try {
      var reqPath = request.uri.path;
      if (reqPath.isEmpty || reqPath == '/') {
        reqPath = '/dist/index.html';
      }
      final decodedPath = Uri.decodeComponent(reqPath);
      final targetFile = File(p.join(pluginDir, decodedPath.startsWith('/') ? decodedPath.substring(1) : decodedPath));
      final canonicalTarget = p.canonicalize(targetFile.path);
      final canonicalRoot = p.canonicalize(pluginDir);

      // Path Jail: 严格阻止父目录穿越
      final separator = Platform.isWindows ? r'\' : '/';
      final rootPrefix = canonicalRoot.endsWith(separator) ? canonicalRoot : '$canonicalRoot$separator';
      final normTarget = Platform.isWindows ? canonicalTarget.toLowerCase() : canonicalTarget;
      final normRoot = Platform.isWindows ? rootPrefix.toLowerCase() : rootPrefix;

      if (!normTarget.startsWith(normRoot) && normTarget != (Platform.isWindows ? canonicalRoot.toLowerCase() : canonicalRoot)) {
        request.response.statusCode = HttpStatus.forbidden;
        request.response.write('403 Forbidden: Path traversal out of plugin root');
        await request.response.close();
        return;
      }

      if (!await targetFile.exists()) {
        request.response.statusCode = HttpStatus.notFound;
        request.response.write('404 Not Found: ${request.uri.path}');
        await request.response.close();
        return;
      }

      final ext = p.extension(targetFile.path).toLowerCase();
      final mime = _mimeTypes[ext] ?? 'application/octet-stream';
      request.response.headers.set(HttpHeaders.contentTypeHeader, mime);
      request.response.headers.set('Access-Control-Allow-Origin', '*');
      request.response.headers.set('Cache-Control', 'no-cache');

      await request.response.addStream(targetFile.openRead());
      await request.response.close();
    } catch (e) {
      try {
        request.response.statusCode = HttpStatus.internalServerError;
        request.response.write('500 Internal Error: $e');
        await request.response.close();
      } catch (_) {}
    }
  }

  Future<void> _toggleFullscreen(bool fullscreen) async {
    if (_isFullscreen == fullscreen) return;
    _isFullscreen = fullscreen;
    if (Platform.isWindows) {
      try {
        await windowManager.ensureInitialized();
        if (fullscreen) {
          _originalDesktopFullscreen = await windowManager.isFullScreen();
          await windowManager.setFullScreen(true);
        } else {
          await windowManager.setFullScreen(_originalDesktopFullscreen ?? false);
        }
      } catch (_) {}
    } else {
      if (fullscreen) {
        SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
      } else {
        SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
      }
    }
    if (mounted) setState(() {});
  }

  void _handleToast(String message, String type) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).clearSnackBars();
    final isSuccess = type == 'success';
    final isError = type == 'error';
    final accentColor = isSuccess
        ? const Color(0xFF10B981)
        : isError
            ? const Color(0xFFEF4444)
            : const Color(0xFF38BDF8);

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              isSuccess
                  ? Icons.check_circle_rounded
                  : isError
                      ? Icons.error_rounded
                      : Icons.info_rounded,
              color: accentColor,
              size: 20,
            ),
            const SizedBox(width: 10),
            Flexible(
              child: Text(
                message,
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                  color: Color(0xFFF8FAFC),
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
        backgroundColor: const Color(0xEE1E293B),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: const BorderSide(color: Color(0x22FFFFFF), width: 1),
        ),
        elevation: 6,
        margin: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
        duration: const Duration(milliseconds: 2000),
      ),
    );
  }

  Future<bool> _handleConfirmDialog(String title, String message) async {
    if (!mounted) return false;
    final res = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('确定')),
        ],
      ),
    );
    return res ?? false;
  }

  @override
  void dispose() {
    _bridgeService?.dispose();
    _localServer?.close(force: true);
    if (widget.plugin.webViewRunner?.keepScreenOn == true) {
      WakelockPlus.disable();
    }
    if (_isFullscreen) {
      if (Platform.isWindows) {
        windowManager.setFullScreen(_originalDesktopFullscreen ?? false);
      } else {
        SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
      }
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return Scaffold(
        appBar: AppBar(title: Text(widget.plugin.name)),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    if (_errorMessage != null) {
      return Scaffold(
        appBar: AppBar(title: Text(widget.plugin.name)),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.error_outline, size: 48, color: Colors.red),
                const SizedBox(height: 16),
                Text(_errorMessage!, textAlign: TextAlign.center),
                const SizedBox(height: 24),
                ElevatedButton.icon(
                  onPressed: () {
                    setState(() {
                      _isLoading = true;
                      _errorMessage = null;
                    });
                    _initContainer();
                  },
                  icon: const Icon(Icons.refresh),
                  label: const Text('重试加载'),
                ),
              ],
            ),
          ),
        ),
      );
    }

    final isSystemDark = Theme.of(context).brightness == Brightness.dark;
    final effectiveDark = _isPluginDark || isSystemDark;
    final bgColor = effectiveDark ? const Color(0xFF0F172A) : Theme.of(context).colorScheme.surface;
    final fgColor = effectiveDark ? const Color(0xFFF8FAFC) : Theme.of(context).colorScheme.onSurface;

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) return;
        if (_isFullscreen) {
          await _toggleFullscreen(false);
          return;
        }
        if (await _webViewController?.canGoBack() ?? false) {
          await _webViewController?.goBack();
          return;
        }
        if (context.mounted) {
          Navigator.of(context).pop();
        }
      },
      child: Scaffold(
        backgroundColor: bgColor,
        appBar: _isFullscreen
            ? null
            : AppBar(
                backgroundColor: bgColor,
                foregroundColor: fgColor,
                elevation: 0,
                surfaceTintColor: Colors.transparent,
                title: Text(
                  widget.plugin.name,
                  style: TextStyle(
                    color: fgColor,
                    fontWeight: FontWeight.w600,
                    fontSize: 18,
                  ),
                ),
                bottom: PreferredSize(
                  preferredSize: const Size.fromHeight(1),
                  child: Container(
                    color: effectiveDark
                        ? const Color(0xFF1E293B)
                        : Theme.of(context).colorScheme.outlineVariant.withOpacity(0.3),
                    height: 1,
                  ),
                ),
                actions: [
                  IconButton(
                    icon: Icon(Icons.refresh_rounded, color: fgColor),
                    tooltip: '刷新页面',
                    onPressed: () => _webViewController?.reload(),
                  ),
                  IconButton(
                    icon: Icon(Icons.fullscreen_rounded, color: fgColor),
                    tooltip: '全屏模式',
                    onPressed: () => _toggleFullscreen(true),
                  ),
                ],
              ),
        body: Stack(
          children: [
            InAppWebView(
              initialUrlRequest: URLRequest(url: WebUri(_serverUrl!)),
              initialSettings: InAppWebViewSettings(
                isInspectable: true,
                allowsInlineMediaPlayback: true,
                transparentBackground: true,
                supportZoom: false,
              ),
              initialUserScripts: UnmodifiableListView([
                UserScript(
                  source: WebviewBridgeService.getInjectionScript(),
                  injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
                ),
              ]),
              onWebViewCreated: (controller) {
                _webViewController = controller;
                controller.addJavaScriptHandler(
                  handlerName: 'ToolboxBridge',
                  callback: (args) async {
                    if (args.isEmpty || args[0] is! Map) {
                      return {'success': false, 'error': '无效的 RPC 参数'};
                    }
                    final call = Map<String, dynamic>.from(args[0] as Map);
                    final action = call['action']?.toString() ?? '';
                    final payload = Map<String, dynamic>.from(call['payload'] ?? {});
                    return await _bridgeService?.handleBridgeCall(action, payload);
                  },
                );
              },
              onLoadStop: (controller, url) async {
                final isDark = Theme.of(context).brightness == Brightness.dark;
                // 补充注入一次以确保单页应用 (SPA) 动态更新时 window.Toolbox 始终就绪
                await controller.evaluateJavascript(
                  source: WebviewBridgeService.getInjectionScript(),
                );
                await controller.evaluateJavascript(
                  source: "if (window.Toolbox && window.Toolbox.emit) { window.Toolbox.emit('theme_change', { isDark: $isDark }); }",
                );
              },
            ),
            if (_isFullscreen)
              Positioned(
                top: 16,
                right: 16,
                child: Opacity(
                  opacity: 0.6,
                  child: Material(
                    color: Colors.black54,
                    shape: const CircleBorder(),
                    child: IconButton(
                      icon: const Icon(Icons.fullscreen_exit, color: Colors.white),
                      tooltip: '退出全屏',
                      onPressed: () => _toggleFullscreen(false),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
