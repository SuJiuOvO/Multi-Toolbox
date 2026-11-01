import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:window_manager/window_manager.dart';

import '../models/bulletin_settings.dart';

class HandheldBulletinPage extends StatefulWidget {
  /// These switches allow embedders/tests to preview without changing the display.
  const HandheldBulletinPage({
    super.key,
    this.animatePreview = true,
    this.managePresentationSystem = true,
  });
  final bool animatePreview;
  final bool managePresentationSystem;
  static const preferenceKey = 'handheld_bulletin.settings.v1';

  @override
  State<HandheldBulletinPage> createState() => _HandheldBulletinPageState();
}

class _HandheldBulletinPageState extends State<HandheldBulletinPage> {
  BulletinSettings _settings = const BulletinSettings();
  final _text = TextEditingController();
  Timer? _saveTimer;
  SharedPreferences? _preferences;
  bool _edited = false;
  String _saveStatus = '正在读取本机设置…';

  @override
  void initState() {
    super.initState();
    _text.text = _settings.text;
    _load();
  }

  Future<void> _load() async {
    try {
      _preferences = await SharedPreferences.getInstance();
      if (!mounted) return;
      setState(() {
        if (!_edited) {
          _settings = BulletinSettings.decode(
              _preferences!.getString(HandheldBulletinPage.preferenceKey));
          _text.text = _settings.text;
        }
        _saveStatus = '设置仅保存在本机';
      });
      if (_edited) await _save();
    } catch (_) {
      if (mounted) setState(() => _saveStatus = '本机设置读取失败，仍可正常展示');
    }
  }

  Future<void> _save() async {
    final preferences = _preferences;
    if (preferences == null) return;
    final content = jsonEncode(_settings.toJson());
    try {
      final saved = await preferences.setString(
          HandheldBulletinPage.preferenceKey, content);
      if (mounted) {
        setState(() => _saveStatus = saved ? '已自动保存到本机' : '保存失败，请稍后重试');
      }
    } catch (_) {
      if (mounted) setState(() => _saveStatus = '保存失败，请稍后重试');
    }
  }

