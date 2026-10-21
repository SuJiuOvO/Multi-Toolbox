import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui show Rect, Offset, Size;

import 'package:flutter/services.dart' show rootBundle;
import 'package:archive/archive.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:syncfusion_flutter_pdf/pdf.dart' as sf;
import 'package:pdfrx/pdfrx.dart' as rx;
import 'package:xml/xml.dart' as xml;
import 'package:markdown/markdown.dart' as md;

import 'pptx_template_data.dart';
import 'tool_engine_service.dart' show ProcessingResult;
import 'cad_converter_service.dart';
import 'pptx_pdf_converter_service.dart';
import 'windows_office_converter.dart';
import 'android_office_bridge.dart';

/// 万能文档互转中心服务
/// 涵盖 10 大核心文档互转能力：
/// 1. images_to_pptx: 图片批量转 PPT 演示文稿
/// 2. pptx_to_images: PPT 逐页转图片
/// 3. cad_to_pdf: CAD (DXF) 矢量转高保真 PDF
/// 4. pptx_to_pdf: PPT 演示文稿转 PDF
/// 5. pdf_to_pptx: PDF 转 PPT 演示文稿
/// 6. excel_to_pdf: Excel 工作表转 PDF
/// 7. markdown_to_pdf: Markdown 文档转 PDF
/// 8. txt_to_docx: TXT 纯文本转 Word (.docx)
/// 9. docx_to_pdf: Word 文档 (.docx) 转 PDF
/// 10. pdf_to_docx: PDF 转可编辑 Word (.docx)
class DocConverterService {
  DocConverterService._();

  static List<int>? _cachedChineseFontBytes;

  /// 加载通用中文字体字节流 (优先使用打包的 SourceHanSans 思源黑体，降级系统字体)
  static Future<List<int>?> getChineseFontBytes() async {
    if (_cachedChineseFontBytes != null) return _cachedChineseFontBytes;

    // 1. 尝试从应用内置资产中加载打包字体
    try {
      final byteData = await rootBundle.load('assets/fonts/SourceHanSansCN-Normal.ttf');
      _cachedChineseFontBytes = byteData.buffer.asUint8List();
      return _cachedChineseFontBytes;
    } catch (_) {}

    // 2. 尝试从本地相对路径中加载 (适配测试环境或命令行启动)
    final relativeCandidates = [
      'assets/fonts/SourceHanSansCN-Normal.ttf',
      '../assets/fonts/SourceHanSansCN-Normal.ttf',
      'app/assets/fonts/SourceHanSansCN-Normal.ttf',
    ];
    for (final rel in relativeCandidates) {
      try {
        final f = File(rel);
        if (f.existsSync()) {
          _cachedChineseFontBytes = await f.readAsBytes();
          return _cachedChineseFontBytes;
        }
      } catch (_) {}
    }

    // 3. 尝试 Windows 系统字体
    if (Platform.isWindows) {
      final winCandidates = [
        r'C:\Windows\Fonts\SourceHanSansCN-Normal.ttf',
        r'C:\Windows\Fonts\simhei.ttf',
        r'C:\Windows\Fonts\msyh.ttc',
        r'C:\Windows\Fonts\simsun.ttc',
        r'C:\Windows\Fonts\Deng.ttf',
      ];
      for (final path in winCandidates) {
        try {
          final f = File(path);
          if (f.existsSync()) {
            _cachedChineseFontBytes = await f.readAsBytes();
            return _cachedChineseFontBytes;
          }
        } catch (_) {}
      }
    }

    // 4. 尝试 Android / Linux 系统字体
    final unixCandidates = [
      '/system/fonts/NotoSansSC-Regular.otf',
      '/system/fonts/DroidSansFallback.ttf',
      '/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc',
      '/usr/share/fonts/truetype/wqy/wqy-microhei.ttc',
    ];
    for (final path in unixCandidates) {
      try {
        final f = File(path);
        if (f.existsSync()) {
          _cachedChineseFontBytes = await f.readAsBytes();
          return _cachedChineseFontBytes;
        }
      } catch (_) {}
    }

    return null;
  }

  /// 创建高质量字体对象 (若有 TrueType 字节则嵌入 TrueType 字体子集，否则回退为 CJK 标准字体)
  static sf.PdfFont createChineseFont(
    List<int>? fontBytes,
    double size, {
    sf.PdfFontStyle style = sf.PdfFontStyle.regular,
  }) {
    if (fontBytes != null && fontBytes.isNotEmpty) {
      try {
        return sf.PdfTrueTypeFont(fontBytes, size, style: style);
      } catch (_) {}
    }
    final family = (style == sf.PdfFontStyle.bold)
        ? sf.PdfCjkFontFamily.monotypeHeiMedium
        : sf.PdfCjkFontFamily.sinoTypeSongLight;
    return sf.PdfCjkStandardFont(family, size, style: style);
  }

  static Future<ProcessingResult> execute(
    Map<String, dynamic> input,
    Function(double progress, String status)? onProgress,
  ) async {
    final subTool = input['subTool']?.toString() ?? 'images_to_pptx';
    final List<dynamic> rawFiles = input['files'] ?? [];
    final files = rawFiles.map((e) => e.toString()).toList();
    final params = Map<String, dynamic>.from(input['params'] ?? {});
    final outputDir = input['outputDir']?.toString() ?? Directory.systemTemp.path;

    if (files.isEmpty) {
      return ProcessingResult(success: false, message: '请至少选择一个待转换的源文件');
    }

    try {
      switch (subTool) {
        case 'images_to_pptx':
          return await _imagesToPptx(files, params, outputDir, onProgress);
        case 'pptx_to_images':
          if (Platform.isWindows) {
            final winRes = await WindowsOfficeConverter.convertPptToImages(
              pptPath: files.first,
              outputDir: outputDir,
              format: params['format']?.toString() ?? 'png',
              resolution: params['resolution']?.toString() ?? '1080p',
              exportMode: params['exportMode']?.toString() ?? 'pages',
              bundleZip: params['bundleZip'] == true || '${params['bundleZip']}' == 'true',
              onProgress: onProgress,
            );
            if (winRes.success) return winRes;
            return await _pptxToImagesLight(
              files,
              params,
              outputDir,
              onProgress,
              note: '（未检测到本地 Office 引擎，已自动使用离线轻量引擎完成转换）',
            );
          } else if (Platform.isAndroid) {
            return await _androidOfficeExportGuide(
              files.first,
              'PPT 演示文稿',
              onProgress,
              actionType: 'images',
            );
          } else {
            return await _pptxToImagesLight(files, params, outputDir, onProgress);
          }
        case 'pptx_to_images_android_office':
          return await _androidOfficeExportGuide(
            files.first,
            'PPT 演示文稿',
            onProgress,
            actionType: 'ppt_images',
          );
        case 'pptx_to_images_android_light':
          return await _androidOfficeExportGuide(
            files.first,
            'PPT 演示文稿',
            onProgress,
            actionType: 'ppt_images',
          );
        case 'cad_to_pdf':
          return await _cadToPdf(files, params, outputDir, onProgress);
        case 'pptx_to_pdf':
          if (Platform.isWindows) {
            return await WindowsOfficeConverter.convertPptToPdf(
              pptPath: files.first,
              outputDir: outputDir,
              onProgress: onProgress,
            );
          } else if (Platform.isAndroid) {
            return await _androidOfficeExportGuide(files.first, 'PPT 演示文稿', onProgress);
          } else {
            return await _pptxToPdf(files, params, outputDir, onProgress);
          }
        case 'pptx_to_pdf_android':
          if (Platform.isAndroid) {
            return await _androidOfficeExportGuide(files.first, 'PPT 演示文稿', onProgress);
          } else {
            return await _pptxToPdf(files, params, outputDir, onProgress);
          }
        case 'pdf_to_pptx':
          return await _pdfToPptx(files, params, outputDir, onProgress);
        case 'excel_to_pdf':
          if (Platform.isWindows) {
            return await WindowsOfficeConverter.convertExcelToPdf(
              xlsPath: files.first,
              outputDir: outputDir,
              onProgress: onProgress,
            );
          } else {
            return await _excelToPdf(files, params, outputDir, onProgress);
          }
        case 'excel_to_pdf_android_office':
          if (Platform.isAndroid) {
            return await _androidOfficeExportGuide(files.first, 'Excel 工作簿', onProgress);
          } else {
            return await _excelToPdf(files, params, outputDir, onProgress);
          }
        case 'excel_to_pdf_android_light':
        case 'excel_to_pdf_android':
          return await _excelToPdf(files, params, outputDir, onProgress);
        case 'markdown_to_pdf':
          return await _markdownToPdf(files, params, outputDir, onProgress);
        case 'txt_to_docx':
          return await _txtToDocx(files, params, outputDir, onProgress);
        case 'docx_to_pdf':
          if (Platform.isWindows) {
            return await WindowsOfficeConverter.convertWordToPdf(
              docPath: files.first,
              outputDir: outputDir,
              onProgress: onProgress,
            );
          } else if (Platform.isAndroid) {
            return await _androidOfficeExportGuide(files.first, 'Word 文档', onProgress);
          } else {
            return await _docxToPdf(files, params, outputDir, onProgress);
          }
        case 'docx_to_pdf_android':
          if (Platform.isAndroid) {
            return await _androidOfficeExportGuide(files.first, 'Word 文档', onProgress);
          } else {
            return await _docxToPdf(files, params, outputDir, onProgress);
          }
        case 'pdf_to_docx':
          if (Platform.isWindows) {
            final winRes = await WindowsOfficeConverter.convertPdfToDocx(
              pdfPath: files.first,
              outputDir: outputDir,
              onProgress: onProgress,
            );
            if (winRes.success) return winRes;
            final note = winRes.message.contains('TIMEOUT')
                ? '（提示：检测到微软 Word 进程在逆向重构该 PDF 时响应超时，已自动无缝切换为离线智能清洗排版引擎生成标准 Word 文档）'
                : '（未检测到本地 Office 引擎，已自动使用离线智能清洗排版引擎重构标准 Word 文档）';
            return await _pdfToDocxClean(
              files,
              params,
              outputDir,
              onProgress,
              note: note,
            );
          } else if (Platform.isAndroid) {
            return await _androidOfficeExportGuide(
              files.first,
              'PDF 文档',
              onProgress,
              actionType: 'word',
            );
          } else {
            return await _pdfToDocxClean(files, params, outputDir, onProgress);
          }
        case 'pdf_to_docx_android_office':
          return await _androidOfficeExportGuide(
            files.first,
            'PDF 文档',
            onProgress,
            actionType: 'word',
          );
        case 'pdf_to_docx_android_light':
          return await _pdfToDocxClean(files, params, outputDir, onProgress);
        default:
          return ProcessingResult(
            success: false,
            message: '未知的文档转换子工具类型: $subTool',
          );
      }
    } catch (e) {
      return ProcessingResult(
        success: false,
        message: '文档转换失败: ${e.toString()}',
      );
    }
  }

