import 'package:flutter_test/flutter_test.dart';
import 'package:app/models/registry_mirror_node.dart';
import 'package:app/services/app_update_service.dart';
import 'package:app/services/plugin_manager_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Multi-Source Registry & Mirror Node Tests', () {
    test('Default mirror nodes include Gitee, jsDelivr CDN, and GitHub Raw', () {
      final nodes = RegistryMirrorNode.defaultNodes;
      expect(nodes.length, greaterThanOrEqualTo(3));

      final giteeNode = nodes.firstWhere((n) => n.id == 'gitee');
      expect(giteeNode.indexUrl, contains('gitee.com/sujiuovo/toolbox-community-registry'));
      expect(giteeNode.appVersionUrl, contains('app_version.json'));

      final cdnNode = nodes.firstWhere((n) => n.id == 'github_cdn');
      expect(cdnNode.indexUrl, contains('cdn.jsdelivr.net'));

      final ghNode = nodes.firstWhere((n) => n.id == 'github_raw');
      expect(ghNode.indexUrl, contains('raw.githubusercontent.com'));
    });

    test('PluginManagerService supports node mode switching and initial node', () async {
      final service = PluginManagerService();
      await service.init();

      expect(service.allNodes.isNotEmpty, isTrue);
      expect(service.currentActiveNode, isNotNull);

      await service.setNodeMode('github_cdn');
      expect(service.selectedNodeMode, 'github_cdn');
      expect(service.currentActiveNode.id, 'github_cdn');

      await service.setNodeMode('auto');
      expect(service.selectedNodeMode, 'auto');
    });
  });

  group('App Update Service Logic Tests', () {
    test('AppUpdateInfo correctly parses update payload', () {
      final jsonMap = {
        'latestVersion': '1.1.0',
        'minRequiredVersion': '1.0.0',
        'releaseDate': '2026-10-25',
        'title': '百宝箱 v1.1.0 社区生态发布',
        'releaseNotes': '1. 接入社区市场；\n2. 多源测速与故障切换。',
        'platforms': {
          'windows': {
            'url': 'https://gitee.com/sujiuovo/multi-toolbox/releases/download/v1.1.0/app-windows.zip',
            'mirrors': ['https://github.com/SuJiuOvO/Multi-Toolbox/releases/download/v1.1.0/app-windows.zip'],
            'sha256': 'abc123',
            'installType': 'zip_replace',
          },
          'android': {
            'url': 'https://gitee.com/sujiuovo/multi-toolbox/releases/download/v1.1.0/app-release.apk',
            'mirrors': [],
            'sha256': 'def456',
            'installType': 'apk_installer',
          }
        }
      };

      final latestVer = jsonMap['latestVersion'] as String;
      final hasUpdate = PluginManagerService.compareVersions(latestVer, '1.0.0') > 0;
      expect(hasUpdate, isTrue);

      final platforms = jsonMap['platforms'] as Map<String, dynamic>;
      final windowsUpdate = AppPlatformUpdate.fromJson(platforms['windows'] as Map<String, dynamic>);
      expect(windowsUpdate.url, contains('app-windows.zip'));
      expect(windowsUpdate.mirrors.length, 1);
      expect(windowsUpdate.installType, 'zip_replace');

      final androidUpdate = AppPlatformUpdate.fromJson(platforms['android'] as Map<String, dynamic>);
      expect(androidUpdate.url, contains('app-release.apk'));
      expect(androidUpdate.installType, 'apk_installer');
    });

    test('AppUpdateInfo detects when already up to date', () {
      final latestVer = '1.0.0';
      final currentVer = '1.0.0';
      final hasUpdate = PluginManagerService.compareVersions(latestVer, currentVer) > 0;
      expect(hasUpdate, isFalse);
    });
  });
}
