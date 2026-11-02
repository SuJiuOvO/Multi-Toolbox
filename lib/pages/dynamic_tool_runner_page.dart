import 'dart:convert';
import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:open_filex/open_filex.dart';
import '../models/plugin_manifest.dart';
import '../widgets/plugin_icon_widget.dart';
import '../services/tool_engine_service.dart';
import '../services/background_task_runner.dart';
import '../services/media_engine_service.dart';
import '../services/windows_extension_runner_service.dart';
import '../services/quickjs_bridge_service.dart';
import '../services/android_office_bridge.dart';
import '../services/notification_service.dart';
import '../services/settings_service.dart';
import '../services/storage_permission_service.dart';
import 'terminal_log_viewer.dart';

enum PluginExecutionEngine {
  windowsNative,
  quickJs,
  wasmUniversal,
  internalHandler,
}

class DynamicToolRunnerPage extends StatefulWidget {
  /// 智能解析在当前平台下所使用的执行引擎 (支持双端自适应插件在 Windows 调度原生、在 Android 调度 WASM)
  @visibleForTesting
  static PluginExecutionEngine resolveExecutionEngine({
    required PluginManifest plugin,
    required bool isWindows,
  }) {
    if (isWindows && (plugin.isWindowsExtension || plugin.nativeRunner != null)) {
      return PluginExecutionEngine.windowsNative;
    } else if (plugin.isQuickJsPlugin) {
      return PluginExecutionEngine.quickJs;
    } else if (plugin.isWasmPlugin) {
      return PluginExecutionEngine.wasmUniversal;
    } else if (plugin.isWindowsExtension || plugin.nativeRunner != null) {
      return PluginExecutionEngine.windowsNative;
    } else {
      return PluginExecutionEngine.internalHandler;
    }
  }

  final PluginManifest plugin;

  const DynamicToolRunnerPage({super.key, required this.plugin});

  /// 将用户选择的输入项（可能包含文件路径与文件夹路径）转换为扁平化的有效文件列表。
  ///
  /// - [rawEntries]: 用户选择的文件或文件夹路径列表
  /// - [allowedExtensions]: 允许的文件扩展名列表（若为空则不限类型）
  /// - [isArchiveCompress]: 是否为归档压缩模式（若为 true，则保留文件夹路径以便归档引擎维护目录层级）
  static List<String> flattenInputEntries({
    required List<String> rawEntries,
    List<String> allowedExtensions = const [],
    bool isArchiveCompress = false,
  }) {
    final effective = <String>[];
    final seenPaths = <String>{};
    final allowedExts = allowedExtensions
        .map((e) => e.toLowerCase().replaceFirst(RegExp(r'^\.'), ''))
        .where((e) => e.isNotEmpty)
        .toSet();

    String normalizeKey(String path) {
      final canonical = p.canonicalize(path);
      return Platform.isWindows ? canonical.toLowerCase() : canonical;
    }

    for (final item in rawEntries) {
      if (item.trim().isEmpty) continue;
      final d = Directory(item);
      if (!isArchiveCompress && d.existsSync()) {
        try {
          final dirFiles = d
              .listSync(recursive: true, followLinks: false)
              .whereType<File>()
              .map((f) => f.path)
              .where((filePath) {
                final base = p.basename(filePath);
                if (base.startsWith('.') ||
                    base.toLowerCase() == 'thumbs.db' ||
                    base.toLowerCase() == 'desktop.ini') {
                  return false;
                }
                if (allowedExts.isEmpty) return true;
                final ext = p.extension(filePath).toLowerCase().replaceFirst(RegExp(r'^\.'), '');
                return allowedExts.contains(ext) || allowedExts.any((ae) => filePath.toLowerCase().endsWith(ae));
              })
              .toList();
          dirFiles.sort();
          for (final fPath in dirFiles) {
            final key = normalizeKey(fPath);
            if (seenPaths.add(key)) {
              effective.add(fPath);
            }
          }
        } catch (e) {
          debugPrint('Failed to expand directory $item: $e');
          final key = normalizeKey(item);
          if (seenPaths.add(key)) {
            effective.add(item);
          }
        }
      } else {
        final key = normalizeKey(item);
        if (seenPaths.add(key)) {
          effective.add(item);
        }
      }
    }
    return effective;
  }

  /// 将 Hex 颜色字符串解析为 Flutter Color 对象。
  /// 支持 #RGB, #RRGGBB, #AARRGGBB，以及 'transparent' / 'none'。
  static String formatBytes(int bytes) {
    if (bytes <= 0) return '0 B';
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  static Color parseHexColor(String hexStr) {
    final clean = hexStr.trim().toLowerCase();
    if (clean == 'transparent' || clean == 'none') {
      return Colors.transparent;
    }
    if (clean == 'white') return Colors.white;
    if (clean == 'black') return Colors.black;
    if (clean == 'red') return const Color(0xFFD81E1E);
    if (clean == 'blue') return const Color(0xFF438EDB);
    if (clean == 'gray' || clean == 'grey') return const Color(0xFFEEEEEE);

    String hex = clean.startsWith('#') ? clean.substring(1) : clean;
    if (hex.length == 3) {
      hex = '${hex[0]}${hex[0]}${hex[1]}${hex[1]}${hex[2]}${hex[2]}';
    }
    if (hex.length == 6) {
      hex = 'ff$hex';
    }
    if (hex.length == 8) {
      final val = int.tryParse(hex, radix: 16);
      if (val != null) return Color(val);
    }
    return Colors.white;
  }

  @override
  State<DynamicToolRunnerPage> createState() => _DynamicToolRunnerPageState();
}

class _DynamicToolRunnerPageState extends State<DynamicToolRunnerPage> {
  final Map<String, dynamic> _formValues = {};
  bool _isProcessing = false;
  bool _hasConfirmedNativeSecurityWarning = false;
  final Map<String, bool> _showCompareMode = {};
  double _progress = 0.0;
  String _statusText = '';
  ProcessingResult? _result;
  final List<TerminalLogEntry> _terminalLogs = [];

  @override
  void dispose() {
    if (_isProcessing && !SettingsService().runInBackground) {
      WindowsExtensionRunnerService.killActiveProcess();
      QuickJsBridgeService.killCurrentExecution();
      BackgroundTaskRunner.cancelActive();
      MediaEngineService.cancelActive();
    }
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    for (var input in widget.plugin.inputs) {
      if (input.defaultValue != null) {
        if (input.type == 'select') {
          final supported = input.options.where((o) => o.isSupportedOnCurrentPlatform()).toList();
          if (supported.isNotEmpty && !supported.any((o) => o.value == input.defaultValue)) {
            _formValues[input.id] = supported.first.value;
            continue;
          }
        }
        _formValues[input.id] = input.defaultValue;
      } else if (input.isColorInput) {
        _formValues[input.id] = '#FFFFFF';
      }
    }
  }

  Future<void> _pickFiles(PluginInputDef input) async {
    // 1. 判断是否属于系统缺乏标准 MIME 映射的特殊格式：
    // - 安卓 SAF 对 .001 / .z01 / .r00 等分卷扩展名缺乏系统 MIME 映射
    // - 专有/加密音频、文档或自定义格式（如 .ncm, .qmc, .kgm, .kwm, .mflac, .dwg 等）同样缺乏系统 MIME 映射
    const standardMimeExtensions = {
      'jpg', 'jpeg', 'png', 'gif', 'webp', 'bmp', 'svg',
      'mp3', 'wav', 'ogg', 'm4a', 'flac', 'aac', 'wma',
      'mp4', 'mkv', 'avi', 'mov', 'wmv', 'flv', 'webm',
      'txt', 'pdf', 'doc', 'docx', 'xls', 'xlsx', 'ppt', 'pptx',
      'zip', 'rar', '7z', 'tar', 'gz', 'json', 'xml', 'html'
    };

    final bool hasUnknownAndroidMime = Platform.isAndroid &&
        input.allowedExtensions.isNotEmpty &&
        input.allowedExtensions.any((ext) {
          final clean = ext.toLowerCase().replaceFirst(RegExp(r'^\.'), '');
          return !standardMimeExtensions.contains(clean);
        });

    final bool isAndroidArchivePicker = Platform.isAndroid &&
        (input.isArchive == true ||
            input.id == 'archiveInput' ||
            input.allowedExtensions.any((e) =>
                ['001', 'z01', 'r00', 'part1', 'part01'].contains(e.toLowerCase())));

    final bool forceAnyOnAndroid = hasUnknownAndroidMime || isAndroidArchivePicker;

    final pickerType = (input.allowedExtensions.isNotEmpty && !forceAnyOnAndroid)
        ? FileType.custom
        : FileType.any;
    final pickerExts = (input.allowedExtensions.isNotEmpty && !forceAnyOnAndroid)
        ? input.allowedExtensions
        : null;

    FilePickerResult? res;
    try {
      res = await FilePicker.platform.pickFiles(
        allowMultiple: input.allowMultiple,
        type: pickerType,
        allowedExtensions: pickerExts,
        lockParentWindow: true,
      );
    } catch (e) {
      if (Platform.isAndroid && pickerType == FileType.custom) {
        debugPrint('[FilePicker] Android FileType.custom failed ($e), falling back to FileType.any');
        res = await FilePicker.platform.pickFiles(
          allowMultiple: input.allowMultiple,
          type: FileType.any,
          lockParentWindow: true,
        );
      } else {
        rethrow;
      }
    }

    if (res != null && res.paths.isNotEmpty) {
      List<String> picked = res.paths.whereType<String>().toList();

      // 在 Android 端降级使用 FileType.any 时，若插件定义了明确的 allowedExtensions，
      // 在宿主层做安全过滤，避免用户误选其他无关类型的文件
      if (Platform.isAndroid && (forceAnyOnAndroid || pickerType == FileType.any) && input.allowedExtensions.isNotEmpty && input.isArchive != true && input.id != 'archiveInput') {
        final validExts = input.allowedExtensions
            .map((e) => e.toLowerCase().replaceFirst(RegExp(r'^\.'), ''))
            .toSet();
        final filtered = picked.where((f) {
          final ext = p.extension(f).toLowerCase().replaceFirst(RegExp(r'^\.'), '');
          return validExts.contains(ext) || validExts.any((ve) => f.toLowerCase().endsWith(ve));
        }).toList();

        if (filtered.length < picked.length && mounted) {
          final droppedCount = picked.length - filtered.length;
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('已自动过滤 $droppedCount 个不符合格式要求的文件（仅支持: ${input.allowedExtensions.join(', ')}）'),
              duration: const Duration(seconds: 3),
            ),
          );
        }
        picked = filtered;
      }

      if (picked.isEmpty) return;

