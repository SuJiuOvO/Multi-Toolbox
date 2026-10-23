import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:archive/archive.dart';
import 'package:koni_sevenz/koni_sevenz.dart';
import 'package:koni_rar/koni_rar.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Archive Universal Extractor Tests', () {
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
      final content = 'Hello World from Multi-Toolbox Archive Engine!';
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
  });
}
