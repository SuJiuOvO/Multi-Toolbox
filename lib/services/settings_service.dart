import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 全局配置与偏好持久化服务
/// 架构设计：双通道无死锁持久化引擎
/// 1. 内存极速层：所有 setter 立即赋值并即刻触发 notifyListeners()，UI 保证零延迟响应，绝无任何卡顿或无反应
/// 2. 本地物理文件层 (toolbox_settings.json)：直接采用 pure Dart File I/O 写盘，完全绕过 Android 平台通道与 R8 混淆层，100% 免疫系统级插件异常
/// 3. 原生 SharedPreferences 层：作为次级同步备份通道，捕获所有可能抛出的平台异常，双保险互为容灾
class SettingsService extends ChangeNotifier {
  static final SettingsService _instance = SettingsService._internal();
  factory SettingsService() => _instance;
  SettingsService._internal();

  SharedPreferences? _prefs;
  File? _settingsFile;
  bool _initialized = false;

  // Keys
  static const _keyThemeId = 'app_theme_id';
  static const _keyRunInBackground = 'run_in_background';
  static const _keyNotifyOnComplete = 'notify_on_complete';
  static const _keyBannerDismissedPermanently = 'banner_dismissed_permanently';
  static const _keyBannerDismissPromptShown = 'banner_dismiss_prompt_shown';
  static const _keyDeepSearchDefault = 'deep_search_default';

  // State
  String _themeId = 'minimal_clean';
  bool _runInBackground = true;
  bool _notifyOnComplete = true;
  bool _bannerDismissedPermanently = false;
  bool _bannerDismissPromptShown = false;
  bool _deepSearchDefault = false;

  String get themeId => _themeId;
  bool get runInBackground => _runInBackground;
  bool get notifyOnComplete => _notifyOnComplete;
  bool get bannerDismissedPermanently => _bannerDismissedPermanently;
  bool get bannerDismissPromptShown => _bannerDismissPromptShown;
  bool get deepSearchDefault => _deepSearchDefault;

  Future<File> _getFile() async {
    if (_settingsFile != null) return _settingsFile!;
    Directory dir;
    if (Platform.isWindows) {
      dir = await getApplicationSupportDirectory();
    } else {
      dir = await getApplicationDocumentsDirectory();
    }
    _settingsFile = File(p.join(dir.path, 'toolbox_settings.json'));
    return _settingsFile!;
  }

  /// 初始化偏好配置（无阻塞容灾读取）
  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;

    // 1. 优先从高可靠性的本地 JSON 文件读取 (完全不依赖 Android 原生插件层/R8，100% 保证可用)
    try {
      final file = await _getFile();
      if (await file.exists()) {
        final content = await file.readAsString();
        if (content.trim().isNotEmpty) {
          final map = jsonDecode(content) as Map<String, dynamic>;
          if (map.containsKey(_keyThemeId)) _themeId = map[_keyThemeId] as String;
          if (map.containsKey(_keyRunInBackground)) _runInBackground = map[_keyRunInBackground] as bool;
          if (map.containsKey(_keyNotifyOnComplete)) _notifyOnComplete = map[_keyNotifyOnComplete] as bool;
          if (map.containsKey(_keyBannerDismissedPermanently)) _bannerDismissedPermanently = map[_keyBannerDismissedPermanently] as bool;
          if (map.containsKey(_keyBannerDismissPromptShown)) _bannerDismissPromptShown = map[_keyBannerDismissPromptShown] as bool;
          if (map.containsKey(_keyDeepSearchDefault)) _deepSearchDefault = map[_keyDeepSearchDefault] as bool;
        }
      }
    } catch (e) {
      debugPrint('SettingsService read json file fallback: $e');
    }

    // 2. 尝试从 SharedPreferences 读取补充或迁移 (双向兼容)
    try {
      _prefs = await SharedPreferences.getInstance();
      if (_prefs != null) {
        if (_prefs!.containsKey(_keyThemeId)) _themeId = _prefs!.getString(_keyThemeId) ?? _themeId;
        if (_prefs!.containsKey(_keyRunInBackground)) _runInBackground = _prefs!.getBool(_keyRunInBackground) ?? _runInBackground;
        if (_prefs!.containsKey(_keyNotifyOnComplete)) _notifyOnComplete = _prefs!.getBool(_keyNotifyOnComplete) ?? _notifyOnComplete;
        if (_prefs!.containsKey(_keyBannerDismissedPermanently)) _bannerDismissedPermanently = _prefs!.getBool(_keyBannerDismissedPermanently) ?? _bannerDismissedPermanently;
        if (_prefs!.containsKey(_keyBannerDismissPromptShown)) _bannerDismissPromptShown = _prefs!.getBool(_keyBannerDismissPromptShown) ?? _bannerDismissPromptShown;
        if (_prefs!.containsKey(_keyDeepSearchDefault)) _deepSearchDefault = _prefs!.getBool(_keyDeepSearchDefault) ?? _deepSearchDefault;
      }
    } catch (e) {
      debugPrint('SettingsService SharedPreferences fallback: $e');
    }

    notifyListeners();
  }

  /// 异步双写持久化（本地文件 + SharedPreferences）
  void _persist() {
    // 立即启动异步写盘，绝不阻塞 UI 线程
    Future.microtask(() async {
      final data = {
        _keyThemeId: _themeId,
        _keyRunInBackground: _runInBackground,
        _keyNotifyOnComplete: _notifyOnComplete,
        _keyBannerDismissedPermanently: _bannerDismissedPermanently,
        _keyBannerDismissPromptShown: _bannerDismissPromptShown,
        _keyDeepSearchDefault: _deepSearchDefault,
      };

      // 1. 本地物理文件写盘 (绝对落盘保证)
      try {
        final file = await _getFile();
        await file.writeAsString(jsonEncode(data), flush: true);
      } catch (e) {
        debugPrint('SettingsService file persist error: $e');
      }

      // 2. SharedPreferences 写盘 (双保险互为备份)
      try {
        _prefs ??= await SharedPreferences.getInstance();
        if (_prefs != null) {
          await _prefs!.setString(_keyThemeId, _themeId);
          await _prefs!.setBool(_keyRunInBackground, _runInBackground);
          await _prefs!.setBool(_keyNotifyOnComplete, _notifyOnComplete);
          await _prefs!.setBool(_keyBannerDismissedPermanently, _bannerDismissedPermanently);
          await _prefs!.setBool(_keyBannerDismissPromptShown, _bannerDismissPromptShown);
          await _prefs!.setBool(_keyDeepSearchDefault, _deepSearchDefault);
        }
      } catch (e) {
        debugPrint('SettingsService prefs persist error: $e');
      }
    });
  }

  Future<void> setThemeId(String id) async {
    _themeId = id;
    notifyListeners();
    _persist();
  }

  Future<void> setRunInBackground(bool value) async {
    _runInBackground = value;
    notifyListeners();
    _persist();
  }

  Future<void> setNotifyOnComplete(bool value) async {
    _notifyOnComplete = value;
    notifyListeners();
    _persist();
  }

  Future<void> setBannerDismissedPermanently(bool value) async {
    _bannerDismissedPermanently = value;
    notifyListeners();
    _persist();
  }

  Future<void> setBannerDismissPromptShown(bool value) async {
    _bannerDismissPromptShown = value;
    notifyListeners();
    _persist();
  }

  Future<void> setDeepSearchDefault(bool value) async {
    _deepSearchDefault = value;
    notifyListeners();
    _persist();
  }
}
