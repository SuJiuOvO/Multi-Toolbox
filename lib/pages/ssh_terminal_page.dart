import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:xterm/xterm.dart';

import '../models/ssh_profile.dart';
import '../services/ssh_connection_service.dart';

class SshTerminalPage extends StatefulWidget {
  const SshTerminalPage({super.key, this.service});
  final SshConnectionService? service;

  @override
  State<SshTerminalPage> createState() => _SshTerminalPageState();
}

class _SshTerminalPageState extends State<SshTerminalPage> {
  final _host = TextEditingController();
  final _port = TextEditingController(text: '22');
  final _user = TextEditingController(text: 'root');
  final _password = TextEditingController();
  final _privateKey = TextEditingController();
  final _passphrase = TextEditingController();
  final _name = TextEditingController();
  final _terminalFocus = FocusNode();
  final _terminal = Terminal(maxLines: 5000);
  final _terminalController = TerminalController();
  final _profilesStore = SshProfileStore();
  late final SshConnectionService _service;
  List<SshProfile> _profiles = [];
  SshAuthMethod _auth = SshAuthMethod.password;
  bool _connecting = false;
  bool _connected = false;
  bool _configExpanded = true;
  bool _ctrl = false;
  bool _showPassword = false;
  bool _rememberCredentials = true;
  Timer? _resizeDebounce;
  double _fontSize = 14;
  String _status = '尚未连接';
  String? _error;
  int _attempt = 0;

  @override
  void initState() {
    super.initState();
    _service = widget.service ?? SshConnectionService();
    _terminal.write('\x1b[1;36mMULTI-TOOLBOX / SSH\x1b[0m\r\n'
        '输入服务器信息后连接。支持密码与 PEM / OpenSSH 私钥。\r\n'
        '首次连接请向服务器管理员核对 SHA256 主机指纹。\r\n');
    _terminal.onOutput = (text) {
      if (!_connected) return;
      if (_ctrl &&
          text.isNotEmpty &&
          text.codeUnitAt(0) >= 64 &&
          text.codeUnitAt(0) <= 127) {
        _service.send(
            String.fromCharCode(text.codeUnitAt(0) & 31) + text.substring(1));
        setState(() => _ctrl = false);
      } else {
        _service.send(text);
      }
    };
    _terminal.onResize = (width, height, pixelWidth, pixelHeight) {
      if (!_connected) return;
      _resizeDebounce?.cancel();
      _resizeDebounce = Timer(const Duration(milliseconds: 300), () {
        if (!_connected) return;
        // 软键盘弹起高度急剧缩小保护：限制最低行数为 10 行，防止远端 Shell/提示符折叠错位
        final safeRows = height < 10 ? 10 : height;
        _service.resize(width, safeRows, pixelWidth, pixelHeight);
      });
    };
    _loadProfiles();
  }

  Future<void> _loadProfiles() async {
    try {
      final profiles = await _profilesStore.load();
      if (mounted) setState(() => _profiles = profiles);
    } catch (_) {
      if (mounted) setState(() => _error = '无法读取本机连接配置');
    }
  }

  SshProfile get _profile => SshProfile(
        name: _name.text.trim(),
        host: _host.text.trim(),
        port: int.tryParse(_port.text.trim()) ?? 0,
        username: _user.text.trim(),
        authMethod: _auth,
      );

  void _selectProfile(SshProfile profile) {
    _host.text = profile.host;
    _port.text = '${profile.port}';
    _user.text = profile.username;
    _name.text = profile.name;
    _rememberCredentials = profile.rememberCredentials;
    if (profile.rememberCredentials) {
      if (profile.authMethod == SshAuthMethod.password) {
        _password.text = profile.password;
        _privateKey.clear();
        _passphrase.clear();
      } else {
        _password.clear();
        _privateKey.text = profile.privateKey;
        _passphrase.text = profile.passphrase;
      }
    } else {
      _password.clear();
      _privateKey.clear();
      _passphrase.clear();
    }
    setState(() {
      _auth = profile.authMethod;
      _error = null;
    });
  }

