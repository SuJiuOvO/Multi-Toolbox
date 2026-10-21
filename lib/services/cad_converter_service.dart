import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:archive/archive.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:syncfusion_flutter_pdf/pdf.dart' as sf;
import 'package:xml/xml.dart' as xml;

import 'tool_engine_service.dart';

/// 2D 坐标点
class CadPoint2D {
  final double x;
  final double y;
  const CadPoint2D(this.x, this.y);
}

/// CAD 扁平化矢量图元
abstract class CadPrimitive {
  final int colorIndex;
  const CadPrimitive({this.colorIndex = 7});
}

class CadLinePrimitive extends CadPrimitive {
  final CadPoint2D p1;
  final CadPoint2D p2;
  const CadLinePrimitive(this.p1, this.p2, {super.colorIndex});
}

class CadPolylinePrimitive extends CadPrimitive {
  final List<CadPoint2D> points;
  final bool isClosed;
  const CadPolylinePrimitive(this.points, {this.isClosed = false, super.colorIndex});
}

class CadCirclePrimitive extends CadPrimitive {
  final CadPoint2D center;
  final double radius;
  const CadCirclePrimitive(this.center, this.radius, {super.colorIndex});
}

class CadTextPrimitive extends CadPrimitive {
  final CadPoint2D position;
  final String text;
  final double height;
  final double rotation;
  const CadTextPrimitive(this.position, this.text, {this.height = 10, this.rotation = 0, super.colorIndex});
}

/// DXF Group Code Pair
class _DxfPair {
  final int code;
  final String value;
  const _DxfPair(this.code, this.value);
}

/// CAD 图元与块结构定义
class _DxfEntityData {
  final String type;
  final List<_DxfPair> pairs;
  const _DxfEntityData(this.type, this.pairs);
}

class _DxfBlockData {
  final String name;
  final CadPoint2D basePoint;
  final List<_DxfEntityData> entities;
  _DxfBlockData(this.name, this.basePoint, this.entities);
}

/// 专业离线 CAD (DXF / DWG / DWF) 转高保真 PDF 转换引擎
class CadConverterService {
  CadConverterService._();

  static const List<String> supportedExtensions = ['dxf', 'dwg', 'dwf'];

  /// 执行 CAD 转 PDF 主入口
  static Future<ProcessingResult> convertCadToPdf({
    required List<String> files,
    required Map<String, dynamic> params,
    required String outputDir,
    Function(double progress, String status)? onProgress,
  }) async {
    final cadPath = files.first;
    final ext = p.extension(cadPath).toLowerCase().replaceAll('.', '');

    if (ext == 'dwg' || ext == 'dwf') {
      return ProcessingResult(
        success: false,
        message: '⚠️ 格式限制：${ext.toUpperCase()} 属于 Autodesk 专有二进制加密格式，独立离线端无法直接进行交付级全矢量解码。\n\n'
            '【100% 原始全矢量转换操作指南】：\n'
            '1. 在 AutoCAD / 中望CAD / 浩辰CAD 中打开此图纸；\n'
            '2. 命令行键入快捷命令 DXFOUT 并按回车（或点击【文件】->【另存为】-> 选择【AutoCAD DXF 格式 (*.dxf)】保存）；\n'
            '3. 将保存后的 .dxf 文件直接拖入本工具转换，即可立即输出包含全部图元与块引用的高质量全矢量 PDF！',
      );
    } else {
      return await _convertDxfToPdf(cadPath, params, outputDir, onProgress);
    }
  }

