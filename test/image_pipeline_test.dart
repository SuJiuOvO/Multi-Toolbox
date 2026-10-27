import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:app/models/plugin_manifest.dart';
import 'package:app/services/tool_engine_service.dart';
import 'package:app/services/quickjs_bridge_service.dart';
import 'package:path/path.dart' as p;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ToolEngineService image_pipeline Direct Engine Tests', () {
    late Directory tempDir;
    late File sampleImageFile;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('image_pipeline_test_');
      // 创建一个 100x100 的纯色测试 PNG 图像
      final image = img.Image(width: 100, height: 100);
      img.fill(image, color: img.ColorRgba8(255, 0, 0, 255)); // 红色
      sampleImageFile = File(p.join(tempDir.path, 'sample.png'));
      sampleImageFile.writeAsBytesSync(img.encodePng(image));
    });

    tearDown(() {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('Executes resize and circle_crop and saves to PNG', () async {
      final result = await ToolEngineService.execute(
        handler: 'image_pipeline',
        inputFiles: [sampleImageFile.path],
        params: {
          'steps': [
            {'op': 'resize', 'width': 40, 'height': 40},
            {'op': 'circle_crop'},
            {'op': 'save', 'format': 'png', 'output': 'circle_avatar.png'},
          ],
        },
        outputDir: tempDir.path,
      );

      expect(result.success, isTrue);
      expect(result.outputFiles, isNotNull);
      expect(result.outputFiles!.length, 1);

      final outPath = result.outputFiles!.first;
      expect(File(outPath).existsSync(), isTrue);

      final decoded = img.decodePng(File(outPath).readAsBytesSync());
      expect(decoded, isNotNull);
      expect(decoded!.width, 40);
      expect(decoded!.height, 40);

      // 角落处的像素 (0, 0) 应该被 circle_crop 镂空为完全透明 (alpha = 0)
      final cornerPixel = decoded.getPixel(0, 0);
      expect(cornerPixel.a, 0);

      // 中心处的像素 (20, 20) 应该依然是不透明红色
      final centerPixel = decoded.getPixel(20, 20);
      expect(centerPixel.a, 255);
      expect(centerPixel.r, 255);
    });

    test('Executes init_gif, add_gif_frame, and generates animated GIF', () async {
      // 创建第二个测试帧 (蓝色)
      final frame2 = img.Image(width: 50, height: 50);
      img.fill(frame2, color: img.ColorRgba8(0, 0, 255, 255));
      final frame2File = File(p.join(tempDir.path, 'frame2.png'));
      frame2File.writeAsBytesSync(img.encodePng(frame2));

      final result = await ToolEngineService.execute(
        handler: 'image_pipeline',
        inputFiles: [sampleImageFile.path],
        params: {
          'steps': [
            {'op': 'init_gif', 'fps': 5, 'repeat': 0, 'output': 'test_anim.gif'},
            {'op': 'resize', 'width': 50, 'height': 50},
            {'op': 'add_gif_frame'},
            {'op': 'load', 'file': frame2File.path},
            {'op': 'add_gif_frame'},
          ],
        },
        outputDir: tempDir.path,
      );

      expect(result.success, isTrue);
      expect(result.outputFiles, isNotNull);
      expect(result.outputFiles!.length, 1);

      final gifPath = result.outputFiles!.first;
      expect(File(gifPath).existsSync(), isTrue);
      final gifBytes = File(gifPath).readAsBytesSync();
      expect(gifBytes.length, greaterThan(10));
      // GIF magic bytes: "GIF89a" or "GIF87a"
      final magic = String.fromCharCodes(gifBytes.sublist(0, 6));
      expect(magic.startsWith('GIF'), isTrue);
    });

    test('Overlay / composite operation overlays watermark onto image', () async {
      // 水印图片 (10x10 绿色)
      final watermark = img.Image(width: 10, height: 10);
      img.fill(watermark, color: img.ColorRgba8(0, 255, 0, 255));
      final wmFile = File(p.join(tempDir.path, 'wm.png'));
      wmFile.writeAsBytesSync(img.encodePng(watermark));

      final result = await ToolEngineService.execute(
        handler: 'image_pipeline',
        inputFiles: [sampleImageFile.path],
        params: {
          'steps': [
            {'op': 'overlay', 'image': wmFile.path, 'x': 5, 'y': 5},
            {'op': 'save', 'format': 'png', 'output': 'watermarked.png'},
          ],
        },
        outputDir: tempDir.path,
      );

      expect(result.success, isTrue);
      final outPath = result.outputFiles!.first;
      final decoded = img.decodePng(File(outPath).readAsBytesSync())!;
      final overlaidPixel = decoded.getPixel(5, 5);
      expect(overlaidPixel.g, 255);
    });

    test('Canvas operation creates transparent and solid color canvas without input files', () async {
      final result = await ToolEngineService.execute(
        handler: 'image_pipeline',
        inputFiles: [],
        params: {
          'steps': [
            {'op': 'canvas', 'width': 80, 'height': 80, 'color': 'transparent'},
            {'op': 'save', 'format': 'png', 'output': 'canvas_trans.png'},
          ],
        },
        outputDir: tempDir.path,
      );

      expect(result.success, isTrue);
      final outPath = result.outputFiles!.first;
      final decoded = img.decodePng(File(outPath).readAsBytesSync())!;
      expect(decoded.width, 80);
      expect(decoded.height, 80);
      expect(decoded.getPixel(10, 10).a, 0);
    });

    test('Flip operation mirrors image horizontally and vertically', () async {
      // 创建 2x2 不对称图像: 左上红 (255,0,0), 右上蓝 (0,0,255), 左下绿 (0,255,0), 右下黄 (255,255,0)
      final asym = img.Image(width: 2, height: 2);
      asym.setPixelRgba(0, 0, 255, 0, 0, 255);
      asym.setPixelRgba(1, 0, 0, 0, 255, 255);
      asym.setPixelRgba(0, 1, 0, 255, 0, 255);
      asym.setPixelRgba(1, 1, 255, 255, 0, 255);
      final asymFile = File(p.join(tempDir.path, 'asym.png'));
      asymFile.writeAsBytesSync(img.encodePng(asym));

      // 1. 水平翻转: 左上应该变成蓝色
      final resH = await ToolEngineService.execute(
        handler: 'image_pipeline',
        inputFiles: [asymFile.path],
        params: {
          'steps': [
            {'op': 'flip_h'},
            {'op': 'save', 'format': 'png', 'output': 'flipped_h.png'},
          ],
        },
        outputDir: tempDir.path,
      );
      expect(resH.success, isTrue);
      final decH = img.decodePng(File(resH.outputFiles!.first).readAsBytesSync())!;
      expect(decH.getPixel(0, 0).b, 255); // 原右上角蓝色翻到了左上角

      // 2. 垂直翻转: 左上应该变成绿色
      final resV = await ToolEngineService.execute(
        handler: 'image_pipeline',
        inputFiles: [asymFile.path],
        params: {
          'steps': [
            {'op': 'flip_v'},
            {'op': 'save', 'format': 'png', 'output': 'flipped_v.png'},
          ],
        },
        outputDir: tempDir.path,
      );
      expect(resV.success, isTrue);
      final decV = img.decodePng(File(resV.outputFiles!.first).readAsBytesSync())!;
      expect(decV.getPixel(0, 0).g, 255); // 原左下角绿色翻到了左上角
    });

    test('Overlay operation supports direct dstW and dstH scaling during composition', () async {
      // 10x10 纯绿水印
      final wm = img.Image(width: 10, height: 10);
      img.fill(wm, color: img.ColorRgba8(0, 255, 0, 255));
      final wmFile = File(p.join(tempDir.path, 'wm_scale.png'));
      wmFile.writeAsBytesSync(img.encodePng(wm));

      final result = await ToolEngineService.execute(
        handler: 'image_pipeline',
        inputFiles: [sampleImageFile.path],
        params: {
          'steps': [
            {'op': 'overlay', 'image': wmFile.path, 'x': 0, 'y': 0, 'width': 40, 'height': 40},
            {'op': 'save', 'format': 'png', 'output': 'overlay_scaled.png'},
          ],
        },
        outputDir: tempDir.path,
      );

      expect(result.success, isTrue);
      final dec = img.decodePng(File(result.outputFiles!.first).readAsBytesSync())!;
      // (20, 20) 属于缩放后 40x40 的覆盖区域内，应为绿色
      expect(dec.getPixel(20, 20).g, 255);
      // (60, 60) 超出了 40x40 覆盖区域，应保留原始红色
      expect(dec.getPixel(60, 60).r, 255);
    });

    test('Alpha isolated quantizer preserves transparent background without hollowing out opaque black pixels', () async {
      // 构造包含纯透明背景与纯黑不透明实体的特殊测试图
      final avatar = img.Image(width: 10, height: 10, numChannels: 4);
      img.fill(avatar, color: img.ColorRgba8(0, 0, 0, 0)); // 透明背景
      avatar.setPixelRgba(5, 5, 0, 0, 0, 255); // 纯黑发丝/瞳孔
      final avatarFile = File(p.join(tempDir.path, 'avatar_black.png'));
      avatarFile.writeAsBytesSync(img.encodePng(avatar));

      final result = await ToolEngineService.execute(
        handler: 'image_pipeline',
        inputFiles: [avatarFile.path],
        params: {
          'steps': [
            {'op': 'init_gif', 'fps': 10, 'output': 'clean_avatar.gif'},
            {'op': 'add_gif_frame'},
          ],
        },
        outputDir: tempDir.path,
      );

      expect(result.success, isTrue);
      final gifBytes = File(result.outputFiles!.first).readAsBytesSync();
      final decGif = img.decodeGif(gifBytes)!;
      // 1. 背景像素 (0, 0) 依然完全透明
      expect(decGif.getPixel(0, 0).a, 0);
      // 2. 关键验证：纯黑像素 (5, 5) 保持完全不透明 (a=255, r=0, g=0, b=0)，未被误抠穿孔！
      final blackPixel = decGif.getPixel(5, 5);
      expect(blackPixel.a, 255);
      expect(blackPixel.r, 0);
      expect(blackPixel.g, 0);
      expect(blackPixel.b, 0);
    });
  });

  group('QuickJS Bridge Toolbox.image.pipeline Integration Tests', () {
    test('QuickJS script successfully invokes Toolbox.image.pipeline', () async {
      final tempDir = Directory.systemTemp.createTempSync('qjs_img_pipe_');
      try {
        // 创建基础图片
        final baseImg = img.Image(width: 60, height: 60);
        img.fill(baseImg, color: img.ColorRgba8(200, 100, 50, 255));
        final baseImgFile = File(p.join(tempDir.path, 'input.png'));
        baseImgFile.writeAsBytesSync(img.encodePng(baseImg));

        final manifest = PluginManifest(
          id: 'test-js-image-pipe',
          name: 'QuickJS Image Pipeline Test',
          version: '1.0.0',
          category: 'image',
          description: 'Testing Toolbox.image.pipeline from QuickJS sandbox',
          icon: 'image',
          author: 'Test',
          engineType: 'quickjs',
          executionType: 'quickjs',
          platforms: ['universal'],
          action: PluginActionDef(
            handler: 'quickjs_eval',
            params: {
              'script': """
                async function run({ inputFiles, outputDir, params }) {
                  Toolbox.log('Starting image pipeline from JS...');
                  
                  const res = await Toolbox.image.pipeline([
                    { op: 'resize', width: 30, height: 30 },
                    { op: 'save', format: 'png', output: 'qjs_output.png' }
                  ], inputFiles);
                  
                  Toolbox.log('Pipeline finished with: ' + JSON.stringify(res));
                  return { success: res.success, message: res.message, files: res.files };
                }
              """
            },
          ),
        );

        final result = await QuickJsBridgeService.execute(
          plugin: manifest,
          formValues: {},
          inputFiles: [baseImgFile.path],
          outputDir: tempDir.path,
          onProgress: (pct, stage) {},
          onLog: (line, isError) {},
        );

        expect(result.success, isTrue);
        final generatedFile = File(p.join(tempDir.path, 'qjs_output.png'));
        expect(generatedFile.existsSync(), isTrue);

        final decoded = img.decodePng(generatedFile.readAsBytesSync());
        expect(decoded, isNotNull);
        expect(decoded!.width, 30);
        expect(decoded.height, 30);
      } finally {
        if (tempDir.existsSync()) {
          tempDir.deleteSync(recursive: true);
        }
      }
    });
  });
}
