import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:archive/archive.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'tool_engine_service.dart';

/// Windows 桌面专属原生 Office 转换引擎 (支持 MS Office 16+ 与 金山 WPS 智能互通)
class WindowsOfficeConverter {
  WindowsOfficeConverter._();

  static bool get isSupported => Platform.isWindows;

  /// PPT / PPTX 原生转换为高保真 PDF (100% 还原母版、字体、颜色与图表)
  static Future<ProcessingResult> convertPptToPdf({
    required String pptPath,
    required String outputDir,
    Function(double progress, String status)? onProgress,
  }) async {
    if (!Platform.isWindows) {
      return ProcessingResult(
        success: false,
        message: '当前非 Windows 平台，无法调用桌面 Office 原生引擎。',
      );
    }

    final baseName = p.basenameWithoutExtension(pptPath);
    final outPdf = p.join(outputDir, '${baseName}_office.pdf');
    final absPpt = File(pptPath).absolute.path;
    final absPdf = File(outPdf).absolute.path;

    onProgress?.call(0.1, '正在检测 Windows 办公套件 (MS PowerPoint / WPS 演示)...');

    final script = '''
\$ErrorActionPreference = 'Stop'
\$ppt = \$null
try {
  try {
    \$ppt = New-Object -ComObject PowerPoint.Application
  } catch {
    \$ppt = New-Object -ComObject KWpp.Application
  }
  \$pres = \$ppt.Presentations.Open('$absPpt', -1, 0, 0)
  \$pres.SaveAs('$absPdf', 32)
  \$pres.Close()
  Write-Output "SUCCESS"
} catch {
  Write-Error \$_.Exception.Message
  exit 1
} finally {
  if (\$ppt -ne \$null) {
    try { \$ppt.Quit() } catch {}
    [System.Runtime.InteropServices.Marshal]::ReleaseComObject(\$ppt) | Out-Null
  }
}
''';

    onProgress?.call(0.3, '正在调用原生 Office 引擎渲染矢量页面与排版...');
    final tempDir = Directory.systemTemp.createTempSync('win_ppt_');
    final scriptFile = File(p.join(tempDir.path, 'convert_ppt.ps1'));

    try {
      // 写入 UTF-8 BOM 确保包含中文字符的路径正常解析
      await scriptFile.writeAsBytes(<int>[0xEF, 0xBB, 0xBF, ...utf8.encode(script)]);
      final res = await Process.run('powershell', [
        '-NoProfile',
        '-ExecutionPolicy',
        'Bypass',
        '-File',
        scriptFile.path,
      ]).timeout(
        const Duration(seconds: 45),
        onTimeout: () async {
          try {
            await Process.run('taskkill', ['/F', '/IM', 'POWERPNT.EXE']);
          } catch (_) {}
          try {
            await Process.run('taskkill', ['/F', '/IM', 'wpp.exe']);
          } catch (_) {}
          return ProcessResult(-1, -999, '', 'POWERPOINT_TIMEOUT: PPT 转 PDF 超时，已强制清理后台进程');
        },
      );

      if (res.exitCode == 0 && File(absPdf).existsSync() && File(absPdf).lengthSync() > 0) {
        onProgress?.call(1.0, '转换完成！');
        return ProcessingResult(
          success: true,
          message: '成功通过 Windows 原生 Office 引擎转换为 100% 高保真 PDF！',
          outputFiles: [absPdf],
        );
      } else {
        final err = res.stderr.toString().trim();
        return ProcessingResult(
          success: false,
          message: '⚠️ 转换失败：未检测到电脑安装的 Microsoft Office 或 WPS 工具\n\n'
              'Windows 端【PPT 转 PDF】为确保 100% 格式无损与商业级像素保真，需要调用电脑本地安装的 Microsoft PowerPoint 或 WPS 演示 原生引擎。\n\n'
              '请确保电脑已安装 Microsoft Office 或 WPS Office 后重试。'
              '${err.isNotEmpty ? "\n(系统返回信息: $err)" : ""}',
        );
      }
    } catch (e) {
      return ProcessingResult(
        success: false,
        message: '调用 Office 引擎异常：$e',
      );
    } finally {
      try {
        tempDir.deleteSync(recursive: true);
      } catch (_) {}
    }
  }

