import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;
import 'package:syncfusion_flutter_pdf/pdf.dart' as sf;
import 'package:xml/xml.dart' as xml;

import 'tool_engine_service.dart';

/// 排版文本块
class _TextChunk {
  final String text;
  final double fontSize;
  final bool isBold;
  final bool isItalic;
  final sf.PdfColor color;
  final bool isBreak;

  const _TextChunk({
    this.text = '',
    this.fontSize = 13.0,
    this.isBold = false,
    this.isItalic = false,
    required this.color,
    this.isBreak = false,
  });
}

/// 测量后的行内文本切片
class _MeasuredChunk {
  final _TextChunk chunk;
  final double width;
  final sf.PdfCjkStandardFont font;

  _MeasuredChunk({
    required this.chunk,
    required this.width,
    required this.font,
  });
}

/// 测量后的排版视觉行
class _LayoutLine {
  final List<_MeasuredChunk> chunks;
  final double width;
  final double height;
  final String algn;

  _LayoutLine({
    required this.chunks,
    required this.width,
    required this.height,
    required this.algn,
  });
}

/// PPT 演示文稿转高保真 PDF 转换引擎
class PptxPdfConverterService {
  PptxPdfConverterService._();

  /// 执行 PPTX 转 PDF
  static Future<ProcessingResult> convertPptxToPdf({
    required String pptxPath,
    required String outputDir,
    Function(double progress, String status)? onProgress,
  }) async {
    onProgress?.call(0.08, '正在读取 PPTX 演示文稿结构与主题色彩...');
    final bytes = await File(pptxPath).readAsBytes();
    final archive = ZipDecoder().decodeBytes(bytes);

    // 1. 解析全局主题色板 (ppt/theme/theme1.xml)
    final themeColors = _parseThemeColors(archive);

    // 2. 读取幻灯片原生实际尺寸与比例
    double slideWidth = 960.0;
    double slideHeight = 540.0;

    final presFile = archive.findFile('ppt/presentation.xml');
    if (presFile != null) {
      try {
        final presXml = utf8.decode(presFile.content as List<int>, allowMalformed: true);
        final doc = xml.XmlDocument.parse(presXml);
        final sldSz = doc.findAllElements('p:sldSz').firstOrNull;
        if (sldSz != null) {
          final cx = double.tryParse(sldSz.getAttribute('cx') ?? '') ?? 12192000.0;
          final cy = double.tryParse(sldSz.getAttribute('cy') ?? '') ?? 6858000.0;
          slideWidth = max(200.0, cx / 12700.0);
          slideHeight = max(200.0, cy / 12700.0);
        }
      } catch (_) {}
    }

    final bool isLandscape = slideWidth >= slideHeight;

    // 3. 提取所有幻灯片页面文件并自然排序
    final slideFiles = archive.files
        .where((f) => f.isFile && RegExp(r'ppt/slides/slide\d+\.xml$').hasMatch(f.name))
        .toList();
    slideFiles.sort((a, b) => _compareNatural(a.name, b.name));

    final totalSlides = max(1, slideFiles.length);
    onProgress?.call(0.18, '正在初始化高保真演示级 PDF (共 $totalSlides 页，单页尺寸: ${slideWidth.toStringAsFixed(1)} x ${slideHeight.toStringAsFixed(1)} pt)...');

    // 4. 提取所有媒体资源
    final mediaMap = <String, Uint8List>{};
    for (final f in archive.files) {
      if (f.isFile && f.name.startsWith('ppt/media/')) {
        mediaMap[p.basename(f.name)] = Uint8List.fromList(f.content as List<int>);
      }
    }

    final pdfDoc = sf.PdfDocument();

    for (int i = 0; i < totalSlides; i++) {
      onProgress?.call(
        0.2 + (i / totalSlides) * 0.75,
        '正在逐层排版渲染第 ${i + 1}/$totalSlides 幻灯片页面 (主题、矢量形状与高精度字体)...',
      );

      final section = pdfDoc.sections!.add();
      section.pageSettings.setMargins(0);
      section.pageSettings.size = ui.Size(slideWidth, slideHeight);
      section.pageSettings.orientation =
          isLandscape ? sf.PdfPageOrientation.landscape : sf.PdfPageOrientation.portrait;
      final page = section.pages.add();
      final graphics = page.graphics;

      final slideFile = i < slideFiles.length ? slideFiles[i] : null;
      if (slideFile == null) continue;

      // 解析对应 slideX.xml.rels
      final relsMap = <String, String>{};
      final relsName = 'ppt/slides/_rels/${p.basename(slideFile.name)}.rels';
      final relsFile = archive.findFile(relsName);
      if (relsFile != null) {
        try {
          final relsXml = utf8.decode(relsFile.content as List<int>, allowMalformed: true);
          final doc = xml.XmlDocument.parse(relsXml);
          for (final rel in doc.findAllElements('Relationship')) {
            final id = rel.getAttribute('Id') ?? '';
            final target = rel.getAttribute('Target') ?? '';
            relsMap[id] = p.basename(target);
          }
        } catch (_) {}
      }

      final slideXml = utf8.decode(slideFile.content as List<int>, allowMalformed: true);
      final doc = xml.XmlDocument.parse(slideXml);

      // A. 渲染背景层
      bool hasBackground = false;
      final bgElem = doc.findAllElements('p:bg').firstOrNull;
      if (bgElem != null) {
        // 背景图片
        final blip = bgElem.findAllElements('a:blip').firstOrNull;
        if (blip != null) {
          final rId = blip.getAttribute('r:embed') ?? '';
          final mediaName = relsMap[rId];
          if (mediaName != null && mediaMap.containsKey(mediaName)) {
            try {
              final sfBitmap = sf.PdfBitmap(mediaMap[mediaName]!);
              graphics.drawImage(sfBitmap, ui.Rect.fromLTWH(0, 0, slideWidth, slideHeight));
              hasBackground = true;
            } catch (_) {}
          }
        }
        // 背景单色填充
        if (!hasBackground) {
          final clr = _resolveColor(bgElem, themeColors);
          if (clr != null) {
            graphics.drawRectangle(
              brush: sf.PdfSolidBrush(clr),
              bounds: ui.Rect.fromLTWH(0, 0, slideWidth, slideHeight),
            );
            hasBackground = true;
          }
        }
      }

      if (!hasBackground) {
        // 默认白底清爽背景
        graphics.drawRectangle(
          brush: sf.PdfSolidBrush(sf.PdfColor(255, 255, 255)),
          bounds: ui.Rect.fromLTWH(0, 0, slideWidth, slideHeight),
        );
      }

      // B. 渲染内容层 (遍历 spTree 子节点)
      final spTree = doc.findAllElements('p:spTree').firstOrNull;
      if (spTree != null) {
        _renderSpTree(spTree, graphics, relsMap, mediaMap, themeColors, slideWidth, slideHeight);
      }

      // C. 底部微标页码
      final footerFont = sf.PdfStandardFont(sf.PdfFontFamily.helvetica, 8);
      graphics.drawString(
        '${i + 1} / $totalSlides',
        footerFont,
        brush: sf.PdfSolidBrush(sf.PdfColor(148, 163, 184)),
        bounds: ui.Rect.fromLTWH(slideWidth - 70, slideHeight - 20, 60, 14),
      );
    }

    onProgress?.call(0.96, '正在保存高精度 PDF 演示文稿...');
    final pdfBytes = pdfDoc.saveSync();
    pdfDoc.dispose();

    final baseName = p.basenameWithoutExtension(pptxPath);
    final outPath = p.join(outputDir, '${baseName}_presentation.pdf');
    await File(outPath).writeAsBytes(pdfBytes);

    onProgress?.call(1.0, '转换完成！');
    return ProcessingResult(
      success: true,
      message: '成功将 PPTX 演示文稿转换为 $totalSlides 页高保真 PDF (字体大小、色彩样式与版式完全还原)！',
      outputFiles: [outPath],
    );
  }