  Future<void> _saveProfile() async {
    final profile = SshProfile.withCredentials(
      name: _name.text.trim(),
      host: _host.text.trim(),
      port: int.tryParse(_port.text.trim()) ?? 0,
      username: _user.text.trim(),
      authMethod: _auth,
      password: _password.text,
      privateKey: _privateKey.text,
      passphrase: _passphrase.text,
      rememberCredentials: _rememberCredentials,
    );
    final error = profile.validate();
    if (error != null) {
      setState(() => _error = error);
      return;
    }
    final profiles = [
      ..._profiles.where((entry) => entry.identity != profile.identity),
      profile
    ];
    try {
      await _profilesStore.save(profiles);
      if (!mounted) return;
      setState(() => _profiles = profiles);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(_rememberCredentials
            ? '连接配置与本地加密凭据已保存'
            : '连接配置已保存（未记住认证信息）'),
      ));
    } catch (_) {
      if (mounted) setState(() => _error = '连接配置保存失败，请稍后重试');
    }
  }

  Future<void> _connect() async {
    final validation = _profile.validate();
    if (validation != null) {
      setState(() => _error = validation);
      return;
    }
    FocusManager.instance.primaryFocus?.unfocus();
    final attempt = ++_attempt;
    setState(() {
      _connecting = true;
      _ctrl = false;
      _error = null;
      _status = '正在建立加密连接…';
    });
    try {
      await _service.connect(
        profile: _profile,
        password: _password.text,
        privateKey: _privateKey.text,
        passphrase: _passphrase.text,
        confirmHostKey: (algorithm, fingerprint) =>
            _confirmHostKey(algorithm, fingerprint, attempt),
        columns: _terminal.viewWidth,
        rows: _terminal.viewHeight,
        onOutput: (text) {
          if (mounted && attempt == _attempt) _terminal.write(text);
        },
        onClosed: (message) {
          if (!mounted || attempt != _attempt) return;
          setState(() {
            _connected = false;
            _connecting = false;
            _ctrl = false;
            _status = message;
          });
          _terminal.write('\r\n\x1b[33m[$message]\x1b[0m\r\n');
        },
      );
      if (!mounted || attempt != _attempt) return;
      if (!_rememberCredentials) {
        _password.clear();
        _privateKey.clear();
        _passphrase.clear();
      }
      setState(() {
        _connected = _service.isConnected;
        _connecting = false;
        _ctrl = false;
        _configExpanded = false;
        _status = _connected ? '已连接 · ${_profile.identity}' : '远程会话已结束';
      });
      if (_connected) _requestTerminalFocus();
    } catch (error) {
      if (!mounted || attempt != _attempt) return;
      setState(() {
        _connecting = false;
        _connected = false;
        _status = '连接失败';
        _error = error is SshConnectionException || error is SshHostKeyChanged
            ? '$error'
            : '连接失败，请检查服务器与认证设置';
      });
    }
  }

  void _requestTerminalFocus() {
    // TerminalView is mounted by the next frame after connecting. Requesting
    // focus earlier can silently fail because the focus node is not in the tree.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _connected) _terminalFocus.requestFocus();
    });
  }

  Future<bool> _confirmHostKey(
      String algorithm, String fingerprint, int attempt) async {
    if (!mounted || attempt != _attempt) return false;
    final accepted = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: const Text('首次连接：核对服务器指纹'),
        scrollable: true,
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(_profile.authority,
                    style: const TextStyle(fontWeight: FontWeight.bold)),
                const SizedBox(height: 12),
                Text('主机密钥算法：$algorithm'),
                const SizedBox(height: 8),
                SelectableText(fingerprint,
                    style: const TextStyle(fontFamily: 'monospace')),
                const SizedBox(height: 16),
                const Text('请通过可信渠道核对指纹。信任后会保存在本机，后续密钥变化将阻止连接。'),
              ]),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消连接')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('已核对，信任此主机')),
        ],
      ),
    );
    return mounted && attempt == _attempt && accepted == true;
  }

  void _disconnect() {
    _attempt++;
    _service.disconnect();
    setState(() {
      _connecting = false;
      _connected = false;
      _status = '已断开连接';
      _ctrl = false;
    });
    _terminal.write('\r\n\x1b[33m[连接已关闭]\x1b[0m\r\n');
  }

  Future<void> _importKey() async {
    try {
      final result = await FilePicker.platform
          .pickFiles(type: FileType.any, withData: true);
      if (result == null || !mounted) return;
      final file = result.files.single;
      if (file.size > 1024 * 1024) throw const FormatException();
      final bytes = file.bytes ??
          (file.path == null ? null : await File(file.path!).readAsBytes());
      if (bytes == null || bytes.length > 1024 * 1024) {
        throw const FormatException();
      }
      final text = utf8.decode(bytes);
      if (!text.contains('PRIVATE KEY-----')) throw const FormatException();
      if (mounted) {
        setState(() {
          _privateKey.text = text;
          _error = null;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() => _error = '无法导入：请选择 1MB 以内的 PEM / OpenSSH 私钥文件');
      }
    }
  }

  Future<void> _showKnownHosts() async {
    try {
      final hosts = await _service.knownHosts.load();
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('已信任的服务器'),
          content: SizedBox(
              width: 520,
              child: hosts.isEmpty
                  ? const Text('尚未信任任何服务器。')
                  : ListView(
                      shrinkWrap: true,
                      children: hosts.entries
                          .map((entry) => ListTile(
                                contentPadding: EdgeInsets.zero,
                                title: Text(entry.key),
                                subtitle: SelectableText(entry.value),
                                trailing: IconButton(
                                  tooltip: '移除信任',
                                  icon: const Icon(Icons.delete_outline),
                                  onPressed: () async {
                                    try {
                                      final confirmed = await showDialog<bool>(
                                          context: context,
                                          builder: (dialogContext) =>
                                              AlertDialog(
                                                title: const Text('移除主机信任？'),
                                                content: Text(
                                                    '移除 ${entry.key} 后，下次连接会重新要求核对指纹。仅在已确认服务器更换密钥时操作。'),
                                                actions: [
                                                  TextButton(
                                                      onPressed: () =>
                                                          Navigator.pop(
                                                              dialogContext,
                                                              false),
                                                      child: const Text('取消')),
                                                  FilledButton(
                                                      onPressed: () =>
                                                          Navigator.pop(
                                                              dialogContext,
                                                              true),
                                                      child:
                                                          const Text('移除信任')),
                                                ],
                                              ));
                                      if (confirmed == true) {
                                        await _service.knownHosts
                                            .remove(entry.key);
                                        if (context.mounted) {
                                          Navigator.pop(context);
                                        }
                                      }
                                    } catch (_) {
                                      if (mounted) {
                                        setState(
                                            () => _error = '主机信任记录更新失败，请稍后重试');
                                      }
                                    }
                                  },
                                ),
                              ))
                          .toList())),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('关闭'))
          ],
        ),
      );
    } catch (_) {
      if (mounted) setState(() => _error = '无法读取或更新主机信任记录');
    }
  }

  Future<void> _copy({bool all = false}) async {
    final selection = _terminalController.selection;
    String text = '';
    if (!all && selection != null) {
      text = _terminal.buffer.getText(selection);
    }
    if (text.isEmpty) {
      final lines = <String>[];
      for (int i = 0; i < _terminal.buffer.lines.length; i++) {
        final line = _terminal.buffer.lines[i].toString().trimRight();
        if (line.isNotEmpty) lines.add(line);
      }
      text = lines.join('\n');
    }
    if (text.trim().isNotEmpty) {
      await Clipboard.setData(ClipboardData(text: text));
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(selection != null && !all
                ? '已复制选中文本到剪贴板'
                : '已复制终端屏幕输出内容到剪贴板'),
            duration: const Duration(seconds: 2),
          ),
        );
      }
    } else {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('终端当前无可用文本可复制')),
        );
      }
    }
  }

  Future<void> _showCopyMenu() async {
    final selection = _terminalController.selection;
    final hasSelection = selection != null;
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (hasSelection)
                ListTile(
                  leading: const Icon(Icons.select_all_rounded, color: Colors.blueAccent),
                  title: const Text('复制当前选区文本'),
                  subtitle: const Text('仅将触摸或鼠标高亮的内容存入剪贴板'),
                  onTap: () {
                    Navigator.pop(ctx);
                    _copy(all: false);
                  },
                ),
              ListTile(
                leading: const Icon(Icons.copy_all_rounded, color: Colors.tealAccent),
                title: const Text('复制全部终端输出历史'),
                subtitle: const Text('完整提取所有会话缓冲区文本'),
                onTap: () {
                  Navigator.pop(ctx);
                  _copy(all: true);
                },
              ),
              ListTile(
                leading: const Icon(Icons.paste_rounded, color: Colors.amberAccent),
                title: const Text('粘贴剪贴板命令'),
                onTap: () {
                  Navigator.pop(ctx);
                  _paste();
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _confirmDisconnect() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('断开 SSH 连接？'),
        content: Text('确定要断开与 ${_profile.identity} 的远程终端会话吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('断开连接'),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) {
      _disconnect();
    }
  }

  Future<void> _paste() async {
    final clipboard = await Clipboard.getData('text/plain');
    if (!mounted || !_connected || clipboard?.text == null) return;
    final text = clipboard!.text!;
    if (text.contains('\n') || text.contains('\r')) {
      final confirmed = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
                title: const Text('粘贴多行命令？'),
                content: const Text('剪贴板含有换行，可能立即执行命令。请确认内容来自可信来源。'),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(context, false),
                      child: const Text('取消')),
                  FilledButton(
                      onPressed: () => Navigator.pop(context, true),
                      child: const Text('粘贴')),
                ],
              ));
      if (confirmed != true || !mounted || !_connected) return;
    }
    _terminal.paste(text);
    _requestTerminalFocus();
  }

  @override
  void dispose() {
    _attempt++;
    _resizeDebounce?.cancel();
    _service.disconnect();
    _terminal.onOutput = null;
    _terminal.onResize = null;
    _terminalController.dispose();
    _terminalFocus.dispose();
    for (final controller in [
      _host,
      _port,
      _user,
      _password,
      _privateKey,
      _passphrase,
      _name
    ]) {
      controller.clear();
      controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final busy = _connecting || _connected;
    final wide = MediaQuery.sizeOf(context).width >= 920;
    final showTerminal = _connected;
    final form = _buildForm(busy);
    final panelBody = _configExpanded
        ? (showTerminal
            ? ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 320),
                child: SingleChildScrollView(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: form))
            : Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 12), child: form))
        : const SizedBox.shrink();
    final connectionPanel = Material(
      color: Theme.of(context).colorScheme.surfaceContainerLow,
      borderRadius: BorderRadius.circular(12),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        ListTile(
            dense: true,
            title: const Text('连接配置'),
            subtitle:
                Text(_status, maxLines: 1, overflow: TextOverflow.ellipsis),
            trailing:
                Icon(_configExpanded ? Icons.expand_less : Icons.expand_more),
            onTap: () => setState(() => _configExpanded = !_configExpanded)),
        panelBody,
      ]),
    );
    final content = !showTerminal
        ? SingleChildScrollView(
            child: Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints:
                    BoxConstraints(maxWidth: wide ? 680 : double.infinity),
                child: connectionPanel,
              ),
            ),
          )
        : _buildTerminal();
    return Scaffold(
      resizeToAvoidBottomInset: showTerminal,
      appBar: AppBar(
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('SSH 安全终端'),
            if (_connected) ...[
              const SizedBox(width: 8),
              Flexible(
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: Colors.green.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: Colors.green.withValues(alpha: 0.4)),
                  ),
                  child: Text(
                    _profile.identity,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 11.5,
                      color: Colors.green,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ),
            ],
          ],
        ),
        actions: [
          if (_connected)
            IconButton(
              tooltip: '断开连接',
              icon: const Icon(Icons.power_settings_new_rounded, color: Colors.redAccent),
              onPressed: _confirmDisconnect,
            ),
          IconButton(
            tooltip: '已信任的服务器',
            onPressed: busy ? null : _showKnownHosts,
            icon: const Icon(Icons.verified_user_outlined),
          ),
        ],
      ),
      body: SafeArea(
        child: Padding(
          padding: EdgeInsets.all(wide ? (showTerminal ? 10 : 20) : (showTerminal ? 4 : 10)),
          child: content,
        ),
      ),
    );
  }

  Widget _buildForm(bool busy) {
    Widget field(TextEditingController controller, String label,
            {Key? key,
            bool secret = false,
            TextInputType? keyboard,
            String? hint}) =>
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: TextField(
              key: key,
              controller: controller,
              enabled: !busy,
              obscureText: secret && !_showPassword,
              autocorrect: false,
              enableSuggestions: false,
              keyboardType: keyboard,
              decoration: InputDecoration(
                  labelText: label,
                  hintText: hint,
                  border: const OutlineInputBorder(),
                  isDense: true)),
        );
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Text('加密连接 · 本机直连', style: Theme.of(context).textTheme.titleMedium),
      const SizedBox(height: 6),
      const Text('配置与凭据经本地 AES-256 加密保护，防止被其它恶意插件窃取或上传利用。',
          style: TextStyle(fontSize: 12)),
      const SizedBox(height: 16),
      if (_profiles.isNotEmpty) ...[
        PopupMenuButton<SshProfile>(
            enabled: !busy,
            onSelected: _selectProfile,
            itemBuilder: (_) => _profiles
                .map((profile) => PopupMenuItem(
                    value: profile,
                    child: Text(
                        '${profile.name.isEmpty ? profile.host : profile.name}\n${profile.identity}')))
                .toList(),
            child: const ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(Icons.bookmarks_outlined),
                title: Text('选择已保存连接'),
                trailing: Icon(Icons.arrow_drop_down))),
      ],
      field(_name, '连接名称（可选）'),
      field(_host, '主机 / IP',
          key: const Key('ssh-host'),
          hint: '192.168.1.10 或 server.example.com'),
      Row(children: [
        Expanded(flex: 2, child: field(_user, '用户名')),
        const SizedBox(width: 10),
        Expanded(child: field(_port, '端口', keyboard: TextInputType.number))
      ]),
      SegmentedButton<SshAuthMethod>(
          segments: const [
            ButtonSegment(
                value: SshAuthMethod.password,
                label: Text('密码'),
                icon: Icon(Icons.password)),
            ButtonSegment(
                value: SshAuthMethod.privateKey,
                label: Text('私钥'),
                icon: Icon(Icons.key)),
          ],
          selected: {
            _auth
          },
          onSelectionChanged: busy
              ? null
              : (selection) => setState(() => _auth = selection.single)),
      const SizedBox(height: 14),
      if (_auth == SshAuthMethod.password)
        field(_password, 'SSH 密码', secret: true)
      else ...[
        field(_privateKey, 'PEM / OpenSSH 私钥（粘贴或导入）', secret: true),
        OutlinedButton.icon(
            onPressed: busy ? null : _importKey,
            icon: const Icon(Icons.file_open_outlined),
            label: const Text('导入私钥文件')),
        const SizedBox(height: 12),
        field(_passphrase, '私钥口令（未加密则留空）', secret: true),
      ],
      SwitchListTile.adaptive(
          contentPadding: EdgeInsets.zero,
          dense: true,
          title: const Text('显示认证信息'),
          value: _showPassword,
          onChanged:
              busy ? null : (value) => setState(() => _showPassword = value)),
      CheckboxListTile(
          contentPadding: EdgeInsets.zero,
          dense: true,
          title: const Text('记住密码/私钥（本机安全加密保存）'),
          subtitle: const Text('断开或下次打开无需重新输入，凭据仅在本地解密',
              style: TextStyle(fontSize: 11)),
          value: _rememberCredentials,
          onChanged:
              busy ? null : (val) => setState(() => _rememberCredentials = val ?? false)),
      if (_error != null)
        Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Text(_error!,
                key: const Key('ssh-error'),
                style: TextStyle(color: Theme.of(context).colorScheme.error))),
      FilledButton.icon(
          key: const Key('ssh-connect'),
          onPressed: busy ? _disconnect : _connect,
          icon: Icon(busy ? Icons.stop_circle_outlined : Icons.terminal),
          label: Text(_connecting
              ? '取消连接'
              : _connected
                  ? '断开连接'
                  : '连接服务器')),
      const SizedBox(height: 8),
      OutlinedButton.icon(
          onPressed: busy ? null : _saveProfile,
          icon: const Icon(Icons.save_outlined),
          label: const Text('保存连接配置')),
      if (_profiles.any((entry) => entry.identity == _profile.identity))
        TextButton(
            onPressed: busy
                ? null
                : () async {
                    try {
                      final profiles = _profiles
                          .where((entry) => entry.identity != _profile.identity)
                          .toList();
                      await _profilesStore.save(profiles);
                      if (mounted) setState(() => _profiles = profiles);
                    } catch (_) {
                      if (mounted) setState(() => _error = '连接配置删除失败，请稍后重试');
                    }
                  },
            child: const Text('删除当前已保存配置')),
      const SizedBox(height: 12),
    ]);
  }

  Widget _buildTerminal() => ClipRRect(
        borderRadius: BorderRadius.circular(14),
        child: ColoredBox(
            color: const Color(0xFF10151F),
            child: Column(children: [
              Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  color: const Color(0xFF1C2534),
                  child: Row(children: [
                    Icon(Icons.circle,
                        size: 9,
                        color: _connected
                            ? Colors.greenAccent
                            : _connecting
                                ? Colors.amber
                                : Colors.blueGrey),
                    const SizedBox(width: 8),
                    Expanded(
                        child: Text(
                            _connected
                                ? '● 会话在线 · 字体 ${_fontSize.toInt()}pt'
                                : _status,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                color: Colors.white70, fontSize: 12))),
                    if (_connecting)
                      const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2)),
                    IconButton(
                        tooltip: '复制选项与粘贴',
                        onPressed: _showCopyMenu,
                        icon: const Icon(Icons.copy_rounded,
                            color: Colors.white70, size: 18)),
                    IconButton(
                        tooltip: '缩小字体 (当前 ${_fontSize.toInt()}pt)',
                        onPressed: () => setState(
                            () => _fontSize = (_fontSize - 2).clamp(8.0, 42.0)),
                        icon: const Icon(Icons.text_decrease,
                            color: Colors.white70, size: 18)),
                    IconButton(
                        tooltip: '放大字体 (当前 ${_fontSize.toInt()}pt)',
                        onPressed: () => setState(
                            () => _fontSize = (_fontSize + 2).clamp(8.0, 42.0)),
                        icon: const Icon(Icons.text_increase,
                            color: Colors.white70, size: 18)),
                    if (_connected || _connecting)
                      IconButton(
                          tooltip: '断开 SSH 连接',
                          onPressed: _confirmDisconnect,
                          icon: const Icon(Icons.close,
                              color: Colors.white70, size: 18)),
                  ])),
              Expanded(
                  child: TerminalView(_terminal,
                      controller: _terminalController,
                      focusNode: _terminalFocus,
                      readOnly: !_connected,
                      padding: const EdgeInsets.all(10),
                      textStyle: TerminalStyle(fontSize: _fontSize),
                      keyboardType: TextInputType.visiblePassword,
                      // Windows desktop key events are delivered directly by
                      // xterm's hardware listener. Mobile keeps the native
                      // text-input connection for the on-screen keyboard.
                      hardwareKeyboardOnly: Platform.isWindows,
                      deleteDetection: true)),
              SizedBox(
                  height: 44,
                  child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.symmetric(horizontal: 6),
                      child: Row(children: [
                        _terminalButton(
                            'Ctrl', () => setState(() => _ctrl = !_ctrl),
                            selected: _ctrl),
                        _terminalButton('Esc', () => _service.send('\x1b')),
                        _terminalButton('Tab', () => _service.send('\t')),
                        _terminalButton('Ctrl+C', () => _service.send('\x03')),
                        _terminalButton('↑', () => _service.send('\x1b[A')),
                        _terminalButton('↓', () => _service.send('\x1b[B')),
                        _terminalButton('←', () => _service.send('\x1b[D')),
                        _terminalButton('→', () => _service.send('\x1b[C')),
                        _terminalButton('选区复制', () => _copy(all: false)),
                        _terminalButton('全部复制', () => _copy(all: true)),
                        _terminalButton('粘贴', _paste),
                        TextButton(
                            onPressed: () {
                              _terminal.write('\x1b[2J\x1b[H\x1b[3J');
                            },
                            child: const Text('清屏')),
                      ]))),
            ])),
      );

  Widget _terminalButton(String label, VoidCallback onPressed,
          {bool selected = false}) =>
      TextButton(
        style: TextButton.styleFrom(
            foregroundColor: selected ? Colors.amber : Colors.lightBlueAccent,
            minimumSize: const Size(44, 40),
            padding: const EdgeInsets.symmetric(horizontal: 10)),
        onPressed: !_connected
            ? null
            : () {
                onPressed();
                _requestTerminalFocus();
              },
        child: Text(label),
      );
}