      // 前置格式强校验拦截：若在 manifest 中声明了 rejectedExtensions，命中时弹窗指导并拒绝
      if (input.rejectedExtensions.isNotEmpty) {
        for (var rej in input.rejectedExtensions) {
          final hasRejectedMatch = picked.any((f) {
            final ext = p.extension(f).toLowerCase();
            return rej.extensions.any((re) {
              final clean = re.startsWith('.') ? re : '.$re';
              return clean.toLowerCase() == ext;
            });
          });
          if (hasRejectedMatch) {
            if (mounted) {
              showDialog(
                context: context,
                builder: (ctx) => AlertDialog(
                  title: Row(
                    children: [
                      const Icon(Icons.warning_amber_rounded, color: Colors.orange, size: 24),
                      const SizedBox(width: 8),
                      Text(rej.title, style: const TextStyle(fontSize: 16)),
                    ],
                  ),
                  content: Text(
                    rej.message,
                    style: const TextStyle(fontSize: 13, height: 1.5),
                  ),
                  actions: [
                    FilledButton(
                      onPressed: () => Navigator.pop(ctx),
                      child: const Text('我知道了'),
                    ),
                  ],
                ),
              );
            }
            return;
          }
        }
      } else if (input.id == 'cadInput' && picked.any((f) {
        final ext = p.extension(f).toLowerCase();
        return ext == '.dwg' || ext == '.dwf';
      })) {
        if (mounted) {
          showDialog(
            context: context,
            builder: (ctx) => AlertDialog(
              title: const Row(
                children: [
                  Icon(Icons.warning_amber_rounded, color: Colors.orange, size: 24),
                  SizedBox(width: 8),
                  Text('CAD 专有格式转换提示', style: TextStyle(fontSize: 16)),
                ],
              ),
              content: const Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '您选择的文件属于 DWG / DWF 专有二进制加密格式。',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                  ),
                  SizedBox(height: 10),
                  Text(
                    '由于该格式闭源专有，移动端与跨平台端无法直接进行高保真矢量解码。\n\n'
                    '【100% 全矢量无损转换操作指引】：\n'
                    '1. 在 AutoCAD、中望CAD 或浩辰CAD 中打开此图纸；\n'
                    '2. 命令行键入快捷命令 DXFOUT 并按回车（或点击【另存为】选择 AutoCAD DXF 格式）；\n'
                    '3. 将保存后的 .dxf 文件直接拖入本工具转换，即可立即输出高质量全矢量 PDF！',
                    style: TextStyle(fontSize: 13, height: 1.5),
                  ),
                ],
              ),
              actions: [
                FilledButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('我知道了'),
                ),
              ],
            ),
          );
        }
        return;
      }

      setState(() {
        if (input.allowMultiple) {
          final existing = (_formValues[input.id] is List)
              ? List<String>.from(_formValues[input.id])
              : <String>[];
          for (final f in picked) {
            final fName = p.basename(f);
            final fFile = File(f);
            final fSize = fFile.existsSync() ? fFile.lengthSync() : -1;
            final isDuplicate = existing.any((e) {
              if (e == f) return true;
              if (p.basename(e) == fName) {
                final eFile = File(e);
                if (fSize >= 0 && eFile.existsSync() && eFile.lengthSync() == fSize) {
                  return true;
                }
              }
              return false;
            });
            if (!isDuplicate) {
              existing.add(f);
            }
          }
          _formValues[input.id] = existing;
        } else {
          _formValues[input.id] = picked;
        }
      });
    }
  }

  Future<void> _pickFolder(PluginInputDef input) async {
    if (Platform.isAndroid) {
      final hasPermission = await StoragePermissionService.checkPermission();
      if (!hasPermission && mounted) {
        final ok = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Row(
              children: [
                Icon(Icons.folder_special_rounded, color: Colors.blueAccent),
                SizedBox(width: 8),
                Text('需要所有文件访问权限', style: TextStyle(fontSize: 16)),
              ],
            ),
            content: const Text(
              '打包整个文件夹需要读取文件夹内所有子文件。\n\n由于安卓系统（Android 11+）隐私限制，请在系统设置中为本应用开启【允许管理所有文件】权限。',
              style: TextStyle(fontSize: 14, height: 1.5),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('前往授权'),
              ),
            ],
          ),
        );
        if (ok == true) {
          await StoragePermissionService.requestPermission();
        }
        return;
      }
    }

    final dir = await FilePicker.platform.getDirectoryPath(
      lockParentWindow: true,
    );
    if (dir != null && dir.isNotEmpty) {
      setState(() {
        final existing = (_formValues[input.id] is List)
            ? List<String>.from(_formValues[input.id])
            : <String>[];
        final cleanDir = dir.endsWith('/') || dir.endsWith(r'\')
            ? dir.substring(0, dir.length - 1)
            : dir;
        if (!existing.contains(cleanDir)) {
          existing.add(cleanDir);
        }
        _formValues[input.id] = existing;
      });
    }
  }

  bool _isImageFile(String path) {
    final lower = path.toLowerCase();
    return lower.endsWith('.jpg') ||
        lower.endsWith('.jpeg') ||
        lower.endsWith('.png') ||
        lower.endsWith('.webp') ||
        lower.endsWith('.gif') ||
        lower.endsWith('.bmp');
  }

  bool _isAudioFile(String path) {
    final lower = path.toLowerCase();
    return lower.endsWith('.mp3') ||
        lower.endsWith('.wav') ||
        lower.endsWith('.flac') ||
        lower.endsWith('.aac') ||
        lower.endsWith('.ogg') ||
        lower.endsWith('.m4a');
  }

  bool _isVideoFile(String path) {
    final lower = path.toLowerCase();
    return lower.endsWith('.mp4') ||
        lower.endsWith('.mkv') ||
        lower.endsWith('.avi') ||
        lower.endsWith('.mov') ||
        lower.endsWith('.flv') ||
        lower.endsWith('.webm');
  }

  bool _isInputVisible(PluginInputDef input) {
    if (!input.isSupportedOnCurrentPlatform()) return false;
    final cond = input.visibleIf;
    if (cond == null) return true;
    return _evalCondition(cond);
  }

  bool _evalCondition(PluginInputCondition cond) {
    // 1. 如果该条件依赖的父字段对应另一个输入项，且该输入项当前不可见，则本项递归隐藏
    if (cond.field.isNotEmpty) {
      final parentMatches = widget.plugin.inputs.where((i) => i.id == cond.field);
      if (parentMatches.isNotEmpty) {
        final parentInput = parentMatches.first;
        if (!_isInputVisible(parentInput)) {
          return false;
        }
      }

      final curVal = _formValues[cond.field];
      if (cond.equals != null && curVal?.toString() != cond.equals?.toString()) return false;
      if (cond.notEquals != null && curVal?.toString() == cond.notEquals?.toString()) return false;
      if (cond.inValues != null) {
        final inList = cond.inValues!.map((e) => e?.toString()).toList();
        if (!inList.contains(curVal?.toString())) return false;
      }
    }

    // 2. 支持 and 复合条件
    if (cond.and != null && cond.and!.isNotEmpty) {
      for (final subCond in cond.and!) {
        if (!_evalCondition(subCond)) return false;
      }
    }

    // 3. 支持 or 复合条件 (满足任一即可)
    if (cond.or != null && cond.or!.isNotEmpty) {
      final anyPassed = cond.or!.any((subCond) => _evalCondition(subCond));
      if (!anyPassed) return false;
    }

    return true;
  }

  bool _isAndroidOfficeJumpSubTool(String subTool) {
    if (!Platform.isAndroid) return false;
    return subTool == 'pptx_to_pdf_android' ||
        subTool == 'docx_to_pdf_android' ||
        subTool == 'excel_to_pdf_android_office' ||
        subTool == 'pptx_to_images_android_office' ||
        subTool == 'pdf_to_docx_android_office' ||
        subTool == 'pptx_to_pdf' ||
        subTool == 'docx_to_pdf';
  }

  Widget _buildGuideStep(String stepNumber, String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 20,
            height: 20,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: Colors.blue.shade100,
              shape: BoxShape.circle,
            ),
            child: Text(
              stepNumber,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.bold,
                color: Colors.blue.shade900,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(fontSize: 12.5, height: 1.4, color: Colors.black87),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _executeTool() async {
    if (Platform.isAndroid && (widget.plugin.requiresStoragePermission || widget.plugin.id == 'universal-archive-extractor')) {
      final hasPerm = await StoragePermissionService.checkPermission();
      if (!hasPerm && mounted) {
        final shouldRequest = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Row(
              children: [
                Icon(Icons.folder_special_rounded, color: Colors.blueAccent),
                SizedBox(width: 8),
                Text('存储权限提示', style: TextStyle(fontSize: 16)),
              ],
            ),
            content: Text(
              '${widget.plugin.name} 需要读写设备公共存储区域的文件与文件夹。\n\n为确保真机环境下能正常扫描选定目录并完整输出处理结果，建议开启【允许管理所有文件】权限。',
              style: const TextStyle(fontSize: 14, height: 1.5),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('暂不授权'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('前往授权'),
              ),
            ],
          ),
        );
        if (shouldRequest == true) {
          await StoragePermissionService.requestPermission();
          return;
        }
      }
    }
    if (!mounted) return;

    final visibleInputs = widget.plugin.inputs.where(_isInputVisible).toList();
    final visibleFileInputs = visibleInputs.where((i) => i.type == 'file_picker').toList();

    for (var fileInput in visibleFileInputs) {
      final files = (_formValues[fileInput.id] is List)
          ? List<String>.from(_formValues[fileInput.id])
          : <String>[];
      if (fileInput.required && files.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('请先选择：${fileInput.label}')),
        );
        return;
      }
    }

    for (var input in visibleInputs) {
      if (input.required && input.type != 'file_picker') {
        final val = _formValues[input.id]?.toString().trim() ?? '';
        if (val.isEmpty) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('请填写必填项：${input.label}')),
          );
          return;
        }
      }
    }

    final curSubTool = _formValues['subTool']?.toString() ?? '';
    if (_isAndroidOfficeJumpSubTool(curSubTool)) {
      final checkRes = await AndroidOfficeBridge.checkOfficeInstalled();
      final isInstalled = checkRes['isInstalled'] == true;
      if (!isInstalled && mounted) {
        await showDialog(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Row(
              children: [
                Icon(Icons.warning_amber_rounded, color: Colors.orange, size: 24),
                SizedBox(width: 8),
                Text('未检测到手机办公软件', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
              ],
            ),
            content: Text(
              '当前文档格式包含复杂的母版排版、形状图层与字体样式。为避免移动端独立轻量引擎造成排版错乱和文字重叠，本工具需要通过手机已安装的【WPS Office】或【Microsoft 365 / Office】进行高质量无损导出。\n\n'
              '当前未检测到手机安装上述软件，建议您先在应用商店安装【WPS Office】或【Microsoft 365 / Office】后再试。'
              '${curSubTool.contains('excel') ? '\n\n💡 若只需提取纯表格数据生成 PDF，您可以直接切换至“Excel 转 PDF (本地离线轻量引擎)”进行一键转换。' : ''}',
              style: const TextStyle(fontSize: 13, height: 1.5),
            ),
            actions: [
              FilledButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('我知道了'),
              ),
            ],
          ),
        );
        return;
      }

      if (isInstalled && mounted) {
        final targetAppName = checkRes['primaryName']?.toString() ?? 'WPS Office / Microsoft 365';
        final targetPkg = checkRes['primaryPackage']?.toString() ?? '';
        final isWps = targetPkg.contains('wps') || targetPkg.contains('kingsoft');
        final isImages = curSubTool.contains('images');
        final isDocx = curSubTool.contains('to_docx');
        final docTypeName = curSubTool.contains('excel')
            ? 'Excel 表格'
            : (curSubTool.contains('pptx') ? 'PPT 演示文稿' : (isDocx ? 'PDF 文档' : 'Word 文档'));
        final guideTitle = isImages
            ? '长图/图片导出操作指引'
            : (isDocx ? 'PDF 转 Word 操作指引' : 'PDF 导出操作指引');

        final confirmed = await showDialog<bool>(
          context: context,
          barrierDismissible: false,
          builder: (ctx) => AlertDialog(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            title: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(6),
                  decoration: BoxDecoration(
                    color: Colors.blue.shade50,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Icon(
                    isImages
                        ? Icons.photo_library_rounded
                        : (isDocx ? Icons.edit_document : Icons.menu_book_rounded),
                    color: Colors.blue.shade700,
                    size: 22,
                  ),
                ),
                const SizedBox(width: 10),
                Text(guideTitle, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
              ],
            ),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    decoration: BoxDecoration(
                      color: Colors.green.shade50,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: Colors.green.shade200),
                    ),
                    child: Row(
                      children: [
                        Icon(Icons.check_circle_outline, size: 18, color: Colors.green.shade700),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            '检测到已安装：$targetAppName',
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: Colors.green.shade900,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 14),
                  const Text(
                    '为保证 100% 格式与版式无损，即将调起该应用。请先了解以下操作步骤：',
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, height: 1.4),
                  ),
                  const SizedBox(height: 10),
                  if (isImages) ...[
                    if (isWps) ...[
                      _buildGuideStep('1', '点击下方按钮，将自动为您在【WPS Office】中打开此 PPT 演示文稿；'),
                      _buildGuideStep('2', '点击 WPS 界面左下角【三条横线（工具）】；'),
                      _buildGuideStep('3', '在工具箱中找到并点击【输出为图片】；'),
                      _buildGuideStep('4', '选择导出模式（逐页切图或拼长图）并保存到手机相册。'),
                    ] else ...[
                      _buildGuideStep('1', '点击下方按钮，将自动为您在【Microsoft Office】中打开此 PPT；'),
                      _buildGuideStep('2', '点击右上角菜单【...】或【分享】；'),
                      _buildGuideStep('3', '选择【以图片形式发送/共享】并保存到设备相册！'),
                    ],
                  ] else if (isDocx) ...[
                    if (isWps) ...[
                      _buildGuideStep('1', '点击下方按钮，将自动为您在【WPS Office】中打开此 PDF 文档；'),
                      _buildGuideStep('2', '在 WPS 菜单栏中，切换至【转换】标签；'),
                      _buildGuideStep('3', '点击选择【PDF 转 Word】；'),
                      _buildGuideStep('4', '确认后一键转换为官方高保真可编辑 Word 文档！'),
                    ] else ...[
                      _buildGuideStep('1', '点击下方按钮，将自动为您在【Microsoft Office】中打开此 PDF 文档；'),
                      _buildGuideStep('2', 'Office 会提示将 PDF 转换为可编辑 Word 文档，点击【转换】；'),
                      _buildGuideStep('3', '点击保存或导出为 .docx 格式！'),
                    ],
                  ] else ...[
                    if (isWps) ...[
                      _buildGuideStep('1', '点击下方按钮，将自动为您在【WPS Office】中打开此$docTypeName；'),
                      _buildGuideStep('2', '点击 WPS 界面左下角【三条横线（工具）】；'),
                      _buildGuideStep('3', '在展开的工具箱中找到并点击【输出为 PDF】；'),
                      _buildGuideStep('4', '选择手机本地存储目录并保存，即可获得商业级 100% 原版高保真 PDF！'),
                    ] else ...[
                      _buildGuideStep('1', '点击下方按钮，将自动为您在【Microsoft Office】中打开此$docTypeName；'),
                      _buildGuideStep('2', '点击右上角【...】菜单或左上角【文件】；'),
                      _buildGuideStep('3', '点击【共享】选择【PDF】或点击【打印】选择【另存为 PDF】；'),
                      _buildGuideStep('4', '选择保存位置，即可获得官方商业级 100% 原版高保真 PDF！'),
                    ],
                  ],
                  const SizedBox(height: 12),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: Colors.orange.shade50,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: Colors.orange.shade300),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Icon(Icons.workspace_premium_rounded, size: 18, color: Colors.orange.shade800),
                            const SizedBox(width: 6),
                            Text(
                              'WPS 官方功能与会员限制提醒',
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.bold,
                                color: Colors.orange.shade900,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 6),
                        Text(
                          isImages
                              ? '• 输出图片效果与画质受限于 WPS 会员状态。\n• 非 VIP 会员导出图片可能限制画质清晰度（普通画质较模糊），或附带非会员水印。'
                              : (isDocx
                                  ? '• WPS 移动端【PDF 转 Word】属于 VIP 会员专属权益。\n• 非 VIP 会员可能仅支持试转前几页或无法导出。若无会员，您可返回选择本工具箱的【本地离线轻量排版引擎】进行转换。'
                                  : '• 导出效果与高级排版保留受限于手机办公软件版本与 WPS 会员权限。'),
                          style: TextStyle(
                            fontSize: 11.5,
                            color: Colors.brown.shade800,
                            height: 1.45,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 10),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                    decoration: BoxDecoration(
                      color: Colors.blue.shade50,
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(color: Colors.blue.shade200),
                    ),
                    child: const Row(
                      children: [
                        Icon(Icons.info_outline, size: 16, color: Colors.blue),
                        SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            '请记住上述操作。确认了解后，点击下方按钮立即前往。',
                            style: TextStyle(fontSize: 11.5, color: Colors.blueGrey),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('取消'),
              ),
              FilledButton.icon(
                icon: const Icon(Icons.open_in_new, size: 16),
                label: Text('已了解，立即打开 $targetAppName'),
                onPressed: () => Navigator.pop(ctx, true),
              ),
            ],
          ),
        );

        if (confirmed != true) {
          return;
        }
      }
    }

    if (!mounted) return;

    if (Platform.isWindows &&
        (widget.plugin.isWindowsExtension || widget.plugin.nativeRunner != null) &&
        !widget.plugin.isOfficial &&
        !_hasConfirmedNativeSecurityWarning &&
        !Platform.environment.containsKey('FLUTTER_TEST')) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: const Row(
            children: [
              Icon(Icons.shield_outlined, color: Colors.orange, size: 24),
              SizedBox(width: 8),
              Text('第三方原生扩展安全提示', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            ],
          ),
          content: Text(
            '当前工具「${widget.plugin.name}」属于第三方/社区原生执行模块（.exe / 外部子进程），将在 Windows 本地直接启动独立进程并拥有当前系统的用户执行权限。\n\n'
            '• 请确保该插件来自您信任的开发者或社区来源。\n'
            '• 宿主底座已启用输入参数转义与路径规范化，但无法约束未受信任外部二进制程序本身的内部行为。\n\n'
            '是否确认继续运行？',
            style: const TextStyle(fontSize: 13, height: 1.5),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消'),
            ),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: Colors.orange.shade700,
              ),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('信任并继续运行'),
            ),
          ],
        ),
      );

      if (confirmed != true) {
        return;
      }
      _hasConfirmedNativeSecurityWarning = true;
    }

    setState(() {
      _isProcessing = true;
      _progress = 0.0;
      _statusText = '准备开始处理...';
      _result = null;
      _terminalLogs.clear();
    });

    Directory? baseDir;
    try {
      if (Platform.environment.containsKey('FLUTTER_TEST')) {
        baseDir = Directory.systemTemp;
      } else if (Platform.isWindows) {
        baseDir = await getDownloadsDirectory();
      } else if (Platform.isAndroid) {
        final pubDownload = Directory('/storage/emulated/0/Download');
        if (pubDownload.existsSync()) {
          baseDir = pubDownload;
        } else {
          baseDir = await getExternalStorageDirectory();
        }
      }
    } catch (_) {}
    try {
      baseDir ??= await getApplicationDocumentsDirectory();
    } catch (_) {
      baseDir = Directory.systemTemp;
    }

    final outDir = p.join(baseDir.path, 'Toolbox_Outputs');

    // 解析 action 参数映射模板，例如将 ${quality} 替换为表单实际填写的值
    final evaluatedParams = <String, dynamic>{..._formValues};
    if (widget.plugin.localDir != null) {
      evaluatedParams['pluginDirectory'] = widget.plugin.localDir;
    }
    if (widget.plugin.wasmRunner != null) {
      final wr = widget.plugin.wasmRunner!;
      evaluatedParams['wasmPath'] ??= wr.entry;
      evaluatedParams['executionMode'] ??= wr.executionMode;
      if (wr.args.isNotEmpty) {
        evaluatedParams['cliArgsList'] = wr.args;
        evaluatedParams['cliArgs'] ??= wr.args.join(' ');
      }
      evaluatedParams['batchMode'] ??= wr.batchMode;
      if (wr.functionName != null) {
        evaluatedParams['functionName'] ??= wr.functionName;
      }
      if (wr.env.isNotEmpty) {
        evaluatedParams['wasmEnv'] = wr.env;
      }
    }
    if (widget.plugin.action != null) {
      widget.plugin.action!.params.forEach((key, val) {
        if (val is String && val.startsWith(r'${') && val.endsWith('}')) {
          final varName = val.substring(2, val.length - 1);
          if (_formValues.containsKey(varName)) {
            evaluatedParams[key] = _formValues[varName];
          }
        } else {
          evaluatedParams[key] = val;
        }
      });
    }

    final effectiveInputFiles = <String>[];
    for (var fileInput in visibleFileInputs) {
      final val = _formValues[fileInput.id];
      final rawList = val is List
          ? List<String>.from(val)
          : (val is String && val.isNotEmpty ? [val] : <String>[]);
      final bool preserveDirs = fileInput.preserveDirectoryEntries == true ||
          (fileInput.preserveDirectoryEntriesIf != null &&
              _evalCondition(fileInput.preserveDirectoryEntriesIf!)) ||
          ((widget.plugin.action?.handler == 'archive_universal' || widget.plugin.id == 'archive_universal') &&
              _formValues['archiveMode']?.toString() == 'compress');
      final flattened = DynamicToolRunnerPage.flattenInputEntries(
        rawEntries: rawList,
        allowedExtensions: fileInput.allowedExtensions,
        isArchiveCompress: preserveDirs,
      );
      effectiveInputFiles.addAll(flattened);
    }

    if (effectiveInputFiles.isEmpty && visibleFileInputs.any((i) => i.required)) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              visibleFileInputs.any((i) => i.allowedExtensions.isNotEmpty)
                  ? '所选条目中未扫描到有效文件（格式要求: ${visibleFileInputs.expand((i) => i.allowedExtensions).toSet().join(', ')}）'
                  : '所选条目中未扫描到有效文件',
            ),
          ),
        );
      }
      return;
    }

    final ProcessingResult res;
    final engine = DynamicToolRunnerPage.resolveExecutionEngine(
      plugin: widget.plugin,
      isWindows: Platform.isWindows,
    );
    switch (engine) {
      case PluginExecutionEngine.windowsNative:
        res = await WindowsExtensionRunnerService.execute(
          plugin: widget.plugin,
          formValues: evaluatedParams,
          inputFiles: effectiveInputFiles,
          outputDir: outDir,
          onProgress: (progress, stage) {
            if (!mounted) return;
            setState(() {
              _progress = progress;
              _statusText = stage;
            });
          },
          onLog: (line, isError) {
            if (!mounted) return;
            setState(() {
              _terminalLogs.add(TerminalLogEntry(text: line, isError: isError));
            });
          },
        );
        break;
      case PluginExecutionEngine.quickJs:
        res = await QuickJsBridgeService.execute(
          plugin: widget.plugin,
          formValues: evaluatedParams,
          inputFiles: effectiveInputFiles,
          outputDir: outDir,
          onProgress: (progress, stage) {
            if (!mounted) return;
            setState(() {
              _progress = progress;
              _statusText = stage;
            });
          },
          onLog: (line, isError) {
            if (!mounted) return;
            setState(() {
              _terminalLogs.add(TerminalLogEntry(text: line, isError: isError));
            });
          },
        );
        break;
      case PluginExecutionEngine.wasmUniversal:
        res = await BackgroundTaskRunner.execute(
          handler: widget.plugin.action?.handler ?? 'wasm_universal',
          inputFiles: effectiveInputFiles,
          params: evaluatedParams,
          outputDir: outDir,
          onProgress: (progress, stage) {
            if (!mounted) return;
            setState(() {
              _progress = progress;
              _statusText = stage;
            });
          },
          onLog: (line, isError) {
            if (!mounted) return;
            setState(() {
              _terminalLogs.add(TerminalLogEntry(text: line, isError: isError));
            });
          },
        );
        break;
      case PluginExecutionEngine.internalHandler:
        res = await BackgroundTaskRunner.execute(
          handler: widget.plugin.action?.handler ?? 'image_compress',
          inputFiles: effectiveInputFiles,
          params: evaluatedParams,
          outputDir: outDir,
          onProgress: (progress, stage) {
            if (!mounted) return;
            setState(() {
              _progress = progress;
              _statusText = stage;
            });
          },
          onLog: (line, isError) {
            if (!mounted) return;
            setState(() {
              _terminalLogs.add(TerminalLogEntry(text: line, isError: isError));
            });
          },
        );
        break;
    }

    // 发送任务处理完成系统通知（即使用户已退回主界面或将 App 放至后台）
    try {
      if (res.success) {
        NotificationService().showTaskNotification(
          title: '【${widget.plugin.name}】处理完成',
          body: res.message.isNotEmpty
              ? res.message
              : '输出文件已保存至: $outDir',
          isSuccess: true,
        );
      } else {
        NotificationService().showTaskNotification(
          title: '【${widget.plugin.name}】处理失败',
          body: res.message.isNotEmpty ? res.message : '处理过程中发生异常',
          isSuccess: false,
        );
      }
    } catch (e) {
      debugPrint('通知服务调度跳过或异常: $e');
    }

    if (!mounted) return;
    setState(() {
      _isProcessing = false;
      _result = res;
    });
  }

  Future<void> _openFile(String path) async {
    try {
      final file = File(path);
      if (!file.existsSync()) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('文件不存在或已被移除')),
          );
        }
        return;
      }
      final result = await OpenFilex.open(path);
      if (result.type != ResultType.done && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('提示: ${result.message}')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('打开文件失败: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final textPrimary = theme.colorScheme.onSurface;
    final textSecondary = theme.colorScheme.onSurfaceVariant;
    final isMobile = MediaQuery.sizeOf(context).width < 768;

    final formSection = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: isDark ? const Color(0xFF1E293B) : const Color(0xFFF3F4F6),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: isDark ? const Color(0xFF334155) : const Color(0xFFE5E7EB)),
          ),
          child: Row(
            children: [
              Icon(Icons.tips_and_updates, size: 20, color: theme.colorScheme.primary),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  widget.plugin.description,
                  style: TextStyle(
                    fontSize: 13,
                    color: textPrimary,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        if (widget.plugin.banners.isNotEmpty) ...[
          ...widget.plugin.banners.map((b) => _buildBannerCard(b, context)),
          const SizedBox(height: 12),
        ],
        ...widget.plugin.inputs.where(_isInputVisible).map((input) => _buildInputField(input, context)),
        const SizedBox(height: 16),
        SizedBox(
          width: double.infinity,
          height: 46,
          child: FilledButton.icon(
            onPressed: _isProcessing ? null : _executeTool,
            icon: _isProcessing
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                  )
                : const Icon(Icons.play_arrow),
            label: Text(
              _isProcessing ? '正在处理中...' : '开始执行处理',
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
            ),
          ),
        ),
        if (_isProcessing) ...[
          const SizedBox(height: 14),
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: LinearProgressIndicator(
              minHeight: 7,
              value: _progress > 0 ? _progress.clamp(0.0, 1.0) : null,
            ),
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              Expanded(
                child: Text(
                  _statusText,
                  style: TextStyle(color: textSecondary, fontSize: 12),
                ),
              ),
              if (_progress > 0) ...[
                const SizedBox(width: 8),
                Text(
                  '${(_progress * 100).clamp(0, 100).toStringAsFixed(0)}%',
                  style: TextStyle(
                    color: theme.colorScheme.primary,
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ],
          ),
        ],
        if (widget.plugin.hasTerminal || _terminalLogs.isNotEmpty) ...[
          const SizedBox(height: 16),
          TerminalLogViewer(
            logs: _terminalLogs,
            isRunning: _isProcessing,
            onStop: () {
              WindowsExtensionRunnerService.killActiveProcess();
              QuickJsBridgeService.killCurrentExecution();
              BackgroundTaskRunner.cancelActive();
              MediaEngineService.cancelActive();
            },
            onClear: () {
              setState(() {
                _terminalLogs.clear();
              });
            },
          ),
        ],
      ],
    );

    final resultSection = Container(
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF1E293B) : const Color(0xFFF9FAFB),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: isDark ? const Color(0xFF334155) : const Color(0xFFE5E7EB)),
      ),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '输出结果面板',
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15, color: textPrimary),
          ),
          const SizedBox(height: 12),
          if (_result == null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 24),
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.output, size: 40, color: textSecondary.withValues(alpha: 0.5)),
                    const SizedBox(height: 8),
                    Text(
                      '选择文件并配置参数后点击开始',
                      style: TextStyle(color: textSecondary, fontSize: 13),
                    ),
                  ],
                ),
              ),
            )
          else ...[
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: _result!.success
                    ? (isDark ? const Color(0xFF064E3B).withValues(alpha: 0.3) : const Color(0xFFECFDF5))
                    : (isDark ? const Color(0xFF7F1D1D).withValues(alpha: 0.3) : const Color(0xFFFEF2F2)),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: _result!.success
                      ? (isDark ? const Color(0xFF10B981) : const Color(0xFFA7F3D0))
                      : (isDark ? const Color(0xFFEF4444) : const Color(0xFFFECACA)),
                ),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    _result!.success ? Icons.check_circle : Icons.error,
                    size: 20,
                    color: _result!.success ? const Color(0xFF10B981) : const Color(0xFFEF4444),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _result!.message,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                        color: _result!.success
                            ? (isDark ? const Color(0xFFD1FAE5) : const Color(0xFF065F46))
                            : (isDark ? const Color(0xFFFEE2E2) : const Color(0xFF991B1B)),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            if ((_result!.resultText != null && _result!.resultText!.trim().isNotEmpty) ||
                _result!.resultData != null)
              ..._buildDataResultCards(result: _result!, isDark: isDark, theme: theme),
            if (_result!.outputFiles.isNotEmpty) ...[
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    '生成的输出文件 (${_result!.outputFiles.length}):',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: textPrimary),
                  ),
                  Text(
                    '点击直接打开',
                    style: TextStyle(fontSize: 12, color: theme.colorScheme.primary, fontWeight: FontWeight.w600),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Builder(builder: (context) {
                final allInputFiles = <String>[];
                for (final input in widget.plugin.inputs) {
                  if (input.type == 'file_picker') {
                    final files = (_formValues[input.id] is List)
                        ? List<String>.from(_formValues[input.id])
                        : <String>[];
                    for (final f in files) {
                      if (f.isNotEmpty) allInputFiles.add(f);
                    }
                  }
                }

                // 计算总体积节省数据
                int totalInBytes = 0;
                int totalOutBytes = 0;
                int validSavingsCount = 0;

                for (int i = 0; i < _result!.outputFiles.length; i++) {
                  final outPath = _result!.outputFiles[i];
                  if (!File(outPath).existsSync()) continue;
                  final outSize = File(outPath).lengthSync();
                  totalOutBytes += outSize;

                  String? matchingInput;
                  final baseOut = p.basenameWithoutExtension(outPath).toLowerCase();
                  for (final inPath in allInputFiles) {
                    final baseIn = p.basenameWithoutExtension(inPath).toLowerCase();
                    if (baseOut == baseIn ||
                        baseOut == 'compressed_$baseIn' ||
                        baseOut == 'resized_$baseIn' ||
                        baseOut.contains(baseIn) ||
                        baseIn.contains(baseOut)) {
                      matchingInput = inPath;
                      break;
                    }
                  }
                  if (matchingInput == null && i < allInputFiles.length) {
                    matchingInput = allInputFiles[i];
                  }
                  if (matchingInput != null && File(matchingInput).existsSync()) {
                    totalInBytes += File(matchingInput).lengthSync();
                    validSavingsCount++;
                  }
                }

                final hasCompressionStats = validSavingsCount > 0 && totalInBytes > 0;
                final totalSavedBytes = totalInBytes - totalOutBytes;
                final totalRatio = hasCompressionStats
                    ? ((1.0 - (totalOutBytes / totalInBytes)) * 100.0).clamp(-999.0, 99.9).toStringAsFixed(1)
                    : '0';

                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (hasCompressionStats && _result!.outputFiles.length > 1) ...[
                      Container(
                        margin: const EdgeInsets.only(bottom: 12),
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                        decoration: BoxDecoration(
                          color: isDark
                              ? const Color(0xFF064E3B).withValues(alpha: 0.35)
                              : const Color(0xFFECFDF5),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(
                            color: isDark ? const Color(0xFF10B981) : const Color(0xFFA7F3D0),
                          ),
                        ),
                        child: Row(
                          children: [
                            const Icon(Icons.analytics_outlined, color: Color(0xFF10B981), size: 22),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      Text(
                                        '批量处理完成 · 共 ${_result!.outputFiles.length} 项成果',
                                        style: TextStyle(
                                          fontWeight: FontWeight.bold,
                                          fontSize: 13,
                                          color: isDark ? const Color(0xFFD1FAE5) : const Color(0xFF065F46),
                                        ),
                                      ),
                                      const Spacer(),
                                      Container(
                                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                        decoration: BoxDecoration(
                                          color: totalSavedBytes > 0 ? const Color(0xFF10B981) : Colors.orange,
                                          borderRadius: BorderRadius.circular(10),
                                        ),
                                        child: Text(
                                          totalSavedBytes > 0 ? '综合节省 $totalRatio%' : '体积微增',
                                          style: const TextStyle(
                                            color: Colors.white,
                                            fontSize: 11,
                                            fontWeight: FontWeight.bold,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 3),
                                  Text(
                                    '总体积: ${DynamicToolRunnerPage.formatBytes(totalInBytes)} → ${DynamicToolRunnerPage.formatBytes(totalOutBytes)} (共节省 ${DynamicToolRunnerPage.formatBytes(totalSavedBytes.clamp(0, double.infinity).toInt())})',
                                    style: TextStyle(
                                      fontSize: 11,
                                      color: isDark ? const Color(0xFFA7F3D0) : const Color(0xFF047857),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                    ..._result!.outputFiles.asMap().entries.map((entry) {
                      final outIdx = entry.key;
                      final outPath = entry.value;
                      final isImg = _isImageFile(outPath);
                      final isAudio = _isAudioFile(outPath);
                      final isVideo = _isVideoFile(outPath);
                      final lower = outPath.toLowerCase();
                      final isText = lower.endsWith('.json') ||
                          lower.endsWith('.txt') ||
                          lower.endsWith('.md') ||
                          lower.endsWith('.csv') ||
                          lower.endsWith('.log');
                      final fileExists = File(outPath).existsSync();
                      final outSize = fileExists ? File(outPath).lengthSync() : 0;

                      String? matchingInput;
                      final baseOut = p.basenameWithoutExtension(outPath).toLowerCase();
                      for (final inPath in allInputFiles) {
                        final baseIn = p.basenameWithoutExtension(inPath).toLowerCase();
                        if (baseOut == baseIn ||
                            baseOut == 'compressed_$baseIn' ||
                            baseOut == 'resized_$baseIn' ||
                            baseOut.contains(baseIn) ||
                            baseIn.contains(baseOut)) {
                          matchingInput = inPath;
                          break;
                        }
                      }
                      if (matchingInput == null && outIdx < allInputFiles.length) {
                        matchingInput = allInputFiles[outIdx];
                      }
                      matchingInput ??= allInputFiles.isNotEmpty ? allInputFiles.first : null;

                      final hasMatchingInput = matchingInput != null &&
                          File(matchingInput).existsSync() &&
                          matchingInput != outPath;
                      final inSize = hasMatchingInput ? File(matchingInput).lengthSync() : 0;
                      final savedBytes = inSize - outSize;
                      final ratio = (inSize > 0)
                          ? ((1.0 - (outSize / inSize)) * 100.0).clamp(-999.0, 99.9)
                          : 0.0;

                      final canCompare = isImg && fileExists && hasMatchingInput;
                      final isCompareActive = _showCompareMode[outPath] == true;

                      return Card(
                        margin: const EdgeInsets.only(bottom: 10),
                        elevation: 1,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10),
                          side: BorderSide(color: isDark ? const Color(0xFF334155) : const Color(0xFFE5E7EB)),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            ListTile(
                              onTap: () => _openFile(outPath),
                              dense: true,
                              contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                              leading: isImg && fileExists
                                  ? ClipRRect(
                                      borderRadius: BorderRadius.circular(6),
                                      child: Image.file(
                                        File(outPath),
                                        width: 48,
                                        height: 48,
                                        fit: BoxFit.cover,
                                        errorBuilder: (_, __, ___) => const Icon(Icons.broken_image),
                                      ),
                                    )
                                  : Icon(
                                      isAudio
                                          ? Icons.audiotrack_rounded
                                          : (isVideo
                                              ? Icons.movie_creation_outlined
                                              : (isText ? Icons.description_outlined : Icons.insert_drive_file)),
                                      color: theme.colorScheme.primary,
                                      size: 32,
                                    ),
                              title: Row(
                                children: [
                                  Expanded(
                                    child: Text(
                                      p.basename(outPath),
                                      style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: textPrimary),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                  const SizedBox(width: 6),
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
                                    decoration: BoxDecoration(
                                      color: theme.colorScheme.primary.withValues(alpha: 0.1),
                                      borderRadius: BorderRadius.circular(4),
                                    ),
                                    child: Text(
                                      p.extension(outPath).toUpperCase().replaceAll('.', ''),
                                      style: TextStyle(
                                        fontSize: 9.5,
                                        fontWeight: FontWeight.bold,
                                        color: theme.colorScheme.primary,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                              subtitle: Padding(
                                padding: const EdgeInsets.only(top: 4),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    if (hasMatchingInput && inSize > 0) ...[
                                      Row(
                                        children: [
                                          Text(
                                            '${DynamicToolRunnerPage.formatBytes(inSize)} → ${DynamicToolRunnerPage.formatBytes(outSize)}',
                                            style: TextStyle(
                                              fontSize: 11,
                                              fontWeight: FontWeight.w500,
                                              color: textSecondary,
                                            ),
                                          ),
                                          const SizedBox(width: 8),
                                          Container(
                                            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                                            decoration: BoxDecoration(
                                              color: savedBytes > 0
                                                  ? (isDark ? const Color(0xFF065F46) : const Color(0xFFD1FAE5))
                                                  : (isDark ? const Color(0xFF7F1D1D) : const Color(0xFFFEE2E2)),
                                              borderRadius: BorderRadius.circular(4),
                                            ),
                                            child: Text(
                                              savedBytes > 0
                                                  ? '-${ratio.toStringAsFixed(1)}% (节省 ${DynamicToolRunnerPage.formatBytes(savedBytes)})'
                                                  : (savedBytes == 0 ? '体积持平' : '+${(-ratio).toStringAsFixed(1)}%'),
                                              style: TextStyle(
                                                fontSize: 10,
                                                fontWeight: FontWeight.bold,
                                                color: savedBytes > 0
                                                    ? (isDark ? const Color(0xFF6EE7B7) : const Color(0xFF047857))
                                                    : (isDark ? const Color(0xFFFCA5A5) : const Color(0xFFB91C1C)),
                                              ),
                                            ),
                                          ),
                                        ],
                                      ),
                                      const SizedBox(height: 2),
                                    ] else ...[
                                      Text(
                                        '大小: ${DynamicToolRunnerPage.formatBytes(outSize)}',
                                        style: TextStyle(fontSize: 11, color: textSecondary),
                                      ),
                                      const SizedBox(height: 2),
                                    ],
                                    Text(
                                      outPath,
                                      style: TextStyle(fontSize: 10, color: textSecondary.withValues(alpha: 0.8)),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ],
                                ),
                              ),
                              trailing: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  IconButton(
                                    icon: const Icon(Icons.open_in_new, size: 20),
                                    tooltip: '打开或播放',
                                    onPressed: () => _openFile(outPath),
                                  ),
                                  if (Platform.isWindows)
                                    IconButton(
                                      icon: const Icon(Icons.folder_open, size: 20),
                                      tooltip: '在文件夹中定位',
                                      onPressed: () {
                                        Process.run('explorer.exe', ['/select,', outPath]);
                                      },
                                    ),
                                ],
                              ),
                            ),
                            if (canCompare)
                              Padding(
                                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
                                child: Row(
                                  mainAxisAlignment: MainAxisAlignment.end,
                                  children: [
                                    TextButton.icon(
                                      style: TextButton.styleFrom(
                                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                                        visualDensity: VisualDensity.compact,
                                      ),
                                      onPressed: () {
                                        setState(() {
                                          _showCompareMode[outPath] = !isCompareActive;
                                        });
                                      },
                                      icon: Icon(
                                        isCompareActive ? Icons.image_outlined : Icons.compare,
                                        size: 16,
                                        color: theme.colorScheme.primary,
                                      ),
                                      label: Text(
                                        isCompareActive ? '单图预览' : '原图与压缩后滑动对比',
                                        style: TextStyle(
                                          fontSize: 12,
                                          color: theme.colorScheme.primary,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            if (isImg && fileExists)
                              Padding(
                                padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
                                child: (canCompare && isCompareActive)
                                    ? ImageCompareSliderWidget(
                                        beforeImagePath: matchingInput,
                                        afterImagePath: outPath,
                                        beforeLabel: '原图 (${DynamicToolRunnerPage.formatBytes(inSize)})',
                                        afterLabel: '处理后 (${DynamicToolRunnerPage.formatBytes(outSize)})',
                                      )
                                    : GestureDetector(
                                        onTap: () => _openFile(outPath),
                                        child: Container(
                                          constraints: const BoxConstraints(maxHeight: 220),
                                          decoration: BoxDecoration(
                                            color: isDark ? const Color(0xFF0F172A) : const Color(0xFFF8FAFC),
                                            borderRadius: BorderRadius.circular(8),
                                            border: Border.all(
                                              color: isDark ? const Color(0xFF334155) : const Color(0xFFE2E8F0),
                                            ),
                                          ),
                                          child: ClipRRect(
                                            borderRadius: BorderRadius.circular(8),
                                            child: Image.file(
                                              File(outPath),
                                              fit: BoxFit.contain,
                                              errorBuilder: (_, __, ___) => const SizedBox.shrink(),
                                            ),
                                          ),
                                        ),
                                      ),
                              ),
                          ],
                        ),
                      );
                    }),
                  ],
                );
              }),
            ],
          ],
        ],
      ),
    );

    final canPopDirectly = !_isProcessing || SettingsService().runInBackground;

    return PopScope(
      canPop: canPopDirectly,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) {
          if (_isProcessing && SettingsService().runInBackground) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('【${widget.plugin.name}】正在后台继续处理，完成后将发送系统通知'),
                duration: const Duration(seconds: 3),
              ),
            );
          }
          return;
        }

        final confirmExit = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('正在处理任务'),
            content: const Text(
              '当前任务尚未完成，此时返回将中止任务。是否确认返回？\n\n'
              '提示：您可以在【设置】中开启“返回后保持后台处理”。',
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
              FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('确认返回')),
            ],
          ),
        );

        if (confirmExit == true && context.mounted) {
          WindowsExtensionRunnerService.killActiveProcess();
          QuickJsBridgeService.killCurrentExecution();
          BackgroundTaskRunner.cancelActive();
          MediaEngineService.cancelActive();
          Navigator.of(context).pop();
        }
      },
      child: Scaffold(
        appBar: AppBar(
          title: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              PluginIconWidget(
                manifest: widget.plugin,
                size: 20,
                color: theme.colorScheme.primary,
              ),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  widget.plugin.name,
                  style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 17),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (widget.plugin.isDualAdaptivePlugin) ...[
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: Colors.indigo.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(4),
                    border: Border.all(color: Colors.indigo.withValues(alpha: 0.4)),
                  ),
                  child: Text(
                    Platform.isWindows ? '🚀 Win 原生极速模式' : '🦀 Android Wasm 沙箱模式',
                    style: const TextStyle(fontSize: 10, color: Colors.indigo, fontWeight: FontWeight.bold),
                  ),
                ),
              ] else if (widget.plugin.isWindowsExtension) ...[
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: Colors.blue.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(4),
                    border: Border.all(color: Colors.blue.withValues(alpha: 0.4)),
                  ),
                  child: const Text(
                    '⚡ Win 开放工坊',
                    style: TextStyle(fontSize: 10, color: Colors.blue, fontWeight: FontWeight.bold),
                  ),
                ),
              ],
              if (widget.plugin.isQuickJsPlugin) ...[
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: Colors.teal.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(4),
                    border: Border.all(color: Colors.teal.withValues(alpha: 0.4)),
                  ),
                  child: const Text(
                    '⚡ QuickJS 引擎',
                    style: TextStyle(fontSize: 10, color: Colors.teal, fontWeight: FontWeight.bold),
                  ),
                ),
              ],
              if (widget.plugin.isWasmPlugin) ...[
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: Colors.deepOrange.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(4),
                    border: Border.all(color: Colors.deepOrange.withValues(alpha: 0.4)),
                  ),
                  child: const Text(
                    '🦀 Wasm 沙箱',
                    style: TextStyle(fontSize: 10, color: Colors.deepOrange, fontWeight: FontWeight.bold),
                  ),
                ),
              ],
              if (widget.plugin.isOfficial) ...[
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: Colors.green.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(4),
                    border: Border.all(color: Colors.green.withValues(alpha: 0.4)),
                  ),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.verified_user_rounded, size: 10, color: Colors.green),
                      SizedBox(width: 3),
                      Text(
                        '官方认证',
                        style: TextStyle(fontSize: 10, color: Colors.green, fontWeight: FontWeight.bold),
                      ),
                    ],
                  ),
                ),
              ] else ...[
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: Colors.grey.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(4),
                    border: Border.all(color: Colors.grey.withValues(alpha: 0.4)),
                  ),
                  child: const Text(
                    '社区插件',
                    style: TextStyle(fontSize: 10, color: Colors.grey, fontWeight: FontWeight.bold),
                  ),
                ),
              ],
            ],
          ),
          actions: [
            IconButton(
              tooltip: '插件信息',
              icon: const Icon(Icons.info_outline),
              onPressed: () {
                showAboutDialog(
                  context: context,
                  applicationName: widget.plugin.name,
                  applicationVersion: 'v${widget.plugin.version}',
                  children: [
                    Text('作者: ${widget.plugin.author}'),
                    const SizedBox(height: 8),
                    Text(widget.plugin.description),
                  ],
                );
              },
            ),
          ],
        ),
        body: isMobile
            ? SingleChildScrollView(
                padding: const EdgeInsets.all(16),
                child: Column(
                  children: [
                    formSection,
                    const SizedBox(height: 24),
                    resultSection,
                  ],
                ),
              )
            : Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    flex: 5,
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.all(20),
                      child: formSection,
                    ),
                  ),
                  const VerticalDivider(width: 1),
                  Expanded(
                    flex: 4,
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.all(20),
                      child: resultSection,
                    ),
                  ),
                ],
              ),
      ),
    );
  }

  List<Widget> _buildDataResultCards({
    required ProcessingResult result,
    required bool isDark,
    required ThemeData theme,
  }) {
    final text = result.resultText?.trim() ?? '';
    final data = result.resultData;
    if (text.isEmpty && data == null) return [];

    final outputs = widget.plugin.outputs;

    // 模式 A: 复合输出模式 (Manifest 显式配置了 outputs 输出项，且返回的数据为 Map)
    // 宿主按 output.id 自动从 data 中提取对应子项并流式顺序排布
    if (outputs.isNotEmpty && data is Map) {
      final cards = <Widget>[];
      for (final outDef in outputs) {
        final itemData = data[outDef.id];
        if (itemData == null) continue;

        String itemText;
        if (itemData is String) {
          itemText = itemData;
        } else if (itemData is Map || itemData is List) {
          itemText = JsonEncoder.withIndent('  ').convert(itemData);
        } else {
          itemText = itemData.toString();
        }

        cards.add(
          _renderSingleResultCard(
            label: outDef.label,
            type: outDef.type,
            description: outDef.description,
            text: itemText,
            data: itemData,
            isDark: isDark,
            theme: theme,
          ),
        );
      }
      if (cards.isNotEmpty) return cards;
    }

    // 模式 B: 单项输出或未显式匹配 id 的默认回退展示
    final firstDef = outputs.isNotEmpty ? outputs.first : null;
    final outputLabel = firstDef?.label ?? '执行产出与结果数据';
    final outputType = firstDef?.type ?? (data is Map ? 'key_value_table' : 'copyable_text');
    final outputDesc = firstDef?.description;

    return [
      _renderSingleResultCard(
        label: outputLabel,
        type: outputType,
        description: outputDesc,
        text: text,
        data: data,
        isDark: isDark,
        theme: theme,
      ),
    ];
  }

  Widget _renderSingleResultCard({
    required String label,
    required String type,
    String? description,
    required String text,
    dynamic data,
    required bool isDark,
    required ThemeData theme,
  }) {
    // 拷贝文本构造
    String copyContent = text;
    if (copyContent.isEmpty && data is Map) {
      copyContent = data.entries.map((e) => '${e.key}: ${e.value}').join('\n');
    }

    final IconData iconData = switch (type) {
      'key_value_table' => Icons.table_chart_outlined,
      'markdown' => Icons.article_outlined,
      'json_tree' => Icons.schema_outlined,
      'image_compare' => Icons.compare_outlined,
      _ => Icons.data_object,
    };

    return Card(
      margin: const EdgeInsets.only(top: 8, bottom: 12),
      elevation: 0.5,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(color: isDark ? const Color(0xFF334155) : const Color(0xFFE2E8F0)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Expanded(
                  child: Row(
                    children: [
                      Icon(iconData, size: 18, color: theme.colorScheme.primary),
                      const SizedBox(width: 8),
                      Flexible(
                        child: Text(
                          label,
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 13,
                            color: isDark ? Colors.white : const Color(0xFF1E293B),
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (description != null && description.isNotEmpty) ...[
                        const SizedBox(width: 6),
                        Tooltip(
                          message: description,
                          child: Icon(
                            Icons.info_outline,
                            size: 14,
                            color: isDark ? Colors.grey[400] : Colors.grey[600],
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                if (type != 'image_compare')
                  TextButton.icon(
                    onPressed: () {
                      Clipboard.setData(ClipboardData(text: copyContent));
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text('已复制【$label】到剪贴板'),
                          duration: const Duration(seconds: 2),
                          behavior: SnackBarBehavior.floating,
                        ),
                      );
                    },
                    icon: const Icon(Icons.copy, size: 14),
                    label: const Text('一键复制', style: TextStyle(fontSize: 12)),
                    style: TextButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            if (type == 'image_compare' && data is Map) ...[
              Builder(builder: (context) {
                final before = data['before']?.toString() ?? data['src']?.toString() ?? '';
                final after = data['after']?.toString() ?? data['dst']?.toString() ?? '';
                if (before.isNotEmpty && after.isNotEmpty && File(before).existsSync() && File(after).existsSync()) {
                  return ImageCompareSliderWidget(
                    beforeImagePath: before,
                    afterImagePath: after,
                    beforeLabel: data['beforeLabel']?.toString() ?? '处理前 (Before)',
                    afterLabel: data['afterLabel']?.toString() ?? '处理后 (After)',
                  );
                }
                return Container(
                  padding: const EdgeInsets.all(12),
                  child: Text('无法加载对比图像: 路径不存在或尚未生成', style: TextStyle(color: theme.colorScheme.onSurfaceVariant, fontSize: 12)),
                );
              }),
            ] else if (type == 'key_value_table' && data is Map) ...[
              Container(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: isDark ? const Color(0xFF334155) : const Color(0xFFE2E8F0)),
                ),
                child: Column(
                  children: data.entries.map((entry) {
                    return Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                      decoration: BoxDecoration(
                        border: Border(
                          bottom: BorderSide(
                            color: isDark ? const Color(0xFF334155) : const Color(0xFFF1F5F9),
                          ),
                        ),
                      ),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          SizedBox(
                            width: 120,
                            child: Text(
                              entry.key.toString(),
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                                color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B),
                              ),
                            ),
                          ),
                          Expanded(
                            child: SelectableText(
                              entry.value?.toString() ?? '',
                              style: TextStyle(
                                fontSize: 12,
                                color: isDark ? const Color(0xFFF1F5F9) : const Color(0xFF0F172A),
                              ),
                            ),
                          ),
                        ],
                      ),
                    );
                  }).toList(),
                ),
              ),
            ] else ...[
              Container(
                constraints: const BoxConstraints(maxHeight: 280),
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: isDark ? const Color(0xFF0F172A) : const Color(0xFFF8FAFC),
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: isDark ? const Color(0xFF334155) : const Color(0xFFE2E8F0)),
                ),
                child: SingleChildScrollView(
                  child: SelectableText(
                    text,
                    style: TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 12,
                      height: 1.4,
                      color: isDark ? const Color(0xFF38BDF8) : const Color(0xFF0369A1),
                    ),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildBannerCard(PluginBannerDef banner, BuildContext context) {
    if (banner.platform == 'windows' && !Platform.isWindows) return const SizedBox.shrink();
    if (banner.platform == 'android' && !Platform.isAndroid) return const SizedBox.shrink();

    if (banner.visibleIf != null && !_evalCondition(banner.visibleIf!)) {
      return const SizedBox.shrink();
    }

    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    Color bgColor;
    Color borderColor;
    Color iconColor;
    Color textColor;
    IconData iconData;

    switch (banner.type) {
      case 'warning':
        bgColor = isDark ? const Color(0xFF78350F).withValues(alpha: 0.3) : Colors.amber.shade50;
        borderColor = isDark ? const Color(0xFFF59E0B) : Colors.amber.shade300;
        iconColor = isDark ? const Color(0xFFFCD34D) : Colors.amber.shade900;
        textColor = isDark ? const Color(0xFFFEF3C7) : const Color(0xFF78350F);
        iconData = Icons.warning_amber_rounded;
        break;
      case 'success':
        bgColor = isDark ? const Color(0xFF064E3B).withValues(alpha: 0.3) : Colors.green.shade50;
        borderColor = isDark ? const Color(0xFF10B981) : Colors.green.shade300;
        iconColor = isDark ? const Color(0xFF6EE7B7) : Colors.green.shade800;
        textColor = isDark ? const Color(0xFFD1FAE5) : const Color(0xFF065F46);
        iconData = Icons.phone_android;
        break;
      case 'tip':
        bgColor = isDark ? const Color(0xFF581C87).withValues(alpha: 0.3) : Colors.purple.shade50;
        borderColor = isDark ? const Color(0xFFA855F7) : Colors.purple.shade300;
        iconColor = isDark ? const Color(0xFFD8B4FE) : Colors.purple.shade800;
        textColor = isDark ? const Color(0xFFF3E8FF) : const Color(0xFF581C87);
        iconData = Icons.lightbulb_outline_rounded;
        break;
      case 'info':
      default:
        bgColor = isDark ? const Color(0xFF1E3A8A).withValues(alpha: 0.3) : Colors.blue.shade50;
        borderColor = isDark ? const Color(0xFF3B82F6) : Colors.blue.shade300;
        iconColor = isDark ? const Color(0xFF93C5FD) : Colors.blue.shade800;
        textColor = isDark ? const Color(0xFFDBEAFE) : const Color(0xFF1E3A8A);
        iconData = Icons.info_outline;
        break;
    }

    if (banner.icon != null) {
      switch (banner.icon) {
        case 'desktop_windows':
          iconData = Icons.desktop_windows;
          break;
        case 'phone_android':
          iconData = Icons.phone_android;
          break;
        case 'auto_fix_high':
          iconData = Icons.auto_fix_high;
          break;
        case 'table_chart_outlined':
        case 'table_chart':
          iconData = Icons.table_chart_outlined;
          break;
        case 'folder_zip_outlined':
          iconData = Icons.folder_zip_outlined;
          break;
        case 'info_outline':
          iconData = Icons.info_outline;
          break;
        case 'warning_amber_rounded':
          iconData = Icons.warning_amber_rounded;
          break;
        case 'help_outline':
          iconData = Icons.help_outline;
          break;
      }
    }

    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: borderColor),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(iconData, size: 18, color: iconColor),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              banner.message,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w500,
                color: textColor,
                height: 1.4,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildInputField(PluginInputDef input, BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final textPrimary = theme.colorScheme.onSurface;
    final textSecondary = theme.colorScheme.onSurfaceVariant;
    final inputBg = isDark ? const Color(0xFF1E293B) : Colors.white;
    final inputBorderColor = isDark ? const Color(0xFF475569) : const Color(0xFFD1D5DB);

    if (input.type == 'file_picker') {
      final currentFiles = (_formValues[input.id] is List)
          ? List<String>.from(_formValues[input.id])
          : <String>[];

      if (input.allowMultiple) {
        return Padding(
          padding: const EdgeInsets.only(bottom: 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      input.label,
                      style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: textPrimary),
                    ),
                  ),
                  if (currentFiles.isNotEmpty)
                    TextButton.icon(
                      style: TextButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                        visualDensity: VisualDensity.compact,
                      ),
                      onPressed: () {
                        setState(() {
                          _formValues[input.id] = <String>[];
                        });
                      },
                      icon: const Icon(Icons.clear_all, size: 16, color: Colors.redAccent),
                      label: const Text('清空全部', style: TextStyle(color: Colors.redAccent, fontSize: 12)),
                    ),
                ],
              ),
              const SizedBox(height: 8),
              if (input.allowFolder == false || input.id == 'archiveInput')
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: () => _pickFiles(input),
                    icon: Icon(input.isArchive == true ? Icons.folder_zip_outlined : Icons.note_add_outlined, size: 20),
                    label: Text(input.pickButtonText ?? (input.id == 'archiveInput' ? '选择压缩包 / 分卷文件 (支持多选分卷 .001/.002 等)' : '选择文件')),
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                    ),
                  ),
                )
              else
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: () => _pickFiles(input),
                        icon: const Icon(Icons.note_add_outlined, size: 18),
                        label: Text(input.pickButtonText ?? '添加文件 (多选)'),
                        style: OutlinedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: () => _pickFolder(input),
                        icon: const Icon(Icons.create_new_folder_outlined, size: 18),
                        label: const Text('添加文件夹'),
                        style: OutlinedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                        ),
                      ),
                    ),
                  ],
                ),
              if (currentFiles.isNotEmpty) ...[
                const SizedBox(height: 10),
                Container(
                  constraints: const BoxConstraints(maxHeight: 220),
                  decoration: BoxDecoration(
                    color: inputBg,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: inputBorderColor),
                  ),
                  child: ListView.separated(
                    shrinkWrap: true,
                    itemCount: currentFiles.length,
                    separatorBuilder: (_, __) => Divider(
                      height: 1,
                      color: isDark ? const Color(0xFF334155) : const Color(0xFFE2E8F0),
                    ),
                    itemBuilder: (context, index) {
                      final itemPath = currentFiles[index];
                      final isDirectory = Directory(itemPath).existsSync();
                      final itemName = p.basename(itemPath);
                      final fileExists = !isDirectory && File(itemPath).existsSync();
                      final fileSize = fileExists ? File(itemPath).lengthSync() : 0;
                      return ListTile(
                        dense: true,
                        visualDensity: VisualDensity.compact,
                        contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
                        leading: isDirectory
                            ? const Icon(Icons.folder_rounded, color: Colors.amber, size: 32)
                            : (_isImageFile(itemPath) && fileExists
                                ? ClipRRect(
                                    borderRadius: BorderRadius.circular(6),
                                    child: Image.file(
                                      File(itemPath),
                                      width: 38,
                                      height: 38,
                                      fit: BoxFit.cover,
                                      errorBuilder: (_, __, ___) => Icon(
                                        Icons.insert_drive_file_rounded,
                                        color: isDark ? const Color(0xFF60A5FA) : const Color(0xFF2563EB),
                                        size: 28,
                                      ),
                                    ),
                                  )
                                : Icon(
                                    _isAudioFile(itemPath)
                                        ? Icons.audiotrack_rounded
                                        : (_isVideoFile(itemPath)
                                            ? Icons.movie_creation_outlined
                                            : Icons.insert_drive_file_rounded),
                                    color: isDark ? const Color(0xFF60A5FA) : const Color(0xFF2563EB),
                                    size: 28,
                                  )),
                        title: Row(
                          children: [
                            Expanded(
                              child: Text(
                                itemName,
                                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: textPrimary),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            if (fileSize > 0)
                              Container(
                                margin: const EdgeInsets.only(left: 6),
                                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
                                decoration: BoxDecoration(
                                  color: inputBorderColor.withValues(alpha: 0.5),
                                  borderRadius: BorderRadius.circular(4),
                                ),
                                child: Text(
                                  DynamicToolRunnerPage.formatBytes(fileSize),
                                  style: TextStyle(fontSize: 10, color: textSecondary, fontWeight: FontWeight.bold),
                                ),
                              ),
                          ],
                        ),
                        subtitle: Text(
                          isDirectory ? '文件夹 · $itemPath' : itemPath,
                          style: TextStyle(fontSize: 11, color: textSecondary),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        trailing: IconButton(
                          icon: const Icon(Icons.close, size: 16),
                          splashRadius: 16,
                          color: textSecondary,
                          onPressed: () {
                            setState(() {
                              final list = List<String>.from(_formValues[input.id]);
                              list.removeAt(index);
                              _formValues[input.id] = list;
                            });
                          },
                        ),
                      );
                    },
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    input.selectionSummary != null
                        ? input.selectionSummary!.replaceAll('{count}', '${currentFiles.length}')
                        : (input.allowFolder == false || input.id == 'archiveInput'
                            ? '已选定 ${currentFiles.length} 项文件'
                            : (input.id.contains('archive') || widget.plugin.id.contains('archive'))
                            ? '已收纳 ${currentFiles.length} 项待压缩条目 (包含文件与文件夹)'
                            : '已选择 ${currentFiles.length} 项输入 (包含文件与文件夹)'),
                    style: TextStyle(fontSize: 12, color: textSecondary),
                  ),
                ),
              ],
            ],
          ),
        );
      }

      final currentFile = currentFiles.isNotEmpty ? currentFiles.first : null;
      return Padding(
        padding: const EdgeInsets.only(bottom: 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              input.label,
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: textPrimary),
            ),
            const SizedBox(height: 8),
            InkWell(
              onTap: () => _pickFiles(input),
              borderRadius: BorderRadius.circular(10),
              child: Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  border: Border.all(
                    color: isDark ? const Color(0xFF3B82F6) : const Color(0xFF2563EB),
                    width: 1.5,
                  ),
                  borderRadius: BorderRadius.circular(10),
                  color: isDark
                      ? const Color(0xFF1E3A8A).withValues(alpha: 0.25)
                      : const Color(0xFFEFF6FF),
                ),
                child: Row(
                  children: [
                    if (currentFile != null && _isImageFile(currentFile) && File(currentFile).existsSync())
                      ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: Image.file(
                          File(currentFile),
                          width: 48,
                          height: 48,
                          fit: BoxFit.cover,
                          errorBuilder: (_, __, ___) => Icon(
                            Icons.image_outlined,
                            color: isDark ? const Color(0xFF60A5FA) : const Color(0xFF2563EB),
                            size: 32,
                          ),
                        ),
                      )
                    else
                      Icon(
                        currentFile != null
                            ? (_isAudioFile(currentFile)
                                ? Icons.audiotrack_rounded
                                : (_isVideoFile(currentFile)
                                    ? Icons.movie_creation_outlined
                                    : Icons.insert_drive_file_rounded))
                            : Icons.cloud_upload_outlined,
                        color: isDark ? const Color(0xFF60A5FA) : const Color(0xFF2563EB),
                        size: 32,
                      ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: currentFile == null
                          ? Text(
                              input.allowedExtensions.isNotEmpty
                                  ? '点击选择文件 (支持 ${input.allowedExtensions.join('/')})'
                                  : '点击选择文件',
                              style: TextStyle(color: textSecondary, fontSize: 13),
                            )
                          : Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Expanded(
                                      child: Text(
                                        p.basename(currentFile),
                                        style: TextStyle(
                                          color: textPrimary,
                                          fontWeight: FontWeight.w600,
                                          fontSize: 13,
                                        ),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                    if (File(currentFile).existsSync())
                                      Container(
                                        margin: const EdgeInsets.only(left: 6),
                                        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
                                        decoration: BoxDecoration(
                                          color: theme.colorScheme.primary.withValues(alpha: 0.1),
                                          borderRadius: BorderRadius.circular(4),
                                        ),
                                        child: Text(
                                          DynamicToolRunnerPage.formatBytes(File(currentFile).lengthSync()),
                                          style: TextStyle(
                                            fontSize: 10,
                                            fontWeight: FontWeight.bold,
                                            color: theme.colorScheme.primary,
                                          ),
                                        ),
                                      ),
                                  ],
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  currentFile,
                                  style: TextStyle(fontSize: 11, color: textSecondary),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ],
                            ),
                    ),
                    if (currentFile != null)
                      IconButton(
                        icon: const Icon(Icons.close, size: 18),
                        splashRadius: 18,
                        onPressed: () {
                          setState(() {
                            _formValues[input.id] = <String>[];
                          });
                        },
                      ),
                  ],
                ),
              ),
            ),
            if (currentFile != null && _isImageFile(currentFile) && File(currentFile).existsSync()) ...[
              const SizedBox(height: 8),
              Container(
                constraints: const BoxConstraints(maxHeight: 160),
                decoration: BoxDecoration(
                  color: isDark ? const Color(0xFF0F172A) : const Color(0xFFF1F5F9),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: inputBorderColor),
                ),
                padding: const EdgeInsets.all(4),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: Image.file(
                    File(currentFile),
                    fit: BoxFit.contain,
                    errorBuilder: (_, __, ___) => const SizedBox.shrink(),
                  ),
                ),
              ),
            ],
            ...input.banners.map((b) => _buildBannerCard(b, context)),
          ],
        ),
      );
    } else if (input.type == 'slider') {
      final curVal = ((_formValues[input.id] ?? input.defaultValue) as num).toDouble();
      return Padding(
        padding: const EdgeInsets.only(bottom: 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  input.label,
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: textPrimary),
                ),
                Text(
                  '${curVal.toInt()}',
                  style: TextStyle(fontWeight: FontWeight.bold, color: theme.colorScheme.primary, fontSize: 15),
                ),
              ],
            ),
            Slider(
              value: curVal,
              min: input.min ?? 0.0,
              max: input.max ?? 100.0,
              divisions: input.step != null && input.step! > 0
                  ? ((input.max! - input.min!) / input.step!).round()
                  : null,
              onChanged: (val) {
                setState(() {
                  _formValues[input.id] = val.round();
                });
              },
            ),
          ],
        ),
      );
    } else if (input.type == 'select') {
      final availableOpts = input.options.where((opt) => opt.isSupportedOnCurrentPlatform()).toList();
      String? curVal = _formValues[input.id]?.toString() ?? input.defaultValue?.toString();
      if (!availableOpts.any((o) => o.value == curVal)) {
        curVal = availableOpts.isNotEmpty ? availableOpts.first.value : null;
      }
      return Padding(
        padding: const EdgeInsets.only(bottom: 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              input.label,
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: textPrimary),
            ),
            const SizedBox(height: 8),
            DropdownButtonFormField<String>(
              initialValue: curVal,
              isExpanded: true,
              dropdownColor: inputBg,
              style: TextStyle(fontSize: 14, color: textPrimary, fontWeight: FontWeight.w600),
              icon: Icon(Icons.arrow_drop_down, color: textPrimary),
              decoration: InputDecoration(
                filled: true,
                fillColor: inputBg,
                contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide(color: inputBorderColor),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide(color: inputBorderColor),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide(color: theme.colorScheme.primary, width: 1.5),
                ),
              ),
              items: availableOpts.map((opt) {
                return DropdownMenuItem<String>(
                  value: opt.value,
                  child: Text(
                    opt.label,
                    style: TextStyle(fontSize: 14, color: textPrimary, fontWeight: FontWeight.w600),
                    overflow: TextOverflow.ellipsis,
                    maxLines: 1,
                  ),
                );
              }).toList(),
              onChanged: (val) {
                setState(() {
                  _formValues[input.id] = val;
                });
              },
            ),
          ],
        ),
      );
    } else if (input.type == 'number') {
      return Padding(
        padding: const EdgeInsets.only(bottom: 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              input.label,
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: textPrimary),
            ),
            const SizedBox(height: 8),
            TextFormField(
              initialValue: (_formValues[input.id] ?? input.defaultValue)?.toString(),
              keyboardType: TextInputType.number,
              style: TextStyle(fontSize: 14, color: textPrimary, fontWeight: FontWeight.w500),
              decoration: InputDecoration(
                filled: true,
                fillColor: inputBg,
                contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide(color: inputBorderColor),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide(color: inputBorderColor),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide(color: theme.colorScheme.primary, width: 1.5),
                ),
              ),
              onChanged: (val) {
                _formValues[input.id] = int.tryParse(val) ?? val;
              },
            ),
          ],
        ),
      );
    } else if (!input.isColorInput && (input.type == 'text' || input.type == 'textarea')) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              input.label,
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: textPrimary),
            ),
            const SizedBox(height: 8),
            TextFormField(
              initialValue: (_formValues[input.id] ?? input.defaultValue)?.toString(),
              maxLines: input.type == 'textarea' ? 4 : 1,
              style: TextStyle(fontSize: 14, color: textPrimary, fontWeight: FontWeight.w500),
              decoration: InputDecoration(
                filled: true,
                fillColor: inputBg,
                hintStyle: TextStyle(color: textSecondary.withValues(alpha: 0.6)),
                contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide(color: inputBorderColor),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide(color: inputBorderColor),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide(color: theme.colorScheme.primary, width: 1.5),
                ),
                hintText: input.label,
              ),
              onChanged: (val) {
                _formValues[input.id] = val;
              },
            ),
          ],
        ),
      );
    } else if (input.type == 'switch' || input.type == 'checkbox') {
      final curVal = _formValues[input.id] == true ||
          _formValues[input.id]?.toString().toLowerCase() == 'true';
      return Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Container(
          decoration: BoxDecoration(
            color: inputBg,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: inputBorderColor),
          ),
          child: SwitchListTile(
            dense: true,
            title: Text(
              input.label,
              style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14, color: textPrimary),
            ),
            subtitle: input.description.isNotEmpty
                ? Text(input.description, style: TextStyle(fontSize: 12, color: textSecondary))
                : null,
            value: curVal,
            onChanged: (val) {
              setState(() {
                _formValues[input.id] = val;
              });
            },
          ),
        ),
      );
    } else if (input.isColorInput) {
      final curVal = (_formValues[input.id] ?? input.defaultValue ?? '#FFFFFF').toString();
      final curColor = DynamicToolRunnerPage.parseHexColor(curVal);
      final isTransparent = curVal.trim().toLowerCase() == 'transparent' || curVal.trim().toLowerCase() == 'none';

      final options = input.options;
      final List<Map<String, String>> quickIdPresets = options.isNotEmpty
          ? options.map((opt) => {'label': opt.label, 'value': opt.value.toString()}).toList()
          : const [
              {'label': '白底', 'value': '#FFFFFF'},
              {'label': '天蓝', 'value': '#438EDB'},
              {'label': '红底', 'value': '#D81E1E'},
              {'label': '轻灰', 'value': '#EEEEEE'},
              {'label': '纯黑', 'value': '#000000'},
              {'label': '透明', 'value': 'transparent'},
            ];

      const inlineSwatches = [
        '#FFFFFF', '#F1F5F9', '#94A3B8', '#1E293B',
        '#D81E1E', '#EF4444', '#F97316', '#FBBF24',
        '#16A34A', '#14B8A6', '#438EDB', '#1E40AF',
        '#6366F1', '#A855F7', '#EC4899', '#EEEEEE',
      ];

      return Padding(
        padding: const EdgeInsets.only(bottom: 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Expanded(
                  child: Row(
                    children: [
                      Text(
                        input.label,
                        style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: textPrimary),
                      ),
                      const SizedBox(width: 8),
                      // 当前颜色预览胶囊
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(
                          color: inputBg,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: inputBorderColor),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Container(
                              width: 14,
                              height: 14,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: isTransparent ? Colors.transparent : curColor,
                                border: Border.all(color: Colors.grey.shade400, width: 1),
                              ),
                              child: isTransparent
                                  ? const Icon(Icons.block, size: 10, color: Colors.red)
                                  : null,
                            ),
                            const SizedBox(width: 6),
                            Text(
                              isTransparent ? '透明' : curVal.toUpperCase(),
                              style: TextStyle(
                                fontFamily: 'monospace',
                                fontSize: 11,
                                fontWeight: FontWeight.bold,
                                color: textPrimary,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                FilledButton.tonalIcon(
                  style: FilledButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  ),
                  icon: const Icon(Icons.colorize, size: 16),
                  label: const Text('自定义', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                  onPressed: () => _showCustomColorDialog(input, curVal),
                ),
              ],
            ),
            const SizedBox(height: 8),
            // 常用证件推荐底色快捷选择
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  ...quickIdPresets.map((preset) {
                    final pVal = preset['value']!;
                    final pCol = DynamicToolRunnerPage.parseHexColor(pVal);
                    final isTrans = pVal == 'transparent';
                    final isSelected = isTrans
                        ? isTransparent
                        : (!isTransparent && curVal.replaceAll('#', '').toLowerCase() == pVal.replaceAll('#', '').toLowerCase());
                    return Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: ChoiceChip(
                        avatar: Container(
                          width: 14,
                          height: 14,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: isTrans ? Colors.transparent : pCol,
                            border: Border.all(color: Colors.grey.shade400),
                          ),
                          child: isTrans ? const Icon(Icons.block, size: 10, color: Colors.red) : null,
                        ),
                        label: Text(preset['label']!, style: const TextStyle(fontSize: 12)),
                        selected: isSelected,
                        visualDensity: VisualDensity.compact,
                        padding: EdgeInsets.zero,
                        onSelected: (_) {
                          setState(() {
                            _formValues[input.id] = pVal;
                          });
                        },
                      ),
                    );
                  }),
                ],
              ),
            ),
            const SizedBox(height: 8),
            // 精选色块阵列
            Wrap(
              spacing: 6,
              runSpacing: 6,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                ...inlineSwatches.map((hex) {
                  final isTrans = hex == 'transparent';
                  final color = DynamicToolRunnerPage.parseHexColor(hex);
                  final isSelected = isTrans
                      ? isTransparent
                      : (!isTransparent && curVal.replaceAll('#', '').toLowerCase() == hex.replaceAll('#', '').toLowerCase());
                  return Tooltip(
                    message: isTrans ? '透明' : hex,
                    child: InkWell(
                      borderRadius: BorderRadius.circular(16),
                      onTap: () {
                        setState(() {
                          _formValues[input.id] = hex;
                        });
                      },
                      child: Container(
                        width: 28,
                        height: 28,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: isTrans ? Colors.transparent : color,
                          border: Border.all(
                            color: isSelected
                                ? theme.colorScheme.primary
                                : (isTrans ? Colors.redAccent.withValues(alpha: 0.5) : Colors.grey.withValues(alpha: 0.3)),
                            width: isSelected ? 2.5 : 1,
                          ),
                        ),
                        child: isSelected
                            ? Icon(
                                Icons.check,
                                size: 16,
                                color: isTrans || color.computeLuminance() > 0.5 ? Colors.black : Colors.white,
                              )
                            : (isTrans ? const Icon(Icons.block, size: 12, color: Colors.redAccent) : null),
                      ),
                    ),
                  );
                }),
              ],
            ),
          ],
        ),
      );
    }

    return const SizedBox();
  }

  Future<void> _showCustomColorDialog(PluginInputDef input, String initialVal) async {
    final res = await showDialog<String>(
      context: context,
      builder: (ctx) => VisualColorPickerDialog(initialColorStr: initialVal),
    );

    if (res != null && mounted) {
      setState(() {
        _formValues[input.id] = res;
      });
    }
  }
}

