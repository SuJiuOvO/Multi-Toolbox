import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/windows_uninstaller_service.dart';

/// Interactive host view launched by the windows_uninstaller plugin handler.
class WindowsUninstallerPage extends StatefulWidget {
  const WindowsUninstallerPage({super.key, this.service});
  final WindowsUninstallerService? service;

  @override
  State<WindowsUninstallerPage> createState() => _WindowsUninstallerPageState();
}

class _WindowsUninstallerPageState extends State<WindowsUninstallerPage> {
  late final WindowsUninstallerService _service;
  final _search = TextEditingController();
  List<InstalledWindowsApp> _apps = [];
  List<String> _warnings = [];
  InstalledWindowsApp? _selected;
  InstalledWindowsApp? _lastUninstalled;
  bool _loading = true;
  bool _busy = false;
  bool _waitingForUninstall = false;
  int _operation = 0;
  bool _showSystem = false;
  String _scope = 'all';
  String _sort = 'name';
  String? _error;
  String? _status;

  @override
  void initState() {
    super.initState();
    _service = widget.service ?? WindowsUninstallerService();
    _reload();
  }

  @override
  void dispose() {
    _operation++;
    _search.dispose();
    super.dispose();
  }

  Future<void> _reload() async {
    if (!_service.isSupported) {
      setState(() => _loading = false);
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final inventory = await _service.loadApps();
      if (!mounted) return;
      setState(() {
        _apps = inventory.apps;
        _warnings = inventory.warnings;
        if (_selected != null) {
          final matches = _apps.where((app) => app.id == _selected!.id);
          _selected = matches.isEmpty ? null : matches.first;
        }
      });
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  List<InstalledWindowsApp> get _visibleApps {
    final query = _search.text.trim().toLowerCase();
    final filtered = _apps.where((app) {
      if (!_showSystem && app.systemComponent) return false;
      if (_scope != 'all' && app.registryHive != _scope) return false;
      return query.isEmpty ||
          '${app.name} ${app.publisher} ${app.version} ${app.installLocation}'
              .toLowerCase()
              .contains(query);
    }).toList();
    filtered.sort((a, b) => switch (_sort) {
          'size' => b.estimatedBytes.compareTo(a.estimatedBytes),
          'date' => b.installDate.compareTo(a.installDate),
          'publisher' =>
            a.publisher.toLowerCase().compareTo(b.publisher.toLowerCase()),
          _ => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
        });
    return filtered;
  }

  Future<void> _uninstall(InstalledWindowsApp app) async {
    UninstallCommand command;
    try {
      command = UninstallCommand.fromApp(app);
    } catch (error) {
      _notify(error.toString());
      return;
    }
    var elevate = false;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
          builder: (context, update) => AlertDialog(
                title: Text('卸载 ${app.name}？'),
                content: SizedBox(
                  width: 560,
                  child: SingleChildScrollView(
                      child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('将启动此软件注册的官方卸载程序。请在弹出的窗口中完成后续步骤。'),
                      const SizedBox(height: 14),
                      SelectableText(command.display,
                          style: const TextStyle(
                              fontFamily: 'monospace', fontSize: 12)),
                      const SizedBox(height: 12),
                      SwitchListTile.adaptive(
                        contentPadding: EdgeInsets.zero,
                        value: elevate,
                        onChanged: (value) => update(() => elevate = value),
                        title: const Text('以管理员身份运行'),
                        subtitle: const Text('Windows 可能显示 UAC 授权窗口'),
                      ),
                    ],
                  )),
                ),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(context, false),
                      child: const Text('取消')),
                  FilledButton.icon(
                    key: const ValueKey('confirm-windows-uninstall'),
                    onPressed: () => Navigator.pop(context, true),
                    icon: const Icon(Icons.delete_outline),
                    label: const Text('启动卸载'),
                  ),
                ],
              )),
    );
    if (confirmed != true || !mounted) return;
    final operation = ++_operation;
    setState(() {
      _busy = true;
      _waitingForUninstall = true;
      _status = '正在等待 ${app.name} 的卸载程序退出…';
    });
    try {
      final result = await _service.uninstall(app, elevate: elevate);
      if (!mounted || operation != _operation) return;
      setState(() {
        _waitingForUninstall = false;
        if (result.succeeded) _lastUninstalled = app;
        _status = result.message;
      });
      await _reload();
    } catch (error) {
      if (mounted && operation == _operation) {
        setState(() => _status = '未完成卸载：$error');
      }
    } finally {
      if (mounted && operation == _operation) {
        setState(() {
          _busy = false;
          _waitingForUninstall = false;
        });
      }
    }
  }

  void _stopWaiting() {
    _operation++;
    setState(() {
      _busy = false;
      _waitingForUninstall = false;
      _status = '已停止等待，外部卸载程序仍会继续。完成后请刷新软件列表。';
    });
  }

  Future<void> _scan(InstalledWindowsApp app) async {
    setState(() => _busy = true);
    try {
      final candidates = await _service.scanResidue(app);
      if (!mounted) return;
      await showDialog<void>(
          context: context,
          builder: (context) => AlertDialog(
                title: Text('${app.name} · 残留预览'),
                content: SizedBox(
                  width: 620,
                  child: SingleChildScrollView(
                      child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                          '只检查原卸载注册项和明确登记的安装目录。结果是待核对线索，不代表可以安全删除；此版本提供只读预览。'),
                      const SizedBox(height: 16),
                      if (candidates.isEmpty)
                        const Text(
                            '未发现上述位置残留。此结果不覆盖所有用户数据、共享文件或 Microsoft Store 应用。'),
                      for (final item in candidates) ...[
                        Text(item.kind,
                            style:
                                const TextStyle(fontWeight: FontWeight.bold)),
                        const SizedBox(height: 4),
                        SelectableText(item.path),
                        const SizedBox(height: 4),
                        Text(item.note,
                            style: Theme.of(context).textTheme.bodySmall),
                        TextButton.icon(
                          onPressed: () async {
                            await Clipboard.setData(
                                ClipboardData(text: item.path));
                            if (mounted) _notify('路径已复制');
                          },
                          icon: const Icon(Icons.copy_outlined, size: 16),
                          label: const Text('复制路径'),
                        ),
                        const Divider(),
                      ],
                    ],
                  )),
                ),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('关闭'))
                ],
              ));
    } catch (error) {
      if (mounted) _notify('扫描失败：$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _notify(String message) => ScaffoldMessenger.of(context)
      .showSnackBar(SnackBar(content: Text(message)));

  @override
  Widget build(BuildContext context) {
    if (!_service.isSupported) {
      return Scaffold(
        appBar: AppBar(title: const Text('Windows 软件卸载助手')),
        body: const Center(
            child: Padding(
          padding: EdgeInsets.all(24),
          child: Text('此插件仅在 Windows 上管理已安装的桌面软件。'),
        )),
      );
    }
    final apps = _visibleApps;
    final scanTarget = _lastUninstalled ?? _selected;
    return PopScope(
      canPop: !_busy || _waitingForUninstall,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop && _busy) _notify('请先完成当前操作，再返回。');
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Windows 软件卸载助手'),
          actions: [
            IconButton(
              tooltip: '刷新软件列表',
              onPressed: _busy || _loading ? null : _reload,
              icon: const Icon(Icons.refresh_rounded),
            ),
          ],
        ),
        body: Padding(
          padding: const EdgeInsets.all(20),
          child: LayoutBuilder(builder: (context, viewport) {
            final compact = viewport.maxHeight < 620 || viewport.maxWidth < 650;
            final inventory = LayoutBuilder(builder: (context, size) {
              final list = _list(context, apps);
              if (size.maxWidth < 950) return list;
              return Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(flex: 3, child: list),
                    const SizedBox(width: 16),
                    Expanded(flex: 2, child: _details(context, _selected)),
                  ]);
            });
            final content = Column(
                mainAxisSize: compact ? MainAxisSize.min : MainAxisSize.max,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _header(context, apps),
                  const SizedBox(height: 14),
                  LayoutBuilder(
                      builder: (context, size) => Wrap(
                            spacing: 12,
                            runSpacing: 12,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [
                              SizedBox(
                                width:
                                    size.maxWidth < 600 ? size.maxWidth : 340,
                                child: TextField(
                                  controller: _search,
                                  onChanged: (_) => setState(() {}),
                                  decoration: InputDecoration(
                                    labelText: '搜索名称、发布者或路径',
                                    prefixIcon: const Icon(Icons.search),
                                    suffixIcon: _search.text.isEmpty
                                        ? null
                                        : IconButton(
                                            tooltip: '清空搜索',
                                            onPressed: () =>
                                                setState(_search.clear),
                                            icon: const Icon(Icons.close),
                                          ),
                                    border: const OutlineInputBorder(),
                                  ),
                                ),
                              ),
                              DropdownButton<String>(
                                value: _scope,
                                items: const [
                                  DropdownMenuItem(
                                      value: 'all', child: Text('全部用户范围')),
                                  DropdownMenuItem(
                                      value: 'CurrentUser',
                                      child: Text('当前用户')),
                                  DropdownMenuItem(
                                      value: 'LocalMachine',
                                      child: Text('所有用户')),
                                ],
                                onChanged: (value) =>
                                    setState(() => _scope = value!),
                              ),
                              DropdownButton<String>(
                                value: _sort,
                                items: const [
                                  DropdownMenuItem(
                                      value: 'name', child: Text('按名称')),
                                  DropdownMenuItem(
                                      value: 'size', child: Text('按大小降序')),
                                  DropdownMenuItem(
                                      value: 'date', child: Text('按安装日期')),
                                  DropdownMenuItem(
                                      value: 'publisher', child: Text('按发布者')),
                                ],
                                onChanged: (value) =>
                                    setState(() => _sort = value!),
                              ),
                              FilterChip(
                                selected: _showSystem,
                                onSelected: (value) =>
                                    setState(() => _showSystem = value),
                                label: const Text('显示系统组件'),
                              ),
                            ],
                          )),
                  const SizedBox(height: 12),
                  if (_loading || _busy) const LinearProgressIndicator(),
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      child: Text('读取失败：$_error',
                          style: TextStyle(
                              color: Theme.of(context).colorScheme.error)),
                    ),
                  if (_status != null)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 10),
                      child: Text(_status!),
                    ),
                  if (_waitingForUninstall)
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton.icon(
                        key: const ValueKey('stop-waiting-uninstall'),
                        onPressed: _stopWaiting,
                        icon: const Icon(Icons.hourglass_disabled_outlined),
                        label: const Text('停止等待（卸载程序继续运行）'),
                      ),
                    ),
                  if (_warnings.isNotEmpty)
                    Text('部分注册表项无法读取：${_warnings.length} 项',
                        style: Theme.of(context).textTheme.bodySmall),
                  if (compact)
                    SizedBox(
                        height: (viewport.maxHeight * .55).clamp(220, 420),
                        child: inventory)
                  else
                    Expanded(child: inventory),
                  const SizedBox(height: 12),
                  Wrap(spacing: 12, runSpacing: 8, children: [
                    FilledButton.icon(
                      key: const ValueKey('uninstall-selected-app'),
                      onPressed:
                          _busy || _loading || _selected?.canUninstall != true
                              ? null
                              : () => _uninstall(_selected!),
                      icon: const Icon(Icons.delete_outline),
                      label: const Text('卸载所选软件'),
                    ),
                    OutlinedButton.icon(
                      onPressed: _busy || scanTarget == null
                          ? null
                          : () => _scan(scanTarget),
                      icon: const Icon(Icons.manage_search_outlined),
                      label: Text(_lastUninstalled != null
                          ? '预览上次卸载的软件残留'
                          : '预览所选软件残留'),
                    ),
                  ]),
                ]);
            return compact ? SingleChildScrollView(child: content) : content;
          }),
        ),
      ),
    );
  }

  Widget _header(BuildContext context, List<InstalledWindowsApp> apps) {
    final scheme = Theme.of(context).colorScheme;
    final total = apps.fold<int>(0, (sum, app) => sum + app.estimatedBytes);
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        color: scheme.primaryContainer.withValues(alpha: .45),
      ),
      child: Row(children: [
        Icon(Icons.cleaning_services_outlined, size: 34, color: scheme.primary),
        const SizedBox(width: 16),
        Expanded(
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(
              '${apps.length} 个桌面软件 · 估算 ${(total / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB',
              style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 4),
          const Text('32 / 64 位注册表 · 官方卸载器 · 残留只读预览',
              style: TextStyle(fontSize: 12)),
          const Text('体积来自软件登记值；Microsoft Store 应用不在此列表中。',
              style: TextStyle(fontSize: 12)),
        ])),
      ]),
    );
  }

  Widget _list(BuildContext context, List<InstalledWindowsApp> apps) {
    if (!_loading && apps.isEmpty) {
      return const Center(child: Text('没有找到符合条件的软件'));
    }
    return Card(
      clipBehavior: Clip.antiAlias,
      child: ListView.separated(
        itemCount: apps.length,
        separatorBuilder: (_, __) => const Divider(height: 1),
        itemBuilder: (context, index) {
          final app = apps[index];
          return ListTile(
            key: ValueKey(app.id),
            selected: _selected?.id == app.id,
            leading: Icon(app.systemComponent
                ? Icons.shield_outlined
                : Icons.apps_rounded),
            title: Text(app.name, maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: Text(
                '${app.publisher.isEmpty ? '未知发布者' : app.publisher} · ${app.version}\n${app.scopeLabel} · ${app.architecture}',
                maxLines: 2,
                overflow: TextOverflow.ellipsis),
            isThreeLine: true,
            trailing: Text(app.formattedSize),
            onTap: _busy ? null : () => setState(() => _selected = app),
            onLongPress: () => showDialog<void>(
                context: context,
                builder: (context) => AlertDialog(
                        content:
                            SizedBox(width: 560, child: _details(context, app)),
                        actions: [
                          TextButton(
                              onPressed: () => Navigator.pop(context),
                              child: const Text('关闭'))
                        ])),
          );
        },
      ),
    );
  }

  Widget _details(BuildContext context, InstalledWindowsApp? app) => Card(
        child: app == null
            ? const Center(
                child: Text('选择软件查看登记信息\n窄窗口可长按软件查看详情',
                    textAlign: TextAlign.center))
            : SingleChildScrollView(
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(app.name,
                        style: Theme.of(context).textTheme.titleLarge),
                    const SizedBox(height: 16),
                    for (final entry in <String, String>{
                      '版本': app.version,
                      '发布者': app.publisher,
                      '安装日期': app.installDate,
                      '登记体积': app.formattedSize,
                      '用户范围 / 架构': '${app.scopeLabel} / ${app.architecture}',
                      '安装目录': app.installLocation,
                      '卸载命令': app.uninstallString,
                      '注册表位置': '${app.registryPath} (${app.architecture}视图)',
                    }.entries) ...[
                      Text(entry.key,
                          style: Theme.of(context).textTheme.labelMedium),
                      const SizedBox(height: 4),
                      SelectableText(entry.value.isEmpty ? '未提供' : entry.value),
                      const SizedBox(height: 14),
                    ],
                    if (!app.canUninstall) const Text('此条目为受保护组件或未登记可用卸载命令。'),
                  ],
                )),
      );
}
