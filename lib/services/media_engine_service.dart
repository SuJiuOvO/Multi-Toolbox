import 'dart:async';
import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:io';
import 'dart:math' as math;

import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/ffprobe_kit.dart';
import 'package:ffmpeg_kit_flutter_new/return_code.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:path/path.dart' as p;

import 'tool_engine_service.dart' show ProcessingResult;

/// 可用的 GPU / 系统级硬件视频编码器
enum HwEncoderKind { nvenc, qsv, amf, mediaCodec }

class HwEncoder {
  final HwEncoderKind kind;
  final String codec;
  final String label;
  const HwEncoder(this.kind, this.codec, this.label);
}

/// 媒体文件探测结果
class MediaProbe {
  final double? durationSec;
  final int? bitrateBps;
  final int? width;
  final int? height;
  final double? fps;
  final String? videoCodec;

  const MediaProbe({
    this.durationSec,
    this.bitrateBps,
    this.width,
    this.height,
    this.fps,
    this.videoCodec,
  });

  static const empty = MediaProbe();
}

class _ExecResult {
  final bool ok;
  final int code;
  final String tail;
  final bool cancelled;
  const _ExecResult({
    required this.ok,
    required this.code,
    required this.tail,
    this.cancelled = false,
  });
}

class _Attempt {
  final String label;
  final List<String> args;
  final String outPath;
  const _Attempt(this.label, this.args, this.outPath);
}

class _Quality {
  final String name;
  final int crf;
  final String swPreset;
  final int nvCq;
  final int qsvQuality;
  final int amfQp;
  final double bitrateFactor;
  final int audioKbps;
  const _Quality(
    this.name,
    this.crf,
    this.swPreset,
    this.nvCq,
    this.qsvQuality,
    this.amfQp,
    this.bitrateFactor,
    this.audioKbps,
  );
}

/// 音视频处理引擎 (Android 内置 FFmpegKit / Windows 系统 FFmpeg 进程)
///
/// 相比旧版纯 libx264 软编管线，主要改进：
/// 1. **GPU / 系统硬件编码优先**：Windows 依次探测 NVENC → QSV → AMF；Android 探测 MediaCodec。
///    探测通过一次极小的真实试编码验证，失败自动回退到 CPU 软件编码，无需用户干预。
/// 2. **真实进度条 + 速度 + 预计剩余时间**：基于 FFmpeg `-progress` / 统计回调与媒体总时长计算。
/// 3. **限制软编线程数 + Windows 降低进程优先级**，避免占满 CPU 导致系统/界面卡顿。
/// 4. **可取消**：离开页面或取消任务时终止底层进程。
class MediaEngineService {
  MediaEngineService._();

  // ---------------------------------------------------------------------
  // 状态
  // ---------------------------------------------------------------------
  static bool _cancelRequested = false;
  static Process? _activeProcess;
  static int? _activeSessionId;

  static String? _cachedFfmpegPath;
  static bool _hwProbed = false;
  static HwEncoder? _hwCache;

  static const _winHwCandidates = <HwEncoder>[
    HwEncoder(HwEncoderKind.nvenc, 'h264_nvenc', 'NVIDIA NVENC 显卡硬件编码'),
    HwEncoder(HwEncoderKind.qsv, 'h264_qsv', 'Intel QuickSync 核显硬件编码'),
    HwEncoder(HwEncoderKind.amf, 'h264_amf', 'AMD AMF 显卡硬件编码'),
  ];

  static const _qExtreme = _Quality('extreme', 28, 'veryfast', 32, 30, 32, 0.30, 96);
  static const _qNormal = _Quality('normal', 26, 'veryfast', 28, 26, 28, 0.55, 128);
  static const _qHigh = _Quality('high', 22, 'fast', 23, 22, 23, 0.85, 192);
  static const _qConvert = _Quality('convert', 23, 'fast', 26, 23, 25, 0.75, 160);

  /// 当前是否存在正在执行的 FFmpeg 任务
  static bool get hasActiveJob => _activeProcess != null || _activeSessionId != null;

