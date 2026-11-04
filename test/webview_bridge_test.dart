import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:app/models/plugin_manifest.dart';
import 'package:app/pages/plugin_runner_page.dart';
import 'package:app/pages/webview_tool_runner_page.dart';
import 'package:app/services/webview_bridge_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Webview Runner & PluginManifest Specification Tests', () {
    test('PluginManifest parses webViewRunner and executionType correctly', () {
      final json = {
        'id': 'test-webview-plugin',
        'name': '测试富交互插件',
        'version': '1.0.0',
        'category': 'utility',
        'description': 'A rich interactive test plugin',
        'author': 'Tester',
        'executionType': 'webview',
        'webViewRunner': {
          'entry': 'dist/index.html',
          'allowClipboard': true,
          'keepScreenOn': true,
          'fullscreenOnStart': true,
          'initialTheme': 'dark',
        },
      };

      final manifest = PluginManifest.fromJson(json);
      expect(manifest.executionType, 'webview');
      expect(manifest.isWebviewPlugin, isTrue);
      expect(manifest.platformBadgeText, '🌐 动态富交互');
      expect(manifest.webViewRunner, isNotNull);
      expect(manifest.webViewRunner!.entry, 'dist/index.html');
      expect(manifest.webViewRunner!.allowClipboard, isTrue);
      expect(manifest.webViewRunner!.keepScreenOn, isTrue);
      expect(manifest.webViewRunner!.fullscreenOnStart, isTrue);
      expect(manifest.webViewRunner!.initialTheme, 'dark');

      final serialized = manifest.webViewRunner!.toJson();
      expect(serialized['entry'], 'dist/index.html');
      expect(serialized['keepScreenOn'], isTrue);
    });

    test('PluginRunnerPage routes webview plugin to WebviewToolRunnerPage', () {
      final manifest = PluginManifest.fromJson({
        'id': 'interactive-demo',
        'name': 'Demo',
        'version': '1.0.0',
        'category': 'utility',
        'description': 'demo',
        'author': 'Tester',
        'executionType': 'webview',
        'webViewRunner': {'entry': 'dist/index.html'},
      });

      final widget = PluginRunnerPage.destinationFor(manifest);
      expect(widget, isA<WebviewToolRunnerPage>());
    });
  });

  group('WebviewBridgeService & Path Jail Security Tests', () {
    late Directory tempDir;
    late Directory pluginDir;
    late Directory dataDir;
    late WebviewBridgeService bridge;
    late PluginManifest manifest;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      tempDir = await Directory.systemTemp.createTemp('wv_test_');
      pluginDir = Directory(p.join(tempDir.path, 'plugin_install'))..createSync();
      dataDir = Directory(p.join(tempDir.path, 'plugin_data'))..createSync();

      manifest = PluginManifest.fromJson({
        'id': 'mock-plugin',
        'name': 'Mock Plugin',
        'version': '1.0.0',
        'category': 'utility',
        'description': 'mock',
        'author': 'Tester',
        'executionType': 'webview',
        'webViewRunner': {'entry': 'dist/index.html', 'allowClipboard': true},
      });

      bridge = WebviewBridgeService(
        plugin: manifest,
        pluginLocalDir: pluginDir.path,
        pluginDataDir: dataDir.path,
      );
    });

    tearDown(() async {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('Path Jail blocks unauthorized directory traversal out of root', () {
      final outsideFile = p.join(tempDir.path, 'outside.txt');
      expect(
        () => bridge.assertPathInJail(outsideFile, isWrite: false),
        throwsA(isA<Exception>()),
      );

      final traversalPath = p.join(pluginDir.path, '..', 'secret.txt');
      expect(
        () => bridge.assertPathInJail(traversalPath, isWrite: false),
        throwsA(isA<Exception>()),
      );

      expect(
        () => bridge.assertPathInJail('   ', isWrite: false),
        throwsA(isA<Exception>()),
      );
    });

    test('Storage API isolates per-plugin key-value storage', () async {
      final setRes = await bridge.handleBridgeCall('storage_set', {
        'key': 'theme_pref',
        'value': {'color': '#FF0000', 'speed': 5},
      });
      expect(setRes['success'], isTrue);

      final getRes = await bridge.handleBridgeCall('storage_get', {
        'key': 'theme_pref',
      });
      expect(getRes['success'], isTrue);
      expect(getRes['data'], isA<Map>());
      expect(getRes['data']['color'], '#FF0000');
      expect(getRes['data']['speed'], 5);

      final removeRes = await bridge.handleBridgeCall('storage_remove', {
        'key': 'theme_pref',
      });
      expect(removeRes['success'], isTrue);

      final getAfterRemove = await bridge.handleBridgeCall('storage_get', {
        'key': 'theme_pref',
      });
      expect(getAfterRemove['data'], isNull);
    });

    test('FS API reads and writes within data directory safely', () async {
      final targetFile = p.join(dataDir.path, 'config.json');

      final writeRes = await bridge.handleBridgeCall('fs_write', {
        'path': targetFile,
        'content': jsonEncode({'status': 'active'}),
        'encoding': 'utf8',
      });
      expect(writeRes['success'], isTrue);

      final existsRes = await bridge.handleBridgeCall('fs_exists', {
        'path': targetFile,
      });
      expect(existsRes['data'], isTrue);

      final readRes = await bridge.handleBridgeCall('fs_read', {
        'path': targetFile,
        'encoding': 'utf8',
      });
      expect(readRes['success'], isTrue);
      expect(jsonDecode(readRes['data'] as String)['status'], 'active');
    });

    test('System API triggers toast and fullscreen hooks', () async {
      String? toastMsg;
      String? toastType;
      bool? fsState;

      bridge.onShowToast = (m, t) {
        toastMsg = m;
        toastType = t;
      };
      bridge.onSetFullscreen = (fs) async {
        fsState = fs;
      };

      await bridge.handleBridgeCall('system_toast', {
        'message': 'Hello from Web',
        'type': 'success',
      });
      expect(toastMsg, 'Hello from Web');
      expect(toastType, 'success');

      await bridge.handleBridgeCall('system_set_fullscreen', {
        'fullscreen': true,
      });
      expect(fsState, isTrue);
    });

    test('Unknown action returns structured error without crashing', () async {
      final res = await bridge.handleBridgeCall('unknown_command', {});
      expect(res['success'], isFalse);
      expect(res['error'], contains('未知的 Host Bridge 动作'));
    });

    test('getInjectionScript contains window.Toolbox declaration and API namespaces', () {
      final script = WebviewBridgeService.getInjectionScript();
      expect(script, contains('window.Toolbox'));
      expect(script, contains('ToolboxBridge'));
      expect(script, contains('storage:'));
      expect(script, contains('fs:'));
      expect(script, contains('system:'));
      expect(script, contains('dialog:'));
      expect(script, contains('uninstaller:'));
      expect(script, contains('ssh:'));
    });

    test('Uninstaller API checks platform support', () async {
      final res = await bridge.handleBridgeCall('uninstaller_is_supported', {});
      expect(res['success'], isTrue);
      expect(res['data'], isA<bool>());
    });

    test('SSH Profile API loads, saves, and deletes profiles', () async {
      final saveRes = await bridge.handleBridgeCall('ssh_save_profile', {
        'profile': {
          'name': 'Test Server',
          'host': '192.168.1.50',
          'port': 22,
          'username': 'admin',
          'authMethod': 'password',
        },
      });
      expect(saveRes['success'], isTrue);

      final loadRes = await bridge.handleBridgeCall('ssh_load_profiles', {});
      expect(loadRes['success'], isTrue);
      expect(loadRes['data'], isA<List>());
      final list = loadRes['data'] as List;
      expect(list.length, 1);
      expect(list[0]['host'], '192.168.1.50');

      final delRes = await bridge.handleBridgeCall('ssh_delete_profile', {
        'authority': '192.168.1.50:22',
      });
      expect(delRes['success'], isTrue);

      final loadAfterDel = await bridge.handleBridgeCall('ssh_load_profiles', {});
      expect((loadAfterDel['data'] as List).isEmpty, isTrue);
    });
  });
}
