import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:open_filex/open_filex.dart';
import '../models/plugin_manifest.dart';
import '../services/tool_engine_service.dart';
import '../services/android_office_bridge.dart';

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
    final res = await FilePicker.platform.pickFiles(
      allowMultiple: input.allowMultiple,
      type: input.allowedExtensions.isNotEmpty ? FileType.custom : FileType.any,
      allowedExtensions: input.allowedExtensions.isNotEmpty ? input.allowedExtensions : null,
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
        _formValues[input.id] = picked;
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

    final res = await ToolEngineService.execute(
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
    );

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
    final isMobile = MediaQuery.of(context).size.width < 768;

    final formSection = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: theme.colorScheme.primaryContainer.withValues(alpha: 0.4),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Row(
            children: [
              Icon(Icons.tips_and_updates, size: 20, color: theme.colorScheme.primary),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  widget.plugin.description,
                  style: theme.textTheme.bodyMedium?.copyWith(fontSize: 13),
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
              color: Platform.isWindows ? Colors.blue.shade50 : Colors.green.shade50,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: Platform.isWindows ? Colors.blue.shade200 : Colors.green.shade200,
              ),
            ),
            child: Row(
              children: [
                Icon(
                  Platform.isWindows ? Icons.desktop_windows : Icons.phone_android,
                  size: 18,
                  color: Platform.isWindows ? Colors.blue.shade800 : Colors.green.shade800,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    Platform.isWindows
                        ? '🪟 Windows 运行环境：PPT/Word/Excel 转 PDF 需电脑安装 Microsoft Office（PowerPoint、Word、Excel）或 WPS Office，转换可达 100% 格式无损。'
                        : '🤖 Android 运行环境：Excel 支持【原生 WPS/Office 导出】与【本地离线轻量转换】；PPT 与 Word 调起手机 WPS 或 Office 导出，跳转前将显示详细操作指引。',
                    style: TextStyle(
                      fontSize: 12,
                      color: Platform.isWindows ? Colors.blue.shade900 : Colors.green.shade900,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
        ],
        ...widget.plugin.inputs.where(_isInputVisible).map((input) => _buildInputField(input)),
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
          LinearProgressIndicator(value: _progress > 0 ? _progress : null),
          const SizedBox(height: 6),
          Text(_statusText, style: const TextStyle(color: Colors.grey, fontSize: 12)),
        ],
      ],
    );

    final resultSection = Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
        borderRadius: BorderRadius.circular(12),
      ),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '输出结果面板',
            style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600, fontSize: 15),
          ),
          const SizedBox(height: 12),
          if (_result == null)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 24),
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.output, size: 40, color: Colors.grey),
                    SizedBox(height: 8),
                    Text('选择文件并配置参数后点击开始', style: TextStyle(color: Colors.grey, fontSize: 13)),
                  ],
                ),
              ),
            )
          else ...[
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: _result!.success
                    ? Colors.green.withValues(alpha: 0.15)
                    : Colors.red.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    _result!.success ? Icons.check_circle : Icons.error,
                    size: 20,
                    color: _result!.success ? Colors.green : Colors.red,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _result!.message,
                      style: const TextStyle(fontSize: 13),
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
                    style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
                  ),
                  Text(
                    '点击直接打开',
                    style: TextStyle(fontSize: 12, color: theme.colorScheme.primary),
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
                  elevation: 0.5,
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
                        : const Icon(Icons.insert_drive_file, color: Colors.blueAccent),
                    title: Text(
                      p.basename(outPath),
                      style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
                    ),
                    subtitle: Text(
                      outPath,
                      style: const TextStyle(fontSize: 11, color: Colors.grey),
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

    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.plugin.name,
          style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 17),
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
    );
  }

  Widget _buildInputField(PluginInputDef input) {
    final curSubTool = _formValues['subTool']?.toString() ?? '';
    if (input.type == 'file_picker') {
      final currentFiles = (_formValues[input.id] is List)
          ? List<String>.from(_formValues[input.id])
          : <String>[];
      return Padding(
        padding: const EdgeInsets.only(bottom: 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              input.label,
              style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
            ),
            const SizedBox(height: 8),
            InkWell(
              onTap: () => _pickFiles(input),
              borderRadius: BorderRadius.circular(10),
              child: Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.blueAccent.withValues(alpha: 0.6)),
                  borderRadius: BorderRadius.circular(10),
                  color: Colors.blue.withValues(alpha: 0.04),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.cloud_upload_outlined, color: Colors.blueAccent),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        currentFiles.isEmpty
                            ? '点击选择文件 (支持 ${input.allowedExtensions.join('/')})'
                            : '已选择 ${currentFiles.length} 个文件:\n${currentFiles.map((f) => p.basename(f)).take(2).join(', ')}${currentFiles.length > 2 ? " 等..." : ""}',
                        style: TextStyle(
                          color: currentFiles.isEmpty ? Colors.grey : Colors.black87,
                          fontSize: 13,
                        ),
                      ),
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
                  color: Colors.amber.shade50,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.amber.shade200),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.info_outline, size: 18, color: Colors.amber.shade900),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '💡 格式说明：DWG / DWF 为 Autodesk 专有二进制加密格式，无法直接无损解码。请在 AutoCAD / 中望CAD / 浩辰CAD 中使用快捷命令【DXFOUT】或【另存为 -> AutoCAD DXF (*.dxf)】，本工具支持 DXF 100% 全矢量无损转换！',
                        style: TextStyle(fontSize: 12, color: Colors.amber.shade900, height: 1.4),
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
                  color: Colors.blue.shade50,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.blue.shade200),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.desktop_windows, size: 18, color: Colors.blue.shade800),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '💡 Windows 提示：本功能需电脑安装 Microsoft Office（PowerPoint、Word、Excel）或 WPS 工具。转换时将调用电脑本地原生办公套件进行 100% 格式无损导出为 PDF。',
                        style: TextStyle(fontSize: 12, color: Colors.blue.shade900, height: 1.4),
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
                  color: Colors.green.shade50,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.green.shade200),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.phone_android, size: 18, color: Colors.green.shade800),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '💡 Android 官方高保真导出指引：将为您一键调用手机已安装的【WPS Office】或【Microsoft Office】导出。执行前将显示操作步骤与 WPS 会员权限说明。',
                        style: TextStyle(fontSize: 12, color: Colors.green.shade900, height: 1.4),
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
                  color: Colors.blue.shade50,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.blue.shade200),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.auto_fix_high, size: 18, color: Colors.blue.shade800),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '💡 本地离线智能排版引擎：无需第三方办公软件或 VIP 会员，直接在本地解析 PDF 文本，消除乱空格、修复折行断句，按中文排版规范生成含两字符首行缩进与 A4 版式的可编辑 Word 文档。',
                        style: TextStyle(fontSize: 12, color: Colors.blue.shade900, height: 1.4),
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
                  color: Colors.blue.shade50,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.blue.shade200),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.table_chart_outlined, size: 18, color: Colors.blue.shade800),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '💡 纯本地轻量离线生成：无需依赖第三方办公软件，直接在本地解析 Excel 工作表数据，自动计算列宽并生成标准 A4 表格 PDF。',
                        style: TextStyle(fontSize: 12, color: Colors.blue.shade900, height: 1.4),
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
                  style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
                ),
                Text(
                  '${curVal.toInt()}',
                  style: const TextStyle(fontWeight: FontWeight.w600, color: Colors.blueAccent),
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
              style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
            ),
            const SizedBox(height: 8),
            DropdownButtonFormField<String>(
              initialValue: curVal,
              isExpanded: true,
              decoration: InputDecoration(
                contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
              ),
              items: availableOpts.map((opt) {
                return DropdownMenuItem<String>(
                  value: opt.value,
                  child: Text(
                    opt.label,
                    style: const TextStyle(fontSize: 14),
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
              style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
            ),
            const SizedBox(height: 8),
            TextFormField(
              initialValue: (_formValues[input.id] ?? input.defaultValue)?.toString(),
              keyboardType: TextInputType.number,
              decoration: InputDecoration(
                contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
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
              style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
            ),
            const SizedBox(height: 8),
            TextFormField(
              initialValue: (_formValues[input.id] ?? input.defaultValue)?.toString(),
              maxLines: input.type == 'textarea' ? 4 : 1,
              decoration: InputDecoration(
                contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
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