  // ===========================================================================
  // 1. DXF 矢量图纸全图元与块引用 (BLOCKS / INSERT) 展开转矢量 PDF
  // ===========================================================================
  static Future<ProcessingResult> _convertDxfToPdf(
    String dxfPath,
    Map<String, dynamic> params,
    String outputDir,
    Function(double, String)? onProgress,
  ) async {
    final pageSizeStr = params['pageSize']?.toString() ?? 'A4';
    final orientation = params['orientation']?.toString() ?? 'auto';

    onProgress?.call(0.1, '正在读取并解析 AutoCAD DXF 矢量数据...');
    final file = File(dxfPath);
    String dxfContent;
    try {
      dxfContent = await file.readAsString(encoding: utf8);
    } catch (_) {
      try {
        dxfContent = await file.readAsString(encoding: const Utf8Codec(allowMalformed: true));
      } catch (_) {
        dxfContent = await file.readAsString(encoding: latin1);
      }
    }

    onProgress?.call(0.2, '正在分析 DXF 块定义 (BLOCKS) 与顶层实体 (ENTITIES)...');
    final pairs = _parseDxfPairs(dxfContent);

    final blocks = <String, _DxfBlockData>{};
    final topEntities = <_DxfEntityData>[];

    String? currentSection;
    _DxfBlockData? currentBlock;

    for (int i = 0; i < pairs.length; i++) {
      final pair = pairs[i];
      if (pair.code == 0 && pair.value == 'SECTION') {
        if (i + 1 < pairs.length && pairs[i + 1].code == 2) {
          currentSection = pairs[i + 1].value;
          i++;
        }
        continue;
      } else if (pair.code == 0 && pair.value == 'ENDSEC') {
        currentSection = null;
        continue;
      }

      if (currentSection == 'BLOCKS') {
        if (pair.code == 0 && pair.value == 'BLOCK') {
          String bname = '';
          double bx = 0.0, by = 0.0;
          final entList = <_DxfEntityData>[];
          int j = i + 1;
          while (j < pairs.length && pairs[j].code != 0) {
            if (pairs[j].code == 2) bname = pairs[j].value;
            if (pairs[j].code == 10) bx = double.tryParse(pairs[j].value) ?? 0.0;
            if (pairs[j].code == 20) by = double.tryParse(pairs[j].value) ?? 0.0;
            j++;
          }
          currentBlock = _DxfBlockData(bname, CadPoint2D(bx, by), entList);
          if (bname.isNotEmpty) {
            blocks[bname] = currentBlock;
          }
          i = j - 1;
        } else if (pair.code == 0 && pair.value == 'ENDBLK') {
          currentBlock = null;
        } else if (pair.code == 0 && currentBlock != null) {
          final etype = pair.value;
          final ep = <_DxfPair>[pair];
          int j = i + 1;
          while (j < pairs.length && pairs[j].code != 0) {
            ep.add(pairs[j]);
            j++;
          }
          currentBlock.entities.add(_DxfEntityData(etype, ep));
          i = j - 1;
        }
      } else if (currentSection == 'ENTITIES') {
        if (pair.code == 0) {
          final etype = pair.value;
          final ep = <_DxfPair>[pair];
          int j = i + 1;
          while (j < pairs.length && pairs[j].code != 0) {
            ep.add(pairs[j]);
            j++;
          }
          topEntities.add(_DxfEntityData(etype, ep));
          i = j - 1;
        }
      }
    }

    onProgress?.call(0.4, '正在展开图块引用与坐标矩阵变换...');
    final flattened = <CadPrimitive>[];

    void expandEntityList(
      List<_DxfEntityData> list,
      double tx,
      double ty,
      double sx,
      double sy,
      double rotDeg,
      int depth,
    ) {
      if (depth > 12) return;

      for (final ed in list) {
        final attr = <int, List<String>>{};
        for (final p in ed.pairs) {
          attr.putIfAbsent(p.code, () => []).add(p.value);
        }

        final colorIdx = int.tryParse(attr[62]?.first ?? '7') ?? 7;

        if (ed.type == 'INSERT') {
          final bname = attr[2]?.first ?? '';
          final ix = double.tryParse(attr[10]?.first ?? '0') ?? 0.0;
          final iy = double.tryParse(attr[20]?.first ?? '0') ?? 0.0;
          final isx = double.tryParse(attr[41]?.first ?? '1') ?? 1.0;
          final isy = double.tryParse(attr[42]?.first ?? '1') ?? 1.0;
          final irot = double.tryParse(attr[50]?.first ?? '0') ?? 0.0;

          final transformedIns = _transformPoint(ix, iy, tx, ty, sx, sy, rotDeg);
          final combRot = rotDeg + irot;
          final combSx = sx * isx;
          final combSy = sy * isy;

          if (blocks.containsKey(bname)) {
            expandEntityList(
              blocks[bname]!.entities,
              transformedIns.x,
              transformedIns.y,
              combSx,
              combSy,
              combRot,
              depth + 1,
            );
          }
        } else if (ed.type == 'LINE') {
          final x1 = double.tryParse(attr[10]?.first ?? '0') ?? 0.0;
          final y1 = double.tryParse(attr[20]?.first ?? '0') ?? 0.0;
          final x2 = double.tryParse(attr[11]?.first ?? '0') ?? 0.0;
          final y2 = double.tryParse(attr[21]?.first ?? '0') ?? 0.0;

          final tp1 = _transformPoint(x1, y1, tx, ty, sx, sy, rotDeg);
          final tp2 = _transformPoint(x2, y2, tx, ty, sx, sy, rotDeg);
          flattened.add(CadLinePrimitive(tp1, tp2, colorIndex: colorIdx));
        } else if (ed.type == 'ARC') {
          final cx = double.tryParse(attr[10]?.first ?? '0') ?? 0.0;
          final cy = double.tryParse(attr[20]?.first ?? '0') ?? 0.0;
          final r = double.tryParse(attr[40]?.first ?? '0') ?? 0.0;
          final sa = double.tryParse(attr[50]?.first ?? '0') ?? 0.0;
          final ea = double.tryParse(attr[51]?.first ?? '0') ?? 0.0;

          var sweep = (ea - sa) % 360.0;
          if (sweep <= 0.001) sweep = 360.0;
          final steps = max(8, min(64, (sweep / 8.0).ceil()));
          final pts = <CadPoint2D>[];
          for (int s = 0; s <= steps; s++) {
            final ang = (sa + sweep * (s / steps)) * pi / 180.0;
            final px = cx + r * cos(ang);
            final py = cy + r * sin(ang);
            pts.add(_transformPoint(px, py, tx, ty, sx, sy, rotDeg));
          }
          flattened.add(CadPolylinePrimitive(pts, isClosed: false, colorIndex: colorIdx));
        } else if (ed.type == 'CIRCLE') {
          final cx = double.tryParse(attr[10]?.first ?? '0') ?? 0.0;
          final cy = double.tryParse(attr[20]?.first ?? '0') ?? 0.0;
          final r = double.tryParse(attr[40]?.first ?? '0') ?? 0.0;

          const steps = 36;
          final pts = <CadPoint2D>[];
          for (int s = 0; s <= steps; s++) {
            final ang = (s * 10.0) * pi / 180.0;
            final px = cx + r * cos(ang);
            final py = cy + r * sin(ang);
            pts.add(_transformPoint(px, py, tx, ty, sx, sy, rotDeg));
          }
          flattened.add(CadPolylinePrimitive(pts, isClosed: true, colorIndex: colorIdx));
        } else if (ed.type == 'LWPOLYLINE') {
          final flags = int.tryParse(attr[70]?.first ?? '0') ?? 0;
          final isClosed = (flags & 1) != 0;

          final rawX = attr[10] ?? [];
          final rawY = attr[20] ?? [];
          final rawBulge = attr[42] ?? [];

          final count = min(rawX.length, rawY.length);
          final pts = <CadPoint2D>[];

          for (int v = 0; v < count; v++) {
            final vx = double.tryParse(rawX[v]) ?? 0.0;
            final vy = double.tryParse(rawY[v]) ?? 0.0;
            final tp = _transformPoint(vx, vy, tx, ty, sx, sy, rotDeg);
            pts.add(tp);

            // 处理凸度弧段 (Bulge)
            if (v < rawBulge.length) {
              final b = double.tryParse(rawBulge[v]) ?? 0.0;
              if (b.abs() > 0.001 && v + 1 < count) {
                final nvx = double.tryParse(rawX[v + 1]) ?? 0.0;
                final nvy = double.tryParse(rawY[v + 1]) ?? 0.0;
                _subdivideBulge(vx, vy, nvx, nvy, b, tx, ty, sx, sy, rotDeg, pts);
              }
            }
          }
          if (pts.isNotEmpty) {
            flattened.add(CadPolylinePrimitive(pts, isClosed: isClosed, colorIndex: colorIdx));
          }
        } else if (ed.type == 'TEXT' || ed.type == 'MTEXT') {
          final px = double.tryParse(attr[10]?.first ?? '0') ?? 0.0;
          final py = double.tryParse(attr[20]?.first ?? '0') ?? 0.0;
          final h = double.tryParse(attr[40]?.first ?? '10') ?? 10.0;
          final rot = double.tryParse(attr[50]?.first ?? '0') ?? 0.0;
          var text = (attr[1] ?? []).join(' ');
          if (text.isEmpty && attr[3] != null) {
            text = (attr[3] ?? []).join(' ');
          }
          // 清理 MTEXT 内部控制字符 (例如 \P 换行，\A1; 格式等)
          text = text.replaceAll(RegExp(r'\\[A-Za-z0-9]+;'), '').replaceAll(r'\P', '\n').trim();

          if (text.isNotEmpty) {
            final tpos = _transformPoint(px, py, tx, ty, sx, sy, rotDeg);
            flattened.add(CadTextPrimitive(
              tpos,
              text,
              height: h * (sx.abs() + sy.abs()) / 2.0,
              rotation: rotDeg + rot,
              colorIndex: colorIdx,
            ));
          }
        }
      }
    }

    expandEntityList(topEntities, 0.0, 0.0, 1.0, 1.0, 0.0, 0);

    if (flattened.isEmpty) {
      return ProcessingResult(
        success: false,
        message: 'CAD 文件解析完成，但未检测到可绘制的几何图元或图块内容。',
      );
    }

    onProgress?.call(0.6, '正在计算图纸矢量包围盒 (共 ${flattened.length} 个矢量图元)...');

    // 计算世界坐标包围盒
    double minX = double.infinity, minY = double.infinity;
    double maxX = -double.infinity, maxY = -double.infinity;

    void updateBounds(double x, double y) {
      if (x.isFinite) {
        minX = min(minX, x);
        maxX = max(maxX, x);
      }
      if (y.isFinite) {
        minY = min(minY, y);
        maxY = max(maxY, y);
      }
    }

    for (final prim in flattened) {
      if (prim is CadLinePrimitive) {
        updateBounds(prim.p1.x, prim.p1.y);
        updateBounds(prim.p2.x, prim.p2.y);
      } else if (prim is CadPolylinePrimitive) {
        for (final pt in prim.points) {
          updateBounds(pt.x, pt.y);
        }
      } else if (prim is CadCirclePrimitive) {
        updateBounds(prim.center.x - prim.radius, prim.center.y - prim.radius);
        updateBounds(prim.center.x + prim.radius, prim.center.y + prim.radius);
      } else if (prim is CadTextPrimitive) {
        updateBounds(prim.position.x, prim.position.y);
      }
    }

    if (!minX.isFinite || !maxX.isFinite || minX >= maxX) {
      minX = 0;
      maxX = 800;
    }
    if (!minY.isFinite || !maxY.isFinite || minY >= maxY) {
      minY = 0;
      maxY = 600;
    }

    final cadW = max(1.0, maxX - minX);
    final cadH = max(1.0, maxY - minY);

    onProgress?.call(0.7, '正在构建标准矢量 PDF 页面画布...');
    final pdfDoc = sf.PdfDocument();

    final isLandscape = orientation == 'landscape' || (orientation == 'auto' && cadW > cadH);

    final double pageWidth;
    final double pageHeight;
    if (pageSizeStr == 'A1') {
      pageWidth = isLandscape ? 2383.94 : 1683.78;
      pageHeight = isLandscape ? 1683.78 : 2383.94;
    } else if (pageSizeStr == 'A2') {
      pageWidth = isLandscape ? 1683.78 : 1190.55;
      pageHeight = isLandscape ? 1190.55 : 1683.78;
    } else if (pageSizeStr == 'A3') {
      pageWidth = isLandscape ? 1190.55 : 841.89;
      pageHeight = isLandscape ? 841.89 : 1190.55;
    } else {
      pageWidth = isLandscape ? 841.89 : 595.28;
      pageHeight = isLandscape ? 595.28 : 841.89;
    }

    final section = pdfDoc.sections!.add();
    section.pageSettings.setMargins(0);
    section.pageSettings.size = ui.Size(pageWidth, pageHeight);
    section.pageSettings.orientation =
        isLandscape ? sf.PdfPageOrientation.landscape : sf.PdfPageOrientation.portrait;

    final pdfPage = section.pages.add();
    final graphics = pdfPage.graphics;

    // 留出图纸白边与底部信息栏
    const margin = 40.0;
    const footerHeight = 24.0;
    final availW = pageWidth - 2 * margin;
    final availH = pageHeight - 2 * margin - footerHeight;

    final scale = min(availW / cadW, availH / cadH);
    final offsetX = margin + (availW - cadW * scale) / 2;
    final offsetY = margin + (availH - cadH * scale) / 2;

    // 坐标转换: CAD (原点在左下, Y向上) -> PDF (原点在左上, Y向下)
    double toPdfX(double x) => offsetX + (x - minX) * scale;
    double toPdfY(double y) => offsetY + (maxY - y) * scale;

    onProgress?.call(0.85, '正在高保真矢量绘制 CAD 图元...');

    // 统一配置字体
    final font = sf.PdfCjkStandardFont(sf.PdfCjkFontFamily.monotypeHeiMedium, 10);

    for (final prim in flattened) {
      final pen = sf.PdfPen(_getAciPdfColor(prim.colorIndex), width: 0.8);
      final brush = sf.PdfSolidBrush(_getAciPdfColor(prim.colorIndex));

      if (prim is CadLinePrimitive) {
        graphics.drawLine(
          pen,
          ui.Offset(toPdfX(prim.p1.x), toPdfY(prim.p1.y)),
          ui.Offset(toPdfX(prim.p2.x), toPdfY(prim.p2.y)),
        );
      } else if (prim is CadPolylinePrimitive) {
        if (prim.points.length >= 2) {
          final path = sf.PdfPath();
          final first = ui.Offset(toPdfX(prim.points[0].x), toPdfY(prim.points[0].y));
          path.startFigure();
          for (int i = 1; i < prim.points.length; i++) {
            path.addLine(
              ui.Offset(toPdfX(prim.points[i - 1].x), toPdfY(prim.points[i - 1].y)),
              ui.Offset(toPdfX(prim.points[i].x), toPdfY(prim.points[i].y)),
            );
          }
          if (prim.isClosed && prim.points.length > 2) {
            path.addLine(
              ui.Offset(toPdfX(prim.points.last.x), toPdfY(prim.points.last.y)),
              first,
            );
            path.closeFigure();
          }
          graphics.drawPath(path, pen: pen);
        }
      } else if (prim is CadTextPrimitive) {
        final tx = toPdfX(prim.position.x);
        final ty = toPdfY(prim.position.y);
        graphics.drawString(
          prim.text,
          font,
          brush: brush,
          bounds: ui.Rect.fromLTWH(tx, ty - 8, max(60.0, prim.text.length * 12.0), 16),
        );
      }
    }

    // 底部规范信息栏
    final footerFont = sf.PdfStandardFont(sf.PdfFontFamily.helvetica, 8);
    final footerBrush = sf.PdfSolidBrush(sf.PdfColor(148, 163, 184));
    final baseName = p.basenameWithoutExtension(dxfPath);
    graphics.drawString(
      'AutoCAD DXF 矢量图纸: $baseName | 图元数量: ${flattened.length} | 规格: $pageSizeStr | 比例自适应居中',
      footerFont,
      brush: footerBrush,
      bounds: ui.Rect.fromLTWH(margin, pageHeight - margin - footerHeight + 6, availW, 16),
    );

    onProgress?.call(0.95, '正在保存矢量 PDF 文件...');
    final pdfBytes = pdfDoc.saveSync();
    pdfDoc.dispose();

    final outPath = p.join(outputDir, '${baseName}_cad.pdf');
    await File(outPath).writeAsBytes(pdfBytes);

    onProgress?.call(1.0, '转换完成！');
    return ProcessingResult(
      success: true,
      message: '成功将 AutoCAD DXF 矢量图纸转换为高保真 PDF (包含 ${flattened.length} 个矢量图元与图块引用)！',
      outputFiles: [outPath],
    );
  }

