import 'dart:convert';
import 'dart:io';

import 'package:app/models/plugin_manifest.dart';
import 'package:app/pages/dynamic_tool_runner_page.dart';
import 'package:app/pages/handheld_bulletin_page.dart';
import 'package:app/pages/plugin_runner_page.dart';
import 'package:app/pages/ssh_terminal_page.dart';
import 'package:app/pages/windows_uninstaller_page.dart';
import 'package:app/services/plugin_manager_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

PluginManifest manifest(String id) => PluginManifest.fromJson(
      jsonDecode(File('assets/default_plugins/$id.json').readAsStringSync())
          as Map<String, dynamic>,
    );

void main() {
  test('bundled interactive manifests select their real application pages', () {
    final bulletin = manifest('handheld-bulletin');
    final ssh = manifest('ssh-terminal');
    final uninstaller = manifest('windows-uninstaller');
    expect(
        PluginRunnerPage.destinationFor(bulletin), isA<HandheldBulletinPage>());
    expect(PluginRunnerPage.destinationFor(ssh), isA<SshTerminalPage>());
    expect(PluginRunnerPage.destinationFor(uninstaller),
        isA<WindowsUninstallerPage>());
    for (final plugin in [bulletin, ssh, uninstaller]) {
      expect(PluginManifest.defaultPluginIds, contains(plugin.id));
      expect(plugin.minAppVersion, '1.1.0');
      expect(PluginManagerService.isAppVersionCompatible(plugin.minAppVersion),
          isTrue);
      expect(plugin.executionType, 'internal');
    }
    expect(ssh.permissions, contains('network'));
    expect(uninstaller.platforms, ['windows']);
  });

  test('existing tools and scripts keep their original execution route', () {
    expect(PluginRunnerPage.destinationFor(manifest('image-compress')),
        isA<DynamicToolRunnerPage>());
    final script = PluginManifest.fromJson({
      'id': 'external-script',
      'executionType': 'quickjs',
      'action': {'handler': 'ssh_terminal'},
    });
    expect(
        PluginRunnerPage.destinationFor(script), isA<DynamicToolRunnerPage>());
  });

  testWidgets('launcher explains an incompatible client before loading a tool',
      (tester) async {
    final futurePlugin = PluginManifest.fromJson({
      'id': 'future-ssh',
      'name': 'SSH',
      'minAppVersion': '99.0.0',
      'action': {'handler': 'ssh_terminal'},
    });
    await tester.pumpWidget(
      MaterialApp(home: PluginRunnerPage(plugin: futurePlugin)),
    );
    expect(find.textContaining('99.0.0'), findsOneWidget);
    expect(find.byType(SshTerminalPage), findsNothing);
  });
}