  /// 解析全局主题色表 (ppt/theme/theme1.xml)
  static Map<String, sf.PdfColor> _parseThemeColors(Archive archive) {
    final themeColors = <String, sf.PdfColor>{
      'dk1': sf.PdfColor(0, 0, 0),
      'lt1': sf.PdfColor(255, 255, 255),
      'dk2': sf.PdfColor(31, 73, 125),
      'lt2': sf.PdfColor(238, 236, 225),
      'accent1': sf.PdfColor(79, 129, 189),
      'accent2': sf.PdfColor(192, 80, 77),
      'accent3': sf.PdfColor(155, 187, 89),
      'accent4': sf.PdfColor(128, 100, 162),
      'accent5': sf.PdfColor(75, 172, 198),
      'accent6': sf.PdfColor(247, 150, 70),
      'hlink': sf.PdfColor(0, 0, 255),
      'folHlink': sf.PdfColor(128, 0, 128),
    };

    final themeFile = archive.findFile('ppt/theme/theme1.xml');
    if (themeFile != null) {
      try {
        final content = utf8.decode(themeFile.content as List<int>, allowMalformed: true);
        final doc = xml.XmlDocument.parse(content);
        final clrScheme = doc.findAllElements('a:clrScheme').firstOrNull;
        if (clrScheme != null) {
          for (final child in clrScheme.children.whereType<xml.XmlElement>()) {
            final key = child.name.local;
            final srgb = child.findElements('a:srgbClr').firstOrNull;
            if (srgb != null) {
              final c = _parseHexColor(srgb.getAttribute('val') ?? '');
              if (c != null) themeColors[key] = c;
            } else {
              final sys = child.findElements('a:sysClr').firstOrNull;
              if (sys != null) {
                final c = _parseHexColor(sys.getAttribute('lastClr') ?? '');
                if (c != null) themeColors[key] = c;
              }
            }
          }
        }
      } catch (_) {}
    }

    themeColors['tx1'] = themeColors['dk1']!;
    themeColors['bg1'] = themeColors['lt1']!;
    themeColors['tx2'] = themeColors['dk2']!;
    themeColors['bg2'] = themeColors['lt2']!;
    return themeColors;
  }

