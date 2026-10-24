import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import '../models/plugin_manifest.dart';

/// 功能模块图标组件
/// 支持：
/// 1. 图片格式 (Base64 / 本地文件路径 / 网络URL)，严格限制像素分辨率与文件字节大小，超限自动安全降级；
/// 2. 代码渲染格式 (SVG 矢量代码字符串)；
/// 3. 系统/Material 关键词图标映射；
/// 4. 任意缺失、超限、格式不合规或加载失败均统一安全降级为客户端默认功能模块图标 (Icons.extension_rounded)。
class PluginIconWidget extends StatefulWidget {
  final PluginManifest? manifest;
  final PluginIconDef? iconDef;
  final String? fallbackIcon;
  final String? localDir;
  final double size;
  final Color? color;

  const PluginIconWidget({
    super.key,
    this.manifest,
    this.iconDef,
    this.fallbackIcon,
    this.localDir,
    this.size = 20,
    this.color,
  });

  /// 客户端官方默认功能模块图标组件
  static Widget buildDefaultModuleIcon(
    BuildContext context, {
    double size = 20,
    Color? color,
  }) {
    final effectiveColor = color ?? Theme.of(context).colorScheme.primary;
    return Icon(
      Icons.extension_rounded,
      size: size,
      color: effectiveColor,
    );
  }

  /// Material 图标名称映射字典
  static IconData getMaterialIconData(String? name) {
    if (name == null || name.trim().isEmpty) {
      return Icons.extension_rounded;
    }
    final key = name.trim().toLowerCase();
    switch (key) {
      case 'compress':
        return Icons.compress;
      case 'aspect_ratio':
        return Icons.aspect_ratio;
      case 'badge':
        return Icons.badge;
      case 'movie':
      case 'video':
        return Icons.movie_creation_outlined;
      case 'qr_code':
      case 'qrcode':
        return Icons.qr_code_2_rounded;
      case 'download':
        return Icons.download_for_offline_outlined;
      case 'gif':
        return Icons.gif_box_outlined;
      case 'motion_photo':
      case 'live_photo':
        return Icons.motion_photos_on_outlined;
      case 'pdf':
        return Icons.picture_as_pdf_outlined;
      case 'doc_converter':
      case 'transform':
      case 'watermark':
      case 'banana':
        return Icons.transform_outlined;
      case 'folder_zip':
      case 'zip':
      case 'archive':
      case '7z':
      case 'rar':
        return Icons.folder_zip_outlined;
      case 'code':
      case 'terminal':
      case 'script':
      case 'quickjs':
      case 'js':
        return Icons.code_rounded;
      case 'memory':
      case 'wasm':
      case 'cpu':
        return Icons.memory_rounded;
      case 'image':
      case 'photo':
        return Icons.image_outlined;
      case 'text':
      case 'font':
        return Icons.text_fields_rounded;
      default:
        return Icons.extension_rounded;
    }
  }

  @override
  State<PluginIconWidget> createState() => _PluginIconWidgetState();
}

class _PluginIconWidgetState extends State<PluginIconWidget> {
  // 静态内存校验缓存，避免列表滚动时重复解析与验证
  static final Map<String, Uint8List?> _validatedBytesCache = {};

  Uint8List? _imageBytes;
  bool _isValidating = false;
  bool _validationFailed = false;

  PluginIconDef get _effectiveDef {
    if (widget.iconDef != null) return widget.iconDef!;
    if (widget.manifest != null) return widget.manifest!.effectiveIconDef;
    return PluginIconDef.fromRaw(widget.fallbackIcon ?? 'extension');
  }

  String? get _effectiveLocalDir {
    return widget.localDir ?? widget.manifest?.localDir;
  }

  @override
  void initState() {
    super.initState();
    _checkAndLoadIcon();
  }