  /// Word DOC / DOCX 原生转换为高保真 PDF (100% 还原样式、表格与排版)
  static Future<ProcessingResult> convertWordToPdf({
    required String docPath,
    required String outputDir,
    Function(double progress, String status)? onProgress,
  }) async {
    if (!Platform.isWindows) {
      return ProcessingResult(
        success: false,
        message: '当前非 Windows 平台，无法调用桌面 Office 原生引擎。',
      );
    }

    final baseName = p.basenameWithoutExtension(docPath);
    final outPdf = p.join(outputDir, '${baseName}_office.pdf');
    final absDoc = File(docPath).absolute.path;
    final absPdf = File(outPdf).absolute.path;

    onProgress?.call(0.1, '正在检测 Windows 办公套件 (MS Word / WPS 文字)...');

    final script = '''
\$ErrorActionPreference = 'Stop'
\$word = \$null
try {
  try {
    \$word = New-Object -ComObject Word.Application
  } catch {
    \$word = New-Object -ComObject KWps.Application
  }
  \$doc = \$word.Documents.Open('$absDoc', \$false, \$true)
  \$doc.ExportAsFixedFormat('$absPdf', 17)
  \$doc.Close([ref]0)
  Write-Output "SUCCESS"
} catch {
  Write-Error \$_.Exception.Message
  exit 1
} finally {
  if (\$word -ne \$null) {
    try { \$word.Quit([ref]0) } catch {}
    [System.Runtime.InteropServices.Marshal]::ReleaseComObject(\$word) | Out-Null
  }
}
''';

    onProgress?.call(0.3, '正在调用原生 Office 引擎渲染文档排版...');
    final tempDir = Directory.systemTemp.createTempSync('win_word_');
    final scriptFile = File(p.join(tempDir.path, 'convert_word.ps1'));

    try {
      await scriptFile.writeAsBytes(<int>[0xEF, 0xBB, 0xBF, ...utf8.encode(script)]);
      final res = await Process.run('powershell', [
        '-NoProfile',
        '-ExecutionPolicy',
        'Bypass',
        '-File',
        scriptFile.path,
      ]).timeout(
        const Duration(seconds: 35),
        onTimeout: () async {
          try {
            await Process.run('taskkill', ['/F', '/IM', 'WINWORD.EXE']);
          } catch (_) {}
          try {
            await Process.run('taskkill', ['/F', '/IM', 'wps.exe']);
          } catch (_) {}
          return ProcessResult(-1, -999, '', 'WORD_TIMEOUT: Word 转 PDF 超时，已强制清理后台进程');
        },
      );

      if (res.exitCode == 0 && File(absPdf).existsSync() && File(absPdf).lengthSync() > 0) {
        onProgress?.call(1.0, '转换完成！');
        return ProcessingResult(
          success: true,
          message: '成功通过 Windows 原生 Office 引擎转换为 100% 高保真 PDF！',
          outputFiles: [absPdf],
        );
      } else {
        final err = res.stderr.toString().trim();
        return ProcessingResult(
          success: false,
          message: '⚠️ 转换失败：未检测到电脑安装的 Microsoft Office 或 WPS 工具\n\n'
              'Windows 端【Word 转 PDF】为确保 100% 格式无损与商业级像素保真，需要调用电脑本地安装的 Microsoft Word 或 WPS 文字 原生引擎。\n\n'
              '请确保电脑已安装 Microsoft Office 或 WPS Office 后重试。'
              '${err.isNotEmpty ? "\n(系统返回信息: $err)" : ""}',
        );
      }
    } catch (e) {
      return ProcessingResult(
        success: false,
        message: '调用 Office 引擎异常：$e',
      );
    } finally {
      try {
        tempDir.deleteSync(recursive: true);
      } catch (_) {}
    }
  }