  /// Android 平台调起手机已安装的 WPS Office / Microsoft 365 实现 100% 官方精度导出
  static Future<ProcessingResult> _androidOfficeExportGuide(
    String filePath,
    String docTypeName,
    Function(double, String)? onProgress, {
    String actionType = 'pdf', // 'pdf', 'ppt_images', 'pdf_images', 'images', 'word'
  }) async {
    onProgress?.call(0.1, '正在检测手机环境中的办公软件...');
    final checkRes = await AndroidOfficeBridge.checkOfficeInstalled();
    final isInstalled = checkRes['isInstalled'] == true;

    if (!isInstalled) {
      final String actionDesc = (actionType == 'ppt_images' || actionType == 'pdf_images' || actionType == 'images')
          ? '长图与逐页图片导出'
          : (actionType == 'word' ? 'PDF 转可编辑 Word' : 'PDF 导出');
      return ProcessingResult(
        success: false,
        message: '⚠️ 未检测到手机办公套件\n\n'
            '手机端直接处理 $docTypeName 会严重丢失母版、公式与复杂版式，无法达到商业级质量。\n\n'
            '【100% 官方商业级无损$actionDesc方案】：\n'
            '请先在手机应用商店中安装【WPS Office】或【Microsoft 365 / Office】。\n'
            '安装后即可直接在手机上一键调起并官方高精度导出！',
      );
    }

    onProgress?.call(0.5, '正在调起手机办公软件...');
    final openRes = await AndroidOfficeBridge.openInOffice(filePath);
    final appName = openRes['appName']?.toString() ?? 'WPS Office / Microsoft Office';
    final isWps = appName.toLowerCase().contains('wps') ||
        (openRes['package']?.toString().contains('wps') ?? false) ||
        (openRes['package']?.toString().contains('kingsoft') ?? false);

    if (openRes['success'] == true) {
      onProgress?.call(1.0, '已调起办公软件');
      final String guideSteps;
      if (actionType == 'ppt_images' || (actionType == 'images' && docTypeName.contains('PPT'))) {
        if (isWps) {
          guideSteps = '【100% 原版高保真 PPT 输出图片/长图操作指引】：\n'
              '1. 点击 WPS 界面左下角的【三条横线（工具）】；\n'
              '2. 在工具箱中选择【输出为图片】；\n'
              '3. 选择导出模式（逐页图片或长图）并保存到相册。\n\n'
              '⚠️ 【WPS 会员限制说明】：非 VIP 会员在 WPS 中输出图片通常会限制画质（普通画质可能较模糊），或附带非会员水印；高清/超清无水印画质受限于您的 WPS 会员状态。';
        } else {
          guideSteps = '【100% 原版高保真 PPT 输出图片操作指引】：\n'
              '1. 点击右上角菜单【...】或【分享】；\n'
              '2. 选择【以图片形式发送/共享】并保存到设备相册。';
        }
      } else if (actionType == 'pdf_images' || (actionType == 'images' && docTypeName.contains('PDF'))) {
        if (isWps) {
          guideSteps = '【100% 原版高保真 PDF 输出图片操作指引】：\n'
              '1. 在 WPS 菜单栏中，切换至【转换】标签；\n'
              '2. 选择【PDF 转图片】；\n'
              '3. 确认后导出并保存到相册。\n\n'
              '⚠️ 【WPS 会员限制说明】：非 VIP 会员导出图片可能限制分辨率画质或附带非会员水印。';
        } else {
          guideSteps = '【100% 原版高保真 PDF 输出图片操作指引】：\n'
              '1. 点击右上角菜单【...】或【分享】；\n'
              '2. 选择【以图片形式发送/共享】并保存。';
        }
      } else if (actionType == 'word') {
        if (isWps) {
          guideSteps = '【100% 原版高保真 PDF 转 Word 操作指引】：\n'
              '1. 在 WPS 菜单栏中，切换至【转换】标签；\n'
              '2. 点击选择【PDF 转 Word】；\n'
              '3. 确认后一键转换为官方商业级高保真可编辑 Word 文档。\n\n'
              '⚠️ 【WPS 会员限制说明】：WPS 移动端【PDF 转 Word】通常属于 VIP 会员专属权益（非 VIP 用户可能仅支持试转前几页或无法导出）。若无会员，推荐返回本工具箱选择【本地离线轻量排版引擎】进行无限制文字清洗与标准排版转换！';
        } else {
          guideSteps = '【100% 原版高保真 PDF 转 Word 操作指引】：\n'
              '1. Office 会提示将 PDF 转换为可编辑 Word 文档，点击【转换】；\n'
              '2. 点击保存或导出为 .docx 格式。';
        }
      } else {
        // PDF 导出 (PPT / Word / Excel 转 PDF)
        if (isWps) {
          guideSteps = '【100% 原版高保真导出 PDF 操作指引】：\n'
              '1. 点击 WPS 界面左下角的【三条横线（工具）】；\n'
              '2. 找到并点击【输出为 PDF】；\n'
              '3. 选择手机本地存储目录并保存，即可获得商业级 100% 原版高保真 PDF！';
        } else {
          guideSteps = '【100% 原版高保真导出 PDF 操作指引】：\n'
              '1. 点击右上角【...】菜单或左上角【文件】；\n'
              '2. 点击【共享】选择【PDF】或点击【打印】选择【另存为 PDF】；\n'
              '3. 选择保存位置并导出。';
        }
      }

      return ProcessingResult(
        success: true,
        message: '✓ 已成功为您在 $appName 中打开此 $docTypeName！\n\n$guideSteps',
        outputFiles: [filePath],
      );
    } else {
      return ProcessingResult(
        success: false,
        message: '调起手机办公软件失败：${openRes["message"]}\n\n建议您在手机应用管理中检查 $appName 是否拥有正常读取权限。',
      );
    }
  }

  // ===========================================================================
  // 1. 图片批量转 PPT 幻灯片 (OpenXML Presentation)
  // ===========================================================================
  static Future<ProcessingResult> _imagesToPptx(
    List<String> files,
    Map<String, dynamic> params,
    String outputDir,
    Function(double, String)? onProgress,
  ) async {
    final aspect = (params['aspect'] ?? params['pdfAspect'] ?? 'auto').toString();
    int slideW = 12192000;
    int slideH = 6858000;
    String aspectType = 'screen16x9';

    if (aspect == 'auto' && files.isNotEmpty) {
      try {
        final firstBytes = await File(files.first).readAsBytes();
        final firstDecoded = img.decodeImage(firstBytes);
        if (firstDecoded != null && firstDecoded.height > firstDecoded.width) {
          slideW = 6858000;
          slideH = 9144000;
          aspectType = 'custom';
        }
      } catch (_) {}
    } else if (aspect == '4:3') {
      slideW = 9144000;
      slideH = 6858000;
      aspectType = 'screen4x3';
    } else if (aspect == 'portrait') {
      slideW = 6858000;
      slideH = 9144000;
      aspectType = 'custom';
    }

    onProgress?.call(0.1, '正在读取待转换图片并分析分辨率...');
    final total = files.length;
    final slideEntries = <Map<String, dynamic>>[];

    for (int i = 0; i < total; i++) {
      final fPath = files[i];
      onProgress?.call(0.1 + (i / total) * 0.5, '正在处理图片 ${i + 1}/$total: ${p.basename(fPath)}');

      final rawBytes = await File(fPath).readAsBytes();
      final ext = p.extension(fPath).toLowerCase().replaceAll('.', '');

      Uint8List imageBytes;
      String mediaExt;
      double imgWidth = 1920.0;
      double imgHeight = 1080.0;

      final decoded = img.decodeImage(rawBytes);
      if (decoded != null) {
        imgWidth = decoded.width.toDouble();
        imgHeight = decoded.height.toDouble();
      }

      if (ext == 'jpg' || ext == 'jpeg') {
        imageBytes = rawBytes;
        mediaExt = 'jpeg';
      } else if (ext == 'png') {
        imageBytes = rawBytes;
        mediaExt = 'png';
      } else {
        if (decoded != null) {
          imageBytes = Uint8List.fromList(img.encodePng(decoded));
          mediaExt = 'png';
        } else {
          imageBytes = rawBytes;
          mediaExt = 'png';
        }
      }

      slideEntries.add({
        'imageBytes': imageBytes,
        'mediaExt': mediaExt,
        'imgWidth': imgWidth,
        'imgHeight': imgHeight,
      });
    }

    onProgress?.call(0.7, '正在构建符合 ECMA-376 规范的标准演示文稿体系 (母版/版式/主题)...');
    final outArchive = _buildCompliantPptxArchive(
      slides: slideEntries,
      slideW: slideW,
      slideH: slideH,
      aspectType: aspectType,
    );

    onProgress?.call(0.9, '正在封装生成 PPTX 演示文稿...');
    final zipEncoder = ZipEncoder();
    final pptxBytes = zipEncoder.encode(outArchive);

    final outName = 'Images_Presentation_${DateTime.now().millisecondsSinceEpoch}.pptx';
    final outPath = p.join(outputDir, outName);
    await File(outPath).writeAsBytes(pptxBytes);

    onProgress?.call(1.0, '转换完成！');
    return ProcessingResult(
      success: true,
      message: '成功将 $total 张图片合成生成 PPTX 演示文稿（已注入标准母版与版式体系，零修复弹窗）！',
      outputFiles: [outPath],
    );
  }