  void _change(BulletinSettings settings) {
    setState(() {
      _edited = true;
      _settings = settings;
      _saveStatus = '正在保存…';
    });
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 300), _save);
  }

  @override
  void dispose() {
    _saveTimer?.cancel();
    unawaited(_save());
    _text.dispose();
    super.dispose();
  }

  Future<void> _present() async {
    if (_settings.text.trim().isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('先写下要展示的文字')));
      return;
    }
    _saveTimer?.cancel();
    await _save();
    if (!mounted) return;
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => BulletinPresentationPage(
          settings: _settings, manageSystem: widget.managePresentationSystem),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final preview =
        Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Row(children: [
        const Icon(Icons.visibility_outlined, size: 18),
        const SizedBox(width: 8),
        const Text('实时预览', style: TextStyle(fontWeight: FontWeight.w700)),
        const Spacer(),
        Text('效果随设置更新', style: theme.textTheme.labelSmall),
      ]),
      const SizedBox(height: 12),
      ClipRRect(
          borderRadius: BorderRadius.circular(20),
          child: AspectRatio(
            aspectRatio: 16 / 9,
            child: BulletinCanvas(
                settings: _settings, playing: widget.animatePreview),
          )),
      const SizedBox(height: 14),
      Text('全屏后轻触画面显示控制栏，空格暂停，Esc 返回。静止模式会自动缩小过长文字。',
          style: theme.textTheme.bodySmall
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
      const SizedBox(height: 20),
      FilledButton.icon(
          onPressed: _present,
          icon: const Icon(Icons.fullscreen_rounded),
          label: const Padding(
              padding: EdgeInsets.symmetric(vertical: 14),
              child: Text('开始全屏举牌'))),
      const SizedBox(height: 10),
      Center(child: Text(_saveStatus, style: theme.textTheme.labelSmall)),
    ]);
    final controls = <Widget>[
      _section('写下你的话', Icons.edit_note_rounded, [
        TextField(
            controller: _text,
            minLines: 2,
            maxLines: 5,
            maxLength: 2000,
            decoration: const InputDecoration(
                labelText: '举牌文字',
                hintText: '支持中文、Emoji 和换行',
                border: OutlineInputBorder()),
            onChanged: (value) => _change(_settings.copyWith(text: value))),
        Wrap(
            spacing: 8,
            runSpacing: 8,
            children: BulletinSettings.presets.entries
                .map((entry) => ActionChip(
                      label: Text(entry.key),
                      onPressed: () {
                        _text.text = entry.value.text;
                        _change(entry.value);
                      },
                    ))
                .toList()),
      ]),
      _section('移动与排版', Icons.tune_rounded, [
        DropdownButtonFormField<String>(
          initialValue: _settings.direction,
          key: ValueKey('direction-${_settings.direction}'),
          decoration: const InputDecoration(
              labelText: '滚动方向', border: OutlineInputBorder()),
          items: const [
            DropdownMenuItem(value: 'still', child: Text('静止举牌 · 自动适配')),
            DropdownMenuItem(value: 'left', child: Text('向左滚动 ←')),
            DropdownMenuItem(value: 'right', child: Text('向右滚动 →')),
            DropdownMenuItem(value: 'up', child: Text('向上滚动 ↑')),
            DropdownMenuItem(value: 'down', child: Text('向下滚动 ↓')),
          ],
          onChanged: (value) {
            if (value != null) _change(_settings.copyWith(direction: value));
          },
        ),
        _slider('字体大小', _settings.fontSize, 24, 320, 'px',
            (value) => _change(_settings.copyWith(fontSize: value))),
        if (_settings.direction != 'still')
          _slider('滚动速度', _settings.speed, 10, 500, 'px/s',
              (value) => _change(_settings.copyWith(speed: value))),
        _slider('字间距', _settings.letterSpacing, -2, 30, 'px',
            (value) => _change(_settings.copyWith(letterSpacing: value))),
        _slider('行高', _settings.lineHeight, 1, 2, '倍',
            (value) => _change(_settings.copyWith(lineHeight: value)),
            decimals: 1),
        SwitchListTile.adaptive(
            contentPadding: EdgeInsets.zero,
            title: const Text('加粗文字'),
            value: _settings.bold,
            onChanged: (value) => _change(_settings.copyWith(bold: value))),
      ]),
      _section('颜色与效果', Icons.palette_outlined, [
        _colorRow('文字颜色', _settings.textColor,
            (value) => _change(_settings.copyWith(textColor: value))),
        const SizedBox(height: 14),
        _colorRow('背景颜色', _settings.backgroundColor,
            (value) => _change(_settings.copyWith(backgroundColor: value))),
        const SizedBox(height: 12),
        SwitchListTile.adaptive(
            contentPadding: EdgeInsets.zero,
            title: const Text('霓虹发光'),
            value: _settings.glow,
            onChanged: (value) => _change(_settings.copyWith(glow: value))),
        SwitchListTile.adaptive(
            contentPadding: EdgeInsets.zero,
            title: const Text('空心描边'),
            value: _settings.stroke,
            onChanged: (value) => _change(_settings.copyWith(stroke: value))),
        SwitchListTile.adaptive(
            contentPadding: EdgeInsets.zero,
            title: const Text('LED 点阵'),
            value: _settings.led,
            onChanged: (value) => _change(_settings.copyWith(led: value))),
        SwitchListTile.adaptive(
            contentPadding: EdgeInsets.zero,
            title: const Text('慢速闪烁'),
            subtitle: const Text('对闪光敏感时请关闭此选项'),
            value: _settings.flash,
            onChanged: (value) => _change(_settings.copyWith(flash: value))),
        if (_settings.flash)
          _slider('闪烁周期', _settings.flashPeriod, 1, 5, '秒',
              (value) => _change(_settings.copyWith(flashPeriod: value)),
              decimals: 1),
      ]),
      _section('举牌方式', Icons.screen_rotation_rounded, [
        SwitchListTile.adaptive(
            contentPadding: EdgeInsets.zero,
            title: const Text('全屏时使用横屏'),
            subtitle: const Text('适用于支持方向切换的 Android 设备'),
            value: _settings.landscape,
            onChanged: (value) =>
                _change(_settings.copyWith(landscape: value))),
        SwitchListTile.adaptive(
            contentPadding: EdgeInsets.zero,
            title: const Text('水平镜像'),
            subtitle: const Text('适合对着镜子或摄像头展示'),
            value: _settings.mirror,
            onChanged: (value) => _change(_settings.copyWith(mirror: value))),
        DropdownButtonFormField<int>(
          initialValue: _settings.quarterTurns,
          key: ValueKey('rotation-${_settings.quarterTurns}'),
          decoration: const InputDecoration(
              labelText: '画面旋转', border: OutlineInputBorder()),
          items: [
            for (var i = 0; i < 4; i++)
              DropdownMenuItem(value: i, child: Text('${i * 90}°'))
          ],
          onChanged: (value) {
            if (value != null) _change(_settings.copyWith(quarterTurns: value));
          },
        ),
      ]),
    ];
    return Scaffold(
      appBar: AppBar(title: const Text('手持弹幕举牌')),
      body: LayoutBuilder(builder: (context, bounds) {
        if (bounds.maxWidth >= 1000) {
          return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(
                child: ListView(
                    padding: const EdgeInsets.fromLTRB(24, 16, 12, 32),
                    children: controls)),
            Expanded(
                child: SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(16, 20, 24, 32),
                    child: preview)),
          ]);
        }
        return ListView(
            padding: const EdgeInsets.all(16),
            children: [preview, const SizedBox(height: 24), ...controls]);
      }),
    );
  }

  Widget _section(String title, IconData icon, List<Widget> children) => Card(
        margin: const EdgeInsets.only(bottom: 18),
        child: Padding(
            padding: const EdgeInsets.all(18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(children: [
                  Icon(icon, size: 20),
                  const SizedBox(width: 8),
                  Text(title,
                      style: const TextStyle(
                          fontWeight: FontWeight.w700, fontSize: 16))
                ]),
                const SizedBox(height: 18),
                ...children,
              ],
            )),
      );

  Widget _slider(String label, double value, double min, double max,
          String unit, ValueChanged<double> onChanged,
          {int decimals = 0}) =>
      Padding(
        padding: const EdgeInsets.only(top: 14),
        child: Column(children: [
          Row(children: [
            Text(label),
            const Spacer(),
            Text('${value.toStringAsFixed(decimals)} $unit')
          ]),
          Slider(
              value: value.clamp(min, max),
              min: min,
              max: max,
              onChanged: onChanged),
        ]),
      );

  Widget _colorRow(String label, int current, ValueChanged<int> onChanged) {
    const swatches = [
      0xFFFFFFFF,
      0xFF53FFAA,
      0xFFFF75C8,
      0xFFFFB547,
      0xFF62C7FF,
      0xFFEF4444,
      0xFF080D12,
      0xFF134E4A
    ];
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Text(label),
        const Spacer(),
        TextButton.icon(
          onPressed: () => _customColor(label, current, onChanged),
          icon: const Icon(Icons.colorize, size: 16),
          label: Text(
              '#${(current & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase()}'),
        )
      ]),
      Wrap(
          spacing: 10,
          runSpacing: 10,
          children: swatches
              .map((color) => Semantics(
                    label: '$label #${(color & 0xFFFFFF).toRadixString(16)}',
                    button: true,
                    selected: color == current,
                    child: InkWell(
                        borderRadius: BorderRadius.circular(12),
                        onTap: () => onChanged(color),
                        child: Container(
                            width: 36,
                            height: 36,
                            decoration: BoxDecoration(
                                color: Color(color),
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(
                                    color: color == current
                                        ? Theme.of(context).colorScheme.primary
                                        : Colors.grey.shade500,
                                    width: color == current ? 3 : 1)),
                            child: color == current
                                ? Icon(Icons.check,
                                    size: 20,
                                    color: Color(color).computeLuminance() > .4
                                        ? Colors.black
                                        : Colors.white)
                                : null)),
                  ))
              .toList()),
    ]);
  }

  Future<void> _customColor(
      String label, int current, ValueChanged<int> onChanged) async {
    final controller = TextEditingController(
        text: (current & 0xFFFFFF)
            .toRadixString(16)
            .padLeft(6, '0')
            .toUpperCase());
    String? error;
    final value = await showDialog<int>(
        context: context,
        builder: (context) => StatefulBuilder(
            builder: (context, setDialogState) => AlertDialog(
                  title: Text('自定义$label'),
                  content: TextField(
                      controller: controller,
                      autofocus: true,
                      maxLength: 7,
                      decoration: InputDecoration(
                          labelText: '十六进制 RGB',
                          hintText: '#53FFAA',
                          errorText: error)),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.pop(context),
                        child: const Text('取消')),
                    FilledButton(
                        onPressed: () {
                          final hex =
                              controller.text.trim().replaceFirst('#', '');
                          if (!RegExp(r'^[0-9a-fA-F]{6}$').hasMatch(hex)) {
                            setDialogState(() => error = '请输入 6 位十六进制颜色');
                            return;
                          }
                          Navigator.pop(
                              context, int.parse(hex, radix: 16) | 0xFF000000);
                        },
                        child: const Text('应用'))
                  ],
                )));
    // The dialog may still be animating its TextField out of the tree.
    await Future<void>.delayed(const Duration(milliseconds: 250));
    controller.dispose();
    if (mounted && value != null) onChanged(value);
  }
}

