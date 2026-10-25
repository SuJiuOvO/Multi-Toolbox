import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter/services.dart' show BackgroundIsolateBinaryMessenger, RootIsolateToken;

import 'doc_converter_service.dart';
import 'tool_engine_service.dart';

/// 后台任务调度器：将 CPU 密集型的纯 Dart 处理放入独立 Isolate 执行，
/// 主线程 (UI 线程) 只负责渲染与接收进度，彻底避免“处理时界面卡死”。
///
/// 不适合放入 Isolate 的任务（保持在主线程，但本身是异步/原生执行，不会阻塞界面）：
/// - 依赖平台插件通道的音视频处理 (FFmpegKit / FFmpeg 进程)；
/// - 依赖 pdfrx 渲染器初始化的 PDF 转图片 / PDF 压缩 / PPT 渲染；
/// - 调起 Android 外部办公应用的任务。
class BackgroundTaskRunner {
  BackgroundTaskRunner._();

  static final Map<Isolate, Completer<ProcessingResult>> _active = {};

  /// 文档转换工具中可安全放入后台 Isolate 的子工具
  static const Set<String> _isolateSafeDocTools = {
    'images_to_pptx',
    'cad_to_pdf',
    'markdown_to_pdf',
    'txt_to_docx',
    'pdf_to_docx',
    'pdf_to_docx_android_light',
    'excel_to_pdf',
    'excel_to_pdf_android',
    'excel_to_pdf_android_light',
    'pptx_to_pdf',
    'docx_to_pdf',
  };

  /// 判断某个处理引擎动作是否应当放入后台 Isolate 执行
  static bool shouldUseIsolate(String handler, Map<String, dynamic> params) {
    switch (handler) {
      case 'image_compress':
      case 'image_resize':
      case 'id_photo_bg':
      case 'gemini_banana_watermark':
      case 'qr_toolbox':
      case 'archive_universal':
      case 'wasm_runner':
      case 'wasm_universal':
        return true;
      case 'gif_toolbox':
        return params['mode']?.toString() != 'video_to_gif';
      case 'livephoto_toolbox':
        return params['mode']?.toString() != 'video_to_live';
      case 'pdf_toolbox':
        final mode = params['mode']?.toString() ?? 'images_to_pdf';
        return mode != 'pdf_to_images' && mode != 'compress_pdf';
      case 'doc_converter':
        return _isolateSafeDocTools.contains(params['subTool']?.toString());
      default:
        return false;
    }
  }