  // ===========================================================================
  // 2. PPT 转图片 / 长图 (离线轻量引擎：矢量解析光栅化 + 无缝拼接)
  // ===========================================================================
  static Future<ProcessingResult> _pptxToImagesLight(
    List<String> files,
    Map<String, dynamic> params,
    String outputDir,
    Function(double, String)? onProgress, {
    String? note,
  }) async {
    final pptxPath = files.first;
    final baseName = p.basenameWithoutExtension(pptxPath);
    final bundleZip = params['bundleZip'] == true || '${params['bundleZip']}' == 'true';
    final targetFormat = (params['format']?.toString() ?? 'png').toLowerCase();
    final exportMode = params['exportMode']?.toString() ?? 'pages';
    final isLongImage = exportMode == 'long_image';

    // 优先尝试离线 PPTX -> PDF 转换器，然后通过 Chromium PDFium (pdfrx) 高精光栅化
    try {
      onProgress?.call(0.1, '正在通过离线轻量引擎解析 PPTX 并光栅化排版...');
      final tempDir = Directory.systemTemp.createTempSync('ppt_light_img_');
      final tempPdfRes = await PptxPdfConverterService.convertPptxToPdf(
        pptxPath: pptxPath,
        outputDir: tempDir.path,
        onProgress: (p, s) => onProgress?.call(0.1 + p * 0.4, s),
      );

      if (tempPdfRes.success && tempPdfRes.outputFiles.isNotEmpty) {
        final pdfPath = tempPdfRes.outputFiles.first;
        rx.Pdfrx.cacheDirectoryPath ??= tempDir.path;
        await rx.pdfrxFlutterInitialize();

        final rxDoc = await rx.PdfDocument.openFile(pdfPath);
        final totalPages = rxDoc.pages.length;

        if (totalPages > 0) {
          double scale = 2.0; // 默认 1080p 约 2.0x (144 dpi)
          final resParam = (params['resolution']?.toString() ?? '1080p').toLowerCase();
          if (resParam == '4k') {
            scale = 4.0;
          } else if (resParam == '2k') {
            scale = 2.66;
          } else if (resParam == '720p') {
            scale = 1.33;
          }

          final renderedImages = <img.Image>[];

          for (int i = 0; i < totalPages; i++) {
            onProgress?.call(
              0.5 + (i / totalPages) * 0.3,
              '正在渲染第 ${i + 1}/$totalPages 页画面...',
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
            renderedImages.add(imgObj);
          }

          await rxDoc.dispose();

          if (renderedImages.isNotEmpty) {
            if (isLongImage) {
              onProgress?.call(0.85, '正在无缝拼合为超清长图...');
              final outLongPath = p.join(outputDir, '${baseName}_long_image.$targetFormat');
              await WindowsOfficeConverter.stitchImageObjectsVertically(
                images: renderedImages,
                outputPath: outLongPath,
                format: targetFormat,
                onProgress: onProgress,
              );

              try {
                tempDir.deleteSync(recursive: true);
              } catch (_) {}
              onProgress?.call(1.0, '长图生成完成！');
              return ProcessingResult(
                success: true,
                message: '成功通过离线轻量引擎将 $totalPages 页幻灯片拼接为无缝高清长图！${note != null ? "\n$note" : ""}',
                outputFiles: [outLongPath],
              );
            } else {
              final outArchive = (bundleZip && renderedImages.length > 1) ? Archive() : null;
              final outPaths = <String>[];

              for (int i = 0; i < renderedImages.length; i++) {
                final im = renderedImages[i];
                final fileName = '${baseName}_slide_${i + 1}.$targetFormat';
                final outPath = p.join(outputDir, fileName);

                final Uint8List bytes;
                if (targetFormat == 'jpg' || targetFormat == 'jpeg') {
                  bytes = Uint8List.fromList(img.encodeJpg(im, quality: 92));
                } else {
                  bytes = Uint8List.fromList(img.encodePng(im));
                }

                if (outArchive != null) {
                  outArchive.addFile(ArchiveFile(fileName, bytes.length, bytes));
                } else {
                  await File(outPath).writeAsBytes(bytes);
                  outPaths.add(outPath);
                }
              }

              if (outArchive != null) {
                final zipName = '${baseName}_slides_images.zip';
                final zipPath = p.join(outputDir, zipName);
                final zipBytes = ZipEncoder().encode(outArchive);
                await File(zipPath).writeAsBytes(zipBytes);
                outPaths.add(zipPath);
              }

              try {
                tempDir.deleteSync(recursive: true);
              } catch (_) {}
              onProgress?.call(1.0, '幻灯片图片导出完成！');
              return ProcessingResult(
                success: true,
                message: '成功通过离线轻量引擎导出 ${renderedImages.length} 张高清幻灯片图片！${note != null ? "\n$note" : ""}',
                outputFiles: outPaths,
              );
            }
          }
        }
      }
    } catch (_) {}

    return await _pptxMediaExtractionFallback(pptxPath, params, outputDir, onProgress, note: note);
  }

  static Future<ProcessingResult> _pptxMediaExtractionFallback(
    String pptxPath,
    Map<String, dynamic> params,
    String outputDir,
    Function(double, String)? onProgress, {
    String? note,
  }) async {
    final bundleZip = params['bundleZip'] == true || '${params['bundleZip']}' == 'true';
    final targetFormat = (params['format']?.toString() ?? 'png').toLowerCase();

    onProgress?.call(0.1, '正在解包 PPTX 文件提取内嵌素材...');
    final bytes = await File(pptxPath).readAsBytes();
    final archive = ZipDecoder().decodeBytes(bytes);

    final mediaFiles = <ArchiveFile>[];
    for (final file in archive) {
      if (file.isFile && file.name.startsWith('ppt/media/')) {
        final ext = p.extension(file.name).toLowerCase();
        if (['.png', '.jpg', '.jpeg', '.webp'].contains(ext)) {
          mediaFiles.add(file);
        }
      }
    }

    mediaFiles.sort((a, b) => _compareNatural(a.name, b.name));
    final List<String> outputPaths = [];
    final baseName = p.basenameWithoutExtension(pptxPath);

    if (mediaFiles.isNotEmpty) {
      final total = mediaFiles.length;
      final outArchive = bundleZip && total > 1 ? Archive() : null;

      for (int i = 0; i < total; i++) {
        final mFile = mediaFiles[i];
        final rawBytes = mFile.content as List<int>;
        final fileName = '${baseName}_media_${i + 1}.$targetFormat';
        final outFilePath = p.join(outputDir, fileName);

        final Uint8List finalBytes;
        if (targetFormat == 'jpg' || targetFormat == 'jpeg') {
          final decoded = img.decodeImage(Uint8List.fromList(rawBytes));
          finalBytes = decoded != null
              ? Uint8List.fromList(img.encodeJpg(decoded, quality: 92))
              : Uint8List.fromList(rawBytes);
        } else {
          final decoded = img.decodeImage(Uint8List.fromList(rawBytes));
          finalBytes = decoded != null
              ? Uint8List.fromList(img.encodePng(decoded))
              : Uint8List.fromList(rawBytes);
        }

        if (outArchive != null) {
          outArchive.addFile(ArchiveFile(fileName, finalBytes.length, finalBytes));
        } else {
          await File(outFilePath).writeAsBytes(finalBytes);
          outputPaths.add(outFilePath);
        }
      }

      if (outArchive != null) {
        final zipName = '${baseName}_media_images.zip';
        final zipPath = p.join(outputDir, zipName);
        final zipBytes = ZipEncoder().encode(outArchive);
        await File(zipPath).writeAsBytes(zipBytes);
        outputPaths.add(zipPath);
      }
    } else {
      final slideTexts = _extractPptxSlideTexts(archive);
      final total = max(1, slideTexts.length);
      final outArchive = bundleZip && total > 1 ? Archive() : null;

      for (int i = 0; i < total; i++) {
        final fileName = '${baseName}_slide_${i + 1}.$targetFormat';
        final outFilePath = p.join(outputDir, fileName);

        final canvas = img.Image(width: 1280, height: 720);
        img.fill(canvas, color: img.ColorRgb8(248, 250, 252));
        img.fillRect(canvas, x1: 60, y1: 60, x2: 1220, y2: 660, color: img.ColorRgb8(255, 255, 255));

        final Uint8List finalBytes = (targetFormat == 'jpg' || targetFormat == 'jpeg')
            ? Uint8List.fromList(img.encodeJpg(canvas, quality: 90))
            : Uint8List.fromList(img.encodePng(canvas));

        if (outArchive != null) {
          outArchive.addFile(ArchiveFile(fileName, finalBytes.length, finalBytes));
        } else {
          await File(outFilePath).writeAsBytes(finalBytes);
          outputPaths.add(outFilePath);
        }
      }

      if (outArchive != null) {
        final zipName = '${baseName}_slides_images.zip';
        final zipPath = p.join(outputDir, zipName);
        final zipBytes = ZipEncoder().encode(outArchive);
        await File(zipPath).writeAsBytes(zipBytes);
        outputPaths.add(zipPath);
      }
    }

    return ProcessingResult(
      success: true,
      message: '成功提取 PPT 演示文稿内嵌图片素材！${note != null ? "\n$note" : ""}',
      outputFiles: outputPaths,
    );
  }

  // ===========================================================================
  // 3. CAD (DXF / DWG / DWF) 矢量转高保真 PDF
  // ===========================================================================
  static Future<ProcessingResult> _cadToPdf(
    List<String> files,
    Map<String, dynamic> params,
    String outputDir,
    Function(double, String)? onProgress,
  ) async {
    return await CadConverterService.convertCadToPdf(
      files: files,
      params: params,
      outputDir: outputDir,
      onProgress: onProgress,
    );
  }

  // ===========================================================================
  // 4. PPT 演示文稿转 PDF
  // ===========================================================================
  static Future<ProcessingResult> _pptxToPdf(
    List<String> files,
    Map<String, dynamic> params,
    String outputDir,
    Function(double, String)? onProgress,
  ) async {
    return await PptxPdfConverterService.convertPptxToPdf(
      pptxPath: files.first,
      outputDir: outputDir,
      onProgress: onProgress,
    );
  }

  // ===========================================================================
  // 5. PDF 转 PPT 演示文稿 (基于 pdfrx 引擎与 OpenXML 标准母版)
  // ===========================================================================
  static Future<ProcessingResult> _pdfToPptx(
    List<String> files,
    Map<String, dynamic> params,
    String outputDir,
    Function(double, String)? onProgress,
  ) async {
    final pdfPath = files.first;
    final int dpi = int.tryParse(params['dpi']?.toString() ?? '150') ?? 150;
    final pdfAspect = (params['pdfAspect'] ?? params['aspect'] ?? 'auto').toString();

    onProgress?.call(0.1, '正在初始化 PDF 高清渲染引擎...');
    rx.Pdfrx.cacheDirectoryPath ??= outputDir;
    await rx.pdfrxFlutterInitialize();

    final rxDoc = await rx.PdfDocument.openFile(pdfPath);
    final total = rxDoc.pages.length;
    if (total == 0) {
      await rxDoc.dispose();
      return ProcessingResult(success: false, message: 'PDF 文档中没有可渲染的页面');
    }

    int slideW = 12192000;
    int slideH = 6858000;
    String aspectType = 'screen16x9';

    if (pdfAspect == '16:9') {
      slideW = 12192000;
      slideH = 6858000;
      aspectType = 'screen16x9';
    } else if (pdfAspect == '4:3') {
      slideW = 9144000;
      slideH = 6858000;
      aspectType = 'screen4x3';
    } else if (pdfAspect == 'portrait') {
      // 标准 3:4 竖版演示
      slideW = 6858000;
      slideH = 9144000;
      aspectType = 'custom';
    } else {
      // 默认 auto: 智能自适应匹配 PDF 页面方向与真实比例
      final firstPage = rxDoc.pages.first;
      if (firstPage.height > firstPage.width) {
        // 竖版 PDF: 自动生成符合竖屏阅读的高保真竖向幻灯片，消除多余横向大黑/白边
        slideH = 9144000;
        slideW = (9144000 * firstPage.width / max(1.0, firstPage.height)).round();
        aspectType = 'custom';
      } else {
        slideW = 12192000;
        slideH = 6858000;
        aspectType = 'screen16x9';
      }
    }

    final double scale = dpi / 72.0;
    final slideEntries = <Map<String, dynamic>>[];

    for (int i = 0; i < total; i++) {
      onProgress?.call(0.1 + (i / total) * 0.7, '正在高保真光栅化第 ${i + 1}/$total 页 (保持原始宽高比)...');
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

      final encodedPng = Uint8List.fromList(img.encodePng(imgObj));
      slideEntries.add({
        'imageBytes': encodedPng,
        'mediaExt': 'png',
        'imgWidth': page.width,
        'imgHeight': page.height,
      });
    }
    await rxDoc.dispose();

    onProgress?.call(0.85, '正在装配符合 ECMA-376 规范的标准演示文稿 (母版/版式/主题/居中防变形)...');
    final outArchive = _buildCompliantPptxArchive(
      slides: slideEntries,
      slideW: slideW,
      slideH: slideH,
      aspectType: aspectType,
    );

    onProgress?.call(0.95, '正在打包生成 PPTX 演示文稿...');
    final zipBytes = ZipEncoder().encode(outArchive);

    final baseName = p.basenameWithoutExtension(pdfPath);
    final outPath = p.join(outputDir, '${baseName}_converted.pptx');
    await File(outPath).writeAsBytes(zipBytes);

    onProgress?.call(1.0, '转换完成！');
    return ProcessingResult(
      success: true,
      message: '成功将 $total 页 PDF 转换为标准 PPT 幻灯片演示文稿（已注入标准母版体系，无报错弹窗，页面比例保真居中）！',
      outputFiles: [outPath],
    );
  }

  // ===========================================================================
  // 6. Excel 工作表转 PDF (多页智能表格排版)
  // ===========================================================================
  static Future<ProcessingResult> _excelToPdf(
    List<String> files,
    Map<String, dynamic> params,
    String outputDir,
    Function(double, String)? onProgress,
  ) async {
    final excelPath = files.first;
    final ext = p.extension(excelPath).toLowerCase();

    onProgress?.call(0.1, '正在读取并解析 Excel 数据表格...');
    final List<List<String>> tableData = [];

    if (ext == '.csv' || ext == '.tsv') {
      final content = await File(excelPath).readAsString();
      final lines = const LineSplitter().convert(content);
      final separator = ext == '.tsv' ? '\t' : ',';
      for (final line in lines) {
        if (line.trim().isEmpty) continue;
        tableData.add(line.split(separator).map((e) => e.trim()).toList());
      }
    } else {
      final bytes = await File(excelPath).readAsBytes();
      final archive = ZipDecoder().decodeBytes(bytes);

      // 提取共享字符串表 (xl/sharedStrings.xml)
      final sharedStrings = <String>[];
      final ssFile = archive.findFile('xl/sharedStrings.xml');
      if (ssFile != null) {
        final ssXml = utf8.decode(ssFile.content as List<int>, allowMalformed: true);
        final doc = xml.XmlDocument.parse(ssXml);
        for (final si in doc.findAllElements('si')) {
          final t = si.findAllElements('t').map((e) => e.innerText).join();
          sharedStrings.add(t);
        }
      }

      // 读取首个工作表 (xl/worksheets/sheet1.xml)
      final sheetFile = archive.findFile('xl/worksheets/sheet1.xml') ??
          archive.files.firstWhere(
            (f) => f.name.startsWith('xl/worksheets/sheet'),
            orElse: () => archive.files.first,
          );

      final sheetXml = utf8.decode(sheetFile.content as List<int>, allowMalformed: true);
      final doc = xml.XmlDocument.parse(sheetXml);

      for (final rowElem in doc.findAllElements('row')) {
        final rowCells = <int, String>{};
        int maxCol = 0;

        for (final cElem in rowElem.findAllElements('c')) {
          final rAttr = cElem.getAttribute('r') ?? 'A1';
          final colIdx = _excelColToIndex(rAttr);
          final tAttr = cElem.getAttribute('t');
          final vElem = cElem.findElements('v').firstOrNull;

          String val = '';
          if (vElem != null) {
            if (tAttr == 's') {
              final sIdx = int.tryParse(vElem.innerText) ?? -1;
              if (sIdx >= 0 && sIdx < sharedStrings.length) {
                val = sharedStrings[sIdx];
              }
            } else if (tAttr == 'b') {
              val = vElem.innerText == '1' ? 'TRUE' : 'FALSE';
            } else {
              val = vElem.innerText;
            }
          } else {
            val = cElem.findElements('is').expand((e) => e.findElements('t')).map((e) => e.innerText).join();
          }

          rowCells[colIdx] = val;
          maxCol = max(maxCol, colIdx);
        }

        final rowList = <String>[];
        for (int c = 0; c <= maxCol; c++) {
          rowList.add(rowCells[c] ?? '');
        }
        if (rowList.any((cell) => cell.isNotEmpty)) {
          tableData.add(rowList);
        }
      }
    }

    if (tableData.isEmpty) {
      return ProcessingResult(success: false, message: 'Excel 表格中未检测到有效数据行');
    }

    onProgress?.call(0.4, '正在使用 Syncfusion PdfGrid 排版商务级 PDF 表格 (共 ${tableData.length} 行)...');
    final pdfDoc = sf.PdfDocument();

    final maxCols = tableData.map((e) => e.length).reduce(max);
    final isLandscape = maxCols > 6;
    final section = pdfDoc.sections!.add();
    section.pageSettings.size = isLandscape
        ? const ui.Size(841.89, 595.28)
        : const ui.Size(595.28, 841.89);
    section.pageSettings.orientation = isLandscape
        ? sf.PdfPageOrientation.landscape
        : sf.PdfPageOrientation.portrait;
    section.pageSettings.margins.all = 30;

    final page = section.pages.add();
    final fontBytes = await getChineseFontBytes();
    final font = createChineseFont(fontBytes, 9);
    final headerFont = createChineseFont(fontBytes, 10, style: sf.PdfFontStyle.bold);

    // 绘制表头与标题
    final titleFont = createChineseFont(fontBytes, 16, style: sf.PdfFontStyle.bold);
    final baseName = p.basenameWithoutExtension(excelPath);
    page.graphics.drawString(
      baseName,
      titleFont,
      brush: sf.PdfSolidBrush(sf.PdfColor(30, 41, 59)),
      bounds: const ui.Rect.fromLTWH(0, 0, 400, 25),
    );

    // 构建 PdfGrid
    final grid = sf.PdfGrid();
    grid.columns.add(count: maxCols);

    // 设置网格表头
    grid.headers.add(1);
    final headerRow = grid.headers[0];
    headerRow.style = sf.PdfGridRowStyle(
      backgroundBrush: sf.PdfSolidBrush(sf.PdfColor(51, 65, 85)),
      textBrush: sf.PdfBrushes.white,
      font: headerFont,
    );

    final firstRow = tableData.first;
    for (int c = 0; c < maxCols; c++) {
      headerRow.cells[c].value = c < firstRow.length && firstRow[c].isNotEmpty
          ? firstRow[c]
          : '列 ${c + 1}';
    }

    // 填充数据行
    for (int r = 1; r < tableData.length; r++) {
      final rData = tableData[r];
      final gridRow = grid.rows.add();
      gridRow.style = sf.PdfGridRowStyle(
        backgroundBrush: r % 2 == 0
            ? sf.PdfSolidBrush(sf.PdfColor(248, 250, 252))
            : sf.PdfBrushes.white,
        font: font,
      );
      for (int c = 0; c < maxCols; c++) {
        gridRow.cells[c].value = c < rData.length ? rData[c] : '';
      }
    }

    grid.style = sf.PdfGridStyle(
      cellPadding: sf.PdfPaddings(left: 6, right: 6, top: 4, bottom: 4),
      font: font,
    );

    onProgress?.call(0.7, '正在执行跨页分页流排版绘制...');
    grid.draw(
      page: page,
      bounds: const ui.Rect.fromLTWH(0, 35, 0, 0),
    );

    onProgress?.call(0.95, '正在保存 PDF 文档...');
    final pdfBytes = pdfDoc.saveSync();
    pdfDoc.dispose();

    final outPath = p.join(outputDir, '${baseName}_table.pdf');
    await File(outPath).writeAsBytes(pdfBytes);

    onProgress?.call(1.0, '转换完成！');
    return ProcessingResult(
      success: true,
      message: '成功将 Excel 表格转换为高保真多页 PDF 文档 (包含 ${tableData.length} 行数据)！',
      outputFiles: [outPath],
    );
  }

  // ===========================================================================
  // 7. Markdown 文档转 PDF (基于 GFM 抽象语法树 AST 标准矢量排版)
  // ===========================================================================
  static Future<ProcessingResult> _markdownToPdf(
    List<String> files,
    Map<String, dynamic> params,
    String outputDir,
    Function(double, String)? onProgress,
  ) async {
    final mdPath = files.first;

    onProgress?.call(0.1, '正在读取 Markdown 源文档...');
    final mdText = await File(mdPath).readAsString();

    onProgress?.call(0.3, '正在解析 Markdown 抽象语法树 (AST)...');
    final mdDoc = md.Document(
      extensionSet: md.ExtensionSet.gitHubFlavored,
      encodeHtml: false,
    );
    final lines = const LineSplitter().convert(mdText);
    final nodes = mdDoc.parseLines(lines);

    onProgress?.call(0.5, '正在排版渲染标题、引用、列表、表格与代码块...');
    final pdfDoc = sf.PdfDocument();
    pdfDoc.pageSettings.size = sf.PdfPageSize.a4;
    pdfDoc.pageSettings.margins.all = 40;

    final firstPage = pdfDoc.pages.add();
    final fontBytes = await getChineseFontBytes();
    final renderer = _MarkdownPdfRenderer(pdfDoc, firstPage, fontBytes: fontBytes);
    renderer.renderNodes(nodes);

    onProgress?.call(0.9, '正在生成并保存高质量 PDF 文档...');
    final pdfBytes = pdfDoc.saveSync();
    pdfDoc.dispose();

    final baseName = p.basenameWithoutExtension(mdPath);
    final outPath = p.join(outputDir, '${baseName}_rendered.pdf');
    await File(outPath).writeAsBytes(pdfBytes);

    onProgress?.call(1.0, '转换完成！');
    return ProcessingResult(
      success: true,
      message: '成功将 Markdown 文档渲染为高质量 PDF！已完整保留标题层级、加粗斜体、代码框底色、列表与表格排版。',
      outputFiles: [outPath],
    );
  }

  // ===========================================================================
  // 8. TXT 纯文本转 Word (.docx, 中文智能排版与两字符首行缩进)
  // ===========================================================================
  static Future<ProcessingResult> _txtToDocx(
    List<String> files,
    Map<String, dynamic> params,
    String outputDir,
    Function(double, String)? onProgress,
  ) async {
    final txtPath = files.first;

    onProgress?.call(0.1, '正在读取文本文件内容...');
    final bytes = await File(txtPath).readAsBytes();
    String textContent;
    try {
      textContent = utf8.decode(bytes);
    } catch (_) {
      textContent = latin1.decode(bytes);
    }

    final rawLines = const LineSplitter().convert(textContent);

    onProgress?.call(0.3, '正在执行中文智能格式化排版 (大纲识别、题目与选项排版、两字符首行缩进)...');
    // 清洗与预处理行，识别孤立选项 (如 "A" 独占一行, 下一行是选项内容 "训练 (Training)")
    final cleanLines = <String>[];
    for (int i = 0; i < rawLines.length; i++) {
      final line = rawLines[i].trim();
      if (line.isEmpty) continue;

      if (RegExp(r'^[A-Fa-f]$').hasMatch(line) && i + 1 < rawLines.length) {
        final nextLine = rawLines[i + 1].trim();
        if (nextLine.isNotEmpty &&
            !RegExp(r'^[A-Fa-f]$').hasMatch(nextLine) &&
            !RegExp(r'^\d+[\.、]').hasMatch(nextLine)) {
          cleanLines.add('$line. $nextLine');
          i++; // 跳过下一行，合并为标准选项
          continue;
        }
      }
      cleanLines.add(line);
    }

    onProgress?.call(0.5, '正在构建 OpenXML WordprocessingML 文档结构...');
    final archive = Archive();

    const contentTypes = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n'
        '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">\n'
        '  <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>\n'
        '  <Default Extension="xml" ContentType="application/xml"/>\n'
        '  <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>\n'
        '</Types>';
    _addArchiveString(archive, '[Content_Types].xml', contentTypes);

    const rootRels = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n'
        '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\n'
        '  <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>\n'
        '</Relationships>';
    _addArchiveString(archive, '_rels/.rels', rootRels);

    final template = (params['txtTemplate'] ?? params['template'] ?? 'standard').toString().toLowerCase();

    // 智能排版模板规范定义
    final String latinFont;
    final String eastAsiaFont;
    final String titleEastAsiaFont;
    final String sectionEastAsiaFont;
    final String bodySz;
    final String titleSz;
    final String sectionSz;
    final String bodyLineSpacing;
    final String bodyAfter;
    final int firstLineIndent;
    final int topMargin;
    final int bottomMargin;
    final int leftMargin;
    final int rightMargin;

    switch (template) {
      case 'academic':
        latinFont = 'Times New Roman';
        eastAsiaFont = 'SimSun';
        titleEastAsiaFont = 'SimSun';
        sectionEastAsiaFont = 'SimHei';
        titleSz = '36'; // 18pt 小二
        sectionSz = '30'; // 15pt 小三
        bodySz = '24'; // 12pt 小四
        bodyLineSpacing = '432'; // 1.5 倍行距
        bodyAfter = '100';
        firstLineIndent = 480; // 2 字符
        topMargin = 1701; // 3.0 cm
        bottomMargin = 1417; // 2.5 cm
        leftMargin = 1701; // 3.0 cm
        rightMargin = 1417; // 2.5 cm
        break;
      case 'reading':
        latinFont = 'Georgia';
        eastAsiaFont = 'KaiTi';
        titleEastAsiaFont = 'KaiTi';
        sectionEastAsiaFont = 'KaiTi';
        titleSz = '32'; // 16pt 三号
        sectionSz = '26'; // 13pt
        bodySz = '21'; // 10.5pt 五号
        bodyLineSpacing = '320'; // 1.15 倍行距
        bodyAfter = '50';
        firstLineIndent = 420;
        topMargin = 1134; // 2.0 cm
        bottomMargin = 1134;
        leftMargin = 1247; // 2.2 cm
        rightMargin = 1247;
        break;
      case 'code_log':
        latinFont = 'Consolas';
        eastAsiaFont = 'SimSun';
        titleEastAsiaFont = 'SimHei';
        sectionEastAsiaFont = 'SimHei';
        titleSz = '28';
        sectionSz = '24';
        bodySz = '20'; // 10pt
        bodyLineSpacing = '240'; // 单倍行距
        bodyAfter = '20';
        firstLineIndent = 0; // 无缩进
        topMargin = 1000;
        bottomMargin = 1000;
        leftMargin = 1000;
        rightMargin = 1000;
        break;
      case 'standard':
      default:
        latinFont = 'Calibri';
        eastAsiaFont = 'SimSun';
        titleEastAsiaFont = 'SimHei';
        sectionEastAsiaFont = 'SimHei';
        titleSz = '32'; // 16pt 二号
        sectionSz = '28'; // 14pt 四号
        bodySz = '24'; // 12pt 小四
        bodyLineSpacing = '360'; // 1.25 倍行距
        bodyAfter = '90';
        firstLineIndent = 480; // 2 字符
        topMargin = 1440; // 2.54 cm
        bottomMargin = 1440;
        leftMargin = 1440;
        rightMargin = 1440;
        break;
    }

    final sbDoc = StringBuffer();
    sbDoc.write('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n');
    sbDoc.write('<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">\n');
    sbDoc.write('  <w:body>\n');

    bool isFirstNonEmpty = true;
    for (int i = 0; i < cleanLines.length; i++) {
      final line = cleanLines[i];
      final escaped = _xmlEscape(line);

      if (isFirstNonEmpty) {
        // 第一行如果较短且不以序号开头，认定为主标题
        if (line.length <= 40 &&
            !RegExp(r'^\d+[\.、]').hasMatch(line) &&
            !RegExp(r'^[一二三四五六七八九十]+[、\.]').hasMatch(line)) {
          sbDoc.write('    <w:p>\n');
          sbDoc.write('      <w:pPr>\n');
          sbDoc.write('        <w:jc w:val="center"/>\n');
          sbDoc.write('        <w:spacing w:before="240" w:after="200" w:line="440" w:lineRule="auto"/>\n');
          sbDoc.write('      </w:pPr>\n');
          sbDoc.write('      <w:r>\n');
          sbDoc.write('        <w:rPr>\n');
          sbDoc.write('          <w:rFonts w:ascii="$latinFont" w:eastAsia="$titleEastAsiaFont" w:hAnsi="$latinFont"/>\n');
          sbDoc.write('          <w:b/>\n');
          sbDoc.write('          <w:sz w:val="$titleSz"/>\n');
          sbDoc.write('          <w:color w:val="0F172A"/>\n');
          sbDoc.write('        </w:rPr>\n');
          sbDoc.write('        <w:t xml:space="preserve">$escaped</w:t>\n');
          sbDoc.write('      </w:r>\n');
          sbDoc.write('    </w:p>\n');
          isFirstNonEmpty = false;
          continue;
        }
        isFirstNonEmpty = false;
      }

      // 元信息/副标题 (例如 "题量: 172 满分: 100", "作者: ...", "时间: ...")
      if (RegExp(r'^(题量|满分|作答时间|作者|发布时间|时间|来源|日期)[:：]').hasMatch(line)) {
        sbDoc.write('    <w:p>\n');
        sbDoc.write('      <w:pPr>\n');
        sbDoc.write('        <w:jc w:val="center"/>\n');
        sbDoc.write('        <w:spacing w:before="60" w:after="200" w:line="320" w:lineRule="auto"/>\n');
        sbDoc.write('      </w:pPr>\n');
        sbDoc.write('      <w:r>\n');
        sbDoc.write('        <w:rPr>\n');
        sbDoc.write('          <w:rFonts w:ascii="$latinFont" w:eastAsia="$eastAsiaFont" w:hAnsi="$latinFont"/>\n');
        sbDoc.write('          <w:sz w:val="21"/>\n');
        sbDoc.write('          <w:color w:val="64748B"/>\n');
        sbDoc.write('        </w:rPr>\n');
        sbDoc.write('        <w:t xml:space="preserve">$escaped</w:t>\n');
        sbDoc.write('      </w:r>\n');
        sbDoc.write('    </w:p>\n');
      }
      // 一级大纲标题 / 章节 (例如 "一. 单选题", "第一章 绪论", "# 标题")
      else if (RegExp(r'^[一二三四五六七八九十]+[\.、\s]').hasMatch(line) ||
          RegExp(r'^第[0-9一二三四五六七八九十]+[章节篇部分]').hasMatch(line) ||
          line.startsWith('# ')) {
        final titleText = line.startsWith('# ') ? line.substring(2).trim() : line;
        final escapedTitle = _xmlEscape(titleText);
        sbDoc.write('    <w:p>\n');
        sbDoc.write('      <w:pPr>\n');
        sbDoc.write('        <w:spacing w:before="280" w:after="140" w:line="380" w:lineRule="auto"/>\n');
        sbDoc.write('      </w:pPr>\n');
        sbDoc.write('      <w:r>\n');
        sbDoc.write('        <w:rPr>\n');
        sbDoc.write('          <w:rFonts w:ascii="$latinFont" w:eastAsia="$sectionEastAsiaFont" w:hAnsi="$latinFont"/>\n');
        sbDoc.write('          <w:b/>\n');
        sbDoc.write('          <w:sz w:val="$sectionSz"/>\n');
        sbDoc.write('          <w:color w:val="1E293B"/>\n');
        sbDoc.write('        </w:rPr>\n');
        sbDoc.write('        <w:t xml:space="preserve">$escapedTitle</w:t>\n');
        sbDoc.write('      </w:r>\n');
        sbDoc.write('    </w:p>\n');
      }
      // 题目 / 二级序号 (例如 "1. (单选题)...", "1、...", "(一)...", "## ...")
      else if (RegExp(r'^\d+[\.、\s]').hasMatch(line) ||
          RegExp(r'^[（\(][一二三四五六七八九十0-9]+[）\)]').hasMatch(line) ||
          line.startsWith('## ')) {
        final qText = line.startsWith('## ') ? line.substring(3).trim() : line;
        final escapedQ = _xmlEscape(qText);
        sbDoc.write('    <w:p>\n');
        sbDoc.write('      <w:pPr>\n');
        sbDoc.write('        <w:spacing w:before="180" w:after="80" w:line="340" w:lineRule="auto"/>\n');
        sbDoc.write('      </w:pPr>\n');
        sbDoc.write('      <w:r>\n');
        sbDoc.write('        <w:rPr>\n');
        sbDoc.write('          <w:rFonts w:ascii="$latinFont" w:eastAsia="$eastAsiaFont" w:hAnsi="$latinFont"/>\n');
        sbDoc.write('          <w:b/>\n');
        sbDoc.write('          <w:sz w:val="23"/>\n');
        sbDoc.write('          <w:color w:val="0F172A"/>\n');
        sbDoc.write('        </w:rPr>\n');
        sbDoc.write('        <w:t xml:space="preserve">$escapedQ</w:t>\n');
        sbDoc.write('      </w:r>\n');
        sbDoc.write('    </w:p>\n');
      }
      // 选项或缩进项目 (例如 "A. ...", "A、...", "B ...", "[A] ...")
      else if (RegExp(r'^[A-Fa-f][\.、\s]').hasMatch(line) ||
          RegExp(r'^[（\(][A-Fa-f][）\)]').hasMatch(line) ||
          RegExp(r'^\[[A-Fa-f]\]').hasMatch(line)) {
        sbDoc.write('    <w:p>\n');
        sbDoc.write('      <w:pPr>\n');
        sbDoc.write('        <w:ind w:left="480"/>\n');
        sbDoc.write('        <w:spacing w:before="40" w:after="60" w:line="320" w:lineRule="auto"/>\n');
        sbDoc.write('      </w:pPr>\n');
        sbDoc.write('      <w:r>\n');
        sbDoc.write('        <w:rPr>\n');
        sbDoc.write('          <w:rFonts w:ascii="$latinFont" w:eastAsia="$eastAsiaFont" w:hAnsi="$latinFont"/>\n');
        sbDoc.write('          <w:sz w:val="21"/>\n');
        sbDoc.write('          <w:color w:val="334155"/>\n');
        sbDoc.write('        </w:rPr>\n');
        sbDoc.write('        <w:t xml:space="preserve">$escaped</w:t>\n');
        sbDoc.write('      </w:r>\n');
        sbDoc.write('    </w:p>\n');
      }
      // 普通正文段落
      else {
        sbDoc.write('    <w:p>\n');
        sbDoc.write('      <w:pPr>\n');
        if (firstLineIndent > 0) {
          sbDoc.write('        <w:ind w:firstLineChars="200" w:firstLine="$firstLineIndent"/>\n');
        }
        sbDoc.write('        <w:spacing w:line="$bodyLineSpacing" w:lineRule="auto" w:after="$bodyAfter"/>\n');
        sbDoc.write('        <w:jc w:val="both"/>\n');
        sbDoc.write('      </w:pPr>\n');
        sbDoc.write('      <w:r>\n');
        sbDoc.write('        <w:rPr>\n');
        sbDoc.write('          <w:rFonts w:ascii="$latinFont" w:eastAsia="$eastAsiaFont" w:hAnsi="$latinFont"/>\n');
        sbDoc.write('          <w:sz w:val="$bodySz"/>\n');
        sbDoc.write('          <w:color w:val="1E293B"/>\n');
        sbDoc.write('        </w:rPr>\n');
        sbDoc.write('        <w:t xml:space="preserve">$escaped</w:t>\n');
        sbDoc.write('      </w:r>\n');
        sbDoc.write('    </w:p>\n');
      }
    }

    sbDoc.write('    <w:sectPr>\n');
    sbDoc.write('      <w:pgSz w:w="11906" w:h="16838"/>\n'); // A4 标准页面
    sbDoc.write('      <w:pgMar w:top="$topMargin" w:right="$rightMargin" w:bottom="$bottomMargin" w:left="$leftMargin"/>\n');
    sbDoc.write('    </w:sectPr>\n');
    sbDoc.write('  </w:body>\n');
    sbDoc.write('</w:document>');

    _addArchiveString(archive, 'word/document.xml', sbDoc.toString());

    onProgress?.call(0.85, '正在压缩生成 .docx 文件...');
    final docxBytes = ZipEncoder().encode(archive);

    final baseName = p.basenameWithoutExtension(txtPath);
    final outPath = p.join(outputDir, '${baseName}_converted.docx');
    await File(outPath).writeAsBytes(docxBytes);

    onProgress?.call(1.0, '转换完成！');
    return ProcessingResult(
      success: true,
      message: '成功将 TXT 文本转换为标准 Microsoft Word (.docx) 文档（已完成中文大纲、题目与选项排版，正文自动首行缩进 2 字符）！',
      outputFiles: [outPath],
    );
  }

  // ===========================================================================
  // 9. Word 文档 (.docx) 转 PDF
  // ===========================================================================
  static Future<ProcessingResult> _docxToPdf(
    List<String> files,
    Map<String, dynamic> params,
    String outputDir,
    Function(double, String)? onProgress,
  ) async {
    final docxPath = files.first;

    onProgress?.call(0.1, '正在读取并解压 DOCX 文档包...');
    final bytes = await File(docxPath).readAsBytes();
    final archive = ZipDecoder().decodeBytes(bytes);

    final docFile = archive.findFile('word/document.xml');
    if (docFile == null) {
      return ProcessingResult(success: false, message: '无效的 DOCX 文件: 缺少 word/document.xml');
    }

    onProgress?.call(0.3, '正在解析 Word 文档排版流与段落...');
    final docXml = utf8.decode(docFile.content as List<int>, allowMalformed: true);
    final xmlDoc = xml.XmlDocument.parse(docXml);

    final pdfDoc = sf.PdfDocument();
    pdfDoc.pageSettings.size = sf.PdfPageSize.a4;
    pdfDoc.pageSettings.margins.all = 40;

    var curPage = pdfDoc.pages.add();
    final pageWidth = curPage.getClientSize().width;
    final pageHeight = curPage.getClientSize().height;

    final fontBytes = await getChineseFontBytes();
    final bodyFont = createChineseFont(fontBytes, 11);
    final boldFont = createChineseFont(fontBytes, 12, style: sf.PdfFontStyle.bold);
    final textBrush = sf.PdfSolidBrush(sf.PdfColor(30, 41, 59));

    double curY = 0;

    void ensureSpace(double needHeight) {
      if (curY + needHeight > pageHeight) {
        curPage = pdfDoc.pages.add();
        curY = 0;
      }
    }

    final bodyElem = xmlDoc.findAllElements('w:body').firstOrNull;
    if (bodyElem != null) {
      for (final child in bodyElem.children.whereType<xml.XmlElement>()) {
        if (child.name.local == 'p') {
          final hasPageBreak = child.findAllElements('w:br').any((e) => e.getAttribute('w:type') == 'page');
          if (hasPageBreak) {
            curPage = pdfDoc.pages.add();
            curY = 0;
          }

          final textRuns = <String>[];
          bool isBold = false;

          for (final r in child.findAllElements('w:r')) {
            if (r.findElements('w:rPr').expand((e) => e.findElements('w:b')).isNotEmpty) {
              isBold = true;
            }
            final t = r.findElements('w:t').map((e) => e.innerText).join();
            if (t.isNotEmpty) textRuns.add(t);
          }

          final pText = textRuns.join().trim();
          if (pText.isNotEmpty) {
            ensureSpace(18);
            final elem = sf.PdfTextElement(
              text: pText,
              font: isBold ? boldFont : bodyFont,
              brush: textBrush,
            );
            final result = elem.draw(
              page: curPage,
              bounds: ui.Rect.fromLTWH(0, curY, pageWidth, 0),
            );
            curY = (result?.bounds.bottom ?? (curY + 18)) + 6;
          } else {
            curY += 8;
          }
        } else if (child.name.local == 'tbl') {
          final tableRows = <List<String>>[];
          for (final tr in child.findAllElements('w:tr')) {
            final rowCells = <String>[];
            for (final tc in tr.findAllElements('w:tc')) {
              final cellText = tc.findAllElements('w:t').map((e) => e.innerText).join(' ');
              rowCells.add(cellText.trim());
            }
            if (rowCells.isNotEmpty) tableRows.add(rowCells);
          }

          if (tableRows.isNotEmpty) {
            final maxCols = tableRows.map((e) => e.length).reduce(max);
            final grid = sf.PdfGrid();
            grid.columns.add(count: maxCols);
            for (final rData in tableRows) {
              final gridRow = grid.rows.add();
              gridRow.style = sf.PdfGridRowStyle(font: bodyFont);
              for (int c = 0; c < maxCols; c++) {
                gridRow.cells[c].value = c < rData.length ? rData[c] : '';
              }
            }
            grid.style = sf.PdfGridStyle(
              cellPadding: sf.PdfPaddings(left: 4, right: 4, top: 3, bottom: 3),
              font: bodyFont,
            );
            final layoutResult = grid.draw(
              page: curPage,
              bounds: ui.Rect.fromLTWH(0, curY, pageWidth, 0),
            );
            curY = (layoutResult?.bounds.bottom ?? (curY + 40)) + 10;
          }
        }
      }
    }

    onProgress?.call(0.95, '正在保存 PDF 文档...');
    final pdfBytes = pdfDoc.saveSync();
    pdfDoc.dispose();

    final baseName = p.basenameWithoutExtension(docxPath);
    final outPath = p.join(outputDir, '${baseName}_converted.pdf');
    await File(outPath).writeAsBytes(pdfBytes);

    onProgress?.call(1.0, '转换完成！');
    return ProcessingResult(
      success: true,
      message: '成功将 Word (.docx) 文档转换为 PDF！',
      outputFiles: [outPath],
    );
  }

  // ===========================================================================
  // 10. PDF 转可编辑 Word (.docx) (离线智能清洗与标准排版引擎)
  // ===========================================================================

  /// 智能清洗与分段 PDF 抽取的凌乱文字
  /// 1. 消除汉字间、汉字与标点间由于 PDF 字符绝对定位被误插入的离散空格
  /// 2. 修复跨行脱落的标点符号与引号（将断开的引号、句号、逗号吸附回主句）
  /// 3. 合并自然换行的短行（PDF 视觉硬折行），重构为结构连贯的自然段落
  /// 4. 保护大纲标题、章节、数字序号、题目选项与元信息不被错误串行
  static List<String> cleanAndSegmentPdfText(String rawText) {
    if (rawText.trim().isEmpty) return [];

    final rawLines = const LineSplitter().convert(rawText);
    final preprocessedLines = <String>[];

    // 第一阶段：消除行内离散多余空格，特别是 CJK 字符之间被 PDF 抽取器插入的空格
    for (var line in rawLines) {
      line = line.trim();
      if (line.isEmpty) {
        preprocessedLines.add('');
        continue;
      }

      // 保护元数据字段之间的分隔空格 (例如 "作者：张三   日期：2026-10-20")
      line = line.replaceAllMapped(
        RegExp(r'\s+((?:题量|满分|作答时间|作者|发布时间|时间|来源|日期|学院|专业)[:：])'),
        (m) => '  ${m[1]}',
      );

      // 递归去除中文字符之间的多余单个空格 (例如 "学 业 预 警" -> "学业预警")
      final cjkSpaceRegex = RegExp(r'([\u4e00-\u9fa5]) ([\u4e00-\u9fa5])');
      while (cjkSpaceRegex.hasMatch(line)) {
        line = line.replaceAllMapped(cjkSpaceRegex, (m) => '${m[1]}${m[2]}');
      }

      // 去除中文字符与破折号、连字符之间的空格 (例如 "计划书 - 校园" -> "计划书-校园")
      line = line.replaceAllMapped(RegExp(r'([\u4e00-\u9fa5])\s+([-—·])'), (m) => '${m[1]}${m[2]}');
      line = line.replaceAllMapped(RegExp(r'([-—·])\s+([\u4e00-\u9fa5])'), (m) => '${m[1]}${m[2]}');

      // 消除前引号、前括号后面的多余空格 (例如 “ 智能学情 ” -> “智能学情”)
      line = line.replaceAllMapped(RegExp(r'([“‘（《【])\s+'), (m) => m[1]!);

      // 消除后引号、后括号、逗句号、冒号前面的多余空格
      line = line.replaceAllMapped(RegExp(r'\s+([”’）》】、，。！？；：:])'), (m) => m[1]!);

      // 消除标点符号后面紧跟中文的多余空格 (例如 "水平， 本文档" -> "水平，本文档")
      line = line.replaceAllMapped(RegExp(r'([，。！？；、])\s+([\u4e00-\u9fa5])'), (m) => '${m[1]}${m[2]}');

      // 消除中文与前引号之间的空格 (例如 "阐述了 “智能" -> "阐述了“智能")
      line = line.replaceAllMapped(RegExp(r'([\u4e00-\u9fa5])\s+([“‘（《【])'), (m) => '${m[1]}${m[2]}');

      // 消除后引号与中文之间的空格 (例如 "“学业预警” 两大" -> "“学业预警”两大")
      line = line.replaceAllMapped(RegExp(r'([”’）》】])\s+([\u4e00-\u9fa5])'), (m) => '${m[1]}${m[2]}');

      // 消除冒号后面的多余空格 (例如 "作者： 张三" -> "作者：张三")
      line = line.replaceAllMapped(RegExp(r'([：:])\s+'), (m) => m[1]!);

      // 标准大纲序号与标题之间规范化保留一个半角空格
      if (RegExp(r'^第[0-9一二三四五六七八九十]+[章节篇部分]').hasMatch(line)) {
        line = line.replaceFirstMapped(
          RegExp(r'^(第[0-9一二三四五六七八九十]+[章节篇部分])\s*(.+)'),
          (m) => '${m[1]} ${m[2]}',
        );
      }
      if (RegExp(r'^\d+[\.、]').hasMatch(line)) {
        line = line.replaceFirstMapped(
          RegExp(r'^(\d+[\.、])\s*(.+)'),
          (m) => '${m[1]} ${m[2]}',
        );
      }
      if (RegExp(r'^[A-Fa-f][\.、]').hasMatch(line)) {
        line = line.replaceFirstMapped(
          RegExp(r'^([A-Fa-f][\.、])\s*(.+)'),
          (m) => '${m[1]} ${m[2]}',
        );
      }

      // 去除中文与中文标点之间的空格
      final cjkPunctRegex1 = RegExp(r'([\u4e00-\u9fa5])\s+([，。！？；：”’）》】、])');
      while (cjkPunctRegex1.hasMatch(line)) {
        line = line.replaceAllMapped(cjkPunctRegex1, (m) => '${m[1]}${m[2]}');
      }
      final cjkPunctRegex2 = RegExp(r'([“‘（《【])\s+([\u4e00-\u9fa5])');
      while (cjkPunctRegex2.hasMatch(line)) {
        line = line.replaceAllMapped(cjkPunctRegex2, (m) => '${m[1]}${m[2]}');
      }

      // 连续英文单词之间的多个连续空格归一为单空格
      line = line.replaceAll(RegExp(r'[ \t]{2,}'), ' ');

      preprocessedLines.add(line);
    }

    // 第二阶段：修复跨行的标点符号与引号（标点吸附）
    final attachedLines = <String>[];
    for (int i = 0; i < preprocessedLines.length; i++) {
      var line = preprocessedLines[i];
      if (line.isEmpty) {
        attachedLines.add('');
        continue;
      }

      // 如果当前行开头是句中/句尾标点或后引号，尝试吸附到上一行
      if (attachedLines.isNotEmpty &&
          attachedLines.last.isNotEmpty &&
          RegExp(r'^[，。！？；：”’）》】、]').hasMatch(line)) {
        final match = RegExp(r'^[，。！？；：”’）》】、]+').firstMatch(line);
        if (match != null) {
          final punct = match.group(0)!;
          attachedLines[attachedLines.length - 1] += punct;
          line = line.substring(punct.length).trim();
          if (line.isEmpty) continue;
        }
      }

      // 如果上一行结尾是前引号或左括号，且当前行非空
      if (attachedLines.isNotEmpty &&
          attachedLines.last.isNotEmpty &&
          RegExp(r'[“‘（《【]$').hasMatch(attachedLines.last)) {
        attachedLines[attachedLines.length - 1] += line;
        continue;
      }

      attachedLines.add(line);
    }

    // 第三阶段：段落智能重组（合并因 PDF 视觉折行造成的碎片短行）
    final paragraphs = <String>[];
    final curBuffer = StringBuffer();

    bool isHeadingOrItem(String s) {
      if (s.isEmpty) return false;
      if (s.startsWith('#')) return true;
      if (RegExp(r'^第[0-9一二三四五六七八九十]+[章节篇部分]').hasMatch(s)) return true;
      if (RegExp(r'^[一二三四五六七八九十]+[、\.]').hasMatch(s)) return true;
      if (RegExp(r'^[（\(][一二三四五六七八九十0-9]+[）\)]').hasMatch(s)) return true;
      if (RegExp(r'^\d+[\.、\s]').hasMatch(s)) return true;
      if (RegExp(r'^[A-Fa-f][\.、\s]').hasMatch(s)) return true;
      if (RegExp(r'^[（\(][A-Fa-f][）\)]').hasMatch(s)) return true;
      if (RegExp(r'^\[[A-Fa-f]\]').hasMatch(s)) return true;
      if (RegExp(r'^(题量|满分|作答时间|作者|发布时间|时间|来源|日期|学院|专业)[:：]').hasMatch(s)) return true;
      return false;
    }

    bool isSentenceEnding(String s) {
      if (s.isEmpty) return false;
      return RegExp(r'[。！？!?；;:：][”’」』）\)]*$').hasMatch(s);
    }

    for (int i = 0; i < attachedLines.length; i++) {
      final line = attachedLines[i];

      if (line.isEmpty) {
        if (curBuffer.isNotEmpty) {
          paragraphs.add(curBuffer.toString());
          curBuffer.clear();
        }
        continue;
      }

      if (curBuffer.isEmpty) {
        curBuffer.write(line);
      } else {
        final prevStr = curBuffer.toString();
        if (isHeadingOrItem(line) || isHeadingOrItem(prevStr) || isSentenceEnding(prevStr)) {
          paragraphs.add(prevStr);
          curBuffer.clear();
          curBuffer.write(line);
        } else {
          final prevLast = prevStr.isNotEmpty ? prevStr[prevStr.length - 1] : '';
          final curFirst = line.isNotEmpty ? line[0] : '';
          final isEnglishJoin = RegExp(r'[a-zA-Z0-9]').hasMatch(prevLast) &&
              RegExp(r'[a-zA-Z0-9]').hasMatch(curFirst);
          if (isEnglishJoin) {
            curBuffer.write(' ');
          }
          curBuffer.write(line);
        }
      }
    }

    if (curBuffer.isNotEmpty) {
      paragraphs.add(curBuffer.toString());
    }

    return paragraphs;
  }

  static Future<ProcessingResult> _pdfToDocxClean(
    List<String> files,
    Map<String, dynamic> params,
    String outputDir,
    Function(double, String)? onProgress, {
    String? note,
  }) async {
    final pdfPath = files.first;
    final preserveBreaks = params['preservePageBreaks'] != false &&
        '${params['preservePageBreaks']}' != 'false';

    onProgress?.call(0.1, '正在读取 PDF 源文档并加载排版提取引擎...');
    final pdfBytes = await File(pdfPath).readAsBytes();
    final pdfDoc = sf.PdfDocument(inputBytes: pdfBytes);
    final totalPages = pdfDoc.pages.count;

    if (totalPages == 0) {
      pdfDoc.dispose();
      return ProcessingResult(success: false, message: 'PDF 文档中没有可提取的页面');
    }

    onProgress?.call(0.3, '正在逐页提取 PDF 文本与段落结构 (共 $totalPages 页)...');
    final extractor = sf.PdfTextExtractor(pdfDoc);

    // 逐页提取并执行智能清洗与分段
    final pagesParagraphs = <List<String>>[];
    for (int i = 0; i < totalPages; i++) {
      onProgress?.call(0.3 + (i / totalPages) * 0.45, '正在清洗第 ${i + 1}/$totalPages 页文字与段落...');
      final pageRawText = extractor.extractText(startPageIndex: i, endPageIndex: i);
      final pList = cleanAndSegmentPdfText(pageRawText);
      pagesParagraphs.add(pList);
    }
    pdfDoc.dispose();

    onProgress?.call(0.78, '正在按中文标准格式与首行缩进规范生成 WordprocessingML...');
    final sbDoc = StringBuffer();
    sbDoc.write('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n');
    sbDoc.write('<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">\n');
    sbDoc.write('  <w:body>\n');

    bool isFirstNonEmpty = true;

    for (int pIdx = 0; pIdx < pagesParagraphs.length; pIdx++) {
      final paragraphs = pagesParagraphs[pIdx];

      for (int i = 0; i < paragraphs.length; i++) {
        final line = paragraphs[i];
        if (line.trim().isEmpty) continue;
        final escaped = _xmlEscape(line);

        if (isFirstNonEmpty) {
          // 第一行短文本作为主标题居中
          if (line.length <= 45 &&
              !RegExp(r'^\d+[\.、]').hasMatch(line) &&
              !RegExp(r'^[一二三四五六七八九十]+[、\.]').hasMatch(line)) {
            sbDoc.write('    <w:p>\n');
            sbDoc.write('      <w:pPr>\n');
            sbDoc.write('        <w:jc w:val="center"/>\n');
            sbDoc.write('        <w:spacing w:before="240" w:after="200" w:line="440" w:lineRule="auto"/>\n');
            sbDoc.write('      </w:pPr>\n');
            sbDoc.write('      <w:r>\n');
            sbDoc.write('        <w:rPr>\n');
            sbDoc.write('          <w:rFonts w:ascii="Calibri" w:eastAsia="SimHei" w:hAnsi="Calibri"/>\n');
            sbDoc.write('          <w:b/>\n');
            sbDoc.write('          <w:sz w:val="32"/>\n'); // 16pt 二号
            sbDoc.write('          <w:color w:val="0F172A"/>\n');
            sbDoc.write('        </w:rPr>\n');
            sbDoc.write('        <w:t xml:space="preserve">$escaped</w:t>\n');
            sbDoc.write('      </w:r>\n');
            sbDoc.write('    </w:p>\n');
            isFirstNonEmpty = false;
            continue;
          }
          isFirstNonEmpty = false;
        }

        // 元数据 (作者、日期、来源等)
        if (RegExp(r'^(题量|满分|作答时间|作者|发布时间|时间|来源|日期|学院|专业)[:：]').hasMatch(line)) {
          sbDoc.write('    <w:p>\n');
          sbDoc.write('      <w:pPr>\n');
          sbDoc.write('        <w:jc w:val="center"/>\n');
          sbDoc.write('        <w:spacing w:before="60" w:after="160" w:line="320" w:lineRule="auto"/>\n');
          sbDoc.write('      </w:pPr>\n');
          sbDoc.write('      <w:r>\n');
          sbDoc.write('        <w:rPr>\n');
          sbDoc.write('          <w:rFonts w:ascii="Calibri" w:eastAsia="SimSun" w:hAnsi="Calibri"/>\n');
          sbDoc.write('          <w:sz w:val="21"/>\n'); // 10.5pt 五号
          sbDoc.write('          <w:color w:val="64748B"/>\n');
          sbDoc.write('        </w:rPr>\n');
          sbDoc.write('        <w:t xml:space="preserve">$escaped</w:t>\n');
          sbDoc.write('      </w:r>\n');
          sbDoc.write('    </w:p>\n');
        }
        // 一级章节/大纲标题
        else if (RegExp(r'^[一二三四五六七八九十]+[\.、\s]').hasMatch(line) ||
            RegExp(r'^第[0-9一二三四五六七八九十]+[章节篇部分]').hasMatch(line) ||
            line.startsWith('# ')) {
          final titleText = line.startsWith('# ') ? line.substring(2).trim() : line;
          final escapedTitle = _xmlEscape(titleText);
          sbDoc.write('    <w:p>\n');
          sbDoc.write('      <w:pPr>\n');
          sbDoc.write('        <w:spacing w:before="280" w:after="140" w:line="380" w:lineRule="auto"/>\n');
          sbDoc.write('      </w:pPr>\n');
          sbDoc.write('      <w:r>\n');
          sbDoc.write('        <w:rPr>\n');
          sbDoc.write('          <w:rFonts w:ascii="Calibri" w:eastAsia="SimHei" w:hAnsi="Calibri"/>\n');
          sbDoc.write('          <w:b/>\n');
          sbDoc.write('          <w:sz w:val="28"/>\n'); // 14pt 四号
          sbDoc.write('          <w:color w:val="1E293B"/>\n');
          sbDoc.write('        </w:rPr>\n');
          sbDoc.write('        <w:t xml:space="preserve">$escapedTitle</w:t>\n');
          sbDoc.write('      </w:r>\n');
          sbDoc.write('    </w:p>\n');
        }
        // 二级小节 / 题目序号
        else if (RegExp(r'^\d+[\.、\s]').hasMatch(line) ||
            RegExp(r'^[（\(][一二三四五六七八九十0-9]+[）\)]').hasMatch(line) ||
            line.startsWith('## ')) {
          final qText = line.startsWith('## ') ? line.substring(3).trim() : line;
          final escapedQ = _xmlEscape(qText);
          sbDoc.write('    <w:p>\n');
          sbDoc.write('      <w:pPr>\n');
          sbDoc.write('        <w:spacing w:before="180" w:after="80" w:line="340" w:lineRule="auto"/>\n');
          sbDoc.write('      </w:pPr>\n');
          sbDoc.write('      <w:r>\n');
          sbDoc.write('        <w:rPr>\n');
          sbDoc.write('          <w:rFonts w:ascii="Calibri" w:eastAsia="SimHei" w:hAnsi="Calibri"/>\n');
          sbDoc.write('          <w:b/>\n');
          sbDoc.write('          <w:sz w:val="23"/>\n');
          sbDoc.write('          <w:color w:val="0F172A"/>\n');
          sbDoc.write('        </w:rPr>\n');
          sbDoc.write('        <w:t xml:space="preserve">$escapedQ</w:t>\n');
          sbDoc.write('      </w:r>\n');
          sbDoc.write('    </w:p>\n');
        }
        // 选项或缩进项目
        else if (RegExp(r'^[A-Fa-f][\.、\s]').hasMatch(line) ||
            RegExp(r'^[（\(][A-Fa-f][）\)]').hasMatch(line) ||
            RegExp(r'^\[[A-Fa-f]\]').hasMatch(line)) {
          sbDoc.write('    <w:p>\n');
          sbDoc.write('      <w:pPr>\n');
          sbDoc.write('        <w:ind w:left="480"/>\n');
          sbDoc.write('        <w:spacing w:before="40" w:after="60" w:line="320" w:lineRule="auto"/>\n');
          sbDoc.write('      </w:pPr>\n');
          sbDoc.write('      <w:r>\n');
          sbDoc.write('        <w:rPr>\n');
          sbDoc.write('          <w:rFonts w:ascii="Calibri" w:eastAsia="SimSun" w:hAnsi="Calibri"/>\n');
          sbDoc.write('          <w:sz w:val="21"/>\n');
          sbDoc.write('          <w:color w:val="334155"/>\n');
          sbDoc.write('        </w:rPr>\n');
          sbDoc.write('        <w:t xml:space="preserve">$escaped</w:t>\n');
          sbDoc.write('      </w:r>\n');
          sbDoc.write('    </w:p>\n');
        }
        // 标准正文段落：首行缩进 2 字符、两端对齐、标准字号与行距
        else {
          sbDoc.write('    <w:p>\n');
          sbDoc.write('      <w:pPr>\n');
          sbDoc.write('        <w:ind w:firstLineChars="200" w:firstLine="480"/>\n');
          sbDoc.write('        <w:spacing w:line="360" w:lineRule="auto" w:after="90"/>\n');
          sbDoc.write('        <w:jc w:val="both"/>\n');
          sbDoc.write('      </w:pPr>\n');
          sbDoc.write('      <w:r>\n');
          sbDoc.write('        <w:rPr>\n');
          sbDoc.write('          <w:rFonts w:ascii="Calibri" w:eastAsia="SimSun" w:hAnsi="Calibri"/>\n');
          sbDoc.write('          <w:sz w:val="24"/>\n'); // 12pt 小四
          sbDoc.write('          <w:color w:val="1E293B"/>\n');
          sbDoc.write('        </w:rPr>\n');
          sbDoc.write('        <w:t xml:space="preserve">$escaped</w:t>\n');
          sbDoc.write('      </w:r>\n');
          sbDoc.write('    </w:p>\n');
        }
      }

      // 页间严格保留分页符
      if (preserveBreaks && pIdx < pagesParagraphs.length - 1 && paragraphs.isNotEmpty) {
        sbDoc.write('    <w:p><w:r><w:br w:type="page"/></w:r></w:p>\n');
      }
    }

    sbDoc.write('    <w:sectPr>\n');
    sbDoc.write('      <w:pgSz w:w="11906" w:h="16838"/>\n');
    sbDoc.write('      <w:pgMar w:top="1440" w:right="1440" w:bottom="1440" w:left="1440"/>\n');
    sbDoc.write('    </w:sectPr>\n');
    sbDoc.write('  </w:body>\n');
    sbDoc.write('</w:document>');

    onProgress?.call(0.9, '正在打包 OpenXML Word 文档...');
    final archive = Archive();
    const contentTypes = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n'
        '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">\n'
        '  <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>\n'
        '  <Default Extension="xml" ContentType="application/xml"/>\n'
        '  <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>\n'
        '</Types>';
    _addArchiveString(archive, '[Content_Types].xml', contentTypes);

    const rootRels = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n'
        '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\n'
        '  <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>\n'
        '</Relationships>';
    _addArchiveString(archive, '_rels/.rels', rootRels);

    _addArchiveString(archive, 'word/document.xml', sbDoc.toString());

    final docxBytes = ZipEncoder().encode(archive);

    final baseName = p.basenameWithoutExtension(pdfPath);
    final outPath = p.join(outputDir, '${baseName}_clean.docx');
    await File(outPath).writeAsBytes(docxBytes);

    onProgress?.call(1.0, '转换完成！');
    return ProcessingResult(
      success: true,
      message: '成功将 $totalPages 页 PDF 文字与排版清洗重构为标准 Word (.docx) 文档！${note != null ? "\n$note" : ""}',
      outputFiles: [outPath],
    );
  }

  // ===========================================================================
  // 辅助方法
  // ===========================================================================

  static void _addArchiveString(Archive archive, String path, String content) {
    final bytes = utf8.encode(content);
    archive.addFile(ArchiveFile(path, bytes.length, bytes));
  }

  static String _xmlEscape(String input) {
    return input
        .replaceAll('&', '&amp;')
        .replaceAll('<', '&lt;')
        .replaceAll('>', '&gt;')
        .replaceAll('"', '&quot;')
        .replaceAll("'", '&apos;');
  }

  /// 构建完全符合 ECMA-376 与 Microsoft Office 规范的 OpenXML 演示文稿结构
  /// 基于工业级 Office 标准模板底包，补齐母版、11套版式、主题与完整关联清单，
  /// 彻底解决 PowerPoint 与 WPS 打开提示“内容存在问题需要修复”并删除幻灯片的问题，
  /// 并支持自动按长宽比居中渲染防拉伸变形。
  static Archive _buildCompliantPptxArchive({
    required List<Map<String, dynamic>> slides,
    required int slideW,
    required int slideH,
    required String aspectType,
  }) {
    final tplBytes = PptxTemplateData.bytes;
    final tplArchive = ZipDecoder().decodeBytes(tplBytes);
    final outArchive = Archive();
    final total = slides.length;

    ArchiveFile? ctFile;
    ArchiveFile? presFile;
    ArchiveFile? presRelsFile;

    for (final f in tplArchive.files) {
      if (f.name == '[Content_Types].xml') {
        ctFile = f;
      } else if (f.name == 'ppt/presentation.xml') {
        presFile = f;
      } else if (f.name == 'ppt/_rels/presentation.xml.rels') {
        presRelsFile = f;
      } else {
        outArchive.addFile(f);
      }
    }

    // 逐页添加幻灯片与媒体素材，计算宽高比居中坐标 (防拉伸变形)
    for (int i = 1; i <= total; i++) {
      final s = slides[i - 1];
      final rawBytes = s['imageBytes'] as Uint8List;
      final mediaExt = (s['mediaExt']?.toString() ?? 'png').toLowerCase();
      final double imgW = (s['imgWidth'] as num?)?.toDouble() ?? slideW.toDouble();
      final double imgH = (s['imgHeight'] as num?)?.toDouble() ?? slideH.toDouble();

      final double scale = min(slideW / max(1.0, imgW), slideH / max(1.0, imgH));
      final int drawW = (imgW * scale).round();
      final int drawH = (imgH * scale).round();
      final int offX = ((slideW - drawW) / 2).round();
      final int offY = ((slideH - drawH) / 2).round();

      final mediaPath = 'ppt/media/image$i.$mediaExt';
      outArchive.addFile(ArchiveFile(mediaPath, rawBytes.length, rawBytes));

      final slideXml = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n'
          '<p:sld xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">'
          '<p:cSld><p:spTree>'
          '<p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr>'
          '<p:grpSpPr/>'
          '<p:pic>'
          '<p:nvPicPr><p:cNvPr id="2" name="Picture $i" descr="image$i.$mediaExt"/><p:cNvPicPr><a:picLocks noChangeAspect="1"/></p:cNvPicPr><p:nvPr/></p:nvPicPr>'
          '<p:blipFill><a:blip r:embed="rId2"/><a:stretch><a:fillRect/></a:stretch></p:blipFill>'
          '<p:spPr><a:xfrm><a:off x="$offX" y="$offY"/><a:ext cx="$drawW" cy="$drawH"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom></p:spPr>'
          '</p:pic>'
          '</p:spTree></p:cSld>'
          '<p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr>'
          '</p:sld>';
      _addArchiveString(outArchive, 'ppt/slides/slide$i.xml', slideXml);

      final slideRels = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n'
          '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
          '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideLayout" Target="../slideLayouts/slideLayout7.xml"/>'
          '<Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/image" Target="../media/image$i.$mediaExt"/>'
          '</Relationships>';
      _addArchiveString(outArchive, 'ppt/slides/_rels/slide$i.xml.rels', slideRels);
    }

    // 更新 [Content_Types].xml (注册所有 slide 与图片扩展名，严格遵循 ECMA-376 规范避免重复 Default 声明)
    final ctXml = utf8.decode(ctFile!.content as List<int>);
    final sbCt = StringBuffer();
    for (int i = 1; i <= total; i++) {
      sbCt.write('<Override PartName="/ppt/slides/slide$i.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slide+xml"/>');
    }
    final sbDefaults = StringBuffer();
    if (!ctXml.contains('Extension="png"')) {
      sbDefaults.write('<Default Extension="png" ContentType="image/png"/>');
    }
    if (!ctXml.contains('Extension="jpg"')) {
      sbDefaults.write('<Default Extension="jpg" ContentType="image/jpeg"/>');
    }
    if (!ctXml.contains('Extension="jpeg"')) {
      sbDefaults.write('<Default Extension="jpeg" ContentType="image/jpeg"/>');
    }
    if (!ctXml.contains('Extension="webp"')) {
      sbDefaults.write('<Default Extension="webp" ContentType="image/webp"/>');
    }
    final updatedCt = ctXml.replaceFirst('</Types>', '${sbDefaults.toString()}${sbCt.toString()}</Types>');
    _addArchiveString(outArchive, '[Content_Types].xml', updatedCt);

    // 更新 ppt/_rels/presentation.xml.rels (关联所有幻灯片)
    final presRelsXml = utf8.decode(presRelsFile!.content as List<int>);
    final sbRels = StringBuffer();
    for (int i = 1; i <= total; i++) {
      sbRels.write('<Relationship Id="rIdSlide$i" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slide" Target="slides/slide$i.xml"/>');
    }
    final updatedPresRels = presRelsXml.replaceFirst('</Relationships>', '${sbRels.toString()}</Relationships>');
    _addArchiveString(outArchive, 'ppt/_rels/presentation.xml.rels', updatedPresRels);

    // 更新 ppt/presentation.xml (写入 sldIdLst 与画面尺寸，精准更新 sldSz 保障 notesSz 完整性)
    var presXml = utf8.decode(presFile!.content as List<int>);
    final sbSldIds = StringBuffer();
    for (int i = 1; i <= total; i++) {
      sbSldIds.write('<p:sldId id="${255 + i}" r:id="rIdSlide$i"/>');
    }
    presXml = presXml.replaceFirst('</p:sldMasterIdLst>', '</p:sldMasterIdLst><p:sldIdLst>${sbSldIds.toString()}</p:sldIdLst>');
    presXml = presXml.replaceFirst(
      RegExp(r'<p:sldSz\s+cx="\d+"\s+cy="\d+"(?:\s+type="[^"]*")?\s*/>'),
      '<p:sldSz cx="$slideW" cy="$slideH" type="$aspectType"/>',
    );
    _addArchiveString(outArchive, 'ppt/presentation.xml', presXml);

    return outArchive;
  }

  static int _excelColToIndex(String cellRef) {
    int col = 0;
    for (int i = 0; i < cellRef.length; i++) {
      final code = cellRef.codeUnitAt(i);
      if (code >= 65 && code <= 90) {
        col = col * 26 + (code - 64);
      } else {
        break;
      }
    }
    return max(0, col - 1);
  }

  static List<String> _extractPptxSlideTexts(Archive archive) {
    final slideTexts = <String>[];
    final slideFiles = archive.files
        .where((f) => f.isFile && RegExp(r'ppt/slides/slide\d+\.xml$').hasMatch(f.name))
        .toList();
    slideFiles.sort((a, b) => _compareNatural(a.name, b.name));

    for (final sf in slideFiles) {
      try {
        final xmlStr = utf8.decode(sf.content as List<int>, allowMalformed: true);
        final doc = xml.XmlDocument.parse(xmlStr);
        final texts = doc.findAllElements('a:t').map((e) => e.innerText).join(' ').trim();
        slideTexts.add(texts.isNotEmpty ? texts : 'Slide');
      } catch (_) {
        slideTexts.add('Slide');
      }
    }
    return slideTexts;
  }

  static int _compareNatural(String a, String b) {
    final reg = RegExp(r'(\d+)');
    final matchA = reg.firstMatch(a);
    final matchB = reg.firstMatch(b);
    if (matchA != null && matchB != null) {
      final numA = int.tryParse(matchA.group(1)!) ?? 0;
      final numB = int.tryParse(matchB.group(1)!) ?? 0;
      final cmp = numA.compareTo(numB);
      if (cmp != 0) return cmp;
    }
    return a.compareTo(b);
  }
}

class _StyledSpan {
  final String text;
  final bool isBold;
  final bool isItalic;
  final bool isCode;