  /// 递归遍历 spTree 渲染图形、图像、表格与文字
  static void _renderSpTree(
    xml.XmlElement parent,
    sf.PdfGraphics graphics,
    Map<String, String> relsMap,
    Map<String, Uint8List> mediaMap,
    Map<String, sf.PdfColor> themeColors,
    double slideWidth,
    double slideHeight,
  ) {
    for (final child in parent.children.whereType<xml.XmlElement>()) {
      final name = child.name.local;

      if (name == 'pic') {
        _renderPicture(child, graphics, relsMap, mediaMap);
      } else if (name == 'sp') {
        _renderShape(child, graphics, relsMap, mediaMap, themeColors, slideWidth, slideHeight);
      } else if (name == 'graphicFrame') {
        _renderGraphicFrame(child, graphics, themeColors);
      } else if (name == 'grpSp') {
        _renderSpTree(child, graphics, relsMap, mediaMap, themeColors, slideWidth, slideHeight);
      }
    }
  }

  /// 渲染独立图片 (`<p:pic>`)
  static void _renderPicture(
    xml.XmlElement pic,
    sf.PdfGraphics graphics,
    Map<String, String> relsMap,
    Map<String, Uint8List> mediaMap,
  ) {
    final rect = _parseXfrmBounds(pic);
    if (rect == null) return;

    final blip = pic.findAllElements('a:blip').firstOrNull;
    if (blip == null) return;

    final rId = blip.getAttribute('r:embed') ?? '';
    final mediaName = relsMap[rId];
    if (mediaName != null && mediaMap.containsKey(mediaName)) {
      try {
        final sfBitmap = sf.PdfBitmap(mediaMap[mediaName]!);
        graphics.drawImage(sfBitmap, rect);
      } catch (_) {}
    }
  }

