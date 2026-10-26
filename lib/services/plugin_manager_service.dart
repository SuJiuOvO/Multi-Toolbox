import 'dart:convert';
import 'dart:io';
import 'package:archive/archive.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import '../models/plugin_manifest.dart';
import '../models/registry_mirror_node.dart';

class LocalInstallResult {
  final bool success;
  final String message;
  final PluginManifest? plugin;

  LocalInstallResult({
    required this.success,
    required this.message,
    this.plugin,
  });
}

class _ValidationOutcome {
  final bool isValid;
  final String? errorMessage;

  _ValidationOutcome({required this.isValid, this.errorMessage});
}

class PluginManagerService {
  static final PluginManagerService _instance = PluginManagerService._internal();
  factory PluginManagerService() => _instance;
  PluginManagerService._internal();

  /// 当前百宝箱客户端版本号
  static const String currentAppVersion = '1.0.0';

  /// 比较两个语义化版本号 (例如 "1.0.0" 与 "1.1.0")
  /// 若 v1 > v2 返回 1; 若 v1 < v2 返回 -1; 相等返回 0
  static int compareVersions(String v1, String v2) {
    final clean1 = v1.trim().replaceAll(RegExp(r'^[vV]'), '').split('+').first;
    final clean2 = v2.trim().replaceAll(RegExp(r'^[vV]'), '').split('+').first;
    final parts1 = clean1.split('.').map((e) => int.tryParse(e) ?? 0).toList();
    final parts2 = clean2.split('.').map((e) => int.tryParse(e) ?? 0).toList();
    final maxLen = parts1.length > parts2.length ? parts1.length : parts2.length;
    for (int i = 0; i < maxLen; i++) {
      final p1 = i < parts1.length ? parts1[i] : 0;
      final p2 = i < parts2.length ? parts2[i] : 0;
      if (p1 > p2) return 1;
      if (p1 < p2) return -1;
    }
    return 0;
  }

  /// 检查当前客户端版本是否满足插件的最低版本要求
  static bool isAppVersionCompatible(String minAppVersion) {
    if (minAppVersion.trim().isEmpty) return true;
    return compareVersions(currentAppVersion, minAppVersion) >= 0;
  }