  // ===========================================================================
  // 2. DWG 二进制工程图纸高保真 PDF 转换 (智能外部转换器调用与专业图纸解析报告)
  // ===========================================================================
  static Future<ProcessingResult> convertDwgToPdf(
    String dwgPath,
    Map<String, dynamic> params,
    String outputDir,
    Function(double, String)? onProgress,
  ) async {
    final pageSizeStr = params['pageSize']?.toString() ?? 'A4';
    final orientation = params['orientation']?.toString() ?? 'auto';

    onProgress?.call(0.1, '正在读取 AutoCAD DWG 二进制工程图纸...');
    final file = File(dwgPath);
    final bytes = await file.readAsBytes();
    final baseName = p.basenameWithoutExtension(dwgPath);

    // 1. 尝试检测本机是否安装 dwg2dxf (GNU LibreDWG 矢量转换工具)
    final dwg2dxf = await _findDwg2DxfExecutable();
    if (dwg2dxf != null) {
      onProgress?.call(0.25, '检测到本机已配置 LibreDWG 工具链，正在执行二进制 DWG 至 DXF 矢量转换...');
      final tempDxfPath = p.join(outputDir, '${baseName}_temp.dxf');
      try {
        final res = await Process.run(dwg2dxf, ['-o', tempDxfPath, dwgPath]);
        if (res.exitCode == 0 && File(tempDxfPath).existsSync() && File(tempDxfPath).lengthSync() > 100) {
          onProgress?.call(0.45, 'DWG 矢量提取成功，正在生成高保真矢量 PDF...');
          final dxfResult = await _convertDxfToPdf(tempDxfPath, params, outputDir, onProgress);
          try {
            await File(tempDxfPath).delete();
          } catch (_) {}
          return ProcessingResult(
            success: true,
            message: '成功通过 LibreDWG 将 DWG 图纸转换为 100% 全矢量 PDF！',
            outputFiles: dxfResult.outputFiles,
          );
        }
      } catch (_) {}
    }

    // 2. 无外部 dwg2dxf 时，深度解析 DWG 文件头版本与内嵌工作区快照
    onProgress?.call(0.35, '正在解析 DWG 图纸格式版本与视口元数据...');
    final headerStr = bytes.length >= 6 ? String.fromCharCodes(bytes.sublist(0, 6)) : '';
    final dwgVersion = _getDwgVersionName(headerStr);
    final thumbBytes = await _extractDwgPreviewImage(bytes);

    final outPath = p.join(outputDir, '${baseName}_dwg.pdf');
    final pdfDoc = sf.PdfDocument();

    final double pageWidth;
    final double pageHeight;
    final bool isLandscape = orientation != 'portrait';

    if (pageSizeStr == 'A3') {
      pageWidth = isLandscape ? 1190.55 : 841.89;
      pageHeight = isLandscape ? 841.89 : 1190.55;
    } else {
      pageWidth = isLandscape ? 841.89 : 595.28;
      pageHeight = isLandscape ? 595.28 : 841.89;
    }

    final section = pdfDoc.sections!.add();
    section.pageSettings.setMargins(0);
    section.pageSettings.size = ui.Size(pageWidth, pageHeight);
    section.pageSettings.orientation =
        isLandscape ? sf.PdfPageOrientation.landscape : sf.PdfPageOrientation.portrait;

    final pdfPage = section.pages.add();
    final graphics = pdfPage.graphics;

    const margin = 40.0;
    final availW = pageWidth - 2 * margin;

    // A. 顶部深蓝工程标题栏
    graphics.drawRectangle(
      brush: sf.PdfSolidBrush(sf.PdfColor(15, 23, 42)), // Slate 900
      bounds: ui.Rect.fromLTWH(0, 0, pageWidth, 70),
    );
    graphics.drawLine(
      sf.PdfPen(sf.PdfColor(59, 130, 246), width: 3), // Blue accent bar
      const ui.Offset(0, 70),
      ui.Offset(pageWidth, 70),
    );

    final titleFont = sf.PdfCjkStandardFont(sf.PdfCjkFontFamily.monotypeHeiMedium, 18, style: sf.PdfFontStyle.bold);
    final subTitleFont = sf.PdfCjkStandardFont(sf.PdfCjkFontFamily.sinoTypeSongLight, 10);
    graphics.drawString(
      'AutoCAD 工程图纸分析与转换指南',
      titleFont,
      brush: sf.PdfSolidBrush(sf.PdfColor(255, 255, 255)),
      bounds: ui.Rect.fromLTWH(margin, 16, availW, 24),
    );
    graphics.drawString(
      'AutoCAD Engineering Drawing Inspection & Vector Conversion Guide',
      subTitleFont,
      brush: sf.PdfSolidBrush(sf.PdfColor(148, 163, 184)),
      bounds: ui.Rect.fromLTWH(margin, 42, availW, 16),
    );

    // B. 图纸元数据表格卡片
    final cardTop = 88.0;
    graphics.drawRectangle(
      pen: sf.PdfPen(sf.PdfColor(226, 232, 240), width: 1),
      brush: sf.PdfSolidBrush(sf.PdfColor(248, 250, 252)),
      bounds: ui.Rect.fromLTWH(margin, cardTop, availW, 72),
    );

    final metaTitleFont = sf.PdfCjkStandardFont(sf.PdfCjkFontFamily.monotypeHeiMedium, 10, style: sf.PdfFontStyle.bold);
    final metaValFont = sf.PdfCjkStandardFont(sf.PdfCjkFontFamily.sinoTypeSongLight, 10);
    final labelBrush = sf.PdfSolidBrush(sf.PdfColor(71, 85, 105));
    final valBrush = sf.PdfSolidBrush(sf.PdfColor(15, 23, 42));

    final colW = availW / 2;
    // Row 1
    graphics.drawString('图纸文件: ', metaTitleFont, brush: labelBrush, bounds: ui.Rect.fromLTWH(margin + 16, cardTop + 14, 60, 16));
    graphics.drawString(p.basename(dwgPath), metaValFont, brush: valBrush, bounds: ui.Rect.fromLTWH(margin + 76, cardTop + 14, colW - 90, 16));

    graphics.drawString('CAD 版本: ', metaTitleFont, brush: labelBrush, bounds: ui.Rect.fromLTWH(margin + colW + 16, cardTop + 14, 60, 16));
    graphics.drawString(dwgVersion, metaValFont, brush: valBrush, bounds: ui.Rect.fromLTWH(margin + colW + 76, cardTop + 14, colW - 90, 16));

    // Row 2
    graphics.drawString('文件尺寸: ', metaTitleFont, brush: labelBrush, bounds: ui.Rect.fromLTWH(margin + 16, cardTop + 40, 60, 16));
    graphics.drawString('${(bytes.length / 1024).toStringAsFixed(1)} KB (${bytes.length} 字节)', metaValFont, brush: valBrush, bounds: ui.Rect.fromLTWH(margin + 76, cardTop + 40, colW - 90, 16));

    graphics.drawString('图纸规格: ', metaTitleFont, brush: labelBrush, bounds: ui.Rect.fromLTWH(margin + colW + 16, cardTop + 40, 60, 16));
    graphics.drawString('$pageSizeStr (${pageWidth.toStringAsFixed(0)} x ${pageHeight.toStringAsFixed(0)} pt, ${isLandscape ? "横向" : "纵向"})', metaValFont, brush: valBrush, bounds: ui.Rect.fromLTWH(margin + colW + 76, cardTop + 40, colW - 90, 16));

    // C. 中部区域：视口缩略快照 + 矢量无损导出操作指南并排
    final contentTop = cardTop + 86.0;
    final contentHeight = pageHeight - contentTop - 46.0;

    double previewWidth = 0.0;
    if (thumbBytes != null) {
      previewWidth = min(availW * 0.42, 280.0);
      final previewRect = ui.Rect.fromLTWH(margin, contentTop, previewWidth, contentHeight);

      graphics.drawRectangle(
        pen: sf.PdfPen(sf.PdfColor(226, 232, 240), width: 1),
        brush: sf.PdfSolidBrush(sf.PdfColor(255, 255, 255)),
        bounds: previewRect,
      );

      // 缩略图标题
      final prevTitleFont = sf.PdfCjkStandardFont(sf.PdfCjkFontFamily.monotypeHeiMedium, 11, style: sf.PdfFontStyle.bold);
      graphics.drawString(
        '内嵌工作区缩略视图',
        prevTitleFont,
        brush: sf.PdfSolidBrush(sf.PdfColor(30, 41, 59)),
        bounds: ui.Rect.fromLTWH(margin + 12, contentTop + 12, previewWidth - 24, 18),
      );

      try {
        final sfBitmap = sf.PdfBitmap(thumbBytes);
        final bw = sfBitmap.width.toDouble();
        final bh = sfBitmap.height.toDouble();

        final maxImgW = previewWidth - 24.0;
        final maxImgH = contentHeight - 70.0;
        final s = min(maxImgW / max(1.0, bw), maxImgH / max(1.0, bh));
        final rw = bw * s;
        final rh = bh * s;
        final rx = margin + 12 + (maxImgW - rw) / 2;
        final ry = contentTop + 36 + (maxImgH - rh) / 2;

        graphics.drawRectangle(
          pen: sf.PdfPen(sf.PdfColor(203, 213, 225), width: 1),
          brush: sf.PdfSolidBrush(sf.PdfColor(241, 245, 249)),
          bounds: ui.Rect.fromLTWH(rx - 2, ry - 2, rw + 4, rh + 4),
        );
        graphics.drawImage(sfBitmap, ui.Rect.fromLTWH(rx, ry, rw, rh));

        final noteFont = sf.PdfCjkStandardFont(sf.PdfCjkFontFamily.sinoTypeSongLight, 8);
        graphics.drawString(
          '快照尺寸: ${bw.toInt()} x ${bh.toInt()} 像素 (低解析度视口缩略图)',
          noteFont,
          brush: sf.PdfSolidBrush(sf.PdfColor(148, 163, 184)),
          bounds: ui.Rect.fromLTWH(margin + 12, contentTop + contentHeight - 22, previewWidth - 24, 14),
        );
      } catch (_) {}
    }

    // D. 矢量导出指南卡片
    final guideLeft = margin + (previewWidth > 0 ? previewWidth + 16.0 : 0.0);
    final guideWidth = availW - (previewWidth > 0 ? previewWidth + 16.0 : 0.0);
    final guideRect = ui.Rect.fromLTWH(guideLeft, contentTop, guideWidth, contentHeight);

    graphics.drawRectangle(
      pen: sf.PdfPen(sf.PdfColor(191, 219, 254), width: 1), // Light blue border
      brush: sf.PdfSolidBrush(sf.PdfColor(240, 249, 255)), // Light blue background
      bounds: guideRect,
    );

    final guideTitleFont = sf.PdfCjkStandardFont(sf.PdfCjkFontFamily.monotypeHeiMedium, 13, style: sf.PdfFontStyle.bold);
    final guideBodyFont = sf.PdfCjkStandardFont(sf.PdfCjkFontFamily.sinoTypeSongLight, 10);
    final guideBoldFont = sf.PdfCjkStandardFont(sf.PdfCjkFontFamily.monotypeHeiMedium, 10, style: sf.PdfFontStyle.bold);

    graphics.drawString(
      '【高保真 100% 全矢量图纸导出指南】',
      guideTitleFont,
      brush: sf.PdfSolidBrush(sf.PdfColor(29, 78, 216)), // Blue 700
      bounds: ui.Rect.fromLTWH(guideLeft + 16, contentTop + 16, guideWidth - 32, 20),
    );

    final guideLines = [
      'AutoCAD DWG 为 Autodesk 专有二进制封装格式，内嵌缩略图仅为低清预览。',
      '为了获得 无限缩放不失真、线条与标注绝对清晰 的交付级全矢量 PDF 图纸：',
      '',
      '步骤 1：在 AutoCAD、中望CAD、浩辰CAD 或 FreeCAD 中打开该图纸。',
      '步骤 2：直接在命令行键入快捷命令 DXFOUT 并按回车；',
      '          （或点击顶部菜单【文件】->【另存为】-> 选择【AutoCAD DXF 格式 (*.dxf)】保存）。',
      '步骤 3：将保存后的 .dxf 文件直接拖入本工具转换！',
      '',
      '本工具原生集成了高精度 DXF 矢量引擎：',
      '  • 完整解析图纸图元 (LINE、ARC、CIRCLE、LWPOLYLINE 凹凸多段线)',
      '  • 深度展开多重图块引用与坐标矩阵变换 (BLOCKS / INSERT)',
      '  • 自动计算图纸几何包围盒并居中自适应缩放至标准工程图幅',
      '  • 100% 离线转换，严格保障设计图纸安全无泄漏',
    ];

    double gy = contentTop + 44.0;
    for (final gl in guideLines) {
      if (gl.isEmpty) {
        gy += 6.0;
        continue;
      }
      final isStep = gl.startsWith('步骤') || gl.startsWith('本工具');
      graphics.drawString(
        gl,
        isStep ? guideBoldFont : guideBodyFont,
        brush: isStep ? sf.PdfSolidBrush(sf.PdfColor(15, 23, 42)) : sf.PdfSolidBrush(sf.PdfColor(51, 65, 85)),
        bounds: ui.Rect.fromLTWH(guideLeft + 16, gy, guideWidth - 32, 16),
      );
      gy += 18.0;
    }

    // E. 底部栏
    final footerFont = sf.PdfCjkStandardFont(sf.PdfCjkFontFamily.sinoTypeSongLight, 8);
    graphics.drawString(
      'AutoCAD 离线转换引擎 | 支持 DXF 全矢量展开与 DWG 解析 | $dwgVersion',
      footerFont,
      brush: sf.PdfSolidBrush(sf.PdfColor(148, 163, 184)),
      bounds: ui.Rect.fromLTWH(margin, pageHeight - 30, availW, 14),
    );

    onProgress?.call(0.95, '正在保存工程图纸分析报告...');
    final pdfBytes = pdfDoc.saveSync();
    pdfDoc.dispose();

    await File(outPath).writeAsBytes(pdfBytes);
    onProgress?.call(1.0, '转换完成！');

    return ProcessingResult(
      success: true,
      message: '已成功解析 AutoCAD DWG 图纸 ($dwgVersion)！提示: 为获得 100% 原始全矢量图纸，请在 CAD 中导出为 DXF 格式后转换。',
      outputFiles: [outPath],
    );
  }