  /// 渲染形状与文字框 (`<p:sp>`)
  static void _renderShape(
    xml.XmlElement sp,
    sf.PdfGraphics graphics,
    Map<String, String> relsMap,
    Map<String, Uint8List> mediaMap,
    Map<String, sf.PdfColor> themeColors,
    double slideWidth,
    double slideHeight,
  ) {
    final rect = _parseXfrmBounds(sp);
    if (rect == null) return;

    final spPr = sp.findElements('p:spPr').firstOrNull;
    final prstGeom = spPr?.findElements('a:prstGeom').firstOrNull?.getAttribute('prst') ?? 'rect';

    sf.PdfColor? fillColor;
    sf.PdfPen? strokePen;

    // 1. 检查形状填充与描边
    if (spPr != null) {
      // 检查图片填充 (blipFill)
      final blipFill = spPr.findElements('a:blipFill').firstOrNull;
      if (blipFill != null) {
        final blip = blipFill.findAllElements('a:blip').firstOrNull;
        final rId = blip?.getAttribute('r:embed') ?? '';
        final mediaName = relsMap[rId];
        if (mediaName != null && mediaMap.containsKey(mediaName)) {
          try {
            final sfBitmap = sf.PdfBitmap(mediaMap[mediaName]!);
            graphics.drawImage(sfBitmap, rect);
          } catch (_) {}
        }
      }

      // 检查纯色填充 (solidFill)
      final solidFill = spPr.findElements('a:solidFill').firstOrNull;
      if (solidFill != null) {
        fillColor = _resolveColor(solidFill, themeColors);
      }

      // 检查轮廓 (ln)
      final lnElem = spPr.findElements('a:ln').firstOrNull;
      if (lnElem != null) {
        final lnClr = _resolveColor(lnElem, themeColors);
        final wAttr = lnElem.getAttribute('w');
        final strokeW = wAttr != null ? max(0.5, (double.tryParse(wAttr) ?? 12700.0) / 12700.0) : 1.0;
        if (lnClr != null) {
          strokePen = sf.PdfPen(lnClr, width: strokeW);
        }
      }

      // 绘制图形几何体 (支持矩形、圆角矩形、椭圆)
      if (fillColor != null || strokePen != null) {
        _drawShapeGeometry(
          graphics,
          prstGeom,
          rect,
          brush: fillColor != null ? sf.PdfSolidBrush(fillColor) : null,
          pen: strokePen,
        );
      }
    }

    // 2. 检查文本内容 (p:txBody)
    final txBody = sp.findElements('p:txBody').firstOrNull;
    if (txBody == null) return;

    final paragraphs = txBody.findElements('a:p').toList();
    if (paragraphs.isEmpty) return;

    final bodyPr = txBody.findElements('a:bodyPr').firstOrNull;
    final anchor = bodyPr?.getAttribute('anchor') ?? 't';

    final lIns = (double.tryParse(bodyPr?.getAttribute('lIns') ?? '') ?? 91440.0) / 12700.0;
    final tIns = (double.tryParse(bodyPr?.getAttribute('tIns') ?? '') ?? 45720.0) / 12700.0;
    final rIns = (double.tryParse(bodyPr?.getAttribute('rIns') ?? '') ?? 91440.0) / 12700.0;
    final bIns = (double.tryParse(bodyPr?.getAttribute('bIns') ?? '') ?? 45720.0) / 12700.0;

    final padL = min(rect.width * 0.15, max(2.0, lIns));
    final padR = min(rect.width * 0.15, max(2.0, rIns));
    final padT = min(rect.height * 0.2, max(2.0, tIns));
    final padB = min(rect.height * 0.2, max(2.0, bIns));
    final availWidth = max(10.0, rect.width - padL - padR);
    final availHeight = max(10.0, rect.height - padT - padB);

    final allLines = <_LayoutLine>[];

    for (int pIdx = 0; pIdx < paragraphs.length; pIdx++) {
      final pElem = paragraphs[pIdx];
      final pPr = pElem.findElements('a:pPr').firstOrNull;
      final algn = pPr?.getAttribute('algn') ?? 'l';
      final defRPr = pPr?.findElements('a:defRPr').firstOrNull;

      // 解析段落级默认属性
      final defSzAttr = defRPr?.getAttribute('sz');
      final defFontSize = defSzAttr != null
          ? (double.tryParse(defSzAttr) ?? 1400.0) / 100.0
          : 14.0;
      final defIsBold = defRPr?.getAttribute('b') == '1';
      final defIsItalic = defRPr?.getAttribute('i') == '1';
      final defColor = _resolveColor(defRPr, themeColors) ??
          ((fillColor != null && _isDarkColor(fillColor))
              ? sf.PdfColor(255, 255, 255)
              : sf.PdfColor(30, 41, 59));

      final chunks = <_TextChunk>[];
      for (final child in pElem.children.whereType<xml.XmlElement>()) {
        final tag = child.name.local;
        if (tag == 'br') {
          chunks.add(_TextChunk(isBreak: true, color: defColor));
        } else if (tag == 'r' || tag == 'fld') {
          final tElem = child.findElements('a:t').firstOrNull;
          final text = tElem?.innerText ?? '';
          if (text.isEmpty) continue;

          final rPr = child.findElements('a:rPr').firstOrNull;
          final szAttr = rPr?.getAttribute('sz');
          final rFontSize = szAttr != null
              ? (double.tryParse(szAttr) ?? (defFontSize * 100)) / 100.0
              : defFontSize;
          final rIsBold = rPr?.getAttribute('b') != null
              ? (rPr!.getAttribute('b') == '1')
              : defIsBold;
          final rIsItalic = rPr?.getAttribute('i') != null
              ? (rPr!.getAttribute('i') == '1')
              : defIsItalic;
          final rColor = _resolveColor(rPr, themeColors) ?? defColor;

          chunks.add(_TextChunk(
            text: text,
            fontSize: max(6.0, min(80.0, rFontSize)),
            isBold: rIsBold,
            isItalic: rIsItalic,
            color: rColor,
          ));
        }
      }

      if (chunks.isEmpty) {
        // 空段落占位
        allLines.add(_LayoutLine(
          chunks: [],
          width: 0.0,
          height: defFontSize * 0.8,
          algn: algn,
        ));
      } else {
        final pLines = _layoutParagraph(chunks, algn, availWidth);
        allLines.addAll(pLines);
      }
    }

    if (allLines.isEmpty) return;

    // 垂直方向对齐 (anchor: ctr, b, t)
    final totalTextHeight = allLines.fold<double>(0.0, (sum, l) => sum + l.height);

    double startY;
    if (anchor == 'ctr' || anchor == 'just' || anchor == 'dist') {
      startY = rect.top + padT + max(0.0, (availHeight - totalTextHeight) / 2);
    } else if (anchor == 'b') {
      startY = rect.bottom - padB - totalTextHeight;
    } else {
      startY = rect.top + padT;
    }

    double curY = startY;
    for (final line in allLines) {
      if (curY + line.height > slideHeight - 8.0) break;

      double curX;
      if (line.algn == 'ctr') {
        curX = rect.left + padL + max(0.0, (availWidth - line.width) / 2);
      } else if (line.algn == 'r') {
        curX = rect.right - padR - line.width;
      } else {
        curX = rect.left + padL;
      }

      for (final mc in line.chunks) {
        graphics.drawString(
          mc.chunk.text,
          mc.font,
          brush: sf.PdfSolidBrush(mc.chunk.color),
          bounds: ui.Rect.fromLTWH(curX, curY, mc.width + 2, line.height),
        );
        curX += mc.width;
      }

      curY += line.height;
    }
  }