  /// 统一执行入口：满足条件的任务自动转入后台 Isolate，否则回退主线程执行
  static Future<ProcessingResult> execute({
    required String handler,
    required List<String> inputFiles,
    required Map<String, dynamic> params,
    required String outputDir,
    void Function(double progress, String stage)? onProgress,
    void Function(String line, bool isError)? onLog,
  }) async {
    if (!shouldUseIsolate(handler, params)) {
      return ToolEngineService.execute(
        handler: handler,
        inputFiles: inputFiles,
        params: params,
        outputDir: outputDir,
        onProgress: onProgress,
        onLog: onLog,
      );
    }

    TransferableTypedData? fontData;
    if (handler == 'doc_converter') {
      try {
        final bytes = await DocConverterService.getChineseFontBytes();
        if (bytes != null) {
          fontData = TransferableTypedData.fromList([Uint8List.fromList(bytes)]);
        }
      } catch (_) {}
    }

    final receive = ReceivePort();
    final errorPort = ReceivePort();
    final exitPort = ReceivePort();
    final completer = Completer<ProcessingResult>();

    Isolate? isolate;
    try {
      isolate = await Isolate.spawn<_IsolateRequest>(
        _isolateMain,
        _IsolateRequest(
          port: receive.sendPort,
          handler: handler,
          inputFiles: List<String>.from(inputFiles),
          params: Map<String, dynamic>.from(params),
          outputDir: outputDir,
          token: RootIsolateToken.instance,
          fontData: fontData,
        ),
        onError: errorPort.sendPort,
        onExit: exitPort.sendPort,
        errorsAreFatal: true,
      );
    } catch (_) {
      // 参数无法跨 Isolate 传递等极端情况：回退到主线程执行
      receive.close();
      errorPort.close();
      exitPort.close();
      return ToolEngineService.execute(
        handler: handler,
        inputFiles: inputFiles,
        params: params,
        outputDir: outputDir,
        onProgress: onProgress,
        onLog: onLog,
      );
    }

    _active[isolate] = completer;

    receive.listen((dynamic msg) {
      if (msg is! List || msg.isEmpty) return;
      switch (msg[0]) {
        case 'p':
          onProgress?.call((msg[1] as num).toDouble(), msg[2] as String);
          break;
        case 'l':
          onLog?.call(msg[1] as String, msg[2] as bool);
          break;
        case 'r':
          if (!completer.isCompleted) {
            completer.complete(ProcessingResult(
              success: msg[1] as bool,
              message: msg[2] as String,
              outputFiles: List<String>.from(msg[3] as List),
            ));
          }
          break;
      }
    });
    errorPort.listen((dynamic err) {
      if (!completer.isCompleted) {
        final text = err is List && err.isNotEmpty ? err.first.toString() : err.toString();
        completer.complete(ProcessingResult(success: false, message: '后台处理发生异常: $text'));
      }
    });
    exitPort.listen((dynamic _) {
      if (!completer.isCompleted) {
        completer.complete(ProcessingResult(success: false, message: '后台处理进程已退出'));
      }
    });

    try {
      return await completer.future;
    } finally {
      _active.remove(isolate);
      receive.close();
      errorPort.close();
      exitPort.close();
      isolate.kill(priority: Isolate.immediate);
    }
  }

  /// 取消所有正在后台 Isolate 中执行的任务
  static void cancelActive() {
    final entries = _active.entries.toList();
    for (final e in entries) {
      e.key.kill(priority: Isolate.immediate);
      if (!e.value.isCompleted) {
        e.value.complete(ProcessingResult(success: false, message: '任务已取消'));
      }
    }
  }

  /// 当前是否有后台 Isolate 任务在运行
  static bool get hasActiveTask => _active.isNotEmpty;
}

class _IsolateRequest {
  final SendPort port;
  final String handler;
  final List<String> inputFiles;
  final Map<String, dynamic> params;
  final String outputDir;
  final RootIsolateToken? token;
  final TransferableTypedData? fontData;

  _IsolateRequest({
    required this.port,
    required this.handler,
    required this.inputFiles,
    required this.params,
    required this.outputDir,
    required this.token,
    required this.fontData,
  });
}

@pragma('vm:entry-point')
Future<void> _isolateMain(_IsolateRequest req) async {
  if (req.token != null) {
    try {
      BackgroundIsolateBinaryMessenger.ensureInitialized(req.token!);
    } catch (_) {}
  }
  if (req.fontData != null) {
    try {
      DocConverterService.seedChineseFontBytes(req.fontData!.materialize().asUint8List());
    } catch (_) {}
  }

  var lastSent = DateTime.fromMillisecondsSinceEpoch(0);
  try {
    final result = await ToolEngineService.execute(
      handler: req.handler,
      inputFiles: req.inputFiles,
      params: req.params,
      outputDir: req.outputDir,
      onProgress: (p, s) {
        final now = DateTime.now();
        if (p >= 1.0 || now.difference(lastSent).inMilliseconds >= 120) {
          lastSent = now;
          req.port.send(['p', p, s]);
        }
      },
      onLog: (line, isError) => req.port.send(['l', line, isError]),
    );
    req.port.send(['r', result.success, result.message, result.outputFiles]);
  } catch (e, st) {
    req.port.send(['r', false, '处理发生异常: $e\n$st', <String>[]]);
  }
}