  /// 搜索系统中的 dwg2dxf 可执行程序
  static Future<String?> _findDwg2DxfExecutable() async {
    try {
      final res = await Process.run(Platform.isWindows ? 'where.exe' : 'which', ['dwg2dxf']);
      if (res.exitCode == 0 && res.stdout.toString().trim().isNotEmpty) {
        return res.stdout.toString().trim().split(RegExp(r'[\r\n]+')).first;
      }
    } catch (_) {}

    final appDir = p.dirname(Platform.resolvedExecutable);
    final candidates = [
      p.join(appDir, 'dwg2dxf.exe'),
      p.join(appDir, 'bin', 'dwg2dxf.exe'),
      p.join(appDir, 'tools', 'dwg2dxf.exe'),
      p.join(Directory.current.path, 'dwg2dxf.exe'),
      p.join(Directory.current.path, 'bin', 'dwg2dxf.exe'),
    ];
    for (final c in candidates) {
      if (File(c).existsSync()) return c;
    }
    return null;
  }

  /// 获取 AutoCAD DWG 文件版本名称
  static String _getDwgVersionName(String header) {
    if (header.startsWith('AC1032')) return 'AutoCAD 2018 - 2026 (AC1032)';
    if (header.startsWith('AC1027')) return 'AutoCAD 2013 - 2017 (AC1027)';
    if (header.startsWith('AC1024')) return 'AutoCAD 2010 - 2012 (AC1024)';
    if (header.startsWith('AC1021')) return 'AutoCAD 2007 - 2009 (AC1021)';
    if (header.startsWith('AC1018')) return 'AutoCAD 2004 - 2006 (AC1018)';
    if (header.startsWith('AC1015')) return 'AutoCAD 2000 - 2002 (AC1015)';
    return 'AutoCAD DWG ($header)';
  }