  /// 取消正在执行的音视频任务 (页面销毁 / 用户取消时调用)
  static Future<void> cancelActive() async {
    if (!hasActiveJob) return;
    _cancelRequested = true;
    try {
      _activeProcess?.kill();
    } catch (_) {}
    final sid = _activeSessionId;
    if (sid != null) {
      try {
        await FFmpegKit.cancel(sid);
      } catch (_) {}
    }
  }

  // ---------------------------------------------------------------------
  // 工具函数
  // ---------------------------------------------------------------------

  /// 将时长格式化为 "1分05秒" / "12秒" / "1时02分"
  static String formatDuration(Duration d) {
    final s = d.inSeconds;
    if (s < 60) return '$s秒';
    if (s < 3600) return '${s ~/ 60}分${(s % 60).toString().padLeft(2, '0')}秒';
    return '${s ~/ 3600}时${((s % 3600) ~/ 60).toString().padLeft(2, '0')}分';
  }

  /// 软件编码使用的线程数：保留部分核心给系统与界面，避免全核满载卡顿
  static int softwareThreads() {
    final cores = math.max(1, Platform.numberOfProcessors);
    if (Platform.isAndroid) return math.max(2, cores ~/ 2);
    return math.max(2, (cores * 0.6).floor());
  }

  static double? _parseFraction(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    if (raw.contains('/')) {
      final parts = raw.split('/');
      final a = double.tryParse(parts[0]);
      final b = double.tryParse(parts[1]);
      if (a == null || b == null || b == 0) return null;
      return a / b;
    }
    return double.tryParse(raw);
  }

  static double? _parseClock(String h, String m, String s) {
    final hh = int.tryParse(h);
    final mm = int.tryParse(m);
    final ss = double.tryParse(s);
    if (hh == null || mm == null || ss == null) return null;
    return hh * 3600 + mm * 60 + ss;
  }

  /// 从 ffmpeg 横幅输出中解析媒体信息 (Windows 与单元测试共用)
  static MediaProbe parseBannerInfo(String text) {
    double? duration;
    int? bitrate;
    int? width;
    int? height;
    double? fps;
    String? vcodec;

    final dm = RegExp(r'Duration:\s*(\d+):(\d+):(\d+(?:\.\d+)?)').firstMatch(text);
    if (dm != null) duration = _parseClock(dm.group(1)!, dm.group(2)!, dm.group(3)!);
    final bm = RegExp(r'bitrate:\s*(\d+)\s*kb/s').firstMatch(text);
    if (bm != null) bitrate = (int.tryParse(bm.group(1)!) ?? 0) * 1000;

    for (final line in text.split('\n')) {
      if (!line.contains('Video:')) continue;
      final cm = RegExp(r'Video:\s*([A-Za-z0-9_]+)').firstMatch(line);
      vcodec = cm?.group(1);
      final rm = RegExp(r',\s*(\d{2,5})x(\d{2,5})').firstMatch(line);
      if (rm != null) {
        width = int.tryParse(rm.group(1)!);
        height = int.tryParse(rm.group(2)!);
      }
      final fm = RegExp(r'(\d+(?:\.\d+)?)\s*fps').firstMatch(line);
      if (fm != null) fps = double.tryParse(fm.group(1)!);
      break;
    }
    return MediaProbe(
      durationSec: duration,
      bitrateBps: bitrate,
      width: width,
      height: height,
      fps: fps,
      videoCodec: vcodec,
    );
  }

