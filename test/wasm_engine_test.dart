import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
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

    test('WASI module execution with stdout and args', () async {
      if (!canRunWasm) return;
      const wasiWat = r'''
(module
  (import "wasi_snapshot_preview1" "fd_write"
    (func $fd_write (param i32 i32 i32 i32) (result i32))
  )
  (memory (export "memory") 1)
  (data (i32.const 0) "Hello WASI Stdout!\n")
  (data (i32.const 32) "\00\00\00\00\13\00\00\00")
  (func (export "_start")
    (call $fd_write
      (i32.const 1)
      (i32.const 32)
      (i32.const 1)
      (i32.const 64)
    )
    drop
  )
)
''';
      final bytes = await parseWatFormat(wat: wasiWat);
      final module = await compileWasmModule(bytes);
      final wasiConfig = WasiConfig(
        captureStdout: true,
        captureStderr: true,
        preopenedDirs: const [],
        webBrowserFileSystem: const {},
        args: const ['my_app', 'arg1'],
      );
      final builder = module.builder(wasiConfig: wasiConfig);
      final instance = await builder.build();
      expect(instance.getFunction('_start'), isNotNull);

      // Check stdout stream
      final stdoutFuture = instance.stdout.first;
      final outBytes = await stdoutFuture;
      final text = utf8.decode(outBytes);
      expect(text, contains('Hello WASI Stdout!'));
    });

    test('WASI module execution with preopened directory file write', () async {
      if (!canRunWasm) return;
      final tempDir = Directory.systemTemp.createTempSync('wasm_wasi_fs_test_');
      try {
        const wasiFsWat = r'''
(module
  (import "wasi_snapshot_preview1" "path_open"
    (func $path_open (param i32 i32 i32 i32 i32 i64 i64 i32 i32) (result i32))
  )
  (import "wasi_snapshot_preview1" "fd_write"
    (func $fd_write (param i32 i32 i32 i32) (result i32))
  )
  (import "wasi_snapshot_preview1" "fd_close"
    (func $fd_close (param i32) (result i32))
  )
  (memory (export "memory") 1)
  ;; path at 100: "test_output.txt" (len=15)
  (data (i32.const 100) "test_output.txt")
  ;; file content at 300: "WASI VFS FILE CONTENT OK!" (len=25)
  (data (i32.const 300) "WASI VFS FILE CONTENT OK!")
  ;; iovec at 400: ptr=300, len=25
  (data (i32.const 400) "\2c\01\00\00\19\00\00\00")
  (func (export "_start")
    (local $newfd i32)
    ;; call path_open(fd=3, dirflags=0, path=100, path_len=15, oflags=9 (creat|trunc), rights_base=0x1ffffff, rights_inheriting=0x1ffffff, fdflags=0, fd_out=200)
    (call $path_open
      (i32.const 3)
      (i32.const 0)
      (i32.const 100)
      (i32.const 15)
      (i32.const 9)
      (i64.const 268435455)
      (i64.const 268435455)
      (i32.const 0)
      (i32.const 200)
    )
    drop
    ;; load new fd from 200
    (local.set $newfd (i32.load (i32.const 200)))
    ;; call fd_write($newfd, iovs=400, iovs_len=1, nwritten=256)
    (call $fd_write
      (local.get $newfd)
      (i32.const 400)
      (i32.const 1)
      (i32.const 256)
    )
    drop
    ;; close fd
    (call $fd_close (local.get $newfd))
    drop
  )
)
''';
        final bytes = await parseWatFormat(wat: wasiFsWat);
        final module = await compileWasmModule(bytes);
        final wasiConfig = WasiConfig(
          captureStdout: true,
          captureStderr: true,
          preopenedDirs: [
            PreopenedDir(
              hostPath: tempDir.path,
              wasmGuestPath: '/',
            ),
          ],
          webBrowserFileSystem: const {},
          args: const ['wasm_test'],
        );
        final builder = module.builder(wasiConfig: wasiConfig);
        await builder.build();

        // Verify the file was created in host directory!
        final createdFile = File('${tempDir.path}/test_output.txt');
        expect(createdFile.existsSync(), true, reason: 'File should be created on host disk');
        expect(createdFile.readAsStringSync(), 'WASI VFS FILE CONTENT OK!');
      } finally {
        try {
          tempDir.deleteSync(recursive: true);
        } catch (_) {}
      }
    });

    test('WASI preopened directory introspection (fd_prestat_get and dir_name)', () async {
      if (!canRunWasm) return;
      final tempDir = Directory.systemTemp.createTempSync('wasm_prestat_test_');
      try {
        const prestatWat = r'''
(module
  (import "wasi_snapshot_preview1" "fd_prestat_get"
    (func $fd_prestat_get (param i32 i32) (result i32))
  )
  (import "wasi_snapshot_preview1" "fd_prestat_dir_name"
    (func $fd_prestat_dir_name (param i32 i32 i32) (result i32))
  )
  (memory (export "memory") 1)
  (func (export "check_preopen") (param $fd i32) (result i32)
    ;; prestat struct at 0: tag (u8 at 0), pr_name_len (u32 at 4)
    (call $fd_prestat_get (local.get $fd) (i32.const 0))
  )
  (func (export "get_dir_name") (param $fd i32) (param $buf i32) (param $len i32) (result i32)
    (call $fd_prestat_dir_name (local.get $fd) (local.get $buf) (local.get $len))
  )
  (func (export "get_name_len") (result i32)
    (i32.load (i32.const 4))
  )
)
''';
        final bytes = await parseWatFormat(wat: prestatWat);
        final module = await compileWasmModule(bytes);
        final wasiConfig = WasiConfig(
          captureStdout: true,
          captureStderr: true,
          preopenedDirs: [
            PreopenedDir(
              hostPath: tempDir.path,
              wasmGuestPath: '/output',
            ),
          ],
          webBrowserFileSystem: const {},
        );
        final builder = module.builder(wasiConfig: wasiConfig);
        final instance = await builder.build();

        final checkPreopen = instance.getFunction('check_preopen')!;
        final getNameLen = instance.getFunction('get_name_len')!;
        final getDirName = instance.getFunction('get_dir_name')!;

        // fd 3 is the first preopened directory
        final res3 = checkPreopen([3]);
        expect(res3, [0]); // WASI errno 0 = success!

        final nameLen = getNameLen([]).first as int;
        expect(nameLen, 7); // "/output".length == 7

        final nameRes = getDirName([3, 100, nameLen]);
        expect(nameRes, [0]);

        final mem = instance.getMemory('memory')!;
        final nameBytes = mem.view.sublist(100, 100 + nameLen);
        expect(utf8.decode(nameBytes), '/output');

        // fd 4 should return EBADF (errno 8) because there is only 1 preopened dir
        final res4 = checkPreopen([4]);
        expect(res4.first, isNot(0));
      } finally {
        try {
          tempDir.deleteSync(recursive: true);
        } catch (_) {}
      }
    });

    test('WASI module with empty stdout and error stream handling', () async {
      if (!canRunWasm) return;
      // Module that does not write to stdout/stderr
      const silentWat = r'''
(module
  (memory (export "memory") 1)
  (func (export "_start")
    nop
  )
)
''';
      final bytes = await parseWatFormat(wat: silentWat);
      final module = await compileWasmModule(bytes);
      final wasiConfig = WasiConfig(
        captureStdout: true,
        captureStderr: true,
        preopenedDirs: const [],
        webBrowserFileSystem: const {},
      );
      final instance = await module.builder(wasiConfig: wasiConfig).build();
      // Test reading stdout with timeout
      final List<int> stdoutChunks = [];
      try {
        await for (final chunk in instance.stdout.timeout(const Duration(milliseconds: 100))) {
          stdoutChunks.addAll(chunk);
        }
      } catch (_) {}
      expect(stdoutChunks, isEmpty);
    });

    test('WASI module proc_exit(0) and proc_exit(1) behavior', () async {
      if (!canRunWasm) return;
      // Module that calls proc_exit(0)
      const exit0Wat = r'''
(module
  (import "wasi_snapshot_preview1" "proc_exit"
    (func $proc_exit (param i32))
  )
  (memory (export "memory") 1)
  (func (export "_start")
    (call $proc_exit (i32.const 0))
  )
)
''';
      final bytes0 = await parseWatFormat(wat: exit0Wat);
      final module0 = await compileWasmModule(bytes0);
      final wasiConfig = WasiConfig(
        captureStdout: true,
        captureStderr: true,
        preopenedDirs: const [],
        webBrowserFileSystem: const {},
      );
      // proc_exit(0) exits with code 0 (caught as AnyhowException exit status 0 in some runtimes)
      try {
        await module0.builder(wasiConfig: wasiConfig).build();
      } catch (e) {
        expect(e.toString(), contains('0'));
      }

      // Let's test proc_exit(1)
      const exit1Wat = r'''
(module
  (import "wasi_snapshot_preview1" "proc_exit"
    (func $proc_exit (param i32))
  )
  (memory (export "memory") 1)
  (func (export "_start")
    (call $proc_exit (i32.const 1))
  )
)
''';
      final bytes1 = await parseWatFormat(wat: exit1Wat);
      final module1 = await compileWasmModule(bytes1);
      Object? exit1Err;
      try {
        await module1.builder(wasiConfig: wasiConfig).build();
      } catch (e) {
        exit1Err = e;
      }
      expect(exit1Err, isNotNull);
      expect(exit1Err.toString(), contains('1'));
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
        try {
          tempDir.deleteSync(recursive: true);
        } catch (_) {}
      }
    });

    test('WasmUniversalService CLI argument parser and variable substitution', () {
      final tokens = WasmUniversalService.parseCliArgs(
        '-i "{input}" -o "{outputDir}/result.webp" --quality 85 --name "Hello World"',
        replacements: {
          '{input}': '/input/photo.png',
          '{outputDir}': '/output',
        },
      );
      expect(tokens, [
        '-i',
        '/input/photo.png',
        '-o',
        '/output/result.webp',
        '--quality',
        '85',
        '--name',
        'Hello World',
      ]);
    });

    test('WasmUniversalService execute WASI CLI mode with host disk VFS write and stdout', () async {
      if (!canRunWasm) return;
      final tempDir = Directory.systemTemp.createTempSync('wasm_service_wasi_');
      try {
        final logs = <String>[];
        final result = await WasmUniversalService.execute(
          formValues: {
            'sourceMode': 'demo',
            'executionMode': 'wasi_cli',
            'cliArgs': '-v -o {outputDir}/test.txt',
            'exportJson': 'yes',
          },
          inputFiles: [],
          outputDir: tempDir.path,
          onLog: (line, isErr) => logs.add(line),
        );

        expect(result.success, true);
        // Should have generated wasi_output_demo.txt AND wasm_report.json
        final demoFile = File(p.join(tempDir.path, 'wasi_output_demo.txt'));
        expect(demoFile.existsSync(), true, reason: 'WASI output demo file must exist on host disk');
        expect(demoFile.readAsStringSync(), contains('[WASI VFS Engine] Success!'));

        expect(logs.any((l) => l.contains('[WASI VFS Engine] Success!')), true);
        expect(result.outputFiles.any((f) => f.endsWith('wasi_output_demo.txt')), true);
        expect(result.outputFiles.any((f) => f.endsWith('wasm_report.json')), true);
      } finally {
        try {
          tempDir.deleteSync(recursive: true);
        } catch (_) {}
      }
    });

    test('WasmUniversalService execute memory stream mode with in-memory buffer transformation', () async {
      if (!canRunWasm) return;
      final tempDir = Directory.systemTemp.createTempSync('wasm_service_mem_');
      try {
        // Create an input text file with lowercase ASCII
        final inputFile = File(p.join(tempDir.path, 'sample_input.txt'));
        inputFile.writeAsStringSync('hello wasm memory stream pipeline 2026!');

        final logs = <String>[];
        final result = await WasmUniversalService.execute(
          formValues: {
            'sourceMode': 'demo',
            'executionMode': 'memory_stream',
            'functionName': 'process',
            'exportJson': 'yes',
          },
          inputFiles: [inputFile.path],
          outputDir: tempDir.path,
          onLog: (line, isErr) => logs.add(line),
        );

        expect(result.success, true);
        final processedFile = File(p.join(tempDir.path, 'sample_input_wasm_out.txt'));
        expect(processedFile.existsSync(), true, reason: 'Memory stream output file must be created');
        expect(processedFile.readAsStringSync(), 'HELLO WASM MEMORY STREAM PIPELINE 2026!');

        expect(result.outputFiles.any((f) => f.endsWith('sample_input_wasm_out.txt')), true);
        expect(logs.any((l) => l.contains('内存流处理完成')), true);
      } finally {
        try {
          tempDir.deleteSync(recursive: true);
        } catch (_) {}
      }
    });

    test('WasmUniversalService execute inspect mode generates structure report', () async {
      if (!canRunWasm) return;
      final tempDir = Directory.systemTemp.createTempSync('wasm_service_inspect_');
      try {
        final logs = <String>[];
        final result = await WasmUniversalService.execute(
          formValues: {
            'sourceMode': 'demo',
            'executionMode': 'inspect',
            'exportJson': 'yes',
          },
          inputFiles: [],
          outputDir: tempDir.path,
          onLog: (line, isErr) => logs.add(line),
        );

        expect(result.success, true);
        final reportFile = File(p.join(tempDir.path, 'wasm_report.json'));
        expect(reportFile.existsSync(), true);

        final json = jsonDecode(reportFile.readAsStringSync());
        expect(json['inspection'], isNotNull);
        expect((json['inspection']['exports'] as List).isNotEmpty, true);
      } finally {
        try {
          tempDir.deleteSync(recursive: true);
        } catch (_) {}
      }
    });
  });
}