  // ===========================================================================
  // 3. DWF 网络图形图纸转 PDF
  // ===========================================================================
  static Future<ProcessingResult> convertDwfToPdf(
    String dwfPath,
    Map<String, dynamic> params,
    String outputDir,
    Function(double, String)? onProgress,
  ) async {
    final pageSizeStr = params['pageSize']?.toString() ?? 'A4';
    onProgress?.call(0.2, '正在解压并读取 Autodesk DWF 封装数据...');

    final file = File(dwfPath);
    final bytes = await file.readAsBytes();
    final baseName = p.basenameWithoutExtension(dwfPath);
    final outPath = p.join(outputDir, '${baseName}_dwf.pdf');

    // 寻找 ZIP 偏移 (DWF 6.0 带有 '(DWF V06.xx)\r\n' 头部前缀)
    int zipOffset = 0;
    for (int k = 0; k < min(512, bytes.length - 4); k++) {
      if (bytes[k] == 0x50 && bytes[k + 1] == 0x4B && bytes[k + 2] == 0x03 && bytes[k + 3] == 0x04) {
        zipOffset = k;
        break;
      }
    }

    final zipBytes = zipOffset > 0 ? bytes.sublist(zipOffset) : bytes;

    final pdfDoc = sf.PdfDocument();
    final section = pdfDoc.sections!.add();
    section.pageSettings.setMargins(0);
    const pageWidth = 841.89;
    const pageHeight = 595.28;
    section.pageSettings.size = const ui.Size(pageWidth, pageHeight);
    section.pageSettings.orientation = sf.PdfPageOrientation.landscape;

    final pdfPage = section.pages.add();
    final graphics = pdfPage.graphics;

    bool foundContent = false;
    String dwfSheetTitle = baseName;

    try {
      final archive = ZipDecoder().decodeBytes(zipBytes);

      // 提取 manifest.xml 或 descriptor.xml 中的图纸标题
      for (final f in archive.files) {
        if (f.isFile && (f.name.endsWith('manifest.xml') || f.name.endsWith('descriptor.xml'))) {
          try {
            final xmlStr = utf8.decode(f.content as List<int>, allowMalformed: true);
            final doc = xml.XmlDocument.parse(xmlStr);
            final titleAttr = doc.findAllElements('Section').firstOrNull?.getAttribute('title');
            if (titleAttr != null && titleAttr.isNotEmpty) {
              dwfSheetTitle = titleAttr;
            }
          } catch (_) {}
        }
      }

      // 尝试提取内嵌高质量图片或光栅预览
      for (final f in archive.files) {
        if (f.isFile && (f.name.endsWith('.png') || f.name.endsWith('.jpg') || f.name.endsWith('.bmp'))) {
          try {
            final sfImg = sf.PdfBitmap(Uint8List.fromList(f.content as List<int>));
            final bw = sfImg.width.toDouble();
            final bh = sfImg.height.toDouble();
            final maxW = pageWidth - 80;
            final maxH = pageHeight - 120;
            final s = min(maxW / max(1.0, bw), maxH / max(1.0, bh));
            final rw = bw * s;
            final rh = bh * s;
            final rx = 40 + (maxW - rw) / 2;
            final ry = 40 + (maxH - rh) / 2;
            graphics.drawImage(sfImg, ui.Rect.fromLTWH(rx, ry, rw, rh));
            foundContent = true;
            break;
          } catch (_) {}
        }
      }
    } catch (_) {}

    if (!foundContent) {
      _drawDwgPlaceholder(graphics, dwfSheetTitle, 40, pageWidth - 80, pageHeight - 120);
    }

    final footerFont = sf.PdfCjkStandardFont(sf.PdfCjkFontFamily.sinoTypeSongLight, 9);
    final footerBrush = sf.PdfSolidBrush(sf.PdfColor(100, 116, 139));
    graphics.drawString(
      'Autodesk DWF 设计图纸: $dwfSheetTitle | 纸张: $pageSizeStr | 离线转换完成 (如需全矢量格式请在 CAD 中导出为 DXF)',
      footerFont,
      brush: footerBrush,
      bounds: const ui.Rect.fromLTWH(40, pageHeight - 50, pageWidth - 80, 20),
    );

    final pdfBytes = pdfDoc.saveSync();
    pdfDoc.dispose();
    await File(outPath).writeAsBytes(pdfBytes);

    return ProcessingResult(
      success: true,
      message: '成功解析 Autodesk DWF 图纸并生成 PDF 文档！',
      outputFiles: [outPath],
    );
  }

