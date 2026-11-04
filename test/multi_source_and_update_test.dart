import 'package:flutter_test/flutter_test.dart';
import 'package:app/models/plugin_manifest.dart';
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

    test('PluginManagerService.compareVersions correctly compares semantic versions', () {
      expect(PluginManagerService.compareVersions('1.1.0', '1.0.0'), 1);
      expect(PluginManagerService.compareVersions('1.0.0', '1.1.0'), -1);
      expect(PluginManagerService.compareVersions('1.1.0', '1.1.0'), 0);
      expect(PluginManagerService.compareVersions('v1.2.0', '1.1.9'), 1);
      expect(PluginManagerService.compareVersions('1.0.1', '1.0.0+1'), 1);
      expect(PluginManagerService.compareVersions('1.0.0', '1.0.0+2'), 0);
    });

    test('Older remote plugin version does not falsely flag isUpdateAvailable', () {
      const localVersion = '1.1.0';
      const remoteOlderVersion = '1.0.0';
      const remoteSameVersion = '1.1.0';
      const remoteNewerVersion = '1.2.0';

      final bool olderTriggers = PluginManagerService.compareVersions(remoteOlderVersion, localVersion) > 0;
      final bool sameTriggers = PluginManagerService.compareVersions(remoteSameVersion, localVersion) > 0;
      final bool newerTriggers = PluginManagerService.compareVersions(remoteNewerVersion, localVersion) > 0;

      expect(olderTriggers, isFalse, reason: 'Remote older version should never trigger update');
      expect(sameTriggers, isFalse, reason: 'Identical version should never trigger update');
      expect(newerTriggers, isTrue, reason: 'Strictly newer version should trigger update');
    });
  });

  group('Release Assets & Multi-Source Download Resolution Tests', () {
    test('isValidZipHeader correctly identifies ZIP magic bytes', () {
      expect(PluginManagerService.isValidZipHeader([0x50, 0x4B, 0x03, 0x04]), isTrue);
      expect(PluginManagerService.isValidZipHeader([0x50, 0x4B, 0x05, 0x06]), isTrue);
      expect(PluginManagerService.isValidZipHeader([0x50, 0x4B, 0x07, 0x08]), isTrue);

      // Invalid bytes (e.g. HTML / truncated)
      expect(PluginManagerService.isValidZipHeader([0x3C, 0x21, 0x44, 0x4F]), isFalse); // '<!DO'
      expect(PluginManagerService.isValidZipHeader([0x50, 0x4B, 0x01]), isFalse); // < 4 bytes
      expect(PluginManagerService.isValidZipHeader([]), isFalse);
    });

    test('resolveDownloadCandidateUrls prioritizes active node and resolves Release CDN mirror', () {
      final plugin = PluginManifest.fromJson({
        'id': 'test-plugin',
        'name': '测试插件',
        'version': '1.0.0',
        'minAppVersion': '1.0.0',
        'author': 'Tester',
        'category': 'other',
        'description': 'Desc',
        'icon': 'tool',
        'engineType': 'quickjs',
        'downloadUrls': {
          'gitee': 'https://gitee.com/sujiuovo/toolbox-community-registry/releases/download/plugins/test-plugin.zip',
          'github_cdn': 'https://ghproxy.net/https://github.com/SuJiuOvO/Toolbox-Community-Registry/releases/download/plugins/test-plugin.zip',
          'github_release': 'https://github.com/SuJiuOvO/Toolbox-Community-Registry/releases/download/plugins/test-plugin.zip',
        },
        'downloadUrl': 'https://ghproxy.net/https://github.com/SuJiuOvO/Toolbox-Community-Registry/releases/download/plugins/test-plugin.zip',
      });

      // When active node is github_cdn
      final cdnNode = RegistryMirrorNode.defaultNodes.firstWhere((n) => n.id == 'github_cdn');
      final cdnCandidates = PluginManagerService.resolveDownloadCandidateUrls(
        plugin: plugin,
        activeNode: cdnNode,
        nodes: RegistryMirrorNode.defaultNodes,
      );

      expect(cdnCandidates.first, contains('ghproxy.net'));
      expect(cdnCandidates, contains('https://github.com/SuJiuOvO/Toolbox-Community-Registry/releases/download/plugins/test-plugin.zip'));
      expect(cdnCandidates, contains('https://gitee.com/sujiuovo/toolbox-community-registry/releases/download/plugins/test-plugin.zip'));

      // When active node is gitee
      final giteeNode = RegistryMirrorNode.defaultNodes.firstWhere((n) => n.id == 'gitee');
      final giteeCandidates = PluginManagerService.resolveDownloadCandidateUrls(
        plugin: plugin,
        activeNode: giteeNode,
        nodes: RegistryMirrorNode.defaultNodes,
      );

      expect(giteeCandidates.first, contains('gitee.com'));
      expect(giteeCandidates, contains('https://ghproxy.net/https://github.com/SuJiuOvO/Toolbox-Community-Registry/releases/download/plugins/test-plugin.zip'));

      // When active node is github_raw
      final ghRawNode = RegistryMirrorNode.defaultNodes.firstWhere((n) => n.id == 'github_raw');
      final ghRawCandidates = PluginManagerService.resolveDownloadCandidateUrls(
        plugin: plugin,
        activeNode: ghRawNode,
        nodes: RegistryMirrorNode.defaultNodes,
      );

      // github_raw resolves to github_release alias
      expect(ghRawCandidates.first, 'https://github.com/SuJiuOvO/Toolbox-Community-Registry/releases/download/plugins/test-plugin.zip');
    });

    test('resolveDownloadCandidateUrls synthesizes CDN proxy for direct GitHub Release URLs', () {
      final plugin = PluginManifest.fromJson({
        'id': 'direct-gh-tool',
        'name': 'Direct GH Tool',
        'version': '1.0.0',
        'minAppVersion': '1.0.0',
        'author': 'Tester',
        'category': 'other',
        'description': 'Desc',
        'icon': 'tool',
        'engineType': 'quickjs',
        'downloadUrls': {
          'github': 'https://github.com/SuJiuOvO/Toolbox-Community-Registry/releases/download/plugins/direct-gh-tool.zip',
        },
      });

      final cdnNode = RegistryMirrorNode.defaultNodes.firstWhere((n) => n.id == 'github_cdn');
      final candidates = PluginManagerService.resolveDownloadCandidateUrls(
        plugin: plugin,
        activeNode: cdnNode,
        nodes: RegistryMirrorNode.defaultNodes,
      );

      expect(candidates.first, 'https://ghproxy.net/https://github.com/SuJiuOvO/Toolbox-Community-Registry/releases/download/plugins/direct-gh-tool.zip');
      expect(candidates, contains('https://github.com/SuJiuOvO/Toolbox-Community-Registry/releases/download/plugins/direct-gh-tool.zip'));
    });
  });
}
