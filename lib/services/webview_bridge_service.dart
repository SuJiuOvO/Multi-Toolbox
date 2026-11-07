import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../models/plugin_manifest.dart';
import '../models/ssh_profile.dart';
import 'ssh_connection_service.dart';
import 'windows_uninstaller_service.dart';

/// 动态富交互 (WebView) 宿主沙箱 Bridge 路由调度与安全审计服务
class WebviewBridgeService {
  final PluginManifest plugin;
  final String pluginLocalDir;
  final String pluginDataDir;
  final Set<String> allowedRoots = {};

  // 宿主 UI 代理钩子
  void Function(String message, String type)? onShowToast;
  Future<bool> Function(String title, String message)? onConfirmDialog;
  Future<void> Function(bool fullscreen)? onSetFullscreen;
  void Function(String event, dynamic payload)? onEmitEvent;

  // 可插拔子系统服务实例
  WindowsUninstallerService? _uninstallerService;
  SshConnectionService? _sshService;
  final SshProfileStore? _sshProfileStore;

  WebviewBridgeService({
    required this.plugin,
    required this.pluginLocalDir,
    required this.pluginDataDir,
    this.onShowToast,
    this.onConfirmDialog,
    this.onSetFullscreen,
    this.onEmitEvent,
    WindowsUninstallerService? uninstallerService,
    SshConnectionService? sshService,
    SshProfileStore? sshProfileStore,
  })  : _uninstallerService = uninstallerService,
        _sshService = sshService,
        _sshProfileStore = sshProfileStore {
    // 初始允许访问插件自身目录与私有数据目录
    if (pluginLocalDir.isNotEmpty) {
      allowedRoots.add(p.canonicalize(pluginLocalDir));
    }
    if (pluginDataDir.isNotEmpty) {
      allowedRoots.add(p.canonicalize(pluginDataDir));
    }
  }

  void dispose() {
    _sshService?.disconnect();
  }

  String _prefKey(String key) => 'wv_${plugin.id}_$key';

  /// 校验目标路径是否受限于沙箱合法目录 (Path Jail)
  /// 严禁任意越权访问系统关键目录或宿主用户私有文件
  void assertPathInJail(String targetPath, {required bool isWrite}) {
    final trimmed = targetPath.trim();
    if (trimmed.isEmpty) {
      throw Exception('沙箱安全拦截: 路径不能为空');
    }

    final canonicalTarget = p.canonicalize(trimmed);

    // 写入模式下：只允许写入插件私有数据目录，或用户通过对话框显式选择的目录
    final effectiveRoots = <String>[];
    if (isWrite) {
      if (pluginDataDir.isNotEmpty) {
        effectiveRoots.add(p.canonicalize(pluginDataDir));
      }
      for (final root in allowedRoots) {
        if (root != p.canonicalize(pluginLocalDir)) {
          effectiveRoots.add(root);
        }
      }
    } else {
      // 读取模式下：允许读取插件包内资源、私有数据与用户授权目录
      effectiveRoots.addAll(allowedRoots);
    }

    final isPermitted = effectiveRoots.any((root) => _isPathWithinRoot(canonicalTarget, root));
    if (!isPermitted) {
      throw Exception('沙箱安全拦截: 路径越界访问 [$targetPath] 被拒绝');
    }
  }

  static bool _isPathWithinRoot(String path, String root) {
    final normPath = Platform.isWindows ? path.toLowerCase() : path;
    final normRoot = Platform.isWindows ? root.toLowerCase() : root;
    if (normPath == normRoot) return true;
    final separator = Platform.isWindows ? r'\' : '/';
    final prefix = normRoot.endsWith(separator) ? normRoot : '$normRoot$separator';
    return normPath.startsWith(prefix);
  }

  /// 统一处理 Web 端发起的 RPC 调用
  Future<Map<String, dynamic>> handleBridgeCall(String action, Map<String, dynamic> payload) async {
    try {
      final result = await _dispatchAction(action, payload);
      return {'success': true, 'data': result};
    } catch (e, stack) {
      return {
        'success': false,
        'error': e.toString(),
        'stack': stack.toString(),
      };
    }
  }