  // ---------------------------------------------------------------------
  // FFmpeg 定位 (Windows)
  // ---------------------------------------------------------------------
  static Future<String?> findWindowsFfmpeg() async {
    if (_cachedFfmpegPath != null && (File(_cachedFfmpegPath!).existsSync() || _cachedFfmpegPath == 'ffmpeg')) {
      return _cachedFfmpegPath;
    }

    final exeDir = p.dirname(Platform.resolvedExecutable);
    final candidates = <String>[
      p.join(exeDir, 'ffmpeg.exe'),
      p.join(exeDir, 'bin', 'ffmpeg.exe'),
      'ffmpeg',
    ];
    final home = Platform.environment['USERPROFILE'] ?? '';
    if (home.isNotEmpty) {
      candidates.add(p.join(home, r'AppData\Local\Microsoft\WinGet\Links\ffmpeg.exe'));
      final pkgDir = Directory(p.join(home, r'AppData\Local\Microsoft\WinGet\Packages'));
      if (pkgDir.existsSync()) {
        try {
          await for (final sub in pkgDir.list(followLinks: false)) {
            if (sub is Directory && sub.path.toLowerCase().contains('ffmpeg')) {
              try {
                await for (final f in sub.list(recursive: true, followLinks: false)) {
                  if (f is File && p.basename(f.path).toLowerCase() == 'ffmpeg.exe') {
                    candidates.add(f.path);
                    break;
                  }
                }
              } catch (_) {}
            }
          }
        } catch (_) {}
      }
    }

    for (final cand in candidates) {
      try {
        final res = await Process.run(cand, ['-version']);
        if (res.exitCode == 0) {
          _cachedFfmpegPath = cand;
          return cand;
        }
      } catch (_) {}
    }
    return null;
  }

  static const String ffmpegMissingMessage =
      '未在系统路径或程序目录中找到有效 FFmpeg。\n若下载的是极简便携包，可在 Windows PowerShell 中运行:\nwinget install Gyan.FFmpeg.Essentials\n安装后重启软件；或直接下载自带 FFmpeg 的完整便携包。';

  // ---------------------------------------------------------------------
  // 硬件编码器探测
  // ---------------------------------------------------------------------

  /// 探测当前设备可用的硬件视频编码器 (结果缓存，每次启动仅探测一次)
  static Future<HwEncoder?> detectHardwareEncoder() async {
    if (_hwProbed) return _hwCache;
    _hwProbed = true;
    try {
      if (Platform.isAndroid) {
        final ok = await _testEncodeAndroid(const [
          '-f', 'lavfi', '-i', 'color=c=black:s=640x360:r=30:d=0.4',
          '-c:v', 'h264_mediacodec', '-b:v', '1M', '-f', 'null', '-',
        ]);
        if (ok) {
          _hwCache = const HwEncoder(HwEncoderKind.mediaCodec, 'h264_mediacodec', '手机 GPU/专用芯片硬件编码 (MediaCodec)');
        }
      } else if (Platform.isWindows) {
        final ff = await findWindowsFfmpeg();
        if (ff != null) {
          final listed = (await Process.run(ff, ['-hide_banner', '-encoders'])).stdout.toString();
          for (final cand in _winHwCandidates) {
            if (!listed.contains(cand.codec)) continue;
            final pix = cand.kind == HwEncoderKind.qsv ? 'nv12' : 'yuv420p';
            try {
              final res = await Process.run(ff, [
                '-hide_banner', '-loglevel', 'error', '-nostdin',
                '-f', 'lavfi', '-i', 'color=c=black:s=640x360:r=30:d=0.4',
                '-c:v', cand.codec, '-pix_fmt', pix, '-f', 'null', '-',
              ]).timeout(const Duration(seconds: 20));
              if (res.exitCode == 0) {
                _hwCache = cand;
                break;
              }
            } catch (_) {}
          }
        }
      }
    } catch (e) {
      debugPrint('硬件编码器探测失败: $e');
    }
    return _hwCache;
  }

  static Future<bool> _testEncodeAndroid(List<String> args) async {
    try {
      final s = await FFmpegKit.executeWithArguments(['-hide_banner', '-loglevel', 'error', ...args]);
      return ReturnCode.isSuccess(await s.getReturnCode());
    } catch (_) {
      return false;
    }
  }

