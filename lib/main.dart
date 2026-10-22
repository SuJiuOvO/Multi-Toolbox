import 'dart:ui';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'models/plugin_manifest.dart';
import 'pages/dynamic_tool_runner_page.dart';
import 'pages/plugin_store_page.dart';
import 'services/app_update_service.dart';
import 'services/plugin_manager_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await PluginManagerService().init();
  runApp(const MultiToolboxApp());
}

/// 支持全平台（含 Windows 桌面鼠标直接拖动滚动）的滚动行为
class AppScrollBehavior extends MaterialScrollBehavior {
  const AppScrollBehavior();

  @override
  Set<PointerDeviceKind> get dragDevices => {
        PointerDeviceKind.touch,
        PointerDeviceKind.mouse,
        PointerDeviceKind.trackpad,
        PointerDeviceKind.stylus,
      };
}

class MultiToolboxApp extends StatelessWidget {
  const MultiToolboxApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '多功能百宝箱 (动态插件化)',
      scrollBehavior: const AppScrollBehavior(),
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF2563EB),
          brightness: Brightness.light,
        ),
        useMaterial3: true,
        fontFamilyFallback: const [
          'Microsoft YaHei',
          'PingFang SC',
          'Noto Sans SC',
          'sans-serif',
        ],
        textTheme: const TextTheme(
          titleLarge: TextStyle(fontWeight: FontWeight.w600, letterSpacing: 0),
          titleMedium: TextStyle(fontWeight: FontWeight.w600, letterSpacing: 0),
          titleSmall: TextStyle(fontWeight: FontWeight.w500, letterSpacing: 0),
          bodyLarge: TextStyle(fontWeight: FontWeight.normal, letterSpacing: 0),
          bodyMedium: TextStyle(fontWeight: FontWeight.normal, letterSpacing: 0),
          bodySmall: TextStyle(fontWeight: FontWeight.normal, letterSpacing: 0),
          labelLarge: TextStyle(fontWeight: FontWeight.w500, letterSpacing: 0),
        ),
      ),
      home: const ToolboxHomePage(),
    );
  }
}

class ToolboxHomePage extends StatefulWidget {
  const ToolboxHomePage({super.key});

  @override
  State<ToolboxHomePage> createState() => _ToolboxHomePageState();
}

class _ToolboxHomePageState extends State<ToolboxHomePage> {
  final PluginManagerService _pluginManager = PluginManagerService();
  final TextEditingController _searchController = TextEditingController();
  final ScrollController _categoryScrollController = ScrollController();
  final ScrollController _platformScrollController = ScrollController();

  String _searchQuery = '';
  bool _isDeepSearch = false;
  String _selectedCategory = 'all';
  String _selectedPlatform = 'all';
  bool _showBanner = true;

  @override
  void initState() {
    super.initState();
    _refreshList();
  }

  @override
  void dispose() {
    _searchController.dispose();
    _categoryScrollController.dispose();
    _platformScrollController.dispose();
    super.dispose();
  }

  Future<void> _refreshList() async {
    await _pluginManager.loadInstalledPlugins();
    setState(() {});
  }

