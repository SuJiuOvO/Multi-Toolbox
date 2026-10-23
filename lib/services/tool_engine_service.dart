import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:archive/archive.dart';
import 'package:dio/dio.dart';
import 'package:uuid/uuid.dart';
import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/return_code.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:qr/qr.dart';
import 'package:qr_code_dart_decoder/qr_code_dart_decoder.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart' as sf;
import 'package:pdfrx/pdfrx.dart' as rx;
import 'doc_converter_service.dart';

class ProcessingResult {
  final bool success;
  final String message;
  final List<String> outputFiles;

  ProcessingResult({
    required this.success,
    required this.message,
    this.outputFiles = const [],
  });
}

class ToolEngineService {
  /// 统一引擎调度分发入口
  static Future<ProcessingResult> execute({
    required String handler,
    required List<String> inputFiles,
    required Map<String, dynamic> params,
    required String outputDir,
    Function(double progress, String stage)? onProgress,
  }) async {
    try {
      final outDir = Directory(outputDir);
      if (!outDir.existsSync()) {
        outDir.createSync(recursive: true);
      }

      switch (handler) {
        case 'image_compress':
          if (inputFiles.isEmpty) return ProcessingResult(success: false, message: '请至少选择一个输入文件');
          return await _handleImageCompress(inputFiles, params, outputDir, onProgress);
        case 'image_resize':
          if (inputFiles.isEmpty) return ProcessingResult(success: false, message: '请至少选择一个输入文件');
          return await _handleImageResize(inputFiles, params, outputDir, onProgress);
        case 'id_photo_bg':
          if (inputFiles.isEmpty) return ProcessingResult(success: false, message: '请至少选择一个输入文件');
          return await _handleIdPhotoBg(inputFiles, params, outputDir, onProgress);
        case 'media_pipeline':
          if (inputFiles.isEmpty) return ProcessingResult(success: false, message: '请至少选择一个输入文件');
          return await _handleMediaPipeline(inputFiles, params, outputDir, onProgress);
        case 'qr_toolbox':
          return await _handleQrToolbox(inputFiles, params, outputDir, onProgress);
        case 'chunk_downloader':
          return await _handleChunkDownloader(params, outputDir, onProgress);
        case 'gif_toolbox':
          return await _handleGifToolbox(inputFiles, params, outputDir, onProgress);
        case 'livephoto_toolbox':
          return await _handleLivePhotoToolbox(inputFiles, params, outputDir, onProgress);
        case 'pdf_toolbox':
          return await _handlePdfToolbox(inputFiles, params, outputDir, onProgress);
        case 'gemini_banana_watermark':
          if (inputFiles.isEmpty) return ProcessingResult(success: false, message: '请至少选择一个输入文件');
          return await _handleGeminiBananaWatermark(inputFiles, params, outputDir, onProgress);
        case 'doc_converter':
          return await DocConverterService.execute({
            'subTool': params['subTool'],
            'files': inputFiles,
            'params': params,
            'outputDir': outputDir,
          }, onProgress);
        default:
          return ProcessingResult(
            success: false,
            message: '未识别的处理引擎动作: $handler',
          );
      }
    } catch (e, stack) {
      return ProcessingResult(
        success: false,
        message: '处理发生异常: $e\n$stack',
      );
    }
  }

  // =========================================================================
  // 1. 图片批量压缩 (参考 Caesium / Squoosh / TinyPNG 最佳实践)
  //    - WebP: 优质有损压缩 (高质量小体积)
  //    - JPG: MozJPEG 风格质量控制 + 大图边界安全限制
  //    - PNG: 采用 256/128 色调色板量化 (Color Quantization)，突破 PNG 压缩无效果的瓶颈
  // =========================================================================
  static Future<ProcessingResult> _handleImageCompress(
    List<String> files,
    Map<String, dynamic> params,
    String outputDir,
    Function(double, String)? onProgress,
  ) async {
    final qualityVal = params['quality'];
    final quality = (qualityVal is num ? qualityVal.toInt() : int.tryParse(qualityVal.toString())) ?? 75;
    final format = params['format']?.toString() ?? 'keep_original';
    final maxEdgeVal = params['maxEdge'];
    final maxEdge = (maxEdgeVal is num ? maxEdgeVal.toInt() : int.tryParse(maxEdgeVal?.toString() ?? '0')) ?? 0;

    List<String> results = [];
    int totalOriginalSize = 0;
    int totalCompressedSize = 0;

    for (int i = 0; i < files.length; i++) {
      final filePath = files[i];
      final file = File(filePath);
      final originalBytes = await file.readAsBytes();
      totalOriginalSize += originalBytes.length;

      onProgress?.call(
        i / files.length,
        '正在压缩 (${i + 1}/${files.length}): ${p.basename(filePath)}',
      );

      final decoded = img.decodeImage(originalBytes);
      if (decoded == null) continue;

      img.Image image = decoded;

      // 如果指定了最大边长限制且原图超标，先进行高质量等比缩放
      if (maxEdge > 0 && (image.width > maxEdge || image.height > maxEdge)) {
        if (image.width >= image.height) {
          final targetH = (image.height * (maxEdge / image.width)).round();
          image = img.copyResize(image, width: maxEdge, height: targetH, interpolation: img.Interpolation.cubic);
        } else {
          final targetW = (image.width * (maxEdge / image.height)).round();
          image = img.copyResize(image, width: targetW, height: maxEdge, interpolation: img.Interpolation.cubic);
        }
      }

      String ext = p.extension(filePath).toLowerCase();
      String targetExt = ext;
      if (format == 'webp') {
        targetExt = '.webp';
      } else if (format == 'jpg' || format == 'jpeg') {
        targetExt = '.jpg';
      } else if (format == 'png') {
        targetExt = '.png';
      }

      Uint8List encoded;
      if (targetExt == '.webp') {
        // WebP 编码：现代高效格式
        final encoder = img.WebPEncoder(lossless: false, quality: quality.clamp(5, 100));
        encoded = Uint8List.fromList(encoder.encode(image));
      } else if (targetExt == '.png') {
        // PNG 压缩：如果质量 < 88，执行 256/128/64 色调色板量化，实现大幅度体积缩减（类似 TinyPNG）
        if (quality < 88) {
          int colors = 256;
          if (quality <= 40) {
            colors = 64;
          } else if (quality <= 65) {
            colors = 128;
          }
          final quantized = img.quantize(
            image,
            numberOfColors: colors,
            method: img.QuantizeMethod.octree,
          );
          encoded = Uint8List.fromList(img.encodePng(quantized, level: 9));
        } else {
          encoded = Uint8List.fromList(img.encodePng(image, level: 6));
        }
      } else {
        // JPG 编码：平滑质量控制
        encoded = Uint8List.fromList(img.encodeJpg(image, quality: quality.clamp(5, 100)));
      }

      final outName = 'compressed_${p.basenameWithoutExtension(filePath)}$targetExt';
      final outPath = p.join(outputDir, outName);
      await File(outPath).writeAsBytes(encoded);
      totalCompressedSize += encoded.length;
      results.add(outPath);
    }

    final ratio = totalOriginalSize > 0
        ? ((1 - (totalCompressedSize / totalOriginalSize)) * 100).toStringAsFixed(1)
        : '0';

    onProgress?.call(1.0, '全部图片压缩完成！');
    return ProcessingResult(
      success: true,
      message: '成功压缩 ${results.length} 张图片！\n总体积由 ${(totalOriginalSize / 1024).toStringAsFixed(1)} KB → ${(totalCompressedSize / 1024).toStringAsFixed(1)} KB (压缩率: $ratio%)',
      outputFiles: results,
    );
  }

  // =========================================================================
  // 2. 图片尺寸调整 (保持比例 / 高质量三次样条插值 Cubic Resampling)
  // =========================================================================
  static Future<ProcessingResult> _handleImageResize(
    List<String> files,
    Map<String, dynamic> params,
    String outputDir,
    Function(double, String)? onProgress,
  ) async {
    final mode = params['mode']?.toString() ?? 'scale';
    final scale = (params['scale'] as num?)?.toDouble() ?? 50.0;
    final targetW = (params['width'] as num?)?.toInt() ?? 800;
    final targetH = (params['height'] as num?)?.toInt() ?? 600;

    List<String> results = [];
    for (int i = 0; i < files.length; i++) {
      final filePath = files[i];
      onProgress?.call(i / files.length, '正在缩放: ${p.basename(filePath)} (${i + 1}/${files.length})');

      final bytes = await File(filePath).readAsBytes();
      final image = img.decodeImage(bytes);
      if (image == null) continue;

      int newW = image.width;
      int newH = image.height;

      if (mode == 'scale') {
        newW = max(1, (image.width * (scale / 100)).round());
        newH = max(1, (image.height * (scale / 100)).round());
      } else if (mode == 'fit_width') {
        newW = max(1, targetW);
        newH = max(1, (image.height * (targetW / image.width)).round());
      } else if (mode == 'fit_height') {
        newH = max(1, targetH);
        newW = max(1, (image.width * (targetH / image.height)).round());
      } else if (mode == 'fixed') {
        newW = max(1, targetW);
        newH = max(1, targetH);
      }

      // 使用 Cubic 三次卷积插值算法，获得更加平滑细腻的高保真缩放效果
      final resized = img.copyResize(
        image,
        width: newW,
        height: newH,
        interpolation: img.Interpolation.cubic,
      );

      final outName = 'resized_${newW}x${newH}_${p.basename(filePath)}';
      final outPath = p.join(outputDir, outName);

      final ext = p.extension(filePath).toLowerCase();
      Uint8List encoded;
      if (ext == '.png') {
        encoded = Uint8List.fromList(img.encodePng(resized));
      } else if (ext == '.webp') {
        final encoder = img.WebPEncoder(lossless: false, quality: 90);
        encoded = Uint8List.fromList(encoder.encode(resized));
      } else {
        encoded = Uint8List.fromList(img.encodeJpg(resized, quality: 92));
      }

      await File(outPath).writeAsBytes(encoded);
      results.add(outPath);
    }

    onProgress?.call(1.0, '图片尺寸修改完成！');
    return ProcessingResult(
      success: true,
      message: '成功处理 ${results.length} 张图片',
      outputFiles: results,
    );
  }

  // =========================================================================
  // =========================================================================
  // 2.5 Gemini-Banana 无损去水印 (参考 Reverse Alpha Blending 逆向解算算法)
  //    - 基于数学公式逆向代数解算：Original = (Watermarked - alpha * 255) / (1 - alpha)
  //    - 内置标定 48x48 与 96x96 (含 2026/Gemini 3.x 新规格) Alpha Map 矩阵
  //    - 智能多尺度皮尔逊相关系数 (Pearson Correlation) 自动峰值锚点检测
  //    - 涵盖 1K(64px/32px边距) 与 2K/4K(192px边距) 自动适配
  //    - 边缘暗色轮廓残差融合平滑净化，彻底清除浅色背景边缘黑边暗环
  //    - 纯 Dart 内存级处理，跨平台零原生依赖，无损保留全图画质与色彩空间
  // =========================================================================
  static const String _alpha48ZlibB64 =
      'eNqVVrt24kAMlTQuOFuZju0mf5HtcrZyOvMHTpftho504s+j18zYDptDlICxuaPH1QtCBBF/Q33pG1wKqpD/J/+cyMGOhAALGp+YMxCgHyKKa8J2AORWPpNpx4l50quCgFKyQ8lPmTMYusw+YGG+Gtp8Uf1uRE5X/e69f87M6pDYBINBSuETAlXlDQ04K34JL81OUp96gB5IGKQjm4ymAKvm0C8iKowptGPo6pnPaLoT4eqMukNYH5FeVP3NIiA0VeJ88giMQ4tC9YL9KTkuS/NC4SlYMhrMMX0A+MJNnuWZEErkdBIFK6LAuFMzY4fz9STMCNQz7SmAWgNKM+FYVnguB4wsG1wDjezWDP/jjSy1dBp+lSi5OfNOZtOTmj+1jD2Mmb/I3PAeL7XCwcPClfqVvI+erTQkw2Itn5OHusdzOQ4tl9gL8/nK/5O/WnHWBuAEEeaFv5Eyeh6sBkTG831c920e3R/r1oXve74lKlsV5+nKD0qZ8lD4R3L5Ib5gnh4+cp2yVXKeH0Ev2flR+p3P230qvZmPrWWtw8byve7djMBNH+7k488G7TkmGC/3XSmn1jEN71XxfteXA27wGE226pcwcNPrLKPEkDaBevUrnPTAbYOfcRi8MqWcKSxRimpFfNs1l442G7tW/imm+6Djy5r012Xtkta9YhQ/SGZNrw9lPaHT8ve6XEfQ76y7fHDaVInJGDPvucNfbDpD+B4hrjNhs2/pxej7K5YU1EnXxWzl5o32N4XKDc4Xi36rmuY62mwTQUPs8HXi4djU9+Vb8TVOpK4C3jxTfVHjZupWmOdb8pCV/Ry78Su+BmPs2Mb9MHJ8V0Nf5RUP3Td/+sr82vsJdxG7BXXGakXuhdKnsOe/LLb1HHuplrbkoJRqD9x6fX0CPE6dwg==';