  // ---------------------------------------------------------------------
  // 媒体探测
  // ---------------------------------------------------------------------
  static Future<MediaProbe> probe(String path) async {
    try {
      if (Platform.isAndroid) {
        final session = await FFprobeKit.getMediaInformation(path);
        final info = session.getMediaInformation();
        if (info == null) return MediaProbe.empty;
        double? fps;
        int? w;
        int? h;
        String? codec;
        for (final st in info.getStreams()) {
          if (st.getType() == 'video') {
            w = st.getWidth();
            h = st.getHeight();
            codec = st.getCodec();
            fps = _parseFraction(st.getAverageFrameRate());
            break;
          }
        }
        return MediaProbe(
          durationSec: double.tryParse(info.getDuration() ?? ''),
          bitrateBps: int.tryParse(info.getBitrate() ?? ''),
          width: w,
          height: h,
          fps: fps,
          videoCodec: codec,
        );
      }
      final ff = await findWindowsFfmpeg();
      if (ff == null) return MediaProbe.empty;
      final res = await Process.run(
        ff,
        ['-hide_banner', '-nostdin', '-i', path],
        stderrEncoding: const Utf8Codec(allowMalformed: true),
      ).timeout(const Duration(seconds: 20));
      return parseBannerInfo(res.stderr.toString());
    } catch (_) {
      return MediaProbe.empty;
    }
  }

  // ---------------------------------------------------------------------
  // 底层执行
  // ---------------------------------------------------------------------
  static void _lowerPriorityWindows(int pid) {
    if (!Platform.isWindows) return;
    try {
      final k32 = ffi.DynamicLibrary.open('kernel32.dll');
      final openProcess = k32.lookupFunction<
          ffi.IntPtr Function(ffi.Uint32, ffi.Int32, ffi.Uint32),
          int Function(int, int, int)>('OpenProcess');
      final setPriorityClass = k32.lookupFunction<
          ffi.Int32 Function(ffi.IntPtr, ffi.Uint32),
          int Function(int, int)>('SetPriorityClass');
      final closeHandle = k32.lookupFunction<ffi.Int32 Function(ffi.IntPtr), int Function(int)>('CloseHandle');
      const processSetInformation = 0x0200;
      const belowNormalPriorityClass = 0x00004000;
      final h = openProcess(processSetInformation, 0, pid);
      if (h != 0) {
        setPriorityClass(h, belowNormalPriorityClass);
        closeHandle(h);
      }
    } catch (_) {}
  }

  static String _trimTail(String s) => s.length > 8000 ? s.substring(s.length - 6000) : s;

  /// 执行一次 FFmpeg 命令；[onTick] 回调 (进度 0..1 或 null, 倍速)
  static Future<_ExecResult> _exec(
    List<String> args, {
    double? durationSec,
    void Function(double? fraction, double? speed)? onTick,
  }) async {
    _cancelRequested = false;
    var lastTick = DateTime.fromMillisecondsSinceEpoch(0);
    void tick(double? frac, double? speed) {
      final now = DateTime.now();
      if (now.difference(lastTick).inMilliseconds < 250) return;
      lastTick = now;
      onTick?.call(frac, speed);
    }

    if (Platform.isAndroid) {
      final completer = Completer<ReturnCode?>();
      final logBuf = StringBuffer();
      try {
        final session = await FFmpegKit.executeWithArgumentsAsync(
          ['-hide_banner', '-nostdin', ...args],
          (s) async {
            if (!completer.isCompleted) completer.complete(await s.getReturnCode());
          },
          (log) {
            logBuf.writeln(log.getMessage());
            if (logBuf.length > 12000) {
              final t = _trimTail(logBuf.toString());
              logBuf
                ..clear()
                ..write(t);
            }
          },
          (stats) {
            final ms = stats.getTime();
            final frac = (durationSec != null && durationSec > 0 && ms > 0)
                ? (ms / 1000.0 / durationSec).clamp(0.0, 0.999)
                : null;
            final sp = stats.getSpeed();
            tick(frac, sp > 0 ? sp : null);
          },
        );
        _activeSessionId = session.getSessionId();
        final rc = await completer.future;
        final cancelled = _cancelRequested || ReturnCode.isCancel(rc);
        return _ExecResult(
          ok: ReturnCode.isSuccess(rc),
          code: rc?.getValue() ?? -1,
          tail: logBuf.toString(),
          cancelled: cancelled,
        );
      } finally {
        _activeSessionId = null;
      }
    }

    // Windows
    final ff = await findWindowsFfmpeg();
    if (ff == null) {
      return const _ExecResult(ok: false, code: -1, tail: ffmpegMissingMessage);
    }
    final proc = await Process.start(ff, ['-hide_banner', '-nostdin', '-progress', 'pipe:1', '-nostats', ...args]);
    _activeProcess = proc;
    _lowerPriorityWindows(proc.pid);

    double? dur = durationSec;
    final tail = StringBuffer();
    double? lastSpeed;

    final errSub = proc.stderr.transform(const Utf8Decoder(allowMalformed: true)).listen((chunk) {
      tail.write(chunk);
      if (tail.length > 12000) {
        final t = _trimTail(tail.toString());
        tail
          ..clear()
          ..write(t);
      }
      if (dur == null) {
        final m = RegExp(r'Duration:\s*(\d+):(\d+):(\d+(?:\.\d+)?)').firstMatch(chunk);
        if (m != null) dur = _parseClock(m.group(1)!, m.group(2)!, m.group(3)!);
      }
    });
    final outSub = proc.stdout
        .transform(const Utf8Decoder(allowMalformed: true))
        .transform(const LineSplitter())
        .listen((line) {
      if (line.startsWith('speed=')) {
        lastSpeed = double.tryParse(line.substring(6).replaceAll('x', '').trim());
      } else if (line.startsWith('out_time_us=') || line.startsWith('out_time_ms=')) {
        final us = int.tryParse(line.substring(line.indexOf('=') + 1).trim());
        if (us != null && us > 0) {
          final d = dur;
          final frac = (d != null && d > 0) ? (us / 1e6 / d).clamp(0.0, 0.999) : null;
          tick(frac, lastSpeed);
        }
      }
    });

    final code = await proc.exitCode;
    await Future.wait([errSub.asFuture<void>(), outSub.asFuture<void>()]).catchError((_) => <void>[]);
    final cancelled = _cancelRequested;
    _activeProcess = null;
    return _ExecResult(ok: code == 0, code: code, tail: tail.toString(), cancelled: cancelled);
  }

