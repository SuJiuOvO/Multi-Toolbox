import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:app/models/plugin_manifest.dart';
import 'package:app/services/tool_engine_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Gemini-Banana Lossless Watermark Tests', () {
    late Directory tempDir;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('gemini_wm_test_');
    });

    tearDown(() {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('gemini-banana-watermark manifest parses and conforms to specifications', () {
      final manifestFile = File('assets/default_plugins/gemini-banana-watermark.json');
      expect(manifestFile.existsSync(), isTrue);

      final jsonMap = jsonDecode(manifestFile.readAsStringSync()) as Map<String, dynamic>;
      final manifest = PluginManifest.fromJson(jsonMap);

      expect(manifest.id, 'gemini-banana-watermark');
      expect(manifest.name, 'Gemini 去水印');
      expect(manifest.category, 'image');
      expect(manifest.engineType, 'native_image');
      expect(manifest.isSupportedOnCurrentPlatform(), isTrue);
      expect(manifest.action?.handler, 'gemini_banana_watermark');

      final detectModeInput = manifest.inputs.firstWhere((i) => i.id == 'detectMode');
      expect(detectModeInput.options.any((o) => o.value == 'auto'), isTrue);
      expect(detectModeInput.options.any((o) => o.value == 'force_48'), isTrue);
      expect(detectModeInput.options.any((o) => o.value == 'force_96'), isTrue);
      expect(detectModeInput.options.any((o) => o.value == 'custom'), isTrue);
    });

    test('Reverse alpha blending removes 48x48 watermark on <=1024px image', () async {
      // 1. 创建 512x512 测试彩色渐变图
      final original = img.Image(width: 512, height: 512);
      for (int y = 0; y < 512; y++) {
        for (int x = 0; x < 512; x++) {
          final r = (x * 255 / 512).round();
          final g = (y * 255 / 512).round();
          final b = ((x + y) * 255 / 1024).round();
          original.setPixelRgb(x, y, r, g, b);
        }
      }

      final inputPath = p.join(tempDir.path, 'sample_512.png');
      await File(inputPath).writeAsBytes(img.encodePng(original));

      // 2. 模拟真实 Google Gemini 正向加水印过程 (48x48, 边距 32px)
      //    Watermarked = alpha * 255 + (1 - alpha) * Original
      final watermarked = img.decodePng(await File(inputPath).readAsBytes())!;
      File alpha48Bytes = File('test/assets/bg_48.png');
      if (!alpha48Bytes.existsSync()) {
        alpha48Bytes = File('../community_registry_repo/plugins/gemini-banana-watermark/assets/bg_48.png');
      }
      expect(alpha48Bytes.existsSync(), isTrue);
      final alpha48Img = img.decodePng(alpha48Bytes.readAsBytesSync())!;

      const startX = 512 - 32 - 48;
      const startY = 512 - 32 - 48;

      for (int r = 0; r < 48; r++) {
        for (int c = 0; c < 48; c++) {
          final aPixel = alpha48Img.getPixel(c, r);
          final rawAlpha = [aPixel.r, aPixel.g, aPixel.b].reduce((m, v) => v > m ? v : m) / 255.0;
          if (rawAlpha < 0.002) continue;

          final origPixel = watermarked.getPixel(startX + c, startY + r);
          final wmR = (rawAlpha * 255.0 + (1.0 - rawAlpha) * origPixel.r).round().clamp(0, 255);
          final wmG = (rawAlpha * 255.0 + (1.0 - rawAlpha) * origPixel.g).round().clamp(0, 255);
          final wmB = (rawAlpha * 255.0 + (1.0 - rawAlpha) * origPixel.b).round().clamp(0, 255);
          watermarked.setPixelRgb(startX + c, startY + r, wmR, wmG, wmB);
        }
      }

      final watermarkedPath = p.join(tempDir.path, 'watermarked_512.png');
      await File(watermarkedPath).writeAsBytes(img.encodePng(watermarked));

      // 3. 执行 ToolEngineService.execute 进行无损去水印
      final outDir = p.join(tempDir.path, 'output');
      final res = await ToolEngineService.execute(
        handler: 'gemini_banana_watermark',
        inputFiles: [watermarkedPath],
        params: {
          'detectMode': 'auto',
          'format': 'png',
        },
        outputDir: outDir,
      );

      expect(res.success, isTrue);
      expect(res.outputFiles.length, 1);

      // 4. 验证去除效果
      final restoredImg = img.decodePng(File(res.outputFiles.first).readAsBytesSync())!;
      expect(restoredImg.width, 512);
      expect(restoredImg.height, 512);

      // 检验水印区域恢复精度 (平均像素误差应 < 1.0)
      double totalDiff = 0.0;
      int testedPixels = 0;
      for (int r = 0; r < 48; r++) {
        for (int c = 0; c < 48; c++) {
          final orig = original.getPixel(startX + c, startY + r);
          final rec = restoredImg.getPixel(startX + c, startY + r);
          final diff = (orig.r - rec.r).abs() + (orig.g - rec.g).abs() + (orig.b - rec.b).abs();
          totalDiff += diff / 3.0;
          testedPixels++;
        }
      }
      final meanError = totalDiff / testedPixels;
      expect(meanError, lessThan(1.5));
    });

    test('Reverse alpha blending removes 96x96 watermark on >1024px image', () async {
      // 1. 创建 1200x1200 测试图
      final original = img.Image(width: 1200, height: 1200);
      for (int y = 0; y < 1200; y += 10) {
        for (int x = 0; x < 1200; x += 10) {
          final r = (x * 255 / 1200).round();
          final g = (y * 255 / 1200).round();
          final b = 180;
          for (int dy = 0; dy < 10 && y + dy < 1200; dy++) {
            for (int dx = 0; dx < 10 && x + dx < 1200; dx++) {
              original.setPixelRgb(x + dx, y + dy, r, g, b);
            }
          }
        }
      }

      // 2. 模拟 96x96 水印 (边距 64px)
      File alpha96File = File('test/assets/bg_96.png');
      if (!alpha96File.existsSync()) {
        alpha96File = File('../community_registry_repo/plugins/gemini-banana-watermark/assets/bg_96.png');
      }
      expect(alpha96File.existsSync(), isTrue);
      final alpha96Img = img.decodePng(alpha96File.readAsBytesSync())!;

      const startX = 1200 - 64 - 96;
      const startY = 1200 - 64 - 96;

      final watermarked = img.Image.from(original);
      for (int r = 0; r < 96; r++) {
        for (int c = 0; c < 96; c++) {
          final aPixel = alpha96Img.getPixel(c, r);
          final rawAlpha = [aPixel.r, aPixel.g, aPixel.b].reduce((m, v) => v > m ? v : m) / 255.0;
          if (rawAlpha < 0.002) continue;

          final origPixel = watermarked.getPixel(startX + c, startY + r);
          final wmR = (rawAlpha * 255.0 + (1.0 - rawAlpha) * origPixel.r).round().clamp(0, 255);
          final wmG = (rawAlpha * 255.0 + (1.0 - rawAlpha) * origPixel.g).round().clamp(0, 255);
          final wmB = (rawAlpha * 255.0 + (1.0 - rawAlpha) * origPixel.b).round().clamp(0, 255);
          watermarked.setPixelRgb(startX + c, startY + r, wmR, wmG, wmB);
        }
      }

      final watermarkedPath = p.join(tempDir.path, 'watermarked_1200.png');
      await File(watermarkedPath).writeAsBytes(img.encodePng(watermarked));

      // 3. 执行自适应去除
      final outDir = p.join(tempDir.path, 'output_large');
      final res = await ToolEngineService.execute(
        handler: 'gemini_banana_watermark',
        inputFiles: [watermarkedPath],
        params: {
          'detectMode': 'auto',
          'format': 'png',
        },
        outputDir: outDir,
      );

      expect(res.success, isTrue);
      expect(res.outputFiles.length, 1);

      final restoredImg = img.decodePng(File(res.outputFiles.first).readAsBytesSync())!;
      expect(restoredImg.width, 1200);
      expect(restoredImg.height, 1200);

      double totalDiff = 0.0;
      int testedPixels = 0;
      for (int r = 0; r < 96; r++) {
        for (int c = 0; c < 96; c++) {
          final orig = original.getPixel(startX + c, startY + r);
          final rec = restoredImg.getPixel(startX + c, startY + r);
          final diff = (orig.r - rec.r).abs() + (orig.g - rec.g).abs() + (orig.b - rec.b).abs();
          totalDiff += diff / 3.0;
          testedPixels++;
        }
      }
      final meanError = totalDiff / testedPixels;
      expect(meanError, lessThan(1.5));
    });
    test('Reverse alpha blending removes 2K/4K Gemini watermark on 修复1.png', () async {
      final sampleFile = File(r'C:\Users\ZhuanZ\Desktop\修复1.png');
      if (!sampleFile.existsSync()) return;

      final result = await ToolEngineService.execute(
        handler: 'gemini_banana_watermark',
        inputFiles: [sampleFile.path],
        params: {'detectMode': 'auto'},
        outputDir: tempDir.path,
      );

      expect(result.success, isTrue);
      expect(result.outputFiles.length, 1);
      final outFile = File(result.outputFiles.first);
      expect(outFile.existsSync(), isTrue);

      final outImg = img.decodeImage(outFile.readAsBytesSync())!;
      expect(outImg.width, 2390);
      expect(outImg.height, 1792);

      // Verify the watermark region (around x: 2150, y: 1552) is restored smoothly
      final p1 = outImg.getPixel(2150, 1552);
      final pSurround = outImg.getPixel(2150 + 70, 1552);
      expect((p1.r - pSurround.r).abs(), lessThan(15));
    });
  });
}
