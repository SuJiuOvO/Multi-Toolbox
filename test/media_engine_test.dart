import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:app/services/media_engine_service.dart';
import 'package:app/models/plugin_manifest.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('MediaEngineService audio_convert FFmpeg Argument Tests', () {
    const input = 'test/mock_audio.wav';
    const outputDir = 'test/output';

    test('FLAC transcoding arguments use native flac audio codec and no-video flag', () {
      final outPath = '$outputDir/converted_mock_audio.flac';
      final args = MediaEngineService.buildAudioConvertArgs(
        format: 'flac',
        inputPath: input,
        outPath: outPath,
      );

      expect(args, contains('-vn'));
      expect(args, contains('-c:a'));
      expect(args[args.indexOf('-c:a') + 1], 'flac');
      expect(args.last, outPath);
    });

    test('OGG transcoding uses libvorbis as primary and vorbis as fallback', () {
      final outPath = '$outputDir/converted_mock_audio.ogg';
      final primaryArgs = MediaEngineService.buildAudioConvertArgs(
        format: 'ogg',
        inputPath: input,
        outPath: outPath,
        fallbackOgg: false,
      );
      expect(primaryArgs, contains('-c:a'));
      expect(primaryArgs[primaryArgs.indexOf('-c:a') + 1], 'libvorbis');
      expect(primaryArgs, contains('-q:a'));
      expect(primaryArgs[primaryArgs.indexOf('-q:a') + 1], '5');

      final fallbackArgs = MediaEngineService.buildAudioConvertArgs(
        format: 'ogg',
        inputPath: input,
        outPath: outPath,
        fallbackOgg: true,
      );
      expect(fallbackArgs, contains('-c:a'));
      expect(fallbackArgs[fallbackArgs.indexOf('-c:a') + 1], 'vorbis');
      expect(fallbackArgs, contains('-q:a'));
      expect(fallbackArgs[fallbackArgs.indexOf('-q:a') + 1], '5');
    });

    test('Standard WAV, AAC and MP3 codecs remain correctly configured', () {
      final wavArgs = MediaEngineService.buildAudioConvertArgs(
        format: 'wav',
        inputPath: input,
        outPath: '$outputDir/converted_mock_audio.wav',
      );
      expect(wavArgs[wavArgs.indexOf('-c:a') + 1], 'pcm_s16le');

      final aacArgs = MediaEngineService.buildAudioConvertArgs(
        format: 'aac',
        inputPath: input,
        outPath: '$outputDir/converted_mock_audio.aac',
      );
      expect(aacArgs[aacArgs.indexOf('-c:a') + 1], 'aac');
      expect(aacArgs, contains('-b:a'));
      expect(aacArgs[aacArgs.indexOf('-b:a') + 1], '192k');

      final mp3Args = MediaEngineService.buildAudioConvertArgs(
        format: 'mp3',
        inputPath: input,
        outPath: '$outputDir/converted_mock_audio.mp3',
      );
      expect(mp3Args[mp3Args.indexOf('-c:a') + 1], 'libmp3lame');
      expect(mp3Args, contains('-q:a'));
      expect(mp3Args[mp3Args.indexOf('-q:a') + 1], '2');
    });

    test('Format matching is case-insensitive and trims whitespace', () {
      final upperFlac = MediaEngineService.buildAudioConvertArgs(
        format: '  FLAC  ',
        inputPath: input,
        outPath: '$outputDir/converted_mock_audio.flac',
      );
      expect(upperFlac[upperFlac.indexOf('-c:a') + 1], 'flac');

      final upperOgg = MediaEngineService.buildAudioConvertArgs(
        format: 'OGG',
        inputPath: input,
        outPath: '$outputDir/converted_mock_audio.ogg',
      );
      expect(upperOgg[upperOgg.indexOf('-c:a') + 1], 'libvorbis');
    });
  });

  group('video-audio-toolbox Plugin Manifest Specification Tests', () {
    test('Manifest parses cleanly and includes FLAC and OGG options', () async {
      final file = File('assets/default_plugins/video-audio-toolbox.json');
      expect(file.existsSync(), isTrue);

      final content = await file.readAsString();
      final jsonMap = jsonDecode(content) as Map<String, dynamic>;
      final manifest = PluginManifest.fromJson(jsonMap);

      expect(manifest.id, 'video-audio-toolbox');
      expect(manifest.version, '1.3.0');

      // Check allowedExtensions
      final sourceFilesInput = manifest.inputs.firstWhere((i) => i.id == 'sourceFiles');
      expect(sourceFilesInput.allowedExtensions, contains('flac'));
      expect(sourceFilesInput.allowedExtensions, contains('ogg'));
      expect(sourceFilesInput.allowedExtensions, contains('m4a'));

      // Check target audio format options
      final targetFormatInput = manifest.inputs.firstWhere((i) => i.id == 'audioTargetFormat');
      final formatValues = targetFormatInput.options.map((o) => o.value).toList();
      expect(formatValues, containsAll(['mp3', 'wav', 'aac', 'flac', 'ogg']));
    });
  });
}