class BulletinPresentationPage extends StatefulWidget {
  const BulletinPresentationPage(
      {super.key, required this.settings, this.manageSystem = true});
  final BulletinSettings settings;
  final bool manageSystem;

  @override
  State<BulletinPresentationPage> createState() =>
      _BulletinPresentationPageState();
}

class _ExitBulletinIntent extends Intent {
  const _ExitBulletinIntent();
}

class _ToggleBulletinIntent extends Intent {
  const _ToggleBulletinIntent();
}

class _BulletinPresentationPageState extends State<BulletinPresentationPage> {
  bool _playing = true;
  bool _controls = true;
  Timer? _hideTimer;
  Future<void>? _displaySetup;
  bool? _previousWakelock;
  bool? _previousFullscreen;
  String? _displayNotice;

  @override
  void initState() {
    super.initState();
    if (widget.manageSystem) _displaySetup = _enterDisplay();
    _hideLater();
  }

  Future<void> _enterDisplay() async {
    // Independent APIs: if one platform facility is unavailable, the sign works.
    try {
      _previousWakelock = await WakelockPlus.enabled;
      await WakelockPlus.enable();
    } catch (_) {
      _notice('屏幕常亮不可用，请调整系统息屏时间');
    }
    if (Platform.isWindows) {
      try {
        await windowManager.ensureInitialized();
        _previousFullscreen = await windowManager.isFullScreen();
        await windowManager.setFullScreen(true);
      } catch (_) {
        _notice('窗口全屏不可用，可手动最大化窗口');
      }
    } else if (Platform.isAndroid) {
      try {
        if (widget.settings.landscape) {
          await SystemChrome.setPreferredOrientations([
            DeviceOrientation.landscapeLeft,
            DeviceOrientation.landscapeRight
          ]);
        }
        await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
      } catch (_) {
        _notice('系统限制了横屏或沉浸显示');
      }
    }
  }