  /// Excel XLS / XLSX 原生转换为高保真 PDF (100% 保留精确表格、数值精度与分页)
  static Future<ProcessingResult> convertExcelToPdf({
    required String xlsPath,
    required String outputDir,
    Function(double progress, String status)? onProgress,
  }) async {
    if (!Platform.isWindows) {
      return ProcessingResult(
        success: false,
        message: '当前非 Windows 平台，无法调用桌面 Office 原生引擎。',
      );
    }

    final baseName = p.basenameWithoutExtension(xlsPath);
    final outPdf = p.join(outputDir, '${baseName}_office.pdf');
    final absXls = File(xlsPath).absolute.path;
    final absPdf = File(outPdf).absolute.path;

    onProgress?.call(0.1, '正在检测 Windows 办公套件 (MS Excel / WPS 表格)...');

    final script = '''
\$ErrorActionPreference = 'Stop'
\$excel = \$null
try {
  try {
    \$excel = New-Object -ComObject Excel.Application
  } catch {
    \$excel = New-Object -ComObject Ket.Application
  }
  \$wb = \$excel.Workbooks.Open('$absXls', 0, \$true)
  \$wb.ExportAsFixedFormat(0, '$absPdf')
  \$wb.Close(\$false)
  Write-Output "SUCCESS"
} catch {
  Write-Error \$_.Exception.Message
  exit 1
} finally {
  if (\$excel -ne \$null) {
    try { \$excel.Quit() } catch {}
    [System.Runtime.InteropServices.Marshal]::ReleaseComObject(\$excel) | Out-Null
  }
}
''';

    onProgress?.call(0.3, '正在调用原生 Office 引擎渲染表格与多工作表...');
    final tempDir = Directory.systemTemp.createTempSync('win_excel_');
    final scriptFile = File(p.join(tempDir.path, 'convert_excel.ps1'));

    try {
      await scriptFile.writeAsBytes(<int>[0xEF, 0xBB, 0xBF, ...utf8.encode(script)]);
      final res = await Process.run('powershell', [
        '-NoProfile',
        '-ExecutionPolicy',
        'Bypass',
        '-File',
        scriptFile.path,
      ]).timeout(
        const Duration(seconds: 40),
        onTimeout: () async {
          try {
            await Process.run('taskkill', ['/F', '/IM', 'EXCEL.EXE']);
          } catch (_) {}
          try {
            await Process.run('taskkill', ['/F', '/IM', 'et.exe']);
          } catch (_) {}
          return ProcessResult(-1, -999, '', 'EXCEL_TIMEOUT: Excel 转 PDF 超时，已强制清理后台进程');
        },
      );

      if (res.exitCode == 0 && File(absPdf).existsSync() && File(absPdf).lengthSync() > 0) {
        onProgress?.call(1.0, '转换完成！');
        return ProcessingResult(
          success: true,
          message: '成功通过 Windows 原生 Office 引擎转换为 100% 高保真 PDF！',
          outputFiles: [absPdf],
        );
      } else {
        final err = res.stderr.toString().trim();
        return ProcessingResult(
          success: false,
          message: '⚠️ 转换失败：未检测到电脑安装的 Microsoft Office 或 WPS 工具\n\n'
              'Windows 端【Excel 转 PDF】为确保 100% 格式无损与商业级像素保真，需要调用电脑本地安装的 Microsoft Excel 或 WPS 表格 原生引擎。\n\n'
              '请确保电脑已安装 Microsoft Office 或 WPS Office 后重试。'
              '${err.isNotEmpty ? "\n(系统返回信息: $err)" : ""}',
        );
      }
    } catch (e) {
      return ProcessingResult(
        success: false,
        message: '调用 Office 引擎异常：$e',
      );
    } finally {
      try {
        tempDir.deleteSync(recursive: true);
      } catch (_) {}
    }
  }