  @override
  void didUpdateWidget(PluginIconWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.iconDef != widget.iconDef ||
        oldWidget.manifest != widget.manifest ||
        oldWidget.fallbackIcon != widget.fallbackIcon ||
        oldWidget.localDir != widget.localDir) {
      _checkAndLoadIcon();
    }
  }

  void _checkAndLoadIcon() {
    final def = _effectiveDef;
    if (!def.isImage || def.data == null || def.data!.trim().isEmpty) {
      _imageBytes = null;
      _isValidating = false;
      _validationFailed = false;
      return;
    }

    final rawData = def.data!.trim();
    if (_validatedBytesCache.containsKey(rawData)) {
      final cached = _validatedBytesCache[rawData];
      setState(() {
        _imageBytes = cached;
        _validationFailed = (cached == null);
        _isValidating = false;
      });
      return;
    }

    setState(() {
      _isValidating = true;
      _validationFailed = false;
    });

    _validateAndDecodeImage(rawData, def, _effectiveLocalDir).then((bytes) {
      if (!mounted) return;
      _validatedBytesCache[rawData] = bytes;
      setState(() {
        _imageBytes = bytes;
        _validationFailed = (bytes == null);
        _isValidating = false;
      });
    }).catchError((_) {
      if (!mounted) return;
      _validatedBytesCache[rawData] = null;
      setState(() {
        _imageBytes = null;
        _validationFailed = true;
        _isValidating = false;
      });
    });
  }

  /// 验证图片大小与像素尺寸，完全符合规范返回合法字节，否则返回 null
  static Future<Uint8List?> _validateAndDecodeImage(String rawData, PluginIconDef def, [String? localDir]) async {
    try {
      Uint8List? rawBytes;

      // 1. Base64 格式
      if (rawData.startsWith('data:image/') || (!rawData.contains('/') && !rawData.contains('\\') && rawData.length > 50)) {
        String cleanBase64 = rawData;
        final commaIdx = rawData.indexOf(',');
        if (commaIdx != -1) {
          cleanBase64 = rawData.substring(commaIdx + 1);
        }
        cleanBase64 = cleanBase64.replaceAll(RegExp(r'\s+'), '');
        
        // 估算大小避免超大内存分配
        final estimatedSize = (cleanBase64.length * 3) ~/ 4;
        if (estimatedSize > def.maxSizeBytes) {
          return null; // 超出大小限制，安全降级
        }

        rawBytes = base64Decode(cleanBase64);
      } else if (rawData.startsWith('http://') || rawData.startsWith('https://')) {
        // 网络图片不建议直接作为离线模块图标，若提供则尝试加载（最大下载限制）
        final client = HttpClient()..connectionTimeout = const Duration(seconds: 3);
        try {
          final req = await client.getUrl(Uri.parse(rawData));
          final res = await req.close();
          if (res.statusCode == 200) {
            final contentLength = res.contentLength;
            if (contentLength > def.maxSizeBytes) {
              client.close(force: true);
              return null;
            }
            final bytes = <int>[];
            await for (final chunk in res) {
              bytes.addAll(chunk);
              if (bytes.length > def.maxSizeBytes) {
                client.close(force: true);
                return null;
              }
            }
            rawBytes = Uint8List.fromList(bytes);
          }
        } finally {
          client.close(force: true);
        }
      } else {
        // 本地文件路径
        String filePath = rawData;
        if (!File(filePath).isAbsolute) {
          if (localDir != null && localDir.isNotEmpty) {
            final joined = p.join(localDir, rawData);
            if (File(joined).existsSync()) {
              filePath = joined;
            }
          }
        }
        final file = File(filePath);
        if (file.existsSync()) {
          final size = file.lengthSync();
          if (size > def.maxSizeBytes) {
            return null; // 超出大小限制，安全降级
          }
          rawBytes = await file.readAsBytes();
        }
      }

      if (rawBytes == null || rawBytes.isEmpty) {
        return null;
      }

      // 检查实际字节大小
      if (rawBytes.lengthInBytes > def.maxSizeBytes) {
        return null;
      }

      // 检查图片像素分辨率 (限制像素)
      final decoded = img.decodeImage(rawBytes);
      if (decoded == null) {
        return null; // 无法解析的损坏或未知图片格式
      }

      if (decoded.width > def.maxPixels || decoded.height > def.maxPixels) {
        return null; // 超出像素分辨率限制，安全降级
      }

      return rawBytes;
    } catch (_) {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final def = _effectiveDef;
    final primaryColor = widget.color ?? Theme.of(context).colorScheme.primary;

    // 1. 图片模式
    if (def.isImage) {
      if (_isValidating) {
        return SizedBox(
          width: widget.size,
          height: widget.size,
          child: PluginIconWidget.buildDefaultModuleIcon(context, size: widget.size, color: primaryColor),
        );
      }
      if (_imageBytes != null && !_validationFailed) {
        return ClipRRect(
          borderRadius: BorderRadius.circular(widget.size * 0.22),
          child: Image.memory(
            _imageBytes!,
            width: widget.size,
            height: widget.size,
            fit: BoxFit.contain,
            errorBuilder: (ctx, err, stack) =>
                PluginIconWidget.buildDefaultModuleIcon(context, size: widget.size, color: primaryColor),
          ),
        );
      }
      // 不符合要求或加载失败：降级为客户端默认功能模块图标
      return PluginIconWidget.buildDefaultModuleIcon(context, size: widget.size, color: primaryColor);
    }

    // 2. 代码渲染模式 (SVG 矢量代码)
    if (def.isCode && def.data != null && def.data!.trim().isNotEmpty) {
      final svgData = def.data!.trim();
      // 限制代码大小不超过 64KB
      if (svgData.length <= 64 * 1024) {
        try {
          return SizedBox(
            width: widget.size,
            height: widget.size,
            child: SvgPicture.string(
              svgData,
              width: widget.size,
              height: widget.size,
              fit: BoxFit.contain,
              placeholderBuilder: (ctx) =>
                  PluginIconWidget.buildDefaultModuleIcon(context, size: widget.size, color: primaryColor),
            ),
          );
        } catch (_) {
          return PluginIconWidget.buildDefaultModuleIcon(context, size: widget.size, color: primaryColor);
        }
      } else {
        return PluginIconWidget.buildDefaultModuleIcon(context, size: widget.size, color: primaryColor);
      }
    }

    // 3. 系统/Material 关键词图标模式
    if (def.isMaterial && def.data != null && def.data!.trim().isNotEmpty) {
      final iconData = PluginIconWidget.getMaterialIconData(def.data);
      return Icon(
        iconData,
        size: widget.size,
        color: primaryColor,
      );
    }

    // 4. 兜底降级：客户端默认功能模块图标
    return PluginIconWidget.buildDefaultModuleIcon(context, size: widget.size, color: primaryColor);
  }
}
