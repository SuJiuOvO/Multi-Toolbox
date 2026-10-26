import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
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

class DynamicToolRunnerPage extends StatefulWidget {
  final PluginManifest plugin;

  const DynamicToolRunnerPage({super.key, required this.plugin});

  @override
  State<DynamicToolRunnerPage> createState() => _DynamicToolRunnerPageState();
}

class _DynamicToolRunnerPageState extends State<DynamicToolRunnerPage> {
  final Map<String, dynamic> _formValues = {};
  bool _isProcessing = false;
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
      }
    }
  }

  Future<void> _pickFiles(PluginInputDef input) async {
    // 安卓端 SAF 文件选择器对 .001 / .z01 / .r00 等分卷扩展名缺乏系统 MIME 映射。
    // 当在安卓端选取解压包或允许的扩展名包含分卷后缀时，强制使用 FileType.any，确保 SAF 不会置灰分卷文件
    final bool isAndroidArchivePicker = Platform.isAndroid &&
        (input.id == 'archiveInput' ||
            input.allowedExtensions.any((e) =>
                ['001', 'z01', 'r00', 'part1', 'part01'].contains(e.toLowerCase())));

    final pickerType = (input.allowedExtensions.isNotEmpty && !isAndroidArchivePicker)
        ? FileType.custom
        : FileType.any;
    final pickerExts = (input.allowedExtensions.isNotEmpty && !isAndroidArchivePicker)
        ? input.allowedExtensions
        : null;

    final res = await FilePicker.platform.pickFiles(
      allowMultiple: input.allowMultiple,
      type: pickerType,
      allowedExtensions: pickerExts,
      lockParentWindow: true,
    );

    if (res != null && res.paths.isNotEmpty) {
      final picked = res.paths.whereType<String>().toList();

      // 前置格式强校验拦截：若选择 CAD 时选中了 DWG 或 DWF，直接弹窗指导并拒绝，绝不生成假 PDF
      if (input.id == 'cadInput' && picked.any((f) {
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
    if (Platform.isAndroid && widget.plugin.id == 'universal-archive-extractor') {
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
            content: const Text(
              '压缩与解压模块需要读写设备公共存储区域的文件与文件夹。\n\n为确保真机环境下能正常扫描文件夹并输出压缩包，建议开启【允许管理所有文件】权限。',
              style: TextStyle(fontSize: 14, height: 1.5),
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

    setState(() {
      _isProcessing = true;
      _progress = 0.0;
      _statusText = '准备开始处理...';
      _result = null;
      _terminalLogs.clear();
    });

    Directory? baseDir;
    if (Platform.isWindows) {
      baseDir = await getDownloadsDirectory();
    } else if (Platform.isAndroid) {
      final pubDownload = Directory('/storage/emulated/0/Download');
      if (pubDownload.existsSync()) {
        baseDir = pubDownload;
      } else {
        baseDir = await getExternalStorageDirectory();
      }
    }
    baseDir ??= await getApplicationDocumentsDirectory();

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
      if (_formValues[fileInput.id] is List) {
        effectiveInputFiles.addAll(List<String>.from(_formValues[fileInput.id]));
      }
    }

    final ProcessingResult res;
    if (widget.plugin.isWindowsExtension || widget.plugin.nativeRunner != null) {
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
    } else if (widget.plugin.isQuickJsPlugin) {
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
    } else {
      res = await BackgroundTaskRunner.execute(
        handler: widget.plugin.action?.handler ?? (widget.plugin.isWasmPlugin ? 'wasm_universal' : 'image_compress'),
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
    }

    // 发送任务处理完成系统通知（即使用户已退回主界面或将 App 放至后台）
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
    final isMobile = MediaQuery.of(context).size.width < 768;

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
        if (widget.plugin.id == 'doc-converter') ...[
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: isDark
                  ? (Platform.isWindows ? const Color(0xFF1E3A8A).withValues(alpha: 0.3) : const Color(0xFF064E3B).withValues(alpha: 0.3))
                  : (Platform.isWindows ? Colors.blue.shade50 : Colors.green.shade50),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: isDark
                    ? (Platform.isWindows ? const Color(0xFF3B82F6) : const Color(0xFF10B981))
                    : (Platform.isWindows ? Colors.blue.shade300 : Colors.green.shade300),
              ),
            ),
            child: Row(
              children: [
                Icon(
                  Platform.isWindows ? Icons.desktop_windows : Icons.phone_android,
                  size: 18,
                  color: isDark
                      ? (Platform.isWindows ? const Color(0xFF93C5FD) : const Color(0xFF6EE7B7))
                      : (Platform.isWindows ? Colors.blue.shade900 : Colors.green.shade900),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    Platform.isWindows
                        ? '🪟 Windows 运行环境：PPT/Word/Excel 转 PDF 需电脑安装 Microsoft Office（PowerPoint、Word、Excel）或 WPS Office，转换可达 100% 格式无损。'
                        : '🤖 Android 运行环境：Excel 支持【原生 WPS/Office 导出】与【本地离线轻量转换】；PPT 与 Word 调起手机 WPS 或 Office 导出，跳转前将显示详细操作指引。',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                      color: isDark
                          ? (Platform.isWindows ? const Color(0xFFDBEAFE) : const Color(0xFFD1FAE5))
                          : (Platform.isWindows ? const Color(0xFF1E3A8A) : const Color(0xFF065F46)),
                    ),
                  ),
                ),
              ],
            ),
          ),
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
              ..._result!.outputFiles.map((outPath) {
                final isImg = outPath.endsWith('.jpg') ||
                    outPath.endsWith('.png') ||
                    outPath.endsWith('.webp');
                return Card(
                  margin: const EdgeInsets.only(bottom: 8),
                  elevation: 1,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                    side: BorderSide(color: isDark ? const Color(0xFF334155) : const Color(0xFFE5E7EB)),
                  ),
                  child: ListTile(
                    onTap: () => _openFile(outPath),
                    dense: true,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
                    leading: isImg
                        ? ClipRRect(
                            borderRadius: BorderRadius.circular(4),
                            child: Image.file(
                              File(outPath),
                              width: 44,
                              height: 44,
                              fit: BoxFit.cover,
                            ),
                          )
                        : Icon(Icons.insert_drive_file, color: theme.colorScheme.primary),
                    title: Text(
                      p.basename(outPath),
                      style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: textPrimary),
                    ),
                    subtitle: Text(
                      outPath,
                      style: TextStyle(fontSize: 11, color: textSecondary),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
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
              if (widget.plugin.isWindowsExtension) ...[
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

  Widget _buildInputField(PluginInputDef input, BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final textPrimary = theme.colorScheme.onSurface;
    final textSecondary = theme.colorScheme.onSurfaceVariant;
    final inputBg = isDark ? const Color(0xFF1E293B) : Colors.white;
    final inputBorderColor = isDark ? const Color(0xFF475569) : const Color(0xFFD1D5DB);

    final curSubTool = _formValues['subTool']?.toString() ?? '';
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
              if (input.id == 'archiveInput')
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: () => _pickFiles(input),
                    icon: const Icon(Icons.folder_zip_outlined, size: 20),
                    label: const Text('选择压缩包 / 分卷文件 (支持多选分卷 .001/.002 等)'),
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
                        label: const Text('添加文件 (多选)'),
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
                      return ListTile(
                        dense: true,
                        visualDensity: VisualDensity.compact,
                        leading: Icon(
                          isDirectory ? Icons.folder_rounded : Icons.insert_drive_file_rounded,
                          color: isDirectory ? Colors.amber : (isDark ? const Color(0xFF60A5FA) : const Color(0xFF2563EB)),
                          size: 22,
                        ),
                        title: Text(
                          itemName,
                          style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: textPrimary),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
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
                    input.id == 'archiveInput'
                        ? '已选定 ${currentFiles.length} 个分卷/归档文件'
                        : '已收纳 ${currentFiles.length} 项待压缩条目 (包含文件与文件夹)',
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
                    Icon(
                      currentFile != null ? Icons.folder_zip_rounded : Icons.cloud_upload_outlined,
                      color: isDark ? const Color(0xFF60A5FA) : const Color(0xFF2563EB),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        currentFile == null
                            ? (input.allowedExtensions.isNotEmpty
                                ? '点击选择文件 (支持 ${input.allowedExtensions.join('/')})'
                                : '点击选择文件')
                            : '已选择: ${p.basename(currentFile)}',
                        style: TextStyle(
                          color: currentFile == null ? textSecondary : textPrimary,
                          fontWeight: currentFile == null ? FontWeight.normal : FontWeight.w600,
                          fontSize: 13,
                        ),
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
            if (input.id == 'cadInput') ...[
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                decoration: BoxDecoration(
                  color: isDark ? const Color(0xFF78350F).withValues(alpha: 0.3) : Colors.amber.shade50,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: isDark ? const Color(0xFFF59E0B) : Colors.amber.shade300,
                  ),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.info_outline, size: 18, color: isDark ? const Color(0xFFFCD34D) : Colors.amber.shade900),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '💡 格式说明：DWG / DWF 为 Autodesk 专有二进制加密格式，无法直接无损解码。请在 AutoCAD / 中望CAD / 浩辰CAD 中使用快捷命令【DXFOUT】或【另存为 -> AutoCAD DXF (*.dxf)】，本工具支持 DXF 100% 全矢量无损转换！',
                        style: TextStyle(
                          fontSize: 12,
                          color: isDark ? const Color(0xFFFEF3C7) : const Color(0xFF78350F),
                          height: 1.4,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
            if (Platform.isWindows && (input.id == 'pptxToPdfInput' || input.id == 'docxInput' || input.id == 'excelInput')) ...[
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                decoration: BoxDecoration(
                  color: isDark ? const Color(0xFF1E3A8A).withValues(alpha: 0.3) : Colors.blue.shade50,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: isDark ? const Color(0xFF3B82F6) : Colors.blue.shade300,
                  ),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.desktop_windows, size: 18, color: isDark ? const Color(0xFF93C5FD) : Colors.blue.shade800),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '💡 Windows 提示：本功能需电脑安装 Microsoft Office（PowerPoint、Word、Excel）或 WPS 工具。转换时将调用电脑本地原生办公套件进行 100% 格式无损导出为 PDF。',
                        style: TextStyle(
                          fontSize: 12,
                          color: isDark ? const Color(0xFFDBEAFE) : const Color(0xFF1E3A8A),
                          height: 1.4,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
            if (Platform.isAndroid && (input.id == 'pptxToPdfInput' || input.id == 'docxInput' || (input.id == 'excelInput' && curSubTool == 'excel_to_pdf_android_office') || (input.id == 'pptInput' && curSubTool == 'pptx_to_images_android_office') || (input.id == 'pdfToDocxInput' && curSubTool == 'pdf_to_docx_android_office'))) ...[
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                decoration: BoxDecoration(
                  color: isDark ? const Color(0xFF064E3B).withValues(alpha: 0.3) : Colors.green.shade50,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: isDark ? const Color(0xFF10B981) : Colors.green.shade300,
                  ),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.phone_android, size: 18, color: isDark ? const Color(0xFF6EE7B7) : Colors.green.shade800),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '💡 Android 官方高保真导出指引：将为您一键调用手机已安装的【WPS Office】或【Microsoft Office】导出。执行前将显示操作步骤与 WPS 会员权限说明。',
                        style: TextStyle(
                          fontSize: 12,
                          color: isDark ? const Color(0xFFD1FAE5) : const Color(0xFF065F46),
                          height: 1.4,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
            if (Platform.isAndroid && input.id == 'pdfToDocxInput' && curSubTool == 'pdf_to_docx_android_light') ...[
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                decoration: BoxDecoration(
                  color: isDark ? const Color(0xFF1E3A8A).withValues(alpha: 0.3) : Colors.blue.shade50,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: isDark ? const Color(0xFF3B82F6) : Colors.blue.shade300,
                  ),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.auto_fix_high, size: 18, color: isDark ? const Color(0xFF93C5FD) : Colors.blue.shade800),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '💡 本地离线智能排版引擎：无需第三方办公软件或 VIP 会员，直接在本地解析 PDF 文本，消除乱空格、修复折行断句，按中文排版规范生成含两字符首行缩进与 A4 版式的可编辑 Word 文档。',
                        style: TextStyle(
                          fontSize: 12,
                          color: isDark ? const Color(0xFFDBEAFE) : const Color(0xFF1E3A8A),
                          height: 1.4,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
            if (Platform.isAndroid && input.id == 'excelInput' && (curSubTool == 'excel_to_pdf_android_light' || curSubTool == 'excel_to_pdf_android')) ...[
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                decoration: BoxDecoration(
                  color: isDark ? const Color(0xFF1E3A8A).withValues(alpha: 0.3) : Colors.blue.shade50,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: isDark ? const Color(0xFF3B82F6) : Colors.blue.shade300,
                  ),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.table_chart_outlined, size: 18, color: isDark ? const Color(0xFF93C5FD) : Colors.blue.shade800),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '💡 纯本地轻量离线生成：无需依赖第三方办公软件，直接在本地解析 Excel 工作表数据，自动计算列宽并生成标准 A4 表格 PDF。',
                        style: TextStyle(
                          fontSize: 12,
                          color: isDark ? const Color(0xFFDBEAFE) : const Color(0xFF1E3A8A),
                          height: 1.4,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
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
    } else if (input.type == 'text' || input.type == 'textarea') {
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
    }

    return const SizedBox();
  }
}