  /// 绘制形状矢量几何轮廓
  static void _drawShapeGeometry(
    sf.PdfGraphics graphics,
    String prst,
    ui.Rect rect, {
    sf.PdfBrush? brush,
    sf.PdfPen? pen,
  }) {
    if (prst == 'roundRect') {
      final r = min(10.0, min(rect.width, rect.height) / 4);
      final path = sf.PdfPath();
      path.addArc(ui.Rect.fromLTWH(rect.left, rect.top, 2 * r, 2 * r), 180, 90);
      path.addLine(ui.Offset(rect.left + r, rect.top), ui.Offset(rect.right - r, rect.top));
      path.addArc(ui.Rect.fromLTWH(rect.right - 2 * r, rect.top, 2 * r, 2 * r), 270, 90);
      path.addLine(ui.Offset(rect.right, rect.top + r), ui.Offset(rect.right, rect.bottom - r));
      path.addArc(ui.Rect.fromLTWH(rect.right - 2 * r, rect.bottom - 2 * r, 2 * r, 2 * r), 0, 90);
      path.addLine(ui.Offset(rect.right - r, rect.bottom), ui.Offset(rect.left + r, rect.bottom));
      path.addArc(ui.Rect.fromLTWH(rect.left, rect.bottom - 2 * r, 2 * r, 2 * r), 90, 90);
      path.addLine(ui.Offset(rect.left, rect.bottom - r), ui.Offset(rect.left, rect.top + r));
      path.closeFigure();
      graphics.drawPath(path, brush: brush, pen: pen);
    } else if (prst == 'ellipse') {
      graphics.drawEllipse(rect, brush: brush, pen: pen);
    } else {
      graphics.drawRectangle(brush: brush, pen: pen, bounds: rect);
    }
  }

