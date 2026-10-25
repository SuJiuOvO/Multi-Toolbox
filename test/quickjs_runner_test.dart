import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_js/flutter_js.dart';
import 'package:app/models/plugin_manifest.dart';
import 'package:app/services/quickjs_bridge_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  bool canRunQuickJs = false;

  setUpAll(() {
    try {
      final jsRuntime = getJavascriptRuntime();
      jsRuntime.dispose();
      canRunQuickJs = true;
    } catch (_) {
      canRunQuickJs = false;
    }
  });

  group('QuickJS Runtime & Host Bridge Tests', () {
    test('Flutter JS basic evaluation and JSON processing', () {
      if (!canRunQuickJs) return;
      final jsRuntime = getJavascriptRuntime();
      try {
        final jsResult = jsRuntime.evaluate('1 + 2 * 3');
        expect(jsResult.stringResult, '7');
      } finally {
        jsRuntime.dispose();
      }
    });

    test('QuickJsBridgeService executes inline JS with Host Bridge fs & crypto', () async {
      if (!canRunQuickJs) return;
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

    test('QuickJsBridgeService executes JS script invoking Toolbox.archive', () async {
      if (!canRunQuickJs) return;
      final tempDir = Directory.systemTemp.createTempSync('qjs_archive_');
      final outDir = Directory.systemTemp.createTempSync('qjs_archive_out_');

      try {
        // Create an input file
        final srcFile = File('${tempDir.path}/secret_doc.txt');
        srcFile.writeAsStringSync('Highly classified document content for 7z/zip test');

        final manifest = PluginManifest(
          id: 'test-js-archive-plugin',
          name: 'JS Archive Plugin',
          version: '1.0.0',
          category: 'other',
          description: 'A test plugin powered by QuickJS and archive bridge',
          icon: 'archive',
          author: 'Test Team',
          engineType: 'quickjs',
          executionType: 'quickjs',
          platforms: ['universal'],
          action: PluginActionDef(
            handler: 'quickjs_eval',
            params: {
              'script': """
                async function run({ inputFiles, outputDir, params }) {
                  Toolbox.log('Starting compression via Toolbox.archive...');
                  const zipPath = outputDir + '/packaged.zip';
                  const compResult = await Toolbox.archive.compress(inputFiles, zipPath, 'zip');
                  Toolbox.log('Compress result:', compResult);
                  
                  const extractDir = outputDir + '/unpacked';
                  Toolbox.log('Starting extraction via Toolbox.archive...');
                  const extResult = await Toolbox.archive.extract(zipPath, extractDir);
                  Toolbox.log('Extract result:', extResult);
                  
                  return { success: true, message: 'Archive compress and extract done' };
                }
              """
            },
          ),
        );

        final capturedLogs = <String>[];
        final result = await QuickJsBridgeService.execute(
          plugin: manifest,
          formValues: {},
          inputFiles: [srcFile.path],
          outputDir: outDir.path,
          onProgress: (pct, stage) {},
          onLog: (line, isError) {
            capturedLogs.add(line);
          },
        );

        expect(result.success, true);
        final zipFile = File('${outDir.path}/packaged.zip');
        expect(zipFile.existsSync(), true);

        final extractedFile = File('${outDir.path}/unpacked/packaged/secret_doc.txt');
        expect(extractedFile.existsSync(), true);
        expect(extractedFile.readAsStringSync(), 'Highly classified document content for 7z/zip test');
      } finally {
        if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
        if (outDir.existsSync()) outDir.deleteSync(recursive: true);
      }
    });

    test('QuickJsBridgeService executes JS script invoking Toolbox.wasm', () async {
      if (!canRunQuickJs) return;
      final outDir = Directory.systemTemp.createTempSync('qjs_wasm_out_');
      try {
        final manifest = PluginManifest(
          id: 'test-js-wasm-plugin',
          name: 'JS Wasm Plugin',
          version: '1.0.0',
          category: 'other',
          description: 'A test plugin calling Wasm from JS',
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
                  Toolbox.log('Starting WASM execution from QuickJS sandbox...');
                  
                  const watCode = `
                    (module
                      (func (export "calc") (param i32 i32) (result i32)
                        local.get 0
                        local.get 1
                        i32.mul
                      )
                    )
                  `;
                  
                  const wasmRes = await Toolbox.wasm.call(watCode, 'calc', [7, 6]);
                  Toolbox.log('WASM calc result:', wasmRes);
                  
                  const outFilePath = outputDir + '/wasm_calc.json';
                  Toolbox.fs.writeFile(outFilePath, JSON.stringify(wasmRes));
                  
                  return { success: true, message: 'WASM multiplication returned: ' + wasmRes.result };
                }
              """
            },
          ),
        );

        final capturedLogs = <String>[];
        final result = await QuickJsBridgeService.execute(
          plugin: manifest,
          formValues: {},
          inputFiles: [],
          outputDir: outDir.path,
          onProgress: (pct, stage) {},
          onLog: (line, isError) {
            capturedLogs.add(line);
          },
        );

        expect(result.success, true);
        final reportFile = File('${outDir.path}/wasm_calc.json');
        expect(reportFile.existsSync(), true);
        expect(reportFile.readAsStringSync().contains('"result":[42]'), true);
      } finally {
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
