import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import '../models/plugin_manifest.dart';
import '../services/plugin_manager_service.dart';
import '../theme/app_theme_manager.dart';
import '../widgets/plugin_icon_widget.dart';
import 'dynamic_tool_runner_page.dart';
import 'plugin_store_page.dart';

/// 插件与功能模块管理页面
/// 支持：
/// 1. 本地安装模块与云端市场安装模块的集中查看；
/// 2. 区分【本地导入】、【市场安装】与【内置核心】来源；
/// 3. 本地与第三方模块的一键安全卸载；
/// 4. 实时关键字搜索与多维度分类筛选；
/// 5. 全平台自适应布局（Windows 桌面宽屏网格 / Android 移动端触控卡片）；
/// 6. 深色/浅色主题智能切换适配。
class InstalledPluginsManagerPage extends StatefulWidget {
  final VoidCallback? onInstalledChanged;

  const InstalledPluginsManagerPage({
    super.key,
    this.onInstalledChanged,
  });

  @override
  State<InstalledPluginsManagerPage> createState() => _InstalledPluginsManagerPageState();
}

class _InstalledPluginsManagerPageState extends State<InstalledPluginsManagerPage> {
  final PluginManagerService _pluginManager = PluginManagerService();
  final TextEditingController _searchController = TextEditingController();

  String _searchQuery = '';
  String _selectedFilter = 'all'; // all, non_builtin, local, store, builtin
  bool _isLoading = false;

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadData({bool silent = false}) async {
    if (!silent) {
      setState(() => _isLoading = true);
    }
    await _pluginManager.loadInstalledPlugins();
    // 异步拉取一次远程注册中心（若未拉取过），以便区分市场安装与纯本地导入
    if (_pluginManager.remotePlugins.isEmpty) {
      _pluginManager.fetchRemoteRegistry().then((_) {
        if (mounted) setState(() {});
      });
    }
    if (!mounted) return;
    setState(() => _isLoading = false);
  }

  bool _isStorePlugin(String pluginId) {
    return _pluginManager.remotePlugins.any((r) => r.id == pluginId);
  }

