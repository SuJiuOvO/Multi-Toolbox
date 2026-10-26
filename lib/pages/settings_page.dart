import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../services/app_update_service.dart';
import '../services/notification_service.dart';
import '../services/plugin_manager_service.dart';
import '../services/settings_service.dart';
import 'installed_plugins_manager_page.dart';
import '../theme/app_theme_manager.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  final SettingsService _settings = SettingsService();
  final PluginManagerService _pluginManager = PluginManagerService();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isMobile = MediaQuery.of(context).size.width < 768;

    return Scaffold(
      appBar: AppBar(
        title: const Text('系统设置与关于', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
        centerTitle: false,
      ),
      body: AnimatedBuilder(
        animation: _settings,
        builder: (context, _) {
          return ListView(
            padding: EdgeInsets.symmetric(
              horizontal: isMobile ? 14 : 28,
              vertical: 16,
            ),
            children: [
              // 1. App 头部卡片（新 3D 图标 + 软件信息）
              _buildAppHeaderCard(theme, isMobile),
              const SizedBox(height: 20),

              // 2. UI 主题风格切换
              _buildThemeSection(theme, isMobile),
              const SizedBox(height: 20),

              // 3. 后台任务与通知
              _buildBackgroundAndNotificationSection(theme),
              const SizedBox(height: 20),

              // 4. 网络与镜像节点
              _buildMirrorNetworkSection(theme),
              const SizedBox(height: 20),

              // 5. 插件与功能模块管理
              _buildPluginManagementSection(theme),
              const SizedBox(height: 20),

              // 6. 主页显示偏好
              _buildDisplayPreferencesSection(theme),
              const SizedBox(height: 20),

              // 6. 关于、官方网页与仓库链接
              _buildAboutAndLinksSection(theme),
              const SizedBox(height: 32),
            ],
          );
        },
      ),
    );
  }

  /// App 头部关于卡片
  Widget _buildAppHeaderCard(ThemeData theme, bool isMobile) {
    return Card(
      elevation: 1,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          gradient: LinearGradient(
            colors: [
              theme.colorScheme.primary.withValues(alpha: 0.08),
              theme.colorScheme.secondary.withValues(alpha: 0.03),
            ],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
        ),
        child: Row(
          children: [
            // 3D App 图标
            Container(
              width: 72,
              height: 72,
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: const Color(0xFFE2E8F0),
                  width: 1.2,
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.08),
                    blurRadius: 10,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              padding: const EdgeInsets.all(8),
              clipBehavior: Clip.antiAlias,
              child: Image.asset(
                'assets/app_icon.png',
                fit: BoxFit.contain,
                errorBuilder: (_, __, ___) => Container(
                  color: theme.colorScheme.primary,
                  child: const Icon(Icons.handyman_rounded, color: Colors.white, size: 36),
                ),
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(
                        '多功能百宝箱',
                        style: TextStyle(
                          fontSize: isMobile ? 18 : 20,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: theme.colorScheme.primary,
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: const Text(
                          'v1.0.0',
                          style: TextStyle(fontSize: 10, color: Colors.white, fontWeight: FontWeight.bold),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'Multi-Toolbox · 跨平台动态可扩展万能工具箱',
                    style: TextStyle(
                      fontSize: isMobile ? 11.5 : 12.5,
                      color: Colors.grey.shade700,
                      height: 1.3,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    '开源透明 · 离线隐私计算 · 免重新下载安装更新',
                    style: TextStyle(
                      fontSize: isMobile ? 10.5 : 11.5,
                      color: theme.colorScheme.primary,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// UI 主题风格定制卡片
  Widget _buildThemeSection(ThemeData theme, bool isMobile) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Padding(
          padding: EdgeInsets.only(left: 4, bottom: 8),
          child: Text(
            '🎨 界面视觉主题',
            style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
          ),
        ),
        Card(
          elevation: 0.8,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '选择您喜欢的 UI 风格（包含高质感暗黑与液态晶透毛玻璃）：',
                  style: TextStyle(fontSize: 12.5, color: Colors.grey),
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  children: AppThemeManager.options.map((option) {
                    final isSelected = _settings.themeId == option.id;
                    return InkWell(
                      onTap: () => _settings.setThemeId(option.id),
                      borderRadius: BorderRadius.circular(12),
                      child: Container(
                        width: isMobile ? 150 : 170,
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: option.previewBackground,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: isSelected ? option.primaryColor : Colors.grey.shade300,
                            width: isSelected ? 2 : 1,
                          ),
                          boxShadow: isSelected
                              ? [
                                  BoxShadow(
                                    color: option.primaryColor.withValues(alpha: 0.2),
                                    blurRadius: 8,
                                    offset: const Offset(0, 2),
                                  )
                                ]
                              : null,
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                CircleAvatar(
                                  radius: 12,
                                  backgroundColor: option.primaryColor,
                                  child: Icon(option.icon, size: 14, color: Colors.white),
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    option.name,
                                    style: TextStyle(
                                      fontWeight: FontWeight.bold,
                                      fontSize: 12.5,
                                      color: option.isDark ? Colors.white : Colors.black87,
                                    ),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                                if (isSelected)
                                  Icon(Icons.check_circle, size: 16, color: option.primaryColor),
                              ],
                            ),
                            const SizedBox(height: 6),
                            Text(
                              option.description,
                              style: TextStyle(
                                fontSize: 10.5,
                                color: option.isDark ? Colors.white70 : Colors.black54,
                                height: 1.3,
                              ),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                        ),
                      ),
                    );
                  }).toList(),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  /// 后台处理与系统通知
  Widget _buildBackgroundAndNotificationSection(ThemeData theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Padding(
          padding: EdgeInsets.only(left: 4, bottom: 8),
          child: Text(
            '⚙️ 后台运行与任务通知',
            style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
          ),
        ),
        Card(
          elevation: 0.8,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          child: Column(
            children: [
              SwitchListTile(
                title: const Text('返回后保持后台处理', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                subtitle: const Text(
                  '离开工具界面或最小化 App 时，继续在后台运行当前处理任务',
                  style: TextStyle(fontSize: 12, color: Colors.grey),
                ),
                value: _settings.runInBackground,
                onChanged: (val) => _settings.setRunInBackground(val),
              ),
              const Divider(height: 1, indent: 16, endIndent: 16),
              SwitchListTile(
                title: const Text('任务完成时发送系统通知', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                subtitle: const Text(
                  '当音视频压缩、格式转换或批量处理完成时，通过系统通知栏弹出提示',
                  style: TextStyle(fontSize: 12, color: Colors.grey),
                ),
                value: _settings.notifyOnComplete,
                onChanged: (val) async {
                  if (val) {
                    await NotificationService().requestPermission();
                  }
                  _settings.setNotifyOnComplete(val);
                },
              ),
              const Divider(height: 1, indent: 16, endIndent: 16),
              ListTile(
                title: const Text('通知权限与测试', style: TextStyle(fontSize: 14)),
                subtitle: const Text('发送一条测试通知以验证系统通知权限是否生效', style: TextStyle(fontSize: 12, color: Colors.grey)),
                trailing: OutlinedButton.icon(
                  onPressed: () async {
                    await NotificationService().showTaskNotification(
                      title: '【测试通知】多功能百宝箱',
                      body: '后台任务通知服务正常工作！文件转换完成后将在此提醒。',
                    );
                    if (mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('已触发测试通知，请查看手机/系统通知栏')),
                      );
                    }
                  },
                  icon: const Icon(Icons.notifications_active, size: 16),
                  label: const Text('发送测试'),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// 镜像节点与网络加速
  Widget _buildMirrorNetworkSection(ThemeData theme) {
    final activeNode = _pluginManager.currentActiveNode;
    final host = Uri.tryParse(activeNode.indexUrl)?.host ?? activeNode.name;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Padding(
          padding: EdgeInsets.only(left: 4, bottom: 8),
          child: Text(
            '🌐 网络与镜像加速',
            style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
          ),
        ),
        Card(
          elevation: 0.8,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          child: ListTile(
            leading: CircleAvatar(
              backgroundColor: theme.colorScheme.primaryContainer,
              child: Icon(Icons.cloud_sync, color: theme.colorScheme.primary, size: 20),
            ),
            title: Text('当前镜像加速源：${activeNode.name}', style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
            subtitle: Text(
              '节点 ID：${activeNode.id} | 主机：$host',
              style: const TextStyle(fontSize: 11.5, color: Colors.grey),
            ),
            trailing: FilledButton.tonal(
              onPressed: () => _showMirrorNodeDialog(context),
              child: const Text('切换 / 测速'),
            ),
          ),
        ),
      ],
    );
  }

  /// 主页偏好与横幅设置
  Widget _buildDisplayPreferencesSection(ThemeData theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Padding(
          padding: EdgeInsets.only(left: 4, bottom: 8),
          child: Text(
            '📋 主页显示与搜索偏好',
            style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
          ),
        ),
        Card(
          elevation: 0.8,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          child: Column(
            children: [
              SwitchListTile(
                title: const Text('显示客户端免重下说明横幅', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                subtitle: const Text(
                  '在主页顶部展示“动态扩展与免重新下载安装”特性介绍',
                  style: TextStyle(fontSize: 12, color: Colors.grey),
                ),
                value: !_settings.bannerDismissedPermanently,
                onChanged: (val) {
                  _settings.setBannerDismissedPermanently(!val);
                },
              ),
              const Divider(height: 1, indent: 16, endIndent: 16),
              SwitchListTile(
                title: const Text('默认启用深度搜索', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                subtitle: const Text(
                  '搜索时深入匹配功能简介、算法说明及参数选项',
                  style: TextStyle(fontSize: 12, color: Colors.grey),
                ),
                value: _settings.deepSearchDefault,
                onChanged: (val) => _settings.setDeepSearchDefault(val),
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// 插件与功能模块管理入口
  Widget _buildPluginManagementSection(ThemeData theme) {
    return Card(
      elevation: 1,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Row(
              children: [
                const Icon(Icons.tune_rounded, size: 20, color: AppThemeManager.accentBlue),
                const SizedBox(width: 8),
                Text(
                  '插件与功能模块管理',
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 15,
                    color: theme.colorScheme.onSurface,
                  ),
                ),
              ],
            ),
          ),
          ListTile(
            leading: Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: AppThemeManager.accentBlue.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Icon(Icons.extension_outlined, color: AppThemeManager.accentBlue, size: 20),
            ),
            title: const Text('已安装模块管理与卸载', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
            subtitle: const Text('集中查看、搜索与安全卸载扩展及本地导入模块', style: TextStyle(fontSize: 12)),
            trailing: const Icon(Icons.chevron_right, size: 20),
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => const InstalledPluginsManagerPage(),
                ),
              );
            },
          ),
        ],
      ),
    );
  }

  /// 关于与网页/仓库链接
  Widget _buildAboutAndLinksSection(ThemeData theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Padding(
          padding: EdgeInsets.only(left: 4, bottom: 8),
          child: Text(
            'ℹ️ 关于 Multi-Toolbox 与官方网页',
            style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
          ),
        ),
        Card(
          elevation: 0.8,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          child: Column(
            children: [
              _buildLinkTile(
                icon: Icons.code_rounded,
                title: 'GitHub 客户端开源主仓',
                subtitle: 'https://github.com/SuJiuOvO/Multi-Toolbox',
                url: 'https://github.com/SuJiuOvO/Multi-Toolbox',
              ),
              const Divider(height: 1, indent: 16, endIndent: 16),
              _buildLinkTile(
                icon: Icons.storage_rounded,
                title: 'Gitee 镜像仓库 (国内高速同步)',
                subtitle: 'https://gitee.com/sujiuovo/multi-toolbox',
                url: 'https://gitee.com/sujiuovo/multi-toolbox',
              ),
              const Divider(height: 1, indent: 16, endIndent: 16),
              _buildLinkTile(
                icon: Icons.extension_rounded,
                title: '社区插件生态注册表 (Registry)',
                subtitle: 'https://github.com/SuJiuOvO/Toolbox-Community-Registry',
                url: 'https://github.com/SuJiuOvO/Toolbox-Community-Registry',
              ),
              const Divider(height: 1, indent: 16, endIndent: 16),
              ListTile(
                leading: CircleAvatar(
                  backgroundColor: theme.colorScheme.primaryContainer,
                  child: Icon(Icons.system_update_alt_rounded, color: theme.colorScheme.primary, size: 20),
                ),
                title: const Text('检查新版本更新', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                subtitle: const Text('检查 GitHub / Gitee 官方是否有新版本客户端发布', style: TextStyle(fontSize: 12, color: Colors.grey)),
                trailing: OutlinedButton(
                  onPressed: () => _checkUpdate(context),
                  child: const Text('立即检查'),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildLinkTile({
    required IconData icon,
    required String title,
    required String subtitle,
    required String url,
  }) {
    return ListTile(
      leading: CircleAvatar(
        backgroundColor: Colors.blue.withValues(alpha: 0.1),
        child: Icon(icon, color: Colors.blueAccent, size: 20),
      ),
      title: Text(title, style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600)),
      subtitle: Text(
        subtitle,
        style: const TextStyle(fontSize: 11, color: Colors.blueGrey),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: IconButton(
        icon: const Icon(Icons.copy_rounded, size: 18),
        tooltip: '复制链接',
        onPressed: () {
          Clipboard.setData(ClipboardData(text: url));
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('已复制链接到剪贴板: $url')),
          );
        },
      ),
    );
  }

  Future<void> _checkUpdate(BuildContext context) async {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => const Center(
        child: Card(
          child: Padding(
            padding: EdgeInsets.all(20),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                CircularProgressIndicator(),
                SizedBox(width: 16),
                Text('正在检测新版本...'),
              ],
            ),
          ),
        ),
      ),
    );

    final updateInfo = await AppUpdateService().checkUpdate();
    if (!context.mounted) return;
    Navigator.of(context, rootNavigator: true).pop();

    if (updateInfo == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('已是最新版本或检查更新超时')),
      );
      return;
    }

    if (!updateInfo.hasUpdate) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('当前已是最新版本 (v${PluginManagerService.currentAppVersion})')),
      );
      return;
    }

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Row(
          children: [
            const Icon(Icons.system_update_rounded, color: Colors.blueAccent),
            const SizedBox(width: 8),
            Text('发现新版本 v${updateInfo.latestVersion}'),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('当前版本: v${PluginManagerService.currentAppVersion}'),
            Text('最新版本: v${updateInfo.latestVersion}'),
            const SizedBox(height: 8),
            Text('更新日志:\n${updateInfo.releaseNotes}'),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('稍后')),
          FilledButton(
            onPressed: () {
              Navigator.pop(ctx);
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('请前往主页点击更新或访问 GitHub/Gitee Releases 下载新安装包')),
              );
            },
            child: const Text('了解详情'),
          ),
        ],
      ),
    );
  }

  void _showMirrorNodeDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (dialogCtx, setDialogState) {
            final nodes = _pluginManager.allNodes;
            return AlertDialog(
              title: const Row(
                children: [
                  Icon(Icons.network_check_rounded, color: Colors.blueAccent),
                  SizedBox(width: 8),
                  Text('选择社区镜像源', style: TextStyle(fontSize: 16)),
                ],
              ),
              content: SizedBox(
                width: double.maxFinite,
                child: ListView.separated(
                  shrinkWrap: true,
                  itemCount: nodes.length,
                  separatorBuilder: (_, __) => const Divider(height: 8),
                  itemBuilder: (_, index) {
                    final node = nodes[index];
                    final isCurrent = _pluginManager.currentActiveNode.id == node.id;
                    return ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(
                        node.id == 'gitee'
                            ? Icons.flash_on
                            : (node.id == 'jsdelivr' ? Icons.speed : Icons.public),
                        color: isCurrent ? Colors.green : Colors.grey,
                      ),
                      title: Text(node.name, style: TextStyle(fontWeight: isCurrent ? FontWeight.bold : FontWeight.normal)),
                      subtitle: Text(
                        'ID: ${node.id} · ${Uri.tryParse(node.indexUrl)?.host ?? node.indexUrl}',
                        style: const TextStyle(fontSize: 11),
                      ),
                      trailing: isCurrent
                          ? const Chip(
                              label: Text('当前使用', style: TextStyle(fontSize: 10, color: Colors.green)),
                              visualDensity: VisualDensity.compact,
                              padding: EdgeInsets.zero,
                            )
                          : OutlinedButton(
                              onPressed: () async {
                                await _pluginManager.setNodeMode(node.id);
                                setDialogState(() {});
                                setState(() {});
                                if (context.mounted) {
                                  Navigator.pop(ctx);
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(content: Text('已切换至镜像源：${node.name}')),
                                  );
                                }
                              },
                              child: const Text('使用此源', style: TextStyle(fontSize: 11)),
                            ),
                    );
                  },
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('关闭'),
                ),
              ],
            );
          },
        );
      },
    );
  }
}
