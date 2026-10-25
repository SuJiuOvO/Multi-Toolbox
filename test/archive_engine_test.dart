import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:archive/archive.dart';
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
  });
}