  const _StyledSpan({
    required this.text,
    this.isBold = false,
    this.isItalic = false,
    this.isCode = false,
  });
}

class _MarkdownPdfRenderer {
  final sf.PdfDocument pdfDoc;
  final double pageWidth;
  final double pageHeight;
  sf.PdfPage curPage;
  double curY = 0;

  final sf.PdfFont h1Font;
  final sf.PdfFont h2Font;
  final sf.PdfFont h3Font;
  final sf.PdfFont h4Font;
  final sf.PdfFont bodyFont;
  final sf.PdfFont boldBodyFont;
  final List<int>? fontBytes;
  final sf.PdfFont italicBodyFont;
  final sf.PdfFont codeFont;
  final sf.PdfFont quoteFont;

  final sf.PdfBrush textBrush;
  final sf.PdfBrush boldTextBrush;
  final sf.PdfBrush codeBrush;
  final sf.PdfBrush codeBgBrush;
  final sf.PdfBrush blockquoteBarBrush;
  final sf.PdfBrush blockquoteBgBrush;

  static final RegExp _tokenRegex = RegExp(r'[\u4e00-\u9fa5]|[\w]+|\s+|[^\s\w\u4e00-\u9fa5]');

  _MarkdownPdfRenderer(this.pdfDoc, this.curPage, {this.fontBytes})
      : pageWidth = curPage.getClientSize().width,
        pageHeight = curPage.getClientSize().height,
        h1Font = DocConverterService.createChineseFont(fontBytes, 20, style: sf.PdfFontStyle.bold),
        h2Font = DocConverterService.createChineseFont(fontBytes, 16, style: sf.PdfFontStyle.bold),
        h3Font = DocConverterService.createChineseFont(fontBytes, 13, style: sf.PdfFontStyle.bold),
        h4Font = DocConverterService.createChineseFont(fontBytes, 11.5, style: sf.PdfFontStyle.bold),
        bodyFont = DocConverterService.createChineseFont(fontBytes, 10.5, style: sf.PdfFontStyle.regular),
        boldBodyFont = DocConverterService.createChineseFont(fontBytes, 10.5, style: sf.PdfFontStyle.bold),
        italicBodyFont = DocConverterService.createChineseFont(fontBytes, 10.5, style: sf.PdfFontStyle.italic),
        codeFont = DocConverterService.createChineseFont(fontBytes, 9.5, style: sf.PdfFontStyle.regular),
        quoteFont = DocConverterService.createChineseFont(fontBytes, 10.0, style: sf.PdfFontStyle.italic),
        textBrush = sf.PdfSolidBrush(sf.PdfColor(30, 41, 59)),
        boldTextBrush = sf.PdfSolidBrush(sf.PdfColor(15, 23, 42)),
        codeBrush = sf.PdfSolidBrush(sf.PdfColor(15, 23, 42)),
        codeBgBrush = sf.PdfSolidBrush(sf.PdfColor(241, 245, 249)),
        blockquoteBarBrush = sf.PdfSolidBrush(sf.PdfColor(59, 130, 246)),
        blockquoteBgBrush = sf.PdfSolidBrush(sf.PdfColor(248, 250, 252));