  /// PPT / PPTX 原生转换为高清图片或无缝长图 (100% 还原排版、母版与字体)
  static Future<ProcessingResult> convertPptToImages({
    required String pptPath,
    required String outputDir,
    String format = 'png',
    String resolution = '1080p',
    String exportMode = 'pages', // 'pages' 或 'long_image'
    bool bundleZip = true,
    Function(double progress, String status)? onProgress,
  }) async {
    if (!Platform.isWindows) {
      return ProcessingResult(
        success: false,
        message: '当前非 Windows 平台，无法调用桌面 Office 原生引擎。',
      );
    }

    final absPpt = File(pptPath).absolute.path;
    final baseName = p.basenameWithoutExtension(pptPath);
    final targetFormat = (format.toLowerCase() == 'jpg' || format.toLowerCase() == 'jpeg') ? 'jpg' : 'png';
    final formatUpper = targetFormat == 'jpg' ? 'JPG' : 'PNG';

    int targetW = 1920;
    int targetH = 1080;
    switch (resolution.toLowerCase()) {
      case '4k':
        targetW = 3840;
        targetH = 2160;
        break;
      case '2k':
        targetW = 2560;
        targetH = 1440;
        break;
      case '720p':
        targetW = 1280;
        targetH = 720;
        break;
      case '1080p':
      default:
        targetW = 1920;
        targetH = 1080;
        break;
    }

    onProgress?.call(0.1, '正在检测 Windows 办公套件 (MS PowerPoint / WPS 演示)...');
    final tempDir = Directory.systemTemp.createTempSync('win_ppt_img_');
    final absTempDir = tempDir.absolute.path;

    final script = '''
\$ErrorActionPreference = 'Stop'
\$ppt = \$null
try {
  try {
    \$ppt = New-Object -ComObject PowerPoint.Application
  } catch {
    \$ppt = New-Object -ComObject KWpp.Application
  }
  \$pres = \$ppt.Presentations.Open('$absPpt', -1, 0, 0)
  \$slideCount = \$pres.Slides.Count
  Write-Output "SLIDE_COUNT:\$slideCount"
  for (\$i = 1; \$i -le \$slideCount; \$i++) {
    \$slide = \$pres.Slides.Item(\$i)
    \$imgName = "slide_\$(\$i.ToString('D4')).$targetFormat"
    \$targetImg = [System.IO.Path]::Combine('$absTempDir', \$imgName)
    \$slide.Export(\$targetImg, '$formatUpper', $targetW, $targetH)
  }
  \$pres.Close()
  Write-Output "SUCCESS"
} catch {
  Write-Error \$_.Exception.Message
  exit 1
} finally {
  if (\$ppt -ne \$null) {
    try { \$ppt.Quit() } catch {}
    [System.Runtime.InteropServices.Marshal]::ReleaseComObject(\$ppt) | Out-Null
  }
}
''';

    onProgress?.call(0.25, '正在调用原生 Office 引擎渲染并切分高清幻灯片...');
    final scriptFile = File(p.join(tempDir.path, 'export_ppt.ps1'));

    try {
      await scriptFile.writeAsBytes(<int>[0xEF, 0xBB, 0xBF, ...utf8.encode(script)]);
      final res = await Process.run('powershell', [
        '-NoProfile',
        '-ExecutionPolicy',
        'Bypass',
        '-File',
        scriptFile.path,
      ]).timeout(
        const Duration(seconds: 60),
        onTimeout: () async {
          try {
            await Process.run('taskkill', ['/F', '/IM', 'POWERPNT.EXE']);
          } catch (_) {}
          try {
            await Process.run('taskkill', ['/F', '/IM', 'wpp.exe']);
          } catch (_) {}
          return ProcessResult(-1, -999, '', 'POWERPOINT_TIMEOUT: PPT 导出图片超时，已强制清理后台进程');
        },
      );

      if (res.exitCode != 0) {
        final err = res.stderr.toString().trim();
        return ProcessingResult(
          success: false,
          message: '⚠️ 转换失败：未检测到电脑安装的 Microsoft Office 或 WPS 工具\n\n'
              'Windows 端【PPT 转图片/长图】为确保 100% 像素级保真与字体效果，需调用本地安装的 PowerPoint 或 WPS 演示 原生引擎。\n\n'
              '${err.isNotEmpty ? "\n(系统返回信息: $err)" : ""}',
        );
      }

      final slideFiles = tempDir
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.$targetFormat'))
          .toList();
      slideFiles.sort((a, b) => a.path.compareTo(b.path));

      if (slideFiles.isEmpty) {
        return ProcessingResult(
          success: false,
          message: '未能成功导出幻灯片图像，请确认 PPT 文件内容是否正常。',
        );
      }

      final isLongImage = exportMode == 'long_image';

      if (isLongImage) {
        onProgress?.call(0.7, '正在无缝拼合为超清长图 (共 ${slideFiles.length} 页)...');
        final outLongImgPath = p.join(outputDir, '${baseName}_long_image.$targetFormat');
        await stitchImagesVertically(
          imageFiles: slideFiles,
          outputPath: outLongImgPath,
          format: targetFormat,
          onProgress: onProgress,
        );
        onProgress?.call(1.0, '长图生成完成！');
        return ProcessingResult(
          success: true,
          message: '成功通过 Windows 原生 Office 引擎将 ${slideFiles.length} 页幻灯片拼接为无缝高清长图！',
          outputFiles: [outLongImgPath],
        );
      } else {
        // 逐页切图模式
        final outArchive = (bundleZip && slideFiles.length > 1) ? Archive() : null;
        final outputFiles = <String>[];

        for (int i = 0; i < slideFiles.length; i++) {
          final sFile = slideFiles[i];
          final fileName = '${baseName}_slide_${i + 1}.$targetFormat';
          final finalPath = p.join(outputDir, fileName);

          if (outArchive != null) {
            final bytes = await sFile.readAsBytes();
            outArchive.addFile(ArchiveFile(fileName, bytes.length, bytes));
          } else {
            await sFile.copy(finalPath);
            outputFiles.add(finalPath);
          }
        }

        if (outArchive != null) {
          final zipName = '${baseName}_slides_images.zip';
          final zipPath = p.join(outputDir, zipName);
          final zipBytes = ZipEncoder().encode(outArchive);
          await File(zipPath).writeAsBytes(zipBytes);
          outputFiles.add(zipPath);
          onProgress?.call(1.0, '幻灯片已导出并打包为 ZIP！');
          return ProcessingResult(
            success: true,
            message: '成功通过 Windows 原生 Office 引擎导出 ${slideFiles.length} 张高清幻灯片并打包为 ZIP 压缩包！',
            outputFiles: outputFiles,
          );
        } else {
          onProgress?.call(1.0, '全部幻灯片高清图片导出完成！');
          return ProcessingResult(
            success: true,
            message: '成功通过 Windows 原生 Office 引擎导出 ${slideFiles.length} 张高清幻灯片图片！',
            outputFiles: outputFiles,
          );
        }
      }
    } catch (e) {
      return ProcessingResult(
        success: false,
        message: '调用 PPT 导出引擎异常：$e',
      );
    } finally {
      try {
        tempDir.deleteSync(recursive: true);
      } catch (_) {}
    }
  }