  static String _errorSummary(String tail) {
    final lines = tail
        .split('\n')
        .map((l) => l.trim())
        .where((l) {
          final low = l.toLowerCase();
          return low.contains('error') ||
              low.contains('invalid') ||
              low.contains('failed') ||
              low.contains('no such file') ||
              low.contains('unknown encoder') ||
              low.contains('not found');
        })
        .toList();
    final picked = lines.isNotEmpty ? lines.reversed.take(5).toList().reversed : tail.trim().split('\n').reversed.take(5).toList().reversed;
    return picked.join('\n');
  }

  static String _sizeText(int bytes) {
    if (bytes >= 1024 * 1024) return '${(bytes / 1024 / 1024).toStringAsFixed(2)} MB';
    return '${(bytes / 1024).toStringAsFixed(1)} KB';
  }

  // ---------------------------------------------------------------------
  // 通用命令执行 (GIF / 实况照片等使用)
  // ---------------------------------------------------------------------
  static String? _firstInput(List<String> args) {
    final i = args.indexOf('-i');
    return (i >= 0 && i + 1 < args.length) ? args[i + 1] : null;
  }

  static Future<ProcessingResult> runCommand({
    required List<String> args,
    required String outPath,
    required String successTitle,
    void Function(double, String)? onProgress,
  }) async {
    final sw = Stopwatch()..start();
    onProgress?.call(0.05, '正在启动 FFmpeg 处理管道...');

    double? duration;
    final input = _firstInput(args);
    if (Platform.isAndroid && input != null && File(input).existsSync()) {
      duration = (await probe(input)).durationSec;
    }

    final res = await _exec(
      args,
      durationSec: duration,
      onTick: (frac, speed) {
        if (frac == null) {
          onProgress?.call(0.3, '处理中 · 已运行 ${formatDuration(sw.elapsed)}');
          return;
        }
        final remain = frac > 0.02 ? Duration(milliseconds: (sw.elapsedMilliseconds * (1 - frac) / frac).round()) : null;
        onProgress?.call(
          0.05 + 0.93 * frac,
          '处理中 ${(frac * 100).toStringAsFixed(1)}%${speed != null ? ' · ${speed.toStringAsFixed(1)}x' : ''}${remain != null ? ' · 剩余约 ${formatDuration(remain)}' : ''}',
        );
      },
    );
    sw.stop();

    if (res.cancelled) {
      return ProcessingResult(success: false, message: '任务已取消');
    }
    if (res.ok && File(outPath).existsSync()) {
      final outSize = File(outPath).lengthSync();
      onProgress?.call(1.0, '$successTitle！总耗时 ${formatDuration(sw.elapsed)}');
      return ProcessingResult(
        success: true,
        message: '$successTitle (耗时 ${formatDuration(sw.elapsed)})！\n输出文件: ${p.basename(outPath)}\n最终大小: ${_sizeText(outSize)}',
        outputFiles: [outPath],
      );
    }
    if (res.tail == ffmpegMissingMessage) {
      return ProcessingResult(success: false, message: ffmpegMissingMessage);
    }
    return ProcessingResult(
      success: false,
      message: 'FFmpeg 处理失败 (返回码: ${res.code})\n${_errorSummary(res.tail)}',
    );
  }