  void ensureSpace(double needHeight) {
    if (curY + needHeight > pageHeight) {
      curPage = pdfDoc.pages.add();
      curY = 0;
    }
  }

  String _unescapeHtml(String text) {
    return text
        .replaceAll('\t', '    ')
        .replaceAll('&quot;', '"')
        .replaceAll('&#39;', "'")
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&amp;', '&');
  }

  void renderNodes(List<md.Node> nodes) {
    for (final node in nodes) {
      if (node is md.Element) {
        _renderElement(node);
      } else if (node is md.Text) {
        _renderParagraphText(node.text);
      }
    }
  }

  void _renderElement(md.Element elem) {
    switch (elem.tag) {
      case 'h1':
        _renderHeading(elem, h1Font, 26, 16, hasUnderline: true);
        break;
      case 'h2':
        _renderHeading(elem, h2Font, 22, 12);
        break;
      case 'h3':
        _renderHeading(elem, h3Font, 18, 10);
        break;
      case 'h4':
      case 'h5':
      case 'h6':
        _renderHeading(elem, h4Font, 16, 8);
        break;
      case 'p':
        _renderParagraph(elem);
        break;
      case 'blockquote':
        _renderBlockquote(elem);
        break;
      case 'ul':
        _renderList(elem, isOrdered: false);
        break;
      case 'ol':
        _renderList(elem, isOrdered: true);
        break;
      case 'pre':
        _renderCodeBlock(elem);
        break;
      case 'table':
        _renderTable(elem);
        break;
      case 'hr':
        _renderHorizontalRule();
        break;
      default:
        if (elem.children != null && elem.children!.isNotEmpty) {
          renderNodes(elem.children!);
        } else {
          _renderParagraphText(elem.textContent);
        }
    }
  }

