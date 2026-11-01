import 'package:flutter/material.dart';

import '../models/plugin_manifest.dart';
import '../services/plugin_manager_service.dart';
import 'dynamic_tool_runner_page.dart';
import 'handheld_bulletin_page.dart';
import 'ssh_terminal_page.dart';
import 'windows_uninstaller_page.dart';

/// One entry point for file-processing tools and persistent interactive tools.
class PluginRunnerPage extends StatelessWidget {
  const PluginRunnerPage({super.key, required this.plugin});

  final PluginManifest plugin;

  static Widget destinationFor(PluginManifest plugin) {
    // Scripts and native programs retain their declared execution engine.
    if (plugin.executionType == 'internal' && plugin.nativeRunner == null) {
      switch (plugin.action?.handler) {
        case 'handheld_bulletin':
          return const HandheldBulletinPage();
        case 'windows_uninstaller':
          return const WindowsUninstallerPage();
        case 'ssh_terminal':
          return const SshTerminalPage();
      }
    }
    return DynamicToolRunnerPage(plugin: plugin);
  }

  @override
  Widget build(BuildContext context) {
    if (!plugin.isSupportedOnCurrentPlatform() ||
        !PluginManagerService.isAppVersionCompatible(plugin.minAppVersion)) {
      return Scaffold(
        appBar: AppBar(title: Text(plugin.name)),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(
              !plugin.isSupportedOnCurrentPlatform()
                  ? '此插件不支持当前平台。'
                  : '此插件需要客户端 ${plugin.minAppVersion} 或更高版本，请先更新客户端。',
            ),
          ),
        ),
      );
    }
    return destinationFor(plugin);
  }
}