  /// 检查客户端在线更新
  Future<void> _checkAppUpdate() async {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => const Center(
        child: Card(
          elevation: 6,
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: 24, vertical: 20),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                CircularProgressIndicator(),
                SizedBox(width: 16),
                Text('正在检查客户端最新版本...'),
              ],
            ),
          ),
        ),
      ),
    );

    final updateInfo = await AppUpdateService().checkUpdate();
    if (!mounted) return;
    Navigator.of(context, rootNavigator: true).pop();

    if (updateInfo == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('检查更新失败，请检查网络')),
      );
      return;
    }

    if (!updateInfo.hasUpdate) {
      showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          icon: const Icon(Icons.verified_rounded, color: Colors.green, size: 46),
          title: const Text('已是最新版本'),
          content: Text('当前百宝箱版本 (v${PluginManagerService.currentAppVersion}) 已是最新。'),
          actions: [
            FilledButton(onPressed: () => Navigator.pop(ctx), child: const Text('好的')),
          ],
        ),
      );
      return;
    }

    // 发现新版本
    double updateProgress = 0.0;
    String updateStatus = '';
    bool isUpdating = false;

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (dialogCtx, setDialogState) {
          return AlertDialog(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            title: Row(
              children: [
                const Icon(Icons.system_update, color: Colors.blueAccent),
                const SizedBox(width: 8),
                Text(updateInfo.title, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
              ],
            ),
            content: SizedBox(
              width: 480,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                        decoration: BoxDecoration(
                          color: Colors.blue.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          '最新版本: v${updateInfo.latestVersion}',
                          style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.blueAccent),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text('当前: v${PluginManagerService.currentAppVersion}', style: const TextStyle(color: Colors.grey)),
                    ],
                  ),
                  const SizedBox(height: 10),
                  const Text('更新日志说明：', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                  const SizedBox(height: 4),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: Colors.grey.shade100,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      updateInfo.releaseNotes,
                      style: const TextStyle(fontSize: 12.5, height: 1.4, color: Colors.black87),
                    ),
                  ),
                  if (isUpdating) ...[
                    const SizedBox(height: 14),
                    LinearProgressIndicator(value: updateProgress > 0 ? updateProgress : null),
                    const SizedBox(height: 6),
                    Text(updateStatus, style: const TextStyle(fontSize: 11, color: Colors.blueAccent)),
                  ],
                ],
              ),
            ),
            actions: [
              if (!isUpdating)
                TextButton(
                  onPressed: () => Navigator.pop(dialogCtx),
                  child: const Text('稍后提醒'),
                ),
              FilledButton(
                onPressed: isUpdating || updateInfo.platformUpdate == null
                    ? null
                    : () async {
                        setDialogState(() {
                          isUpdating = true;
                          updateStatus = '正在下载更新...';
                        });

                        final success = await AppUpdateService().downloadAndInstallUpdate(
                          updateInfo.platformUpdate!,
                          onProgress: (prog, stat) {
                            setDialogState(() {
                              updateProgress = prog;
                              updateStatus = stat;
                            });
                          },
                        );

                        if (!success && mounted) {
                          setDialogState(() {
                            isUpdating = false;
                            updateStatus = '下载升级失败，请稍后重试。';
                          });
                        }
                      },
                child: Text(isUpdating ? '正在升级...' : '立即在线升级'),
              ),
            ],
          );
        },
      ),
    );
  }

  /// 本地安装功能模块 (.json / .zip)
  Future<void> _pickAndInstallLocalPlugin() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['json', 'zip'],
        dialogTitle: '选择本地插件文件 (.json 或 .zip 安装包)',
      );

      if (result == null || result.files.isEmpty) return;
      final filePath = result.files.single.path;
      if (filePath == null) return;

      if (!mounted) return;
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => const Center(
          child: Card(
            elevation: 8,
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: 24, vertical: 20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircularProgressIndicator(),
                  SizedBox(height: 16),
                  Text('正在解析并校验模块配置与客户端版本要求...'),
                ],
              ),
            ),
          ),
        ),
      );

      final installResult = await _pluginManager.installLocalPlugin(filePath);
      if (!mounted) return;
      Navigator.of(context, rootNavigator: true).pop(); // 关闭 loading 对话框

      if (installResult.success) {
        await _refreshList();
        if (!mounted) return;
        showDialog(
          context: context,
          builder: (ctx) => AlertDialog(
            icon: const Icon(Icons.check_circle_rounded, color: Colors.green, size: 48),
            title: const Text('本地安装成功'),
            content: Text(installResult.message),
            actions: [
              FilledButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('我知道了'),
              ),
            ],
          ),
        );
      } else {
        showDialog(
          context: context,
          builder: (ctx) => AlertDialog(
            icon: const Icon(Icons.error_outline_rounded, color: Colors.redAccent, size: 48),
            title: const Text('本地安装校验未通过'),
            content: SelectableText(installResult.message),
            actions: [
              FilledButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('关闭'),
              ),
            ],
          ),
        );
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('选择文件或安装出错: $e')),
      );
    }
  }

  Color _getPlatformBadgeColor(PluginManifest item) {
    if (item.isWindowsOnly()) return const Color(0xFF0284C7);
    if (item.isAndroidOnly()) return const Color(0xFF16A34A);
    return const Color(0xFF4F46E5);
  }

  IconData _getIconData(String iconName) {
    switch (iconName) {
      case 'compress':
        return Icons.compress;
      case 'aspect_ratio':
        return Icons.aspect_ratio;
      case 'badge':
        return Icons.badge;
      case 'movie':
        return Icons.movie_creation_outlined;
      case 'qr_code':
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
        return Icons.transform_outlined;
      default:
        return Icons.extension;
    }
  }

  void _openStore() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => PluginStorePage(onInstalledChanged: _refreshList),
      ),
    ).then((_) => _refreshList());
  }

  /// 全屏分类与平台筛选对话框
  void _showCategoryFullscreenDialog() {
    final allPlugins = _pluginManager.installedPlugins;

    // 统计各分类数量
    final Map<String, int> categoryCounts = {
      'all': allPlugins.length,
      'image': allPlugins.where((p) => p.category == 'image').length,
      'media': allPlugins.where((p) => p.category == 'media').length,
      'document': allPlugins.where((p) => p.category == 'document').length,
    };
    // 收集是否有其他未预设的自定义分类
    for (final p in allPlugins) {
      if (!categoryCounts.containsKey(p.category)) {
        categoryCounts[p.category] = allPlugins.where((x) => x.category == p.category).length;
      }
    }

    // 统计各平台数量
    final int countUniversal = allPlugins.where((p) => p.platforms.contains('universal')).length;
    final int countWindows = allPlugins.where((p) => p.platforms.contains('windows') || p.platforms.contains('universal')).length;
    final int countAndroid = allPlugins.where((p) => p.platforms.contains('android') || p.platforms.contains('universal')).length;

    String tempCategory = _selectedCategory;
    String tempPlatform = _selectedPlatform;

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (dialogCtx, setDialogState) {
          final theme = Theme.of(dialogCtx);
          return AlertDialog(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            titlePadding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
            contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
            actionsPadding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
            title: Row(
              children: [
                const Icon(Icons.tune_rounded, color: Colors.blueAccent),
                const SizedBox(width: 10),
                const Text('工具分类与平台全屏筛选', style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
                const Spacer(),
                TextButton(
                  onPressed: () {
                    setDialogState(() {
                      tempCategory = 'all';
                      tempPlatform = 'all';
                    });
                  },
                  child: const Text('重置筛选'),
                ),
              ],
            ),
            content: SizedBox(
              width: 540,
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text('功能业务分类：', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        _buildFilterChoiceItem(
                          label: '全部工具 (${categoryCounts['all'] ?? 0})',
                          icon: Icons.apps,
                          selected: tempCategory == 'all',
                          onTap: () => setDialogState(() => tempCategory = 'all'),
                        ),
                        _buildFilterChoiceItem(
                          label: '图片处理 (${categoryCounts['image'] ?? 0})',
                          icon: Icons.image_outlined,
                          selected: tempCategory == 'image',
                          onTap: () => setDialogState(() => tempCategory = 'image'),
                        ),
                        _buildFilterChoiceItem(
                          label: '音视频转换 (${categoryCounts['media'] ?? 0})',
                          icon: Icons.movie_creation_outlined,
                          selected: tempCategory == 'media',
                          onTap: () => setDialogState(() => tempCategory = 'media'),
                        ),
                        _buildFilterChoiceItem(
                          label: '文档/PDF (${categoryCounts['document'] ?? 0})',
                          icon: Icons.description_outlined,
                          selected: tempCategory == 'document',
                          onTap: () => setDialogState(() => tempCategory = 'document'),
                        ),
                        ...categoryCounts.keys
                            .where((k) => k != 'all' && k != 'image' && k != 'media' && k != 'document')
                            .map((customCat) => _buildFilterChoiceItem(
                                  label: '$customCat (${categoryCounts[customCat] ?? 0})',
                                  icon: Icons.extension,
                                  selected: tempCategory == customCat,
                                  onTap: () => setDialogState(() => tempCategory = customCat),
                                )),
                      ],
                    ),
                    const SizedBox(height: 18),
                    const Text('目标运行平台：', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        _buildFilterChoiceItem(
                          label: '全部平台 (${allPlugins.length})',
                          icon: Icons.devices,
                          selected: tempPlatform == 'all',
                          onTap: () => setDialogState(() => tempPlatform = 'all'),
                        ),
                        _buildFilterChoiceItem(
                          label: '🌐 全平台通用 ($countUniversal)',
                          icon: Icons.public,
                          selected: tempPlatform == 'universal',
                          onTap: () => setDialogState(() => tempPlatform = 'universal'),
                        ),
                        _buildFilterChoiceItem(
                          label: '🪟 Windows 专享/优化 ($countWindows)',
                          icon: Icons.window,
                          selected: tempPlatform == 'windows',
                          onTap: () => setDialogState(() => tempPlatform = 'windows'),
                        ),
                        _buildFilterChoiceItem(
                          label: '🤖 Android 专享/优化 ($countAndroid)',
                          icon: Icons.android,
                          selected: tempPlatform == 'android',
                          onTap: () => setDialogState(() => tempPlatform = 'android'),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: theme.colorScheme.primary.withValues(alpha: 0.06),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Row(
                        children: [
                          Icon(Icons.info_outline, size: 16, color: theme.colorScheme.primary),
                          const SizedBox(width: 8),
                          const Expanded(
                            child: Text(
                              '提示：竖屏或小窗口模式下，主界面分类栏可直接通过鼠标左键按住拖动滑动，亦可通过此全屏面板快捷筛选。',
                              style: TextStyle(fontSize: 11, color: Colors.black87),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () {
                  setState(() {
                    _selectedCategory = tempCategory;
                    _selectedPlatform = tempPlatform;
                  });
                  Navigator.pop(ctx);
                },
                child: const Text('应用筛选'),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildFilterChoiceItem({
    required String label,
    required IconData icon,
    required bool selected,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: selected ? Colors.blue.withValues(alpha: 0.12) : Colors.grey.shade100,
          border: Border.all(
            color: selected ? Colors.blueAccent : Colors.grey.shade300,
            width: selected ? 1.5 : 1.0,
          ),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 16, color: selected ? Colors.blueAccent : Colors.black54),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: selected ? FontWeight.bold : FontWeight.normal,
                color: selected ? Colors.blue.shade900 : Colors.black87,
              ),
            ),
            if (selected) ...[
              const SizedBox(width: 6),
              const Icon(Icons.check, size: 15, color: Colors.blueAccent),
            ],
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isMobile = MediaQuery.of(context).size.width < 600;

    // 过滤已安装插件
    final plugins = _pluginManager.installedPlugins.where((p) {
      if (_selectedCategory != 'all' && p.category != _selectedCategory) {
        return false;
      }
      if (_selectedPlatform != 'all') {
        if (_selectedPlatform == 'universal' && !p.platforms.contains('universal')) {
          return false;
        }
        if (_selectedPlatform == 'windows' &&
            !p.platforms.contains('windows') &&
            !p.platforms.contains('universal')) {
          return false;
        }
        if (_selectedPlatform == 'android' &&
            !p.platforms.contains('android') &&
            !p.platforms.contains('universal')) {
          return false;
        }
      }

      // 关键词搜索（普通搜索 vs 深度搜索）
      if (_searchQuery.trim().isNotEmpty) {
        final query = _searchQuery.trim().toLowerCase();
        final nameMatch = p.name.toLowerCase().contains(query);
        final categoryMatch = p.category.toLowerCase().contains(query);
        final idMatch = p.id.toLowerCase().contains(query);

        if (!_isDeepSearch) {
          // 普通搜索：匹配名称、分类、插件ID
          return nameMatch || categoryMatch || idMatch;
        } else {
          // 深度搜索：同时匹配功能模块简介、输入参数标签、提示词及可选下拉选项
          final descMatch = p.description.toLowerCase().contains(query);
          final inputMatch = p.inputs.any((inp) {
            final labelMatch = inp.label.toLowerCase().contains(query);
            final idMatch = inp.id.toLowerCase().contains(query);
            final optionMatch = inp.options.any((opt) =>
                opt.label.toLowerCase().contains(query) ||
                opt.value.toLowerCase().contains(query));
            return labelMatch || idMatch || optionMatch;
          });
          return nameMatch || categoryMatch || idMatch || descMatch || inputMatch;
        }
      }

      return true;
    }).toList();

    return Scaffold(
      body: CustomScrollView(
        physics: const AlwaysScrollableScrollPhysics(parent: BouncingScrollPhysics()),
        slivers: [
          SliverAppBar(
            floating: true,
            snap: true,
            pinned: !isMobile,
            title: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.handyman_rounded, color: Colors.blueAccent),
                const SizedBox(width: 8),
                Text(
                  '多功能百宝箱',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: isMobile ? 16 : 18),
                ),
              ],
            ),
            actions: [
              if (isMobile) ...[
                IconButton(
                  icon: const Icon(Icons.add_shopping_cart, color: Colors.blueAccent),
                  tooltip: '下载新工具 / 模块市场',
                  onPressed: _openStore,
                ),
                PopupMenuButton<String>(
                  icon: const Icon(Icons.more_vert),
                  tooltip: '更多选项',
                  onSelected: (val) {
                    if (val == 'install') {
                      _pickAndInstallLocalPlugin();
                    } else if (val == 'update') {
                      _checkAppUpdate();
                    } else if (val == 'refresh') {
                      _refreshList();
                    }
                  },
                  itemBuilder: (ctx) => [
                    const PopupMenuItem(
                      value: 'install',
                      child: Row(
                        children: [
                          Icon(Icons.file_upload_outlined, size: 18, color: Colors.blueAccent),
                          SizedBox(width: 8),
                          Text('本地安装模块 (.json / .zip)'),
                        ],
                      ),
                    ),
                    const PopupMenuItem(
                      value: 'update',
                      child: Row(
                        children: [
                          Icon(Icons.system_update_alt_rounded, size: 18, color: Colors.orange),
                          SizedBox(width: 8),
                          Text('检查客户端新版本'),
                        ],
                      ),
                    ),
                    const PopupMenuItem(
                      value: 'refresh',
                      child: Row(
                        children: [
                          Icon(Icons.refresh, size: 18),
                          SizedBox(width: 8),
                          Text('刷新已安装工具'),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(width: 4),
              ] else ...[
                OutlinedButton.icon(
                  onPressed: _pickAndInstallLocalPlugin,
                  icon: const Icon(Icons.file_upload_outlined, size: 17),
                  label: const Text('本地安装'),
                ),
                const SizedBox(width: 8),
                FilledButton.icon(
                  onPressed: _openStore,
                  icon: const Icon(Icons.add_shopping_cart, size: 18),
                  label: const Text('功能中心 / 模块市场'),
                ),
                IconButton(
                  tooltip: '检查新版本更新',
                  icon: const Icon(Icons.system_update_alt_rounded),
                  onPressed: _checkAppUpdate,
                ),
                IconButton(
                  tooltip: '刷新已安装工具',
                  icon: const Icon(Icons.refresh),
                  onPressed: _refreshList,
                ),
                const SizedBox(width: 8),
              ],
            ],
          ),

          // 顶部横幅说明 (可关闭)
          if (_showBanner)
            SliverToBoxAdapter(
              child: Container(
                width: double.infinity,
                margin: EdgeInsets.symmetric(
                  horizontal: isMobile ? 12 : 20,
                  vertical: 6,
                ),
                padding: EdgeInsets.fromLTRB(isMobile ? 10 : 14, isMobile ? 8 : 10, 6, isMobile ? 8 : 10),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [
                      theme.colorScheme.primary.withValues(alpha: 0.08),
                      theme.colorScheme.primary.withValues(alpha: 0.02),
                    ],
                  ),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: theme.colorScheme.primary.withValues(alpha: 0.2)),
                ),
                child: Row(
                  children: [
                    Icon(Icons.cloud_sync, size: isMobile ? 24 : 30, color: theme.colorScheme.primary),
                    SizedBox(width: isMobile ? 8 : 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '客户端免重新安装 · 云端热插拔与本地扩展',
                            style: TextStyle(
                              fontWeight: FontWeight.w600,
                              fontSize: isMobile ? 12.5 : 14,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            '所有工具均通过模块化规范加载。可进入右上角「模块市场」下载，或点击「本地安装」加载 .json/.zip 模块。',
                            style: TextStyle(
                              color: Colors.black54,
                              fontSize: isMobile ? 11 : 12,
                            ),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close, size: 18, color: Colors.grey),
                      tooltip: '关闭提示',
                      onPressed: () => setState(() => _showBanner = false),
                    ),
                  ],
                ),
              ),
            ),

          // 首页搜索栏 + 深度搜索开关
          SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: isMobile ? 12 : 20, vertical: 4),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _searchController,
                      onChanged: (val) {
                        setState(() {
                          _searchQuery = val;
                        });
                      },
                      decoration: InputDecoration(
                        hintText: _isDeepSearch
                            ? (isMobile ? '深度搜索 (匹配简介与参数)...' : '深度搜索已安装工具 (深入匹配功能简介、算法及参数说明)...')
                            : (isMobile ? '搜索已安装工具...' : '搜索已安装工具 (名称、分类、ID)...'),
                        hintStyle: const TextStyle(fontSize: 13, color: Colors.grey),
                        prefixIcon: const Icon(Icons.search, size: 20),
                        suffixIcon: _searchQuery.isNotEmpty
                            ? IconButton(
                                icon: const Icon(Icons.clear, size: 18),
                                onPressed: () {
                                  _searchController.clear();
                                  setState(() {
                                    _searchQuery = '';
                                  });
                                },
                              )
                            : null,
                        isDense: true,
                        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                        filled: true,
                        fillColor: Colors.grey.shade100,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10),
                          borderSide: BorderSide(color: Colors.grey.shade300),
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10),
                          borderSide: BorderSide(color: Colors.grey.shade300),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10),
                          borderSide: BorderSide(color: theme.colorScheme.primary),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  // 深度搜索切换 Chip
                  Tooltip(
                    message: '开启后将在功能模块的详细简介和参数说明中深入检索关键词',
                    child: FilterChip(
                      avatar: Icon(
                        _isDeepSearch ? Icons.manage_search_rounded : Icons.search_rounded,
                        size: 17,
                        color: _isDeepSearch ? Colors.white : theme.colorScheme.primary,
                      ),
                      label: Text(
                        _isDeepSearch ? '深度搜索' : '普通搜索',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: _isDeepSearch ? Colors.white : Colors.black87,
                        ),
                      ),
                      selected: _isDeepSearch,
                      selectedColor: theme.colorScheme.primary,
                      showCheckmark: false,
                      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 0),
                      visualDensity: VisualDensity.compact,
                      onSelected: (val) {
                        setState(() {
                          _isDeepSearch = val;
                        });
                      },
                    ),
                  ),
                ],
              ),
            ),
          ),

          // 搜索结果提示条（如果正在搜索）
          if (_searchQuery.trim().isNotEmpty)
            SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: isMobile ? 12 : 20, vertical: 2),
                child: Row(
                  children: [
                    Text(
                      '共检索到 ${plugins.length} 个功能模块',
                      style: const TextStyle(fontSize: 12, color: Colors.blueAccent, fontWeight: FontWeight.w600),
                    ),
                    if (_isDeepSearch)
                      const Text(
                        ' (已开启深度搜索：包含简介及参数)',
                        style: TextStyle(fontSize: 11, color: Colors.grey),
                      ),
                    const Spacer(),
                    InkWell(
                      onTap: () {
                        _searchController.clear();
                        setState(() => _searchQuery = '');
                      },
                      child: const Text('清除搜索', style: TextStyle(fontSize: 11, color: Colors.redAccent)),
                    ),
                  ],
                ),
              ),
            ),

          // 分类筛选 Chip + 全屏展开按钮
          SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: isMobile ? 12 : 20, vertical: 2),
              child: Row(
                children: [
                  Expanded(
                    child: Scrollbar(
                      controller: _categoryScrollController,
                      child: SingleChildScrollView(
                        controller: _categoryScrollController,
                        scrollDirection: Axis.horizontal,
                        physics: const BouncingScrollPhysics(),
                        child: Row(
                          children: [
                            FilterChip(
                              label: const Text('全部工具'),
                              selected: _selectedCategory == 'all',
                              onSelected: (_) => setState(() => _selectedCategory = 'all'),
                            ),
                            const SizedBox(width: 8),
                            FilterChip(
                              label: const Text('图片处理'),
                              selected: _selectedCategory == 'image',
                              onSelected: (_) => setState(() => _selectedCategory = 'image'),
                            ),
                            const SizedBox(width: 8),
                            FilterChip(
                              label: const Text('音视频转换'),
                              selected: _selectedCategory == 'media',
                              onSelected: (_) => setState(() => _selectedCategory = 'media'),
                            ),
                            const SizedBox(width: 8),
                            FilterChip(
                              label: const Text('文档/PDF'),
                              selected: _selectedCategory == 'document',
                              onSelected: (_) => setState(() => _selectedCategory = 'document'),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  // 全屏展开筛选按钮
                  Tooltip(
                    message: '全屏展开分类与架构筛选面板',
                    child: ActionChip(
                      avatar: const Icon(Icons.fullscreen_rounded, size: 18, color: Colors.blueAccent),
                      label: const Text('全屏展开', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
                      visualDensity: VisualDensity.compact,
                      onPressed: _showCategoryFullscreenDialog,
                    ),
                  ),
                ],
              ),
            ),
          ),

          // 平台架构筛选 Chip
          SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: isMobile ? 12 : 20, vertical: 2),
              child: Scrollbar(
                controller: _platformScrollController,
                child: SingleChildScrollView(
                  controller: _platformScrollController,
                  scrollDirection: Axis.horizontal,
                  physics: const BouncingScrollPhysics(),
                  child: Row(
                    children: [
                      ChoiceChip(
                        label: const Text('全部平台'),
                        selected: _selectedPlatform == 'all',
                        onSelected: (_) => setState(() => _selectedPlatform = 'all'),
                      ),
                      const SizedBox(width: 6),
                      ChoiceChip(
                        label: const Text('🌐 全平台通用'),
                        selected: _selectedPlatform == 'universal',
                        onSelected: (_) => setState(() => _selectedPlatform = 'universal'),
                      ),
                      const SizedBox(width: 6),
                      ChoiceChip(
                        label: const Text('🪟 Windows 专享/优化'),
                        selected: _selectedPlatform == 'windows',
                        onSelected: (_) => setState(() => _selectedPlatform = 'windows'),
                      ),
                      const SizedBox(width: 6),
                      ChoiceChip(
                        label: const Text('🤖 Android 专享/优化'),
                        selected: _selectedPlatform == 'android',
                        onSelected: (_) => setState(() => _selectedPlatform = 'android'),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          const SliverToBoxAdapter(child: SizedBox(height: 4)),

          // 工具卡片 Grid 列表
          if (plugins.isEmpty)
            SliverFillRemaining(
              hasScrollBody: false,
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.search_off_rounded, size: 60, color: Colors.grey),
                      const SizedBox(height: 12),
                      Text(
                        _searchQuery.isNotEmpty
                            ? '未搜索到匹配 “$_searchQuery” 的功能模块'
                            : '当前分类或平台筛选下暂无已安装的工具',
                        style: const TextStyle(color: Colors.grey, fontSize: 15),
                      ),
                      const SizedBox(height: 12),
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (_searchQuery.isNotEmpty ||
                              _selectedCategory != 'all' ||
                              _selectedPlatform != 'all')
                            OutlinedButton.icon(
                              onPressed: () {
                                setState(() {
                                  _searchController.clear();
                                  _searchQuery = '';
                                  _selectedCategory = 'all';
                                  _selectedPlatform = 'all';
                                });
                              },
                              icon: const Icon(Icons.clear_all, size: 16),
                              label: const Text('重置筛选与搜索'),
                            ),
                          const SizedBox(width: 10),
                          FilledButton.icon(
                            onPressed: _openStore,
                            icon: const Icon(Icons.download, size: 16),
                            label: const Text('前往功能中心下载'),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            )
          else
            SliverPadding(
              padding: EdgeInsets.fromLTRB(
                isMobile ? 12 : 20,
                4,
                isMobile ? 12 : 20,
                isMobile ? 24 : 20,
              ),
              sliver: SliverGrid(
                gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
                  maxCrossAxisExtent: 380,
                  mainAxisSpacing: 10,
                  crossAxisSpacing: 10,
                  mainAxisExtent: isMobile ? 130 : 155,
                ),
                delegate: SliverChildBuilderDelegate(
                  (ctx, index) {
                    final item = plugins[index];
                    return Card(
                      elevation: 1,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      clipBehavior: Clip.antiAlias,
                      child: InkWell(
                        onTap: () {
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => DynamicToolRunnerPage(plugin: item),
                            ),
                          );
                        },
                        child: Padding(
                          padding: EdgeInsets.all(isMobile ? 11 : 14),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  CircleAvatar(
                                    radius: isMobile ? 16 : 18,
                                    backgroundColor: theme.colorScheme.primaryContainer,
                                    child: Icon(_getIconData(item.icon),
                                        size: isMobile ? 18 : 20, color: theme.colorScheme.primary),
                                  ),
                                  const SizedBox(width: 10),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          item.name,
                                          style: TextStyle(
                                            fontWeight: FontWeight.w600,
                                            fontSize: isMobile ? 13.5 : 14,
                                          ),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                        Row(
                                          children: [
                                            Text(
                                              'v${item.version}',
                                              style: const TextStyle(fontSize: 10.5, color: Colors.grey),
                                            ),
                                            const SizedBox(width: 6),
                                            Container(
                                              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                                              decoration: BoxDecoration(
                                                color: _getPlatformBadgeColor(item).withValues(alpha: 0.12),
                                                borderRadius: BorderRadius.circular(4),
                                              ),
                                              child: Text(
                                                item.platformBadgeText,
                                                style: TextStyle(
                                                  fontSize: 9.5,
                                                  fontWeight: FontWeight.w500,
                                                  color: _getPlatformBadgeColor(item),
                                                ),
                                              ),
                                            ),
                                          ],
                                        ),
                                      ],
                                    ),
                                  ),
                                  const Icon(Icons.chevron_right, size: 20, color: Colors.grey),
                                ],
                              ),
                              const SizedBox(height: 6),
                              Expanded(
                                child: Text(
                                  item.description,
                                  style: TextStyle(
                                    fontSize: isMobile ? 11.5 : 12,
                                    color: Colors.black87,
                                    height: 1.35,
                                  ),
                                  maxLines: isMobile ? 2 : 3,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                  childCount: plugins.length,
                ),
              ),
            ),
        ],
      ),
    );
  }
}
