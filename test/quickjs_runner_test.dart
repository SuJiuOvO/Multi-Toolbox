import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_js/flutter_js.dart';
import 'package:app/models/plugin_manifest.dart';
import 'package:app/services/quickjs_bridge_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('QuickJS Runtime & Host Bridge Tests', () {
    test('Flutter JS basic evaluation and JSON processing', () {
      final jsRuntime = getJavascriptRuntime();
      try {
        final jsResult = jsRuntime.evaluate('1 + 2 * 3');
        expect(jsResult.stringResult, '7');
      } finally {
        jsRuntime.dispose();
      }
    });

    test('QuickJsBridgeService executes inline JS with Host Bridge fs & crypto', () async {
      final tempDir = Directory.systemTemp.createTempSync('qjs_test_');
      final outDir = Directory.systemTemp.createTempSync('qjs_out_');

      try {
        final manifest = PluginManifest(
          id: 'test-js-plugin',
          name: 'QuickJS Test Plugin',
          version: '1.0.0',
          category: 'text',
          description: 'A test plugin powered by QuickJS sandbox',
          icon: 'code',
          author: 'Test Team',
          engineType: 'quickjs',
          executionType: 'quickjs',
          platforms: ['universal'],
          action: PluginActionDef(
            handler: 'quickjs_eval',
            params: {
              'script': """
                async function run({ inputFiles, outputDir, params }) {
                  Toolbox.log('Hello from QuickJS sandbox!');
                  Toolbox.setProgress(0.5, 'Hashing content...');
                  
                  const targetText = 'Hello QuickJS Host Bridge';
                  const md5Hash = Toolbox.crypto.md5(targetText);
                  const shaHash = Toolbox.crypto.sha256(targetText);
                  
                  const outFilePath = outputDir + '/hash_result.json';
                  const jsonReport = JSON.stringify({
                    target: targetText,
                    md5: md5Hash,
                    sha256: shaHash,
                    platform: Toolbox.platform
                  }, null, 2);
                  
                  Toolbox.fs.writeFile(outFilePath, jsonReport);
                  Toolbox.setProgress(1.0, 'Done');
                  
                  return { success: true, message: 'All hashes generated successfully' };
                }
              """
            },
          ),
        );

        final capturedLogs = <String>[];
        final progressUpdates = <double>[];

        final result = await QuickJsBridgeService.execute(
          plugin: manifest,
          formValues: {},
          inputFiles: [],
          outputDir: outDir.path,
          onProgress: (pct, stage) {
            progressUpdates.add(pct);
          },
          onLog: (line, isError) {
            capturedLogs.add(line);
          },
        );

        expect(result.success, true);
        expect(capturedLogs.any((l) => l.contains('Hello from QuickJS sandbox!')), true);
        expect(progressUpdates.contains(0.5), true);
        expect(result.outputFiles.length, 1);

        final generatedFile = File(result.outputFiles.first);
        expect(generatedFile.existsSync(), true);

        final content = generatedFile.readAsStringSync();
        expect(content.contains('Hello QuickJS Host Bridge'), true);
        expect(content.contains('"md5":'), true);
        expect(content.contains('"sha256":'), true);
      } finally {
        if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
        if (outDir.existsSync()) outDir.deleteSync(recursive: true);
      }
    });

    test('PluginManifest correctly identifies QuickJS plugin and badges', () {
      final manifest = PluginManifest(
        id: 'js-markdown-formatter',
        name: 'JS Markdown Formatter',
        version: '1.0.0',
        category: 'text',
        description: 'Format markdown',
        icon: 'edit',
        author: 'Community',
        engineType: 'quickjs',
        executionType: 'quickjs',
        platforms: ['universal'],
      );

      expect(manifest.isQuickJsPlugin, true);
      expect(manifest.isWindowsExtension, false);
      expect(manifest.hasTerminal, true);
      expect(manifest.platformBadgeText, '⚡ JS 动态插件');
    });
  });
}