  // ---------------------------------------------------------------------
  // 视频 / 音频综合处理
  // ---------------------------------------------------------------------
  static int _targetBitrate(MediaProbe pr, _Quality q) {
    int base;
    if (pr.bitrateBps != null && pr.bitrateBps! > 0) {
      base = pr.bitrateBps!;
    } else {
      final px = (pr.width ?? 1920) * (pr.height ?? 1080);
      final fps = (pr.fps ?? 30).clamp(1, 120).toDouble();
      base = (px * fps * 0.1).round();
    }
    var v = (base * q.bitrateFactor).round().clamp(600000, 20000000).toInt();
    if (q.name == 'extreme') v = math.min(v, 2500000);
    return v;
  }

  /// 构造视频编码参数 (对外公开以便单元测试)
  static List<String> buildVideoCodecArgs({
    required HwEncoder? hw,
    required String qualityName,
    required MediaProbe probe,
    required int threads,
  }) {
    final q = _qualityByName(qualityName);
    if (hw == null) {
      return [
        '-c:v', 'libx264',
        '-preset', q.swPreset,
        '-crf', '${q.crf}',
        '-pix_fmt', 'yuv420p',
        '-threads', '$threads',
      ];
    }
    switch (hw.kind) {
      case HwEncoderKind.nvenc:
        return [
          '-c:v', 'h264_nvenc',
          '-preset', 'p4',
          '-rc', 'vbr',
          '-cq', '${q.nvCq}',
          '-b:v', '0',
          '-profile:v', 'high',
          '-pix_fmt', 'yuv420p',
        ];
      case HwEncoderKind.qsv:
        return [
          '-c:v', 'h264_qsv',
          '-preset', 'medium',
          '-global_quality', '${q.qsvQuality}',
          '-pix_fmt', 'nv12',
        ];
      case HwEncoderKind.amf:
        return [
          '-c:v', 'h264_amf',
          '-quality', 'balanced',
          '-rc', 'cqp',
          '-qp_i', '${q.amfQp}',
          '-qp_p', '${q.amfQp + 2}',
          '-pix_fmt', 'yuv420p',
        ];
      case HwEncoderKind.mediaCodec:
        return [
          '-c:v', 'h264_mediacodec',
          '-b:v', '${_targetBitrate(probe, q)}',
        ];
    }
  }

  static _Quality _qualityByName(String name) {
    switch (name) {
      case 'extreme':
        return _qExtreme;
      case 'high':
      case 'high_quality':
        return _qHigh;
      case 'convert':
        return _qConvert;
      default:
        return _qNormal;
    }
  }

