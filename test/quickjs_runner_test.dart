import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_js/flutter_js.dart';
import 'package:app/models/plugin_manifest.dart';
import 'package:app/services/quickjs_bridge_service.dart';
import 'package:path/path.dart' as p;

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

    test('QuickJsBridgeService handles binary I/O and Uint8Array transformation with Toolbox.fs and Toolbox.utils', () async {
      final outDir = Directory.systemTemp.createTempSync('qjs_binary_test_');
      try {
        // Create an arbitrary binary file (containing non-UTF8 bytes like 0xFF, 0xD8, 0x00, 0x89, 0x50)
        final binarySource = File('${outDir.path}/raw_binary.bin');
        binarySource.writeAsBytesSync([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0xFF, 0xD8, 0x00, 0xAA]);

        final manifest = PluginManifest(
          id: 'test-binary-io',
          name: 'Binary IO Test',
          version: '1.0.0',
          category: 'developer',
          description: 'Testing binary file I/O',
          icon: 'code',
          author: 'Test',
          engineType: 'quickjs',
          executionType: 'quickjs',
          platforms: ['universal'],
          action: PluginActionDef(
            handler: 'quickjs_eval',
            params: {
              'script': """
                async function run({ inputFiles, outputDir, params }) {
                  const srcPath = outputDir + '/raw_binary.bin';
                  
                  // 1. Read binary via readBytes (Base64)
                  const b64Data = Toolbox.fs.readBytes(srcPath);
                  Toolbox.log('Base64 length: ' + b64Data.length);
                  
                  // 2. Convert to Uint8Array using helper
                  const bytes = Toolbox.utils.base64ToBytes(b64Data);
                  Toolbox.log('Bytes length: ' + bytes.length);
                  
                  // Verify magic bytes (PNG header: 0x89 0x50)
                  const isPngMagic = (bytes[0] === 0x89 && bytes[1] === 0x50);
                  
                  // Mutate last byte (0xAA -> 0xBB)
                  bytes[bytes.length - 1] = 0xBB;
                  
                  // 3. Convert back to Base64 and write
                  const modifiedB64 = Toolbox.utils.bytesToBase64(bytes);
                  const destPath = outputDir + '/modified_binary.bin';
                  Toolbox.fs.writeFile(destPath, modifiedB64, true);
                  
                  return { success: isPngMagic, message: 'Binary I/O complete' };
                }
              """
            },
          ),
        );

        final result = await QuickJsBridgeService.execute(
          plugin: manifest,
          formValues: {},
          inputFiles: [],
          outputDir: outDir.path,
          onProgress: (pct, stage) {},
          onLog: (line, isError) {},
        );

        expect(result.success, true);
        final modFile = File('${outDir.path}/modified_binary.bin');
        expect(modFile.existsSync(), true);
        final modBytes = modFile.readAsBytesSync();
        expect(modBytes.length, 12);
        expect(modBytes[0], 0x89);
        expect(modBytes[1], 0x50);
        expect(modBytes[11], 0xBB);
      } finally {
        if (outDir.existsSync()) outDir.deleteSync(recursive: true);
      }
    });

    test('QuickJsBridgeService base64ToBytes accurately decodes padded base64 without byte loss', () async {
      if (!canRunQuickJs) return;
      final outDir = Directory.systemTemp.createTempSync('qjs_b64_pad_test_');
      try {
        final manifest = PluginManifest(
          id: 'test-js-b64-pad',
          name: 'QuickJS Base64 Padding Test',
          version: '1.0.0',
          category: 'text',
          description: 'Testing base64ToBytes padding calculation',
          icon: 'code',
          author: 'Test',
          engineType: 'quickjs',
          executionType: 'quickjs',
          platforms: ['universal'],
          action: PluginActionDef(
            handler: 'quickjs_eval',
            params: {
              'script': """
                async function run() {
                  // 1 byte (AQ==)
                  const b1 = Toolbox.utils.base64ToBytes('AQ==');
                  // 2 bytes (AQI=)
                  const b2 = Toolbox.utils.base64ToBytes('AQI=');
                  // 3 bytes (AQID)
                  const b3 = Toolbox.utils.base64ToBytes('AQID');
                  // 4 bytes (AQIDBA==)
                  const b4 = Toolbox.utils.base64ToBytes('AQIDBA==');

                  const ok1 = (b1.length === 1 && b1[0] === 1);
                  const ok2 = (b2.length === 2 && b2[0] === 1 && b2[1] === 2);
                  const ok3 = (b3.length === 3 && b3[0] === 1 && b3[1] === 2 && b3[2] === 3);
                  const ok4 = (b4.length === 4 && b4[0] === 1 && b4[1] === 2 && b4[2] === 3 && b4[3] === 4);

                  return {
                    success: (ok1 && ok2 && ok3 && ok4),
                    lengths: [b1.length, b2.length, b3.length, b4.length]
                  };
                }
              """
            },
          ),
        );

        final logs = <String>[];
        final result = await QuickJsBridgeService.execute(
          plugin: manifest,
          formValues: {},
          inputFiles: [],
          outputDir: outDir.path,
          onProgress: (p, s) {},
          onLog: (l, e) => logs.add(l),
        );

        if (!result.success) {
          print('Execution failed: ${result.message}, logs: $logs');
        }

        expect(result.success, true);
      } finally {
        if (outDir.existsSync()) outDir.deleteSync(recursive: true);
      }
    });

    test('QuickJsBridgeService Toolbox.fs.delete and remove cleans up intermediate files and folders', () async {
      if (!canRunQuickJs) return;
      final outDir = Directory.systemTemp.createTempSync('qjs_fs_del_test_');
      try {
        final manifest = PluginManifest(
          id: 'test-js-fs-del',
          name: 'QuickJS FS Delete Test',
          version: '1.0.0',
          category: 'text',
          description: 'Testing Toolbox.fs.delete and remove',
          icon: 'code',
          author: 'Test',
          engineType: 'quickjs',
          executionType: 'quickjs',
          platforms: ['universal'],
          action: PluginActionDef(
            handler: 'quickjs_eval',
            params: {
              'script': """
                async function run({ outputDir }) {
                  const testFile = outputDir + '/temp_slice.tmp';
                  const testSubdir = outputDir + '/temp_sub';
                  
                  // 1. Write file & create dir
                  Toolbox.fs.writeFile(testFile, 'temporary slice data');
                  Toolbox.fs.mkdir(testSubdir);
                  Toolbox.fs.writeFile(testSubdir + '/sub.tmp', 'sub data');
                  
                  const fileCreated = Toolbox.fs.exists(testFile);
                  const dirCreated = Toolbox.fs.exists(testSubdir);
                  
                  // 2. Delete file with Toolbox.fs.remove
                  const delFileRes = Toolbox.fs.remove(testFile);
                  const fileExistsAfter = Toolbox.fs.exists(testFile);
                  
                  // 3. Delete directory with Toolbox.fs.delete
                  const delDirRes = Toolbox.fs.delete(testSubdir);
                  const dirExistsAfter = Toolbox.fs.exists(testSubdir);
                  
                  return {
                    success: (fileCreated && dirCreated && delFileRes && !fileExistsAfter && delDirRes && !dirExistsAfter)
                  };
                }
              """
            },
          ),
        );

        final logs = <String>[];
        final result = await QuickJsBridgeService.execute(
          plugin: manifest,
          formValues: {},
          inputFiles: [],
          outputDir: outDir.path,
          onProgress: (p, s) {},
          onLog: (l, e) => logs.add(l),
        );

        if (!result.success) {
          print('Execution failed: ${result.message}, logs: $logs');
        }

        expect(result.success, true);
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

    test('QuickJsBridgeService Path Jail blocks unauthorized file access outside allowed roots', () async {
      if (!canRunQuickJs) return;
      final outDir = Directory.systemTemp.createTempSync('qjs_jail_out_');

      try {
        final manifest = PluginManifest(
          id: 'test-jail-plugin',
          name: 'Jail Test',
          version: '1.0.0',
          category: 'other',
          description: 'Testing sandbox path security jail',
          icon: 'security',
          author: 'Security Auditor',
          engineType: 'quickjs',
          executionType: 'quickjs',
          platforms: ['universal'],
          action: PluginActionDef(
            handler: 'quickjs_eval',
            params: {
              'script': """
                async function run({ outputDir }) {
                  let blockedRead = false;
                  let blockedWrite = false;
                  
                  // Try reading unauthorized path outside sandbox
                  try {
                    Toolbox.fs.readFile('C:/Windows/System32/drivers/etc/hosts');
                  } catch (e) {
                    blockedRead = e.message.includes('沙箱安全拦截');
                  }
                  
                  // Try writing unauthorized path outside sandbox
                  try {
                    Toolbox.fs.writeFile('C:/unauthorized_secret.txt', 'evil payload');
                  } catch (e) {
                    blockedWrite = e.message.includes('沙箱安全拦截');
                  }

                  return {
                    success: blockedRead && blockedWrite,
                    data: { blockedRead: blockedRead, blockedWrite: blockedWrite },
                    text: 'Jail assertion passed'
                  };
                }
              """
            },
          ),
        );

        final logs = <String>[];
        final result = await QuickJsBridgeService.execute(
          plugin: manifest,
          formValues: {},
          inputFiles: [],
          outputDir: outDir.path,
          onProgress: (p, s) {},
          onLog: (l, e) => logs.add(l),
        );

        if (!result.success) {
          print('Execution failed: ${result.message}, logs: $logs');
        }

        expect(result.success, true);
        expect(result.resultText, 'Jail assertion passed');
      } finally {
        if (outDir.existsSync()) outDir.deleteSync(recursive: true);
      }
    });

    test('QuickJsBridgeService Path Jail blocks reading sibling files in parent directory without permission', () async {
      if (!canRunQuickJs) return;
      final tempFolder = Directory.systemTemp.createTempSync('qjs_jail_parent_');
      final outDir = Directory.systemTemp.createTempSync('qjs_jail_out2_');
      final selectedFile = File(p.join(tempFolder.path, 'selected.txt'))..writeAsStringSync('allowed content');
      File(p.join(tempFolder.path, 'secret_sibling.txt')).writeAsStringSync('super secret content');

      try {
        final manifest = PluginManifest(
          id: 'test-parent-jail-plugin',
          name: 'Parent Jail Test',
          version: '1.0.0',
          category: 'other',
          description: 'Testing parent folder traversal protection',
          icon: 'security',
          author: 'Security Auditor',
          engineType: 'quickjs',
          executionType: 'quickjs',
          platforms: ['universal'],
          permissions: [],
          action: PluginActionDef(
            handler: 'quickjs_eval',
            params: {
              'script': """
                async function run({ inputFiles, outputDir }) {
                  const allowedFile = inputFiles[0];
                  const siblingFile = allowedFile.replace('selected.txt', 'secret_sibling.txt');
                  
                  // 1. Reading explicitly selected file must succeed
                  const allowedContent = Toolbox.fs.readFile(allowedFile);
                  
                  // 2. Reading sibling file without permission must be blocked
                  let blockedSibling = false;
                  try {
                    Toolbox.fs.readFile(siblingFile);
                  } catch (e) {
                    blockedSibling = e.message.includes('沙箱安全拦截');
                  }
                  
                  // 3. Listing parent dir without permission must be blocked
                  let blockedList = false;
                  try {
                    const lastSlash = Math.max(allowedFile.lastIndexOf('/'), allowedFile.lastIndexOf('\\\\'));
                    const parentDir = allowedFile.substring(0, lastSlash);
                    Toolbox.fs.readDir(parentDir);
                  } catch (e) {
                    blockedList = e.message.includes('沙箱安全拦截');
                  }

                  return {
                    success: allowedContent === 'allowed content' && blockedSibling && blockedList,
                    data: { blockedSibling, blockedList },
                    text: 'Parent jail protection passed'
                  };
                }
              """
            },
          ),
        );

        final logs = <String>[];
        final result = await QuickJsBridgeService.execute(
          plugin: manifest,
          formValues: {},
          inputFiles: [selectedFile.path],
          outputDir: outDir.path,
          onProgress: (p, s) {},
          onLog: (l, e) => logs.add(l),
        );

        if (!result.success) {
          print('Parent Jail test failed: ${result.message}, logs: $logs');
        }

        expect(result.success, true);
        expect(result.resultText, 'Parent jail protection passed');
      } finally {
        if (tempFolder.existsSync()) tempFolder.deleteSync(recursive: true);
        if (outDir.existsSync()) outDir.deleteSync(recursive: true);
      }
    });

    test('QuickJsBridgeService allows sibling files when fs:read_directory permission is declared', () async {
      if (!canRunQuickJs) return;
      final tempFolder = Directory.systemTemp.createTempSync('qjs_jail_perm_');
      final outDir = Directory.systemTemp.createTempSync('qjs_jail_out3_');
      final selectedFile = File(p.join(tempFolder.path, 'track.mp3'))..writeAsStringSync('audio data');
      File(p.join(tempFolder.path, 'track.lrc')).writeAsStringSync('lyrics data');

      try {
        final manifest = PluginManifest(
          id: 'test-parent-perm-plugin',
          name: 'Parent Perm Test',
          version: '1.0.0',
          category: 'other',
          description: 'Testing authorized sibling folder access',
          icon: 'security',
          author: 'Security Auditor',
          engineType: 'quickjs',
          executionType: 'quickjs',
          platforms: ['universal'],
          permissions: ['fs:read_directory'],
          action: PluginActionDef(
            handler: 'quickjs_eval',
            params: {
              'script': """
                async function run({ inputFiles, outputDir }) {
                  const audioFile = inputFiles[0];
                  const lrcFile = audioFile.replace('track.mp3', 'track.lrc');
                  const lrcContent = Toolbox.fs.readFile(lrcFile);
                  return {
                    success: lrcContent === 'lyrics data',
                    text: 'Authorized sibling access passed'
                  };
                }
              """
            },
          ),
        );

        final result = await QuickJsBridgeService.execute(
          plugin: manifest,
          formValues: {},
          inputFiles: [selectedFile.path],
          outputDir: outDir.path,
          onProgress: (p, s) {},
          onLog: (l, e) {},
        );

        expect(result.success, true);
        expect(result.resultText, 'Authorized sibling access passed');
      } finally {
        if (tempFolder.existsSync()) tempFolder.deleteSync(recursive: true);
        if (outDir.existsSync()) outDir.deleteSync(recursive: true);
      }
    });

    test('QuickJsBridgeService Toolbox.storage persists and retrieves values per-plugin', () async {
      if (!canRunQuickJs) return;
      final outDir = Directory.systemTemp.createTempSync('qjs_storage_out_');

      try {
        final manifest = PluginManifest(
          id: 'test-storage-plugin',
          name: 'Storage Test',
          version: '1.0.0',
          category: 'other',
          description: 'Testing isolated plugin storage',
          icon: 'storage',
          author: 'Test Team',
          engineType: 'quickjs',
          executionType: 'quickjs',
          platforms: ['universal'],
          action: PluginActionDef(
            handler: 'quickjs_eval',
            params: {
              'script': """
                async function run({ outputDir }) {
                  Toolbox.storage.set('apiKey', 'sk_live_test_12345');
                  Toolbox.storage.set('themeMode', 'dark');
                  
                  const savedKey = Toolbox.storage.get('apiKey');
                  const savedTheme = Toolbox.storage.get('themeMode');
                  const defVal = Toolbox.storage.get('nonExistent', 'fallback');
                  
                  Toolbox.storage.remove('themeMode');
                  const all = Toolbox.storage.getAll();

                  return {
                    success: (savedKey === 'sk_live_test_12345' && savedTheme === 'dark' && defVal === 'fallback' && all.apiKey === 'sk_live_test_12345' && all.themeMode === undefined),
                    data: all,
                    text: 'Storage roundtrip verified'
                  };
                }
              """
            },
          ),
        );

        final logs = <String>[];
        final result = await QuickJsBridgeService.execute(
          plugin: manifest,
          formValues: {},
          inputFiles: [],
          outputDir: outDir.path,
          onProgress: (p, s) {},
          onLog: (l, e) => logs.add(l),
        );

        if (!result.success) {
          print('Execution failed: ${result.message}, logs: $logs');
        }

        expect(result.success, true);
        expect(result.resultData is Map, true);
        expect((result.resultData as Map)['apiKey'], 'sk_live_test_12345');
      } finally {
        if (outDir.existsSync()) outDir.deleteSync(recursive: true);
      }
    });

    test('QuickJsBridgeService blocks network requests when network permission is missing', () async {
      if (!canRunQuickJs) return;
      final outDir = Directory.systemTemp.createTempSync('qjs_net_out_');

      try {
        final manifest = PluginManifest(
          id: 'test-no-network-plugin',
          name: 'No Network Test',
          version: '1.0.0',
          category: 'other',
          description: 'Testing network permission guard',
          icon: 'wifi_off',
          author: 'Test Team',
          engineType: 'quickjs',
          executionType: 'quickjs',
          platforms: ['universal'],
          permissions: [], // No network permission!
          action: PluginActionDef(
            handler: 'quickjs_eval',
            params: {
              'script': """
                async function run() {
                  let syncBlocked = false;
                  try {
                    Toolbox.http.get('https://example.com/api');
                  } catch (e) {
                    syncBlocked = e.message.includes('network') || e.message.includes('网络');
                  }

                  let asyncBlocked = false;
                  try {
                    await fetch('https://example.com/api');
                  } catch (e) {
                    asyncBlocked = e.message.includes('network') || e.message.includes('网络');
                  }

                  return { 
                    success: (syncBlocked && asyncBlocked), 
                    text: 'Network interception verified' 
                  };
                }
              """
            },
          ),
        );

        final logs = <String>[];
        final result = await QuickJsBridgeService.execute(
          plugin: manifest,
          formValues: {},
          inputFiles: [],
          outputDir: outDir.path,
          onProgress: (p, s) {},
          onLog: (l, e) => logs.add(l),
        );

        if (!result.success) {
          print('Execution failed: ${result.message}, logs: $logs');
        }

        expect(result.success, true);
        expect(result.resultText, 'Network interception verified');
      } finally {
        if (outDir.existsSync()) outDir.deleteSync(recursive: true);
      }
    });

    test('QuickJsBridgeService Toolbox.http.fetch and getAsync execute non-blocking HTTP successfully with permission', () async {
      if (!canRunQuickJs) return;
      final prevOverrides = HttpOverrides.current;
      HttpOverrides.global = null; // 解除 flutter_test 对真实本地 HttpClient 的 400 拦截
      final outDir = Directory.systemTemp.createTempSync('qjs_async_net_');

      // 启动本地测试 HTTP 服务
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((HttpRequest request) {
        if (request.uri.path == '/api/greet') {
          request.response
            ..statusCode = 200
            ..headers.contentType = ContentType.json
            ..write('{"greeting": "Hello Async Host Bridge!"}')
            ..close();
        } else {
          request.response
            ..statusCode = 404
            ..close();
        }
      });

      final port = server.port;

      try {
        final manifest = PluginManifest(
          id: 'test-async-network-plugin',
          name: 'Async Network Test',
          version: '1.0.0',
          category: 'other',
          description: 'Testing async fetch & getAsync',
          icon: 'wifi',
          author: 'Test Team',
          engineType: 'quickjs',
          executionType: 'quickjs',
          platforms: ['universal'],
          permissions: ['network'], // 明确授权 network
          action: PluginActionDef(
            handler: 'quickjs_eval',
            params: {
              'script': """
                async function run() {
                  const url = 'http://127.0.0.1:$port/api/greet';
                  
                  // 1. 测试异步 Toolbox.http.getAsync (支持 .json() 与 .body)
                  const res1 = await Toolbox.http.getAsync(url);
                  Toolbox.log('res1:', JSON.stringify(res1));
                  const parsed1 = await res1.json();
                  
                  // 2. 测试全局标准 fetch (自动路由到 Toolbox.http.fetch 异步宿主桥)
                  const res2 = await fetch(url);
                  Toolbox.log('res2:', JSON.stringify(res2));
                  const parsed2 = await res2.json();

                  return {
                    success: (res1.statusCode === 200 && res1.ok === true && parsed1.greeting === 'Hello Async Host Bridge!' && res2.status === 200 && res2.ok === true && parsed2.greeting === 'Hello Async Host Bridge!'),
                    data: { res1: parsed1, res2: parsed2 },
                    text: parsed2.greeting
                  };
                }
              """
            },
          ),
        );

        final logs = <String>[];
        final result = await QuickJsBridgeService.execute(
          plugin: manifest,
          formValues: {},
          inputFiles: [],
          outputDir: outDir.path,
          onProgress: (p, s) {},
          onLog: (l, e) => logs.add(l),
        );

        if (!result.success) {
          print('Execution failed: ${result.message}, logs: $logs');
        }

        expect(result.success, true);
        expect(result.resultText, 'Hello Async Host Bridge!');
        expect(result.resultData is Map, true);
      } finally {
        HttpOverrides.global = prevOverrides;
        await server.close(force: true);
        if (outDir.existsSync()) outDir.deleteSync(recursive: true);
      }
    });
  });
}
