import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:archive/archive.dart';
import 'package:fast_gbk/fast_gbk.dart';
import 'package:flutter/foundation.dart';
import 'package:koni_archive_core/io.dart';
import 'package:koni_sevenz/koni_sevenz.dart';
import 'package:koni_rar/koni_rar.dart';
import 'package:path/path.dart' as p;
import 'tool_engine_service.dart';

/// 压缩包元信息条目
class ArchiveEntryInfo {
  final String path;
  final int size;
  final bool isDirectory;

  ArchiveEntryInfo({
    required this.path,
    required this.size,
    required this.isDirectory,
  });

  Map<String, dynamic> toJson() => {
    'path': path,
    'size': size,
    'isDirectory': isDirectory,
  };
}

/// 跨分卷组合随机访问数据源 (零临时文件拷贝，支持 .001 / .002 / .003 等多分卷无缝拼接读取)
final class CompositeFileByteSource implements ByteSource {
  final List<FileByteSource> _sources;
  final List<int> _partOffsets;
  final int _totalLength;
  @override
  final String? name;
  bool _closed = false;

  CompositeFileByteSource._(
    this._sources,
    this._partOffsets,
    this._totalLength, {
    this.name,
  });

  static Future<CompositeFileByteSource> openParts(
    List<File> partFiles, {
    String? name,
  }) async {
    final sources = <FileByteSource>[];
    final offsets = <int>[];
    var runningOffset = 0;
    try {
      for (final file in partFiles) {
        final src = await FileByteSource.open(file.path);
        sources.add(src);
        offsets.add(runningOffset);
        runningOffset += src.length;
      }
      return CompositeFileByteSource._(
        sources,
        offsets,
        runningOffset,
        name: name ?? (partFiles.isNotEmpty ? partFiles.first.path : null),
      );
    } catch (e) {
      for (final s in sources) {
        await s.close();
      }
      rethrow;
    }
  }

  @override
  int get length => _totalLength;

  @override
  Future<Uint8List> read(int offset, int length) async {
    checkByteSourceRange(this, offset, length);
    if (_closed) {
      throw ArchiveClosedException('read($offset, $length) after close()');
    }
    if (length == 0) return Uint8List(0);

    final out = Uint8List(length);
    var remaining = length;
    var curGlobalOffset = offset;
    var writePos = 0;

    for (var i = 0; i < _sources.length && remaining > 0; i++) {
      final partStart = _partOffsets[i];
      final partLen = _sources[i].length;
      final partEnd = partStart + partLen;
      if (curGlobalOffset >= partEnd) continue;

      final localOffset = curGlobalOffset - partStart;
      final chunkLen = min(remaining, partLen - localOffset);
      final chunk = await _sources[i].read(localOffset, chunkLen);
      out.setRange(writePos, writePos + chunkLen, chunk);

      writePos += chunkLen;
      curGlobalOffset += chunkLen;
      remaining -= chunkLen;
    }

    return out;
  }

  Future<Uint8List> readAllBytes() => read(0, _totalLength);

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    for (final s in _sources) {
      await s.close();
    }
  }
}

/// 跨平台万能压缩与解压引擎服务 (All-in-One Universal Archive Engine)
/// 统一调度 7z、RAR4/RAR5、Zip、Tar、GZip、BZip2、XZ 等全规格格式解压、同名文件夹归整与分卷压缩/解压
class ArchiveUniversalService {
  /// 智能解析与修复压缩包内文件名编码 (完美解决 Windows GBK/CP936 乱码与 UTF-8 跨平台兼容)
  static String fixArchiveFileName(String rawName) {
    final codeUnits = rawName.codeUnits;
    final hasHighLatin = codeUnits.any((c) => c >= 0x80 && c <= 0xFF);
    final hasUnicode = codeUnits.any((c) => c > 0xFF);

    if (hasUnicode || !hasHighLatin) {
      return rawName;
    }

    final bytes = Uint8List.fromList(codeUnits);

    // 1. 优先尝试 UTF-8 解码 (处理未置位 UTF-8 flag 但实际是 UTF-8 字节被转为 Latin-1 的场景)
    try {
      return utf8.decode(bytes);
    } catch (_) {}

    // 2. 尝试 GBK / GB2312 / CP936 解码 (Windows 经典中文压缩包编码)
    try {
      return gbk.decode(bytes);
    } catch (_) {}

    return rawName;
  }

  /// 用于 koni 格式 (7z, RAR) 的原始字节解码器
  static String decodeArchiveEntryBytes(Uint8List nameBytes) {
    try {
      return utf8.decode(nameBytes);
    } catch (_) {
      try {
        return gbk.decode(nameBytes);
      } catch (_) {
        return String.fromCharCodes(nameBytes);
      }
    }
  }

  /// 安全写文件工具：预先探测并清理旧文件，并在遇到 Android FUSE / Scoped Storage 的
  /// PathExistsException (errno = 17) 时自动回退至 FileMode.writeOnly 模式强制覆写
  static Future<void> _safeWriteFile(File file, List<int> bytes) async {
    if (file.existsSync()) {
      try {
        file.deleteSync();
      } catch (_) {}
    }
    try {
      await file.writeAsBytes(bytes, flush: true);
    } catch (_) {
      try {
        if (file.existsSync()) {
          file.deleteSync();
        }
      } catch (_) {}
      final raf = await file.open(mode: FileMode.writeOnly);
      try {
        await raf.writeFrom(bytes);
        await raf.flush();
      } finally {
        await raf.close();
      }
    }
  }