/// 交互式专业调色盘与颜色选择器对话框
class VisualColorPickerDialog extends StatefulWidget {
  final String initialColorStr;
  const VisualColorPickerDialog({super.key, required this.initialColorStr});

  @override
  State<VisualColorPickerDialog> createState() => _VisualColorPickerDialogState();
}

class _VisualColorPickerDialogState extends State<VisualColorPickerDialog> {
  late bool _isTransparent;
  late double _hue;
  late double _saturation;
  late double _value;
  late TextEditingController _hexController;

  static const List<Map<String, dynamic>> _quickPresets = [
    {'label': '标准白底', 'value': '#FFFFFF', 'color': Color(0xFFFFFFFF)},
    {'label': '常用天蓝', 'value': '#438EDB', 'color': Color(0xFF438EDB)},
    {'label': '标准红底', 'value': '#D81E1E', 'color': Color(0xFFD81E1E)},
    {'label': '职业轻灰', 'value': '#EEEEEE', 'color': Color(0xFFEEEEEE)},
    {'label': '国徽深蓝', 'value': '#1E40AF', 'color': Color(0xFF1E40AF)},
    {'label': '经典纯黑', 'value': '#000000', 'color': Color(0xFF000000)},
    {'label': '透明底色', 'value': 'transparent', 'color': Colors.transparent},
  ];

