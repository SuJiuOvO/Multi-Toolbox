import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:app/models/plugin_manifest.dart';
import 'package:app/pages/installed_plugins_manager_page.dart';
import 'package:app/services/plugin_manager_service.dart';
import 'package:path/path.dart' as p;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('PluginManifest isBuiltIn Flag Tests', () {
    test('defaultPluginIds are correctly recognized as built-in', () {
      final builtInManifest = PluginManifest(
        id: 'image-compress',
        name: '图片压缩',
        version: '1.0.0',
        category: 'image',
        description: '内置图片压缩',
        icon: 'compress',
        author: 'Toolbox',
        engineType: 'native_image',
      );
      expect(builtInManifest.isBuiltIn, isTrue);

      final wasmManifest = PluginManifest(
        id: 'universal-wasm-runner',
        name: 'Wasm 运行器',
        version: '1.0.0',
        category: 'calc',
        description: 'WASM 算力沙箱',
        icon: 'code',
        author: 'Toolbox',
        engineType: 'wasm',
      );
      expect(wasmManifest.isBuiltIn, isTrue);
    });

    test('Third-party and custom local plugins are recognized as non-builtin', () {
      final customManifest = PluginManifest(
        id: 'ncm-audio-converter',
        name: 'NCM 音频解锁转换器',
        version: '1.0.0',
        category: 'audio',
        description: 'WASM NCM 解锁',
        icon: 'audio',
        author: 'Community',
        engineType: 'wasm',
      );
      expect(customManifest.isBuiltIn, isFalse);

      final localManifest = PluginManifest(
        id: 'my-custom-tool',
        name: '我的私人工具',
        version: '0.1.0',
        category: 'custom',
        description: '测试自定义工具',
        icon: 'extension',
        author: 'Developer',
        engineType: 'quickjs',
      );
      expect(localManifest.isBuiltIn, isFalse);
    });
  });

  group('Plugin Uninstallation & Lifecycle Tests', () {
    late Directory tempPluginsDir;
    late PluginManagerService service;

    setUp(() async {
      tempPluginsDir = Directory.systemTemp.createTempSync('plugins_uninstall_test_');
      service = PluginManagerService();
      service.overridePluginsDirectory(tempPluginsDir);
    });

    tearDown(() {
      if (tempPluginsDir.existsSync()) {
        tempPluginsDir.deleteSync(recursive: true);
      }
    });

    test('Locally installed plugin can be uninstalled and directory is wiped cleanly', () async {
      // 1. 本地安装一个新插件
      final jsonFile = File(p.join(tempPluginsDir.path, 'test_module.json'));
      await jsonFile.writeAsString(jsonEncode({
        'id': 'test-uninstall-target',
        'name': '待卸载测试模块',
        'version': '1.0.0',
        'category': 'tools',
        'description': '用于验证卸载流程的专用测试插件',
        'engineType': 'quickjs',
        'author': 'Tester',
        'inputs': [],
      }));

      final installResult = await service.installLocalPlugin(jsonFile.path);
      expect(installResult.success, isTrue);

      final installedTargetDir = Directory(p.join(tempPluginsDir.path, 'test-uninstall-target'));
      expect(installedTargetDir.existsSync(), isTrue);

      // 验证在已安装列表中存在
      expect(service.installedPlugins.any((p) => p.id == 'test-uninstall-target'), isTrue);

      // 2. 调用卸载
      final uninstallSuccess = await service.uninstallPlugin('test-uninstall-target');
      expect(uninstallSuccess, isTrue);

      // 3. 验证目录被彻底删除，且列表中已移除
      expect(installedTargetDir.existsSync(), isFalse);
      expect(service.installedPlugins.any((p) => p.id == 'test-uninstall-target'), isFalse);
    });

    test('Local dev plugin directory can be linked, persisted in dev_links.json, and unlinked safely without wiping source files', () async {
      // 1. 创建独立的开发者工作区目录
      final devWorkspaceDir = Directory.systemTemp.createTempSync('dev_workspace_plugin_');
      try {
        final manifestFile = File(p.join(devWorkspaceDir.path, 'manifest.json'));
        await manifestFile.writeAsString(jsonEncode({
          'id': 'my-live-dev-tool',
          'name': '本地热调试插件',
          'version': '0.0.1-alpha',
          'category': 'dev',
          'description': '正在本地快速迭代开发的插件',
          'engineType': 'quickjs',
          'author': 'Developer',
          'inputs': [],
        }));

        // 2. 建立开发关联
        final linkResult = await service.linkDevPluginDirectory(devWorkspaceDir.path);
        expect(linkResult.success, isTrue);

        // 3. 检查已安装列表中存在，且标记为 isDevLink == true
        final devPlugin = service.installedPlugins.firstWhere((p) => p.id == 'my-live-dev-tool');
        expect(devPlugin.isDevLink, isTrue);
        expect(devPlugin.platformBadgeText, contains('本地调试'));

        // 4. 检查 dev_links.json 持久化成功
        final devLinksFile = File(p.join(tempPluginsDir.path, 'dev_links.json'));
        expect(devLinksFile.existsSync(), isTrue);
        final devLinksMap = jsonDecode(await devLinksFile.readAsString()) as Map<String, dynamic>;
        expect(devLinksMap['my-live-dev-tool'], devWorkspaceDir.path);

        // 5. 调用卸载 (解除关联)
        final unlinkSuccess = await service.uninstallPlugin('my-live-dev-tool');
        expect(unlinkSuccess, isTrue);

        // 6. 验证已从列表移除
        expect(service.installedPlugins.any((p) => p.id == 'my-live-dev-tool'), isFalse);

        // 7. 关键保障：开发者工作区原始源码依然完好无损！
        expect(devWorkspaceDir.existsSync(), isTrue);
        expect(manifestFile.existsSync(), isTrue);

        // 8. 验证 dev_links.json 中记录已清除
        final updatedLinksMap = jsonDecode(await devLinksFile.readAsString()) as Map<String, dynamic>;
        expect(updatedLinksMap.containsKey('my-live-dev-tool'), isFalse);
      } finally {
        if (devWorkspaceDir.existsSync()) {
          devWorkspaceDir.deleteSync(recursive: true);
        }
      }
    });
  });

  group('InstalledPluginsManagerPage Search & Filter Simulation Tests', () {
    final samplePlugins = [
      PluginManifest(
        id: 'image-compress',
        name: '图片压缩优化',
        version: '1.0.0',
        category: 'image',
        description: '高保真压缩图片体积',
        icon: 'compress',
        author: 'Official',
        engineType: 'native_image',
      ),
      PluginManifest(
        id: 'ncm-audio-converter',
        name: '网易云音乐 NCM 格式转换',
        version: '1.1.0',
        category: 'audio',
        description: '基于 WebAssembly 纯本地沙箱无损解密并转换为 FLAC/MP3',
        icon: 'audio',
        author: 'Community Dev',
        engineType: 'wasm',
      ),
      PluginManifest(
        id: 'windows-cmd-tool',
        name: 'CMD 命令行辅助',
        version: '1.0.0',
        category: 'win_ext',
        description: 'Windows 桌面自动化批处理脚本',
        icon: 'terminal',
        author: 'SysAdmin',
        engineType: 'native_executable',
        platforms: ['windows'],
      ),
    ];

    test('Filter by keyword searches name, id, category, author and description', () {
      // 搜索 "ncm"
      final ncmResults = samplePlugins.where((p) {
        const q = 'ncm';
        return p.name.toLowerCase().contains(q) ||
            p.description.toLowerCase().contains(q) ||
            p.id.toLowerCase().contains(q);
      }).toList();
      expect(ncmResults.length, 1);
      expect(ncmResults.first.id, 'ncm-audio-converter');

      // 搜索 "webassembly"
      final wasmResults = samplePlugins.where((p) {
        const q = 'webassembly';
        return p.name.toLowerCase().contains(q) ||
            p.description.toLowerCase().contains(q);
      }).toList();
      expect(wasmResults.length, 1);
      expect(wasmResults.first.id, 'ncm-audio-converter');

      // 搜索 "SysAdmin" (作者)
      final authorResults = samplePlugins.where((p) {
        final q = 'sysadmin'.toLowerCase();
        return p.author.toLowerCase().contains(q);
      }).toList();
      expect(authorResults.length, 1);
      expect(authorResults.first.id, 'windows-cmd-tool');
    });

    test('Filter by built-in vs third-party scopes', () {
      final builtinOnly = samplePlugins.where((p) => p.isBuiltIn).toList();
      expect(builtinOnly.length, 1);
      expect(builtinOnly.first.id, 'image-compress');

      final nonBuiltin = samplePlugins.where((p) => !p.isBuiltIn).toList();
      expect(nonBuiltin.length, 2);
      expect(nonBuiltin.map((p) => p.id), containsAll(['ncm-audio-converter', 'windows-cmd-tool']));
    });
  });

  group('InstalledPluginsManagerPage Widget Rendering Tests', () {
    testWidgets('Renders InstalledPluginsManagerPage with search bar and filter chips', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: InstalledPluginsManagerPage(),
        ),
      );
      await tester.pumpAndSettle();

      // 校验标题存在
      expect(find.text('插件与模块管理'), findsOneWidget);

      // 校验搜索框存在
      expect(find.byType(TextField), findsOneWidget);

      // 校验筛选 Chips 存在
      expect(find.textContaining('全部'), findsOneWidget);
      expect(find.textContaining('第三方与扩展'), findsOneWidget);
      expect(find.textContaining('内置核心'), findsOneWidget);
    });
  });
}