  /// 提取压缩包干净的基础名称（剥离分卷后缀与复合扩展名），用于创建同名文件夹
  static String extractArchiveBaseName(String filePath) {
    var name = p.basename(filePath);

    // 1. 剥离 RAR 分卷后缀 (.part01.rar, .part1.rar, .r00, .r01)
    name = name.replaceFirst(RegExp(r'\.part\d+\.rar$', caseSensitive: false), '');
    name = name.replaceFirst(RegExp(r'\.r\d{2,4}$', caseSensitive: false), '');

    // 2. 剥离 ZIP 分卷后缀 (.z01, .z02)
    name = name.replaceFirst(RegExp(r'\.z\d{2,4}$', caseSensitive: false), '');

    // 3. 剥离通用数字分卷后缀 (.001, .002, .003)
    name = name.replaceFirst(RegExp(r'\.\d{3,4}$', caseSensitive: false), '');

    // 4. 剥离复合归档后缀 (.tar.gz, .tar.bz2, .tar.xz, .tar.zst, .tgz, .tbz, .txz)
    for (final compound in [
      '.tar.gz',
      '.tar.bz2',
      '.tar.xz',
      '.tar.zst',
      '.tgz',
      '.tbz',
      '.txz',
    ]) {
      if (name.toLowerCase().endsWith(compound)) {
        name = name.substring(0, name.length - compound.length);
        break;
      }
    }

    // 5. 剥离常规单层压缩后缀
    for (final ext in [
      '.7z',
      '.rar',
      '.zip',
      '.tar',
      '.gz',
      '.bz2',
      '.xz',
      '.cb7',
      '.cbr',
      '.apk',
      '.jar',
      '.epub',
    ]) {
      if (name.toLowerCase().endsWith(ext)) {
        name = name.substring(0, name.length - ext.length);
        break;
      }
    }

    // 清理非法目录名字符
    final sanitized = name.replaceAll(RegExp(r'[<>:"/\\|?*]'), '_').trim();
    return sanitized.isEmpty ? 'extracted_archive' : sanitized;
  }