  static const List<String> _paletteSwatches = [
    '#FFFFFF', '#F8FAFC', '#F1F5F9', '#E2E8F0', '#94A3B8', '#64748B', '#334155', '#1E293B', '#000000',
    '#FCA5A5', '#F87171', '#EF4444', '#DC2626', '#B91C1C', '#D81E1E',
    '#FDBA74', '#FB923C', '#F97316', '#EA580C', '#FDE047', '#FACC15',
    '#86EFAC', '#4ADE80', '#22C55E', '#16A34A', '#5EEAD4', '#14B8A6',
    '#67E8F9', '#38BDF8', '#0EA5E9', '#438EDB', '#3B82F6', '#1E40AF',
    '#A5B4FC', '#6366F1', '#C084FC', '#A855F7', '#9333EA',
    '#F472B6', '#EC4899', '#DB2777', '#FB7185', '#EEEEEE', 'transparent',
  ];

  @override
  void initState() {
    super.initState();
    final raw = widget.initialColorStr.trim().toLowerCase();
    _isTransparent = raw == 'transparent' || raw == 'none';
    final initialColor = DynamicToolRunnerPage.parseHexColor(widget.initialColorStr);
    final hsv = HSVColor.fromColor(initialColor);
    _hue = hsv.hue;
    _saturation = hsv.saturation;
    _value = hsv.value.clamp(0.05, 1.0);
    _hexController = TextEditingController(text: _isTransparent ? 'transparent' : _colorToHex(initialColor));
  }

