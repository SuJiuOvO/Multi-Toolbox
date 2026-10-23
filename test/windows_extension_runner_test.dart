import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:app/models/plugin_manifest.dart';
import 'package:app/services/windows_extension_runner_service.dart';
import 'package:app/pages/terminal_log_viewer.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Windows Open Extension Runner & Manifest Tests', () {
    test('PluginNativeRunnerDef JSON serialization & deserialization', () {
      final json = {
        'entry': 'curl.exe',
        'args': ['-L', '-o', '{outputDir}/{fileName}', '{url}'],
        'showTerminal': true,
        'shell': 'powershell',
        'runMode': 'child_process',
      };

      final runner = PluginNativeRunnerDef.fromJson(json);
      expect(runner.entry, 'curl.exe');
      expect(runner.args, ['-L', '-o', '{outputDir}/{fileName}', '{url}']);
      expect(runner.showTerminal, true);
      expect(runner.shell, 'powershell');
      expect(runner.runMode, 'child_process');

      final exported = runner.toJson();
      expect(exported['entry'], 'curl.exe');
      expect(exported['showTerminal'], true);
    });

    test('PluginManifest recognizes Windows Open Extension and Terminal', () {
      final json = {
        'id': 'windows-media-downloader',
        'name': 'Windows 流式抓取与下载器',
        'version': '1.0.0',
        'minAppVersion': '1.0.0',
        'category': 'win_ext',
        'platforms': ['windows'],
        'executionType': 'native_executable',
        'description': 'Windows Open Extension test description',
        'icon': 'bolt',
        'author': 'Toolbox 开放工坊',
        'engineType': 'win_native_runner',
        'inputs': [
          {
            'id': 'url',
            'label': '下载地址',
            'type': 'text',
            'defaultValue': 'https://example.com/test.bin',
            'required': true,
          },
          {
            'id': 'fileName',
            'label': '文件名',
            'type': 'text',
            'defaultValue': 'output.bin',
            'required': true,
          }
        ],
        'nativeRunner': {
          'entry': 'curl.exe',
          'args': ['-L', '-o', '{outputDir}/{fileName}', '{url}'],
          'showTerminal': true,
        }
      };

      final manifest = PluginManifest.fromJson(json, isRemote: false);
      expect(manifest.id, 'windows-media-downloader');
      expect(manifest.isWindowsOnly(), true);
      expect(manifest.isWindowsExtension, true);
      expect(manifest.hasTerminal, true);
      expect(manifest.platformBadgeText, '⚡ Win 开放扩展');
      expect(manifest.nativeRunner, isNotNull);
      expect(manifest.nativeRunner!.entry, 'curl.exe');
    });

    test('TerminalLogEntry timestamps and error flags', () {
      final entry1 = TerminalLogEntry(text: 'Starting download...');
      expect(entry1.text, 'Starting download...');
      expect(entry1.isError, false);
      expect(entry1.timestamp, isNotNull);

      final entry2 = TerminalLogEntry(text: 'Process failed', isError: true);
      expect(entry2.text, 'Process failed');
      expect(entry2.isError, true);
    });

    test('WindowsExtensionRunnerService executes native command and captures logs', () async {
      if (!Platform.isWindows) return;

      final tempDir = Directory.systemTemp.createTempSync('win_ext_test_');
      final outDir = Directory.systemTemp.createTempSync('win_ext_out_');

      try {
        final manifest = PluginManifest(
          id: 'test-echo-extension',
          name: 'Echo Test',
          version: '1.0.0',
          category: 'win_ext',
          description: 'Test echo command',
          icon: 'terminal',
          author: 'Test',
          engineType: 'win_native_runner',
          executionType: 'native_executable',
          platforms: ['windows'],
          nativeRunner: PluginNativeRunnerDef(
            entry: 'cmd.exe',
            args: ['/c', 'echo', 'Hello-From-Windows-Extension'],
            showTerminal: true,
          ),
        );

        final capturedLogs = <String>[];
        final result = await WindowsExtensionRunnerService.execute(
          plugin: manifest,
          formValues: {},
          inputFiles: [],
          outputDir: outDir.path,
          onProgress: (p, s) {},
          onLog: (line, isError) {
            capturedLogs.add(line);
          },
        );

        expect(result.success, true);
        expect(capturedLogs.any((l) => l.contains('Hello-From-Windows-Extension')), true);
      } finally {
        if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
        if (outDir.existsSync()) outDir.deleteSync(recursive: true);
      }
    });
  });
}
