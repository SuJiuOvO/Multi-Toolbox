import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:wasm_run/wasm_run.dart';
// ignore: implementation_imports
import 'package:wasm_run/src/rust/api.dart' show parseWatFormat;
import 'package:app/services/wasm_universal_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  bool canRunWasm = false;

  setUpAll(() async {
    final dllFile = File('wasm_run_dart.dll');
    if (dllFile.existsSync()) {
      try {
        await WasmRunLibrary.setUp(
          lib: ExternalLibrary.open(dllFile.absolute.path),
        );
        canRunWasm = true;
      } catch (_) {}
    } else {
      try {
        await WasmRunLibrary.setUp();
        canRunWasm = true;
      } catch (_) {}
    }
  });

  group('WebAssembly (WASM) Sandbox Engine Tests', () {
    test('Compile and execute in-memory WebAssembly module (add function)', () async {
      if (!canRunWasm) return;
      // 41-byte valid WebAssembly module exporting add(i32, i32) -> i32
      const wasmB64 = 'AGFzbQEAAAABBwFgAn9/AX8DAgEABwcBA2FkZAAACgkBBwAgACABags=';
      final wasmBytes = Uint8List.fromList(base64Decode(wasmB64));

      // 1. Compile WASM bytecode into machine module
      final module = await compileWasmModule(wasmBytes);

      // 2. Introspect module exports
      final exports = module.getExports();
      expect(exports.any((e) => e.name == 'add'), true);

      // 3. Instantiate WASM module in sandbox
      final instance = await module.builder().build();

      // 4. Retrieve exported function
      final addFunc = instance.getFunction('add');
      expect(addFunc, isNotNull);

      // 5. Invoke exported function in sandbox
      final result1 = addFunc!([15, 27]);
      expect(result1, [42]);

      final result2 = addFunc([100, 234]);
      expect(result2, [334]);
    });

    test('Compile WAT text format on-the-fly and execute recursive fibonacci in WASM sandbox', () async {
      if (!canRunWasm) return;
      const watSource = r'''
(module
  (func $add (export "add") (param i32 i32) (result i32)
    local.get 0
    local.get 1
    i32.add
  )
  (func $fib (export "fib") (param i32) (result i32)
    local.get 0
    i32.const 2
    i32.lt_s
    if (result i32)
      local.get 0
    else
      local.get 0
      i32.const 1
      i32.sub
      call $fib
      local.get 0
      i32.const 2
      i32.sub
      call $fib
      i32.add
    end
  )
)
''';
      final binaryBytes = await parseWatFormat(wat: watSource);
      expect(binaryBytes.length > 20, true);

      final module = await compileWasmModule(binaryBytes);
      final exports = module.getExports();
      expect(exports.map((e) => e.name).toSet(), containsAll(['add', 'fib']));

      final instance = await module.builder().build();
      final fibFunc = instance.getFunction('fib');
      expect(fibFunc, isNotNull);

      // fib(0) = 0, fib(1) = 1, fib(2) = 1, fib(5) = 5, fib(10) = 55, fib(12) = 144
      expect(fibFunc!([0]), [0]);
      expect(fibFunc([1]), [1]);
      expect(fibFunc([5]), [5]);
      expect(fibFunc([10]), [55]);
      expect(fibFunc([12]), [144]);
    });

    test('WasmUniversalService execute pipeline runs successfully with report output', () async {
      if (!canRunWasm) return;
      final tempDir = Directory.systemTemp.createTempSync('wasm_service_test_');
      try {
        final logs = <String>[];
        final result = await WasmUniversalService.execute(
          formValues: {
            'sourceMode': 'demo',
            'executionMode': 'call_func',
            'functionName': 'fib',
            'functionArgs': '10',
            'exportJson': 'yes',
          },
          inputFiles: [],
          outputDir: tempDir.path,
          onLog: (line, isErr) => logs.add(line),
        );

        expect(result.success, true);
        expect(result.outputFiles.length, 1);
        final reportFile = File(result.outputFiles.first);
        expect(reportFile.existsSync(), true);

        final reportJson = jsonDecode(reportFile.readAsStringSync());
        expect(reportJson['moduleName'], contains('内置'));
        expect(reportJson['execution']['function'], 'fib');
        expect(reportJson['execution']['result'], [55]);
        expect(logs.any((l) => l.contains('执行成功！返回值: [55]')), true);
      } finally {
        tempDir.deleteSync(recursive: true);
      }
    });
  });
}