  void _notice(String notice) {
    if (mounted) setState(() => _displayNotice = notice);
  }

  Future<void> _restoreDisplay() async {
    await _displaySetup;
    if (_previousWakelock == false) {
      try {
        await WakelockPlus.disable();
      } catch (_) {/* platform unavailable */}
    }
    if (_previousFullscreen != null) {
      try {
        await windowManager.setFullScreen(_previousFullscreen!);
      } catch (_) {/* window closed */}
    }
    if (Platform.isAndroid) {
      try {
        await SystemChrome.setPreferredOrientations([]);
        await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
      } catch (_) {/* activity already gone */}
    }
  }

  void _hideLater() {
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(seconds: 4), () {
      if (mounted) {
        setState(() => _controls = false);
      }
    });
  }

  void _toggleControls() {
    setState(() => _controls = !_controls);
    if (_controls) _hideLater();
  }

  void _togglePlayback() {
    setState(() {
      _playing = !_playing;
      _controls = true;
    });
    _hideLater();
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    if (widget.manageSystem) unawaited(_restoreDisplay());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Shortcuts(
        shortcuts: const {
          SingleActivator(LogicalKeyboardKey.escape): _ExitBulletinIntent(),
          SingleActivator(LogicalKeyboardKey.space): _ToggleBulletinIntent(),
        },
        child: Actions(
            actions: {
              _ExitBulletinIntent:
                  CallbackAction<_ExitBulletinIntent>(onInvoke: (_) {
                Navigator.maybePop(context);
                return null;
              }),
              _ToggleBulletinIntent:
                  CallbackAction<_ToggleBulletinIntent>(onInvoke: (_) {
                _togglePlayback();
                return null;
              }),
            },
            child: Focus(
                autofocus: true,
                child: Scaffold(
                  backgroundColor: Color(widget.settings.backgroundColor),
                  body: Stack(fit: StackFit.expand, children: [
                    GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: _toggleControls,
                        child: BulletinCanvas(
                            settings: widget.settings, playing: _playing)),
                    if (_controls)
                      SafeArea(
                          child: Align(
                        alignment: Alignment.topCenter,
                        child: Container(
                          margin: const EdgeInsets.all(12),
                          padding: const EdgeInsets.symmetric(
                              horizontal: 10, vertical: 6),
                          decoration: BoxDecoration(
                              color: Colors.black.withValues(alpha: .8),
                              borderRadius: BorderRadius.circular(30)),
                          child: Row(mainAxisSize: MainAxisSize.min, children: [
                            IconButton(
                                tooltip: '返回编辑',
                                onPressed: () => Navigator.maybePop(context),
                                icon: const Icon(Icons.arrow_back,
                                    color: Colors.white)),
                            IconButton(
                                tooltip: _playing ? '暂停' : '继续',
                                onPressed: _togglePlayback,
                                icon: Icon(
                                    _playing
                                        ? Icons.pause_rounded
                                        : Icons.play_arrow_rounded,
                                    color: Colors.white)),
                            const SizedBox(width: 8),
                            const Text('轻触隐藏 · Esc 返回',
                                style: TextStyle(
                                    color: Colors.white, fontSize: 12)),
                            const SizedBox(width: 10),
                          ]),
                        ),
                      )),
                    if (_displayNotice != null && _controls)
                      SafeArea(
                          child: Align(
                              alignment: Alignment.bottomCenter,
                              child: Container(
                                  margin: const EdgeInsets.all(12),
                                  padding: const EdgeInsets.all(10),
                                  color: Colors.black87,
                                  child: Text(_displayNotice!,
                                      style: const TextStyle(
                                          color: Colors.white))))),
                  ]),
                ))),
      );
}