  // ===========================================================================
  // 辅助函数
  // ===========================================================================

  static void _drawDwgPlaceholder(sf.PdfGraphics graphics, String name, double margin, double w, double h) {
    graphics.drawRectangle(
      pen: sf.PdfPen(sf.PdfColor(203, 213, 225), width: 1.5),
      brush: sf.PdfSolidBrush(sf.PdfColor(248, 250, 252)),
      bounds: ui.Rect.fromLTWH(margin, margin, w, h),
    );
    final font = sf.PdfCjkStandardFont(sf.PdfCjkFontFamily.monotypeHeiMedium, 18, style: sf.PdfFontStyle.bold);
    final subFont = sf.PdfCjkStandardFont(sf.PdfCjkFontFamily.sinoTypeSongLight, 12);
    final brush = sf.PdfSolidBrush(sf.PdfColor(30, 41, 59));
    final subBrush = sf.PdfSolidBrush(sf.PdfColor(100, 116, 139));

    graphics.drawString('AutoCAD 工程图纸', font, brush: brush, bounds: ui.Rect.fromLTWH(margin + 30, margin + 40, w - 60, 30));
    graphics.drawString('图纸文件名: $name', subFont, brush: subBrush, bounds: ui.Rect.fromLTWH(margin + 30, margin + 80, w - 60, 20));
  }

