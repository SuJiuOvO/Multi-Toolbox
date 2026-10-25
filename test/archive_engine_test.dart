import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:archive/archive.dart';
import 'package:fast_gbk/fast_gbk.dart';
import 'package:koni_sevenz/koni_sevenz.dart';
import 'package:koni_rar/koni_rar.dart';
import 'package:path/path.dart' as p;
import 'package:app/services/archive_universal_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Archive Universal Extractor & Multi-Volume Tests', () {
    late Directory tempDir;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('archive_test_');
    });

    tearDown(() {
      try {
        if (tempDir.existsSync()) {
          tempDir.deleteSync(recursive: true);
        }
      } catch (_) {}
    });

    test('Zip archive creation and in-memory decode roundtrip', () {
      final archive = Archive();
      const content = 'Hello World from Multi-Toolbox Archive Engine!';
      archive.addFile(ArchiveFile('test_doc.txt', content.length, content.codeUnits));

      final zipBytes = ZipEncoder().encode(archive);
      expect(zipBytes, isNotNull);

      final decodedArchive = ZipDecoder().decodeBytes(zipBytes);
      expect(decodedArchive.length, 1);
      final decodedFile = decodedArchive.first;
      expect(decodedFile.name, 'test_doc.txt');
      expect(String.fromCharCodes(decodedFile.content as List<int>), content);
    });

    test('SevenZFormat and RarFormat descriptors are available', () {
      const sevenz = SevenZFormat();
      expect(sevenz.name, '7z');

      const rar = RarFormat();
      expect(rar.name, 'rar');
    });

    test('extractArchiveBaseName strips compound and multi-volume extensions cleanly', () {
      expect(ArchiveUniversalService.extractArchiveBaseName('/tmp/project_backup.tar.gz'), 'project_backup');
      expect(ArchiveUniversalService.extractArchiveBaseName('/tmp/movie.part01.rar'), 'movie');
      expect(ArchiveUniversalService.extractArchiveBaseName('/tmp/dataset.7z.001'), 'dataset');
      expect(ArchiveUniversalService.extractArchiveBaseName('/tmp/photos.zip.002'), 'photos');
      expect(ArchiveUniversalService.extractArchiveBaseName('/tmp/split_pkg.z01'), 'split_pkg');
      expect(ArchiveUniversalService.extractArchiveBaseName('/tmp/legacy_vol.r00'), 'legacy_vol');
    });

    test('Extract creates archive-named subfolder and avoids double-nesting', () async {
      final srcDir = Directory(p.join(tempDir.path, 'src'))..createSync();
      final f1 = File(p.join(srcDir.path, 'alpha.txt'))..writeAsStringSync('Alpha Content');
      final f2 = File(p.join(srcDir.path, 'beta.txt'))..writeAsStringSync('Beta Content');

      final zipPath = p.join(tempDir.path, 'my_bundle.zip');
      final compRes = await ArchiveUniversalService.compress(
        inputPaths: [f1.path, f2.path],
        outputPath: zipPath,
        format: 'zip',
      );
      expect(compRes.success, isTrue);

      final outRoot = p.join(tempDir.path, 'out_single');
      final extRes = await ArchiveUniversalService.extract(
        archivePath: zipPath,
        outputDir: outRoot,
      );
      expect(extRes.success, isTrue);
      expect(extRes.outputFiles.length, 2);

      // Verify files are inside outRoot/my_bundle/ instead of dumped at outRoot/
      final expectedSubfolder = Directory(p.join(outRoot, 'my_bundle'));
      expect(expectedSubfolder.existsSync(), isTrue);
      expect(File(p.join(expectedSubfolder.path, 'alpha.txt')).readAsStringSync(), 'Alpha Content');
      expect(File(p.join(expectedSubfolder.path, 'beta.txt')).readAsStringSync(), 'Beta Content');
    });

    test('Multi-volume split compression (.001, .002, ...) and multi-volume extraction roundtrip', () async {
      final srcDir = Directory(p.join(tempDir.path, 'split_src'))..createSync();
      final payloadA = List<int>.generate(4096, (i) => ((i * i * 73) ^ (i >> 3) ^ 0x5A) & 0xFF);
      final payloadB = List<int>.generate(4096, (i) => ((i * i * 41) ^ (i >> 2) ^ 0xA5) & 0xFF);
      final fileA = File(p.join(srcDir.path, 'data_a.bin'))..writeAsBytesSync(payloadA);
      final fileB = File(p.join(srcDir.path, 'data_b.bin'))..writeAsBytesSync(payloadB);

      final baseZipPath = p.join(tempDir.path, 'multi_vol_pkg.zip');
      final compRes = await ArchiveUniversalService.compress(
        inputPaths: [fileA.path, fileB.path],
        outputPath: baseZipPath,
        format: 'zip',
        splitBytesOverride: 250, // Force splitting into multiple .001, .002, ... volumes
      );

      expect(compRes.success, isTrue);
      expect(compRes.outputFiles.length, greaterThan(2));
      expect(compRes.outputFiles.first.endsWith('.zip.001'), isTrue);

      // Even if user selects the second volume (.002), it should auto-discover all parts and extract into multi_vol_pkg/
      final outRoot = p.join(tempDir.path, 'out_multi');
      final extRes = await ArchiveUniversalService.extract(
        archivePath: compRes.outputFiles[1],
        outputDir: outRoot,
      );

      expect(extRes.success, isTrue);
      expect(extRes.outputFiles.length, 2);
      final targetSubDir = p.join(outRoot, 'multi_vol_pkg');
      expect(File(p.join(targetSubDir, 'data_a.bin')).readAsBytesSync(), payloadA);
      expect(File(p.join(targetSubDir, 'data_b.bin')).readAsBytesSync(), payloadB);
    });

    test('GBK Chinese filename encoding recovery in ZIP and koni formats', () {
      const originalChinese = '2026年度业务数据分析与战略报告.docx';
      final gbkBytes = gbk.encode(originalChinese);

      // Simulate package:archive Latin-1 decoding of GBK bytes
      final garbled = String.fromCharCodes(gbkBytes);
      expect(garbled, isNot(originalChinese));

      final fixed = ArchiveUniversalService.fixArchiveFileName(garbled);
      expect(fixed, originalChinese);

      // Verify raw byte decoder for koni (7z / RAR)
      final decodedFromBytes = ArchiveUniversalService.decodeArchiveEntryBytes(Uint8List.fromList(gbkBytes));
      expect(decodedFromBytes, originalChinese);

      // Verify UTF-8 strings are unchanged
      expect(ArchiveUniversalService.fixArchiveFileName(originalChinese), originalChinese);
    });

    test('Compressing mixed files and nested directories preserves hierarchy', () async {
      final srcDir = Directory(p.join(tempDir.path, 'mixed_src'))..createSync();
      final standaloneFile = File(p.join(srcDir.path, 'root_notes.txt'))..writeAsStringSync('Root note content');

      final subDir = Directory(p.join(srcDir.path, 'project_folder'))..createSync();
      File(p.join(subDir.path, 'code.py')).writeAsStringSync('print("hello")');
      File(p.join(subDir.path, 'data.csv')).writeAsStringSync('id,val\n1,100');

      final zipPath = p.join(tempDir.path, 'mixed_bundle.zip');
      final compRes = await ArchiveUniversalService.compress(
        inputPaths: [standaloneFile.path, subDir.path],
        outputPath: zipPath,
        format: 'zip',
      );
      expect(compRes.success, isTrue);

      final outRoot = p.join(tempDir.path, 'mixed_out');
      final extRes = await ArchiveUniversalService.extract(
        archivePath: zipPath,
        outputDir: outRoot,
      );
      expect(extRes.success, isTrue);

      final extractedBase = Directory(p.join(outRoot, 'mixed_bundle'));
      expect(extractedBase.existsSync(), isTrue);
      expect(File(p.join(extractedBase.path, 'root_notes.txt')).readAsStringSync(), 'Root note content');
      expect(File(p.join(extractedBase.path, 'project_folder', 'code.py')).readAsStringSync(), 'print("hello")');
      expect(File(p.join(extractedBase.path, 'project_folder', 'data.csv')).readAsStringSync(), 'id,val\n1,100');
    });

    test('Repeated compression over existing split and single archive does not throw PathExistsException', () async {
      final f1 = File(p.join(tempDir.path, 'file1.txt'))..writeAsStringSync('Hello 1');
      final f2 = File(p.join(tempDir.path, 'file2.txt'))..writeAsStringSync('Hello 2');
      final targetZip = p.join(tempDir.path, 'repeat_archive.zip');

      // First run (with splitting into .001, .002, ...)
      final res1 = await ArchiveUniversalService.compress(
        inputPaths: [f1.path, f2.path],
        outputPath: targetZip,
        splitBytesOverride: 50,
      );
      expect(res1.success, isTrue);

      // Second run: repeatedly compress to the EXACT SAME outputPath and split files, plus duplicate inputs
      final res2 = await ArchiveUniversalService.compress(
        inputPaths: [f1.path, f2.path, f1.path],
        outputPath: targetZip,
        splitBytesOverride: 50,
      );
      expect(res2.success, isTrue);

      // Verify extraction succeeds from the overwritten archive using candidateFiles
      final outDir = p.join(tempDir.path, 'repeat_out');
      final extRes = await ArchiveUniversalService.extract(
        archivePath: res2.outputFiles.first,
        candidateFiles: res2.outputFiles,
        outputDir: outDir,
      );
      expect(extRes.success, isTrue);
      expect(extRes.outputFiles.length, 2);
    });

    test('candidateFiles multi-selection connects scattered split volumes cleanly', () async {
      final dir1 = Directory(p.join(tempDir.path, 'folder1'))..createSync();
      final dir2 = Directory(p.join(tempDir.path, 'folder2'))..createSync();
      final p1 = File(p.join(dir1.path, 'scattered.zip.001'))..writeAsBytesSync([1, 2, 3]);
      final p2 = File(p.join(dir2.path, 'scattered.zip.002'))..writeAsBytesSync([4, 5, 6]);

      final parts = ArchiveUniversalService.collectNumberedVolumes(
        p1.path,
        candidateFiles: [p2.path, p1.path],
      );
      expect(parts, isNotNull);
      expect(parts!.length, 2);
      expect(parts.first.path.endsWith('.001'), isTrue);
      expect(parts.last.path.endsWith('.002'), isTrue);
    });
  });
}