/// Shared real time renderer for editor and presentation. Movement uses elapsed
/// time rather than frame count, so animation speed is stable across refresh rates.
class BulletinCanvas extends StatefulWidget {
  const BulletinCanvas(
      {super.key, required this.settings, this.playing = true});
  final BulletinSettings settings;
  final bool playing;
  @override
  State<BulletinCanvas> createState() => _BulletinCanvasState();
}

class _BulletinCanvasState extends State<BulletinCanvas>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late final Ticker _ticker;
  final _seconds = ValueNotifier<double>(0);
  double _previous = 0;
  bool _foreground = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _ticker = createTicker((elapsed) {
      final now = elapsed.inMicroseconds / Duration.microsecondsPerSecond;
      _seconds.value += now - _previous;
      _previous = now;
    });
    _updateTicker();
  }

  void _updateTicker() {
    final animate = widget.playing &&
        _foreground &&
        (widget.settings.direction != 'still' || widget.settings.flash);
    if (animate && !_ticker.isActive) {
      _previous = 0;
      _ticker.start();
    }
    if (!animate && _ticker.isActive) _ticker.stop();
  }

  @override
  void didUpdateWidget(covariant BulletinCanvas oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.settings.direction != widget.settings.direction ||
        oldWidget.settings.text != widget.settings.text) {
      _seconds.value = 0;
    }
    _updateTicker();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    _updateTicker();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _ticker.dispose();
    _seconds.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ColoredBox(
        color: Color(widget.settings.backgroundColor),
        child: RotatedBox(
            quarterTurns: widget.settings.quarterTurns,
            child: CustomPaint(
                painter: _BulletinPainter(widget.settings, _seconds),
                size: Size.infinite)),
      );
}