  /// 本地安装功能模块 (.json / .zip)
  Future<void> _pickAndInstallLocalPlugin() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['json', 'zip'],
        dialogTitle: '选择本地插件文件 (.json 或 .zip 安装包)',
        lockParentWindow: true,
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
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircularProgressIndicator(),
                  SizedBox(width: 20),
                  Text('正在校验并安装本地功能模块...'),
                ],
              ),
            ),
          ),
        ),
      );

      final installResult = await _pluginManager.installLocalPlugin(filePath);
      if (!mounted) return;
      Navigator.pop(context); // 关闭加载圈

      if (installResult.success) {
        widget.onInstalledChanged?.call();
        await _loadData(silent: true);
        if (!mounted) return;
        showDialog(
          context: context,
          builder: (ctx) => AlertDialog(
            icon: const Icon(Icons.check_circle_rounded, color: Colors.green, size: 48),
            title: const Text('安装成功'),
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

  /// 关联本地源码开发目录 (免打包实时调试)
  Future<void> _pickAndLinkDevPlugin() async {
    try {
      final selectedDir = await FilePicker.platform.getDirectoryPath(
        dialogTitle: '选择插件源码开发目录 (必须包含 manifest.json)',
        lockParentWindow: true,
      );

      if (selectedDir == null || selectedDir.isEmpty) return;

      if (!mounted) return;
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => const Center(
          child: Card(
            elevation: 8,
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: 24, vertical: 20),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircularProgressIndicator(),
                  SizedBox(width: 20),
                  Text('正在校验开发目录并建立调试关联...'),
                ],
              ),
            ),
          ),
        ),
      );

      final linkResult = await _pluginManager.linkDevPluginDirectory(selectedDir);
      if (!mounted) return;
      Navigator.pop(context); // 关闭加载框

      if (linkResult.success) {
        widget.onInstalledChanged?.call();
        await _loadData(silent: true);
        if (!mounted) return;
        showDialog(
          context: context,
          builder: (ctx) => AlertDialog(
            icon: const Icon(Icons.construction_rounded, color: Colors.indigo, size: 48),
            title: const Text('开发调试模式已就绪'),
            content: SelectableText(linkResult.message),
            actions: [
              FilledButton(
                onPressed: () {
                  Navigator.pop(ctx);
                  if (linkResult.plugin != null) {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => DynamicToolRunnerPage(plugin: linkResult.plugin!),
                      ),
                    );
                  }
                },
                child: const Text('立即进入测试'),
              ),
            ],
          ),
        );
      } else {
        if (!mounted) return;
        showDialog(
          context: context,
          builder: (ctx) => AlertDialog(
            icon: const Icon(Icons.error_outline_rounded, color: Colors.redAccent, size: 48),
            title: const Text('关联失败'),
            content: SelectableText(linkResult.message),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('关闭')),
            ],
          ),
        );
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('选择目录异常: $e')));
    }
  }

  /// 卸载插件
  Future<void> _uninstallPlugin(PluginManifest plugin) async {
    final theme = Theme.of(context);
    final isDev = plugin.isDevLink;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Row(
          children: [
            Icon(isDev ? Icons.link_off_rounded : Icons.warning_amber_rounded, color: isDev ? Colors.orange : Colors.redAccent, size: 24),
            const SizedBox(width: 8),
            Text(isDev ? '解除调试关联确认' : '卸载模块确认', style: TextStyle(color: theme.colorScheme.onSurface)),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(isDev ? '确定要解除对开发目录【${plugin.name}】的调试关联吗？' : '确定要卸载功能模块【${plugin.name}】（v${plugin.version}）吗？'),
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: (isDev ? Colors.orange : Colors.redAccent).withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: (isDev ? Colors.orange : Colors.redAccent).withValues(alpha: 0.2)),
              ),
              child: Text(
                isDev
                    ? '此操作仅从客户端中移除调试快捷关联，绝对不会删除你的源码开发目录：\n${plugin.localDir}'
                    : '卸载后将永久删除该模块存储在本地的所有程序代码、依赖组件及私有配置文件。',
                style: TextStyle(fontSize: 12, color: isDev ? Colors.orange.shade800 : Colors.redAccent, height: 1.4),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: isDev ? Colors.orange : Colors.redAccent),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(isDev ? '解除关联' : '确认卸载'),
          ),
        ],
      ),
    );

    if (confirm == true) {
      final success = await _pluginManager.uninstallPlugin(plugin.id);
      if (!mounted) return;

      if (success) {
        widget.onInstalledChanged?.call();
        await _loadData(silent: true);
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('模块【${plugin.name}】已成功卸载并清理！'),
            backgroundColor: Colors.green,
            duration: const Duration(seconds: 3),
          ),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('模块【${plugin.name}】卸载失败，请检查文件是否被占用。'),
            backgroundColor: Colors.redAccent,
          ),
        );
      }
    }
  }

  void _openPlugin(PluginManifest plugin) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => DynamicToolRunnerPage(plugin: plugin),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final screenWidth = MediaQuery.of(context).size.width;
    final isMobile = screenWidth < 768;

    final allPlugins = _pluginManager.installedPlugins;

    // 统计各类型数量
    final totalCount = allPlugins.length;
    final builtinCount = allPlugins.where((p) => p.isBuiltIn).length;
    final nonBuiltinCount = totalCount - builtinCount;
    final storeCount = allPlugins.where((p) => !p.isBuiltIn && _isStorePlugin(p.id)).length;
    final localCount = allPlugins.where((p) => !p.isBuiltIn && !_isStorePlugin(p.id)).length;

    // 筛选过滤
    final filteredPlugins = allPlugins.where((p) {
      if (_selectedFilter == 'non_builtin' && p.isBuiltIn) return false;
      if (_selectedFilter == 'builtin' && !p.isBuiltIn) return false;
      if (_selectedFilter == 'local' && (p.isBuiltIn || _isStorePlugin(p.id))) return false;
      if (_selectedFilter == 'store' && (p.isBuiltIn || !_isStorePlugin(p.id))) return false;

      if (_searchQuery.trim().isNotEmpty) {
        final q = _searchQuery.trim().toLowerCase();
        final nameMatch = p.name.toLowerCase().contains(q);
        final descMatch = p.description.toLowerCase().contains(q);
        final idMatch = p.id.toLowerCase().contains(q);
        final catMatch = p.category.toLowerCase().contains(q);
        final authorMatch = p.author.toLowerCase().contains(q);
        final badgeMatch = p.platformBadgeText.toLowerCase().contains(q);
        return nameMatch || descMatch || idMatch || catMatch || authorMatch || badgeMatch;
      }
      return true;
    }).toList();

    final textPrimary = isDark ? Colors.white : const Color(0xFF1E293B);
    final textSecondary = isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B);
    final searchBg = isDark ? const Color(0xFF1E293B) : const Color(0xFFF1F5F9);
    final searchBorder = isDark ? const Color(0xFF334155) : const Color(0xFFE2E8F0);

    return Scaffold(
      appBar: AppBar(
        title: const Text(
          '插件与模块管理',
          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
        ),
        actions: [
          if (isMobile) ...[
            IconButton(
              icon: const Icon(Icons.code_rounded, color: Colors.indigo),
              tooltip: '关联本地开发目录',
              onPressed: _pickAndLinkDevPlugin,
            ),
            IconButton(
              icon: const Icon(Icons.file_upload_outlined, color: AppThemeManager.accentBlue),
              tooltip: '本地安装模块',
              onPressed: _pickAndInstallLocalPlugin,
            ),
            IconButton(
              icon: const Icon(Icons.add_shopping_cart_outlined, color: AppThemeManager.accentGreen),
              tooltip: '插件市场',
              onPressed: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => PluginStorePage(onInstalledChanged: widget.onInstalledChanged ?? () {}),
                  ),
                ).then((_) => _loadData(silent: true));
              },
            ),
            IconButton(
              icon: const Icon(Icons.refresh),
              tooltip: '刷新列表',
              onPressed: () => _loadData(),
            ),
          ] else ...[
            OutlinedButton.icon(
              onPressed: _pickAndLinkDevPlugin,
              icon: const Icon(Icons.code_rounded, size: 16),
              label: const Text('关联开发目录'),
            ),
            const SizedBox(width: 8),
            OutlinedButton.icon(
              onPressed: _pickAndInstallLocalPlugin,
              icon: const Icon(Icons.file_upload_outlined, size: 16),
              label: const Text('本地安装模块'),
            ),
            const SizedBox(width: 8),
            FilledButton.icon(
              onPressed: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => PluginStorePage(onInstalledChanged: widget.onInstalledChanged ?? () {}),
                  ),
                ).then((_) => _loadData(silent: true));
              },
              icon: const Icon(Icons.add_shopping_cart_outlined, size: 16),
              label: const Text('前往插件市场'),
            ),
            const SizedBox(width: 4),
            IconButton(
              icon: const Icon(Icons.refresh),
              tooltip: '刷新已安装列表',
              onPressed: () => _loadData(),
            ),
            const SizedBox(width: 8),
          ],
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () => _loadData(silent: true),
        child: Column(
          children: [
            // 搜索与快捷统计头部
            Container(
              padding: EdgeInsets.symmetric(
                horizontal: isMobile ? 12 : 20,
                vertical: 10,
              ),
              decoration: BoxDecoration(
                color: theme.scaffoldBackgroundColor,
                border: Border(
                  bottom: BorderSide(
                    color: isDark ? const Color(0xFF334155).withValues(alpha: 0.5) : const Color(0xFFE2E8F0),
                    width: 1,
                  ),
                ),
              ),
              child: Column(
                children: [
                  // 搜索输入框
                  TextField(
                    controller: _searchController,
                    style: TextStyle(fontSize: 14, color: textPrimary),
                    decoration: InputDecoration(
                      filled: true,
                      fillColor: searchBg,
                      hintText: '搜索已安装模块（名称、功能简介、分类、ID或作者）...',
                      hintStyle: TextStyle(fontSize: 13, color: textSecondary.withValues(alpha: 0.7)),
                      prefixIcon: const Icon(Icons.search, size: 20),
                      suffixIcon: _searchQuery.isNotEmpty
                          ? IconButton(
                              icon: const Icon(Icons.clear, size: 18),
                              onPressed: () {
                                _searchController.clear();
                                setState(() => _searchQuery = '');
                              },
                            )
                          : null,
                      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                        borderSide: BorderSide(color: searchBorder),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                        borderSide: BorderSide(color: searchBorder),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                        borderSide: const BorderSide(color: AppThemeManager.accentBlue, width: 1.5),
                      ),
                    ),
                    onChanged: (val) {
                      setState(() => _searchQuery = val);
                    },
                  ),
                  const SizedBox(height: 10),

                  // 分类筛选 Chip 条
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: [
                        _buildFilterChip('all', '全部 ($totalCount)', isDark),
                        const SizedBox(width: 8),
                        _buildFilterChip('non_builtin', '第三方与扩展 ($nonBuiltinCount)', isDark),
                        const SizedBox(width: 8),
                        _buildFilterChip('local', '本地导入 ($localCount)', isDark),
                        const SizedBox(width: 8),
                        _buildFilterChip('store', '市场安装 ($storeCount)', isDark),
                        const SizedBox(width: 8),
                        _buildFilterChip('builtin', '内置核心 ($builtinCount)', isDark),
                      ],
                    ),
                  ),
                ],
              ),
            ),

            // 模块列表内容区
            Expanded(
              child: _isLoading
                  ? const Center(child: CircularProgressIndicator())
                  : filteredPlugins.isEmpty
                      ? _buildEmptyView(textPrimary, textSecondary)
                      : isMobile
                          ? _buildMobileList(filteredPlugins, isDark, textPrimary, textSecondary)
                          : _buildDesktopGrid(filteredPlugins, screenWidth, isDark, textPrimary, textSecondary),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFilterChip(String filterKey, String label, bool isDark) {
    final isSelected = _selectedFilter == filterKey;
    return ChoiceChip(
      label: Text(label),
      selected: isSelected,
      labelStyle: TextStyle(
        fontSize: 12,
        fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
        color: isSelected
            ? Colors.white
            : (isDark ? const Color(0xFFCBD5E1) : const Color(0xFF475569)),
      ),
      selectedColor: AppThemeManager.accentBlue,
      backgroundColor: isDark ? const Color(0xFF1E293B) : const Color(0xFFF1F5F9),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      onSelected: (_) {
        setState(() => _selectedFilter = filterKey);
      },
    );
  }

  Widget _buildEmptyView(Color textPrimary, Color textSecondary) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              _searchQuery.isNotEmpty ? Icons.search_off_rounded : Icons.extension_off_rounded,
              size: 56,
              color: textSecondary.withValues(alpha: 0.4),
            ),
            const SizedBox(height: 14),
            Text(
              _searchQuery.isNotEmpty ? '未找到包含 “$_searchQuery” 的已安装模块' : '当前暂无符合条件的插件模块',
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: textPrimary),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              _searchQuery.isNotEmpty ? '请尝试更换搜索关键字或切换上方筛选分类' : '您可以从本地导入 .zip / .json 安装包，或前往云端市场下载丰富工具。',
              style: TextStyle(fontSize: 12.5, color: textSecondary, height: 1.4),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 18),
            if (_searchQuery.isNotEmpty)
              OutlinedButton.icon(
                onPressed: () {
                  _searchController.clear();
                  setState(() => _searchQuery = '');
                },
                icon: const Icon(Icons.clear, size: 16),
                label: const Text('清空搜索条件'),
              )
            else
              FilledButton.icon(
                onPressed: _pickAndInstallLocalPlugin,
                icon: const Icon(Icons.file_upload_outlined, size: 16),
                label: const Text('本地安装新插件'),
              ),
          ],
        ),
      ),
    );
  }

  /// 桌面端网格视图
  Widget _buildDesktopGrid(
    List<PluginManifest> list,
    double screenWidth,
    bool isDark,
    Color textPrimary,
    Color textSecondary,
  ) {
    final crossAxisCount = screenWidth >= 1200 ? 3 : 2;

    return GridView.builder(
      padding: const EdgeInsets.all(16),
      physics: const AlwaysScrollableScrollPhysics(parent: BouncingScrollPhysics()),
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: crossAxisCount,
        mainAxisSpacing: 14,
        crossAxisSpacing: 14,
        childAspectRatio: crossAxisCount == 3 ? 1.55 : 1.7,
      ),
      itemCount: list.length,
      itemBuilder: (context, index) {
        return _buildPluginCard(list[index], isDark, textPrimary, textSecondary, isDesktop: true);
      },
    );
  }

  /// 移动端列表视图
  Widget _buildMobileList(
    List<PluginManifest> list,
    bool isDark,
    Color textPrimary,
    Color textSecondary,
  ) {
    return ListView.separated(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      physics: const AlwaysScrollableScrollPhysics(parent: BouncingScrollPhysics()),
      itemCount: list.length,
      separatorBuilder: (_, __) => const SizedBox(height: 10),
      itemBuilder: (context, index) {
        return _buildPluginCard(list[index], isDark, textPrimary, textSecondary, isDesktop: false);
      },
    );
  }

  /// 插件卡片渲染
  Widget _buildPluginCard(
    PluginManifest plugin,
    bool isDark,
    Color textPrimary,
    Color textSecondary, {
    required bool isDesktop,
  }) {
    final isBuiltIn = plugin.isBuiltIn;
    final isStore = !isBuiltIn && _isStorePlugin(plugin.id);
    final isLocal = !isBuiltIn && !isStore;

    final cardBg = isDark ? const Color(0xFF1E293B) : Colors.white;
    final cardBorder = isDark ? const Color(0xFF334155) : const Color(0xFFE2E8F0);

    return Container(
      decoration: BoxDecoration(
        color: cardBg,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: cardBorder, width: 1.2),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: isDark ? 0.2 : 0.04),
            blurRadius: 8,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 头部：图标 + 标题 + 来源 Badge + 版本
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                PluginIconWidget(manifest: plugin, size: 28),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              plugin.name,
                              style: TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.bold,
                                color: textPrimary,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          const SizedBox(width: 6),
                          _buildOriginBadge(
                            isBuiltIn: isBuiltIn,
                            isStore: isStore,
                            isLocal: isLocal,
                            isDevLink: plugin.isDevLink,
                            isDark: isDark,
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          Text(
                            'v${plugin.version}',
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                              color: textSecondary,
                            ),
                          ),
                          const SizedBox(width: 8),
                          _buildPlatformBadge(plugin, isDark),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),

            // 功能简介描述
            Expanded(
              child: Text(
                plugin.description,
                style: TextStyle(
                  fontSize: 12.5,
                  color: textSecondary,
                  height: 1.35,
                ),
                maxLines: isDesktop ? 2 : 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(height: 6),

            // 元信息行：作者与 ID
            Row(
              children: [
                Expanded(
                  child: Text(
                    '作者: ${plugin.author} · 分类: ${plugin.category}',
                    style: TextStyle(fontSize: 11, color: textSecondary.withValues(alpha: 0.8)),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),

            // 底部操作按钮栏
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                // 卸载按钮
                if (!isBuiltIn)
                  OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.redAccent,
                      side: const BorderSide(color: Colors.redAccent, width: 1.2),
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                      visualDensity: VisualDensity.compact,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                    ),
                    icon: const Icon(Icons.delete_outline_rounded, size: 15),
                    label: const Text('卸载模块', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                    onPressed: () => _uninstallPlugin(plugin),
                  )
                else
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: isDark ? const Color(0xFF334155).withValues(alpha: 0.5) : const Color(0xFFF1F5F9),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.lock_outline_rounded, size: 13, color: textSecondary),
                        const SizedBox(width: 4),
                        Text(
                          '系统核心内置',
                          style: TextStyle(fontSize: 11, color: textSecondary, fontWeight: FontWeight.w500),
                        ),
                      ],
                    ),
                  ),
                const SizedBox(width: 8),

                // 打开运行按钮
                FilledButton.tonalIcon(
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                    visualDensity: VisualDensity.compact,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                  ),
                  icon: const Icon(Icons.play_arrow_rounded, size: 17),
                  label: const Text('进入工具', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                  onPressed: () => _openPlugin(plugin),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// 来源 Badge
  Widget _buildOriginBadge({
    required bool isBuiltIn,
    required bool isStore,
    required bool isLocal,
    required bool isDevLink,
    required bool isDark,
  }) {
    final String label;
    final Color color;
    final IconData icon;

    if (isDevLink) {
      label = '本地调试';
      color = Colors.indigo;
      icon = Icons.construction_rounded;
    } else if (isBuiltIn) {
      label = '内置';
      color = isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B);
      icon = Icons.verified_user_rounded;
    } else if (isLocal) {
      label = '本地导入';
      color = Colors.orange;
      icon = Icons.folder_zip_rounded;
    } else {
      label = '市场安装';
      color = const Color(0xFF10B981);
      icon = Icons.cloud_download_rounded;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: color.withValues(alpha: 0.3), width: 0.8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 11, color: color),
          const SizedBox(width: 3),
          Text(
            label,
            style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.bold, color: color),
          ),
        ],
      ),
    );
  }

  /// 平台 Badge
  Widget _buildPlatformBadge(PluginManifest plugin, bool isDark) {
    final text = plugin.platformBadgeText;
    Color color = AppThemeManager.accentBlue;

    if (plugin.isDualAdaptivePlugin) {
      color = const Color(0xFF6366F1); // 自适应 靛蓝紫色
    } else if (plugin.isWasmPlugin) {
      color = const Color(0xFFDC2626); // Wasm 红色
    } else if (plugin.isWindowsExtension) {
      color = const Color(0xFF0284C7); // Win 蓝色
    } else if (plugin.isQuickJsPlugin) {
      color = const Color(0xFFD97706); // JS 黄橙色
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        text,
        style: TextStyle(fontSize: 10, fontWeight: FontWeight.w600, color: color),
      ),
    );
  }
}