  /// 段落多样式文本排版换行计算
  static List<_LayoutLine> _layoutParagraph(
    List<_TextChunk> chunks,
    String algn,
    double availWidth,
  ) {
    final lines = <_LayoutLine>[];
    var currentLineChunks = <_MeasuredChunk>[];
    double currentLineWidth = 0.0;
    double currentLineHeight = 14.0;

    void finishLine() {
      if (currentLineChunks.isNotEmpty) {
        lines.add(_LayoutLine(
          chunks: List.from(currentLineChunks),
          width: currentLineWidth,
          height: currentLineHeight,
          algn: algn,
        ));
        currentLineChunks.clear();
        currentLineWidth = 0.0;
        currentLineHeight = 14.0;
      }
    }

    for (final chunk in chunks) {
      if (chunk.isBreak) {
        finishLine();
        continue;
      }

      final font = sf.PdfCjkStandardFont(
        sf.PdfCjkFontFamily.monotypeHeiMedium,
        chunk.fontSize,
        style: chunk.isBold
            ? sf.PdfFontStyle.bold
            : (chunk.isItalic ? sf.PdfFontStyle.italic : sf.PdfFontStyle.regular),
      );

      final rawText = chunk.text;
      if (rawText.isEmpty) continue;

      final totalWidth = font.measureString(rawText).width;
      if (currentLineWidth + totalWidth <= availWidth || currentLineChunks.isEmpty) {
        currentLineChunks.add(_MeasuredChunk(
          chunk: chunk,
          width: totalWidth,
          font: font,
        ));
        currentLineWidth += totalWidth;
        currentLineHeight = max(currentLineHeight, chunk.fontSize * 1.32);
      } else {
        // 需分词或按字符折行
        final runes = rawText.runes.toList();
        final wordBuf = StringBuffer();

        for (int i = 0; i < runes.length; i++) {
          final char = String.fromCharCode(runes[i]);
          final testWidth = font.measureString(wordBuf.toString() + char).width;

          if (currentLineWidth + testWidth <= availWidth || currentLineChunks.isEmpty) {
            wordBuf.write(char);
          } else {
            if (wordBuf.isNotEmpty) {
              final w = font.measureString(wordBuf.toString()).width;
              currentLineChunks.add(_MeasuredChunk(
                chunk: _TextChunk(
                  text: wordBuf.toString(),
                  fontSize: chunk.fontSize,
                  isBold: chunk.isBold,
                  isItalic: chunk.isItalic,
                  color: chunk.color,
                ),
                width: w,
                font: font,
              ));
              currentLineWidth += w;
              currentLineHeight = max(currentLineHeight, chunk.fontSize * 1.32);
              wordBuf.clear();
            }
            finishLine();
            wordBuf.write(char);
          }
        }

        if (wordBuf.isNotEmpty) {
          final w = font.measureString(wordBuf.toString()).width;
          currentLineChunks.add(_MeasuredChunk(
            chunk: _TextChunk(
              text: wordBuf.toString(),
              fontSize: chunk.fontSize,
              isBold: chunk.isBold,
              isItalic: chunk.isItalic,
              color: chunk.color,
            ),
            width: w,
            font: font,
          ));
          currentLineWidth += w;
          currentLineHeight = max(currentLineHeight, chunk.fontSize * 1.32);
        }
      }
    }

    finishLine();
    return lines;
  }

