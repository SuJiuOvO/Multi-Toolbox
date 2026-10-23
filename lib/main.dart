import 'dart:ui';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'models/plugin_manifest.dart';
import 'pages/dynamic_tool_runner_page.dart';
import 'pages/plugin_store_page.dart';
import 'pages/settings_page.dart';
import 'services/app_update_service.dart';
import 'services/notification_service.dart';
import 'services/plugin_manager_service.dart';
import 'services/settings_service.dart';
import 'theme/app_theme_manager.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 1. 本地轻量偏好读取（带防超时保护，绝不阻塞应用启动）
  try {
    await SettingsService().init().timeout(const Duration(milliseconds: 1000));
  } catch (e) {
    debugPrint('SettingsService init fallback: $e');
  }

  // 2. 本地插件索引读取（带防超时保护）
  try {
    await PluginManagerService().init().timeout(const Duration(milliseconds: 1500));
  } catch (e) {
    debugPrint('PluginManagerService init fallback: $e');
  }

  // 3. 立即启动根应用！第一时间挂载首帧，彻底根治安卓启动白屏卡死问题！
  runApp(const MultiToolboxApp());

  // 4. 通知插件等非核心平台原生服务在首帧后异步挂载，严禁阻塞 UI 启动
  Future.microtask(() async {
    try {
      await NotificationService().init();
    } catch (e) {
      debugPrint('NotificationService async init fallback: $e');
    }
  });
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
    return AnimatedBuilder(
      animation: SettingsService(),
      builder: (context, _) {
        final currentThemeId = SettingsService().themeId;
        final baseTheme = AppThemeManager.getThemeData(currentThemeId);

        final finalTheme = baseTheme.copyWith(
          pageTransitionsTheme: const PageTransitionsTheme(
            builders: {
              TargetPlatform.android: ZoomPageTransitionsBuilder(),
              TargetPlatform.windows: ZoomPageTransitionsBuilder(),
            },
          ),
        );

        return MaterialApp(
          title: '多功能百宝箱 (动态插件化)',
          scrollBehavior: const AppScrollBehavior(),
          debugShowCheckedModeBanner: false,
          theme: finalTheme,
          home: const ToolboxHomePage(),
        );
      },
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

  String _searchQuery = '';
  bool _isDeepSearch = false;
  String _selectedCategory = 'all';
  String _selectedPlatform = 'all';
  bool _showBanner = true;
  bool _isCompactGrid = true;

  @override
  void initState() {
    super.initState();
    _showBanner = !SettingsService().bannerDismissedPermanently;
    _isDeepSearch = SettingsService().deepSearchDefault;
    _refreshList();
  }

  @override
  void dispose() {
    _searchController.dispose();
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
    if (item.platforms.contains('universal')) return AppThemeManager.accentGreen;
    if (item.isWindowsOnly()) return AppThemeManager.accentBlue;
    if (item.isAndroidOnly()) return AppThemeManager.accentYellow;
    return AppThemeManager.accentBlue;
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
      case 'watermark':
      case 'banana':
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

  void _openSettings() {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const SettingsPage()),
    ).then((_) {
      setState(() {
        if (SettingsService().bannerDismissedPermanently) {
          _showBanner = false;
        }
      });
    });
  }

  Future<void> _handleDismissBanner() async {
    final settings = SettingsService();
    // 如果已经提示过（即后续再叉掉），直接关闭，不再给出任何提示
    if (settings.bannerDismissPromptShown) {
      setState(() => _showBanner = false);
      return;
    }

    // 第一次叉掉：弹出永久关闭提示说明
    final choice = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.help_outline_rounded, color: Colors.blueAccent),
            SizedBox(width: 8),
            Text('关闭提示说明', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
          ],
        ),
        content: const Text(
          '是否永久关闭此免重下安装说明横幅？\n\n'
          '选择“永久关闭”后，以后打开软件将不再显示此提示。',
          style: TextStyle(fontSize: 13.5, height: 1.4),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, 'once'),
            child: const Text('仅这次'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, 'forever'),
            child: const Text('永久关闭'),
          ),
        ],
      ),
    );

    if (choice == 'forever') {
      await settings.setBannerDismissedPermanently(true);
      await settings.setBannerDismissPromptShown(true);
      setState(() => _showBanner = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('已永久关闭提示说明，后续可在【设置】中重新开启。')),
        );
      }
    } else if (choice == 'once') {
      await settings.setBannerDismissPromptShown(true);
      setState(() => _showBanner = false);
      if (mounted) {
        // 用户选择仅这次，再提示用户可以到设置中永久关闭提示说明
        await showDialog(
          context: context,
          builder: (ctx2) => AlertDialog(
            title: const Row(
              children: [
                Icon(Icons.info_outline, color: Colors.blueAccent),
                SizedBox(width: 8),
                Text('提示', style: TextStyle(fontSize: 16)),
              ],
            ),
            content: const Text(
              '已为您关闭本次说明。\n\n'
              '如果您以后不再需要看到此提示说明，可以随时在【设置】中开启或永久关闭此提示。',
              style: TextStyle(fontSize: 13.5, height: 1.4),
            ),
            actions: [
              FilledButton(
                onPressed: () => Navigator.pop(ctx2),
                child: const Text('我知道了'),
              ),
            ],
          ),
        );
      }
    }
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
          return AlertDialog(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            titlePadding: const EdgeInsets.fromLTRB(16, 16, 16, 10),
            contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
            actionsPadding: const EdgeInsets.fromLTRB(16, 10, 16, 14),
            title: Row(
              children: [
                const Icon(Icons.tune_rounded, color: Colors.blueAccent, size: 20),
                const SizedBox(width: 8),
                const Text('分类与平台筛选', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                const Spacer(),
                TextButton.icon(
                  onPressed: () {
                    setDialogState(() {
                      tempCategory = 'all';
                      tempPlatform = 'all';
                    });
                  },
                  icon: const Icon(Icons.refresh, size: 14),
                  label: const Text('重置', style: TextStyle(fontSize: 12)),
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  ),
                ),
              ],
            ),
            content: SizedBox(
              width: 500,
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text('功能业务分类：', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: [
                        _buildFilterChoiceItem(
                          label: '全部 (${categoryCounts['all'] ?? 0})',
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
                          label: '音视频 (${categoryCounts['media'] ?? 0})',
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
                                  icon: Icons.extension_outlined,
                                  selected: tempCategory == customCat,
                                  onTap: () => setDialogState(() => tempCategory = customCat),
                                )),
                      ],
                    ),
                    const SizedBox(height: 16),
                    const Text('目标运行平台：', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: [
                        _buildFilterChoiceItem(
                          label: '全部 (${allPlugins.length})',
                          icon: Icons.devices,
                          selected: tempPlatform == 'all',
                          onTap: () => setDialogState(() => tempPlatform = 'all'),
                        ),
                        _buildFilterChoiceItem(
                          label: '全平台通用 ($countUniversal)',
                          icon: Icons.public,
                          selected: tempPlatform == 'universal',
                          onTap: () => setDialogState(() => tempPlatform = 'universal'),
                        ),
                        _buildFilterChoiceItem(
                          label: 'Windows 专享 ($countWindows)',
                          icon: Icons.window,
                          selected: tempPlatform == 'windows',
                          onTap: () => setDialogState(() => tempPlatform = 'windows'),
                        ),
                        _buildFilterChoiceItem(
                          label: 'Android 专享 ($countAndroid)',
                          icon: Icons.android,
                          selected: tempPlatform == 'android',
                          onTap: () => setDialogState(() => tempPlatform = 'android'),
                        ),
                      ],
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
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final onSurface = Theme.of(context).colorScheme.onSurface;
    final primary = Theme.of(context).colorScheme.primary;

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
        decoration: BoxDecoration(
          color: selected
              ? primary
              : (isDark ? const Color(0xFF1E293B) : const Color(0xFFF3F4F6)),
          border: Border.all(
            color: selected
                ? primary
                : (isDark ? const Color(0xFF334155) : const Color(0xFFD1D5DB)),
            width: selected ? 1.4 : 1.0,
          ),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 15, color: selected ? Colors.white : onSurface),
            const SizedBox(width: 5),
            Text(
              label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: selected ? FontWeight.bold : FontWeight.w500,
                color: selected ? Colors.white : onSurface,
              ),
            ),
            if (selected) ...[
              const SizedBox(width: 4),
              const Icon(Icons.check, size: 13, color: Colors.white),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildFilterChip({
    required String label,
    required bool selected,
    required VoidCallback onSelected,
    required ThemeData theme,
    required bool isDark,
    required Color textPrimary,
  }) {
    return InkWell(
      onTap: onSelected,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: selected
              ? theme.colorScheme.primary
              : (isDark ? const Color(0xFF1E293B) : const Color(0xFFF3F4F6)),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: selected
                ? theme.colorScheme.primary
                : (isDark ? const Color(0xFF334155) : const Color(0xFFD1D5DB)),
            width: selected ? 1.2 : 1.0,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 11.5,
            fontWeight: selected ? FontWeight.bold : FontWeight.w500,
            color: selected ? Colors.white : textPrimary,
          ),
        ),
      ),
    );
  }

  Widget _buildCardContainer({
    required BuildContext context,
    required Widget child,
    required VoidCallback onTap,
    EdgeInsetsGeometry? margin,
    double borderRadius = 12,
  }) {
    final theme = Theme.of(context);
    final isGlass = SettingsService().themeId == 'liquid_glass';

    if (isGlass) {
      return Container(
        margin: margin ?? EdgeInsets.zero,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(borderRadius),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.06),
              blurRadius: 16,
              offset: const Offset(0, 4),
            ),
            BoxShadow(
              color: Colors.white.withValues(alpha: 0.7),
              blurRadius: 2,
              offset: const Offset(-1, -1),
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(borderRadius),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
            child: Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    Colors.white.withValues(alpha: 0.80),
                    Colors.white.withValues(alpha: 0.50),
                  ],
                ),
                borderRadius: BorderRadius.circular(borderRadius),
                border: Border.all(
                  color: Colors.white.withValues(alpha: 0.95),
                  width: 1.4,
                ),
              ),
              child: Material(
                color: Colors.transparent,
                child: InkWell(
                  onTap: onTap,
                  borderRadius: BorderRadius.circular(borderRadius),
                  child: child,
                ),
              ),
            ),
          ),
        ),
      );
    }

    return Card(
      margin: margin ?? EdgeInsets.zero,
      elevation: 1,
      color: theme.cardColor,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(borderRadius),
        side: BorderSide(
          color: theme.colorScheme.outline.withValues(alpha: 0.6),
          width: 1.0,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: child,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final screenSize = MediaQuery.of(context).size;
    final isMobile = screenSize.width < 600;
    final isPortrait = screenSize.height > screenSize.width || screenSize.width < 500;
    final isDark = theme.brightness == Brightness.dark;
    final isGlass = SettingsService().themeId == 'liquid_glass';
    final textPrimary = theme.colorScheme.onSurface;
    final textSecondary = theme.colorScheme.onSurfaceVariant;

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

    final bodyContent = CustomScrollView(
        physics: const AlwaysScrollableScrollPhysics(parent: BouncingScrollPhysics()),
        slivers: [
          SliverAppBar(
            floating: true,
            snap: true,
            pinned: !isMobile,
            backgroundColor: isGlass ? Colors.white.withValues(alpha: 0.65) : null,
            title: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.handyman_rounded, color: AppThemeManager.accentBlue),
                const SizedBox(width: 8),
                Text(
                  '多功能百宝箱',
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: isMobile ? 16 : 18,
                    color: textPrimary,
                  ),
                ),
              ],
            ),
            actions: [
              if (isMobile) ...[
                IconButton(
                  icon: const Icon(Icons.add_shopping_cart, color: AppThemeManager.accentBlue),
                  tooltip: '下载新工具 / 模块市场',
                  onPressed: _openStore,
                ),
                IconButton(
                  icon: Icon(Icons.settings_outlined, color: textPrimary),
                  tooltip: '系统设置与关于',
                  onPressed: _openSettings,
                ),
                PopupMenuButton<String>(
                  icon: Icon(Icons.more_vert, color: textPrimary),
                  tooltip: '更多选项',
                  onSelected: (val) {
                    if (val == 'settings') {
                      _openSettings();
                    } else if (val == 'install') {
                      _pickAndInstallLocalPlugin();
                    } else if (val == 'update') {
                      _checkAppUpdate();
                    } else if (val == 'refresh') {
                      _refreshList();
                    }
                  },
                  itemBuilder: (ctx) => [
                    const PopupMenuItem(
                      value: 'settings',
                      child: Row(
                        children: [
                          Icon(Icons.settings_outlined, size: 18, color: AppThemeManager.accentBlue),
                          SizedBox(width: 8),
                          Text('系统设置与关于'),
                        ],
                      ),
                    ),
                    const PopupMenuItem(
                      value: 'install',
                      child: Row(
                        children: [
                          Icon(Icons.file_upload_outlined, size: 18, color: AppThemeManager.accentBlue),
                          SizedBox(width: 8),
                          Text('本地安装模块 (.json / .zip)'),
                        ],
                      ),
                    ),
                    const PopupMenuItem(
                      value: 'update',
                      child: Row(
                        children: [
                          Icon(Icons.system_update_alt_rounded, size: 18, color: AppThemeManager.accentYellow),
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
                  tooltip: '系统设置与关于',
                  icon: Icon(Icons.settings_outlined, color: textPrimary),
                  onPressed: _openSettings,
                ),
                IconButton(
                  tooltip: '检查新版本更新',
                  icon: const Icon(Icons.system_update_alt_rounded, color: AppThemeManager.accentYellow),
                  onPressed: _checkAppUpdate,
                ),
                IconButton(
                  tooltip: '刷新已安装工具',
                  icon: Icon(Icons.refresh, color: textPrimary),
                  onPressed: _refreshList,
                ),
                const SizedBox(width: 8),
              ],
            ],
          ),

          // 顶部横幅说明 (可关闭，并支持永久关闭提示)
          if (_showBanner && !SettingsService().bannerDismissedPermanently)
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
                      theme.colorScheme.primary.withValues(alpha: 0.10),
                      theme.colorScheme.primary.withValues(alpha: 0.03),
                    ],
                  ),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: theme.colorScheme.primary.withValues(alpha: 0.3)),
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
                              fontWeight: FontWeight.bold,
                              fontSize: isMobile ? 12.5 : 14,
                              color: textPrimary,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            '所有工具均通过模块化规范加载。可进入右上角「模块市场」下载，或点击「本地安装」加载 .json/.zip 模块。',
                            style: TextStyle(
                              color: textSecondary,
                              fontSize: isMobile ? 11 : 12,
                            ),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      icon: Icon(Icons.close, size: 18, color: textSecondary),
                      tooltip: '关闭提示',
                      onPressed: _handleDismissBanner,
                    ),
                  ],
                ),
              ),
            ),

          // 首页搜索栏 + 深度搜索开关 (长条轻量形，Switch 样式无放大镜)
          SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: isMobile ? 12 : 20, vertical: 4),
              child: Row(
                children: [
                  Expanded(
                    child: SizedBox(
                      height: 38,
                      child: TextField(
                        controller: _searchController,
                        style: TextStyle(fontSize: 13, color: textPrimary),
                        onChanged: (val) {
                          setState(() {
                            _searchQuery = val;
                          });
                        },
                        decoration: InputDecoration(
                          hintText: _isDeepSearch
                              ? (isMobile ? '深度搜索 (匹配简介与参数)...' : '深度搜索已安装工具 (深入匹配功能简介、算法及参数说明)...')
                              : (isMobile ? '搜索已安装工具...' : '搜索已安装工具 (名称、分类、ID)...'),
                          hintStyle: TextStyle(fontSize: 12.5, color: textSecondary),
                          prefixIcon: Icon(Icons.search, size: 18, color: textSecondary),
                          prefixIconConstraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                          suffixIcon: _searchQuery.isNotEmpty
                              ? IconButton(
                                  icon: Icon(Icons.clear, size: 16, color: textSecondary),
                                  padding: EdgeInsets.zero,
                                  constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                                  onPressed: () {
                                    _searchController.clear();
                                    setState(() {
                                      _searchQuery = '';
                                    });
                                  },
                                )
                              : null,
                          isDense: true,
                          contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                          filled: true,
                          fillColor: isDark ? const Color(0xFF1E293B) : const Color(0xFFF3F4F6),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(20),
                            borderSide: BorderSide(color: isDark ? const Color(0xFF334155) : const Color(0xFFD1D5DB)),
                          ),
                          enabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(20),
                            borderSide: BorderSide(color: isDark ? const Color(0xFF334155) : const Color(0xFFD1D5DB)),
                          ),
                          focusedBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(20),
                            borderSide: BorderSide(color: theme.colorScheme.primary, width: 1.5),
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  // 深度搜索 开关样式（Switch 开关，消除放大镜图标误导）
                  Tooltip(
                    message: '深度搜索开关：开启后在功能模块详细简介与参数说明中检索',
                    child: InkWell(
                      onTap: () => setState(() => _isDeepSearch = !_isDeepSearch),
                      borderRadius: BorderRadius.circular(20),
                      child: Container(
                        height: 38,
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        decoration: BoxDecoration(
                          color: _isDeepSearch
                              ? AppThemeManager.accentYellow.withValues(alpha: 0.15)
                              : (isDark ? const Color(0xFF1E293B) : const Color(0xFFF3F4F6)),
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(
                            color: _isDeepSearch
                                ? AppThemeManager.accentYellow
                                : (isDark ? const Color(0xFF334155) : const Color(0xFFD1D5DB)),
                          ),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              '深度搜索',
                              style: TextStyle(
                                fontSize: 11.5,
                                fontWeight: _isDeepSearch ? FontWeight.bold : FontWeight.w500,
                                color: _isDeepSearch ? AppThemeManager.accentYellow : textPrimary,
                              ),
                            ),
                            const SizedBox(width: 2),
                            Transform.scale(
                              scale: 0.68,
                              child: Switch(
                                value: _isDeepSearch,
                                activeColor: AppThemeManager.accentYellow,
                                onChanged: (val) => setState(() => _isDeepSearch = val),
                                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                              ),
                            ),
                          ],
                        ),
                      ),
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
                      style: const TextStyle(fontSize: 12, color: AppThemeManager.accentBlue, fontWeight: FontWeight.bold),
                    ),
                    if (_isDeepSearch)
                      Text(
                        ' (已开启深度搜索：包含简介及参数)',
                        style: TextStyle(fontSize: 11, color: textSecondary),
                      ),
                    const Spacer(),
                    InkWell(
                      onTap: () {
                        _searchController.clear();
                        setState(() => _searchQuery = '');
                      },
                      child: const Text('清除搜索', style: TextStyle(fontSize: 11, color: AppThemeManager.accentRed, fontWeight: FontWeight.bold)),
                    ),
                  ],
                ),
              ),
            ),

          // 分类筛选 Chip + 全屏展开按钮 (缩小尺寸、去文字仅留小图标、移除进度条覆盖)
          SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: isMobile ? 12 : 20, vertical: 2),
              child: Row(
                children: [
                  Expanded(
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      physics: const BouncingScrollPhysics(),
                      child: Row(
                        children: [
                          _buildFilterChip(
                            label: '全部',
                            selected: _selectedCategory == 'all',
                            onSelected: () => setState(() => _selectedCategory = 'all'),
                            theme: theme,
                            isDark: isDark,
                            textPrimary: textPrimary,
                          ),
                          const SizedBox(width: 6),
                          _buildFilterChip(
                            label: '图片处理',
                            selected: _selectedCategory == 'image',
                            onSelected: () => setState(() => _selectedCategory = 'image'),
                            theme: theme,
                            isDark: isDark,
                            textPrimary: textPrimary,
                          ),
                          const SizedBox(width: 6),
                          _buildFilterChip(
                            label: '音视频',
                            selected: _selectedCategory == 'media',
                            onSelected: () => setState(() => _selectedCategory = 'media'),
                            theme: theme,
                            isDark: isDark,
                            textPrimary: textPrimary,
                          ),
                          const SizedBox(width: 6),
                          _buildFilterChip(
                            label: '文档/PDF',
                            selected: _selectedCategory == 'document',
                            onSelected: () => setState(() => _selectedCategory = 'document'),
                            theme: theme,
                            isDark: isDark,
                            textPrimary: textPrimary,
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  // 全屏展开筛选按钮（仅保留小图标，无冗余文字）
                  Tooltip(
                    message: '全屏分类与平台筛选',
                    child: InkWell(
                      onTap: _showCategoryFullscreenDialog,
                      borderRadius: BorderRadius.circular(8),
                      child: Container(
                        padding: const EdgeInsets.all(6),
                        decoration: BoxDecoration(
                          color: AppThemeManager.accentBlue.withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: AppThemeManager.accentBlue.withValues(alpha: 0.3)),
                        ),
                        child: const Icon(Icons.tune_rounded, size: 18, color: AppThemeManager.accentBlue),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),

          // 平台架构筛选 Chip + 布局切换按钮（卡片精简 vs 列表详情）
          SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: isMobile ? 12 : 20, vertical: 2),
              child: Row(
                children: [
                  Expanded(
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      physics: const BouncingScrollPhysics(),
                      child: Row(
                        children: [
                          _buildFilterChip(
                            label: '全部',
                            selected: _selectedPlatform == 'all',
                            onSelected: () => setState(() => _selectedPlatform == 'all'),
                            theme: theme,
                            isDark: isDark,
                            textPrimary: textPrimary,
                          ),
                          const SizedBox(width: 6),
                          _buildFilterChip(
                            label: '🌐 通用',
                            selected: _selectedPlatform == 'universal',
                            onSelected: () => setState(() => _selectedPlatform == 'universal'),
                            theme: theme,
                            isDark: isDark,
                            textPrimary: textPrimary,
                          ),
                          const SizedBox(width: 6),
                          _buildFilterChip(
                            label: '🪟 Win',
                            selected: _selectedPlatform == 'windows',
                            onSelected: () => setState(() => _selectedPlatform == 'windows'),
                            theme: theme,
                            isDark: isDark,
                            textPrimary: textPrimary,
                          ),
                          const SizedBox(width: 6),
                          _buildFilterChip(
                            label: '🤖 安卓',
                            selected: _selectedPlatform == 'android',
                            onSelected: () => setState(() => _selectedPlatform == 'android'),
                            theme: theme,
                            isDark: isDark,
                            textPrimary: textPrimary,
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  // 布局模式切换按钮：卡片排列（简单样式） vs 列表/详细卡片样式（原版响应式）
                  Tooltip(
                    message: _isCompactGrid ? '切换至原版详细卡片视图' : '切换至精简网格卡片视图',
                    child: InkWell(
                      onTap: () => setState(() => _isCompactGrid = !_isCompactGrid),
                      borderRadius: BorderRadius.circular(8),
                      child: Container(
                        padding: const EdgeInsets.all(6),
                        decoration: BoxDecoration(
                          color: _isCompactGrid
                              ? AppThemeManager.accentBlue.withValues(alpha: 0.12)
                              : (isDark ? const Color(0xFF1E293B) : const Color(0xFFF3F4F6)),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                            color: _isCompactGrid
                                ? AppThemeManager.accentBlue
                                : (isDark ? const Color(0xFF334155) : const Color(0xFFD1D5DB)),
                          ),
                        ),
                        child: Icon(
                          _isCompactGrid ? Icons.view_agenda_outlined : Icons.grid_view_rounded,
                          size: 18,
                          color: _isCompactGrid ? AppThemeManager.accentBlue : textSecondary,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SliverToBoxAdapter(child: SizedBox(height: 4)),

          // 工具列表（卡片紧凑视图 vs 列表详情视图）
          if (plugins.isEmpty)
            SliverFillRemaining(
              hasScrollBody: false,
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.search_off_rounded, size: 60, color: textSecondary),
                      const SizedBox(height: 12),
                      Text(
                        _searchQuery.isNotEmpty
                            ? '未搜索到匹配 “$_searchQuery” 的功能模块'
                            : '当前分类或平台筛选下暂无已安装的工具',
                        style: TextStyle(color: textSecondary, fontSize: 15),
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
          else if (_isCompactGrid)
            // 卡片式排列（简单样式，只显示图标和名称，竖屏显示更多功能）
            SliverPadding(
              padding: EdgeInsets.fromLTRB(
                isMobile ? 12 : 20,
                4,
                isMobile ? 12 : 20,
                isMobile ? 24 : 20,
              ),
              sliver: SliverGrid(
                gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
                  maxCrossAxisExtent: isMobile ? 195 : 240,
                  mainAxisSpacing: 8,
                  crossAxisSpacing: 8,
                  mainAxisExtent: isMobile ? 66 : 74,
                ),
                delegate: SliverChildBuilderDelegate(
                  (ctx, index) {
                    final item = plugins[index];
                    final badgeColor = _getPlatformBadgeColor(item);
                    return _buildCardContainer(
                      context: context,
                      borderRadius: 10,
                      onTap: () {
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => DynamicToolRunnerPage(plugin: item),
                          ),
                        );
                      },
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                        child: Row(
                          children: [
                            Container(
                              width: isMobile ? 32 : 36,
                              height: isMobile ? 32 : 36,
                              decoration: BoxDecoration(
                                color: theme.colorScheme.primary.withValues(alpha: 0.12),
                                shape: BoxShape.circle,
                              ),
                              child: Icon(
                                _getIconData(item.icon),
                                size: isMobile ? 18 : 20,
                                color: theme.colorScheme.primary,
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Text(
                                    item.name,
                                    style: TextStyle(
                                      fontWeight: FontWeight.bold,
                                      fontSize: isMobile ? 12.5 : 13.5,
                                      color: textPrimary,
                                    ),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  const SizedBox(height: 2),
                                  Row(
                                    children: [
                                      Text(
                                        'v${item.version}',
                                        style: TextStyle(fontSize: 10, color: textSecondary),
                                      ),
                                      const SizedBox(width: 4),
                                      Container(
                                        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 0.5),
                                        decoration: BoxDecoration(
                                          color: badgeColor.withValues(alpha: 0.12),
                                          borderRadius: BorderRadius.circular(3),
                                          border: Border.all(color: badgeColor.withValues(alpha: 0.3), width: 0.5),
                                        ),
                                        child: Text(
                                          item.platforms.contains('universal') ? '通用' : (item.isWindowsOnly() ? 'Win' : '安卓'),
                                          style: TextStyle(
                                            fontSize: 8.5,
                                            fontWeight: FontWeight.bold,
                                            color: badgeColor,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                  childCount: plugins.length,
                ),
              ),
            )
          else if (isPortrait)
            // 详细列表模式（竖屏比例下：自适应为纯单列列表）
            SliverPadding(
              padding: EdgeInsets.fromLTRB(
                isMobile ? 12 : 20,
                4,
                isMobile ? 12 : 20,
                isMobile ? 24 : 20,
              ),
              sliver: SliverList(
                delegate: SliverChildBuilderDelegate(
                  (ctx, index) {
                    final item = plugins[index];
                    final badgeColor = _getPlatformBadgeColor(item);
                    return _buildCardContainer(
                      context: context,
                      margin: const EdgeInsets.only(bottom: 8),
                      borderRadius: 12,
                      onTap: () {
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => DynamicToolRunnerPage(plugin: item),
                          ),
                        );
                      },
                      child: Padding(
                        padding: EdgeInsets.all(isMobile ? 12 : 14),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Container(
                                  width: isMobile ? 34 : 38,
                                  height: isMobile ? 34 : 38,
                                  decoration: BoxDecoration(
                                    color: theme.colorScheme.primary.withValues(alpha: 0.12),
                                    shape: BoxShape.circle,
                                  ),
                                  child: Icon(
                                    _getIconData(item.icon),
                                    size: isMobile ? 18 : 20,
                                    color: theme.colorScheme.primary,
                                  ),
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        item.name,
                                        style: TextStyle(
                                          fontWeight: FontWeight.bold,
                                          fontSize: isMobile ? 13.5 : 14.5,
                                          color: textPrimary,
                                        ),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                      const SizedBox(height: 2),
                                      Row(
                                        children: [
                                          Text(
                                            'v${item.version}',
                                            style: TextStyle(fontSize: 10.5, color: textSecondary),
                                          ),
                                          const SizedBox(width: 6),
                                          Container(
                                            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                                            decoration: BoxDecoration(
                                              color: badgeColor.withValues(alpha: 0.12),
                                              borderRadius: BorderRadius.circular(4),
                                              border: Border.all(color: badgeColor.withValues(alpha: 0.3), width: 0.5),
                                            ),
                                            child: Text(
                                              item.platformBadgeText,
                                              style: TextStyle(
                                                fontSize: 9.5,
                                                fontWeight: FontWeight.bold,
                                                color: badgeColor,
                                              ),
                                            ),
                                          ),
                                          if (item.isWindowsExtension) ...[
                                            const SizedBox(width: 4),
                                            Container(
                                              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                                              decoration: BoxDecoration(
                                                color: Colors.amber.withValues(alpha: 0.15),
                                                borderRadius: BorderRadius.circular(4),
                                                border: Border.all(color: Colors.amber.withValues(alpha: 0.3), width: 0.5),
                                              ),
                                              child: const Text(
                                                '⚡ 开放工坊',
                                                style: TextStyle(
                                                  fontSize: 9.5,
                                                  fontWeight: FontWeight.bold,
                                                  color: Colors.amber,
                                                ),
                                              ),
                                            ),
                                          ],
                                        ],
                                      ),
                                    ],
                                  ),
                                ),
                                Icon(Icons.chevron_right, size: 20, color: textSecondary),
                              ],
                            ),
                            const SizedBox(height: 6),
                            Text(
                              item.description,
                              style: TextStyle(
                                fontSize: isMobile ? 11.5 : 12,
                                color: textSecondary,
                                height: 1.35,
                              ),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                  childCount: plugins.length,
                ),
              ),
            )
          else
            // 详细卡片模式（横屏/Windows/平板横版比例下：多列卡片自适应网格，充分利用空间）
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
              sliver: SliverGrid(
                gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                  maxCrossAxisExtent: 380,
                  mainAxisSpacing: 10,
                  crossAxisSpacing: 10,
                  mainAxisExtent: 145,
                ),
                delegate: SliverChildBuilderDelegate(
                  (ctx, index) {
                    final item = plugins[index];
                    final badgeColor = _getPlatformBadgeColor(item);
                    return _buildCardContainer(
                      context: context,
                      borderRadius: 12,
                      onTap: () {
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => DynamicToolRunnerPage(plugin: item),
                          ),
                        );
                      },
                      child: Padding(
                        padding: const EdgeInsets.all(14),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Container(
                                  width: 38,
                                  height: 38,
                                  decoration: BoxDecoration(
                                    color: theme.colorScheme.primary.withValues(alpha: 0.12),
                                    shape: BoxShape.circle,
                                  ),
                                  child: Icon(
                                    _getIconData(item.icon),
                                    size: 20,
                                    color: theme.colorScheme.primary,
                                  ),
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        item.name,
                                        style: TextStyle(
                                          fontWeight: FontWeight.bold,
                                          fontSize: 14.5,
                                          color: textPrimary,
                                        ),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                      const SizedBox(height: 2),
                                      Row(
                                        children: [
                                          Text(
                                            'v${item.version}',
                                            style: TextStyle(fontSize: 10.5, color: textSecondary),
                                          ),
                                          const SizedBox(width: 6),
                                          Container(
                                            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                                            decoration: BoxDecoration(
                                              color: badgeColor.withValues(alpha: 0.12),
                                              borderRadius: BorderRadius.circular(4),
                                              border: Border.all(color: badgeColor.withValues(alpha: 0.3), width: 0.5),
                                            ),
                                            child: Text(
                                              item.platformBadgeText,
                                              style: TextStyle(
                                                fontSize: 9.5,
                                                fontWeight: FontWeight.bold,
                                                color: badgeColor,
                                              ),
                                            ),
                                          ),
                                          if (item.isWindowsExtension) ...[
                                            const SizedBox(width: 4),
                                            Container(
                                              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                                              decoration: BoxDecoration(
                                                color: Colors.amber.withValues(alpha: 0.15),
                                                borderRadius: BorderRadius.circular(4),
                                                border: Border.all(color: Colors.amber.withValues(alpha: 0.3), width: 0.5),
                                              ),
                                              child: const Text(
                                                '⚡ 开放工坊',
                                                style: TextStyle(
                                                  fontSize: 9.5,
                                                  fontWeight: FontWeight.bold,
                                                  color: Colors.amber,
                                                ),
                                              ),
                                            ),
                                          ],
                                        ],
                                      ),
                                    ],
                                  ),
                                ),
                                Icon(Icons.chevron_right, size: 20, color: textSecondary),
                              ],
                            ),
                            const SizedBox(height: 8),
                            Expanded(
                              child: Text(
                                item.description,
                                style: TextStyle(
                                  fontSize: 12,
                                  color: textSecondary,
                                  height: 1.35,
                                ),
                                maxLines: 3,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                  childCount: plugins.length,
                ),
              ),
            ),
        ],
      );

    return Scaffold(
      body: isGlass
          ? Container(
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    Color(0xFFF0F4FF),
                    Color(0xFFE5EEFF),
                    Color(0xFFF3E8FF),
                    Color(0xFFE0F2FE),
                  ],
                ),
              ),
              child: bodyContent,
            )
          : bodyContent,
    );
  }
}