  /// PDF 原生转换为可编辑 Word (.docx) (利用 MS Word PDF Reflow 智能重构段落、表格与样式)
  static Future<ProcessingResult> convertPdfToDocx({
    required String pdfPath,
    required String outputDir,
    Function(double progress, String status)? onProgress,
  }) async {
    if (!Platform.isWindows) {
      return ProcessingResult(
        success: false,
        message: '当前非 Windows 平台，无法调用桌面 Office 原生引擎。',
      );
    }

    final baseName = p.basenameWithoutExtension(pdfPath);
    final outDocx = p.join(outputDir, '${baseName}_reflow.docx');
    final absPdf = File(pdfPath).absolute.path;
    final absDocx = File(outDocx).absolute.path;

    onProgress?.call(0.1, '正在检测 Windows 办公套件 (MS Word / WPS 文字)...');

    final script = '''
\$ErrorActionPreference = 'Stop'
\$regPaths = @(
  'HKCU:\\Software\\Microsoft\\Office\\16.0\\Word\\Options',
  'HKCU:\\Software\\Microsoft\\Office\\15.0\\Word\\Options'
)
foreach (\$r in \$regPaths) {
  if (!(Test-Path \$r)) { New-Item -Path \$r -Force | Out-Null }
  Set-ItemProperty -Path \$r -Name 'DisableConvertPdfWarning' -Value 1 -Type DWord -Force
}

\$word = \$null
try {
  try {
    \$word = New-Object -ComObject Word.Application
  } catch {
    \$word = New-Object -ComObject KWps.Application
  }
  \$word.Visible = \$false
  \$word.DisplayAlerts = 0
  try { \$word.AutomationSecurity = 3 } catch {}
  try { \$word.FeatureInstall = 0 } catch {}
  try { \$word.ScreenUpdating = \$false } catch {}

  \$doc = \$word.Documents.Open('$absPdf', \$false, \$true, \$false)
  \$doc.SaveAs2('$absDocx', 16)
  \$doc.Close([ref]0)
  Write-Output "SUCCESS"
} catch {
  Write-Error \$_.Exception.Message
  exit 1
} finally {
  if (\$word -ne \$null) {
    try { \$word.Quit([ref]0) } catch {}
    [System.Runtime.InteropServices.Marshal]::ReleaseComObject(\$word) | Out-Null
  }
}
''';

    onProgress?.call(0.3, '正在调用原生 Word PDF Reflow 引擎逆向重构版面与表格...');
    final tempDir = Directory.systemTemp.createTempSync('win_pdf_reflow_');
    final scriptFile = File(p.join(tempDir.path, 'convert_reflow.ps1'));

    try {
      await scriptFile.writeAsBytes(<int>[0xEF, 0xBB, 0xBF, ...utf8.encode(script)]);
      final res = await Process.run('powershell', [
        '-NoProfile',
        '-ExecutionPolicy',
        'Bypass',
        '-File',
        scriptFile.path,
      ]).timeout(
        const Duration(seconds: 35),
        onTimeout: () async {
          try {
            await Process.run('taskkill', ['/F', '/IM', 'WINWORD.EXE']);
          } catch (_) {}
          try {
            await Process.run('taskkill', ['/F', '/IM', 'wps.exe']);
          } catch (_) {}
          return ProcessResult(-1, -999, '', 'WORD_COM_TIMEOUT: Word 原生重构在 35 秒内未响应，已强制清理后台进程');
        },
      );

      if (res.exitCode == 0 && File(absDocx).existsSync() && File(absDocx).lengthSync() > 0) {
        onProgress?.call(1.0, 'Word 重构完成！');
        return ProcessingResult(
          success: true,
          message: '成功通过 Windows 原生 Office 引擎将 PDF 逆向重构为商业级可编辑 Word 文档！',
          outputFiles: [absDocx],
        );
      } else {
        final err = res.stderr.toString().trim();
        return ProcessingResult(
          success: false,
          message: '⚠️ 转换失败：未检测到电脑安装的 Microsoft Word 或 WPS 工具\n\n'
              'Windows 端【PDF 转可编辑 Word】为获得最佳段落、表格重构与排版保留效果，需调用本地安装的 Microsoft Word 或 WPS 文字 原生引擎。\n\n'
              '请确保电脑已安装 Microsoft Office 或 WPS Office 后重试。'
              '${err.isNotEmpty ? "\n(系统返回信息: $err)" : ""}',
        );
      }
    } catch (e) {
      return ProcessingResult(
        success: false,
        message: '调用 Word 转换引擎异常：$e',
      );
    } finally {
      try {
        tempDir.deleteSync(recursive: true);
      } catch (_) {}
    }
  }