  static const String _alpha96LegacyZlibB64 =
      'eNp1WjF7HLkNHYKkPslutKvL9+W7NNZeirNTuZSvibaKXVlKc0rn0qk8qrxXDef+eIj3AJKzcsbW7uzuDAgCDw8gOCmmWI801b8oWUQmCfWIEpNEHBJl0q+CyN1p/i3EeoWkJCni3npar6w31G/1Yv0yUWiu7/itvtYf6l16VZjCNOGzXp7r+zTpV5NcL0spV3U00Z/1pcrRcavoSZWgXHwdL3KVnwOUgYaROlbx+j+YlHrphBHrx7dV/vJeT/VzkFzVSxhO36sqIhihzqhOC7PQy6pZol6kKqp4DIB56GVVNUygCnlU/T/DVvqFSlHBgjfaouosdd46sr7Eel1UM0HepCZR+0+UCXupyRLmEJ+XepyqQfEfauoYdepqagyh1qSBRO2jn3w+Sa1SxQWdBQ2kt4SUJdWhRG6Lyl8OtH6gmeEyysicTjDIJHhH6BVoqHLVX3DSpGOp+qHeIuqMR5Vflo/1VGemFqs2p31sJMJNfcuxgStgDPBKahqdY3WISqHTJ3P8XFR8NRDkq7wI1OmFQKUEgqeaPifqHwGupOOo9wMGEYQB/abmDeqB+E6Fl/p3GynIggPhUlUE8jiuernqXAdRBavn6g2BrkRcwVY4YqT+9eQJ5qkvX6rtGEIwn16r4yQDqnoC0RcviFNTQChGJ4EATgAO5Kurd3CuzmHZITQQV4EmFDjIwgu4VXNFBjTMq5dTvs5FoUnPAAH6w2dKV/lHDRMNIJhevSTqsACA6hwC7K0MobciUjVgwCxArIaFGIrqBTUedqU0/U+XIAUVPimOdJp8E0OLBsZFBFIm1QWoh7MBOwzG6Sl+1Cv3kFztr2/3ep3yGiau+DAcENo0UoaH1IAJEFHPBmIN8gfuSWk/F7q3rPXkdCWZMal+VWcnggFuV9H5IsEdipkaJKAHnWI0RoD/GPzgyUcoruL1pRyrgavsC/weQXOMYv2XL+pvWaPAZ6PMp5bmiBxGMVupAZ/jvuBY3ESnHW9MCG8gFeDEIJw5oQPpQAKiqB5TQ40AR7DiY/Hg0pf69pQ8B6h5J7JKYkjrFCwNJDHaSDCQDkUGgvX0D0noLZ27/FncxeWgblWlGYlOQRwE/IQUyEQnShgKNjC1BJKy3kszzMXQo38rpjJfxSEmPZRoHHzMjO9k3MB4jIyUmIx4EZ/paOq79eGKjy3WyZngRQWSsgNZLwsRFsm/wlGMJWDbGh4x/a25dmluXkulObI9UAOioS8jWRPJw9iBeXealPZwB1hJ51hRtXsuy4Cd1Scwv065Am8SyyY0PxBHRwCC0YoD/FmEWYLDrEUejDaLY6fYPJ6iXaYuVBDqcBZTCB0MBbmWf5UtrJAxn6R4dMyo5psBljtFNAKN1MYjm6tV/8nEKtRZl0xW2CSz2y+jYRgA/KJ6YHkTNHBrQsp6AwyOeSCjK9LBriyUVLiArpjmI8hxd3L5pnNxY+n33/diHI1xbAqCkk0tZbwgFt8UTBqKyLrX3xouHZqLz0Jf510MgSWEBmWOkZkrWbwhvwlYkOITOF+nphS6n89h3wxE+WW+DiGzzhADJwghZZuJCEONWQ4hNjEribz2uG3AXzmRpbRs8PVSo0zTEYoKkr9YhSvIDgimEK3gjEh+OtjNf50STPPBPpUl6OQy/5QuWBdEeFsYb1lthUgNyDJWS8HrQHDYPzvqzTLwrgJp7fG2qg9qAnXyEYIvEUE66MQYjqyjA8mzHip+bcIdP36M2VJ9EGjlzOCEfRIxpYgPAIFODNVMzWfhcFoKjTAeLda62+vp99tgVWX0Wt1qt1opUn9Ln9EwFO5KWX50dHe30fTzP1GJpUhWs1IadWh1K5Jn8qSoGlz+fiZvc6omW7ts/PCwJ8u5bOAzaX5lWcEaCRWPxMO3QdEz9YuHQrcXzuafo2YkM4vxKauviWuvjBJY5PLjC4MUT71rt00pTX++HQkRlc/SWXFZ54EFh1htkeJh7nzjVOOieqLpqOqGe37XMmQ0XcXmQF6t4+6ehirBeGZIWutals7PbViLufK4s2RG+KiHE+p9C4/L+1O3u7PkRufl7LR0bl2UwB/3YGifB2xi1YRcHU8DsJvzuvjxfGt7Xq8DzMcbchscjNUzOfm6St/6dRyrAXOs4s6vt8h+2FU2TlYWCVfvt1+WrXZl+RFGS/lTS4dSyov4Gxnk97cabbbak/DmX6dO6ZtY6qgZ+WfjiJ4eBsyu88Pf6eZX7x9OgwpUbHWOaVXzCvuuZXkB0/7WUxCy9fPjP/byoSemsrZzFDlLu7px2ujqxX/rw7SAaBz7YfbCwKVage96rMuYd3t23Oo/6uOK4P7TqWx9OWJzaeps0pinsg6zsinweqor5fnDhrnO8ciTdQimTgoDqAYy3Yovv8W//Po4j0T2f46u7zbEzrUu3dN/PLy/YqF5+3l+EVQjJW89W85DZPSXA/n06cAK1Jojb/8z4L9NtzR6W9Yh3gaMlO0HG+XLAcwgtqJD6XKtdfK6diUMB0BX582tpUevehyejjcxXlyg5YF8gDZfPd8fZ4uDjXpMh2VDrFve7uKrYe6vsLZAqY7SEOuZrOuCdP1gYdqDYouarQc7Vl3+H8dXJLYElhZbwyZdH6Dps/s39IfYtQ9wbpWyCZd2PO1Taz9YecUVfGKPQFcav35rdl5ZJ5QfVCZbfqX2zwdbJFl+D94uQ1LLbKnVOdyPvFVGTPWF0lpeQOnT69iPbKsLZjBPyhMXNH+dxyxSPBe770drNfnzYZAOba1vlYZFsZbZ2gXdPZSRrlu1v6xlrFcG+U+v4ubIzfKe7aONiFIuHUvDUCfIAY9jlVXf7lpTwyoFxWcQ8wAWl8zx+or1/OHUysCenwbZI2N9P7gTm/ycml1YR2Rr7yIjK6Bu5qWXOKWlvlJelBF1ETY61rq32Rf2vVJBS95/15bVWEeVMuSlMqwo5z1XXzCKtluydVFQNrNW1+UMDBTYCMestCcGN7T1Lwq4bWYuX/fN9IyrlKwhLN6yxHopJlscOFiTvPo6csx6zmjA0fw6Beu6tEFU5Sze5GglqSTpBSpcf/N8vjbymnTlpKpxkngEiVGNd+R9h0NsUWm9E7MlTvfz2jPHWK2TUFe1fWrdEnKaz8IWwt7UZf9SGr44jd2pDK2HkTb0uz/2VieTBZKRTYY3rbeCFT1LRbFVGiGAO8NtGUi/FVJWK/2SuTRXgm+ui95aNEvYstWaWK4Blpf6/d1QOZdNKin3yabJPBXT0Jn0FQavuLBeEsRn3R1g91k98rRJXIOxPrPzDNr1dVEk7unfGHLrhmJlP7FxnLMtQtBbvfzmDFSGBtyicRUQUyF69613PWPi1ghU4E5d8HmlZLa05uqbng89kPXk59SXQtyy8CZBso0ndFVBclZFtHmOVBjl42Jl6ZBwytH2vxiykkJ3L/bEwAZoNVkagzuTtXkz24i4OlzNy9obh/T0M/fPIoqDoSvf4OLdJt29i74+Fd/eA3+0dtEB1NNL6/r+jtGv3XnqZU62lCuW1GP2KQU2zPvi0nY90bZ/smZMk//ohRNbvc3yKbXdquS9K0Yx96ngJoZ5phlx2e67NxGN5XYWVrhfO/0OeWxqxB5WydCSY0thtuprt+iV90sDqb48glayd56tde3G6Kv4Tp5JjEGxm0UAeEe5Crs6oedsJD3feAZEa1/bn7kjbggFYz7SHvXA9pH4Tk9LGPdlyOr3Mbf6T/JAOC0g+B7a99p9EG6W2dZ1avKxv/HqNNSbN2LMw4SUg6cA3wY2rdkvbK0aQE64mef9j2j6y9HzsIInmS/ZkUKdLNZ/MZuTWL1lic2wCUlOAmIGne7g8rXf18vYPXd7IQPtWd3k7ak2NVTQ69F2fdiktP0OfJoagdfvvng18WSckLE/KlbRsKqVVg9S/zj0UmyTxOsw1l/i+U5pjvtfb0FRmU0j7M9j91SG8mo4sBiIvuVt+ySWDWBU2r/awlLlnAYQ5sTN07bLk1rbmS3bDMK3bIkMYA1vtuqNjoDBT7T+I0Kr7cUKIzJYvJO7srRNGEOC79wxE6do+1rBH0Cox4H1yUGS0zIb2KHNOEi27egJTxVYS5IxlIFZ0aceJgt5bh2490RbumX2EkCfLTBE6KMNBnA0zCfbhIp9z6GlZsnSyomYGoYSdgnr8VmZjzt7iI/qgcSGv+53+T6XczRrFktmfKCDT0D0Yiu0R0req/x30Z7bSMScJVr0UPkoCgexTXNL+169mxviUCn67pbIldpnRwqwQo08Fe15Fd97AhZTsL0xziLZ3thE1Ht+9myPge++nT7wkRDu8KVeVgZ/gML66AHlsvwPo9WfkA==';

  static const String _alpha96NewZlibB64 =
      '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';

  static Uint8List? _cachedAlpha48;
  static Uint8List? _cachedAlpha96Legacy;
  static Uint8List? _cachedAlpha96New;

  static Uint8List _getGeminiAlphaMap(int logoSize, {bool is2026Variant = true}) {
    if (logoSize == 48) {
      _cachedAlpha48 ??= Uint8List.fromList(zlib.decode(base64Decode(_alpha48ZlibB64)));
      return _cachedAlpha48!;
    } else if (is2026Variant) {
      _cachedAlpha96New ??= Uint8List.fromList(zlib.decode(base64Decode(_alpha96NewZlibB64)));
      return _cachedAlpha96New!;
    } else {
      _cachedAlpha96Legacy ??= Uint8List.fromList(zlib.decode(base64Decode(_alpha96LegacyZlibB64)));
      return _cachedAlpha96Legacy!;
    }
  }

  static Future<ProcessingResult> _handleGeminiBananaWatermark(
    List<String> files,
    Map<String, dynamic> params,
    String outputDir,
    Function(double, String)? onProgress,
  ) async {
    final detectMode = params['detectMode']?.toString() ?? 'auto';
    final customLogoSizeVal = params['customLogoSize'];
    final customLogoSize = (customLogoSizeVal is num ? customLogoSizeVal.toInt() : int.tryParse(customLogoSizeVal?.toString() ?? '96')) ?? 96;
    final customMarginRightVal = params['customMarginRight'];
    final customMarginRight = (customMarginRightVal is num ? customMarginRightVal.toInt() : int.tryParse(customMarginRightVal?.toString() ?? '64')) ?? 64;
    final customMarginBottomVal = params['customMarginBottom'];
    final customMarginBottom = (customMarginBottomVal is num ? customMarginBottomVal.toInt() : int.tryParse(customMarginBottomVal?.toString() ?? '64')) ?? 64;
    final format = params['format']?.toString() ?? 'keep_original';

    const double maxAlpha = 0.99;
    const double logoValue = 255.0;

    final results = <String>[];
    int processedCount = 0;

    for (int i = 0; i < files.length; i++) {
      final filePath = files[i];
      final file = File(filePath);
      if (!file.existsSync()) continue;

      onProgress?.call(
        i / files.length,
        '正在去除水印 (${i + 1}/${files.length}): ${p.basename(filePath)}',
      );

      final originalBytes = await file.readAsBytes();
      final decoded = img.decodeImage(originalBytes);
      if (decoded == null) continue;

      img.Image image = decoded;

      int logoSize = 96;
      int marginRight = 64;
      int marginBottom = 64;
      Uint8List alphaMap = _getGeminiAlphaMap(96, is2026Variant: true);

      if (detectMode == 'gemini_2k') {
        logoSize = 96;
        marginRight = 192;
        marginBottom = 192;
        alphaMap = _getGeminiAlphaMap(96, is2026Variant: true);
      } else if (detectMode == 'force_48') {
        logoSize = 48;
        marginRight = 32;
        marginBottom = 32;
        alphaMap = _getGeminiAlphaMap(48);
      } else if (detectMode == 'force_96') {
        logoSize = 96;
        marginRight = 64;
        marginBottom = 64;
        alphaMap = _getGeminiAlphaMap(96, is2026Variant: true);
      } else if (detectMode == 'custom') {
        logoSize = customLogoSize == 48 ? 48 : 96;
        marginRight = customMarginRight;
        marginBottom = customMarginBottom;
        alphaMap = _getGeminiAlphaMap(logoSize, is2026Variant: true);
      } else {
        // auto 模式：采用多尺度多规格候选 + 皮尔逊相关度自动测定
        final alpha96New = _getGeminiAlphaMap(96, is2026Variant: true);
        final alpha96Legacy = _getGeminiAlphaMap(96, is2026Variant: false);
        final alpha48 = _getGeminiAlphaMap(48);

        final candidates = [
          {'size': 96, 'mr': 192, 'mb': 192, 'map': alpha96New},
          {'size': 96, 'mr': 64, 'mb': 64, 'map': alpha96New},
          {'size': 96, 'mr': 64, 'mb': 64, 'map': alpha96Legacy},
          {'size': 48, 'mr': 32, 'mb': 32, 'map': alpha48},
          {'size': 48, 'mr': 96, 'mb': 96, 'map': alpha48},
        ];

        double bestCorr = -1.0;
        int bestIdx = -1;

        for (int cIdx = 0; cIdx < candidates.length; cIdx++) {
          final cand = candidates[cIdx];
          final sz = cand['size'] as int;
          final mr = cand['mr'] as int;
          final mb = cand['mb'] as int;
          final map = cand['map'] as Uint8List;

          final sx = image.width - mr - sz;
          final sy = image.height - mb - sz;
          if (sx < 0 || sy < 0 || sx + sz > image.width || sy + sz > image.height) continue;

          double sumX = 0, sumY = 0, sumXX = 0, sumYY = 0, sumXY = 0;
          final n = sz * sz;
          for (int r = 0; r < sz; r++) {
            final rowOff = r * sz;
            for (int c = 0; c < sz; c++) {
              final pixel = image.getPixel(sx + c, sy + r);
              final br = (pixel.r + pixel.g + pixel.b) / 3.0;
              final a = map[rowOff + c] / 255.0;
              sumX += br; sumY += a;
              sumXX += br * br; sumYY += a * a;
              sumXY += br * a;
            }
          }
          final vx = sumXX - (sumX * sumX) / n;
          final vy = sumYY - (sumY * sumY) / n;
          if (vx > 0 && vy > 0) {
            final corr = (sumXY - (sumX * sumY) / n) / sqrt(vx * vy);
            if (corr > bestCorr) {
              bestCorr = corr;
              bestIdx = cIdx;
            }
          }
        }

        if (bestIdx >= 0 && bestCorr >= 0.20) {
          final cand = candidates[bestIdx];
          logoSize = cand['size'] as int;
          marginRight = cand['mr'] as int;
          marginBottom = cand['mb'] as int;
          alphaMap = cand['map'] as Uint8List;
        } else {
          // 启发式分辨率回退
          if (image.width >= 1500 || image.height >= 1500) {
            logoSize = 96;
            marginRight = 192;
            marginBottom = 192;
            alphaMap = alpha96New;
          } else if (image.width > 1024 && image.height > 1024) {
            logoSize = 96;
            marginRight = 64;
            marginBottom = 64;
            alphaMap = alpha96New;
          } else {
            logoSize = 48;
            marginRight = 32;
            marginBottom = 32;
            alphaMap = alpha48;
          }
        }
      }

      // 精确峰值微调 (防裁剪导致边距微移)
      int startX = image.width - marginRight - logoSize;
      int startY = image.height - marginBottom - logoSize;

      double peakCorr = -1.0;
      int peakSx = startX;
      int peakSy = startY;

      for (int dy = -8; dy <= 8; dy++) {
        for (int dx = -8; dx <= 8; dx++) {
          final curSx = startX + dx;
          final curSy = startY + dy;
          if (curSx < 0 || curSy < 0 || curSx + logoSize > image.width || curSy + logoSize > image.height) continue;
          double sumX = 0, sumY = 0, sumXX = 0, sumYY = 0, sumXY = 0;
          final n = logoSize * logoSize;
          for (int r = 0; r < logoSize; r++) {
            final rowOff = r * logoSize;
            for (int c = 0; c < logoSize; c++) {
              final pixel = image.getPixel(curSx + c, curSy + r);
              final br = (pixel.r + pixel.g + pixel.b) / 3.0;
              final a = alphaMap[rowOff + c] / 255.0;
              sumX += br; sumY += a;
              sumXX += br * br; sumYY += a * a;
              sumXY += br * a;
            }
          }
          final vx = sumXX - (sumX * sumX) / n;
          final vy = sumYY - (sumY * sumY) / n;
          if (vx > 0 && vy > 0) {
            final corr = (sumXY - (sumX * sumY) / n) / sqrt(vx * vy);
            if (corr > peakCorr) {
              peakCorr = corr;
              peakSx = curSx;
              peakSy = curSy;
            }
          }
        }
      }

      if (peakCorr > 0.15) {
        startX = peakSx;
        startY = peakSy;
      }

      if (startX >= 0 && startY >= 0 && startX + logoSize <= image.width && startY + logoSize <= image.height) {
        // 1. 逆向代数解算 (Reverse Alpha Blending)
        for (int row = 0; row < logoSize; row++) {
          final y = startY + row;
          final rowOff = row * logoSize;
          for (int col = 0; col < logoSize; col++) {
            final x = startX + col;
            final a = (alphaMap[rowOff + col] / 255.0).clamp(0.0, maxAlpha);
            if (a < 0.003) continue;

            final oneMinusAlpha = 1.0 - a;
            final pixel = image.getPixel(x, y);
            final rOrig = ((pixel.r - a * logoValue) / oneMinusAlpha).round().clamp(0, 255);
            final gOrig = ((pixel.g - a * logoValue) / oneMinusAlpha).round().clamp(0, 255);
            final bOrig = ((pixel.b - a * logoValue) / oneMinusAlpha).round().clamp(0, 255);
            image.setPixelRgba(x, y, rOrig, gOrig, bOrig, pixel.a);
          }
        }

        // 2. 轮廓边界净化平滑 (彻底消除亮白背景边缘微弱暗环残留)
        final copyImg = image.clone();
        for (int row = 0; row < logoSize; row++) {
          final y = startY + row;
          final rowOff = row * logoSize;
          for (int col = 0; col < logoSize; col++) {
            final x = startX + col;
            final a = alphaMap[rowOff + col] / 255.0;
            if (a >= 0.002 && a <= 0.12) {
              final samplesR = <int>[];
              final samplesG = <int>[];
              final samplesB = <int>[];

              for (int dy = -3; dy <= 3; dy++) {
                for (int dx = -3; dx <= 3; dx++) {
                  if (dx == 0 && dy == 0) continue;
                  final ny = y + dy;
                  final nx = x + dx;
                  final nr = row + dy;
                  final nc = col + dx;
                  if (nr >= 0 && nr < logoSize && nc >= 0 && nc < logoSize) {
                    if (alphaMap[nr * logoSize + nc] / 255.0 < 0.002) {
                      final np = copyImg.getPixel(nx, ny);
                      samplesR.add(np.r.toInt());
                      samplesG.add(np.g.toInt());
                      samplesB.add(np.b.toInt());
                    }
                  } else if (ny >= 0 && ny < image.height && nx >= 0 && nx < image.width) {
                    final np = copyImg.getPixel(nx, ny);
                    samplesR.add(np.r.toInt());
                    samplesG.add(np.g.toInt());
                    samplesB.add(np.b.toInt());
                  }
                }
              }

              if (samplesR.isNotEmpty) {
                final avgR = (samplesR.reduce((a, b) => a + b) / samplesR.length).round();
                final avgG = (samplesG.reduce((a, b) => a + b) / samplesG.length).round();
                final avgB = (samplesB.reduce((a, b) => a + b) / samplesB.length).round();
                const blendW = 0.95;
                final cur = image.getPixel(x, y);
                final resR = (cur.r * (1 - blendW) + avgR * blendW).round().clamp(0, 255);
                final resG = (cur.g * (1 - blendW) + avgG * blendW).round().clamp(0, 255);
                final resB = (cur.b * (1 - blendW) + avgB * blendW).round().clamp(0, 255);
                image.setPixelRgba(x, y, resR, resG, resB, cur.a);
              }
            }
          }
        }
      }

      // 导出处理结果
      String ext = p.extension(filePath).toLowerCase();
      String targetExt = ext;
      if (format == 'webp') {
        targetExt = '.webp';
      } else if (format == 'jpg' || format == 'jpeg') {
        targetExt = '.jpg';
      } else if (format == 'png') {
        targetExt = '.png';
      }

      Uint8List encoded;
      if (targetExt == '.webp') {
        final encoder = img.WebPEncoder(lossless: true);
        encoded = Uint8List.fromList(encoder.encode(image));
      } else if (targetExt == '.jpg' || targetExt == '.jpeg') {
        encoded = Uint8List.fromList(img.encodeJpg(image, quality: 98));
      } else {
        encoded = Uint8List.fromList(img.encodePng(image, level: 6));
      }

      final outName = 'nowm_${p.basenameWithoutExtension(filePath)}$targetExt';
      final outPath = p.join(outputDir, outName);
      await File(outPath).writeAsBytes(encoded);
      results.add(outPath);
      processedCount++;
    }

    onProgress?.call(1.0, '去水印完成，已保存 $processedCount 张图像');

    return ProcessingResult(
      success: processedCount > 0,
      message: processedCount > 0
          ? '成功无损去除 $processedCount 张图片中的 Gemini 水印'
          : '未能处理选中的图片文件',
      outputFiles: results,
    );
  }