  final Dio _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 10),
    receiveTimeout: const Duration(seconds: 30),
  ));

  /// 可选镜像节点列表 (默认包含 Gitee 极速、jsDelivr CDN、GitHub 官方直连)
  List<RegistryMirrorNode> customNodes = [];
  List<RegistryMirrorNode> get allNodes => [...RegistryMirrorNode.defaultNodes, ...customNodes];

  /// 当前所选节点模式：'auto' (自动竞速优选), 或指定节点 ID ('gitee', 'github_cdn', 'github_raw', 'custom')
  String selectedNodeMode = 'auto';

  /// 当前实际激活使用的节点 (默认 Gitee 极速)
  RegistryMirrorNode currentActiveNode = RegistryMirrorNode.defaultNodes[0];

  /// 当前激活节点的延迟 (ms)
  int? activeNodeLatency;

  /// 云端插件中心地址 (自动对齐当前激活节点)
  String get serverRegistryUrl => currentActiveNode.indexUrl;

  // 本地已安装插件列表
  List<PluginManifest> installedPlugins = [];
  // 云端市场所有插件列表
  List<PluginManifest> remotePlugins = [];

  Directory? _pluginsDirectory;
  Directory get pluginsDirectory => _pluginsDirectory ?? Directory('');

  @visibleForTesting
  void overridePluginsDirectory(Directory dir) {
    _pluginsDirectory = dir;
  }

  /// 初始化本地目录与服务器配置
  Future<void> init() async {
    try {
      Directory appDocDir;
      if (Platform.isWindows) {
        appDocDir = await getApplicationSupportDirectory();
      } else {
        appDocDir = await getApplicationDocumentsDirectory();
      }
      _pluginsDirectory = Directory(p.join(appDocDir.path, 'toolbox_plugins'));
      if (!_pluginsDirectory!.existsSync()) {
        _pluginsDirectory!.createSync(recursive: true);
      }
    } catch (_) {
      _pluginsDirectory = Directory(p.join(Directory.systemTemp.path, 'toolbox_plugins'));
      if (!_pluginsDirectory!.existsSync()) {
        _pluginsDirectory!.createSync(recursive: true);
      }
    }

    // 读取持久化保存的节点模式
    try {
      final modeFile = File(p.join(pluginsDirectory.path, 'node_mode.txt'));
      if (modeFile.existsSync()) {
        final savedMode = modeFile.readAsStringSync().trim();
        if (savedMode.isNotEmpty) {
          selectedNodeMode = savedMode;
        }
      }
    } catch (_) {}

    // 读取持久化保存的自定义服务器地址（如果有）
    try {
      final configFile = File(p.join(pluginsDirectory.path, 'server_url.txt'));
      if (configFile.existsSync()) {
        final savedUrl = configFile.readAsStringSync().trim();
        if (savedUrl.isNotEmpty) {
          customNodes = [
            RegistryMirrorNode(
              id: 'custom',
              name: '自定义私有源',
              icon: '🔧',
              indexUrl: savedUrl,
              pingUrl: savedUrl,
              packageBaseUrl: p.dirname(savedUrl),
              appVersionUrl: '${p.dirname(savedUrl)}/app_version.json',
            )
          ];
        }
      }
    } catch (_) {}

    _resolveInitialNode();
    await loadInstalledPlugins();
  }

  void _resolveInitialNode() {
    if (selectedNodeMode != 'auto') {
      final found = allNodes.where((n) => n.id == selectedNodeMode).firstOrNull;
      if (found != null) {
        currentActiveNode = found;
        return;
      }
    }
    // 默认选用 Gitee 国内极速
    currentActiveNode = RegistryMirrorNode.defaultNodes[0];
  }

  /// 更改节点模式 ('auto', 'gitee', 'github_cdn', 'github_raw', 'custom')
  Future<void> setNodeMode(String mode) async {
    selectedNodeMode = mode;
    _resolveInitialNode();
    try {
      final modeFile = File(p.join(pluginsDirectory.path, 'node_mode.txt'));
      await modeFile.writeAsString(mode);
    } catch (_) {}
  }

  /// 更改并持久化自定义服务器地址
  Future<void> updateServerUrl(String newUrl) async {
    final cleanUrl = newUrl.trim();
    if (cleanUrl.isEmpty) return;
    try {
      final configFile = File(p.join(pluginsDirectory.path, 'server_url.txt'));
      await configFile.writeAsString(cleanUrl);
      customNodes = [
        RegistryMirrorNode(
          id: 'custom',
          name: '自定义私有源',
          icon: '🔧',
          indexUrl: cleanUrl,
          pingUrl: cleanUrl,
          packageBaseUrl: p.dirname(cleanUrl),
          appVersionUrl: '${p.dirname(cleanUrl)}/app_version.json',
        )
      ];
      if (selectedNodeMode == 'custom') {
        currentActiveNode = customNodes.first;
      }
    } catch (_) {}
  }

  /// 对所有镜像节点进行并发延迟测速 (超时 2500ms)
  Future<Map<String, int>> pingAllNodes() async {
    final Map<String, int> results = {};
    final testNodes = allNodes;

    await Future.wait(testNodes.map((node) async {
      final sw = Stopwatch()..start();
      try {
        final resp = await _dio.get(
          node.pingUrl,
          options: Options(
            receiveTimeout: const Duration(milliseconds: 2500),
            sendTimeout: const Duration(milliseconds: 2500),
            validateStatus: (status) => status != null && status < 500,
          ),
        );
        sw.stop();
        if (resp.statusCode == 200 || resp.statusCode == 304) {
          results[node.id] = sw.elapsedMilliseconds;
        } else {
          results[node.id] = -1; // 异常状态码
        }
      } catch (_) {
        results[node.id] = -1; // 超时或无法连接
      }
    }));

    return results;
  }

  /// 加载本地已下载并解压的插件
  Future<List<PluginManifest>> loadInstalledPlugins() async {
    if (_pluginsDirectory == null) {
      await init();
    }
    if (_pluginsDirectory == null || !_pluginsDirectory!.existsSync()) {
      installedPlugins = [];
      return [];
    }

    final List<PluginManifest> loaded = [];
    try {
      final subDirs = _pluginsDirectory!.listSync().whereType<Directory>();
      for (var dir in subDirs) {
        final manifestFile = File(p.join(dir.path, 'manifest.json'));
        if (manifestFile.existsSync()) {
          try {
            final jsonStr = await manifestFile.readAsString();
            final jsonMap = jsonDecode(jsonStr);
            final plugin = PluginManifest.fromJson(jsonMap, isRemote: false);
            plugin.localDir = dir.path;

            // 平台适配检查：若本地残留的插件不兼容当前操作系统平台（如安卓端残留的 windows-media-downloader），自动清理并排除
            if (!plugin.isSupportedOnCurrentPlatform()) {
              try {
                dir.deleteSync(recursive: true);
              } catch (_) {}
              continue;
            }

            loaded.add(plugin);
          } catch (e) {
            debugPrint('解析本地插件失败: ${dir.path}, 错误: $e');
          }
        }
      }
    } catch (e) {
      debugPrint('读取已安装插件目录发生异常: $e');
    }

    // 确保核心内置功能插件就绪并保持与 assets 同步更新
    for (final id in PluginManifest.defaultPluginIds) {
      try {
        final assetData = await rootBundle.loadString('assets/default_plugins/$id.json');
        final jsonMap = jsonDecode(assetData);
        final assetPlugin = PluginManifest.fromJson(jsonMap, isRemote: false);

        // 平台适配检查：若预置功能不兼容当前操作系统，严禁安装预置！
        if (!assetPlugin.isSupportedOnCurrentPlatform()) {
          continue;
        }

        final targetDir = Directory(p.join(_pluginsDirectory!.path, id));
        if (!targetDir.existsSync()) {
          targetDir.createSync(recursive: true);
        }
        final mFile = File(p.join(targetDir.path, 'manifest.json'));

        final existingIdx = loaded.indexWhere((p) => p.id == id);
        bool shouldUpdate = false;
        if (existingIdx == -1) {
          shouldUpdate = true;
        } else {
          if (!mFile.existsSync()) {
            shouldUpdate = true;
          } else {
            final currentContent = await mFile.readAsString();
            if (currentContent.trim() != assetData.trim()) {
              shouldUpdate = true;
            }
          }
        }

        if (shouldUpdate) {
          await mFile.writeAsString(assetData);
          assetPlugin.localDir = targetDir.path;
          if (existingIdx == -1) {
            loaded.add(assetPlugin);
          } else {
            loaded[existingIdx] = assetPlugin;
          }
        }
      } catch (e) {
        debugPrint('加载/同步默认插件失败 $id: $e');
      }
    }

    installedPlugins = loaded;
    return installedPlugins;
  }

  /// 从远程注册中心获取最新插件列表 (支持多源智能竞速与自动故障转移)
  Future<List<PluginManifest>> fetchRemoteRegistry() async {
    await loadInstalledPlugins();

    // 智能竞速：若处于自动模式，测试各镜像节点延迟并优先选用最快节点
    if (selectedNodeMode == 'auto') {
      try {
        final pingMap = await pingAllNodes();
        final healthyNodes = allNodes.where((n) => (pingMap[n.id] ?? -1) > 0).toList();
        if (healthyNodes.isNotEmpty) {
          healthyNodes.sort((a, b) => (pingMap[a.id] ?? 9999).compareTo(pingMap[b.id] ?? 9999));
          currentActiveNode = healthyNodes.first;
          activeNodeLatency = pingMap[currentActiveNode.id];
          debugPrint('【多源竞速】自动选用最优节点: ${currentActiveNode.name} (${activeNodeLatency}ms)');
        }
      } catch (e) {
        debugPrint('【多源竞速】测速出错，沿用当前节点: $e');
      }
    }

    // 候选拉取节点队列：当前节点优先，其他节点作为故障降级备用
    final List<RegistryMirrorNode> candidateNodes = [
      currentActiveNode,
      ...allNodes.where((n) => n.id != currentActiveNode.id),
    ];

    for (final node in candidateNodes) {
      try {
        debugPrint('正在从镜像节点拉取插件清单: ${node.name} -> ${node.indexUrl}');
        final response = await _dio.get(
          node.indexUrl,
          options: Options(
            connectTimeout: const Duration(seconds: 6),
            receiveTimeout: const Duration(seconds: 15),
          ),
        );

        if (response.statusCode == 200) {
          dynamic data = response.data;
          if (data is String) {
            data = jsonDecode(data);
          }

          final rawList = data['plugins'] as List? ?? [];
          final list = rawList
              .map((item) => PluginManifest.fromJson(item, isRemote: true))
              .toList();

          // 标记是否已安装以及是否有更新
          for (var remote in list) {
            final local = installedPlugins.where((p) => p.id == remote.id).firstOrNull;
            if (local != null) {
              remote.isInstalled = true;
              remote.localDir = local.localDir;
              if (remote.version != local.version) {
                remote.isUpdateAvailable = true;
              }
            } else {
              remote.isInstalled = false;
            }
          }

          remotePlugins = list;
          currentActiveNode = node; // 记录实际成功的节点
          return remotePlugins;
        }
      } catch (e) {
        debugPrint('从节点【${node.name}】获取插件清单失败: $e，尝试下一个备用节点...');
      }
    }

    debugPrint('所有镜像节点均暂时不可用，已保留上一次缓存列表 (${remotePlugins.length} 个)');
    return remotePlugins;
  }

  /// 下载并安装/热更新插件包 (.zip)
  /// 具备多平台镜像线路自动重试与故障平滑切换能力
  Future<bool> installPlugin(
    PluginManifest plugin, {
    Function(double progress, String status)? onProgress,
  }) async {
    // 校验最低客户端版本要求
    if (!isAppVersionCompatible(plugin.minAppVersion)) {
      debugPrint('客户端版本过低 (当前: v$currentAppVersion, 插件要求最低: v${plugin.minAppVersion})，拒绝安装');
      return false;
    }

    // 整理候选下载地址列表 (当前节点优先 -> 其他镜像节点 -> 备用直连地址)
    final List<String> candidateUrls = [];
    if (plugin.downloadUrls.containsKey(currentActiveNode.id)) {
      final u = plugin.downloadUrls[currentActiveNode.id]!;
      if (u.isNotEmpty && !candidateUrls.contains(u)) candidateUrls.add(u);
    }
    for (final node in allNodes) {
      if (plugin.downloadUrls.containsKey(node.id)) {
        final u = plugin.downloadUrls[node.id]!;
        if (u.isNotEmpty && !candidateUrls.contains(u)) candidateUrls.add(u);
      }
    }
    if (plugin.downloadUrl != null && plugin.downloadUrl!.isNotEmpty && !candidateUrls.contains(plugin.downloadUrl)) {
      candidateUrls.add(plugin.downloadUrl!);
    }

    if (candidateUrls.isEmpty) {
      debugPrint('插件【${plugin.name}】未配置任何有效下载地址');
      return false;
    }

    final tempDir = await getTemporaryDirectory();
    final tempZipPath = p.join(tempDir.path, '${plugin.id}_${DateTime.now().millisecondsSinceEpoch}.zip');

    // 依次尝试所有镜像下载线路
    bool downloadSuccess = false;
    for (int i = 0; i < candidateUrls.length; i++) {
      String effectiveDownloadUrl = candidateUrls[i];

      // 回环地址对齐处理（模拟器测试兼容）
      try {
        final regUri = Uri.parse(serverRegistryUrl);
        final dlUri = Uri.parse(effectiveDownloadUrl);
        if ((dlUri.host == '127.0.0.1' || dlUri.host == 'localhost') &&
            regUri.host != '127.0.0.1' &&
            regUri.host != 'localhost') {
          effectiveDownloadUrl = dlUri.replace(host: regUri.host, port: regUri.port).toString();
        }
      } catch (_) {}

      try {
        if (i == 0) {
          onProgress?.call(0.1, '正在连接【${currentActiveNode.name}】下载线路...');
        } else {
          onProgress?.call(0.12, '主节点受阻，已自动无缝切换至备用下载线路 (${i + 1}/${candidateUrls.length})...');
        }

        if (File(tempZipPath).existsSync()) {
          try {
            File(tempZipPath).deleteSync();
          } catch (_) {}
        }

        await _dio.download(
          effectiveDownloadUrl,
          tempZipPath,
          options: Options(
            connectTimeout: const Duration(seconds: 8),
            receiveTimeout: const Duration(seconds: 40),
          ),
          onReceiveProgress: (received, total) {
            if (total > 0) {
              final progress = 0.2 + (received / total) * 0.65;
              onProgress?.call(progress, '已下载 ${(received / 1024).toStringAsFixed(1)} KB / ${(total / 1024).toStringAsFixed(1)} KB');
            }
          },
        );

        if (File(tempZipPath).existsSync() && File(tempZipPath).lengthSync() > 100) {
          downloadSuccess = true;
          break; // 下载成功，跳出重试循环
        }
      } catch (e) {
        debugPrint('线路下载失败 ($effectiveDownloadUrl): $e');
      }
    }

    if (!downloadSuccess) {
      debugPrint('所有镜像线路均下载失败，请检查网络');
      return false;
    }

    try {
      onProgress?.call(0.88, '下载完成，正在校验模块完整性并解压安装...');
      final zipBytes = await File(tempZipPath).readAsBytes();
      final archive = ZipDecoder().decodeBytes(zipBytes);

      // 解压目标路径
      final targetPluginDir = Directory(p.join(pluginsDirectory.path, plugin.id));
      if (targetPluginDir.existsSync()) {
        targetPluginDir.deleteSync(recursive: true);
      }
      targetPluginDir.createSync(recursive: true);

      for (final file in archive) {
        final filename = file.name;
        if (file.isFile) {
          final data = file.content as List<int>;
          final outFile = File(p.join(targetPluginDir.path, filename));
          outFile.parent.createSync(recursive: true);
          await outFile.writeAsBytes(data);
        } else {
          Directory(p.join(targetPluginDir.path, filename)).createSync(recursive: true);
        }
      }

      // 清理临时文件
      try {
        await File(tempZipPath).delete();
      } catch (_) {}

      onProgress?.call(1.0, '安装完成！');
      await loadInstalledPlugins();
      return true;
    } catch (e) {
      debugPrint('解压或写入插件失败: $e');
      return false;
    }
  }

  /// 本地安装功能模块 (.json 描述文件 或 .zip 插件安装包)
  /// 严格校验结构完整性、字段合法性以及最低客户端版本要求
  Future<LocalInstallResult> installLocalPlugin(String filePath) async {
    final file = File(filePath);
    if (!file.existsSync()) {
      return LocalInstallResult(
        success: false,
        message: '待安装文件不存在: $filePath',
      );
    }

    final ext = p.extension(filePath).toLowerCase();
    if (ext != '.json' && ext != '.zip') {
      return LocalInstallResult(
        success: false,
        message: '不支持的文件类型，请选择 .json 描述文件或 .zip 插件压缩包',
      );
    }

    try {
      if (ext == '.json') {
        final jsonStr = await file.readAsString();
        final Map<String, dynamic> jsonMap;
        try {
          final decoded = jsonDecode(jsonStr);
          if (decoded is! Map<String, dynamic>) {
            return LocalInstallResult(
              success: false,
              message: 'JSON 内容必须为顶级对象结构，解析失败',
            );
          }
          jsonMap = decoded;
        } catch (e) {
          return LocalInstallResult(
            success: false,
            message: 'JSON 语法解析失败: $e',
          );
        }

        final validation = _validatePluginJson(jsonMap);
        if (!validation.isValid) {
          return LocalInstallResult(
            success: false,
            message: '插件配置校验未通过：\n${validation.errorMessage}',
          );
        }

        final manifest = PluginManifest.fromJson(jsonMap, isRemote: false);

        // 校验客户端最低版本要求
        if (!isAppVersionCompatible(manifest.minAppVersion)) {
          return LocalInstallResult(
            success: false,
            message: '⛔ 客户端版本过低，拒绝安装！\n\n'
                '插件【${manifest.name}】要求的最低客户端版本为 v${manifest.minAppVersion}，'
                '而当前客户端版本为 v$currentAppVersion。\n\n'
                '请先将百宝箱客户端升级至最新版本后再进行安装！',
          );
        }

        // 保存至 plugins 目录
        final targetPluginDir = Directory(p.join(pluginsDirectory.path, manifest.id));
        if (!targetPluginDir.existsSync()) {
          targetPluginDir.createSync(recursive: true);
        }
        final targetManifest = File(p.join(targetPluginDir.path, 'manifest.json'));
        await targetManifest.writeAsString(jsonStr);
        manifest.localDir = targetPluginDir.path;

        await loadInstalledPlugins();
        return LocalInstallResult(
          success: true,
          message: '功能模块【${manifest.name}】已成功校验并完成本地安装！',
          plugin: manifest,
        );
      } else {
        // ZIP 压缩包处理
        final zipBytes = await file.readAsBytes();
        final archive = ZipDecoder().decodeBytes(zipBytes);

        ArchiveFile? manifestEntry;
        String? rootPrefix;

        for (final entry in archive) {
          final name = entry.name.replaceAll('\\', '/');
          if (name == 'manifest.json') {
            manifestEntry = entry;
            rootPrefix = '';
            break;
          } else if (name.endsWith('/manifest.json') && name.split('/').length == 2) {
            manifestEntry = entry;
            rootPrefix = '${name.split("/").first}/';
            break;
          }
        }

        if (manifestEntry == null) {
          return LocalInstallResult(
            success: false,
            message: '插件压缩包格式不合格：根目录中缺少 manifest.json 描述文件',
          );
        }

        final manifestStr = utf8.decode(manifestEntry.content as List<int>);
        final Map<String, dynamic> jsonMap;
        try {
          final decoded = jsonDecode(manifestStr);
          if (decoded is! Map<String, dynamic>) {
            return LocalInstallResult(
              success: false,
              message: 'manifest.json 内容必须为顶级对象结构',
            );
          }
          jsonMap = decoded;
        } catch (e) {
          return LocalInstallResult(
            success: false,
            message: 'manifest.json 语法解析失败: $e',
          );
        }

        final validation = _validatePluginJson(jsonMap);
        if (!validation.isValid) {
          return LocalInstallResult(
            success: false,
            message: '压缩包内插件配置校验未通过：\n${validation.errorMessage}',
          );
        }

        final manifest = PluginManifest.fromJson(jsonMap, isRemote: false);

        // 校验客户端最低版本要求
        if (!isAppVersionCompatible(manifest.minAppVersion)) {
          return LocalInstallResult(
            success: false,
            message: '⛔ 客户端版本过低，拒绝安装！\n\n'
                '插件【${manifest.name}】要求的最低客户端版本为 v${manifest.minAppVersion}，'
                '而当前客户端版本为 v$currentAppVersion。\n\n'
                '请先将百宝箱客户端升级至最新版本后再进行安装！',
          );
        }

        // 解压到目标目录
        final targetPluginDir = Directory(p.join(pluginsDirectory.path, manifest.id));
        if (targetPluginDir.existsSync()) {
          targetPluginDir.deleteSync(recursive: true);
        }
        targetPluginDir.createSync(recursive: true);

        for (final entry in archive) {
          var relPath = entry.name.replaceAll('\\', '/');
          if (rootPrefix != null && rootPrefix.isNotEmpty && relPath.startsWith(rootPrefix)) {
            relPath = relPath.substring(rootPrefix.length);
          }
          if (relPath.isEmpty) continue;

          final destPath = p.join(targetPluginDir.path, relPath);
          if (entry.isFile) {
            final outFile = File(destPath);
            outFile.parent.createSync(recursive: true);
            await outFile.writeAsBytes(entry.content as List<int>);
          } else {
            Directory(destPath).createSync(recursive: true);
          }
        }

        manifest.localDir = targetPluginDir.path;
        await loadInstalledPlugins();
        return LocalInstallResult(
          success: true,
          message: '功能模块【${manifest.name}】已成功校验并完成本地解压安装！',
          plugin: manifest,
        );
      }
    } catch (e) {
      return LocalInstallResult(
        success: false,
        message: '本地安装过程发生异常: $e',
      );
    }
  }

  /// 插件 JSON 结构与必填字段规范校验
  static _ValidationOutcome _validatePluginJson(Map<String, dynamic> json) {
    final missingFields = <String>[];

    final id = json['id']?.toString().trim();
    if (id == null || id.isEmpty) {
      missingFields.add('id (插件唯一英文标识)');
    } else if (!RegExp(r'^[a-zA-Z0-9_\-]+$').hasMatch(id)) {
      return _ValidationOutcome(
        isValid: false,
        errorMessage: '插件 id 必须仅包含英文字母、数字、下划线或连字符，当前为: "$id"',
      );
    }

    final name = json['name']?.toString().trim();
    if (name == null || name.isEmpty) {
      missingFields.add('name (插件中文显示名称)');
    }

    final version = json['version']?.toString().trim();
    if (version == null || version.isEmpty) {
      missingFields.add('version (版本号，如 1.0.0)');
    }

    final category = json['category']?.toString().trim();
    if (category == null || category.isEmpty) {
      missingFields.add('category (分类归属)');
    }

    final description = json['description']?.toString().trim();
    if (description == null || description.isEmpty) {
      missingFields.add('description (功能模块简介说明)');
    }

    if (json['action'] == null && json['engineType'] == null) {
      missingFields.add('action 或 engineType (功能执行逻辑定义)');
    }

    if (missingFields.isNotEmpty) {
      return _ValidationOutcome(
        isValid: false,
        errorMessage: '缺少必要的基础配置字段：\n• ${missingFields.join('\n• ')}',
      );
    }

    return _ValidationOutcome(isValid: true);
  }

  /// 卸载插件
  Future<bool> uninstallPlugin(String pluginId) async {
    try {
      final targetPluginDir = Directory(p.join(pluginsDirectory.path, pluginId));
      if (targetPluginDir.existsSync()) {
        await targetPluginDir.delete(recursive: true);
      }
      await loadInstalledPlugins();
      return true;
    } catch (e) {
      debugPrint('插件卸载失败: $e');
      return false;
    }
  }
}