  /// 竖向无缝拼接多个图像文件为单张高保真长图
  static Future<String> stitchImagesVertically({
    required List<File> imageFiles,
    required String outputPath,
    required String format,
    Function(double progress, String status)? onProgress,
  }) async {
    if (imageFiles.isEmpty) {
      throw ArgumentError('待拼合图片列表不能为空');
    }

    onProgress?.call(0.65, '正在读取并解码幻灯片画面 (共 ${imageFiles.length} 帧)...');
    final images = <img.Image>[];
    int maxWidth = 0;

    for (int i = 0; i < imageFiles.length; i++) {
      final bytes = await imageFiles[i].readAsBytes();
      final decoded = img.decodeImage(bytes);
      if (decoded != null) {
        images.add(decoded);
        if (decoded.width > maxWidth) {
          maxWidth = decoded.width;
        }
      }
    }

    if (images.isEmpty) {
      throw Exception('未能解码任何有效图像');
    }

    return await stitchImageObjectsVertically(
      images: images,
      outputPath: outputPath,
      format: format,
      onProgress: onProgress,
    );
  }

  /// 将内存中的图片对象列表竖向无缝拼合成单张长图
  static Future<String> stitchImageObjectsVertically({
    required List<img.Image> images,
    required String outputPath,
    required String format,
    Function(double progress, String status)? onProgress,
  }) async {
    if (images.isEmpty) {
      throw ArgumentError('待拼合图片列表不能为空');
    }

    int maxWidth = 0;
    for (final im in images) {
      if (im.width > maxWidth) {
        maxWidth = im.width;
      }
    }

    int totalHeight = 0;
    for (final im in images) {
      if (im.width == maxWidth) {
        totalHeight += im.height;
      } else {
        totalHeight += (im.height * (maxWidth / im.width)).round();
      }
    }

    onProgress?.call(0.8, '正在合成垂直无缝长图画布 ($maxWidth × $totalHeight 像素)...');
    final longImage = img.Image(width: maxWidth, height: totalHeight);
    img.fill(longImage, color: img.ColorRgba8(255, 255, 255, 255));

    int curY = 0;
    for (int i = 0; i < images.length; i++) {
      onProgress?.call(
        0.8 + (i / images.length) * 0.15,
        '正在合成第 ${i + 1}/${images.length} 帧...',
      );
      img.Image toDraw = images[i];
      if (toDraw.width != maxWidth) {
        toDraw = img.copyResize(toDraw, width: maxWidth);
      }
      img.compositeImage(longImage, toDraw, dstX: 0, dstY: curY);
      curY += toDraw.height;
    }

    onProgress?.call(0.96, '正在保存超清长图文件...');
    final Uint8List outBytes;
    if (format.toLowerCase() == 'jpg' || format.toLowerCase() == 'jpeg') {
      outBytes = Uint8List.fromList(img.encodeJpg(longImage, quality: 92));
    } else {
      outBytes = Uint8List.fromList(img.encodePng(longImage));
    }

    await File(outputPath).writeAsBytes(outBytes);
    return outputPath;
  }
}
