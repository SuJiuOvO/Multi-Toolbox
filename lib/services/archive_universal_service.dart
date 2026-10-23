import 'dart:io';
import 'package:archive/archive.dart';
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

/// 跨平台万能压缩与解压引擎服务 (All-in-One Universal Archive Engine)
/// 统一调度 7z、RAR4/RAR5、Zip、Tar、GZip、BZip2、XZ 等全规格格式解压与归档
class ArchiveUniversalService {
  /// 万能解压核心入口
  static Future<ProcessingResult> extract({
    required String archivePath,
    required String outputDir,
    String? password,
    void Function(double progress, String stage)? onProgress,
    void Function(String line, bool isError)? onLog,
  }) async {
    final archiveFile = File(archivePath);
    if (!archiveFile.existsSync()) {
      return ProcessingResult(success: false, message: '压缩包文件不存在: $archivePath');
    }

    final outDir = Directory(outputDir);
    if (!outDir.existsSync()) {
      outDir.createSync(recursive: true);
    }

    final ext = _detectExtension(archivePath);
    onLog?.call('>>> 准备解压文件: ${p.basename(archivePath)} (格式: $ext)', false);
    onProgress?.call(0.05, '正在分析压缩文件包结构...');

    try {
      if (ext == '.7z' || ext == '.cb7') {
        return await _extract7z(
          archiveFile: archiveFile,
          outputDir: outputDir,
          password: password,
          onProgress: onProgress,
          onLog: onLog,
        );
      } else if (ext == '.rar' || ext == '.cbr') {
        return await _extractRar(
          archiveFile: archiveFile,
          outputDir: outputDir,
          password: password,
          onProgress: onProgress,
          onLog: onLog,
        );
      } else if (ext.startsWith('.tar') || ext == '.tgz' || ext == '.tbz' || ext == '.txz') {
        return await _extractTar(
          archiveFile: archiveFile,
          outputDir: outputDir,
          ext: ext,
          onProgress: onProgress,
          onLog: onLog,
        );
      } else {
        // 默认作为 Zip / Apk / Jar / Epub 处理
        return await _extractZip(
          archiveFile: archiveFile,
          outputDir: outputDir,
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

  /// 7z 解压处理 (基于 koni_sevenz，支持 LZMA/LZMA2/Deflate/AES-256)
  static Future<ProcessingResult> _extract7z({
    required File archiveFile,
    required String outputDir,
    String? password,
    void Function(double, String)? onProgress,
    void Function(String, bool)? onLog,
  }) async {
    final source = await FileByteSource.open(archiveFile.path);
    final options = ArchiveReadOptions(password: password);
    const format = SevenZFormat();

    onProgress?.call(0.1, '正在读取 7z 目录与数据流...');
    final reader = await format.createReader(source, options);

    final extractedPaths = <String>[];
    final totalEntries = reader.entries.length;
    onLog?.call('>>> 7z 压缩包读取成功，共计 $totalEntries 个条目', false);

    int processedCount = 0;
    try {
      for (final entry in reader.entries) {
        processedCount++;
        final normalizedPath = entry.path.replaceAll(r'\', '/');
        final targetPath = p.join(outputDir, normalizedPath);

        if (entry.type == ArchiveEntryType.directory) {
          Directory(targetPath).createSync(recursive: true);
          continue;
        }

        final targetFile = File(targetPath);
        targetFile.parent.createSync(recursive: true);

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

    onProgress?.call(1.0, '7z 解压完成！');
    onLog?.call('>>> 7z 解压完成！共解压 ${extractedPaths.length} 个文件', false);

    return ProcessingResult(
      success: true,
      message: '7z 压缩包解压成功！共提取 ${extractedPaths.length} 个文件',
      outputFiles: extractedPaths,
    );
  }

  /// RAR 解压处理 (基于 koni_rar，支持 RAR4 & RAR5, AES-128 / AES-256)
  static Future<ProcessingResult> _extractRar({
    required File archiveFile,
    required String outputDir,
    String? password,
    void Function(double, String)? onProgress,
    void Function(String, bool)? onLog,
  }) async {
    final source = await FileByteSource.open(archiveFile.path);
    final options = ArchiveReadOptions(password: password);
    const format = RarFormat();

    onProgress?.call(0.1, '正在读取 RAR 格式头与卷数据...');
    final reader = await format.createReader(source, options);

    final extractedPaths = <String>[];
    final totalEntries = reader.entries.length;
    onLog?.call('>>> RAR 压缩包解析就绪，共计 $totalEntries 个条目', false);

    int processedCount = 0;
    try {
      for (final entry in reader.entries) {
        processedCount++;
        final normalizedPath = entry.path.replaceAll(r'\', '/');
        final targetPath = p.join(outputDir, normalizedPath);

        if (entry.type == ArchiveEntryType.directory) {
          Directory(targetPath).createSync(recursive: true);
          continue;
        }

        final targetFile = File(targetPath);
        targetFile.parent.createSync(recursive: true);

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

    onProgress?.call(1.0, 'RAR 解压完成！');
    onLog?.call('>>> RAR 解压完成！共解压 ${extractedPaths.length} 个文件', false);

    return ProcessingResult(
      success: true,
      message: 'RAR 压缩包解压成功！共提取 ${extractedPaths.length} 个文件',
      outputFiles: extractedPaths,
    );
  }

  /// ZIP 解压处理 (基于 archive 包)
  static Future<ProcessingResult> _extractZip({
    required File archiveFile,
    required String outputDir,
    String? password,
    void Function(double, String)? onProgress,
    void Function(String, bool)? onLog,
  }) async {
    onProgress?.call(0.1, '正在解析 ZIP 目录索引...');
    final bytes = archiveFile.readAsBytesSync();
    final decoder = ZipDecoder();
    final archive = decoder.decodeBytes(bytes, password: password);

    final extractedPaths = <String>[];
    final totalFiles = archive.files.length;
    onLog?.call('>>> ZIP 包读取完成，包含 $totalFiles 个文件或目录', false);

    int count = 0;
    for (final file in archive.files) {
      count++;
      final targetPath = p.join(outputDir, file.name);
      if (file.isFile) {
        final outFile = File(targetPath);
        outFile.parent.createSync(recursive: true);
        outFile.writeAsBytesSync(file.content as List<int>);
        extractedPaths.add(outFile.path);
      } else {
        Directory(targetPath).createSync(recursive: true);
      }

      if (totalFiles > 0) {
        final pct = 0.1 + (count / totalFiles) * 0.85;
        onProgress?.call(pct, '正在解压: ${p.basename(file.name)} ($count/$totalFiles)');
      }
    }

    onProgress?.call(1.0, 'ZIP 解压完成！');
    onLog?.call('>>> ZIP 解压完成！共解压 ${extractedPaths.length} 个文件', false);

    return ProcessingResult(
      success: true,
      message: 'ZIP 压缩包解压成功！共提取 ${extractedPaths.length} 个文件',
      outputFiles: extractedPaths,
    );
  }

  /// TAR / TAR.GZ / TAR.BZ2 / TAR.XZ 解压处理
  static Future<ProcessingResult> _extractTar({
    required File archiveFile,
    required String outputDir,
    required String ext,
    void Function(double, String)? onProgress,
    void Function(String, bool)? onLog,
  }) async {
    onProgress?.call(0.1, '正在解压 TAR 流...');
    List<int> bytes = archiveFile.readAsBytesSync();

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
      final targetPath = p.join(outputDir, file.name);
      if (file.isFile) {
        final outFile = File(targetPath);
        outFile.parent.createSync(recursive: true);
        outFile.writeAsBytesSync(file.content as List<int>);
        extractedPaths.add(outFile.path);
      } else {
        Directory(targetPath).createSync(recursive: true);
      }

      if (total > 0) {
        final pct = 0.1 + (count / total) * 0.85;
        onProgress?.call(pct, '正在解压: ${p.basename(file.name)} ($count/$total)');
      }
    }

    onProgress?.call(1.0, 'TAR 归档解压完成！');
    return ProcessingResult(
      success: true,
      message: 'TAR 归档解压成功！共提取 ${extractedPaths.length} 个文件',
      outputFiles: extractedPaths,
    );
  }

  /// 归档压缩核心入口 (支持打包为 .zip 或 .tar.gz)
  static Future<ProcessingResult> compress({
    required List<String> inputPaths,
    required String outputPath,
    String format = 'zip',
    void Function(double progress, String stage)? onProgress,
    void Function(String line, bool isError)? onLog,
  }) async {
    onProgress?.call(0.1, '正在收集待压缩文件...');
    final archive = Archive();

    for (final path in inputPaths) {
      final f = File(path);
      if (f.existsSync()) {
        final name = p.basename(path);
        final bytes = f.readAsBytesSync();
        archive.addFile(ArchiveFile(name, bytes.length, bytes));
      } else if (Directory(path).existsSync()) {
        final dir = Directory(path);
        final baseName = p.basename(path);
        for (final entity in dir.listSync(recursive: true)) {
          if (entity is File) {
            final rel = p.relative(entity.path, from: dir.path);
            final archiveEntryName = '$baseName/$rel'.replaceAll(r'\', '/');
            final bytes = entity.readAsBytesSync();
            archive.addFile(ArchiveFile(archiveEntryName, bytes.length, bytes));
          }
        }
      }
    }

    onProgress?.call(0.4, '正在执行压缩编码...');
    final outFile = File(outputPath);
    outFile.parent.createSync(recursive: true);

    if (format.toLowerCase() == 'tar.gz' || format.toLowerCase() == 'tgz') {
      final tarBytes = TarEncoder().encode(archive);
      final gzBytes = GZipEncoder().encode(tarBytes);
      outFile.writeAsBytesSync(gzBytes);
    } else {
      final zipBytes = ZipEncoder().encode(archive);
      outFile.writeAsBytesSync(zipBytes);
    }

    onProgress?.call(1.0, '打包压缩完成！');
    onLog?.call('>>> 压缩文件已保存至: $outputPath', false);

    return ProcessingResult(
      success: true,
      message: '压缩文件已成功生成！',
      outputFiles: [outputPath],
    );
  }

  static String _detectExtension(String filePath) {
    final lower = filePath.toLowerCase();
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