  /// 规范化压缩包内部相对路径：防路径穿越 (Zip-Slip)，并自动消除与外层同名文件夹重复嵌套的顶层目录
  static String _resolveTargetFilePath(
    String targetSubDir,
    String archiveBaseName,
    String rawEntryPath,
  ) {
    final normalized = rawEntryPath.replaceAll(r'\', '/');
    final segments = normalized
        .split('/')
        .where((s) => s.isNotEmpty && s != '.' && s != '..')
        .toList();
    if (segments.isEmpty) {
      return targetSubDir;
    }
    // 若压缩包内部本身第一层目录就与 archiveBaseName 同名，避免出现 outputDir/foo/foo/bar.txt 双重嵌套
    if (segments.length > 1 &&
        segments.first.toLowerCase() == archiveBaseName.toLowerCase()) {
      segments.removeAt(0);
    }
    return p.joinAll([targetSubDir, ...segments]);
  }

  /// 公开分卷探寻方法，支持指定候选集与本地目录深层关联
  static List<File>? collectNumberedVolumes(String filePath, {List<String>? candidateFiles}) =>
      _collectNumberedVolumes(filePath, candidateFiles: candidateFiles);

  /// 检测并收集数字分卷文件列表 (.001, .002, .003 ...)
  /// 无论用户选中了 .001 还是 .002 / .003，都能自动定位全套分卷
  static List<File>? _collectNumberedVolumes(String filePath, {List<String>? candidateFiles}) {
    // 1. 若外部传入了候选文件列表，优先直接从候选集中聚合匹配同名前缀的分卷
    if (candidateFiles != null && candidateFiles.length > 1) {
      final baseMatch = RegExp(r'^(.*)\.(\d{3,4})$').firstMatch(p.basename(filePath));
      if (baseMatch != null) {
        final basePrefix = baseMatch.group(1)!.toLowerCase();
        final matched = <File>[];
        for (final c in candidateFiles) {
          final cMatch = RegExp(r'^(.*)\.(\d{3,4})$').firstMatch(p.basename(c));
          if (cMatch != null && cMatch.group(1)!.toLowerCase() == basePrefix) {
            final f = File(c);
            if (f.existsSync()) matched.add(f);
          }
        }
        if (matched.length > 1) {
          matched.sort((a, b) => p.basename(a.path).toLowerCase().compareTo(p.basename(b.path).toLowerCase()));
          return matched;
        }
      }
    }

    final match = RegExp(r'^(.*)\.(\d{3,4})$').firstMatch(filePath);
    if (match == null) return null;

    final prefix = match.group(1)!;
    final digits = match.group(2)!;
    final padWidth = digits.length;

    final parts = <File>[];
    for (var idx = 1; idx <= 9999; idx++) {
      final candidatePath = '$prefix.${idx.toString().padLeft(padWidth, '0')}';
      final f = File(candidatePath);
      if (f.existsSync()) {
        parts.add(f);
      } else {
        break;
      }
    }
    if (parts.length > 1) return parts;

    // 2. 安卓环境特殊自愈：若当前文件处于缓存目录 (file_picker 缓存)，到常见存储路径自动探查原文件与同胞分卷
    if (Platform.isAndroid && filePath.contains('/cache/')) {
      final fileName = p.basename(filePath);
      final filePrefixMatch = RegExp(r'^(.*)\.(\d{3,4})$').firstMatch(fileName);
      if (filePrefixMatch != null) {
        final fileBase = filePrefixMatch.group(1)!;
        final searchDirs = [
          '/storage/emulated/0/Download',
          '/storage/emulated/0/Download/Toolbox_Outputs',
          '/storage/emulated/0/Documents',
        ];
        for (final dirPath in searchDirs) {
          final firstRealFile = File('$dirPath/$fileName');
          if (firstRealFile.existsSync()) {
            final realParts = <File>[];
            for (var idx = 1; idx <= 9999; idx++) {
              final cPath = '$dirPath/$fileBase.${idx.toString().padLeft(padWidth, '0')}';
              final f = File(cPath);
              if (f.existsSync()) {
                realParts.add(f);
              } else {
                break;
              }
            }
            if (realParts.length > 1) return realParts;
          }
        }
      }
    }

    return parts.isNotEmpty ? parts : null;
  }

  /// 检测并收集 Split ZIP 分卷 (.z01, .z02, ... + .zip)
  static List<File>? _collectSplitZipVolumes(String filePath, {List<String>? candidateFiles}) {
    // 0. 若外部传入了候选文件列表，优先从 candidateFiles 匹配
    if (candidateFiles != null && candidateFiles.length > 1) {
      final baseNoExtMatch = RegExp(r'^(.*?)(\.z\d{2,4}|\.zip)$', caseSensitive: false).firstMatch(p.basename(filePath));
      if (baseNoExtMatch != null) {
        final prefix = baseNoExtMatch.group(1)!.toLowerCase();
        final matched = <File>[];
        for (final c in candidateFiles) {
          final cBase = p.basename(c).toLowerCase();
          if (cBase.startsWith(prefix) && (RegExp(r'\.z\d{2,4}$').hasMatch(cBase) || cBase.endsWith('.zip'))) {
            final f = File(c);
            if (f.existsSync()) matched.add(f);
          }
        }
        if (matched.length > 1) {
          matched.sort((a, b) => p.basename(a.path).toLowerCase().compareTo(p.basename(b.path).toLowerCase()));
          return matched;
        }
      }
    }
    final lower = filePath.toLowerCase();
    String? baseNoExt;
    if (RegExp(r'\.z\d{2,4}$').hasMatch(lower)) {
      baseNoExt = filePath.replaceFirst(RegExp(r'\.z\d{2,4}$', caseSensitive: false), '');
    } else if (lower.endsWith('.zip')) {
      final candidateBase = filePath.substring(0, filePath.length - 4);
      if (File('$candidateBase.z01').existsSync() || File('$candidateBase.Z01').existsSync()) {
        baseNoExt = candidateBase;
      }
    }
    if (baseNoExt == null) return null;

    final parts = <File>[];
    for (var idx = 1; idx <= 999; idx++) {
      final suffix = '.z${idx.toString().padLeft(2, '0')}';
      final fLower = File('$baseNoExt$suffix');
      final fUpper = File('$baseNoExt${suffix.toUpperCase()}');
      if (fLower.existsSync()) {
        parts.add(fLower);
      } else if (fUpper.existsSync()) {
        parts.add(fUpper);
      } else {
        break;
      }
    }
    final zipEnd = File('$baseNoExt.zip');
    final zipEndUpper = File('$baseNoExt.ZIP');
    if (zipEnd.existsSync()) {
      parts.add(zipEnd);
    } else if (zipEndUpper.existsSync()) {
      parts.add(zipEndUpper);
    }
    return parts.length > 1 ? parts : null;
  }

  /// 若用户选择了 RAR 的后续分卷 (如 .part2.rar 或 .r00)，自动回溯定位第 1 卷
  static File _resolveRarFirstVolume(File selectedFile) {
    final path = selectedFile.path;
    final partMatch = RegExp(r'^(.*)\.part(\d+)\.rar$', caseSensitive: false).firstMatch(path);
    if (partMatch != null) {
      final prefix = partMatch.group(1)!;
      final numStr = partMatch.group(2)!;
      final volNum = int.tryParse(numStr) ?? 1;
      if (volNum > 1) {
        final firstCandidate = File('$prefix.part${1.toString().padLeft(numStr.length, '0')}.rar');
        if (firstCandidate.existsSync()) return firstCandidate;
        final unpaddedCandidate = File('$prefix.part1.rar');
        if (unpaddedCandidate.existsSync()) return unpaddedCandidate;
      }
      return selectedFile;
    }

    final rMatch = RegExp(r'^(.*)\.r\d{2,4}$', caseSensitive: false).firstMatch(path);
    if (rMatch != null) {
      final prefix = rMatch.group(1)!;
      final rarCandidate = File('$prefix.rar');
      if (rarCandidate.existsSync()) return rarCandidate;
    }

    return selectedFile;
  }

  /// 根据 RAR 第 1 卷路径与 1-based 分卷号 (2, 3, ...)，定位对应分卷文件
  static File? _resolveRarVolumeFile(String firstVolumePath, int volume, {List<String>? candidateFiles}) {
    if (volume <= 1) return File(firstVolumePath);

    // 0. 若外部传入了候选文件列表，优先从 candidateFiles 匹配对应分卷
    if (candidateFiles != null && candidateFiles.isNotEmpty) {
      for (final c in candidateFiles) {
        final m = RegExp(r'\.part(\d+)\.rar$', caseSensitive: false).firstMatch(c);
        if (m != null && int.tryParse(m.group(1)!) == volume) {
          final f = File(c);
          if (f.existsSync()) return f;
        }
        final rIndex = volume - 2;
        if (rIndex >= 0) {
          final rm = RegExp(r'\.r(\d{2,4})$', caseSensitive: false).firstMatch(c);
          if (rm != null && int.tryParse(rm.group(1)!) == rIndex) {
            final f = File(c);
            if (f.existsSync()) return f;
          }
        }
      }
    }
    if (volume <= 1) return File(firstVolumePath);

    // 情况 1: name.part1.rar / name.part01.rar / name.part001.rar
    final partMatch = RegExp(r'^(.*)\.part(\d+)(\.rar)$', caseSensitive: false)
        .firstMatch(firstVolumePath);
    if (partMatch != null) {
      final prefix = partMatch.group(1)!;
      final firstDigits = partMatch.group(2)!;
      final ext = partMatch.group(3)!;
      final padded = '$prefix.part${volume.toString().padLeft(firstDigits.length, '0')}$ext';
      if (File(padded).existsSync()) return File(padded);
      final raw = '$prefix.part$volume$ext';
      if (File(raw).existsSync()) return File(raw);
    }

    // 情况 2: 传统命名 name.rar -> name.r00 (第 2 卷), name.r01 (第 3 卷) ...
    if (firstVolumePath.toLowerCase().endsWith('.rar')) {
      final prefix = firstVolumePath.substring(0, firstVolumePath.length - 4);
      final rIndex = volume - 2; // volume 2 -> .r00
      if (rIndex >= 0) {
        final rPath = '$prefix.r${rIndex.toString().padLeft(2, '0')}';
        if (File(rPath).existsSync()) return File(rPath);
        final rPathUpper = '$prefix.R${rIndex.toString().padLeft(2, '0')}';
        if (File(rPathUpper).existsSync()) return File(rPathUpper);
      }
    }

    return null;
  }

  /// 万能解压核心入口
  /// 默认将所有解压文件规整输出至 `outputDir/<压缩包同名文件夹>/` 下，并自动识别分卷压缩包
  static Future<ProcessingResult> extract({
    required String archivePath,
    required String outputDir,
    List<String>? candidateFiles,
    String? password,
    bool createSubfolder = true,
    void Function(double progress, String stage)? onProgress,
    void Function(String line, bool isError)? onLog,
  }) async {
    final archiveFile = File(archivePath);
    if (!archiveFile.existsSync()) {
      return ProcessingResult(success: false, message: '压缩包文件不存在: $archivePath');
    }

    final archiveBaseName = extractArchiveBaseName(archivePath);
    final effectiveOutputDir = createSubfolder
        ? p.join(outputDir, archiveBaseName)
        : outputDir;

    final outDir = Directory(effectiveOutputDir);
    if (!outDir.existsSync()) {
      outDir.createSync(recursive: true);
    }

    // 1. 检测是否为 .001 / .002 数字分卷压缩包
    final numberedParts = _collectNumberedVolumes(archivePath, candidateFiles: candidateFiles);
    final effectivePathForExt = numberedParts != null
        ? archivePath.replaceFirst(RegExp(r'\.\d{3,4}$'), '')
        : archivePath;
    final ext = _detectExtension(effectivePathForExt);

    if (numberedParts != null && numberedParts.length > 1) {
      onLog?.call(
        '>>> 检测到分卷压缩包，共发现 ${numberedParts.length} 个分卷 (${p.basename(numberedParts.first.path)} ~ ${p.basename(numberedParts.last.path)})',
        false,
      );
    }

    onLog?.call(
      '>>> 准备解压文件: ${p.basename(archivePath)} (格式: $ext) -> 目标文件夹: $archiveBaseName/',
      false,
    );
    onProgress?.call(0.05, '正在分析压缩文件包结构...');

    try {
      if (ext == '.7z' || ext == '.cb7') {
        return await _extract7z(
          archiveFile: archiveFile,
          numberedParts: numberedParts,
          candidateFiles: candidateFiles,
          targetSubDir: effectiveOutputDir,
          archiveBaseName: archiveBaseName,
          password: password,
          onProgress: onProgress,
          onLog: onLog,
        );
      } else if (ext == '.rar' || ext == '.cbr' || RegExp(r'^\.r\d{2,4}$').hasMatch(ext)) {
        return await _extractRar(
          archiveFile: archiveFile,
          numberedParts: numberedParts,
          candidateFiles: candidateFiles,
          targetSubDir: effectiveOutputDir,
          archiveBaseName: archiveBaseName,
          password: password,
          onProgress: onProgress,
          onLog: onLog,
        );
      } else if (ext.startsWith('.tar') || ext == '.tgz' || ext == '.tbz' || ext == '.txz') {
        return await _extractTar(
          archiveFile: archiveFile,
          numberedParts: numberedParts,
          candidateFiles: candidateFiles,
          targetSubDir: effectiveOutputDir,
          archiveBaseName: archiveBaseName,
          ext: ext,
          onProgress: onProgress,
          onLog: onLog,
        );
      } else {
        // 默认作为 Zip / .z01 / Apk / Jar / Epub 处理
        return await _extractZip(
          archiveFile: archiveFile,
          numberedParts: numberedParts,
          candidateFiles: candidateFiles,
          targetSubDir: effectiveOutputDir,
          archiveBaseName: archiveBaseName,
          password: password,
          onProgress: onProgress,
          onLog: onLog,
        );
      }
    } catch (e, stack) {
      debugPrint('解压异常: $e\n$stack');
      onLog?.call('>>> 解压异常: $e', true);
      return ProcessingResult(
        success: false,
        message: '解压失败: ${e.toString().replaceAll("Exception: ", "")}',
      );
    }
  }

  /// 7z 解压处理 (基于 koni_sevenz，支持单卷与 .7z.001/.7z.002 多分卷、LZMA/LZMA2/AES-256)
  static Future<ProcessingResult> _extract7z({
    required File archiveFile,
    required List<File>? numberedParts,
    List<String>? candidateFiles,
    required String targetSubDir,
    required String archiveBaseName,
    String? password,
    void Function(double, String)? onProgress,
    void Function(String, bool)? onLog,
  }) async {
    final ByteSource source;
    if (numberedParts != null && numberedParts.isNotEmpty) {
      source = await CompositeFileByteSource.openParts(
        numberedParts,
        name: archiveBaseName,
      );
    } else {
      source = await FileByteSource.open(archiveFile.path);
    }

    final options = ArchiveReadOptions(
      password: password,
      entryNameDecoder: decodeArchiveEntryBytes,
    );
    const format = SevenZFormat();

    onProgress?.call(0.1, '正在读取 7z 目录与数据流...');
    final reader = await format.createReader(source, options);

    final extractedPaths = <String>[];
    final totalEntries = reader.entries.length;
    final volNote = (numberedParts != null && numberedParts.length > 1)
        ? ' (${numberedParts.length} 个分卷联合读取)'
        : '';
    onLog?.call('>>> 7z 压缩包$volNote读取成功，共计 $totalEntries 个条目', false);

    int processedCount = 0;
    try {
      for (final entry in reader.entries) {
        processedCount++;
        final cleanPath = fixArchiveFileName(entry.path);
        final targetPath = _resolveTargetFilePath(
          targetSubDir,
          archiveBaseName,
          cleanPath,
        );

        if (entry.type == ArchiveEntryType.directory) {
          Directory(targetPath).createSync(recursive: true);
          continue;
        }

        final targetFile = File(targetPath);
        targetFile.parent.createSync(recursive: true);
        if (targetFile.existsSync()) {
          try { targetFile.deleteSync(); } catch (_) {}
        }

        final sink = targetFile.openWrite();
        await sink.addStream(reader.openRead(entry));
        await sink.close();

        extractedPaths.add(targetFile.path);

        if (totalEntries > 0) {
          final pct = 0.1 + (processedCount / totalEntries) * 0.85;
          onProgress?.call(pct, '正在解压: ${p.basename(targetPath)} ($processedCount/$totalEntries)');
        }
      }
    } finally {
      await reader.close();
      await source.close();
    }

    if (extractedPaths.isEmpty) {
      return ProcessingResult(
        success: false,
        message: '7z 压缩包中未提取到有效文件。若为分卷压缩包，请确保包含全部编号分卷并在解压时同时勾选全部相关分卷。',
      );
    }

    onProgress?.call(1.0, '7z 解压完成！');
    onLog?.call('>>> 7z 解压完成！文件已归整至文件夹: $targetSubDir', false);

    return ProcessingResult(
      success: true,
      message: '7z 压缩包$volNote解压成功！\n已归整至同名文件夹: $archiveBaseName/ (共 ${extractedPaths.length} 个文件)',
      outputFiles: extractedPaths,
    );
  }

  /// RAR 解压处理 (基于 koni_rar，支持单卷、.part1.rar/.part2.rar 分卷、.rar+.r00 分卷及 .rar.001 分卷)
  static Future<ProcessingResult> _extractRar({
    required File archiveFile,
    required List<File>? numberedParts,
    List<String>? candidateFiles,
    required String targetSubDir,
    required String archiveBaseName,
    String? password,
    void Function(double, String)? onProgress,
    void Function(String, bool)? onLog,
  }) async {
    final openedVolumes = <ByteSource>[];
    final ByteSource firstSource;
    var volumeCount = 1;

    if (numberedParts != null && numberedParts.isNotEmpty) {
      firstSource = await CompositeFileByteSource.openParts(
        numberedParts,
        name: archiveBaseName,
      );
      openedVolumes.add(firstSource);
      volumeCount = numberedParts.length;
    } else {
      final firstFile = _resolveRarFirstVolume(archiveFile);
      if (firstFile.path != archiveFile.path) {
        onLog?.call('>>> 自动定位到 RAR 分卷首卷: ${p.basename(firstFile.path)}', false);
      }
      firstSource = await FileByteSource.open(firstFile.path);
      openedVolumes.add(firstSource);
    }

    final firstVolPath = _resolveRarFirstVolume(archiveFile).path;
    final options = ArchiveReadOptions(
      password: password,
      entryNameDecoder: decodeArchiveEntryBytes,
      nextVolume: (int volume) async {
        final nextFile = _resolveRarVolumeFile(firstVolPath, volume, candidateFiles: candidateFiles);
        if (nextFile == null || !nextFile.existsSync()) {
          return null;
        }
        volumeCount = max(volumeCount, volume);
        onLog?.call('>>> 正在加载 RAR 第 $volume 分卷: ${p.basename(nextFile.path)}', false);
        final src = await FileByteSource.open(nextFile.path);
        openedVolumes.add(src);
        return src;
      },
    );
    const format = RarFormat();

    onProgress?.call(0.1, '正在读取 RAR 格式头与分卷数据...');
    ArchiveReader? reader;
    final extractedPaths = <String>[];

    try {
      reader = await format.createReader(firstSource, options);
      final totalEntries = reader.entries.length;
      final volNote = volumeCount > 1 ? ' (共 $volumeCount 个分卷)' : '';
      onLog?.call('>>> RAR 压缩包$volNote解析就绪，共计 $totalEntries 个条目', false);

      int processedCount = 0;
      for (final entry in reader.entries) {
        processedCount++;
        final cleanPath = fixArchiveFileName(entry.path);
        final targetPath = _resolveTargetFilePath(
          targetSubDir,
          archiveBaseName,
          cleanPath,
        );

        if (entry.type == ArchiveEntryType.directory) {
          Directory(targetPath).createSync(recursive: true);
          continue;
        }

        final targetFile = File(targetPath);
        targetFile.parent.createSync(recursive: true);
        if (targetFile.existsSync()) {
          try { targetFile.deleteSync(); } catch (_) {}
        }

        final sink = targetFile.openWrite();
        await sink.addStream(reader.openRead(entry));
        await sink.close();

        extractedPaths.add(targetFile.path);

        if (totalEntries > 0) {
          final pct = 0.1 + (processedCount / totalEntries) * 0.85;
          onProgress?.call(pct, '正在解压: ${p.basename(targetPath)} ($processedCount/$totalEntries)');
        }
      }
    } finally {
      await reader?.close();
      for (final src in openedVolumes) {
        await src.close();
      }
    }

    if (extractedPaths.isEmpty) {
      return ProcessingResult(
        success: false,
        message: 'RAR 压缩包中未提取到有效文件。若为分卷压缩包，请确保包含全部编号分卷并在解压时同时勾选全部相关分卷。',
      );
    }

    final volNote = volumeCount > 1 ? ' ($volumeCount 个分卷)' : '';
    onProgress?.call(1.0, 'RAR 解压完成！');
    onLog?.call('>>> RAR 解压完成！文件已归整至文件夹: $targetSubDir', false);

    return ProcessingResult(
      success: true,
      message: 'RAR 压缩包$volNote解压成功！\n已归整至同名文件夹: $archiveBaseName/ (共 ${extractedPaths.length} 个文件)',
      outputFiles: extractedPaths,
    );
  }

  /// ZIP 解压处理 (支持单卷 .zip、分卷 .zip.001/.zip.002 以及 .z01/.z02+.zip)
  static Future<ProcessingResult> _extractZip({
    required File archiveFile,
    required List<File>? numberedParts,
    List<String>? candidateFiles,
    required String targetSubDir,
    required String archiveBaseName,
    String? password,
    void Function(double, String)? onProgress,
    void Function(String, bool)? onLog,
  }) async {
    onProgress?.call(0.1, '正在解析 ZIP 目录索引...');
    Uint8List bytes;
    var volumeCount = 1;

    final splitZipParts = numberedParts ?? _collectSplitZipVolumes(archiveFile.path, candidateFiles: candidateFiles);
    if (splitZipParts != null && splitZipParts.length > 1) {
      volumeCount = splitZipParts.length;
      onLog?.call('>>> 正在合并读取 $volumeCount 个 ZIP 分卷流...', false);
      final composite = await CompositeFileByteSource.openParts(splitZipParts);
      try {
        bytes = await composite.readAllBytes();
      } finally {
        await composite.close();
      }
    } else {
      bytes = await archiveFile.readAsBytes();
    }

    final decoder = ZipDecoder();
    final archive = decoder.decodeBytes(bytes, password: password);

    if (archive.files.isEmpty) {
      final isNumbered = RegExp(r'\.\d{3,4}$').hasMatch(archiveFile.path);
      final errMsg = isNumbered
          ? '未能在该压缩包中找到有效文件。该文件疑似多分卷压缩包的分卷之一，请确保所有分卷（如 .001, .002 等）完整存在，并在解压时同时勾选全部相关分卷！'
          : '解压失败: 压缩包内未包含有效文件或已被损坏。';
      return ProcessingResult(success: false, message: errMsg);
    }

    final extractedPaths = <String>[];
    final totalFiles = archive.files.length;
    final volNote = volumeCount > 1 ? ' ($volumeCount 个分卷)' : '';
    onLog?.call('>>> ZIP 包$volNote读取完成，包含 $totalFiles 个文件或目录', false);

    int count = 0;
    for (final file in archive.files) {
      count++;
      final cleanName = fixArchiveFileName(file.name);
      final targetPath = _resolveTargetFilePath(
        targetSubDir,
        archiveBaseName,
        cleanName,
      );
      if (file.isFile) {
        final outFile = File(targetPath);
        outFile.parent.createSync(recursive: true);
        await _safeWriteFile(outFile, file.content as List<int>);
        extractedPaths.add(outFile.path);
      } else {
        Directory(targetPath).createSync(recursive: true);
      }

      if (totalFiles > 0) {
        final pct = 0.1 + (count / totalFiles) * 0.85;
        onProgress?.call(pct, '正在解压: ${p.basename(cleanName)} ($count/$totalFiles)');
      }
    }

    if (extractedPaths.isEmpty) {
      return ProcessingResult(
        success: false,
        message: 'ZIP 压缩包未提取到有效文件。若为分卷压缩包，请确保包含全部编号分卷并在解压时同时勾选全部相关分卷。',
      );
    }

    onProgress?.call(1.0, 'ZIP 解压完成！');
    onLog?.call('>>> ZIP 解压完成！文件已归整至文件夹: $targetSubDir', false);

    return ProcessingResult(
      success: true,
      message: 'ZIP 压缩包$volNote解压成功！\n已归整至同名文件夹: $archiveBaseName/ (共 ${extractedPaths.length} 个文件)',
      outputFiles: extractedPaths,
    );
  }

  /// TAR / TAR.GZ / TAR.BZ2 / TAR.XZ 解压处理 (支持单卷与 .tar.gz.001 分卷)
  static Future<ProcessingResult> _extractTar({
    required File archiveFile,
    required List<File>? numberedParts,
    List<String>? candidateFiles,
    required String targetSubDir,
    required String archiveBaseName,
    required String ext,
    void Function(double, String)? onProgress,
    void Function(String, bool)? onLog,
  }) async {
    onProgress?.call(0.1, '正在解压 TAR 流...');
    List<int> bytes;
    var volumeCount = 1;

    if (numberedParts != null && numberedParts.length > 1) {
      volumeCount = numberedParts.length;
      onLog?.call('>>> 正在合并读取 $volumeCount 个 TAR 分卷流...', false);
      final composite = await CompositeFileByteSource.openParts(numberedParts);
      try {
        bytes = await composite.readAllBytes();
      } finally {
        await composite.close();
      }
    } else {
      bytes = await archiveFile.readAsBytes();
    }

    if (ext == '.tar.gz' || ext == '.tgz') {
      bytes = GZipDecoder().decodeBytes(bytes);
    } else if (ext == '.tar.bz2' || ext == '.tbz') {
      bytes = BZip2Decoder().decodeBytes(bytes);
    } else if (ext == '.tar.xz' || ext == '.txz') {
      bytes = XZDecoder().decodeBytes(bytes);
    }

    final archive = TarDecoder().decodeBytes(bytes);
    final extractedPaths = <String>[];
    final total = archive.files.length;

    int count = 0;
    for (final file in archive.files) {
      count++;
      final cleanName = fixArchiveFileName(file.name);
      final targetPath = _resolveTargetFilePath(
        targetSubDir,
        archiveBaseName,
        cleanName,
      );
      if (file.isFile) {
        final outFile = File(targetPath);
        outFile.parent.createSync(recursive: true);
        await _safeWriteFile(outFile, file.content as List<int>);
        extractedPaths.add(outFile.path);
      } else {
        Directory(targetPath).createSync(recursive: true);
      }

      if (total > 0) {
        final pct = 0.1 + (count / total) * 0.85;
        onProgress?.call(pct, '正在解压: ${p.basename(cleanName)} ($count/$total)');
      }
    }

    if (extractedPaths.isEmpty) {
      return ProcessingResult(
        success: false,
        message: 'TAR 归档未提取到有效文件。',
      );
    }

    final volNote = volumeCount > 1 ? ' ($volumeCount 个分卷)' : '';
    onProgress?.call(1.0, 'TAR 归档解压完成！');
    onLog?.call('>>> TAR 解压完成！文件已归整至文件夹: $targetSubDir', false);

    return ProcessingResult(
      success: true,
      message: 'TAR 归档$volNote解压成功！\n已归整至同名文件夹: $archiveBaseName/ (共 ${extractedPaths.length} 个文件)',
      outputFiles: extractedPaths,
    );
  }

  /// 归档压缩核心入口 (支持打包为 .zip 或 .tar.gz，并支持按指定分卷大小自动拆分为 .001, .002 ...)
  static Future<ProcessingResult> compress({
    required List<String> inputPaths,
    required String outputPath,
    String format = 'zip',
    int splitSizeMb = 0,
    int? splitBytesOverride,
    void Function(double progress, String stage)? onProgress,
    void Function(String line, bool isError)? onLog,
  }) async {
    onProgress?.call(0.1, '正在收集待压缩文件...');
    final archive = Archive();
    final addedEntryNames = <String>{};

    for (final rawPath in inputPaths) {
      final path = rawPath.endsWith('/') || rawPath.endsWith(r'\')
          ? rawPath.substring(0, rawPath.length - 1)
          : rawPath;
      final f = File(path);
      if (f.existsSync()) {
        final name = p.basename(path);
        if (addedEntryNames.contains(name)) {
          // 自动跳过重复添加的文件
          continue;
        }
        addedEntryNames.add(name);
        final bytes = await f.readAsBytes();
        archive.addFile(ArchiveFile(name, bytes.length, bytes));
      } else if (Directory(path).existsSync()) {
        final dir = Directory(path);
        final baseName = p.basename(path);
        List<FileSystemEntity> entities = [];
        try {
          entities = dir.listSync(recursive: true);
        } catch (e) {
          onLog?.call('>>> 扫描目录异常 ($path): $e。若在安卓真机上，请确保在系统设置中授予【所有文件访问权限】', true);
        }
        if (entities.isEmpty) {
          onLog?.call('>>> 提示: 目录 $baseName 下未扫描到任何文件。若文件夹内实际包含文件，请检查系统设置中是否已为本应用开启【允许管理所有文件】权限。', true);
        }
        for (final entity in entities) {
          if (entity is File) {
            final rel = p.relative(entity.path, from: dir.path);
            final archiveEntryName = '$baseName/$rel'.replaceAll(r'\', '/');
            if (addedEntryNames.contains(archiveEntryName)) continue;
            addedEntryNames.add(archiveEntryName);
            final bytes = await entity.readAsBytes();
            archive.addFile(ArchiveFile(archiveEntryName, bytes.length, bytes));
          } else if (entity is Directory) {
            final rel = p.relative(entity.path, from: dir.path);
            final archiveEntryName = '$baseName/$rel/'.replaceAll(r'\', '/');
            if (addedEntryNames.contains(archiveEntryName)) continue;
            addedEntryNames.add(archiveEntryName);
            archive.addFile(ArchiveFile(archiveEntryName, 0, <int>[]));
          }
        }
      }
    }

    if (archive.files.isEmpty) {
      return ProcessingResult(
        success: false,
        message: '压缩失败: 未收集到待压缩的文件。若在安卓真机上打包文件夹，请确保已在系统权限设置中开启【允许管理所有文件】权限。',
      );
    }

    onProgress?.call(0.45, '正在执行压缩编码...');
    final outFile = File(outputPath);
    outFile.parent.createSync(recursive: true);

    // 预清理可能存在的同名旧归档文件或同名前缀分卷，防止 Android FUSE 报 PathExistsException (errno = 17)
    if (outFile.existsSync()) {
      try {
        outFile.deleteSync();
      } catch (_) {}
    }
    for (var i = 1; i <= 9999; i++) {
      final oldVol = File('$outputPath.${i.toString().padLeft(3, '0')}');
      if (oldVol.existsSync()) {
        try {
          oldVol.deleteSync();
        } catch (_) {}
      } else {
        break;
      }
    }

    final List<int> encodedBytes;
    if (format.toLowerCase() == 'tar.gz' || format.toLowerCase() == 'tgz') {
      final tarBytes = TarEncoder().encode(archive);
      encodedBytes = GZipEncoder().encode(tarBytes);
    } else {
      encodedBytes = ZipEncoder().encode(archive);
    }

    final splitLimitBytes = splitBytesOverride ?? (splitSizeMb > 0 ? splitSizeMb * 1024 * 1024 : 0);
    if (splitLimitBytes > 0 && encodedBytes.length > splitLimitBytes) {
      final totalVolumes = (encodedBytes.length / splitLimitBytes).ceil();
      onProgress?.call(0.75, '正在切分生成 $totalVolumes 个分卷包...');
      onLog?.call('>>> 正在按分卷大小切分为 $totalVolumes 个分卷 (.001 ~ .${totalVolumes.toString().padLeft(3, '0')})', false);

      final volumePaths = <String>[];
      for (var i = 0; i < totalVolumes; i++) {
        final start = i * splitLimitBytes;
        final end = min(start + splitLimitBytes, encodedBytes.length);
        final volName = '$outputPath.${(i + 1).toString().padLeft(3, '0')}';
        final volFile = File(volName);
        await _safeWriteFile(volFile, encodedBytes.sublist(start, end));
        volumePaths.add(volName);
      }

      onProgress?.call(1.0, '分卷压缩完成！');
      onLog?.call('>>> 分卷压缩完成！共生成 ${volumePaths.length} 个分卷文件', false);
      return ProcessingResult(
        success: true,
        message: '分卷压缩成功！共生成 ${volumePaths.length} 个分卷文件 (${p.basename(volumePaths.first)} ~ ${p.basename(volumePaths.last)})',
        outputFiles: volumePaths,
      );
    }

    await _safeWriteFile(outFile, encodedBytes);
    onProgress?.call(1.0, '打包压缩完成！');
    onLog?.call('>>> 压缩文件已保存至: $outputPath', false);

    return ProcessingResult(
      success: true,
      message: '压缩文件已成功生成！(${(encodedBytes.length / 1024).toStringAsFixed(1)} KB)',
      outputFiles: [outputPath],
    );
  }

  static String _detectExtension(String filePath) {
    final lower = filePath.toLowerCase();
    if (RegExp(r'\.part\d+\.rar$').hasMatch(lower)) {
      return '.rar';
    }
    if (RegExp(r'\.r\d{2,4}$').hasMatch(lower)) {
      return '.rar';
    }
    if (RegExp(r'\.z\d{2,4}$').hasMatch(lower)) {
      return '.zip';
    }
    for (final complexExt in [
      '.tar.gz',
      '.tar.bz2',
      '.tar.xz',
      '.tar.zst',
      '.tgz',
      '.tbz',
      '.txz',
    ]) {
      if (lower.endsWith(complexExt)) return complexExt;
    }
    return p.extension(lower);
  }
}