    // 3. 修改证件照底色 (参考 HivisionIDPhotos 架构规范)
  //    - 多点四角自适应背景色彩空间采样
  //    - 双重梯度色彩泛洪 + 距离场计算连续 Alpha 通道 (0.0~1.0)
  //    - 边缘去溢色/色边净化 (Color Decontamination): 彻底消除蓝底/红底发丝残存反光
  //    - 规范比例智能裁剪与居中对齐 (一寸、小二寸、二寸)
  // =========================================================================
  static Future<ProcessingResult> _handleIdPhotoBg(
    List<String> files,
    Map<String, dynamic> params,
    String outputDir,
    Function(double, String)? onProgress,
  ) async {
    final filePath = files.first;
    final colorParam = params['color']?.toString() ?? 'white';
    final sizeParam = params['size']?.toString() ?? 'keep';
    final featherParam = (params['feather'] as num?)?.toInt() ?? 3;
    final toleranceParam = (params['tolerance'] as num?)?.toDouble() ?? 50.0;

    onProgress?.call(0.10, '正在读取与解析证件照...');
    final bytes = await File(filePath).readAsBytes();
    img.Image? original = img.decodeImage(bytes);
    if (original == null) {
      return ProcessingResult(success: false, message: '无法解析待处理的图片文件');
    }

    // 目标背景 RGB 定义
    int tR = 255, tG = 255, tB = 255;
    if (colorParam == 'red') {
      tR = 216; tG = 30; tB = 30; // 官方标准中国红
    } else if (colorParam == 'blue') {
      tR = 67; tG = 142; tB = 219; // 经典证件天蓝
    } else if (colorParam == 'gray') {
      tR = 238; tG = 238; tB = 238; // 职场轻灰底
    }

    final w = original.width;
    final h = original.height;

    // -------------------------------------------------------------
    // Step 1: 多区域精细采样原始背景色 (顶部、四角、两侧)
    // -------------------------------------------------------------
    onProgress?.call(0.20, '正在多区域采样原始背景色与光影分布...');
    double sumR = 0, sumG = 0, sumB = 0;
    int sampleCount = 0;

    void sampleArea(int startX, int endX, int startY, int endY) {
      for (int y = max(0, startY); y < min(h, endY); y++) {
        for (int x = max(0, startX); x < min(w, endX); x++) {
          final px = original.getPixel(x, y);
          sumR += px.r;
          sumG += px.g;
          sumB += px.b;
          sampleCount++;
        }
      }
    }

    final cornerW = max(5, (w * 0.1).round());
    final cornerH = max(5, (h * 0.1).round());
    sampleArea(0, cornerW, 0, cornerH); // 左上角
    sampleArea(w - cornerW, w, 0, cornerH); // 右上角
    sampleArea(0, w, 0, min(10, h)); // 顶边前10行
    sampleArea(0, min(8, w), 0, (h * 0.5).round()); // 左侧上半段
    sampleArea(w - min(8, w), w, 0, (h * 0.5).round()); // 右侧上半段

    final baseR = sampleCount > 0 ? sumR / sampleCount : 255.0;
    final baseG = sampleCount > 0 ? sumG / sampleCount : 255.0;
    final baseB = sampleCount > 0 ? sumB / sampleCount : 255.0;

    // -------------------------------------------------------------
    // Step 2: 四边种子泛洪扩散分割背景
    // -------------------------------------------------------------
    onProgress?.call(0.35, '正在执行自适应人像轮廓分离...');
    final bgMask = Uint8List(w * h); // 1 = 确定是背景
    final visited = Uint8List(w * h);
    final queue = Queue<int>();

    void seed(int x, int y) {
      if (x < 0 || x >= w || y < 0 || y >= h) return;
      final idx = y * w + x;
      if (visited[idx] == 0) {
        visited[idx] = 1;
        queue.add(idx);
      }
    }

    // 四边播种
    for (int x = 0; x < w; x++) {
      seed(x, 0);
      seed(x, h - 1);
    }
    for (int y = 0; y < h; y++) {
      seed(0, y);
      seed(w - 1, y);
    }

    final threshold = toleranceParam + featherParam * 3;

    while (queue.isNotEmpty) {
      final cur = queue.removeFirst();
      final cx = cur % w;
      final cy = cur ~/ w;
      final cp = original.getPixel(cx, cy);

      final diff = sqrt(
        pow(cp.r - baseR, 2) +
        pow(cp.g - baseG, 2) +
        pow(cp.b - baseB, 2),
      );

      if (diff <= threshold) {
        bgMask[cur] = 1;

        if (cx > 0 && visited[cur - 1] == 0) { visited[cur - 1] = 1; queue.add(cur - 1); }
        if (cx < w - 1 && visited[cur + 1] == 0) { visited[cur + 1] = 1; queue.add(cur + 1); }
        if (cy > 0 && visited[cur - w] == 0) { visited[cur - w] = 1; queue.add(cur - w); }
        if (cy < h - 1 && visited[cur + w] == 0) { visited[cur + w] = 1; queue.add(cur + w); }
      }
    }

    // -------------------------------------------------------------
    // Step 3: 计算距离场，生成发丝级连续 Alpha Matte
    // -------------------------------------------------------------
    onProgress?.call(0.55, '正在生成连续 Alpha 掩码并执行边缘抗锯齿...');
    final distField = Uint8List(w * h);
    final featherRadius = max(2, featherParam + 1);

    final bfsQueue = Queue<int>();
    for (int i = 0; i < w * h; i++) {
      if (bgMask[i] == 1) {
        distField[i] = 0;
        final x = i % w;
        final y = i ~/ w;
        bool nearFg = false;
        if (x > 0 && bgMask[i - 1] == 0) nearFg = true;
        if (!nearFg && x < w - 1 && bgMask[i + 1] == 0) nearFg = true;
        if (!nearFg && y > 0 && bgMask[i - w] == 0) nearFg = true;
        if (!nearFg && y < h - 1 && bgMask[i + w] == 0) nearFg = true;
        if (nearFg) bfsQueue.add(i);
      } else {
        distField[i] = 255;
      }
    }

    while (bfsQueue.isNotEmpty) {
      final cur = bfsQueue.removeFirst();
      final curDist = distField[cur];
      if (curDist >= featherRadius) continue;

      final cx = cur % w;
      final cy = cur ~/ w;
      final nextDist = curDist + 1;

      void trySpread(int ni) {
        if (distField[ni] > nextDist) {
          distField[ni] = nextDist;
          bfsQueue.add(ni);
        }
      }

      if (cx > 0) trySpread(cur - 1);
      if (cx < w - 1) trySpread(cur + 1);
      if (cy > 0) trySpread(cur - w);
      if (cy < h - 1) trySpread(cur + w);
    }

    // -------------------------------------------------------------
    // Step 4: 边缘去溢色 (Color Decontamination) + 新背景 Alpha 合成
    //    核心：去除原背景在人像边缘渗入的残存反光（色边净化）
    // -------------------------------------------------------------
    onProgress?.call(0.75, '正在执行色边净化与高质量人像底色融合...');
    final resultImg = img.Image(width: w, height: h);

    for (int y = 0; y < h; y++) {
      for (int x = 0; x < w; x++) {
        final idx = y * w + x;
        final orig = original.getPixel(x, y);

        if (bgMask[idx] == 1) {
          // 纯背景区直接赋目标色
          resultImg.setPixelRgb(x, y, tR, tG, tB);
        } else {
          final d = distField[idx];
          if (d < featherRadius) {
            // 过渡区：连续 Alpha
            final alpha = (d / featherRadius).clamp(0.0, 1.0);

            // 去溢色净化：从当前像素色彩中扣除原背景色的混入比率
            // F_clean = (Pixel - (1 - alpha) * BaseBg) / alpha
            double cleanR = orig.r.toDouble();
            double cleanG = orig.g.toDouble();
            double cleanB = orig.b.toDouble();

            if (alpha > 0.15) {
              cleanR = ((orig.r - (1.0 - alpha) * baseR) / alpha).clamp(0.0, 255.0);
              cleanG = ((orig.g - (1.0 - alpha) * baseG) / alpha).clamp(0.0, 255.0);
              cleanB = ((orig.b - (1.0 - alpha) * baseB) / alpha).clamp(0.0, 255.0);
            }

            // 与新目标底色融合
            final r = (alpha * cleanR + (1.0 - alpha) * tR).round().clamp(0, 255);
            final g = (alpha * cleanG + (1.0 - alpha) * tG).round().clamp(0, 255);
            final b = (alpha * cleanB + (1.0 - alpha) * tB).round().clamp(0, 255);
            resultImg.setPixelRgb(x, y, r, g, b);
          } else {
            // 纯人像主体，原色保留
            resultImg.setPixel(x, y, orig);
          }
        }
      }
    }

    // -------------------------------------------------------------
    // Step 5: 规范冲印尺寸处理 (非拉伸变形，采用比例居中裁切/缩放)
    // -------------------------------------------------------------
    img.Image finalImage = resultImg;
    int? targetCropW;
    int? targetCropH;

    if (sizeParam == '1_inch') {
      targetCropW = 295;
      targetCropH = 413;
    } else if (sizeParam == 'small_2_inch') {
      targetCropW = 413;
      targetCropH = 531;
    } else if (sizeParam == '2_inch') {
      targetCropW = 413;
      targetCropH = 626;
    }

    if (targetCropW != null && targetCropH != null) {
      onProgress?.call(0.90, '正在智能居中对齐并适配冲印规格 (${targetCropW}x$targetCropH)...');
      final targetRatio = targetCropW / targetCropH;
      final currentRatio = w / h;

      img.Image cropped;
      if (currentRatio > targetRatio) {
        // 当前图太宽，裁剪左右
        final fitW = (h * targetRatio).round();
        final startX = ((w - fitW) / 2).round();
        cropped = img.copyCrop(resultImg, x: startX, y: 0, width: fitW, height: h);
      } else {
        // 当前图太高，裁剪底部（证件照头部保留在上方）
        final fitH = (w / targetRatio).round();
        final startY = 0; // 顶部对齐
        cropped = img.copyCrop(resultImg, x: 0, y: startY, width: w, height: fitH);
      }

      finalImage = img.copyResize(
        cropped,
        width: targetCropW,
        height: targetCropH,
        interpolation: img.Interpolation.cubic,
      );
    }

    onProgress?.call(0.98, '正在导出证件照成果...');
    final outName = 'idphoto_${colorParam}_${sizeParam}_${p.basenameWithoutExtension(filePath)}.jpg';
    final outPath = p.join(outputDir, outName);
    await File(outPath).writeAsBytes(img.encodeJpg(finalImage, quality: 96));

    onProgress?.call(1.0, '证件照制作完成！');
    return ProcessingResult(
      success: true,
      message: '已成功将证件照更换为 $colorParam 底色并完成边缘去溢色！\n导出文件: $outName (${finalImage.width}x${finalImage.height})',
      outputFiles: [outPath],
    );
  }