  Future<dynamic> _dispatchAction(String action, Map<String, dynamic> payload) async {
    switch (action) {
      // ==========================
      // 1. 本地存储 (Storage API)
      // ==========================
      case 'storage_get': {
        final key = payload['key']?.toString() ?? '';
        final prefs = await SharedPreferences.getInstance();
        final raw = prefs.getString(_prefKey(key));
        if (raw == null) return null;
        try {
          return jsonDecode(raw);
        } catch (_) {
          return raw;
        }
      }
      case 'storage_set': {
        final key = payload['key']?.toString() ?? '';
        final value = payload['value'];
        final prefs = await SharedPreferences.getInstance();
        final serialized = value is String ? value : jsonEncode(value);
        await prefs.setString(_prefKey(key), serialized);
        return true;
      }
      case 'storage_remove': {
        final key = payload['key']?.toString() ?? '';
        final prefs = await SharedPreferences.getInstance();
        await prefs.remove(_prefKey(key));
        return true;
      }
      case 'storage_clear': {
        final prefs = await SharedPreferences.getInstance();
        final prefix = 'wv_${plugin.id}_';
        final keysToRemove = prefs.getKeys().where((k) => k.startsWith(prefix)).toList();
        for (final k in keysToRemove) {
          await prefs.remove(k);
        }
        return true;
      }

      // ==========================
      // 2. 受限文件系统 (FS API)
      // ==========================
      case 'fs_read': {
        final filePath = payload['path']?.toString() ?? '';
        assertPathInJail(filePath, isWrite: false);
        final file = File(filePath);
        if (!await file.exists()) {
          throw Exception('文件不存在: $filePath');
        }
        final encoding = payload['encoding']?.toString().toLowerCase() ?? 'utf8';
        if (encoding == 'base64') {
          final bytes = await file.readAsBytes();
          return base64Encode(bytes);
        }
        return await file.readAsString();
      }
      case 'fs_write': {
        final filePath = payload['path']?.toString() ?? '';
        assertPathInJail(filePath, isWrite: true);
        final content = payload['content']?.toString() ?? '';
        final encoding = payload['encoding']?.toString().toLowerCase() ?? 'utf8';
        final file = File(filePath);
        await file.parent.create(recursive: true);
        if (encoding == 'base64') {
          final bytes = base64Decode(content);
          await file.writeAsBytes(bytes);
        } else {
          await file.writeAsString(content);
        }
        return true;
      }
      case 'fs_exists': {
        final targetPath = payload['path']?.toString() ?? '';
        assertPathInJail(targetPath, isWrite: false);
        return await File(targetPath).exists() || await Directory(targetPath).exists();
      }
      case 'fs_list': {
        final dirPath = payload['path']?.toString() ?? '';
        assertPathInJail(dirPath, isWrite: false);
        final dir = Directory(dirPath);
        if (!await dir.exists()) {
          return <String>[];
        }
        final list = await dir.list().toList();
        return list.map((e) => p.basename(e.path)).toList();
      }

      // ==========================
      // 3. 系统能力 (System API)
      // ==========================
      case 'system_keep_screen_on': {
        final keep = payload['keep'] == true;
        await WakelockPlus.toggle(enable: keep);
        return true;
      }
      case 'system_set_fullscreen': {
        final fs = payload['fullscreen'] == true;
        if (onSetFullscreen != null) {
          await onSetFullscreen!(fs);
        }
        return true;
      }
      case 'system_toast': {
        final message = payload['message']?.toString() ?? '';
        final type = payload['type']?.toString() ?? 'info';
        onShowToast?.call(message, type);
        return true;
      }
      case 'system_copy_text': {
        if (plugin.webViewRunner?.allowClipboard == false) {
          throw Exception('当前插件未申请剪贴板访问权限 (allowClipboard: false)');
        }
        final text = payload['text']?.toString() ?? '';
        await Clipboard.setData(ClipboardData(text: text));
        return true;
      }
      case 'system_read_text': {
        if (plugin.webViewRunner?.allowClipboard == false) {
          throw Exception('当前插件未申请剪贴板读取权限 (allowClipboard: false)');
        }
        final data = await Clipboard.getData(Clipboard.kTextPlain);
        return data?.text ?? '';
      }
      case 'system_open_external': {
        final rawUrl = payload['url']?.toString() ?? '';
        final uri = Uri.tryParse(rawUrl);
        if (uri != null && (uri.isScheme('http') || uri.isScheme('https'))) {
          await launchUrl(uri, mode: LaunchMode.externalApplication);
          return true;
        }
        throw Exception('无效或不支持的外部 URL: $rawUrl');
      }
      case 'system_open_file': {
        final filePath = payload['path']?.toString() ?? '';
        assertPathInJail(filePath, isWrite: false);
        final file = File(filePath);
        if (!await file.exists()) {
          throw Exception('文件不存在: $filePath');
        }
        final res = await OpenFilex.open(filePath);
        return res.type.name;
      }

      // ==========================
      // 4. 对话框能力 (Dialog API)
      // ==========================
      case 'dialog_pick_files': {
        final multiple = payload['multiple'] == true;
        final exts = (payload['extensions'] as List?)?.map((e) => e.toString()).toList();
        final result = await FilePicker.platform.pickFiles(
          allowMultiple: multiple,
          allowedExtensions: exts,
          type: exts != null && exts.isNotEmpty ? FileType.custom : FileType.any,
        );
        if (result == null || result.files.isEmpty) return <String>[];
        final pickedPaths = result.files.map((f) => f.path).whereType<String>().toList();
        for (final pth in pickedPaths) {
          allowedRoots.add(p.canonicalize(File(pth).parent.path));
        }
        return pickedPaths;
      }
      case 'dialog_pick_directory': {
        final dirPath = await FilePicker.platform.getDirectoryPath();
        if (dirPath == null || dirPath.trim().isEmpty) return null;
        allowedRoots.add(p.canonicalize(dirPath));
        return dirPath;
      }
      case 'dialog_save_file': {
        final defaultName = payload['defaultName']?.toString() ?? 'output.bin';
        final exts = (payload['extensions'] as List?)?.map((e) => e.toString()).toList();
        final contentBase64 = payload['contentBase64']?.toString();

        String? savePath;
        if (Platform.isWindows) {
          savePath = await FilePicker.platform.saveFile(
            dialogTitle: payload['dialogTitle']?.toString() ?? '保存文件',
            fileName: defaultName,
            allowedExtensions: exts,
            type: exts != null && exts.isNotEmpty ? FileType.custom : FileType.any,
          );
        } else {
          Directory? saveDir = await getDownloadsDirectory();
          saveDir ??= await getExternalStorageDirectory();
          saveDir ??= await getApplicationDocumentsDirectory();
          savePath = p.join(saveDir.path, defaultName);
        }

        if (savePath == null) return null;

        if (contentBase64 != null && contentBase64.isNotEmpty) {
          final bytes = base64Decode(contentBase64);
          final file = File(savePath);
          await file.parent.create(recursive: true);
          await file.writeAsBytes(bytes);
        }
        allowedRoots.add(p.canonicalize(File(savePath).parent.path));
        return savePath;
      }
      case 'dialog_confirm': {
        final title = payload['title']?.toString() ?? '确认操作';
        final message = payload['message']?.toString() ?? '';
        if (onConfirmDialog != null) {
          return await onConfirmDialog!(title, message);
        }
        return true;
      }

      // ==========================
      // 5. Windows 软件卸载 (Uninstaller API)
      // ==========================
      case 'uninstaller_is_supported': {
        return Platform.isWindows;
      }
      case 'uninstaller_load_apps': {
        if (!Platform.isWindows) {
          throw Exception('软件卸载功能仅支持 Windows 平台');
        }
        _uninstallerService ??= WindowsUninstallerService();
        final inventory = await _uninstallerService!.loadApps();
        return {
          'apps': inventory.apps.map((a) => a.toJson()).toList(),
          'warnings': inventory.warnings,
        };
      }
      case 'uninstaller_load_icons': {
        if (!Platform.isWindows) return <String, String>{};
        _uninstallerService ??= WindowsUninstallerService();
        final appsJson = payload['apps'] as List? ?? [];
        final apps = appsJson
            .map((a) => InstalledWindowsApp.fromJson(Map<String, dynamic>.from(a)))
            .toList();
        final icons = await _uninstallerService!.loadIconPaths(apps);
        return icons;
      }
      case 'uninstaller_execute': {
        if (!Platform.isWindows) {
          throw Exception('软件卸载功能仅支持 Windows 平台');
        }
        _uninstallerService ??= WindowsUninstallerService();
        final appJson = payload['app'];
        if (appJson == null) throw Exception('缺少目标应用数据');
        final app = InstalledWindowsApp.fromJson(Map<String, dynamic>.from(appJson));
        final asAdmin = payload['asAdmin'] == true;
        final res = await _uninstallerService!.uninstall(app, elevate: asAdmin);
        return {
          'exitCode': res.exitCode,
          'succeeded': res.succeeded,
          'restartRequired': res.restartRequired,
          'message': res.message,
        };
      }
      case 'uninstaller_scan_residues': {
        if (!Platform.isWindows) return [];
        _uninstallerService ??= WindowsUninstallerService();
        final appJson = payload['app'];
        if (appJson == null) throw Exception('缺少目标应用数据');
        final app = InstalledWindowsApp.fromJson(Map<String, dynamic>.from(appJson));
        final candidates = await _uninstallerService!.scanResidue(app);
        return candidates.map((c) => c.toJson()).toList();
      }
      case 'uninstaller_clean_residues': {
        if (!Platform.isWindows) return {'deletedPaths': [], 'errors': []};
        _uninstallerService ??= WindowsUninstallerService();
        final candidatesJson = payload['candidates'] as List? ?? [];
        final candidates = candidatesJson
            .map((c) => WindowsResidueCandidate.fromJson(Map<String, dynamic>.from(c)))
            .toList();
        final res = await _uninstallerService!.deleteResidue(candidates);
        return res.toJson();
      }

      // ==========================
      // 6. SSH 安全终端 (SSH Terminal API)
      // ==========================
      case 'ssh_load_profiles': {
        final store = _sshProfileStore ?? SshProfileStore();
        final profiles = await store.load();
        return profiles.map((p) => p.toJson()).toList();
      }
      case 'ssh_save_profile': {
        final store = _sshProfileStore ?? SshProfileStore();
        final profileJson = payload['profile'];
        if (profileJson == null) throw Exception('缺少 Profile 配置');
        final profile = SshProfile.fromJson(Map<String, dynamic>.from(profileJson));
        final profiles = await store.load();
        final index = profiles.indexWhere((p) => p.authority == profile.authority);
        if (index >= 0) {
          profiles[index] = profile;
        } else {
          profiles.add(profile);
        }
        await store.save(profiles);
        return true;
      }
      case 'ssh_delete_profile': {
        final store = _sshProfileStore ?? SshProfileStore();
        final authority = payload['authority']?.toString() ?? '';
        final profiles = await store.load();
        profiles.removeWhere((p) => p.authority == authority);
        await store.save(profiles);
        return true;
      }
      case 'ssh_connect': {
        final profileJson = payload['profile'];
        if (profileJson == null) throw Exception('缺少 Profile 配置');
        final profile = SshProfile.fromJson(Map<String, dynamic>.from(profileJson));
        final password = payload['password']?.toString() ?? '';
        final privateKey = payload['privateKey']?.toString() ?? '';
        final passphrase = payload['passphrase']?.toString() ?? '';
        final cols = (payload['columns'] as num?)?.toInt() ?? 80;
        final rows = (payload['rows'] as num?)?.toInt() ?? 24;

        _sshService ??= SshConnectionService();
        await _sshService!.connect(
          profile: profile,
          password: password,
          privateKey: privateKey,
          passphrase: passphrase,
          confirmHostKey: (algo, fp) async {
            if (onConfirmDialog != null) {
              return await onConfirmDialog!(
                '验证主机指纹',
                '首次连接服务器 $algo 指纹为：\n$fp\n是否确认信任并继续连接？',
              );
            }
            return true;
          },
          onOutput: (text) {
            onEmitEvent?.call('ssh_output', {'text': text});
          },
          onClosed: (msg) {
            onEmitEvent?.call('ssh_closed', {'message': msg});
          },
          columns: cols,
          rows: rows,
        );
        return true;
      }
      case 'ssh_send': {
        final text = payload['text']?.toString() ?? '';
        _sshService?.send(text);
        return true;
      }
      case 'ssh_resize': {
        final cols = (payload['columns'] as num?)?.toInt() ?? 80;
        final rows = (payload['rows'] as num?)?.toInt() ?? 24;
        _sshService?.resize(cols, rows);
        return true;
      }
      case 'ssh_disconnect': {
        _sshService?.disconnect();
        return true;
      }

      default:
        throw Exception('未知的 Host Bridge 动作: $action');
    }
  }