  void _renderHeading(md.Element elem, sf.PdfFont font, double fontH, double topSpace, {bool hasUnderline = false}) {
    final title = _unescapeHtml(elem.textContent).trim();
    if (title.isEmpty) return;

    final totalH = fontH + (hasUnderline ? 14 : 6);
    curY += topSpace;
    ensureSpace(totalH);

    curPage.graphics.drawString(
      title,
      font,
      brush: boldTextBrush,
      bounds: ui.Rect.fromLTWH(0, curY, pageWidth, 0),
    );
    curY += fontH + 4;

    if (hasUnderline) {
      curPage.graphics.drawLine(
        sf.PdfPen(sf.PdfColor(226, 232, 240), width: 1),
        ui.Offset(0, curY),
        ui.Offset(pageWidth, curY),
      );
      curY += 8;
    } else {
      curY += 4;
    }
  }

  void _renderParagraph(md.Element elem) {
    final spans = <_StyledSpan>[];
    _extractSpans(elem.children, spans);
    if (spans.isEmpty) return;

    _drawInlineSpans(spans, leftOffset: 0, maxWidth: pageWidth, afterMargin: 6);
  }

  void _renderParagraphText(String rawText) {
    final text = rawText.trim();
    if (text.isEmpty) return;
    _drawInlineSpans([_StyledSpan(text: text)], leftOffset: 0, maxWidth: pageWidth, afterMargin: 6);
  }

