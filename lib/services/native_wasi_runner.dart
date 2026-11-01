// wasm_run 0.2.0+2 starts WASI before its asynchronous stdio registrations
// finish. Keep this adapter on that pinned bridge API until upstream exposes
// an awaitable registration and explicit entrypoint execution.
// ignore_for_file: implementation_imports, invalid_use_of_internal_member, invalid_use_of_protected_member

import 'dart:async';
import 'dart:convert';

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:wasm_run/src/rust/api.dart' as native;
import 'package:wasm_run/src/rust/config.dart' show StdIOKind;
import 'package:wasm_run/src/rust/frb_generated.dart';
import 'package:wasm_run/src/rust/types.dart' show ExternalValue_Func;
import 'package:wasm_run/wasm_run.dart' show ModuleConfig, WasiConfig;

/// Captures WASI output through native EOF, including output before a trap or
/// proc_exit. No WASI code runs until both native sinks are registered.
Future<({String stdout, String stderr, Object? error})> runNativeWasiCli({
  required Uint8List bytes,
  required WasiConfig config,
}) async {
  final compiled = await native.compileWasm(
    moduleWasm: bytes,
    config: const ModuleConfig(),
  );
  final module = native.moduleBuilder(module: compiled, wasiConfig: config);
  final stdout = _WasiOutputCapture();
  final stderr = _WasiOutputCapture();
  Object? error;
  try {
    await Future.wait([
      stdout.connect(module, StdIOKind.stdout),
      stderr.connect(module, StdIOKind.stderr),
    ]);
    final instance = await module.instantiate();
    final exports = instance.exports();
    for (final name in ['_start', '_initialize']) {
      final entrypoints = exports.where((export) => export.desc.name == name);
      if (entrypoints.isEmpty) continue;
      final function = entrypoints.first.value;
      if (function is ExternalValue_Func &&
          module.getFunctionType(func: function.field0).parameters.isEmpty) {
        await module.callFunctionHandle(func: function.field0, args: const []);
        break;
      }
    }
  } catch (e) {
    error = e;
  } finally {
    // Dropping the native store closes both sinks after their queued writes,
    // and releases preopened directory handles on Windows.
    try {
      await module.dispose();
    } catch (e) {
      error ??= e;
      await Future.wait([stdout.cancel(), stderr.cancel()]);
    }
  }
  await Future.wait([stdout.closed.future, stderr.closed.future]);
  return (
    stdout: stdout.text,
    stderr: stderr.text,
    error: error ?? stdout.error ?? stderr.error,
  );
}

class _WasiOutputCapture {
  final _sink = RustStreamSink<Uint8List>();
  final _bytes = BytesBuilder();
  final closed = Completer<void>();
  late final StreamSubscription<Uint8List> _subscription;
  Object? error;

  _WasiOutputCapture() {
    final api = RustLib.instance.api as RustLibApiImpl;
    _sink.setupAndSerialize(
      codec: DcoCodec(
        decodeSuccessData: api.dco_decode_list_prim_u_8_strict,
        decodeErrorData: api.dco_decode_AnyhowException,
      ),
    );
    _subscription = _sink.stream.listen(
      _bytes.add,
      onError: (Object e) => error ??= e,
      onDone: () => closed.complete(),
    );
  }

  String get text => utf8.decode(_bytes.takeBytes(), allowMalformed: true);

  Future<void> connect(native.WasmRunModuleId module, StdIOKind kind) async {
    try {
      final api = RustLib.instance.api as RustLibApiImpl;
      // Same generated call as stdioStream(), retaining its completion future
      // instead of discarding it with unawaited(). No native ABI changes.
      await api.handler.executeNormal(
        NormalTask(
          callFfi: (port) =>
              api.wire.wire__crate__api__wasm_run_module_id_stdio_stream(
            port,
            api.cst_encode_box_autoadd_wasm_run_module_id(module),
            api.cst_encode_StreamSink_list_prim_u_8_strict_Dco(_sink),
            api.cst_encode_std_io_kind(kind),
          ),
          codec: DcoCodec(
            decodeSuccessData: api.dco_decode_unit,
            decodeErrorData: api.dco_decode_AnyhowException,
          ),
          constMeta: api.kCrateApiWasmRunModuleIdStdioStreamConstMeta,
          argValues: [module, _sink, kind],
          apiImpl: api,
        ),
      );
    } catch (_) {
      await cancel();
      rethrow;
    }
  }

  Future<void> cancel() async {
    await _subscription.cancel();
    if (!closed.isCompleted) closed.complete();
  }
}
