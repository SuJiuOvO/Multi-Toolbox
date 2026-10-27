import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:open_filex/open_filex.dart';
import '../models/plugin_manifest.dart';
import '../widgets/plugin_icon_widget.dart';
import '../services/app_update_service.dart';
import '../services/plugin_manager_service.dart';
import 'installed_plugins_manager_page.dart';

class PluginStorePage extends StatefulWidget {
  final VoidCallback onInstalledChanged;

  const PluginStorePage({super.key, required this.onInstalledChanged});

  @override
  State<PluginStorePage> createState() => _PluginStorePageState();
}

class _PluginStorePageState extends State<PluginStorePage> {
  final PluginManagerService _pluginManager = PluginManagerService();
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';
  bool _isLoading = true;
  String? _downloadingPluginId;
  double _downloadProgress = 0.0;
  String _downloadStatus = '';
  String _selectedScope = 'all'; // 'all', 'official', 'community', 'win_ext'
  Map<String, int> _nodePingResults = {};
  bool _isPingingNodes = false;

  @override
  void initState() {
    super.initState();
    _refreshStore();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Color _getPlatformBadgeColor(PluginManifest item) {
    if (item.isDualAdaptivePlugin) return const Color(0xFF6366F1);
    if (item.isWindowsOnly()) return const Color(0xFF0284C7);
    if (item.isAndroidOnly()) return const Color(0xFF16A34A);
    return const Color(0xFF4F46E5);
  }

  void _openInstalledManager() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => InstalledPluginsManagerPage(onInstalledChanged: widget.onInstalledChanged),
      ),
    ).then((_) => _refreshStore(silent: true));
  }

  Future<void> _refreshStore({bool silent = false}) async {
    if (!silent) {
      setState(() => _isLoading = true);
    }
    await _pluginManager.fetchRemoteRegistry();
    if (!mounted) return;
    setState(() => _isLoading = false);
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
        widget.onInstalledChanged();
        await _refreshStore(silent: true);
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
        SnackBar(content: Text('选择文件或执行本地安装出错: $e')),
      );
    }
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
                Text('正在连接镜像节点检查客户端更新...'),
              ],
            ),
          ),
        ),
      ),
    );

    final updateInfo = await AppUpdateService().checkUpdate();
    if (!mounted) return;
    Navigator.of(context, rootNavigator: true).pop(); // 关闭 loading

    if (updateInfo == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('检查更新失败，请检查网络或切换可用镜像节点')),
      );
      return;
    }

    if (!updateInfo.hasUpdate) {
      showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          icon: const Icon(Icons.verified_rounded, color: Colors.green, size: 46),
          title: const Text('已是最新版本'),
          content: Text('当前客户端版本 (v${PluginManagerService.currentAppVersion}) 运行正常，无需更新。'),
          actions: [
            FilledButton(onPressed: () => Navigator.pop(ctx), child: const Text('确定')),
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
                          updateStatus = '准备启动下载...';
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
                            updateStatus = '下载升级失败，请稍后重试或前往项目仓库下载。';
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

  /// 节点测速与换源对话框
  void _showNodeSelectionDialog() {
    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (dialogCtx, setDialogState) {
          final currentMode = _pluginManager.selectedNodeMode;
          final allNodes = _pluginManager.allNodes;

          return AlertDialog(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            title: Row(
              children: [
                const Icon(Icons.wifi_tethering_rounded, color: Colors.blueAccent),
                const SizedBox(width: 8),
                const Text('网络镜像节点与多源配置', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
              ],
            ),
            content: SizedBox(
              width: 520,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      '百宝箱支持在国内/国际复杂网络下自动故障转移。您可以保持「智能竞速」，或指定首选线路：',
                      style: TextStyle(fontSize: 12, color: Colors.black54),
                    ),
                    const SizedBox(height: 12),

                    // 智能优选选项
                    RadioListTile<String>(
                      value: 'auto',
                      groupValue: currentMode,
                      title: const Row(
                        children: [
                          Text('🚀 智能竞速（推荐）', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13.5)),
                          SizedBox(width: 6),
                          Chip(
                            label: Text('自动降级', style: TextStyle(fontSize: 10, color: Colors.green)),
                            visualDensity: VisualDensity.compact,
                            padding: EdgeInsets.zero,
                          ),
                        ],
                      ),
                      subtitle: Text(
                        '并发检测各镜像节点响应时间，自动选用当前最快可用线路 (当前: ${_pluginManager.currentActiveNode.name})',
                        style: const TextStyle(fontSize: 11),
                      ),
                      onChanged: (val) async {
                        if (val != null) {
                          await _pluginManager.setNodeMode(val);
                          setDialogState(() {});
                          if (mounted) setState(() {});
                        }
                      },
                    ),

                    const Divider(height: 16),
                    const Text('可选镜像节点列表：', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                    const SizedBox(height: 6),

                    // 节点列表
                    ...allNodes.map((node) {
                      final latency = _nodePingResults[node.id];
                      String latencyText = '未测速';
                      Color latencyColor = Colors.grey;

                      if (_isPingingNodes) {
                        latencyText = '测速中...';
                        latencyColor = Colors.orange;
                      } else if (latency != null) {
                        if (latency > 0) {
                          latencyText = '$latency ms';
                          latencyColor = latency < 150 ? Colors.green : (latency < 400 ? Colors.amber.shade800 : Colors.red);
                        } else {
                          latencyText = '超时/受阻';
                          latencyColor = Colors.red;
                        }
                      }

                      return RadioListTile<String>(
                        value: node.id,
                        groupValue: currentMode,
                        dense: true,
                        contentPadding: const EdgeInsets.symmetric(horizontal: 8),
                        title: Row(
                          children: [
                            Expanded(
                              child: Text(
                                '${node.icon} ${node.name}',
                                style: const TextStyle(fontSize: 12.5),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            const SizedBox(width: 6),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
                              decoration: BoxDecoration(
                                color: latencyColor.withValues(alpha: 0.12),
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: Text(
                                latencyText,
                                style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: latencyColor),
                              ),
                            ),
                          ],
                        ),
                        subtitle: Text(node.indexUrl, style: const TextStyle(fontSize: 10, color: Colors.grey), maxLines: 1, overflow: TextOverflow.ellipsis),
                        onChanged: (val) async {
                          if (val != null) {
                            await _pluginManager.setNodeMode(val);
                            setDialogState(() {});
                            if (mounted) setState(() {});
                          }
                        },
                      );
                    }),

                    const SizedBox(height: 12),
                    Row(
                      children: [
                        OutlinedButton.icon(
                          onPressed: _isPingingNodes
                              ? null
                              : () async {
                                  setDialogState(() => _isPingingNodes = true);
                                  final pings = await _pluginManager.pingAllNodes();
                                  setDialogState(() {
                                    _nodePingResults = pings;
                                    _isPingingNodes = false;
                                  });
                                  if (mounted) setState(() {});
                                },
                          icon: _isPingingNodes
                              ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                              : const Icon(Icons.speed, size: 16),
                          label: const Text('全节点测速'),
                        ),
                        const SizedBox(width: 8),
                        TextButton.icon(
                          onPressed: _showCustomServerDialog,
                          icon: const Icon(Icons.add_link, size: 16),
                          label: const Text('配置私有源'),
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
                child: const Text('关闭'),
              ),
              FilledButton(
                onPressed: () {
                  Navigator.pop(ctx);
                  _refreshStore();
                },
                child: const Text('应用并刷新市场'),
              ),
            ],
          );
        },
      ),
    );
  }

  void _showCustomServerDialog() {
    final controller = TextEditingController(text: _pluginManager.serverRegistryUrl);

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.dns, color: Colors.blueAccent),
            SizedBox(width: 8),
            Text('配置第三方私有插件源', style: TextStyle(fontSize: 16)),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '输入完整的远程索引 (index.json) HTTP/HTTPS 地址：',
              style: TextStyle(fontSize: 12, color: Colors.black54),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: controller,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                isDense: true,
                hintText: 'https://example.com/registry/index.json',
              ),
              style: const TextStyle(fontSize: 13),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          FilledButton(
            onPressed: () async {
              final newUrl = controller.text.trim();
              if (newUrl.isNotEmpty) {
                await _pluginManager.updateServerUrl(newUrl);
                await _pluginManager.setNodeMode('custom');
                if (ctx.mounted) Navigator.pop(ctx);
                if (mounted) _refreshStore();
              }
            },
            child: const Text('保存并启用'),
          ),
        ],
      ),
    );
  }

  /// 弹出预览功能模块简介与详细参数对话框
  void _showPluginDetailDialog(PluginManifest item) {
    final isCompatible = PluginManagerService.isAppVersionCompatible(item.minAppVersion);
    final isSupportedLocally = item.isSupportedOnCurrentPlatform();
    final theme = Theme.of(context);

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        titlePadding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
        contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
        actionsPadding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
        title: Row(
          children: [
            CircleAvatar(
              radius: 20,
              backgroundColor: theme.colorScheme.primaryContainer,
              child: PluginIconWidget(manifest: item, size: 22, color: theme.colorScheme.primary),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(item.name, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                      ),
                      if (item.isOfficial)
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                          decoration: BoxDecoration(
                            color: Colors.blue.withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: const Text('官方认证', style: TextStyle(fontSize: 10, color: Colors.blueAccent, fontWeight: FontWeight.bold)),
                        )
                      else
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                          decoration: BoxDecoration(
                            color: Colors.teal.withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: const Text('社区贡献', style: TextStyle(fontSize: 10, color: Colors.teal, fontWeight: FontWeight.bold)),
                        ),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text('ID: ${item.id} · v${item.version} · 作者: ${item.author}',
                      style: const TextStyle(fontSize: 11, color: Colors.grey)),
                ],
              ),
            ),
          ],
        ),
        content: SizedBox(
          width: 520,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                // 兼容性状态标签条
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: isCompatible
                        ? Colors.green.withValues(alpha: 0.08)
                        : Colors.redAccent.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: isCompatible
                          ? Colors.green.withValues(alpha: 0.3)
                          : Colors.redAccent.withValues(alpha: 0.3),
                    ),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        isCompatible ? Icons.verified_user_rounded : Icons.warning_rounded,
                        size: 20,
                        color: isCompatible ? Colors.green : Colors.redAccent,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          isCompatible
                              ? '客户端兼容：要求最低客户端 v${item.minAppVersion} (当前 v${PluginManagerService.currentAppVersion} 满足)'
                              : '客户端不兼容：要求最低客户端 v${item.minAppVersion} (当前版本 v${PluginManagerService.currentAppVersion} 过低，拒绝安装)',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: isCompatible ? Colors.green.shade800 : Colors.redAccent.shade700,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),

                // 平台与分类属性
                Wrap(
                  spacing: 8,
                  runSpacing: 6,
                  children: [
                    Chip(
                      avatar: const Icon(Icons.category, size: 14),
                      label: Text('分类: ${item.category}'),
                      visualDensity: VisualDensity.compact,
                      padding: EdgeInsets.zero,
                    ),
                    Chip(
                      avatar: const Icon(Icons.devices, size: 14),
                      label: Text(item.platformBadgeText),
                      backgroundColor: _getPlatformBadgeColor(item).withValues(alpha: 0.1),
                      labelStyle: TextStyle(color: _getPlatformBadgeColor(item), fontWeight: FontWeight.bold),
                      visualDensity: VisualDensity.compact,
                      padding: EdgeInsets.zero,
                    ),
                    if (item.engineType.isNotEmpty)
                      Chip(
                        avatar: const Icon(Icons.memory, size: 14),
                        label: Text('引擎: ${item.engineType}'),
                        visualDensity: VisualDensity.compact,
                        padding: EdgeInsets.zero,
                      ),
                    if (item.isWindowsExtension)
                      Chip(
                        avatar: const Icon(Icons.bolt, size: 14, color: Colors.amber),
                        label: const Text('⚡ Win 开放工坊'),
                        backgroundColor: Colors.amber.withValues(alpha: 0.1),
                        labelStyle: const TextStyle(color: Colors.amber, fontWeight: FontWeight.bold),
                        visualDensity: VisualDensity.compact,
                        padding: EdgeInsets.zero,
                      ),
                  ],
                ),
                const SizedBox(height: 12),

                const Text('功能简介与技术特性：', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                const SizedBox(height: 4),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: Colors.grey.shade100,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: SelectableText(
                    item.description,
                    style: const TextStyle(fontSize: 13, height: 1.45, color: Colors.black87),
                  ),
                ),
                const SizedBox(height: 12),

                if (item.inputs.isNotEmpty) ...[
                  const Text('支持的输入项与参数说明：', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                  const SizedBox(height: 6),
                  ...item.inputs.map((inp) {
                    final optionsText = inp.options.isNotEmpty
                        ? ' [可选选项: ${inp.options.map((o) => o.label).join('、')}]'
                        : '';
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Icon(Icons.arrow_right, size: 18, color: Colors.blueAccent),
                          Expanded(
                            child: RichText(
                              text: TextSpan(
                                style: const TextStyle(fontSize: 12, color: Colors.black87),
                                children: [
                                  TextSpan(text: '${inp.label} (${inp.type}): ', style: const TextStyle(fontWeight: FontWeight.w600)),
                                  TextSpan(text: '字段 ${inp.id}$optionsText'),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                    );
                  }),
                ],
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('关闭'),
          ),
          if (item.isInstalled && !item.isUpdateAvailable)
            OutlinedButton.icon(
              onPressed: () {
                Navigator.pop(ctx);
                _uninstallPlugin(item);
              },
              icon: const Icon(Icons.delete_outline, size: 16),
              label: const Text('卸载该模块'),
              style: OutlinedButton.styleFrom(foregroundColor: Colors.redAccent),
            )
          else if (!isSupportedLocally)
            OutlinedButton(
              onPressed: null,
              child: const Text('当前操作系统不兼容'),
            )
          else if (!isCompatible)
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: Colors.grey),
              onPressed: () {
                Navigator.pop(ctx);
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text('插件【${item.name}】要求客户端最低版本为 v${item.minAppVersion}，请先升级客户端！'),
                    backgroundColor: Colors.redAccent,
                  ),
                );
              },
              child: const Text('版本不兼容，无法安装'),
            )
          else if (item.isUpdateAvailable)
            FilledButton.icon(
              onPressed: () {
                Navigator.pop(ctx);
                _installPlugin(item);
              },
              icon: const Icon(Icons.update, size: 16),
              label: const Text('立即更新'),
              style: FilledButton.styleFrom(backgroundColor: Colors.orange),
            )
          else
            FilledButton.icon(
              onPressed: () {
                Navigator.pop(ctx);
                _installPlugin(item);
              },
              icon: const Icon(Icons.download, size: 16),
              label: const Text('立即下载安装'),
            ),
        ],
      ),
    );
  }

  Future<void> _installPlugin(PluginManifest plugin) async {
    // 校验客户端版本
    if (!PluginManagerService.isAppVersionCompatible(plugin.minAppVersion)) {
      showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          icon: const Icon(Icons.block, color: Colors.redAccent, size: 48),
          title: const Text('无法安装'),
          content: Text(
            '插件【${plugin.name}】要求的最低客户端版本为 v${plugin.minAppVersion}，'
            '而当前客户端版本为 v${PluginManagerService.currentAppVersion}。\n\n'
            '请先更新百宝箱客户端至最新版本后再进行安装！',
          ),
          actions: [
            FilledButton(onPressed: () => Navigator.pop(ctx), child: const Text('确定')),
          ],
        ),
      );
      return;
    }

    setState(() {
      _downloadingPluginId = plugin.id;
      _downloadProgress = 0.0;
      _downloadStatus = '准备连接下载线路...';
    });

    final success = await _pluginManager.installPlugin(
      plugin,
      onProgress: (progress, status) {
        if (!mounted) return;
        setState(() {
          _downloadProgress = progress;
          _downloadStatus = status;
        });
      },
    );

    if (!mounted) return;
    setState(() {
      _downloadingPluginId = null;
    });

    if (success) {
      plugin.isInstalled = true;
      plugin.isUpdateAvailable = false;
      widget.onInstalledChanged();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('插件【${plugin.name}】已成功安装并启用！')),
      );
      await _refreshStore(silent: true);
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('插件【${plugin.name}】多节点下载均失败，请检查网络或切换节点')),
      );
    }
  }

  Future<void> _uninstallPlugin(PluginManifest plugin) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('卸载功能确认'),
        content: Text('确定要卸载【${plugin.name}】吗？卸载后可随时在插件中心重新下载。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.redAccent),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('确认卸载'),
          ),
        ],
      ),
    );

    if (confirm == true) {
      await _pluginManager.uninstallPlugin(plugin.id);
      plugin.isInstalled = false;
      plugin.isUpdateAvailable = false;
      widget.onInstalledChanged();
      await _refreshStore(silent: true);
    }
  }


  void _openCommunityRepo(String url) async {
    try {
      await OpenFilex.open(url);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isMobile = MediaQuery.of(context).size.width < 600;
    final activeNode = _pluginManager.currentActiveNode;

    final filteredPlugins = _pluginManager.remotePlugins.where((p) {
      // 严格只预置和展示适配当前操作系统平台的功能模块
      if (!p.isSupportedOnCurrentPlatform()) return false;
      if (_selectedScope == 'official' && !p.isOfficial) return false;
      if (_selectedScope == 'community' && p.isOfficial) return false;
      if (_selectedScope == 'win_ext' && !p.isWindowsExtension) return false;
      if (_searchQuery.trim().isNotEmpty) {
        final q = _searchQuery.trim().toLowerCase();
        final nameMatch = p.name.toLowerCase().contains(q);
        final descMatch = p.description.toLowerCase().contains(q);
        final catMatch = p.category.toLowerCase().contains(q);
        final authorMatch = p.author.toLowerCase().contains(q);
        final idMatch = p.id.toLowerCase().contains(q);
        return nameMatch || descMatch || catMatch || authorMatch || idMatch;
      }
      return true;
    }).toList();

    return Scaffold(
      appBar: AppBar(
        title: Text(
          isMobile ? '插件模块市场' : '功能插件市场 (云端社区中心)',
          style: TextStyle(fontWeight: FontWeight.bold, fontSize: isMobile ? 16 : 18),
        ),
        actions: [
          if (!isMobile) ...[
            OutlinedButton.icon(
              onPressed: _openInstalledManager,
              icon: const Icon(Icons.tune_rounded, size: 16),
              label: const Text('已安装管理'),
            ),
            const SizedBox(width: 6),
            FilledButton.tonalIcon(
              onPressed: _pickAndInstallLocalPlugin,
              icon: const Icon(Icons.file_upload_outlined, size: 18),
              label: const Text('本地安装'),
            ),
            const SizedBox(width: 6),
            OutlinedButton.icon(
              onPressed: _checkAppUpdate,
              icon: const Icon(Icons.system_update_alt_rounded, size: 16),
              label: const Text('检查更新'),
            ),
            IconButton(
              icon: const Icon(Icons.speed),
              tooltip: '镜像节点测速与换源',
              onPressed: _showNodeSelectionDialog,
            ),
            IconButton(
              icon: const Icon(Icons.refresh),
              tooltip: '刷新插件市场',
              onPressed: _refreshStore,
            ),
            PopupMenuButton<String>(
              icon: const Icon(Icons.more_vert),
              tooltip: '更多与社区',
              onSelected: (val) {
                if (val == 'gitee') {
                  _openCommunityRepo('https://gitee.com/sujiuovo/toolbox-community-registry');
                } else if (val == 'github') {
                  _openCommunityRepo('https://github.com/SuJiuOvO/Toolbox-Community-Registry');
                } else if (val == 'update') {
                  _checkAppUpdate();
                } else if (val == 'nodes') {
                  _showNodeSelectionDialog();
                }
              },
              itemBuilder: (ctx) => [
                const PopupMenuItem(
                  value: 'gitee',
                  child: Row(children: [Text('🇨🇳 Gitee 社区仓库'), Spacer(), Icon(Icons.open_in_new, size: 16)]),
                ),
                const PopupMenuItem(
                  value: 'github',
                  child: Row(children: [Text('🐙 GitHub 社区仓库'), Spacer(), Icon(Icons.open_in_new, size: 16)]),
                ),
                const PopupMenuDivider(),
                const PopupMenuItem(
                  value: 'update',
                  child: Row(children: [Text('🚀 检查客户端版本更新')]),
                ),
                const PopupMenuItem(
                  value: 'nodes',
                  child: Row(children: [Text('🌐 多节点线路测速与换源')]),
                ),
              ],
            ),
          ] else ...[
            IconButton(
              icon: const Icon(Icons.tune_rounded),
              tooltip: '管理已安装插件',
              onPressed: _openInstalledManager,
            ),
            IconButton(
              icon: const Icon(Icons.speed),
              tooltip: '镜像节点测速与换源',
              onPressed: _showNodeSelectionDialog,
            ),
            PopupMenuButton<String>(
              icon: const Icon(Icons.more_vert),
              tooltip: '更多与社区',
              onSelected: (val) {
                if (val == 'installed') {
                  _openInstalledManager();
                } else if (val == 'install') {
                  _pickAndInstallLocalPlugin();
                } else if (val == 'update') {
                  _checkAppUpdate();
                } else if (val == 'refresh') {
                  _refreshStore();
                } else if (val == 'gitee') {
                  _openCommunityRepo('https://gitee.com/sujiuovo/toolbox-community-registry');
                } else if (val == 'github') {
                  _openCommunityRepo('https://github.com/SuJiuOvO/Toolbox-Community-Registry');
                }
              },
              itemBuilder: (ctx) => [
                const PopupMenuItem(
                  value: 'installed',
                  child: Row(children: [
                    Icon(Icons.tune_rounded, size: 18, color: Colors.blueAccent),
                    SizedBox(width: 8),
                    Text('管理已安装模块与卸载'),
                  ]),
                ),
                const PopupMenuItem(
                  value: 'install',
                  child: Row(children: [
                    Icon(Icons.file_upload_outlined, size: 18, color: Colors.blueAccent),
                    SizedBox(width: 8),
                    Text('本地安装模块 (.json / .zip)'),
                  ]),
                ),
                const PopupMenuItem(
                  value: 'update',
                  child: Row(children: [
                    Icon(Icons.system_update_alt_rounded, size: 18, color: Colors.orange),
                    SizedBox(width: 8),
                    Text('检查客户端新版本'),
                  ]),
                ),
                const PopupMenuItem(
                  value: 'refresh',
                  child: Row(children: [
                    Icon(Icons.refresh, size: 18),
                    SizedBox(width: 8),
                    Text('刷新插件市场'),
                  ]),
                ),
                const PopupMenuDivider(),
                const PopupMenuItem(
                  value: 'gitee',
                  child: Row(children: [
                    Text('🇨🇳 Gitee 社区仓库'),
                    Spacer(),
                    Icon(Icons.open_in_new, size: 16),
                  ]),
                ),
                const PopupMenuItem(
                  value: 'github',
                  child: Row(children: [
                    Text('🐙 GitHub 社区仓库'),
                    Spacer(),
                    Icon(Icons.open_in_new, size: 16),
                  ]),
                ),
              ],
            ),
          ],
          const SizedBox(width: 4),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : CustomScrollView(
              physics: const AlwaysScrollableScrollPhysics(parent: BouncingScrollPhysics()),
              slivers: [
                // 顶部多源网络节点连接状态条
                SliverToBoxAdapter(
                  child: Container(
                    margin: EdgeInsets.fromLTRB(isMobile ? 12 : 16, 6, isMobile ? 12 : 16, 2),
                    padding: EdgeInsets.symmetric(horizontal: isMobile ? 10 : 12, vertical: 7),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.primary.withValues(alpha: 0.06),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: theme.colorScheme.primary.withValues(alpha: 0.15)),
                    ),
                    child: Row(
                      children: [
                        Text(activeNode.icon, style: const TextStyle(fontSize: 16)),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Row(
                            children: [
                              Flexible(
                                child: Text(
                                  activeNode.name,
                                  style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              if (_pluginManager.activeNodeLatency != null) ...[
                                const SizedBox(width: 6),
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                                  decoration: BoxDecoration(
                                    color: Colors.green.withValues(alpha: 0.15),
                                    borderRadius: BorderRadius.circular(4),
                                  ),
                                  child: Text(
                                    '${_pluginManager.activeNodeLatency}ms',
                                    style: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Colors.green),
                                  ),
                                ),
                              ],
                              const SizedBox(width: 4),
                              Text(
                                _pluginManager.selectedNodeMode == 'auto' ? '(竞速)' : '(锁定)',
                                style: const TextStyle(fontSize: 10.5, color: Colors.grey),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 6),
                        InkWell(
                          onTap: _showNodeSelectionDialog,
                          borderRadius: BorderRadius.circular(4),
                          child: const Padding(
                            padding: EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(Icons.swap_horiz, size: 16, color: Colors.blueAccent),
                                SizedBox(width: 2),
                                Text('换源测速', style: TextStyle(fontSize: 12, color: Colors.blueAccent, fontWeight: FontWeight.w600)),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),

                // 市场搜索栏
                SliverToBoxAdapter(
                  child: Padding(
                    padding: EdgeInsets.fromLTRB(isMobile ? 12 : 16, 6, isMobile ? 12 : 16, 4),
                    child: SizedBox(
                      height: 38,
                      child: TextField(
                        controller: _searchController,
                        style: const TextStyle(fontSize: 13),
                        onChanged: (val) {
                          setState(() {
                            _searchQuery = val;
                          });
                        },
                        decoration: InputDecoration(
                          hintText: isMobile ? '搜索插件 (名称、简介、作者)...' : '搜索云端社区插件 (名称、简介、作者或分类)...',
                          hintStyle: const TextStyle(fontSize: 12.5, color: Colors.grey),
                          prefixIcon: const Icon(Icons.search, size: 18),
                          prefixIconConstraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                          suffixIcon: _searchQuery.isNotEmpty
                              ? IconButton(
                                  icon: const Icon(Icons.clear, size: 16),
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
                          fillColor: Colors.grey.shade100,
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(20),
                            borderSide: BorderSide(color: Colors.grey.shade300),
                          ),
                          enabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(20),
                            borderSide: BorderSide(color: Colors.grey.shade300),
                          ),
                          focusedBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(20),
                            borderSide: BorderSide(color: theme.colorScheme.primary),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),

                // 社区范围筛选与平台筛选
                SliverToBoxAdapter(
                  child: Container(
                    padding: EdgeInsets.symmetric(horizontal: isMobile ? 12 : 16, vertical: 2),
                    alignment: Alignment.centerLeft,
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      physics: const BouncingScrollPhysics(),
                      child: Row(
                        children: [
                          FilterChip(
                            label: const Text('全部'),
                            visualDensity: VisualDensity.compact,
                            labelStyle: const TextStyle(fontSize: 11.5),
                            padding: const EdgeInsets.symmetric(horizontal: 4),
                            selected: _selectedScope == 'all',
                            onSelected: (_) => setState(() => _selectedScope = 'all'),
                          ),
                          const SizedBox(width: 6),
                          FilterChip(
                            avatar: const Icon(Icons.verified, size: 13, color: Colors.blueAccent),
                            label: const Text('官方认证'),
                            visualDensity: VisualDensity.compact,
                            labelStyle: const TextStyle(fontSize: 11.5),
                            padding: const EdgeInsets.symmetric(horizontal: 4),
                            selected: _selectedScope == 'official',
                            onSelected: (_) => setState(() => _selectedScope = 'official'),
                          ),
                          const SizedBox(width: 6),
                          FilterChip(
                            avatar: const Icon(Icons.people, size: 13, color: Colors.teal),
                            label: const Text('社区精选'),
                            visualDensity: VisualDensity.compact,
                            labelStyle: const TextStyle(fontSize: 11.5),
                            padding: const EdgeInsets.symmetric(horizontal: 4),
                            selected: _selectedScope == 'community',
                            onSelected: (_) => setState(() => _selectedScope = 'community'),
                          ),
                          if (Platform.isWindows) ...[
                            const SizedBox(width: 6),
                            FilterChip(
                              avatar: const Icon(Icons.bolt, size: 14, color: Colors.amber),
                              label: const Text('⚡ Win 开放工坊'),
                              visualDensity: VisualDensity.compact,
                              labelStyle: const TextStyle(fontSize: 11.5),
                              padding: const EdgeInsets.symmetric(horizontal: 4),
                              selected: _selectedScope == 'win_ext',
                              onSelected: (_) => setState(() => _selectedScope = 'win_ext'),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                ),
                const SliverToBoxAdapter(child: SizedBox(height: 4)),

                // 插件列表
                if (filteredPlugins.isEmpty)
                  SliverFillRemaining(
                    hasScrollBody: false,
                    child: Center(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.inbox_outlined, size: 54, color: Colors.grey),
                            const SizedBox(height: 12),
                            const Text('未找到匹配搜索或筛选条件的插件', style: TextStyle(color: Colors.grey, fontSize: 14)),
                            const SizedBox(height: 12),
                            OutlinedButton.icon(
                              onPressed: _showNodeSelectionDialog,
                              icon: const Icon(Icons.swap_horiz, size: 16),
                              label: const Text('切换其他可用镜像节点'),
                            ),
                          ],
                        ),
                      ),
                    ),
                  )
                else
                  SliverPadding(
                    padding: EdgeInsets.fromLTRB(
                      isMobile ? 12 : 16,
                      4,
                      isMobile ? 12 : 16,
                      isMobile ? 24 : 16,
                    ),
                    sliver: SliverList(
                      delegate: SliverChildBuilderDelegate(
                        (ctx, index) {
                          final item = filteredPlugins[index];
                          final isDownloading = _downloadingPluginId == item.id;
                          final isAnyBusy = _downloadingPluginId != null;
                          final isSupportedLocally = item.isSupportedOnCurrentPlatform();
                          final isCompatible = PluginManagerService.isAppVersionCompatible(item.minAppVersion);

                          return Card(
                            margin: const EdgeInsets.only(bottom: 12),
                            elevation: 1,
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                            child: Padding(
                              padding: EdgeInsets.all(isMobile ? 12 : 15),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      CircleAvatar(
                                        radius: isMobile ? 18 : 20,
                                        backgroundColor: theme.colorScheme.primaryContainer,
                                        child: PluginIconWidget(
                                          manifest: item,
                                          size: isMobile ? 20 : 22,
                                          color: theme.colorScheme.primary,
                                        ),
                                      ),
                                      const SizedBox(width: 10),
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment: CrossAxisAlignment.start,
                                          children: [
                                            Row(
                                              children: [
                                                Expanded(
                                                  child: Text(
                                                    item.name,
                                                    style: TextStyle(
                                                      fontWeight: FontWeight.w600,
                                                      fontSize: isMobile ? 14 : 15,
                                                    ),
                                                  ),
                                                ),
                                                if (item.isOfficial)
                                                  Container(
                                                    padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                                                    decoration: BoxDecoration(
                                                      color: Colors.blue.withValues(alpha: 0.1),
                                                      borderRadius: BorderRadius.circular(4),
                                                    ),
                                                    child: const Text('官方认证', style: TextStyle(fontSize: 10, color: Colors.blueAccent, fontWeight: FontWeight.bold)),
                                                  ),
                                                const SizedBox(width: 6),
                                                Container(
                                                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
                                                  decoration: BoxDecoration(
                                                    color: _getPlatformBadgeColor(item).withValues(alpha: 0.12),
                                                    borderRadius: BorderRadius.circular(4),
                                                  ),
                                                  child: Text(
                                                    item.platformBadgeText,
                                                    style: TextStyle(
                                                      fontSize: 10,
                                                      fontWeight: FontWeight.w500,
                                                      color: _getPlatformBadgeColor(item),
                                                    ),
                                                  ),
                                                ),
                                                if (item.isWindowsExtension) ...[
                                                  const SizedBox(width: 4),
                                                  Container(
                                                    padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
                                                    decoration: BoxDecoration(
                                                      color: Colors.amber.withValues(alpha: 0.15),
                                                      borderRadius: BorderRadius.circular(4),
                                                      border: Border.all(color: Colors.amber.withValues(alpha: 0.3)),
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
                                            const SizedBox(height: 2),
                                            Row(
                                              children: [
                                                Expanded(
                                                  child: Text(
                                                    'v${item.version} · ${item.author} · ${(item.size != null ? (item.size! / 1024).toStringAsFixed(1) : "0")} KB',
                                                    style: const TextStyle(fontSize: 11, color: Colors.grey),
                                                    overflow: TextOverflow.ellipsis,
                                                  ),
                                                ),
                                                const SizedBox(width: 6),
                                                Container(
                                                  padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                                                  decoration: BoxDecoration(
                                                    color: isCompatible
                                                        ? Colors.green.withValues(alpha: 0.1)
                                                        : Colors.red.withValues(alpha: 0.1),
                                                    borderRadius: BorderRadius.circular(3),
                                                  ),
                                                  child: Text(
                                                    '最低: v${item.minAppVersion}',
                                                    style: TextStyle(
                                                      fontSize: 9,
                                                      color: isCompatible ? Colors.green.shade800 : Colors.redAccent,
                                                      fontWeight: FontWeight.bold,
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
                                  const SizedBox(height: 8),
                                  Text(
                                    item.description,
                                    style: TextStyle(
                                      fontSize: isMobile ? 12 : 13,
                                      color: Colors.black87,
                                      height: 1.35,
                                    ),
                                    maxLines: isMobile ? 2 : 3,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  const SizedBox(height: 8),

                                  // 按钮组：预览简介 + 下载/更新/卸载操作
                                  Row(
                                    mainAxisAlignment: MainAxisAlignment.end,
                                    children: [
                                      OutlinedButton.icon(
                                        onPressed: () => _showPluginDetailDialog(item),
                                        icon: const Icon(Icons.info_outline, size: 14),
                                        label: const Text('预览简介', style: TextStyle(fontSize: 12)),
                                        style: OutlinedButton.styleFrom(
                                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                                          visualDensity: VisualDensity.compact,
                                        ),
                                      ),
                                      const SizedBox(width: 8),
                                      if (item.isInstalled && !item.isUpdateAvailable)
                                        OutlinedButton(
                                          onPressed: isAnyBusy ? null : () => _uninstallPlugin(item),
                                          style: OutlinedButton.styleFrom(
                                            foregroundColor: Colors.redAccent,
                                            side: const BorderSide(color: Colors.redAccent),
                                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                                            visualDensity: VisualDensity.compact,
                                          ),
                                          child: const Text('已安装 (卸载)', style: TextStyle(fontSize: 12)),
                                        )
                                      else if (!isSupportedLocally)
                                        Container(
                                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                                          decoration: BoxDecoration(
                                            color: Colors.grey.shade200,
                                            borderRadius: BorderRadius.circular(6),
                                          ),
                                          child: const Text('平台不兼容',
                                              style: TextStyle(fontSize: 11, color: Colors.grey)),
                                        )
                                      else if (!isCompatible)
                                        FilledButton(
                                          onPressed: () {
                                            ScaffoldMessenger.of(context).showSnackBar(
                                              SnackBar(
                                                content: Text('插件【${item.name}】要求的最低客户端版本为 v${item.minAppVersion}，当前客户端版本为 v${PluginManagerService.currentAppVersion}，请先升级百宝箱客户端！'),
                                                backgroundColor: Colors.redAccent,
                                              ),
                                            );
                                          },
                                          style: FilledButton.styleFrom(
                                            backgroundColor: Colors.grey,
                                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                                            visualDensity: VisualDensity.compact,
                                          ),
                                          child: const Text('客户端版本过低', style: TextStyle(fontSize: 12)),
                                        )
                                      else if (item.isUpdateAvailable)
                                        FilledButton(
                                          onPressed: isAnyBusy ? null : () => _installPlugin(item),
                                          style: FilledButton.styleFrom(
                                            backgroundColor: Colors.orange,
                                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                                            visualDensity: VisualDensity.compact,
                                          ),
                                          child: Text(isDownloading ? '更新中...' : '更新',
                                              style: const TextStyle(fontSize: 12)),
                                        )
                                      else
                                        FilledButton.icon(
                                          onPressed: isAnyBusy ? null : () => _installPlugin(item),
                                          style: FilledButton.styleFrom(
                                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                                            visualDensity: VisualDensity.compact,
                                          ),
                                          icon: isDownloading
                                              ? const SizedBox(
                                                  width: 14,
                                                  height: 14,
                                                  child: CircularProgressIndicator(
                                                      strokeWidth: 2, color: Colors.white),
                                                )
                                              : const Icon(Icons.download, size: 15),
                                          label: Text(isDownloading ? '安装中...' : '下载安装',
                                              style: const TextStyle(fontSize: 12)),
                                        ),
                                    ],
                                  ),
                                  if (isDownloading) ...[
                                    const SizedBox(height: 8),
                                    LinearProgressIndicator(value: _downloadProgress > 0 ? _downloadProgress : null),
                                    const SizedBox(height: 4),
                                    Text(
                                      _downloadStatus,
                                      style: const TextStyle(fontSize: 11, color: Colors.blueAccent),
                                    ),
                                  ],
                                ],
                              ),
                            ),
                          );
                        },
                        childCount: filteredPlugins.length,
                      ),
                    ),
                  ),
              ],
            ),
    );
  }
}