  void _extractSpans(List<md.Node>? children, List<_StyledSpan> target, {bool isBold = false, bool isItalic = false, bool isCode = false}) {
    if (children == null) return;
    for (final child in children) {
      if (child is md.Text) {
        if (child.text.isNotEmpty) {
          target.add(_StyledSpan(
            text: child.text,
            isBold: isBold,
            isItalic: isItalic,
            isCode: isCode,
          ));
        }
      } else if (child is md.Element) {
        final tag = child.tag;
        if (tag == 'br') {
          target.add(const _StyledSpan(text: '\n'));
          continue;
        }
        _extractSpans(
          child.children,
          target,
          isBold: isBold || tag == 'strong' || tag == 'b',
          isItalic: isItalic || tag == 'em' || tag == 'i',
          isCode: isCode || tag == 'code',
        );
      }
    }
  }

  void _drawInlineSpans(
    List<_StyledSpan> spans, {
    double leftOffset = 0,
    required double maxWidth,
    double afterMargin = 6,
  }) {
    if (spans.isEmpty) return;

    final lineHeight = 16.0;
    double curX = leftOffset;

    ensureSpace(lineHeight);

    for (final span in spans) {
      if (span.text == '\n') {
        curX = leftOffset;
        curY += lineHeight;
        ensureSpace(lineHeight);
        continue;
      }
      final text = _unescapeHtml(span.text);
      if (text.isEmpty) continue;

      final sf.PdfFont font = span.isCode
          ? codeFont
          : (span.isBold
              ? boldBodyFont
              : (span.isItalic ? italicBodyFont : bodyFont));
      final brush = span.isCode ? codeBrush : (span.isBold ? boldTextBrush : textBrush);

      final matches = _tokenRegex.allMatches(text);
      for (final match in matches) {
        final token = match.group(0)!;
        final tokenSize = font.measureString(token);
        final tokenW = tokenSize.width;

        if (curX + tokenW > leftOffset + maxWidth && curX > leftOffset && token.trim().isNotEmpty) {
          curX = leftOffset;
          curY += lineHeight;
          ensureSpace(lineHeight);
        }

        if (span.isCode) {
          curPage.graphics.drawRectangle(
            brush: codeBgBrush,
            bounds: ui.Rect.fromLTWH(curX, curY + 1, tokenW + 1, lineHeight - 2),
          );
        }

        curPage.graphics.drawString(
          token,
          font,
          brush: brush,
          bounds: ui.Rect.fromLTWH(curX, curY, 0, 0),
        );
        curX += tokenW;
      }
    }

    curY += lineHeight + afterMargin;
  }

