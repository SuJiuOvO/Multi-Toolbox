import 'dart:async';
import 'dart:io';

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
  final Map<String, String> _iconCache = {};
  List<String> _warnings = [];
  InstalledWindowsApp? _selected;
  InstalledWindowsApp? _lastUninstalled;
  bool _loading = true;
  bool _busy = false;
  bool _waitingForUninstall = false;
  int _operation = 0;
  int _reloadGeneration = 0;
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
    final generation = ++_reloadGeneration;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final inventory = await _service.loadApps();
      if (!mounted) return;
      setState(() {
        _apps = [
          for (final app in inventory.apps) _withCachedIcon(app),
        ];
        _warnings = inventory.warnings;
        if (_selected != null) {
          final matches = _apps.where((app) => app.id == _selected!.id);
          _selected = matches.isEmpty ? null : matches.first;
        }
      });
      unawaited(_loadIcons(inventory.apps, generation));
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _loadIcons(
      List<InstalledWindowsApp> apps, int generation) async {
    try {
      final icons = await _service.loadIconPaths(apps);
      if (!mounted || generation != _reloadGeneration || icons.isEmpty) return;
      for (final app in apps) {
        final path = icons[app.id];
        if (path != null && path.trim().isNotEmpty) {
          _iconCache[_iconCacheKey(app)] = path;
        }
      }
      setState(() {
        _apps = _apps.map(_withCachedIcon).toList();
      });
    } catch (_) {
      // Icon extraction is a progressive enhancement; the inventory remains
      // usable with its fallback glyphs if one shell operation fails.
    }
  }

  String _iconCacheKey(InstalledWindowsApp app) {
    final source = app.displayIcon.trim().toLowerCase();
    return '${app.id}\u0000$source';
  }

  InstalledWindowsApp _withCachedIcon(InstalledWindowsApp app) {
    final cachedPath = _iconCache[_iconCacheKey(app)];
    return cachedPath == null || cachedPath.isEmpty
        ? app
        : app.copyWith(iconPath: cachedPath);
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
    var scanAfterReload = false;
    try {
      final result = await _service.uninstall(app, elevate: elevate);
      if (!mounted || operation != _operation) return;
      setState(() {
        _waitingForUninstall = false;
        if (result.succeeded) {
          _lastUninstalled = app;
          scanAfterReload = true;
        }
        _status = result.message;
      });
      await _reload();
      if (scanAfterReload && mounted && operation == _operation) {
        await _scan(app);
      }
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
      final selected = <WindowsResidueCandidate>[];
      final removableCount = candidates.where((item) => item.canDelete).length;
      final chosen = await showDialog<List<WindowsResidueCandidate>>(
          context: context,
          builder: (dialogContext) => StatefulBuilder(
              builder: (context, updateDialog) => AlertDialog(
                    title: Text('${app.name} · 扫描并清理残留'),
                    content: SizedBox(
                      width: 680,
                      child: SingleChildScrollView(
                          child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                              '已按软件名称、发布者、安装目录和精确注册表路径扫描。默认不勾选任何项目；请核对路径后选择，删除不可撤销。'),
                          const SizedBox(height: 12),
                          Text(
                            '发现 ${candidates.length} 项，其中 $removableCount 项可清理，已选择 ${selected.length} 项',
                            style: const TextStyle(fontWeight: FontWeight.bold),
                          ),
                          if (candidates.any((item) => item.canDelete))
                            Align(
                              alignment: Alignment.centerLeft,
                              child: TextButton.icon(
                                key: const ValueKey('select-all-residue'),
                                onPressed: () => updateDialog(() {
                                  final removable = candidates
                                      .where((item) => item.canDelete)
                                      .toList();
                                  if (selected.length == removable.length) {
                                    selected.clear();
                                  } else {
                                    selected
                                      ..clear()
                                      ..addAll(removable);
                                  }
                                }),
                                icon: const Icon(Icons.checklist),
                                label:
                                    Text(selected.isEmpty ? '全选可清理项' : '取消全选'),
                              ),
                            ),
                          if (candidates.isEmpty)
                            const Padding(
                              padding: EdgeInsets.symmetric(vertical: 20),
                              child: Text(
                                  '未发现常见残留。此结果不覆盖所有用户数据、共享文件或 Microsoft Store 应用。'),
                            ),
                          for (final item in candidates)
                            _residueTile(
                              context,
                              item,
                              selected.contains(item),
                              (checked) => updateDialog(() {
                                if (checked == true) {
                                  if (!selected.contains(item)) {
                                    selected.add(item);
                                  }
                                } else {
                                  selected.remove(item);
                                }
                              }),
                            ),
                        ],
                      )),
                    ),
                    actions: [
                      TextButton(
                          onPressed: () => Navigator.pop(dialogContext),
                          child: const Text('关闭')),
                      if (candidates.any((item) => item.canDelete))
                        FilledButton.icon(
                          key: const ValueKey('delete-selected-residue'),
                          onPressed: selected.isEmpty
                              ? null
                              : () => Navigator.pop(
                                  dialogContext, List.of(selected)),
                          icon: const Icon(Icons.delete_sweep_outlined),
                          label: Text('清理 ${selected.length} 项'),
                        ),
                    ],
                  )));
      if (chosen == null || chosen.isEmpty || !mounted) return;
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('确认永久删除这些残留？'),
          content: SizedBox(
            width: 620,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                      '将永久删除以下目录、文件或注册表项，不进入回收站。正在运行的程序可能占用文件，失败项会单独列出。'),
                  const SizedBox(height: 12),
                  for (final item in chosen)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: Text('• ${item.path}'),
                    ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('取消')),
            FilledButton(
              key: const ValueKey('confirm-delete-residue'),
              onPressed: () => Navigator.pop(context, true),
              child: const Text('永久删除'),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;
      final result = await _service.deleteResidue(chosen);
      if (!mounted) return;
      final message = result.succeeded
          ? '已清理 ${result.deletedPaths.length} 项残留。'
          : '已清理 ${result.deletedPaths.length} 项，${result.errors.length} 项失败：\n${result.errors.join('\n')}';
      setState(() => _status = message);
      _notify(result.succeeded ? '残留清理完成' : '部分残留无法删除');
      await _reload();
    } catch (error) {
      if (mounted) _notify('扫描失败：$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _residueTile(
    BuildContext context,
    WindowsResidueCandidate item,
    bool selected,
    ValueChanged<bool?> onChanged,
  ) {
    return CheckboxListTile(
      value: selected,
      onChanged: item.canDelete ? onChanged : null,
      contentPadding: EdgeInsets.zero,
      controlAffinity: ListTileControlAffinity.leading,
      title:
          Text(item.kind, style: const TextStyle(fontWeight: FontWeight.w600)),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 4),
          SelectableText(item.path,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
          const SizedBox(height: 4),
          Text(item.note),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: item.path));
                if (mounted) _notify('路径已复制');
              },
              icon: const Icon(Icons.copy_outlined, size: 16),
              label: const Text('复制路径'),
            ),
          ),
        ],
      ),
      isThreeLine: true,
    );
  }

  void _notify(String message) => ScaffoldMessenger.of(context)
      .showSnackBar(SnackBar(content: Text(message)));

  @override
  Widget build(BuildContext context) {
    if (!_service.isSupported) {
      return Scaffold(
        appBar: AppBar(title: const Text('软件卸载')),
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
          title: const Text('软件卸载'),
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
                          ? '扫描并清理上次卸载残留'
                          : '扫描并清理所选软件残留'),
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
          const Text('32 / 64 位注册表 · 应用图标 · 官方卸载器 · 残留扫描清理',
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
            leading: _appIcon(app, 40),
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

  Widget _appIcon(InstalledWindowsApp app, double size) {
    final fallback = Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Icon(
        app.systemComponent ? Icons.shield_outlined : Icons.apps_rounded,
        size: size * .58,
      ),
    );
    final path = app.iconPath.trim();
    if (path.isEmpty || !File(path).existsSync()) return fallback;
    return ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: Image.file(
        File(path),
        width: size,
        height: size,
        fit: BoxFit.contain,
        cacheWidth: (size * MediaQuery.devicePixelRatioOf(context)).round(),
        errorBuilder: (_, __, ___) => fallback,
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
                    Row(
                      children: [
                        _appIcon(app, 52),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Text(app.name,
                              style: Theme.of(context).textTheme.titleLarge),
                        ),
                      ],
                    ),
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