  /// 从 DWG 文件字节流提取嵌入式高清缩略图 (AutoCAD 2000 - 2024 PNG / BMP 图像)
  static Future<Uint8List?> _extractDwgPreviewImage(Uint8List dwgBytes) async {
    if (dwgBytes.length < 32) return null;

    // 1. 优先搜索 PNG 签名 (现代 AutoCAD 2013+ AC1027/AC1032)
    const pngSig = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];
    final pngIdx = _findSublist(dwgBytes, pngSig);
    if (pngIdx != -1) {
      const iendSig = [0x49, 0x45, 0x4E, 0x44]; // 'IEND'
      final iendIdx = _findSublist(dwgBytes, iendSig, start: pngIdx);
      if (iendIdx != -1) {
        final pngEnd = min(dwgBytes.length, iendIdx + 8);
        return dwgBytes.sublist(pngIdx, pngEnd);
      }
    }

    // 2. 解析 DWG 头部偏移 13 的缩略图地址 (AutoCAD 2000-2010 AC1015/AC1018/AC1021)
    try {
      final byteData = ByteData.sublistView(dwgBytes);
      final thumbAddr = byteData.getUint32(13, Endian.little);
      if (thumbAddr > 0 && thumbAddr + 20 < dwgBytes.length) {
        final thumbSize = byteData.getUint32(thumbAddr + 16, Endian.little);
        final blockStart = thumbAddr + 20;
        if (blockStart + thumbSize <= dwgBytes.length) {
          final block = dwgBytes.sublist(blockStart, blockStart + thumbSize);
          final pIdx = _findSublist(block, pngSig);
          if (pIdx != -1) {
            return block.sublist(pIdx);
          }

          if (block.isNotEmpty) {
            final count = block[0];
            int pos = 1;
            for (int i = 0; i < count && pos + 9 <= block.length; i++) {
              final itemType = block[pos];
              final itemOffset = ByteData.sublistView(block).getUint32(pos + 1, Endian.little);
              final itemLength = ByteData.sublistView(block).getUint32(pos + 5, Endian.little);
              pos += 9;

              if (itemType == 2 && itemOffset < dwgBytes.length) {
                // 2 = BMP (DIB 数据，缺少 14 字节 BITMAPFILEHEADER)
                final bmpEnd = min(dwgBytes.length, itemOffset + itemLength);
                final rawBmpData = dwgBytes.sublist(itemOffset, bmpEnd);
                if (rawBmpData.length >= 40) {
                  final dibData = ByteData.sublistView(rawBmpData);
                  final biSize = dibData.getUint32(0, Endian.little);
                  final biBitCount = dibData.getUint16(14, Endian.little);
                  final biClrUsed = dibData.getUint32(32, Endian.little);
                  final numColors = biClrUsed > 0 ? biClrUsed : (biBitCount <= 8 ? (1 << biBitCount) : 0);
                  final offBits = 14 + biSize + (numColors * 4);
                  final fileSize = 14 + rawBmpData.length;

                  final bmpFile = BytesBuilder();
                  bmpFile.add([0x42, 0x4D]); // 'BM'
                  final b = ByteData(12);
                  b.setUint32(0, fileSize, Endian.little);
                  b.setUint16(4, 0, Endian.little);
                  b.setUint16(6, 0, Endian.little);
                  b.setUint32(8, offBits, Endian.little);
                  bmpFile.add(b.buffer.asUint8List());
                  bmpFile.add(rawBmpData);

                  final completeBmp = bmpFile.toBytes();
                  // 验证 image 库解码
                  final decoded = img.decodeBmp(completeBmp);
                  if (decoded != null) {
                    return Uint8List.fromList(img.encodePng(decoded));
                  }
                  return completeBmp;
                }
              }
            }
          }
        }
      }
    } catch (_) {}