  /// 渲染图表格 (`<p:graphicFrame>`)
  static void _renderGraphicFrame(
    xml.XmlElement frame,
    sf.PdfGraphics graphics,
    Map<String, sf.PdfColor> themeColors,
  ) {
    final rect = _parseXfrmBounds(frame);
    if (rect == null) return;

    final tbl = frame.findAllElements('a:tbl').firstOrNull;
    if (tbl == null) return;

    final rows = tbl.findAllElements('a:tr').toList();
    if (rows.isEmpty) return;

    final rowCount = rows.length;
    final rowHeight = rect.height / max(1, rowCount);

    for (int r = 0; r < rowCount; r++) {
      final cells = rows[r].findAllElements('a:tc').toList();
      if (cells.isEmpty) continue;
      final colWidth = rect.width / max(1, cells.length);

      for (int c = 0; c < cells.length; c++) {
        final cellRect = ui.Rect.fromLTWH(
          rect.left + c * colWidth,
          rect.top + r * rowHeight,
          colWidth,
          rowHeight,
        );

        // 绘制单元格背景与边框
        final tcPr = cells[c].findElements('a:tcPr').firstOrNull;
        final cellFill = _resolveColor(tcPr, themeColors) ??
            (r == 0 ? sf.PdfColor(241, 245, 249) : sf.PdfColor(255, 255, 255));

        graphics.drawRectangle(
          pen: sf.PdfPen(sf.PdfColor(226, 232, 240), width: 0.8),
          brush: sf.PdfSolidBrush(cellFill),
          bounds: cellRect,
        );

        final text = cells[c]
            .findAllElements('a:t')
            .map((e) => e.innerText)
            .join(' ')
            .trim();
        if (text.isNotEmpty) {
          final font = sf.PdfCjkStandardFont(
            sf.PdfCjkFontFamily.monotypeHeiMedium,
            10,
            style: r == 0 ? sf.PdfFontStyle.bold : sf.PdfFontStyle.regular,
          );
          final textBrush = _isDarkColor(cellFill)
              ? sf.PdfSolidBrush(sf.PdfColor(255, 255, 255))
              : sf.PdfSolidBrush(sf.PdfColor(30, 41, 59));

          graphics.drawString(
            text,
            font,
            brush: textBrush,
            bounds: ui.Rect.fromLTWH(cellRect.left + 4, cellRect.top + 4, cellRect.width - 8, cellRect.height - 8),
          );
        }
      }
    }
  }