  @override
  void dispose() {
    _hexController.dispose();
    super.dispose();
  }

  Color get _currentColor {
    if (_isTransparent) return Colors.transparent;
    return HSVColor.fromAHSV(1.0, _hue, _saturation, _value).toColor();
  }

  String _colorToHex(Color color) {
    final r = color.red.toRadixString(16).padLeft(2, '0').toUpperCase();
    final g = color.green.toRadixString(16).padLeft(2, '0').toUpperCase();
    final b = color.blue.toRadixString(16).padLeft(2, '0').toUpperCase();
    return '#$r$g$b';
  }

  void _applyColor(Color color, {bool isTrans = false}) {
    setState(() {
      _isTransparent = isTrans;
      if (!isTrans) {
        final hsv = HSVColor.fromColor(color);
        _hue = hsv.hue;
        _saturation = hsv.saturation;
        _value = hsv.value.clamp(0.05, 1.0);
        _hexController.text = _colorToHex(color);
      } else {
        _hexController.text = 'transparent';
      }
    });
  }

  void _onHexInput(String val) {
    final clean = val.trim().toLowerCase();
    if (clean == 'transparent' || clean == 'none') {
      setState(() {
        _isTransparent = true;
      });
      return;
    }
    final color = DynamicToolRunnerPage.parseHexColor(val);
    final hsv = HSVColor.fromColor(color);
    setState(() {
      _isTransparent = false;
      _hue = hsv.hue;
      _saturation = hsv.saturation;
      _value = hsv.value.clamp(0.05, 1.0);
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final curColor = _currentColor;
    final curHex = _isTransparent ? 'transparent' : _colorToHex(curColor);

    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      backgroundColor: isDark ? const Color(0xFF0F172A) : Colors.white,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480, maxHeight: 680),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // 标题栏
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Row(
                    children: [
                      Icon(Icons.palette_outlined, color: theme.colorScheme.primary, size: 22),
                      const SizedBox(width: 8),
                      const Text(
                        '专业调色盘与颜色选择器',
                        style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                      ),
                    ],
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, size: 20),
                    splashRadius: 20,
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
              const SizedBox(height: 14),

              Expanded(
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // 1. 实时预览条
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: isDark ? const Color(0xFF1E293B) : const Color(0xFFF8FAFC),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: isDark ? const Color(0xFF334155) : const Color(0xFFE2E8F0)),
                        ),
                        child: Row(
                          children: [
                            Container(
                              width: 52,
                              height: 52,
                              decoration: BoxDecoration(
                                color: _isTransparent ? Colors.transparent : curColor,
                                borderRadius: BorderRadius.circular(10),
                                border: Border.all(color: Colors.grey.shade400, width: 1.5),
                              ),
                              child: _isTransparent
                                  ? const Icon(Icons.block, color: Colors.red, size: 28)
                                  : null,
                            ),
                            const SizedBox(width: 14),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    _isTransparent ? '透明背景 (Transparent)' : curHex,
                                    style: TextStyle(
                                      fontFamily: 'monospace',
                                      fontSize: 16,
                                      fontWeight: FontWeight.bold,
                                      color: isDark ? Colors.white : const Color(0xFF0F172A),
                                    ),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    _isTransparent
                                        ? 'Alpha: 0 (无底色)'
                                        : 'RGB(${curColor.red}, ${curColor.green}, ${curColor.blue})',
                                    style: TextStyle(fontSize: 12, color: Colors.grey.shade500),
                                  ),
                                ],
                              ),
                            ),
                            ActionChip(
                              label: Text(_isTransparent ? '切回纯色' : '设为透明', style: const TextStyle(fontSize: 12)),
                              avatar: Icon(_isTransparent ? Icons.color_lens_outlined : Icons.block, size: 14),
                              onPressed: () {
                                if (_isTransparent) {
                                  _applyColor(const Color(0xFFFFFFFF));
                                } else {
                                  _applyColor(Colors.transparent, isTrans: true);
                                }
                              },
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 16),

                      // 2. 证件照标准推荐色
                      const Text(
                        '证件照标准推荐底色',
                        style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: _quickPresets.map((p) {
                          final pVal = p['value'].toString();
                          final pCol = p['color'] as Color;
                          final isTrans = pVal == 'transparent';
                          final isSelected = isTrans
                              ? _isTransparent
                              : (!_isTransparent && curHex.toLowerCase() == pVal.toLowerCase());
                          return ChoiceChip(
                            label: Text(p['label'] as String, style: const TextStyle(fontSize: 12)),
                            avatar: Container(
                              width: 14,
                              height: 14,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: isTrans ? Colors.transparent : pCol,
                                border: Border.all(color: Colors.grey.shade400),
                              ),
                              child: isTrans ? const Icon(Icons.block, size: 10, color: Colors.red) : null,
                            ),
                            selected: isSelected,
                            onSelected: (_) => _applyColor(pCol, isTrans: isTrans),
                          );
                        }).toList(),
                      ),
                      const SizedBox(height: 16),

                      // 3. 滑块微调 (Hue, Saturation, Value)
                      const Text(
                        '色彩空间实时微调',
                        style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: 10),
                      // 色相 (Hue)
                      Row(
                        children: [
                          const SizedBox(width: 48, child: Text('色相', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600))),
                          Expanded(
                            child: Container(
                              height: 20,
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(10),
                                gradient: const LinearGradient(
                                  colors: [
                                    Color(0xFFFF0000),
                                    Color(0xFFFFFF00),
                                    Color(0xFF00FF00),
                                    Color(0xFF00FFFF),
                                    Color(0xFF0000FF),
                                    Color(0xFFFF00FF),
                                    Color(0xFFFF0000),
                                  ],
                                ),
                              ),
                              child: SliderTheme(
                                data: SliderTheme.of(context).copyWith(
                                  trackHeight: 20,
                                  activeTrackColor: Colors.transparent,
                                  inactiveTrackColor: Colors.transparent,
                                  thumbColor: Colors.white,
                                  thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 10),
                                  overlayShape: const RoundSliderOverlayShape(overlayRadius: 0),
                                ),
                                child: Slider(
                                  value: _hue,
                                  min: 0.0,
                                  max: 360.0,
                                  onChanged: (v) {
                                    setState(() {
                                      _isTransparent = false;
                                      _hue = v;
                                      _hexController.text = _colorToHex(_currentColor);
                                    });
                                  },
                                ),
                              ),
                            ),
                          ),
                          SizedBox(width: 48, child: Text('${_hue.round()}°', textAlign: TextAlign.right, style: const TextStyle(fontSize: 11, fontFamily: 'monospace'))),
                        ],
                      ),
                      const SizedBox(height: 10),

                      // 饱和度 (Saturation)
                      Row(
                        children: [
                          const SizedBox(width: 48, child: Text('饱和度', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600))),
                          Expanded(
                            child: Slider(
                              value: _saturation,
                              min: 0.0,
                              max: 1.0,
                              onChanged: (v) {
                                setState(() {
                                  _isTransparent = false;
                                  _saturation = v;
                                  _hexController.text = _colorToHex(_currentColor);
                                });
                              },
                            ),
                          ),
                          SizedBox(width: 48, child: Text('${(_saturation * 100).round()}%', textAlign: TextAlign.right, style: const TextStyle(fontSize: 11, fontFamily: 'monospace'))),
                        ],
                      ),
                      const SizedBox(height: 6),

                      // 明度 (Value / Brightness)
                      Row(
                        children: [
                          const SizedBox(width: 48, child: Text('明度', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600))),
                          Expanded(
                            child: Slider(
                              value: _value,
                              min: 0.0,
                              max: 1.0,
                              onChanged: (v) {
                                setState(() {
                                  _isTransparent = false;
                                  _value = v;
                                  _hexController.text = _colorToHex(_currentColor);
                                });
                              },
                            ),
                          ),
                          SizedBox(width: 48, child: Text('${(_value * 100).round()}%', textAlign: TextAlign.right, style: const TextStyle(fontSize: 11, fontFamily: 'monospace'))),
                        ],
                      ),
                      const SizedBox(height: 16),

                      // 4. 丰富色板网格
                      const Text(
                        '快速精选色彩矩阵',
                        style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: _paletteSwatches.map((swatchHex) {
                          final isTrans = swatchHex == 'transparent';
                          final swatchCol = DynamicToolRunnerPage.parseHexColor(swatchHex);
                          final isSelected = isTrans
                              ? _isTransparent
                              : (!_isTransparent && curHex.toLowerCase() == swatchHex.toLowerCase());
                          return Tooltip(
                            message: isTrans ? '透明' : swatchHex,
                            child: InkWell(
                              borderRadius: BorderRadius.circular(16),
                              onTap: () => _applyColor(swatchCol, isTrans: isTrans),
                              child: Container(
                                width: 28,
                                height: 28,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: isTrans ? Colors.transparent : swatchCol,
                                  border: Border.all(
                                    color: isSelected ? theme.colorScheme.primary : Colors.grey.withValues(alpha: 0.35),
                                    width: isSelected ? 2.5 : 1,
                                  ),
                                ),
                                child: isSelected
                                    ? Icon(
                                        Icons.check,
                                        size: 16,
                                        color: isTrans || swatchCol.computeLuminance() > 0.5 ? Colors.black : Colors.white,
                                      )
                                    : (isTrans ? const Icon(Icons.block, size: 12, color: Colors.red) : null),
                              ),
                            ),
                          );
                        }).toList(),
                      ),
                      const SizedBox(height: 16),

                      // 5. 手动代码输入
                      Row(
                        children: [
                          Expanded(
                            child: TextField(
                              controller: _hexController,
                              decoration: InputDecoration(
                                labelText: '十六进制代码 (Hex)',
                                hintText: '如 #438EDB 或 transparent',
                                border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                                contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                                isDense: true,
                              ),
                              onChanged: _onHexInput,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),

              const SizedBox(height: 14),
              // 底部确认与取消
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('取消'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton.icon(
                    icon: const Icon(Icons.check, size: 16),
                    label: const Text('确认应用'),
                    onPressed: () {
                      final resultStr = _isTransparent ? 'transparent' : _colorToHex(_currentColor);
                      Navigator.pop(context, resultStr);
                    },
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Before / After 交互式图片滑动对比组件
class ImageCompareSliderWidget extends StatefulWidget {
  final String beforeImagePath;
  final String afterImagePath;
  final String beforeLabel;
  final String afterLabel;

  const ImageCompareSliderWidget({
    super.key,
    required this.beforeImagePath,
    required this.afterImagePath,
    this.beforeLabel = '处理前 (Before)',
    this.afterLabel = '处理后 (After)',
  });

  @override
  State<ImageCompareSliderWidget> createState() => _ImageCompareSliderWidgetState();
}

class _ImageCompareSliderWidgetState extends State<ImageCompareSliderWidget> {
  double _sliderPosition = 0.5;

  @override
  Widget build(BuildContext context) {
    final beforeFile = File(widget.beforeImagePath);
    final afterFile = File(widget.afterImagePath);

    if (!beforeFile.existsSync() || !afterFile.existsSync()) {
      return Container(
        height: 120,
        alignment: Alignment.center,
        child: const Text('图像文件未找到，无法生成对比', style: TextStyle(color: Colors.grey, fontSize: 12)),
      );
    }

    final isDark = Theme.of(context).brightness == Brightness.dark;

    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth > 0 ? constraints.maxWidth : 300.0;
        const height = 260.0;

        return ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: Container(
            height: height,
            decoration: BoxDecoration(
              color: isDark ? const Color(0xFF0F172A) : const Color(0xFFF1F5F9),
              border: Border.all(color: isDark ? const Color(0xFF334155) : const Color(0xFFE2E8F0)),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Stack(
              children: [
                // 1. 底层：处理后的完整图片 (After)
                Positioned.fill(
                  child: Image.file(
                    afterFile,
                    fit: BoxFit.contain,
                  ),
                ),

                // 2. 顶层：处理前的图片 (Before)，使用 ClipRect 裁剪只显示左侧
                Positioned.fill(
                  child: ClipRect(
                    clipper: HorizontalRectClipper(_sliderPosition),
                    child: Image.file(
                      beforeFile,
                      fit: BoxFit.contain,
                    ),
                  ),
                ),

                // 3. 标签
                Positioned(
                  left: 10,
                  top: 10,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.65),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      widget.beforeLabel,
                      style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold),
                    ),
                  ),
                ),
                Positioned(
                  right: 10,
                  top: 10,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.65),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      widget.afterLabel,
                      style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold),
                    ),
                  ),
                ),

                // 4. 分割线
                Positioned(
                  left: width * _sliderPosition - 1,
                  top: 0,
                  bottom: 0,
                  child: Container(
                    width: 2,
                    color: Colors.white,
                  ),
                ),

                // 5. 滑动手柄
                Positioned(
                  left: width * _sliderPosition - 16,
                  top: height / 2 - 16,
                  child: Container(
                    width: 32,
                    height: 32,
                    decoration: BoxDecoration(
                      color: Colors.white,
                      shape: BoxShape.circle,
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.3),
                          blurRadius: 4,
                          offset: const Offset(0, 2),
                        ),
                      ],
                    ),
                    child: const Icon(Icons.compare_arrows, size: 20, color: Colors.blueAccent),
                  ),
                ),

                // 6. 全局横向拖动手势监听
                Positioned.fill(
                  child: GestureDetector(
                    behavior: HitTestBehavior.translucent,
                    onHorizontalDragUpdate: (details) {
                      setState(() {
                        _sliderPosition = (details.localPosition.dx / width).clamp(0.0, 1.0);
                      });
                    },
                    onTapDown: (details) {
                      setState(() {
                        _sliderPosition = (details.localPosition.dx / width).clamp(0.0, 1.0);
                      });
                    },
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class HorizontalRectClipper extends CustomClipper<Rect> {
  final double fraction;
  HorizontalRectClipper(this.fraction);

  @override
  Rect getClip(Size size) {
    return Rect.fromLTWH(0, 0, size.width * fraction, size.height);
  }

  @override
  bool shouldReclip(HorizontalRectClipper oldClipper) => oldClipper.fraction != fraction;
}