class _BulletinPainter extends CustomPainter {
  _BulletinPainter(this.settings, this.seconds) : super(repaint: seconds);
  final BulletinSettings settings;
  final ValueNotifier<double> seconds;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty || settings.text.isEmpty) return;
    canvas.save();
    canvas.clipRect(Offset.zero & size);
    if (settings.mirror) {
      canvas.translate(size.width, 0);
      canvas.scale(-1, 1);
    }
    if (settings.flash &&
        seconds.value % settings.flashPeriod >= settings.flashPeriod * .65) {
      canvas.restore();
      return;
    }
    final color = Color(settings.textColor);
    final style = TextStyle(
      fontSize: settings.fontSize,
      fontWeight: settings.bold ? FontWeight.w900 : FontWeight.w400,
      letterSpacing: settings.letterSpacing,
      height: settings.lineHeight,
      color: settings.stroke ? null : color,
      foreground: settings.stroke
          ? (Paint()
            ..color = color
            ..style = PaintingStyle.stroke
            ..strokeWidth = math.max(1.5, settings.fontSize / 60))
          : null,
      shadows: settings.glow
          ? [
              Shadow(color: color.withValues(alpha: .8), blurRadius: 15),
              Shadow(color: color.withValues(alpha: .5), blurRadius: 30)
            ]
          : null,
    );
    final text = TextPainter(
        text: TextSpan(text: settings.text, style: style),
        textDirection: TextDirection.ltr,
        textAlign: TextAlign.center)
      ..layout();
    if (settings.direction == 'still') {
      final scale = math
          .min(
              1.0,
              math.min((size.width - 24) / math.max(text.width, 1),
                  (size.height - 24) / math.max(text.height, 1)))
          .clamp(.001, 1.0);
      canvas.translate((size.width - text.width * scale) / 2,
          (size.height - text.height * scale) / 2);
      canvas.scale(scale);
      text.paint(canvas, Offset.zero);
    } else {
      final horizontal =
          settings.direction == 'left' || settings.direction == 'right';
      final extent = horizontal ? size.width : size.height;
      final textExtent = horizontal ? text.width : text.height;
      final distance =
          (seconds.value * settings.speed + (extent + textExtent) / 2) %
              (extent + textExtent + 32);
      final forward =
          settings.direction == 'left' || settings.direction == 'up';
      final position = forward ? extent - distance : distance - textExtent;
      text.paint(
          canvas,
          horizontal
              ? Offset(position, (size.height - text.height) / 2)
              : Offset((size.width - text.width) / 2, position));
    }
    canvas.restore();
    text.dispose();
    if (settings.led) {
      // A thin background grid cuts the glyphs into a regular LED matrix.
      final grid = Paint()
        ..color = Color(settings.backgroundColor).withValues(alpha: .86)
        ..strokeWidth = 2;
      canvas.save();
      canvas.clipRect(Offset.zero & size);
      for (double x = 0; x <= size.width; x += 6) {
        canvas.drawLine(Offset(x, 0), Offset(x, size.height), grid);
      }
      for (double y = 0; y <= size.height; y += 6) {
        canvas.drawLine(Offset(0, y), Offset(size.width, y), grid);
      }
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(covariant _BulletinPainter oldDelegate) =>
      oldDelegate.settings != settings;
}