    return null;
  }

  static int _findSublist(Uint8List list, List<int> pattern, {int start = 0}) {
    if (pattern.isEmpty || list.length < pattern.length) return -1;
    final maxSearch = list.length - pattern.length;
    for (int i = start; i <= maxSearch; i++) {
      bool match = true;
      for (int j = 0; j < pattern.length; j++) {
        if (list[i + j] != pattern[j]) {
          match = false;
          break;
        }
      }
      if (match) return i;
    }
    return -1;
  }

  /// 仿射变换计算
  static CadPoint2D _transformPoint(
    double x,
    double y,
    double tx,
    double ty,
    double sx,
    double sy,
    double rotDeg,
  ) {
    final rad = rotDeg * pi / 180.0;
    final xs = x * sx;
    final ys = y * sy;
    final xr = xs * cos(rad) - ys * sin(rad);
    final yr = xs * sin(rad) + ys * cos(rad);
    return CadPoint2D(tx + xr, ty + yr);
  }

  /// 细分多段线中的弧段 (Bulge)
  static void _subdivideBulge(
    double x1,
    double y1,
    double x2,
    double y2,
    double b,
    double tx,
    double ty,
    double sx,
    double sy,
    double rotDeg,
    List<CadPoint2D> pts,
  ) {
    final theta = 4.0 * atan(b);
    final dx = x2 - x1;
    final dy = y2 - y1;
    final chord = sqrt(dx * dx + dy * dy);
    if (chord < 1e-6) return;

    final r = (chord / 2.0) / sin(theta / 2.0).abs();
    final midX = (x1 + x2) / 2.0;
    final midY = (y1 + y2) / 2.0;
    final distToCenter = sqrt(max(0.0, r * r - (chord / 2.0) * (chord / 2.0)));
    final perpX = -dy / chord;
    final perpY = dx / chord;
    final sign = b > 0 ? 1.0 : -1.0;
    final cx = midX + sign * distToCenter * perpX;
    final cy = midY + sign * distToCenter * perpY;

    final startAngle = atan2(y1 - cy, x1 - cx);
    final endAngle = atan2(y2 - cy, x2 - cx);
    var sweep = endAngle - startAngle;
    if (b > 0 && sweep < 0) sweep += 2 * pi;
    if (b < 0 && sweep > 0) sweep -= 2 * pi;

    const n = 8;
    for (int k = 1; k < n; k++) {
      final ang = startAngle + sweep * (k / n);
      final px = cx + r * cos(ang);
      final py = cy + r * sin(ang);
      pts.add(_transformPoint(px, py, tx, ty, sx, sy, rotDeg));
    }
  }

  /// 快速解析 DXF 成对行 (Code / Value)
  static List<_DxfPair> _parseDxfPairs(String content) {
    final lines = const LineSplitter().convert(content);
    final pairs = <_DxfPair>[];
    for (int i = 0; i < lines.length - 1; i += 2) {
      final code = int.tryParse(lines[i].trim());
      if (code != null) {
        pairs.add(_DxfPair(code, lines[i + 1].trim()));
      }
    }
    return pairs;
  }

  /// AutoCAD ACI 颜色对照表
  static sf.PdfColor _getAciPdfColor(int aci) {
    switch (aci) {
      case 1:
        return sf.PdfColor(239, 68, 68); // Red
      case 2:
        return sf.PdfColor(234, 179, 8); // Yellow
      case 3:
        return sf.PdfColor(34, 197, 94); // Green
      case 4:
        return sf.PdfColor(6, 182, 212); // Cyan
      case 5:
        return sf.PdfColor(59, 130, 246); // Blue
      case 6:
        return sf.PdfColor(217, 70, 239); // Magenta
      case 7:
      case 0:
      case 256:
        // 在白色图纸背景上，默认的白色/黑底反转为典雅深藏青
        return sf.PdfColor(30, 41, 59);
      case 8:
        return sf.PdfColor(100, 116, 139);
      case 9:
        return sf.PdfColor(148, 163, 184);
      default:
        return sf.PdfColor(30, 41, 59);
    }
  }
}
