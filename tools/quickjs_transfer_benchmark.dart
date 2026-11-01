// Run explicitly with:
// flutter test tools/quickjs_transfer_benchmark.dart --reporter expanded --concurrency=1
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:app/models/plugin_manifest.dart';
import 'package:app/services/quickjs_bridge_service.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_js/flutter_js.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('manual QuickJS Base64 and binary transfer benchmark', () async {
    // Fail explicitly if the native engine is missing; a skipped benchmark
    // must never be mistaken for a measured transfer.
    final runtime = getJavascriptRuntime(xhr: false);
    try {
      final probe = runtime.evaluate('1 + 2');
      expect(probe.isError, isFalse);
      expect(probe.stringResult, '3');
    } finally {
      runtime.dispose();
    }

    const configuredSizes = String.fromEnvironment(
      'QUICKJS_BENCHMARK_SIZES',
      defaultValue: '1,10,50',
    );
    final sizes = configuredSizes.split(',').map(int.parse).toList();
    expect(sizes, isNotEmpty);
    expect(sizes.every((size) => size > 0 && size <= 50), isTrue,
        reason: 'Benchmark sizes must be integer MiB values between 1 and 50');

    final workspace = Directory.systemTemp.createTempSync('qjs_benchmark_');
    try {
      for (final sizeMiB in sizes) {
        final sizeBytes = sizeMiB * 1024 * 1024;
        final input = File(p.join(workspace.path, 'input-$sizeMiB.bin'));
        _writeFixture(input, sizeBytes);
        final expectedHash = await sha256.bind(input.openRead()).first;

        for (final mode in ['base64', 'readBinary']) {
          final output = Directory(p.join(workspace.path, '$sizeMiB-$mode'))
            ..createSync();
          final rssBefore = _readRss();
          final clock = Stopwatch()..start();
          final result = await QuickJsBridgeService.execute(
            plugin: _benchmarkManifest,
            formValues: {'mode': mode},
            inputFiles: [input.path],
            outputDir: output.path,
            onProgress: (_, __) {},
            onLog: (_, __) {},
          );
          clock.stop();
          final rssAfter = _readRss();
          final processMaxRss = _readRss(maximum: true);

          expect(result.success, isTrue, reason: result.message);
          final destination = File(p.join(output.path, 'roundtrip.bin'));
          expect(destination.lengthSync(), sizeBytes);
          final actualHash = await sha256.bind(destination.openRead()).first;
          expect(actualHash, expectedHash,
              reason: '$sizeMiB MiB $mode roundtrip');

          // RSS snapshots are not per-case peaks. maxRss is cumulative for
          // this entire test process, including earlier sizes and verification.
          // ignore: avoid_print
          print(jsonEncode({
            'sizeMiB': sizeMiB,
            'mode': mode,
            'executeMs': clock.elapsedMicroseconds / 1000,
            'js': result.resultData,
            'rssBeforeBytes': rssBefore,
            'rssAfterBytes': rssAfter,
            'processMaxRssBytes': processMaxRss,
            'sha256': actualHash.toString(),
          }));
        }
      }
    } finally {
      QuickJsBridgeService.killCurrentExecution();
      workspace.deleteSync(recursive: true);
    }
  }, timeout: const Timeout(Duration(minutes: 10)));
}

void _writeFixture(File file, int length) {
  final block = Uint8List.fromList(List.generate(1024 * 1024, (i) => i & 0xff));
  final sink = file.openSync(mode: FileMode.write);
  try {
    for (var offset = 0; offset < length; offset += block.length) {
      sink.writeFromSync(block);
    }
  } finally {
    sink.closeSync();
  }
}

int? _readRss({bool maximum = false}) {
  try {
    return maximum ? ProcessInfo.maxRss : ProcessInfo.currentRss;
  } on UnsupportedError {
    return null;
  }
}

final _benchmarkManifest = PluginManifest(
  id: 'quickjs-transfer-benchmark',
  name: 'QuickJS Transfer Benchmark',
  version: '1.0.0',
  category: 'other',
  description: 'Manual end-to-end binary transfer measurement',
  icon: 'code',
  author: 'Multi-Toolbox',
  engineType: 'quickjs',
  executionType: 'quickjs',
  platforms: ['universal'],
  action: PluginActionDef(
    handler: 'quickjs_eval',
    params: {
      'script': r'''
        async function run({ inputFiles, outputDir, params }) {
          const start = Date.now();
          const value = params.mode === 'base64'
            ? Toolbox.fs.readBytes(inputFiles[0])
            : Toolbox.fs.readBinary(inputFiles[0]);
          const readMs = Date.now() - start;
          if (params.mode === 'base64' && typeof value !== 'string') {
            throw new Error('readBytes must return a Base64 string');
          }
          if (params.mode !== 'base64' && !(value instanceof Uint8Array)) {
            throw new Error('readBinary must return Uint8Array');
          }
          const writeStart = Date.now();
          const output = outputDir + '/roundtrip.bin';
          if (params.mode === 'base64') {
            Toolbox.fs.writeFile(output, value, true);
          } else {
            Toolbox.fs.writeBinary(output, value);
          }
          return {
            success: true,
            data: {
              readMs,
              writeMs: Date.now() - writeStart,
              transferredLength: value.length,
              representation: params.mode === 'base64' ? 'Base64 chars' : 'bytes'
            }
          };
        }
      ''',
    },
  ),
);