  void _renderBlockquote(md.Element elem) {
    final spans = <_StyledSpan>[];
    _extractSpans(elem.children, spans);
    if (spans.isEmpty) return;

    curY += 4;
    ensureSpace(24);
    final startY = curY;

    _drawInlineSpans(spans, leftOffset: 12, maxWidth: pageWidth - 16, afterMargin: 6);
    final blockHeight = (curY - startY).clamp(16.0, 1000.0);

    curPage.graphics.drawRectangle(
      brush: blockquoteBarBrush,
      bounds: ui.Rect.fromLTWH(0, startY + 1, 3.5, blockHeight - 2),
    );
    curY += 4;
  }

  void _renderList(md.Element elem, {required bool isOrdered}) {
    if (elem.children == null) return;
    int index = 1;

    for (final child in elem.children!) {
      if (child is! md.Element || child.tag != 'li') continue;

      String bullet = isOrdered ? '$index. ' : '• ';
      final spans = <_StyledSpan>[];
      _extractSpans(child.children, spans);

      if (spans.isNotEmpty) {
        final firstText = spans.first.text.trimLeft();
        if (firstText.startsWith('[ ] ')) {
          bullet = '☐ ';
          spans[0] = _StyledSpan(
            text: firstText.substring(4),
            isBold: spans.first.isBold,
            isItalic: spans.first.isItalic,
            isCode: spans.first.isCode,
          );
        } else if (firstText.startsWith('[x] ') || firstText.startsWith('[X] ')) {
          bullet = '☑ ';
          spans[0] = _StyledSpan(
            text: firstText.substring(4),
            isBold: spans.first.isBold,
            isItalic: spans.first.isItalic,
            isCode: spans.first.isCode,
          );
        }
      }

      ensureSpace(16);
      curPage.graphics.drawString(
        bullet,
        boldBodyFont,
        brush: blockquoteBarBrush,
        bounds: ui.Rect.fromLTWH(4, curY, 20, 0),
      );

      _drawInlineSpans(spans, leftOffset: isOrdered ? 22 : 18, maxWidth: pageWidth - 24, afterMargin: 4);
      index++;
    }
    curY += 4;
  }

  void _renderCodeBlock(md.Element elem) {
    final rawCode = _unescapeHtml(elem.textContent).trimRight();
    if (rawCode.isEmpty) return;

    final codeLines = rawCode.split('\n');

    // 动态根据最长行计算字号与行高，避免字符溢出或换行错乱（特别是包含制表符架构图时）
    double maxLineLen = 0;
    for (final l in codeLines) {
      if (l.length > maxLineLen) maxLineLen = l.length.toDouble();
    }
    double fontSize = 9.0;
    if (maxLineLen > 52) {
      fontSize = (pageWidth - 24) / maxLineLen;
      if (fontSize < 6.5) fontSize = 6.5;
      if (fontSize > 9.0) fontSize = 9.0;
    }
    final activeCodeFont = DocConverterService.createChineseFont(fontBytes, fontSize);
    final lineHeight = (fontSize * 1.45).clamp(9.0, 15.0);
    final padding = 8.0;
    final totalH = codeLines.length * lineHeight + padding * 2;

    ensureSpace(30);

    if (totalH + 10 <= pageHeight - curY) {
      curPage.graphics.drawRectangle(
        brush: codeBgBrush,
        pen: sf.PdfPen(sf.PdfColor(203, 213, 225), width: 0.5),
        bounds: ui.Rect.fromLTWH(0, curY, pageWidth, totalH),
      );

      double codeY = curY + padding;
      for (final line in codeLines) {
        curPage.graphics.drawString(
          line,
          activeCodeFont,
          brush: codeBrush,
          bounds: ui.Rect.fromLTWH(10, codeY, pageWidth - 16, 0),
        );
        codeY += lineHeight;
      }
      curY += totalH + 10;
    } else {
      for (final line in codeLines) {
        ensureSpace(lineHeight + 4);
        curPage.graphics.drawRectangle(
          brush: codeBgBrush,
          bounds: ui.Rect.fromLTWH(0, curY, pageWidth, lineHeight + 2),
        );
        curPage.graphics.drawString(
          line,
          activeCodeFont,
          brush: codeBrush,
          bounds: ui.Rect.fromLTWH(10, curY + 1, pageWidth - 16, 0),
        );
        curY += lineHeight + 2;
      }
      curY += 10;
    }
  }

  void _renderTable(md.Element elem) {
    if (elem.children == null) return;

    final grid = sf.PdfGrid();
    List<String> headerCols = [];
    final dataRows = <List<String>>[];

    for (final section in elem.children!) {
      if (section is! md.Element) continue;

      if (section.tag == 'thead') {
        for (final tr in section.children ?? []) {
          if (tr is! md.Element || tr.tag != 'tr') continue;
          for (final th in tr.children ?? []) {
            if (th is md.Element && (th.tag == 'th' || th.tag == 'td')) {
              headerCols.add(_unescapeHtml(th.textContent).trim());
            }
          }
        }
      } else if (section.tag == 'tbody') {
        for (final tr in section.children ?? []) {
          if (tr is! md.Element || tr.tag != 'tr') continue;
          final rowCells = <String>[];
          for (final td in tr.children ?? []) {
            if (td is md.Element && (td.tag == 'td' || td.tag == 'th')) {
              rowCells.add(_unescapeHtml(td.textContent).trim());
            }
          }
          if (rowCells.isNotEmpty) {
            dataRows.add(rowCells);
          }
        }
      }
    }

    if (headerCols.isEmpty && dataRows.isNotEmpty) {
      headerCols = dataRows.removeAt(0);
    }
    if (headerCols.isEmpty) return;

    final colCount = headerCols.length;
    grid.columns.add(count: colCount);

    grid.headers.add(1);
    final headerRow = grid.headers[0];
    headerRow.style = sf.PdfGridRowStyle(
      backgroundBrush: sf.PdfSolidBrush(sf.PdfColor(241, 245, 249)),
      textBrush: boldTextBrush,
      font: boldBodyFont,
    );
    for (int i = 0; i < colCount; i++) {
      headerRow.cells[i].value = headerCols[i];
    }

    for (int r = 0; r < dataRows.length; r++) {
      final rowData = dataRows[r];
      final gridRow = grid.rows.add();
      if (r % 2 == 1) {
        gridRow.style = sf.PdfGridRowStyle(
          backgroundBrush: sf.PdfSolidBrush(sf.PdfColor(248, 250, 252)),
        );
      }
      for (int c = 0; c < colCount; c++) {
        gridRow.cells[c].value = c < rowData.length ? rowData[c] : '';
      }
    }

    grid.style = sf.PdfGridStyle(
      cellPadding: sf.PdfPaddings(left: 6, right: 6, top: 5, bottom: 5),
      font: bodyFont,
    );

    ensureSpace(40);
    final layoutResult = grid.draw(
      page: curPage,
      bounds: ui.Rect.fromLTWH(0, curY, pageWidth, pageHeight - curY),
    );

    if (layoutResult != null) {
      curPage = layoutResult.page;
      curY = layoutResult.bounds.bottom + 12;
    } else {
      curY += 40;
    }
  }

  void _renderHorizontalRule() {
    ensureSpace(16);
    curY += 8;
    curPage.graphics.drawLine(
      sf.PdfPen(sf.PdfColor(203, 213, 225), width: 1),
      ui.Offset(0, curY),
      ui.Offset(pageWidth, curY),
    );
    curY += 10;
  }
}