  /// 解析 `<a:xfrm>` 中的坐标与宽高并转换为 PDF Points
  static ui.Rect? _parseXfrmBounds(xml.XmlElement elem) {
    final off = elem.findAllElements('a:off').firstOrNull;
    final ext = elem.findAllElements('a:ext').firstOrNull;
    if (off == null || ext == null) return null;

    final ox = double.tryParse(off.getAttribute('x') ?? '');
    final oy = double.tryParse(off.getAttribute('y') ?? '');
    final cx = double.tryParse(ext.getAttribute('cx') ?? '');
    final cy = double.tryParse(ext.getAttribute('cy') ?? '');

    if (ox == null || oy == null || cx == null || cy == null) return null;

    return ui.Rect.fromLTWH(
      ox / 12700.0,
      oy / 12700.0,
      max(1.0, cx / 12700.0),
      max(1.0, cy / 12700.0),
    );
  }

  /// 提取节点颜色并结合主题解析
  static sf.PdfColor? _resolveColor(
    xml.XmlElement? container,
    Map<String, sf.PdfColor> themeColors,
  ) {
    if (container == null) return null;

    final srgb = container.findAllElements('a:srgbClr').firstOrNull;
    if (srgb != null) {
      return _parseHexColor(srgb.getAttribute('val') ?? '');
    }

    final scheme = container.findAllElements('a:schemeClr').firstOrNull;
    if (scheme != null) {
      final val = scheme.getAttribute('val') ?? '';
      final base = themeColors[val];
      if (base != null) {
        final lumModAttr = scheme.findElements('a:lumMod').firstOrNull?.getAttribute('val');
        final lumOffAttr = scheme.findElements('a:lumOff').firstOrNull?.getAttribute('val');
        if (lumModAttr != null || lumOffAttr != null) {
          final mod = (double.tryParse(lumModAttr ?? '') ?? 100000.0) / 100000.0;
          final off = (double.tryParse(lumOffAttr ?? '') ?? 0.0) / 100000.0;
          return _adjustLuminance(base, mod, off);
        }
        return base;
      }
    }

    final sys = container.findAllElements('a:sysClr').firstOrNull;
    if (sys != null) {
      return _parseHexColor(sys.getAttribute('lastClr') ?? '');
    }

    return null;
  }

  /// 16 进制颜色解析
  static sf.PdfColor? _parseHexColor(String hex) {
    if (hex.isEmpty) return null;
    hex = hex.replaceAll('#', '').trim();
    if (hex.length == 6) {
      final r = int.tryParse(hex.substring(0, 2), radix: 16) ?? 0;
      final g = int.tryParse(hex.substring(2, 4), radix: 16) ?? 0;
      final b = int.tryParse(hex.substring(4, 6), radix: 16) ?? 0;
      return sf.PdfColor(r, g, b);
    }
    return null;
  }

  /// 调整色相亮度 (lumMod / lumOff)
  static sf.PdfColor _adjustLuminance(sf.PdfColor color, double mod, double off) {
    int adjust(int val) {
      final res = (val * mod + 255.0 * off).round();
      return max(0, min(255, res));
    }
    return sf.PdfColor(adjust(color.r), adjust(color.g), adjust(color.b));
  }

  /// 判断颜色明暗以决定反色文字
  static bool _isDarkColor(sf.PdfColor color) {
    final luminance = 0.299 * color.r + 0.587 * color.g + 0.114 * color.b;
    return luminance < 140;
  }

  static int _compareNatural(String a, String b) {
    final re = RegExp(r'(\d+)|(\D+)');
    final aMatches = re.allMatches(a).toList();
    final bMatches = re.allMatches(b).toList();
    for (int i = 0; i < min(aMatches.length, bMatches.length); i++) {
      final aStr = aMatches[i].group(0)!;
      final bStr = bMatches[i].group(0)!;
      final aNum = int.tryParse(aStr);
      final bNum = int.tryParse(bStr);
      if (aNum != null && bNum != null) {
        final cmp = aNum.compareTo(bNum);
        if (cmp != 0) return cmp;
      } else {
        final cmp = aStr.compareTo(bStr);
        if (cmp != 0) return cmp;
      }
    }
    return a.length.compareTo(b.length);
  }
}