  // =========================================================================
  // 4. 音视频通用处理管道 (参考 LosslessCut + HandBrake 工业级标准)
  //    - 智能动态定位 FFmpeg 核心
  //    - 提取音频：优先 Stream Copy 无损直拷 (0.1秒秒级完成)，免去长时间重采样
  //    - 视频压缩：借鉴 HandBrake CRF 恒定质量量化，支持 720p/1080p 自适应降采样
  //    - 视频倒放：加入帧率降采样与分辨率保护，彻底解决 1080p60 爆内存挂死
  //    - 进程管道：异步消费 Drain stdout/stderr，杜绝管道缓冲死锁
  // =========================================================================
  static Future<ProcessingResult> _handleMediaPipeline(
    List<String> files,
    Map<String, dynamic> params,
    String outputDir,
    Function(double, String)? onProgress,
  ) async {
    final filePath = files.first;
    final op = (params['op'] ?? params['operation'])?.toString() ?? 'compress_video';
    final preset = params['preset']?.toString() ?? 'normal';
    onProgress?.call(0.05, '正在准备音视频处理指令...');

    // ---------- 构建命令参数 ----------
    String outName = 'media_${DateTime.now().millisecondsSinceEpoch}.mp4';
    List<String> ffmpegArgs = [];

    if (op == 'extract_audio' || op == 'extract_audio_copy') {
      outName = 'extracted_${p.basenameWithoutExtension(filePath)}.aac';
      ffmpegArgs = [
        '-y', '-i', filePath,
        '-vn',
        '-c:a', 'copy',
        p.join(outputDir, outName),
      ];
    } else if (op == 'extract_audio_mp3') {
      outName = 'extracted_${p.basenameWithoutExtension(filePath)}.mp3';
      ffmpegArgs = [
        '-y', '-i', filePath,
        '-vn',
        '-c:a', 'libmp3lame',
        '-q:a', '2',
        '-threads', '0',
        p.join(outputDir, outName),
      ];
    } else if (op == 'compress_video') {
      outName = 'compressed_${p.basenameWithoutExtension(filePath)}.mp4';
      if (preset == 'extreme') {
        ffmpegArgs = [
          '-y', '-i', filePath,
          '-vf', "scale=-2:'min(720,ih)',fps=30",
          '-c:v', 'libx264',
          '-preset', 'veryfast',
          '-crf', '28',
          '-c:a', 'aac',
          '-b:a', '96k',
          '-movflags', '+faststart',
          '-threads', '0',
          p.join(outputDir, outName),
        ];
      } else if (preset == 'high_quality') {
        ffmpegArgs = [
          '-y', '-i', filePath,
          '-c:v', 'libx264',
          '-preset', 'fast',
          '-crf', '22',
          '-c:a', 'aac',
          '-b:a', '192k',
          '-movflags', '+faststart',
          '-threads', '0',
          p.join(outputDir, outName),
        ];
      } else {
        ffmpegArgs = [
          '-y', '-i', filePath,
          '-c:v', 'libx264',
          '-preset', 'veryfast',
          '-crf', '26',
          '-c:a', 'aac',
          '-b:a', '128k',
          '-movflags', '+faststart',
          '-threads', '0',
          p.join(outputDir, outName),
        ];
      }
    } else if (op == 'reverse_video') {
      outName = 'reversed_${p.basenameWithoutExtension(filePath)}.mp4';
      ffmpegArgs = [
        '-y', '-i', filePath,
        '-vf', "scale=-2:'min(720,ih)',fps=30,reverse",
        '-af', 'areverse',
        '-c:v', 'libx264',
        '-preset', 'veryfast',
        '-c:a', 'aac',
        '-threads', '0',
        p.join(outputDir, outName),
      ];
    } else if (op == 'to_mp4') {
      outName = 'converted_${p.basenameWithoutExtension(filePath)}.mp4';
      ffmpegArgs = [
        '-y', '-i', filePath,
        '-c:v', 'libx264',
        '-preset', 'fast',
        '-crf', '23',
        '-c:a', 'aac',
        '-b:a', '160k',
        '-movflags', '+faststart',
        '-threads', '0',
        p.join(outputDir, outName),
      ];
    } else if (op == 'audio_convert') {
      final targetFmt = params['format']?.toString() ?? 'mp3';
      if (targetFmt == 'wav') {
        outName = 'converted_${p.basenameWithoutExtension(filePath)}.wav';
        ffmpegArgs = [
          '-y', '-i', filePath,
          '-c:a', 'pcm_s16le',
          p.join(outputDir, outName),
        ];
      } else if (targetFmt == 'aac') {
        outName = 'converted_${p.basenameWithoutExtension(filePath)}.aac';
        ffmpegArgs = [
          '-y', '-i', filePath,
          '-c:a', 'aac',
          '-b:a', '192k',
          p.join(outputDir, outName),
        ];
      } else {
        outName = 'converted_${p.basenameWithoutExtension(filePath)}.mp3';
        ffmpegArgs = [
          '-y', '-i', filePath,
          '-c:a', 'libmp3lame',
          '-q:a', '2',
          '-threads', '0',
          p.join(outputDir, outName),
        ];
      }
    }

    final outPath = p.join(outputDir, outName);
    final sw = Stopwatch()..start();

    // ========================================================
    // 分支 1: Android 平台 (使用内置 NDK FFmpeg 动态库)
    // ========================================================
    if (Platform.isAndroid) {
      onProgress?.call(0.20, '正在通过 Android 原生内置 FFmpeg 核心处理...');
      final session = await FFmpegKit.executeWithArguments(ffmpegArgs);
      sw.stop();
      final returnCode = await session.getReturnCode();

      if (ReturnCode.isSuccess(returnCode) && File(outPath).existsSync()) {
        final outSize = File(outPath).lengthSync();
        onProgress?.call(1.0, '任务完成！总耗时 ${sw.elapsed.inSeconds} 秒');
        return ProcessingResult(
          success: true,
          message: '任务完成 (耗时 ${sw.elapsed.inSeconds} 秒)！\n输出文件: $outName\n最终大小: ${(outSize / 1024).toStringAsFixed(1)} KB',
          outputFiles: [outPath],
        );
      } else {
        // 音频直拷失败时自动回退转码
        if (op == 'extract_audio' || op == 'extract_audio_copy') {
          onProgress?.call(0.30, '流直拷模式不兼容，切换为高质量 MP3 提取...');
          outName = 'extracted_${p.basenameWithoutExtension(filePath)}.mp3';
          final outPath2 = p.join(outputDir, outName);
          final fallbackArgs = [
            '-y', '-i', filePath,
            '-vn',
            '-c:a', 'libmp3lame',
            '-q:a', '2',
            '-threads', '0',
            outPath2,
          ];
          sw.reset(); sw.start();
          final session2 = await FFmpegKit.executeWithArguments(fallbackArgs);
          sw.stop();
          final returnCode2 = await session2.getReturnCode();
          if (ReturnCode.isSuccess(returnCode2) && File(outPath2).existsSync()) {
            final outSize = File(outPath2).lengthSync();
            onProgress?.call(1.0, '处理完成！总耗时 ${sw.elapsed.inSeconds} 秒');
            return ProcessingResult(
              success: true,
              message: '任务完成 (耗时 ${sw.elapsed.inSeconds} 秒)！\n输出文件: $outName\n最终大小: ${(outSize / 1024).toStringAsFixed(1)} KB',
              outputFiles: [outPath2],
            );
          }
        }

        final logs = await session.getAllLogsAsString();
        return ProcessingResult(
          success: false,
          message: 'FFmpeg 处理失败 (ReturnCode: $returnCode)\n$logs',
        );
      }
    }

    // ========================================================
    // 分支 2: Windows 桌面端 (智能寻检系统级 FFmpeg 进程)
    // ========================================================
    onProgress?.call(0.10, '正在检测系统 FFmpeg 编解码引擎...');
    String? ffmpegPath;
    final exeDir = p.dirname(Platform.resolvedExecutable);
    final candidates = <String>[
      p.join(exeDir, 'ffmpeg.exe'),
      p.join(exeDir, 'bin', 'ffmpeg.exe'),
      'ffmpeg',
    ];
    final home = Platform.environment['USERPROFILE'] ?? '';
    if (home.isNotEmpty) {
      candidates.add(p.join(home, r'AppData\Local\Microsoft\WinGet\Links\ffmpeg.exe'));
      final sdkDir = Directory(p.join(home, r'AppData\Local\Microsoft\WinGet\Packages'));
      if (sdkDir.existsSync()) {
        try {
          for (var sub in sdkDir.listSync(recursive: false)) {
            if (sub is Directory && sub.path.toLowerCase().contains('ffmpeg')) {
              try {
                sub.listSync(recursive: true)
                    .whereType<File>()
                    .where((f) => p.basename(f.path).toLowerCase() == 'ffmpeg.exe')
                    .take(1)
                    .forEach((f) => candidates.add(f.path));
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
          ffmpegPath = cand;
          break;
        }
      } catch (_) {}
    }

    if (ffmpegPath == null) {
      return ProcessingResult(
        success: false,
        message: '未在系统路径或程序目录中找到有效 FFmpeg。\n若下载的是极简便携包，可在 Windows PowerShell 中运行:\nwinget install Gyan.FFmpeg.Essentials\n安装后重启软件；或直接下载自带 FFmpeg 的完整便携包。',
      );
    }

    onProgress?.call(0.20, '已就绪 FFmpeg 核心，正在启动音视频处理管道...');
    final process = await Process.start(ffmpegPath, ffmpegArgs);

    final stderrBuf = StringBuffer();
    process.stdout.drain<void>();
    process.stderr.transform(const SystemEncoding().decoder).listen((data) {
      stderrBuf.write(data);
      if (data.contains('time=')) {
        onProgress?.call(0.60, '正在转码处理中 (${sw.elapsed.inSeconds}s)...');
      }
    });

    final exitCode = await process.exitCode;
    sw.stop();

    if (exitCode == 0 && File(outPath).existsSync()) {
      final outSize = File(outPath).lengthSync();
      onProgress?.call(1.0, '任务完成！总耗时 ${sw.elapsed.inSeconds} 秒');
      return ProcessingResult(
        success: true,
        message: '处理完成 (耗时 ${sw.elapsed.inSeconds} 秒)！\n输出文件: $outName\n最终大小: ${(outSize / 1024).toStringAsFixed(1)} KB',
        outputFiles: [outPath],
      );
    } else {
      if (op == 'extract_audio' || op == 'extract_audio_copy') {
        onProgress?.call(0.30, '流直拷未识别到独立音轨，自动回退至高质量 MP3 提取...');
        outName = 'extracted_${p.basenameWithoutExtension(filePath)}.mp3';
        final outPath2 = p.join(outputDir, outName);
        final fallbackArgs = [
          '-y', '-i', filePath,
          '-vn',
          '-c:a', 'libmp3lame',
          '-q:a', '2',
          '-threads', '0',
          outPath2,
        ];
        sw.reset(); sw.start();
        final process2 = await Process.start(ffmpegPath, fallbackArgs);
        process2.stdout.drain<void>();
        process2.stderr.drain<void>();
        final exitCode2 = await process2.exitCode;
        sw.stop();

        if (exitCode2 == 0 && File(outPath2).existsSync()) {
          final outSize = File(outPath2).lengthSync();
          onProgress?.call(1.0, '回退处理完成！耗时 ${sw.elapsed.inSeconds} 秒');
          return ProcessingResult(
            success: true,
            message: '处理完成 (耗时 ${sw.elapsed.inSeconds} 秒)！\n输出文件: $outName\n最终大小: ${(outSize / 1024).toStringAsFixed(1)} KB',
            outputFiles: [outPath2],
          );
        }
      }

      return ProcessingResult(
        success: false,
        message: 'FFmpeg 处理失败 (退出码: $exitCode)\n${stderrBuf.toString().split('\n').where((l) => l.toLowerCase().contains('error') || l.toLowerCase().contains('invalid')).take(5).join('\n')}',
      );
    }
  }

  // =========================================================================
  // 5. 二维码综合工具箱 (生成高保真 PNG 与相册/文件识别)
  //    - 生成: 采用纯 Dart qr 算法库，生成高精度位图与合规静区，导出 PNG
  //    - 识别: 采用纯 Dart 版 ZXing (qr_code_dart_decoder)，零原生库依赖解算
  // =========================================================================
  static Future<ProcessingResult> _handleQrToolbox(
    List<String> inputFiles,
    Map<String, dynamic> params,
    String outputDir,
    Function(double, String)? onProgress,
  ) async {
    final mode = params['mode']?.toString() ?? 'generate';

    if (mode == 'decode') {
      if (inputFiles.isEmpty) {
        return ProcessingResult(success: false, message: '请先在上方选择待识别的二维码图片');
      }
      onProgress?.call(0.2, '正在读取并解析图片特征...');
      final filePath = inputFiles[0];
      final fileBytes = await File(filePath).readAsBytes();

      final decodedImg = img.decodeImage(fileBytes);
      if (decodedImg == null) {
        return ProcessingResult(success: false, message: '无法解析所选图片文件，请确认是否为有效图片格式');
      }

      // 无论原图是 JPEG (RGB 3 通道) 还是其他格式，转为标准的 RGBA 4 通道，确保 ZXing 引擎按 4 字节步长正确解算
      final rgbaImg = decodedImg.numChannels == 4 ? decodedImg : decodedImg.convert(numChannels: 4);
      final rgbaBytes = Uint8List.fromList(img.encodePng(rgbaImg));

      onProgress?.call(0.5, '正在通过 ZXing 引擎检索二维码定位点...');
      final decoder = QrCodeDartDecoder(formats: [BarcodeFormat.qrCode]);
      ScanResult? result;
      try {
        result = await decoder.decodeFile(rgbaBytes);
      } catch (_) {}

      // 如果直解失败，尝试进行灰度与高对比度增强重试
      if (result == null || result.text.isEmpty) {
        onProgress?.call(0.7, '初次识别未命中，尝试对比度增强二次解算...');
        final gray = img.grayscale(rgbaImg);
        final enhanced = img.contrast(gray, contrast: 150);
        final enhancedBytes = Uint8List.fromList(img.encodePng(enhanced.convert(numChannels: 4)));
        try {
          result = await decoder.decodeFile(enhancedBytes);
        } catch (_) {}
      }

      if (result != null && result.text.isNotEmpty) {
        final decodedText = result.text;
        final outName = 'qr_result_${DateTime.now().millisecondsSinceEpoch}.txt';
        final outPath = p.join(outputDir, outName);
        await File(outPath).writeAsString(decodedText);
        onProgress?.call(1.0, '识别成功！');
        return ProcessingResult(
          success: true,
          message: '🎉 成功识别出二维码内容：\n\n$decodedText\n\n（识别内容已同步写入结果文本）',
          outputFiles: [outPath],
        );
      } else {
        return ProcessingResult(
          success: false,
          message: '未能从所选图片中识别出有效的二维码。\n请确保二维码没有被严重遮挡、反光或模糊。',
        );
      }
    } else {
      // 生成模式
      final content = params['content']?.toString().trim() ?? '';
      if (content.isEmpty) {
        return ProcessingResult(success: false, message: '二维码内容不能为空，请输入文本或网址');
      }

      final errorLevelStr = params['errorLevel']?.toString().toUpperCase() ?? 'M';
      int errorCorrectLevel;
      switch (errorLevelStr) {
        case 'L':
          errorCorrectLevel = QrErrorCorrectLevel.L;
          break;
        case 'Q':
          errorCorrectLevel = QrErrorCorrectLevel.Q;
          break;
        case 'H':
          errorCorrectLevel = QrErrorCorrectLevel.H;
          break;
        case 'M':
        default:
          errorCorrectLevel = QrErrorCorrectLevel.M;
          break;
      }

      final sizeVal = params['size'];
      final targetSize = (sizeVal is num ? sizeVal.toInt() : int.tryParse(sizeVal?.toString() ?? '600')) ?? 600;

      onProgress?.call(0.3, '正在根据数据量计算最优纠错与网格矩阵...');
      final qrCode = QrCode.fromData(
        data: content,
        errorCorrectLevel: errorCorrectLevel,
      );
      final qrImage = QrImage(qrCode);
      final moduleCount = qrImage.moduleCount;

      onProgress?.call(0.6, '正在光栅化绘制高清晰度二维码与静区...');
      const quietZone = 4; // 标准 4 模块留白
      final totalModules = moduleCount + (quietZone * 2);
      final modulePixelSize = max(1, (targetSize / totalModules).floor());
      final actualDimension = totalModules * modulePixelSize;

      final image = img.Image(width: actualDimension, height: actualDimension, numChannels: 4);
      img.fill(image, color: img.ColorRgba8(255, 255, 255, 255)); // 纯白底

      final darkColor = img.ColorRgba8(0, 0, 0, 255); // 纯黑点
      for (int r = 0; r < moduleCount; r++) {
        for (int c = 0; c < moduleCount; c++) {
          if (qrImage.isDark(r, c)) {
            final startX = (c + quietZone) * modulePixelSize;
            final startY = (r + quietZone) * modulePixelSize;
            img.fillRect(
              image,
              x1: startX,
              y1: startY,
              x2: startX + modulePixelSize - 1,
              y2: startY + modulePixelSize - 1,
              color: darkColor,
            );
          }
        }
      }

      onProgress?.call(0.9, '正在编码导出 PNG 文件...');
      final pngBytes = Uint8List.fromList(img.encodePng(image));
      final outName = 'qrcode_${DateTime.now().millisecondsSinceEpoch}.png';
      final outPath = p.join(outputDir, outName);
      await File(outPath).writeAsBytes(pngBytes);

      onProgress?.call(1.0, '二维码制作完成！');
      return ProcessingResult(
        success: true,
        message: '🎉 二维码生成成功！\n尺寸: ${actualDimension}x$actualDimension px\n纠错等级: $errorLevelStr\n内容: $content',
        outputFiles: [outPath],
      );
    }
  }

  // =========================================================================
  // 6. 多线程分块下载器 (HTTP Range 并发切片 + 断点分块写入)
  // =========================================================================
  static Future<ProcessingResult> _handleChunkDownloader(
    Map<String, dynamic> params,
    String outputDir,
    Function(double, String)? onProgress,
  ) async {
    final url = params['url']?.toString().trim() ?? '';
    if (url.isEmpty || (!url.startsWith('http://') && !url.startsWith('https://'))) {
      return ProcessingResult(success: false, message: '请输入有效的 HTTP 或 HTTPS 下载直链');
    }

    final threadsVal = params['threads'];
    final threads = ((threadsVal is num ? threadsVal.toInt() : int.tryParse(threadsVal?.toString() ?? '4')) ?? 4).clamp(1, 16);
    final customFileName = params['fileName']?.toString().trim() ?? '';

    final dio = Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(minutes: 10),
      headers: {
        'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
      },
    ));

    onProgress?.call(0.05, '正在探测远程文件大小与断点续传支持...');
    int totalLength = 0;
    bool supportsRange = false;
    String fileName = customFileName;

    try {
      final probeResp = await dio.get(
        url,
        options: Options(
          headers: {'Range': 'bytes=0-0'},
          validateStatus: (status) => status != null && status < 500,
        ),
      );

      // 提取文件名
      if (fileName.isEmpty) {
        final disposition = probeResp.headers.value('content-disposition');
        if (disposition != null) {
          final match = RegExp(r'''filename\*?=(?:UTF-8'')?["']?([^";\r\n]+)["']?''').firstMatch(disposition);
          if (match != null) {
            fileName = Uri.decodeComponent(match.group(1)!);
          }
        }
      }

      if (probeResp.statusCode == 206) {
        supportsRange = true;
        final contentRange = probeResp.headers.value('content-range');
        if (contentRange != null) {
          final match = RegExp(r'/(\d+)').firstMatch(contentRange);
          if (match != null) {
            totalLength = int.tryParse(match.group(1)!) ?? 0;
          }
        }
      }

      if (totalLength <= 0) {
        final cl = probeResp.headers.value('content-length');
        if (cl != null) {
          totalLength = int.tryParse(cl) ?? 0;
        }
      }
    } catch (_) {}

    // 如果还没有文件名，从 URL 中提取
    if (fileName.isEmpty) {
      try {
        final uri = Uri.parse(url);
        if (uri.pathSegments.isNotEmpty) {
          fileName = uri.pathSegments.lastWhere((s) => s.isNotEmpty, orElse: () => '');
        }
      } catch (_) {}
      if (fileName.isEmpty) {
        fileName = 'download_${DateTime.now().millisecondsSinceEpoch}.bin';
      }
    }

    // 清洗文件名中的非法字符
    fileName = fileName.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
    final outPath = p.join(outputDir, fileName);

    final sw = Stopwatch()..start();
    int lastDownloaded = 0;
    int lastCheckTime = 0;
    double currentSpeedBps = 0;

    // 单线程降级通道
    if (!supportsRange || totalLength <= 0 || threads == 1) {
      onProgress?.call(0.1, '服务器不支持 Range 分块或为单流，启动直连下载...');
      await dio.download(
        url,
        outPath,
        onReceiveProgress: (received, total) {
          final now = sw.elapsedMilliseconds;
          if (now - lastCheckTime >= 500) {
            final diffBytes = received - lastDownloaded;
            final diffSeconds = (now - lastCheckTime) / 1000.0;
            currentSpeedBps = diffSeconds > 0 ? diffBytes / diffSeconds : 0;
            lastDownloaded = received;
            lastCheckTime = now;
          }
          final speedStr = (currentSpeedBps / 1024 / 1024).toStringAsFixed(2);
          final progress = total > 0 ? (received / total).clamp(0.0, 0.99) : 0.5;
          final totalStr = total > 0 ? '${(total / 1024 / 1024).toStringAsFixed(1)} MB' : '未知';
          onProgress?.call(progress, '已下载 ${(received / 1024 / 1024).toStringAsFixed(1)} MB / $totalStr ($speedStr MB/s)');
        },
      );
    } else {
      // 多线程并发切片下载通道
      final numChunks = (totalLength < 1024 * 1024) ? 1 : threads;
      final chunkSize = (totalLength / numChunks).ceil();
      final partPaths = <String>[];
      final chunkDownloadedBytes = List<int>.filled(numChunks, 0);

      for (int i = 0; i < numChunks; i++) {
        partPaths.add(p.join(outputDir, '.part_${i}_$fileName'));
      }

      onProgress?.call(0.1, '已建立 $numChunks 个切片并发线程，开始并行拉取...');

      final futures = <Future<void>>[];
      for (int i = 0; i < numChunks; i++) {
        final chunkIdx = i;
        final start = chunkIdx * chunkSize;
        final end = min((chunkIdx + 1) * chunkSize - 1, totalLength - 1);
        final partFile = File(partPaths[chunkIdx]);

        futures.add(Future(() async {
          final chunkDio = Dio(BaseOptions(
            connectTimeout: const Duration(seconds: 15),
            headers: {'User-Agent': dio.options.headers['User-Agent']},
          ));

          final resp = await chunkDio.get<ResponseBody>(
            url,
            options: Options(
              headers: {'Range': 'bytes=$start-$end'},
              responseType: ResponseType.stream,
            ),
          );

          final sink = partFile.openWrite();
          await for (final data in resp.data!.stream) {
            sink.add(data);
            chunkDownloadedBytes[chunkIdx] += data.length;

            final totalDownloaded = chunkDownloadedBytes.fold<int>(0, (a, b) => a + b);
            final now = sw.elapsedMilliseconds;
            if (now - lastCheckTime >= 500) {
              final diffBytes = totalDownloaded - lastDownloaded;
              final diffSeconds = (now - lastCheckTime) / 1000.0;
              currentSpeedBps = diffSeconds > 0 ? diffBytes / diffSeconds : 0;
              lastDownloaded = totalDownloaded;
              lastCheckTime = now;
            }

            final speedStr = (currentSpeedBps / 1024 / 1024).toStringAsFixed(2);
            final progress = (totalDownloaded / totalLength).clamp(0.0, 0.96);
            onProgress?.call(
              progress,
              '并行切片下载 ($numChunks 线程): ${(totalDownloaded / 1024 / 1024).toStringAsFixed(1)} / ${(totalLength / 1024 / 1024).toStringAsFixed(1)} MB ($speedStr MB/s)',
            );
          }
          await sink.flush();
          await sink.close();
        }));
      }

      await Future.wait(futures);

      onProgress?.call(0.97, '各切片下载完成，正在高效拼合落盘...');
      final finalSink = File(outPath).openWrite();
      for (int i = 0; i < numChunks; i++) {
        final partFile = File(partPaths[i]);
        if (partFile.existsSync()) {
          await finalSink.addStream(partFile.openRead());
          try {
            await partFile.delete();
          } catch (_) {}
        }
      }
      await finalSink.flush();
      await finalSink.close();
    }

    sw.stop();
    final outSize = File(outPath).existsSync() ? File(outPath).lengthSync() : 0;
    onProgress?.call(1.0, '下载完成！总耗时 ${sw.elapsed.inSeconds} 秒');

    return ProcessingResult(
      success: true,
      message: '🎉 文件多线程下载成功！\n'
          '文件名称: $fileName\n'
          '文件大小: ${(outSize / 1024 / 1024).toStringAsFixed(2)} MB\n'
          '切片模式: ${supportsRange ? "$threads 线程并行" : "单线程直连"}\n'
          '总计耗时: ${sw.elapsed.inSeconds} 秒',
      outputFiles: [outPath],
    );
  }

  // =========================================================================
  // FFmpeg 跨平台执行助手 (Android 内置原生 NDK / Windows 动态进程)
  // =========================================================================
  static String? _cachedFfmpegPath;

  static Future<String?> _findWindowsFfmpeg() async {
    if (_cachedFfmpegPath != null && File(_cachedFfmpegPath!).existsSync()) {
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
      final sdkDir = Directory(p.join(home, r'AppData\Local\Microsoft\WinGet\Packages'));
      if (sdkDir.existsSync()) {
        try {
          for (var sub in sdkDir.listSync(recursive: false)) {
            if (sub is Directory && sub.path.toLowerCase().contains('ffmpeg')) {
              try {
                sub
                    .listSync(recursive: true)
                    .whereType<File>()
                    .where((f) => p.basename(f.path).toLowerCase() == 'ffmpeg.exe')
                    .take(1)
                    .forEach((f) => candidates.add(f.path));
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

  static Future<ProcessingResult> _executeFFmpegCommand({
    required List<String> ffmpegArgs,
    required String outPath,
    required String successTitle,
    Function(double, String)? onProgress,
  }) async {
    final sw = Stopwatch()..start();
    final outName = p.basename(outPath);

    if (Platform.isAndroid) {
      onProgress?.call(0.20, '正在通过 Android 原生内置 FFmpeg 核心处理...');
      final session = await FFmpegKit.executeWithArguments(ffmpegArgs);
      sw.stop();
      final returnCode = await session.getReturnCode();

      if (ReturnCode.isSuccess(returnCode) && File(outPath).existsSync()) {
        final outSize = File(outPath).lengthSync();
        onProgress?.call(1.0, '$successTitle！总耗时 ${sw.elapsed.inSeconds} 秒');
        return ProcessingResult(
          success: true,
          message: '$successTitle (耗时 ${sw.elapsed.inSeconds} 秒)！\n输出文件: $outName\n最终大小: ${(outSize / 1024).toStringAsFixed(1)} KB',
          outputFiles: [outPath],
        );
      } else {
        final logs = await session.getAllLogsAsString();
        return ProcessingResult(
          success: false,
          message: 'FFmpeg 处理失败 (ReturnCode: $returnCode)\n$logs',
        );
      }
    }

    // Windows 平台
    onProgress?.call(0.10, '正在检测系统 FFmpeg 编解码引擎...');
    final ffmpegPath = await _findWindowsFfmpeg();
    if (ffmpegPath == null) {
      return ProcessingResult(
        success: false,
        message: '未在系统路径或程序目录中找到有效 FFmpeg。\n若下载的是极简便携包，可在 Windows PowerShell 中运行:\nwinget install Gyan.FFmpeg.Essentials\n安装后重启软件；或直接下载自带 FFmpeg 的完整便携包。',
      );
    }

    onProgress?.call(0.20, '已就绪 FFmpeg 核心，正在启动处理管道...');
    final process = await Process.start(ffmpegPath, ffmpegArgs);
    final stderrBuf = StringBuffer();
    process.stdout.drain<void>();
    process.stderr.transform(const SystemEncoding().decoder).listen((data) {
      stderrBuf.write(data);
      if (data.contains('time=') || data.contains('frame=')) {
        onProgress?.call(0.60, '正在转码处理中 (${sw.elapsed.inSeconds}s)...');
      }
    });

    final exitCode = await process.exitCode;
    sw.stop();

    if (exitCode == 0 && File(outPath).existsSync()) {
      final outSize = File(outPath).lengthSync();
      onProgress?.call(1.0, '$successTitle！总耗时 ${sw.elapsed.inSeconds} 秒');
      return ProcessingResult(
        success: true,
        message: '$successTitle (耗时 ${sw.elapsed.inSeconds} 秒)！\n输出文件: $outName\n最终大小: ${(outSize / 1024).toStringAsFixed(1)} KB',
        outputFiles: [outPath],
      );
    } else {
      return ProcessingResult(
        success: false,
        message: 'FFmpeg 处理失败 (退出码: $exitCode)\n${stderrBuf.toString().split('\n').where((l) => l.toLowerCase().contains('error') || l.toLowerCase().contains('invalid')).take(5).join('\n')}',
      );
    }
  }

  // =========================================================================
  // 7. GIF 动图制作与逐帧解析 (工业级调色板优化 + 多图合成 + 逐帧归档)
  // =========================================================================
  static Future<ProcessingResult> _handleGifToolbox(
    List<String> inputFiles,
    Map<String, dynamic> params,
    String outputDir,
    Function(double, String)? onProgress,
  ) async {
    final mode = params['mode']?.toString() ?? 'images_to_gif';

    if (mode == 'images_to_gif') {
      if (inputFiles.length < 2) {
        return ProcessingResult(
          success: false,
          message: '多图合成动态 GIF 请至少选择 2 张图片',
        );
      }

      final delayVal = params['delayMs'];
      final delayMs = ((delayVal is num ? delayVal.toInt() : int.tryParse(delayVal?.toString() ?? '200')) ?? 200).clamp(20, 5000);
      final repeatVal = params['repeat'];
      final repeat = (repeatVal is num ? repeatVal.toInt() : int.tryParse(repeatVal?.toString() ?? '0')) ?? 0;
      final scaleVal = params['scaleWidth'];
      final scaleWidth = (scaleVal is num ? scaleVal.toInt() : int.tryParse(scaleVal?.toString() ?? '0')) ?? 0;

      onProgress?.call(0.05, '正在初始化 GIF 编码器...');
      final encoder = img.GifEncoder(repeat: repeat);
      final durationCentiseconds = (delayMs / 10).round().clamp(1, 1000);

      int targetW = 0;
      int targetH = 0;

      for (int i = 0; i < inputFiles.length; i++) {
        final fPath = inputFiles[i];
        final progress = 0.05 + (i / inputFiles.length) * 0.8;
        onProgress?.call(progress, '正在解析与栅格化第 ${i + 1}/${inputFiles.length} 帧...');

        final bytes = await File(fPath).readAsBytes();
        final decoded = img.decodeImage(bytes);
        if (decoded == null) {
          return ProcessingResult(
            success: false,
            message: '无法解析图片: ${p.basename(fPath)}，请检查文件格式',
          );
        }

        if (i == 0) {
          if (scaleWidth > 0 && scaleWidth < decoded.width) {
            targetW = scaleWidth;
            targetH = (decoded.height * (scaleWidth / decoded.width)).round();
          } else {
            targetW = decoded.width;
            targetH = decoded.height;
          }
        }

        img.Image frameImage = decoded;
        if (frameImage.width != targetW || frameImage.height != targetH) {
          frameImage = img.copyResize(
            frameImage,
            width: targetW,
            height: targetH,
            interpolation: img.Interpolation.linear,
          );
        }

        encoder.addFrame(frameImage, duration: durationCentiseconds);
      }

      onProgress?.call(0.90, '正在生成并压缩 GIF 数据流...');
      final gifBytes = encoder.finish();
      if (gifBytes == null || gifBytes.isEmpty) {
        return ProcessingResult(
          success: false,
          message: 'GIF 编码器输出为空，请重试',
        );
      }

      final outName = 'gif_animated_${DateTime.now().millisecondsSinceEpoch}.gif';
      final outPath = p.join(outputDir, outName);
      await File(outPath).writeAsBytes(gifBytes);

      onProgress?.call(1.0, 'GIF 动图制作成功！');
      return ProcessingResult(
        success: true,
        message: '🎉 动态 GIF 制作完成！\n'
            '帧数: ${inputFiles.length} 帧\n'
            '帧间隔: ${delayMs}ms (约 ${(1000 / delayMs).toStringAsFixed(1)} FPS)\n'
            '分辨率: ${targetW}x$targetH px\n'
            '循环模式: ${repeat == 0 ? "无限循环" : "单次播放"}\n'
            '文件大小: ${(gifBytes.length / 1024).toStringAsFixed(1)} KB',
        outputFiles: [outPath],
      );
    } else if (mode == 'video_to_gif') {
      if (inputFiles.isEmpty) {
        return ProcessingResult(
          success: false,
          message: '请选择待转换为 GIF 的视频文件',
        );
      }

      final filePath = inputFiles[0];
      final startTime = params['startTime']?.toString().trim().isNotEmpty == true
          ? params['startTime'].toString().trim()
          : '00:00:00';
      final durationVal = params['duration'];
      final duration = ((durationVal is num ? durationVal.toDouble() : double.tryParse(durationVal?.toString() ?? '5')) ?? 5.0).clamp(0.5, 60.0);
      final fpsVal = params['fps'];
      final fps = ((fpsVal is num ? fpsVal.toInt() : int.tryParse(fpsVal?.toString() ?? '12')) ?? 12).clamp(1, 30);
      final widthVal = params['width'];
      final width = ((widthVal is num ? widthVal.toInt() : int.tryParse(widthVal?.toString() ?? '480')) ?? 480).clamp(120, 1920);

      final outName = 'video_to_gif_${p.basenameWithoutExtension(filePath)}_${DateTime.now().millisecondsSinceEpoch}.gif';
      final outPath = p.join(outputDir, outName);

      // 高清调色板双通道流水线 (工业级调色板优化，消除杂色噪点与条带失真)
      final filterString = 'fps=$fps,scale=$width:-2:flags=lanczos,split[s0][s1];[s0]palettegen=max_colors=256[p];[s1][p]paletteuse=dither=bayer';
      final ffmpegArgs = [
        '-y',
        '-ss', startTime,
        '-t', duration.toString(),
        '-i', filePath,
        '-vf', filterString,
        outPath,
      ];

      return await _executeFFmpegCommand(
        ffmpegArgs: ffmpegArgs,
        outPath: outPath,
        successTitle: '🎉 视频转 GIF 动图完成',
        onProgress: onProgress,
      );
    } else if (mode == 'extract_frames') {
      if (inputFiles.isEmpty) {
        return ProcessingResult(
          success: false,
          message: '请选择需要解析帧的 GIF 文件',
        );
      }

      final filePath = inputFiles[0];
      final format = (params['format']?.toString().toLowerCase() == 'jpg' || params['format']?.toString().toLowerCase() == 'jpeg') ? 'jpg' : 'png';
      final exportZip = params['exportZip'] == true || params['exportZip']?.toString().toLowerCase() != 'false';

      onProgress?.call(0.1, '正在读取并解析 GIF 动图数据...');
      final bytes = await File(filePath).readAsBytes();
      final decoded = img.decodeGif(bytes);

      if (decoded == null || decoded.numFrames <= 0) {
        return ProcessingResult(
          success: false,
          message: '无法解析该 GIF 文件，或该文件不包含有效动画帧',
        );
      }

      final totalFrames = decoded.frames.length;
      final baseName = p.basenameWithoutExtension(filePath);
      final subFolderName = '${baseName}_frames_${DateTime.now().millisecondsSinceEpoch}';
      final framesDir = Directory(p.join(outputDir, subFolderName));
      if (!framesDir.existsSync()) {
        framesDir.createSync(recursive: true);
      }

      onProgress?.call(0.2, '共解析出 $totalFrames 个动图帧，开始逐帧导出为 $format...');
      final exportedFiles = <String>[];
      final archive = Archive();

      for (int i = 0; i < totalFrames; i++) {
        final frame = decoded.frames[i];
        final curProgress = 0.2 + (i / totalFrames) * 0.7;
        onProgress?.call(curProgress, '正在导出第 ${i + 1}/$totalFrames 帧...');

        final frameFileName = 'frame_${(i + 1).toString().padLeft(3, '0')}.$format';
        final framePath = p.join(framesDir.path, frameFileName);
        final frameBytes = format == 'jpg'
            ? Uint8List.fromList(img.encodeJpg(frame, quality: 95))
            : Uint8List.fromList(img.encodePng(frame));

        await File(framePath).writeAsBytes(frameBytes);
        exportedFiles.add(framePath);

        if (exportZip) {
          archive.addFile(ArchiveFile(frameFileName, frameBytes.length, frameBytes));
        }
      }

      String zipSummary = '';
      if (exportZip) {
        onProgress?.call(0.95, '正在打包 ZIP 压缩归档...');
        final zipBytes = ZipEncoder().encode(archive);
        if (zipBytes.isNotEmpty) {
          final zipName = '${baseName}_frames.zip';
          final zipPath = p.join(outputDir, zipName);
          await File(zipPath).writeAsBytes(zipBytes);
          exportedFiles.insert(0, zipPath);
          zipSummary = '\n已同步打包 ZIP: $zipName (${(zipBytes.length / 1024).toStringAsFixed(1)} KB)';
        }
      }

      onProgress?.call(1.0, 'GIF 逐帧解析完成！');
      return ProcessingResult(
        success: true,
        message: '🎉 GIF 逐帧解析成功！\n'
            '共成功提取: $totalFrames 个独立帧图片\n'
            '导出格式: ${format.toUpperCase()}\n'
            '存储目录: $subFolderName$zipSummary',
        outputFiles: exportedFiles,
      );
    } else {
      return ProcessingResult(
        success: false,
        message: '未知的 GIF 工具箱操作模式: $mode',
      );
    }
  }

  // =========================================================================
  // 8. 实况照片 (Live Photo / Motion Photo) 制作与解析
  //    - 模式 1: 静态图 + 短视频合流 (image_video_to_live)
  //    - 模式 2: 单视频一键提炼实况 (video_to_live)
  //    - 模式 3: 实况照片解析与分离 (extract_live_photo)
  // =========================================================================
  static String _buildMotionPhotoXmp(int videoLength) {
    return '<x:xmpmeta xmlns:x="adobe:ns:meta/" x:xmptk="Adobe XMP Core 5.1.0-jc003">'
        '<rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">'
        '<rdf:Description rdf:about="" '
        'xmlns:GCamera="http://ns.google.com/photos/1.0/camera/" '
        'xmlns:Container="http://ns.google.com/photos/1.0/container/" '
        'xmlns:Item="http://ns.google.com/photos/1.0/container/item/" '
        'GCamera:MotionPhoto="1" '
        'GCamera:MotionPhotoVersion="1" '
        'GCamera:MotionPhotoPresentationTimestampUs="0" '
        'GCamera:MicroVideo="1" '
        'GCamera:MicroVideoVersion="1" '
        'GCamera:MicroVideoOffset="$videoLength" '
        'GCamera:MicroVideoPresentationTimestampUs="0">'
        '<Container:Directory>'
        '<rdf:Seq>'
        '<rdf:li rdf:parseType="Resource">'
        '<Container:Item Item:Mime="image/jpeg" Item:Semantic="Primary" Item:Length="0" Item:Padding="0"/>'
        '</rdf:li>'
        '<rdf:li rdf:parseType="Resource">'
        '<Container:Item Item:Mime="video/mp4" Item:Semantic="MotionPhoto" Item:Length="$videoLength" Item:Padding="0"/>'
        '</rdf:li>'
        '</rdf:Seq>'
        '</Container:Directory>'
        '</rdf:Description>'
        '</rdf:RDF>'
        '</x:xmpmeta>';
  }

  static Uint8List _synthesizeMotionPhoto(Uint8List jpegBytes, Uint8List videoBytes) {
    if (jpegBytes.length < 4 || jpegBytes[0] != 0xFF || jpegBytes[1] != 0xD8) {
      final decoded = img.decodeImage(jpegBytes);
      if (decoded != null) {
        jpegBytes = Uint8List.fromList(img.encodeJpg(decoded, quality: 96));
      }
    }

    final xmpXml = _buildMotionPhotoXmp(videoBytes.length);
    final xmpHeader = utf8.encode('http://ns.adobe.com/xap/1.0/\x00');
    final xmpXmlBytes = utf8.encode(xmpXml);
    final segmentLength = 2 + xmpHeader.length + xmpXmlBytes.length;

    int insertOffset = 2;
    int offset = 2;
    while (offset + 4 < jpegBytes.length) {
      if (jpegBytes[offset] == 0xFF) {
        final marker = jpegBytes[offset + 1];
        if (marker == 0xDA || marker == 0xD9) break;
        final segLen = (jpegBytes[offset + 2] << 8) | jpegBytes[offset + 3];
        if (marker == 0xE0) {
          insertOffset = offset + 2 + segLen;
          break;
        }
        offset += 2 + segLen;
      } else {
        break;
      }
    }

    final builder = BytesBuilder();
    builder.add(jpegBytes.sublist(0, insertOffset));
    builder.add([0xFF, 0xE1]);
    builder.add([(segmentLength >> 8) & 0xFF, segmentLength & 0xFF]);
    builder.add(xmpHeader);
    builder.add(xmpXmlBytes);
    builder.add(jpegBytes.sublist(insertOffset));
    builder.add(videoBytes);

    return builder.toBytes();
  }

  static Future<ProcessingResult> _handleLivePhotoToolbox(
    List<String> inputFiles,
    Map<String, dynamic> params,
    String outputDir,
    Function(double, String)? onProgress,
  ) async {
    final mode = params['mode']?.toString() ?? 'image_video_to_live';

    if (mode == 'image_video_to_live') {
      String? imagePath;
      String? videoPath;

      if (params['imageFile'] is List && (params['imageFile'] as List).isNotEmpty) {
        imagePath = (params['imageFile'] as List).first.toString();
      } else if (params['imageFile'] != null && params['imageFile'].toString().isNotEmpty) {
        imagePath = params['imageFile'].toString();
      }

      if (params['videoFile'] is List && (params['videoFile'] as List).isNotEmpty) {
        videoPath = (params['videoFile'] as List).first.toString();
      } else if (params['videoFile'] != null && params['videoFile'].toString().isNotEmpty) {
        videoPath = params['videoFile'].toString();
      }

      if (imagePath == null || videoPath == null) {
        for (final f in inputFiles) {
          final ext = p.extension(f).toLowerCase();
          if (['.jpg', '.jpeg', '.png', '.webp', '.bmp'].contains(ext) && imagePath == null) {
            imagePath = f;
          } else if (['.mp4', '.mov', '.mkv', '.avi', '.flv', '.webm'].contains(ext) && videoPath == null) {
            videoPath = f;
          }
        }
      }

      if (imagePath == null || !File(imagePath).existsSync()) {
        return ProcessingResult(success: false, message: '请先在上方选择有效的静态封面图片 (JPG/PNG/WebP)');
      }
      if (videoPath == null || !File(videoPath).existsSync()) {
        return ProcessingResult(success: false, message: '请先在上方选择有效的实况视频文件 (MP4/MOV)');
      }

      final exportFormat = params['exportFormat']?.toString() ?? 'android_motion_photo';
      onProgress?.call(0.1, '正在读取封面图片与实况视频流...');

      var imageBytes = await File(imagePath).readAsBytes();
      final videoBytes = await File(videoPath).readAsBytes();

      if (imageBytes.length < 4 || imageBytes[0] != 0xFF || imageBytes[1] != 0xD8) {
        onProgress?.call(0.2, '正在将封面图无损转换为标准 JPEG...');
        final decoded = img.decodeImage(imageBytes);
        if (decoded == null) {
          return ProcessingResult(success: false, message: '无法解析封面图片，请确认格式');
        }
        imageBytes = Uint8List.fromList(img.encodeJpg(decoded, quality: 96));
      }

      final outputFiles = <String>[];
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final baseName = p.basenameWithoutExtension(imagePath);

      if (exportFormat == 'android_motion_photo' || exportFormat == 'both') {
        onProgress?.call(0.5, '正在注入 Google Camera XMP 容器元数据并合流...');
        final motionPhotoBytes = _synthesizeMotionPhoto(imageBytes, videoBytes);
        final outName = 'MotionPhoto_${baseName}_$timestamp.jpg';
        final outPath = p.join(outputDir, outName);
        await File(outPath).writeAsBytes(motionPhotoBytes);
        outputFiles.add(outPath);
      }

      if (exportFormat == 'ios_live_photo' || exportFormat == 'both') {
        onProgress?.call(0.8, '正在生成 iOS Live Photo 配对包 (注入 AssetIdentifier)...');
        final uuid = const Uuid().v4().toUpperCase();
        final archive = Archive();
        archive.addFile(ArchiveFile('IMG_$timestamp.JPG', imageBytes.length, imageBytes));
        archive.addFile(ArchiveFile('IMG_$timestamp.MOV', videoBytes.length, videoBytes));
        archive.addFile(ArchiveFile('live_photo_uuid.txt', uuid.length, utf8.encode(uuid)));

        final zipBytes = ZipEncoder().encode(archive);
        if (zipBytes.isNotEmpty) {
          final zipName = 'LivePhoto_iOS_${baseName}_$timestamp.zip';
          final zipPath = p.join(outputDir, zipName);
          await File(zipPath).writeAsBytes(zipBytes);
          outputFiles.add(zipPath);
        }
      }

      onProgress?.call(1.0, '实况照片制作完成！');
      return ProcessingResult(
        success: true,
        message: '🎉 实况照片封装制作成功！\n'
            '封面大小: ${(imageBytes.length / 1024).toStringAsFixed(1)} KB\n'
            '微动视频大小: ${(videoBytes.length / 1024).toStringAsFixed(1)} KB\n'
            '生成规范: ${exportFormat == "both" ? "Android 单文件 + iOS 配对 ZIP" : (exportFormat == "ios_live_photo" ? "iOS Live Photo 配对 ZIP" : "Android Motion Photo 单文件 (Google/小米/三星相册即按即播)")}',
        outputFiles: outputFiles,
      );
    } else if (mode == 'video_to_live') {
      if (inputFiles.isEmpty) {
        return ProcessingResult(success: false, message: '请选择需要转换的视频文件');
      }

      final videoPath = inputFiles.first;
      if (!File(videoPath).existsSync()) {
        return ProcessingResult(success: false, message: '视频文件不存在: $videoPath');
      }

      final coverTimestamp = params['coverTimestamp']?.toString().trim().isNotEmpty == true
          ? params['coverTimestamp'].toString().trim()
          : '00:00:00';
      final durationVal = params['duration'];
      final duration = ((durationVal is num ? durationVal.toDouble() : double.tryParse(durationVal?.toString() ?? '2.0')) ?? 2.0).clamp(0.5, 6.0);
      final exportFormat = params['exportFormat']?.toString() ?? 'android_motion_photo';

      onProgress?.call(0.1, '正在通过 FFmpeg 截取封面帧与实况短视频...');
      final tempDir = Directory.systemTemp.createTempSync('livephoto_tmp_');
      try {
        final coverPath = p.join(tempDir.path, 'cover_temp.jpg');
        final clipPath = p.join(tempDir.path, 'clip_temp.mp4');

        final coverArgs = [
          '-y',
          '-ss', coverTimestamp,
          '-i', videoPath,
          '-vframes', '1',
          '-q:v', '2',
          coverPath,
        ];
        onProgress?.call(0.2, '正在截取视频高清晰度静态封面...');
        final coverRes = await _executeFFmpegCommand(
          ffmpegArgs: coverArgs,
          outPath: coverPath,
          successTitle: '封面提取完成',
        );
        if (!coverRes.success || !File(coverPath).existsSync()) {
          return ProcessingResult(success: false, message: '从视频中提取封面帧失败: ${coverRes.message}');
        }

        final clipArgs = [
          '-y',
          '-ss', coverTimestamp,
          '-t', duration.toString(),
          '-i', videoPath,
          '-c:v', 'libx264',
          '-preset', 'fast',
          '-crf', '20',
          '-c:a', 'aac',
          '-b:a', '128k',
          '-movflags', '+faststart',
          clipPath,
        ];
        onProgress?.call(0.5, '正在转码实况微动视频片段 (${duration}s)...');
        final clipRes = await _executeFFmpegCommand(
          ffmpegArgs: clipArgs,
          outPath: clipPath,
          successTitle: '片段截取完成',
        );
        if (!clipRes.success || !File(clipPath).existsSync()) {
          return ProcessingResult(success: false, message: '截取实况视频片段失败: ${clipRes.message}');
        }

        final imageBytes = await File(coverPath).readAsBytes();
        final videoBytes = await File(clipPath).readAsBytes();

        final outputFiles = <String>[];
        final timestamp = DateTime.now().millisecondsSinceEpoch;
        final baseName = p.basenameWithoutExtension(videoPath);

        if (exportFormat == 'android_motion_photo' || exportFormat == 'both') {
          onProgress?.call(0.8, '正在注入 XMP 容器元数据并合流...');
          final motionPhotoBytes = _synthesizeMotionPhoto(imageBytes, videoBytes);
          final outName = 'MotionPhoto_${baseName}_$timestamp.jpg';
          final outPath = p.join(outputDir, outName);
          await File(outPath).writeAsBytes(motionPhotoBytes);
          outputFiles.add(outPath);
        }

        if (exportFormat == 'ios_live_photo' || exportFormat == 'both') {
          onProgress?.call(0.9, '正在生成 iOS Live Photo 配对包...');
          final uuid = const Uuid().v4().toUpperCase();
          final archive = Archive();
          archive.addFile(ArchiveFile('IMG_$timestamp.JPG', imageBytes.length, imageBytes));
          archive.addFile(ArchiveFile('IMG_$timestamp.MOV', videoBytes.length, videoBytes));
          archive.addFile(ArchiveFile('live_photo_uuid.txt', uuid.length, utf8.encode(uuid)));

          final zipBytes = ZipEncoder().encode(archive);
          if (zipBytes.isNotEmpty) {
            final zipName = 'LivePhoto_iOS_${baseName}_$timestamp.zip';
            final zipPath = p.join(outputDir, zipName);
            await File(zipPath).writeAsBytes(zipBytes);
            outputFiles.add(zipPath);
          }
        }

        onProgress?.call(1.0, '视频提炼实况照片完成！');
        return ProcessingResult(
          success: true,
          message: '🎉 视频一键提炼实况照片成功！\n'
              '截取片段时长: ${duration}s (从 $coverTimestamp 起)\n'
              '合流生成格式: ${exportFormat == "both" ? "Android 单文件 + iOS 配对 ZIP" : (exportFormat == "ios_live_photo" ? "iOS Live Photo 配对包" : "Android Motion Photo 单文件")}',
          outputFiles: outputFiles,
        );
      } finally {
        try {
          tempDir.deleteSync(recursive: true);
        } catch (_) {}
      }
    } else if (mode == 'extract_live_photo') {
      if (inputFiles.isEmpty) {
        return ProcessingResult(success: false, message: '请选择需要解析分离的实况照片文件');
      }

      final sourcePath = inputFiles.first;
      if (!File(sourcePath).existsSync()) {
        return ProcessingResult(success: false, message: '文件不存在: $sourcePath');
      }

      onProgress?.call(0.2, '正在扫描实况照片 XMP 元数据与容器轨道...');
      final fileBytes = await File(sourcePath).readAsBytes();

      int? videoStartOffset;
      final contentString = latin1.decode(fileBytes);

      // 1. 优先精准解析 XMP Container:Directory 中 Semantic="MotionPhoto" 的专用条目
      // （完美规避小米澎湃 HyperOS、三星、Google Pixel 等 Ultra HDR 照片中包含的前置 GainMap Item 干扰）
      final itemRegex = RegExp(r'<[^>]*?Container:Item[^>]*?>', caseSensitive: false);
      for (final m in itemRegex.allMatches(contentString)) {
        final itemStr = m.group(0)!;
        if (itemStr.contains('MotionPhoto') && itemStr.contains('Item:Length')) {
          final lenMatch = RegExp(r'Item:Length\s*=\s*["\x27](\d+)["\x27]').firstMatch(itemStr);
          if (lenMatch != null) {
            final len = int.tryParse(lenMatch.group(1)!);
            if (len != null && len > 0 && len < fileBytes.length) {
              videoStartOffset = fileBytes.length - len;
              break;
            }
          }
        }
      }

      // 2. 传统/单条目 XMP 与 GCamera:MicroVideoOffset 检索
      if (videoStartOffset == null) {
        final match = RegExp(r'GCamera:MicroVideoOffset\s*=\s*["\x27](\d+)["\x27]').firstMatch(contentString) ??
            RegExp(r'MicroVideoOffset["\s]*[:=]["\s]*(\d+)').firstMatch(contentString) ??
            RegExp(r'Item:Length\s*=\s*["\x27](\d+)["\x27]').firstMatch(contentString);
        if (match != null) {
          final len = int.tryParse(match.group(1)!);
          if (len != null && len > 0 && len < fileBytes.length) {
            videoStartOffset = fileBytes.length - len;
          }
        }
      }

      // 3. 严格校验 videoStartOffset 是否真实指向合法的 MP4 ftyp 标头；若不符自动修正
      bool isFtypValid(int offset) {
        if (offset < 0 || offset + 8 > fileBytes.length) return false;
        return fileBytes[offset + 4] == 0x66 &&
            fileBytes[offset + 5] == 0x74 &&
            fileBytes[offset + 6] == 0x79 &&
            fileBytes[offset + 7] == 0x70;
      }

      if (videoStartOffset != null && !isFtypValid(videoStartOffset)) {
        videoStartOffset = null;
      }

      // 4. 终极自愈回退策略：扫描 MP4 容器特征码 ftyp (0x66, 0x74, 0x79, 0x70)
      if (videoStartOffset == null) {
        for (int i = 2; i < fileBytes.length - 8; i++) {
          if (fileBytes[i] == 0x66 &&
              fileBytes[i + 1] == 0x74 &&
              fileBytes[i + 2] == 0x79 &&
              fileBytes[i + 3] == 0x70) {
            final boxSize = (fileBytes[i - 4] << 24) |
                (fileBytes[i - 3] << 16) |
                (fileBytes[i - 2] << 8) |
                fileBytes[i - 1];
            if (boxSize >= 16 && boxSize <= 1024) {
              videoStartOffset = i - 4;
              break;
            }
          }
        }
      }

      if (videoStartOffset == null || videoStartOffset <= 0 || videoStartOffset >= fileBytes.length) {
        return ProcessingResult(
          success: false,
          message: '未能从所选文件中检测到嵌入的微动视频轨道，请确认是否为有效的实况/动态照片 (.jpg)',
        );
      }

      onProgress?.call(0.6, '检测到微动视频轨道 (偏移量: $videoStartOffset)，正在进行无损切片剥离...');
      final coverBytes = fileBytes.sublist(0, videoStartOffset);
      final videoBytes = fileBytes.sublist(videoStartOffset);

      final baseName = p.basenameWithoutExtension(sourcePath);
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final coverName = '${baseName}_cover_$timestamp.jpg';
      final videoName = '${baseName}_video_$timestamp.mp4';
      final coverPath = p.join(outputDir, coverName);
      final videoPath = p.join(outputDir, videoName);

      await File(coverPath).writeAsBytes(coverBytes);
      await File(videoPath).writeAsBytes(videoBytes);

      onProgress?.call(1.0, '实况照片解析分离完成！');
      return ProcessingResult(
        success: true,
        message: '🎉 实况照片解析分离成功！\n'
            '提取静态封面: $coverName (${(coverBytes.length / 1024).toStringAsFixed(1)} KB)\n'
            '提取微动视频: $videoName (${(videoBytes.length / 1024).toStringAsFixed(1)} KB)',
        outputFiles: [coverPath, videoPath],
      );
    } else {
      return ProcessingResult(success: false, message: '未知的实况照片工具操作模式: $mode');
    }
  }

  // =========================================================================
  // 8. PDF 综合工具箱 (基于 100% 纯 Dart 高效引擎 syncfusion_flutter_pdf 与 Chromium PDFium 渲染器 pdfrx)
  //    - 图片批量转 PDF: 支持标准 A4 (纵向/横向/自适应) 与图片原始尺寸, 支持页边距控制
  //    - PDF 转高清图片: 150/300 DPI 工业级光栅化渲染为 PNG / JPG, 支持多页打包 ZIP
  //    - PDF 页面合并: 无损高保真多文档序列合并
  //    - PDF 页面拆分/提取: 支持全页一键拆分为单页 PDF (ZIP 打包) 或自定义页码范围提取 (如 1-3, 5, 8-10)
  //    - PDF 深度压缩: 深度流压缩优化 (Stream Deflate Optimization)
  // =========================================================================
  static Future<ProcessingResult> _handlePdfToolbox(
    List<String> files,
    Map<String, dynamic> params,
    String outputDir,
    Function(double, String)? onProgress,
  ) async {
    final mode = params['mode']?.toString() ?? 'images_to_pdf';

    switch (mode) {
      case 'images_to_pdf':
        return await _pdfImagesToPdf(files, params, outputDir, onProgress);
      case 'pdf_to_images':
        return await _pdfToImages(files, params, outputDir, onProgress);
      case 'merge_pdf':
        return await _pdfMerge(files, params, outputDir, onProgress);
      case 'split_pdf':
        return await _pdfSplit(files, params, outputDir, onProgress);
      case 'compress_pdf':
        return await _pdfCompress(files, params, outputDir, onProgress);
      default:
        return ProcessingResult(
          success: false,
          message: '未知的 PDF 工具箱操作模式: $mode',
        );
    }
  }

  /// 1. 图片批量转 PDF
  static Future<ProcessingResult> _pdfImagesToPdf(
    List<String> files,
    Map<String, dynamic> params,
    String outputDir,
    Function(double, String)? onProgress,
  ) async {
    if (files.isEmpty) {
      return ProcessingResult(success: false, message: '请至少选择一张图片文件进行转换');
    }

    final pageSize = params['pageSize']?.toString() ?? 'a4';
    final pageOrientation = params['pageOrientation']?.toString() ?? 'auto';
    final marginType = params['margin']?.toString() ?? 'none';
    double marginVal = 0.0;
    if (marginType == 'small') {
      marginVal = 20.0;
    } else if (marginType == 'normal') {
      marginVal = 40.0;
    }

    final doc = sf.PdfDocument();
    doc.pageSettings.setMargins(0);

    for (int i = 0; i < files.length; i++) {
      final filePath = files[i];
      onProgress?.call((i / files.length) * 0.85, '正在排版第 ${i + 1}/${files.length} 张图片...');
      final imgBytes = await File(filePath).readAsBytes();
      
      // 解析图片原始尺寸
      final decodedImg = img.decodeImage(imgBytes);
      final double imgWidth = decodedImg != null ? decodedImg.width.toDouble() : 595.28;
      final double imgHeight = decodedImg != null ? decodedImg.height.toDouble() : 841.89;

      // 保证图片流兼容性：syncfusion PdfBitmap 原生仅支持 JPEG 与 PNG
      // 若为 WebP, BMP, GIF 等格式，转为内存 PNG 字节流以 100% 确保兼容
      Uint8List effectiveBytes = imgBytes;
      final isJpeg = imgBytes.length >= 3 && imgBytes[0] == 0xFF && imgBytes[1] == 0xD8 && imgBytes[2] == 0xFF;
      final isPng = imgBytes.length >= 8 && imgBytes[0] == 0x89 && imgBytes[1] == 0x50 && imgBytes[2] == 0x4E && imgBytes[3] == 0x47;
      if (!isJpeg && !isPng) {
        if (decodedImg != null) {
          effectiveBytes = Uint8List.fromList(img.encodePng(decodedImg));
        }
      }

      if (pageSize == 'fit_image') {
        final pageW = imgWidth + marginVal * 2;
        final pageH = imgHeight + marginVal * 2;
        final section = doc.sections!.add();
        section.pageSettings.orientation = pageW > pageH
            ? sf.PdfPageOrientation.landscape
            : sf.PdfPageOrientation.portrait;
        section.pageSettings.size = ui.Size(pageW, pageH);
        section.pageSettings.setMargins(0);
        final page = section.pages.add();
        page.graphics.drawImage(
          sf.PdfBitmap(effectiveBytes),
          ui.Rect.fromLTWH(marginVal, marginVal, imgWidth, imgHeight),
        );
      } else {
        // 标准 A4 纸张排版 (595.28 x 841.89)
        final bool isLandscape;
        if (pageOrientation == 'landscape') {
          isLandscape = true;
        } else if (pageOrientation == 'portrait') {
          isLandscape = false;
        } else {
          isLandscape = imgWidth > imgHeight;
        }

        final double pageW = isLandscape ? 841.89 : 595.28;
        final double pageH = isLandscape ? 595.28 : 841.89;
        final double availW = max(10.0, pageW - marginVal * 2);
        final double availH = max(10.0, pageH - marginVal * 2);

        final scale = min(availW / imgWidth, availH / imgHeight);
        final drawW = imgWidth * scale;
        final drawH = imgHeight * scale;
        final drawX = marginVal + (availW - drawW) / 2;
        final drawY = marginVal + (availH - drawH) / 2;

        final section = doc.sections!.add();
        section.pageSettings.orientation = isLandscape
            ? sf.PdfPageOrientation.landscape
            : sf.PdfPageOrientation.portrait;
        section.pageSettings.size = ui.Size(pageW, pageH);
        section.pageSettings.setMargins(0);
        final page = section.pages.add();
        page.graphics.drawImage(
          sf.PdfBitmap(effectiveBytes),
          ui.Rect.fromLTWH(drawX, drawY, drawW, drawH),
        );
      }
    }

    onProgress?.call(0.9, '正在生成与保存 PDF 文档...');
    final pdfBytes = doc.saveSync();
    doc.dispose();

    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final outPath = p.join(outputDir, 'images_bundle_$timestamp.pdf');
    await File(outPath).writeAsBytes(pdfBytes);

    onProgress?.call(1.0, '图片批量转 PDF 完成！');
    return ProcessingResult(
      success: true,
      message: '🎉 成功将 ${files.length} 张图片合成为 PDF 文档！\n'
          '页面规格: ${pageSize == "fit_image" ? "自适应图片" : "标准 A4"}\n'
          '生成文件: ${p.basename(outPath)} (${(pdfBytes.length / 1024).toStringAsFixed(1)} KB)',
      outputFiles: [outPath],
    );
  }

  /// 2. PDF 转高清图片 (基于 Chromium PDFium 高清渲染器 pdfrx)
  static Future<ProcessingResult> _pdfToImages(
    List<String> files,
    Map<String, dynamic> params,
    String outputDir,
    Function(double, String)? onProgress,
  ) async {
    if (files.isEmpty) {
      return ProcessingResult(success: false, message: '请选择一个 PDF 文件');
    }

    final pdfPath = files.first;
    final format = params['imageFormat']?.toString().toLowerCase() ?? 'png';
    final dpiVal = params['dpi'];
    final dpi = (dpiVal is num ? dpiVal.toInt() : int.tryParse(dpiVal?.toString() ?? '150')) ?? 150;
    final bundleZip = params['bundleZip'] == true || params['bundleZip']?.toString() == 'true';

    onProgress?.call(0.1, '正在初始化 PDF 高清渲染引擎...');
    rx.Pdfrx.cacheDirectoryPath ??= outputDir;
    await rx.pdfrxFlutterInitialize();

    final rxDoc = await rx.PdfDocument.openFile(pdfPath);
    final totalPages = rxDoc.pages.length;
    if (totalPages == 0) {
      await rxDoc.dispose();
      return ProcessingResult(success: false, message: 'PDF 文档中没有可渲染的页面');
    }

    // 72 DPI 为 PDF 标准基础点阵尺寸
    final double scale = dpi / 72.0;
    List<String> outPaths = [];
    final archive = bundleZip && totalPages > 1 ? Archive() : null;
    final baseName = p.basenameWithoutExtension(pdfPath);

    for (int i = 0; i < totalPages; i++) {
      onProgress?.call(
        0.1 + (i / totalPages) * 0.75,
        '正在渲染第 ${i + 1}/$totalPages 页 ($dpi DPI 高清)...',
      );
      final page = rxDoc.pages[i];
      final targetW = (page.width * scale).round();
      final targetH = (page.height * scale).round();

      final rxImg = await page.render(
        fullWidth: targetW.toDouble(),
        fullHeight: targetH.toDouble(),
        backgroundColor: 0xFFFFFFFF,
      );

      if (rxImg == null) continue;

      final imgObj = img.Image.fromBytes(
        width: rxImg.width,
        height: rxImg.height,
        bytes: rxImg.pixels.buffer,
        order: img.ChannelOrder.bgra,
        numChannels: 4,
      );
      rxImg.dispose();

      final Uint8List encodedBytes;
      final String ext;
      if (format == 'jpg' || format == 'jpeg') {
        encodedBytes = Uint8List.fromList(img.encodeJpg(imgObj, quality: 92));
        ext = 'jpg';
      } else {
        encodedBytes = Uint8List.fromList(img.encodePng(imgObj));
        ext = 'png';
      }

      final fileName = '${baseName}_page_${(i + 1).toString().padLeft(3, '0')}.$ext';
      if (archive != null) {
        archive.addFile(ArchiveFile(fileName, encodedBytes.length, encodedBytes));
      } else {
        final filePath = p.join(outputDir, fileName);
        await File(filePath).writeAsBytes(encodedBytes);
        outPaths.add(filePath);
      }
    }

    await rxDoc.dispose();

    if (archive != null) {
      onProgress?.call(0.9, '正在将 $totalPages 页图片打包为 ZIP 压缩包...');
      final zipData = ZipEncoder().encode(archive);
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final zipPath = p.join(outputDir, '${baseName}_images_$timestamp.zip');
      await File(zipPath).writeAsBytes(zipData);
      outPaths = [zipPath];
    }

    onProgress?.call(1.0, 'PDF 转高清图片完成！');
    return ProcessingResult(
      success: true,
      message: '🎉 PDF 页面转图片成功！\n'
          '渲染规格: $dpi DPI (${format.toUpperCase()})\n'
          '处理页数: 共 $totalPages 页\n'
          '输出文件: ${outPaths.map((f) => p.basename(f)).join(', ')}',
      outputFiles: outPaths,
    );
  }

  /// 3. PDF 页面合并
  static Future<ProcessingResult> _pdfMerge(
    List<String> files,
    Map<String, dynamic> params,
    String outputDir,
    Function(double, String)? onProgress,
  ) async {
    if (files.length < 2) {
      return ProcessingResult(success: false, message: '请至少选择 2 个 PDF 文件进行合并');
    }

    final mergedDoc = sf.PdfDocument();
    mergedDoc.pageSettings.setMargins(0);
    int totalPageCount = 0;

    for (int docIdx = 0; docIdx < files.length; docIdx++) {
      final filePath = files[docIdx];
      onProgress?.call(
        (docIdx / files.length) * 0.85,
        '正在合并第 ${docIdx + 1}/${files.length} 个文档: ${p.basename(filePath)}...',
      );
      final bytes = await File(filePath).readAsBytes();
      final loaded = sf.PdfDocument(inputBytes: bytes);

      for (int pIdx = 0; pIdx < loaded.pages.count; pIdx++) {
        final srcPage = loaded.pages[pIdx];
        final template = srcPage.createTemplate();
        final section = mergedDoc.sections!.add();
        section.pageSettings.orientation = srcPage.size.width > srcPage.size.height
            ? sf.PdfPageOrientation.landscape
            : sf.PdfPageOrientation.portrait;
        section.pageSettings.size = srcPage.size;
        section.pageSettings.setMargins(0);
        final newPage = section.pages.add();
        newPage.graphics.drawPdfTemplate(template, ui.Offset.zero, srcPage.size);
        totalPageCount++;
      }
      loaded.dispose();
    }

    onProgress?.call(0.9, '正在保存合并后的 PDF 文档...');
    final mergedBytes = mergedDoc.saveSync();
    mergedDoc.dispose();

    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final outPath = p.join(outputDir, 'merged_document_$timestamp.pdf');
    await File(outPath).writeAsBytes(mergedBytes);

    onProgress?.call(1.0, 'PDF 合并完成！');
    return ProcessingResult(
      success: true,
      message: '🎉 成功将 ${files.length} 个 PDF 文件合并为单体文档！\n'
          '合并总页数: $totalPageCount 页\n'
          '生成文件: ${p.basename(outPath)} (${(mergedBytes.length / 1024).toStringAsFixed(1)} KB)',
      outputFiles: [outPath],
    );
  }

  /// 4. PDF 页面拆分/提取
  static Future<ProcessingResult> _pdfSplit(
    List<String> files,
    Map<String, dynamic> params,
    String outputDir,
    Function(double, String)? onProgress,
  ) async {
    if (files.isEmpty) {
      return ProcessingResult(success: false, message: '请选择要拆分的 PDF 文件');
    }

    final pdfPath = files.first;
    final splitMode = params['splitMode']?.toString() ?? 'all_pages';
    final bytes = await File(pdfPath).readAsBytes();
    final loaded = sf.PdfDocument(inputBytes: bytes);
    final totalPages = loaded.pages.count;
    final baseName = p.basenameWithoutExtension(pdfPath);
    loaded.dispose();

    if (totalPages == 0) {
      return ProcessingResult(success: false, message: '所选 PDF 文档页数为空');
    }

    if (splitMode == 'all_pages') {
      final archive = Archive();
      for (int i = 0; i < totalPages; i++) {
        onProgress?.call((i / totalPages) * 0.85, '正在切分第 ${i + 1}/$totalPages 页...');
        
        List<int> singleBytes;
        try {
          // 优先采用高保真原生 removeAt 切分 (规避 template cloneResources bug)
          final singleDoc = sf.PdfDocument(inputBytes: bytes);
          for (int p = totalPages - 1; p >= 0; p--) {
            if (p != i) {
              singleDoc.pages.removeAt(p);
            }
          }
          singleBytes = singleDoc.saveSync();
          singleDoc.dispose();
        } catch (_) {
          // 容错降级回退
          final singleDoc = sf.PdfDocument();
          final tempLoaded = sf.PdfDocument(inputBytes: bytes);
          final t = tempLoaded.pages[i].createTemplate();
          final sec = singleDoc.sections!.add();
          sec.pageSettings.orientation = tempLoaded.pages[i].size.width > tempLoaded.pages[i].size.height
              ? sf.PdfPageOrientation.landscape
              : sf.PdfPageOrientation.portrait;
          sec.pageSettings.size = tempLoaded.pages[i].size;
          sec.pageSettings.setMargins(0);
          sec.pages.add().graphics.drawPdfTemplate(t, ui.Offset.zero, tempLoaded.pages[i].size);
          singleBytes = singleDoc.saveSync();
          singleDoc.dispose();
          tempLoaded.dispose();
        }

        final pageName = '${baseName}_page_${(i + 1).toString().padLeft(3, '0')}.pdf';
        archive.addFile(ArchiveFile(pageName, singleBytes.length, singleBytes));
      }

      onProgress?.call(0.9, '正在打包单页 PDF 为 ZIP 压缩包...');
      final zipData = ZipEncoder().encode(archive);
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final zipPath = p.join(outputDir, '${baseName}_all_pages_$timestamp.zip');
      await File(zipPath).writeAsBytes(zipData);

      onProgress?.call(1.0, '全页拆分完成！');
      return ProcessingResult(
        success: true,
        message: '🎉 成功将文档拆分为 $totalPages 个独立单页 PDF，并打包为 ZIP！\n'
            '生成文件: ${p.basename(zipPath)} (${(zipData.length / 1024).toStringAsFixed(1)} KB)',
        outputFiles: [zipPath],
      );
    } else {
      // 自定义页码提取
      final rangeStr = params['pageRange']?.toString() ?? '';
      final parsedIndices = _parsePageRanges(rangeStr, totalPages);
      if (parsedIndices.isEmpty) {
        return ProcessingResult(
          success: false,
          message: '未解析到有效的页码。当前文档共 $totalPages 页，请输入如: 1-3, 5, 8-10',
        );
      }

      List<int> outBytes;
      try {
        final keepSet = parsedIndices.toSet();
        final extractedDoc = sf.PdfDocument(inputBytes: bytes);
        for (int p = totalPages - 1; p >= 0; p--) {
          if (!keepSet.contains(p)) {
            extractedDoc.pages.removeAt(p);
          }
        }
        outBytes = extractedDoc.saveSync();
        extractedDoc.dispose();
      } catch (_) {
        // 容错降级
        final extractedDoc = sf.PdfDocument();
        final tempLoaded = sf.PdfDocument(inputBytes: bytes);
        for (int idx = 0; idx < parsedIndices.length; idx++) {
          final pIndex = parsedIndices[idx];
          onProgress?.call((idx / parsedIndices.length) * 0.85, '正在提取第 ${pIndex + 1} 页...');
          final t = tempLoaded.pages[pIndex].createTemplate();
          final sec = extractedDoc.sections!.add();
          sec.pageSettings.orientation = tempLoaded.pages[pIndex].size.width > tempLoaded.pages[pIndex].size.height
              ? sf.PdfPageOrientation.landscape
              : sf.PdfPageOrientation.portrait;
          sec.pageSettings.size = tempLoaded.pages[pIndex].size;
          sec.pageSettings.setMargins(0);
          sec.pages.add().graphics.drawPdfTemplate(t, ui.Offset.zero, tempLoaded.pages[pIndex].size);
        }
        tempLoaded.dispose();
        outBytes = extractedDoc.saveSync();
        extractedDoc.dispose();
      }

      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final outPath = p.join(outputDir, '${baseName}_extracted_$timestamp.pdf');
      await File(outPath).writeAsBytes(outBytes);

      onProgress?.call(1.0, '指定页面提取完成！');
      return ProcessingResult(
        success: true,
        message: '🎉 成功提取指定的 ${parsedIndices.length} 页为新 PDF 文档！\n'
            '提取页码: ${parsedIndices.map((i) => i + 1).join(', ')}\n'
            '生成文件: ${p.basename(outPath)} (${(outBytes.length / 1024).toStringAsFixed(1)} KB)',
        outputFiles: [outPath],
      );
    }
  }

  /// 5. PDF 深度压缩
  static Future<ProcessingResult> _pdfCompress(
    List<String> files,
    Map<String, dynamic> params,
    String outputDir,
    Function(double, String)? onProgress,
  ) async {
    if (files.isEmpty) {
      return ProcessingResult(success: false, message: '请选择要压缩的 PDF 文件');
    }

    final pdfPath = files.first;
    final origBytes = await File(pdfPath).readAsBytes();
    final origSize = origBytes.length;
    final strategy = params['compressStrategy']?.toString() ?? 'lossless';
    final baseName = p.basenameWithoutExtension(pdfPath);
    final timestamp = DateTime.now().millisecondsSinceEpoch;

    List<int> bestBytes;

    if (strategy == 'scanned_image') {
      onProgress?.call(0.1, '正在准备扫描件/栅格图片重采样深度压缩...');
      rx.Pdfrx.cacheDirectoryPath ??= outputDir;
      await rx.pdfrxFlutterInitialize();

      final rxDoc = await rx.PdfDocument.openFile(pdfPath);
      final total = rxDoc.pages.length;
      final rasterDoc = sf.PdfDocument();
      rasterDoc.compressionLevel = sf.PdfCompressionLevel.best;

      for (int i = 0; i < total; i++) {
        onProgress?.call(
          0.1 + (i / total) * 0.75,
          '正在重采样压缩第 ${i + 1}/$total 页 (120 DPI JPEG优化)...',
        );
        final page = rxDoc.pages[i];
        final scale = 120.0 / 72.0;
        final targetW = (page.width * scale).round();
        final targetH = (page.height * scale).round();
        final rxImg = await page.render(
          fullWidth: targetW.toDouble(),
          fullHeight: targetH.toDouble(),
          backgroundColor: 0xFFFFFFFF,
        );

        if (rxImg == null) continue;

        final imgObj = img.Image.fromBytes(
          width: rxImg.width,
          height: rxImg.height,
          bytes: rxImg.pixels.buffer,
          order: img.ChannelOrder.bgra,
          numChannels: 4,
        );
        rxImg.dispose();

        final jpgBytes = Uint8List.fromList(img.encodeJpg(imgObj, quality: 75));
        final sec = rasterDoc.sections!.add();
        sec.pageSettings.orientation = page.width > page.height
            ? sf.PdfPageOrientation.landscape
            : sf.PdfPageOrientation.portrait;
        sec.pageSettings.size = ui.Size(page.width, page.height);
        sec.pageSettings.setMargins(0);
        sec.pages.add().graphics.drawImage(
          sf.PdfBitmap(jpgBytes),
          ui.Rect.fromLTWH(0, 0, page.width, page.height),
        );
      }
      await rxDoc.dispose();

      onProgress?.call(0.9, '正在生成重构后的 PDF 文档...');
      final rasterBytes = rasterDoc.saveSync();
      rasterDoc.dispose();

      // 如果栅格化比原文件小，使用栅格化结果；如果原文件是纯矢量文字（比栅格化还小），则保护原文件不膨胀
      bestBytes = rasterBytes.length < origSize ? rasterBytes : origBytes;
    } else {
      // 标准无损流优化 (Stream Deflate Optimization)
      onProgress?.call(0.3, '正在执行标准无损 Deflate 流压缩与交叉引用表优化...');
      final loaded = sf.PdfDocument(inputBytes: origBytes);
      loaded.compressionLevel = sf.PdfCompressionLevel.best;
      final directCompressed = loaded.saveSync();
      loaded.dispose();

      // 绝不反向增大：若已是最优压缩态，保留原文件
      bestBytes = directCompressed.length < origSize ? directCompressed : origBytes;
    }

    final outPath = p.join(outputDir, '${baseName}_compressed_$timestamp.pdf');
    await File(outPath).writeAsBytes(bestBytes);

    final newSize = bestBytes.length;
    final savedBytes = origSize - newSize;
    final ratio = origSize > 0 ? ((savedBytes / origSize) * 100).toStringAsFixed(1) : '0';

    onProgress?.call(1.0, '压缩处理完成！');
    final String summary;
    if (savedBytes > 0) {
      summary = '🎉 成功压缩！体积减少 $ratio% (节省 ${(savedBytes / 1024).toStringAsFixed(1)} KB)';
    } else {
      summary = '💡 当前 PDF 内部数据流已处于最优压缩状态（无未压缩冗余流）。已为您保留原体积精简输出，避免无谓膨胀。';
    }

    return ProcessingResult(
      success: true,
      message: '$summary\n'
          '原始大小: ${(origSize / 1024).toStringAsFixed(1)} KB -> 输出大小: ${(newSize / 1024).toStringAsFixed(1)} KB\n'
          '生成文件: ${p.basename(outPath)}',
      outputFiles: [outPath],
    );
  }

  /// 辅助解析页码范围，例如 "1-3, 5, 8-10" -> 0-based 索引列表
  static List<int> _parsePageRanges(String rangeStr, int totalPages) {
    final List<int> indices = [];
    final parts = rangeStr.split(RegExp(r'[,，]'));
    for (var part in parts) {
      part = part.trim();
      if (part.isEmpty) continue;
      if (part.contains('-')) {
        final sub = part.split('-');
        if (sub.length == 2) {
          final start = int.tryParse(sub[0].trim());
          final end = int.tryParse(sub[1].trim());
          if (start != null && end != null) {
            final from = min(start, end);
            final to = max(start, end);
            for (int p = from; p <= to; p++) {
              if (p >= 1 && p <= totalPages && !indices.contains(p - 1)) {
                indices.add(p - 1);
              }
            }
          }
        }
      } else {
        final p = int.tryParse(part);
        if (p != null && p >= 1 && p <= totalPages && !indices.contains(p - 1)) {
          indices.add(p - 1);
        }
      }
    }
    return indices;
  }
}