  /// 生成在 Webview 启动时注入的全局 `window.Toolbox` API 脚本
  static String getInjectionScript() {
    return '''
(function() {
  if (window.Toolbox) return;

  window.Toolbox = {
    _handlers: {},

    invoke: function(action, payload) {
      if (!window.flutter_inappwebview || !window.flutter_inappwebview.callHandler) {
        return Promise.reject(new Error("Host Bridge 未初始化"));
      }
      return window.flutter_inappwebview.callHandler('ToolboxBridge', {
        action: action,
        payload: payload || {}
      }).then(function(res) {
        if (!res) return null;
        if (res.success) {
          return res.data;
        } else {
          return Promise.reject(new Error(res.error || "调用失败"));
        }
      });
    },

    storage: {
      get: function(key) { return Toolbox.invoke('storage_get', { key: key }); },
      set: function(key, val) { return Toolbox.invoke('storage_set', { key: key, value: val }); },
      remove: function(key) { return Toolbox.invoke('storage_remove', { key: key }); },
      clear: function() { return Toolbox.invoke('storage_clear', {}); }
    },

    fs: {
      readFile: function(path, enc) { return Toolbox.invoke('fs_read', { path: path, encoding: enc || 'utf8' }); },
      writeFile: function(path, content, enc) { return Toolbox.invoke('fs_write', { path: path, content: content, encoding: enc || 'utf8' }); },
      exists: function(path) { return Toolbox.invoke('fs_exists', { path: path }); },
      listDir: function(path) { return Toolbox.invoke('fs_list', { path: path }); }
    },

    system: {
      setKeepScreenOn: function(keep) { return Toolbox.invoke('system_keep_screen_on', { keep: !!keep }); },
      setFullscreen: function(fs) { return Toolbox.invoke('system_set_fullscreen', { fullscreen: !!fs }); },
      showToast: function(msg, type) { return Toolbox.invoke('system_toast', { message: msg, type: type || 'info' }); },
      copyText: function(text) { return Toolbox.invoke('system_copy_text', { text: text }); },
      readText: function() { return Toolbox.invoke('system_read_text', {}); },
      openExternal: function(url) { return Toolbox.invoke('system_open_external', { url: url }); },
      openFile: function(path) { return Toolbox.invoke('system_open_file', { path: path }); }
    },

    dialog: {
      pickFiles: function(opts) { return Toolbox.invoke('dialog_pick_files', opts || {}); },
      pickDirectory: function() { return Toolbox.invoke('dialog_pick_directory', {}); },
      saveFile: function(opts) { return Toolbox.invoke('dialog_save_file', opts || {}); },
      confirm: function(title, msg) { return Toolbox.invoke('dialog_confirm', { title: title, message: msg }); }
    },

    uninstaller: {
      isSupported: function() { return Toolbox.invoke('uninstaller_is_supported', {}); },
      loadApps: function() { return Toolbox.invoke('uninstaller_load_apps', {}); },
      loadIcons: function(apps) { return Toolbox.invoke('uninstaller_load_icons', { apps: apps || [] }); },
      execute: function(app, asAdmin) { return Toolbox.invoke('uninstaller_execute', { app: app, asAdmin: !!asAdmin }); },
      scanResidues: function(app) { return Toolbox.invoke('uninstaller_scan_residues', { app: app }); },
      cleanResidues: function(candidates) { return Toolbox.invoke('uninstaller_clean_residues', { candidates: candidates || [] }); }
    },

    ssh: {
      loadProfiles: function() { return Toolbox.invoke('ssh_load_profiles', {}); },
      saveProfile: function(p) { return Toolbox.invoke('ssh_save_profile', { profile: p }); },
      deleteProfile: function(auth) { return Toolbox.invoke('ssh_delete_profile', { authority: auth }); },
      connect: function(opts) { return Toolbox.invoke('ssh_connect', opts || {}); },
      send: function(text) { return Toolbox.invoke('ssh_send', { text: text }); },
      resize: function(cols, rows) { return Toolbox.invoke('ssh_resize', { columns: cols, rows: rows }); },
      disconnect: function() { return Toolbox.invoke('ssh_disconnect', {}); }
    },

    on: function(event, callback) {
      if (!this._handlers[event]) this._handlers[event] = [];
      this._handlers[event].push(callback);
    },

    emit: function(event, payload) {
      var cbs = this._handlers[event] || [];
      for (var i = 0; i < cbs.length; i++) {
        try { cbs[i](payload); } catch(e) { console.error(e); }
      }
    }
  };

  window.dispatchEvent(new CustomEvent('toolboxready', { detail: window.Toolbox }));
})();
''';
  }
}