  static List<_Attempt> _videoAttempts({
    required String input,
    required String outPath,
    required String qualityName,
    required MediaProbe probe,
    required HwEncoder? hw,
    String? videoFilter,
  }) {
    final q = _qualityByName(qualityName);
    final threads = softwareThreads();

    List<String> compose(HwEncoder? enc) {
      final useHwDecode = enc != null && Platform.isWindows;
      return [
        '-y',
        if (useHwDecode) ...['-hwaccel', 'auto'],
        '-i', input,
        if (videoFilter != null) ...['-vf', videoFilter],
        ...buildVideoCodecArgs(hw: enc, qualityName: qualityName, probe: probe, threads: threads),
        '-c:a', 'aac',
        '-b:a', '${q.audioKbps}k',
        '-movflags', '+faststart',
        outPath,
      ];
    }

    return [
      if (hw != null) _Attempt(hw.label, compose(hw), outPath),
      _Attempt('CPU 软件编码', compose(null), outPath),
    ];
  }

  /// 音视频综合处理入口
  static Future<ProcessingResult> processMedia({
    required String inputPath,
    required Map<String, dynamic> params,
    required String outputDir,
    void Function(double, String)? onProgress,
  }) async {
    final op = (params['op'] ?? params['operation'])?.toString() ?? 'compress_video';
    final preset = params['preset']?.toString() ?? 'normal';
    final hwPref = params['hwAccel']?.toString() ?? 'auto';

    if (!File(inputPath).existsSync()) {
      return ProcessingResult(success: false, message: '输入文件不存在: $inputPath');
    }

    onProgress?.call(0.02, '正在分析媒体文件...');
    final probeInfo = await probe(inputPath);
    final base = p.basenameWithoutExtension(inputPath);
    final attempts = <_Attempt>[];

    final isVideoOp = op == 'compress_video' || op == 'to_mp4' || op == 'reverse_video';
    HwEncoder? hw;
    if (isVideoOp && op != 'reverse_video' && hwPref != 'off') {
      onProgress?.call(0.03, '正在检测硬件加速能力...');
      hw = await detectHardwareEncoder();
    }

    switch (op) {
      case 'extract_audio':
      case 'extract_audio_copy':
        {
          final aac = p.join(outputDir, 'extracted_$base.aac');
          final mp3 = p.join(outputDir, 'extracted_$base.mp3');
          attempts.add(_Attempt('无损直拷音轨', ['-y', '-i', inputPath, '-vn', '-c:a', 'copy', aac], aac));
          attempts.add(_Attempt('转码为 MP3', ['-y', '-i', inputPath, '-vn', '-c:a', 'libmp3lame', '-q:a', '2', mp3], mp3));
        }
        break;
      case 'extract_audio_mp3':
        {
          final mp3 = p.join(outputDir, 'extracted_$base.mp3');
          attempts.add(_Attempt('提取为 MP3', ['-y', '-i', inputPath, '-vn', '-c:a', 'libmp3lame', '-q:a', '2', mp3], mp3));
        }
        break;
      case 'compress_video':
        {
          final out = p.join(outputDir, 'compressed_$base.mp4');
          final q = preset == 'extreme' ? 'extreme' : (preset == 'high_quality' ? 'high' : 'normal');
          attempts.addAll(_videoAttempts(
            input: inputPath,
            outPath: out,
            qualityName: q,
            probe: probeInfo,
            hw: hw,
            videoFilter: preset == 'extreme' ? "scale=-2:'min(720,ih)',fps=30" : null,
          ));
        }
        break;
      case 'to_mp4':
        {
          final out = p.join(outputDir, 'converted_$base.mp4');
          attempts.addAll(_videoAttempts(
            input: inputPath,
            outPath: out,
            qualityName: 'convert',
            probe: probeInfo,
            hw: hw,
          ));
        }
        break;
      case 'reverse_video':
        {
          final d = probeInfo.durationSec;
          if (d != null && d > 150) {
            return ProcessingResult(
              success: false,
              message: '视频倒放需要将整段画面载入内存，当前视频时长 ${formatDuration(Duration(seconds: d.round()))}，'
                  '为避免内存溢出闪退，仅支持 2 分钟以内的视频倒放。请先截取片段后再试。',
            );
          }
          final out = p.join(outputDir, 'reversed_$base.mp4');
          attempts.add(_Attempt('视频倒放', [
            '-y', '-i', inputPath,
            '-vf', "scale=-2:'min(720,ih)',fps=30,reverse",
            '-af', 'areverse',
            '-c:v', 'libx264', '-preset', 'veryfast', '-pix_fmt', 'yuv420p',
            '-c:a', 'aac',
            '-threads', '${softwareThreads()}',
            out,
          ], out));
        }
        break;
      case 'audio_convert':
        {
          final fmt = params['format']?.toString() ?? 'mp3';
          if (fmt == 'wav') {
            final out = p.join(outputDir, 'converted_$base.wav');
            attempts.add(_Attempt('转换为 WAV', ['-y', '-i', inputPath, '-vn', '-c:a', 'pcm_s16le', out], out));
          } else if (fmt == 'aac') {
            final out = p.join(outputDir, 'converted_$base.aac');
            attempts.add(_Attempt('转换为 AAC', ['-y', '-i', inputPath, '-vn', '-c:a', 'aac', '-b:a', '192k', out], out));
          } else {
            final out = p.join(outputDir, 'converted_$base.mp3');
            attempts.add(_Attempt('转换为 MP3', ['-y', '-i', inputPath, '-vn', '-c:a', 'libmp3lame', '-q:a', '2', out], out));
          }
        }
        break;
      default:
        return ProcessingResult(success: false, message: '未知的音视频操作: $op');
    }

    final total = Stopwatch()..start();
    String lastError = '';
    for (var i = 0; i < attempts.length; i++) {
      final a = attempts[i];
      final isLast = i == attempts.length - 1;
      if (i > 0) {
        onProgress?.call(0.05, '${attempts[i - 1].label} 不可用，已自动切换: ${a.label}');
      }
      try {
        final f = File(a.outPath);
        if (f.existsSync()) f.deleteSync();
      } catch (_) {}

      final sw = Stopwatch()..start();
      final res = await _exec(
        a.args,
        durationSec: probeInfo.durationSec,
        onTick: (frac, speed) {
          if (frac == null) {
            onProgress?.call(0.1, '${a.label} · 已运行 ${formatDuration(sw.elapsed)}');
            return;
          }
          final remain = frac > 0.02 ? Duration(milliseconds: (sw.elapsedMilliseconds * (1 - frac) / frac).round()) : null;
          onProgress?.call(
            0.05 + 0.93 * frac,
            '${a.label} ${(frac * 100).toStringAsFixed(1)}%'
            '${speed != null ? ' · ${speed.toStringAsFixed(1)}x' : ''}'
            '${remain != null ? ' · 剩余约 ${formatDuration(remain)}' : ''}',
          );
        },
      );
      sw.stop();

      if (res.cancelled) {
        try {
          final f = File(a.outPath);
          if (f.existsSync()) f.deleteSync();
        } catch (_) {}
        return ProcessingResult(success: false, message: '任务已取消');
      }
      if (res.tail == ffmpegMissingMessage) {
        return ProcessingResult(success: false, message: ffmpegMissingMessage);
      }

      if (res.ok && File(a.outPath).existsSync() && File(a.outPath).lengthSync() > 0) {
        total.stop();
        final outSize = File(a.outPath).lengthSync();
        final inSize = File(inputPath).lengthSync();
        final ratio = (isVideoOp && inSize > 0) ? '\n体积变化: ${_sizeText(inSize)} → ${_sizeText(outSize)} (${(outSize * 100 / inSize).toStringAsFixed(0)}%)' : '\n最终大小: ${_sizeText(outSize)}';
        onProgress?.call(1.0, '任务完成！总耗时 ${formatDuration(total.elapsed)}');
        return ProcessingResult(
          success: true,
          message: '任务完成 (耗时 ${formatDuration(total.elapsed)})！\n输出文件: ${p.basename(a.outPath)}$ratio\n处理方式: ${a.label}',
          outputFiles: [a.outPath],
        );
      }

      lastError = 'FFmpeg 处理失败 (返回码: ${res.code})\n${_errorSummary(res.tail)}';
      debugPrint('[MediaEngine] ${a.label} 失败: $lastError');
      if (isLast) break;
    }

    return ProcessingResult(success: false, message: lastError);
  }
}
