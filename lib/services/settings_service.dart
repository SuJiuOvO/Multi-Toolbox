import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

class SettingsService extends ChangeNotifier {
  static final SettingsService _instance = SettingsService._internal();
  factory SettingsService() => _instance;
  SettingsService._internal();

  SharedPreferences? _prefs;

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

  /// 确保 SharedPreferences 实例已初始化，避免任何冷启动或并发时的 null 忽略
  Future<SharedPreferences> _getPrefs() async {
    _prefs ??= await SharedPreferences.getInstance();
    return _prefs!;
  }

  Future<void> init() async {
    try {
      final prefs = await _getPrefs();
      _themeId = prefs.getString(_keyThemeId) ?? 'minimal_clean';
      _runInBackground = prefs.getBool(_keyRunInBackground) ?? true;
      _notifyOnComplete = prefs.getBool(_keyNotifyOnComplete) ?? true;
      _bannerDismissedPermanently = prefs.getBool(_keyBannerDismissedPermanently) ?? false;
      _bannerDismissPromptShown = prefs.getBool(_keyBannerDismissPromptShown) ?? false;
      _deepSearchDefault = prefs.getBool(_keyDeepSearchDefault) ?? false;
      notifyListeners();
    } catch (e) {
      debugPrint('SettingsService.init error: $e');
    }
  }

  Future<void> setThemeId(String id) async {
    _themeId = id;
    final prefs = await _getPrefs();
    await prefs.setString(_keyThemeId, id);
    notifyListeners();
  }

  Future<void> setRunInBackground(bool value) async {
    _runInBackground = value;
    final prefs = await _getPrefs();
    await prefs.setBool(_keyRunInBackground, value);
    notifyListeners();
  }

  Future<void> setNotifyOnComplete(bool value) async {
    _notifyOnComplete = value;
    final prefs = await _getPrefs();
    await prefs.setBool(_keyNotifyOnComplete, value);
    notifyListeners();
  }

  Future<void> setBannerDismissedPermanently(bool value) async {
    _bannerDismissedPermanently = value;
    final prefs = await _getPrefs();
    await prefs.setBool(_keyBannerDismissedPermanently, value);
    notifyListeners();
  }

  Future<void> setBannerDismissPromptShown(bool value) async {
    _bannerDismissPromptShown = value;
    final prefs = await _getPrefs();
    await prefs.setBool(_keyBannerDismissPromptShown, value);
    notifyListeners();
  }

  Future<void> setDeepSearchDefault(bool value) async {
    _deepSearchDefault = value;
    final prefs = await _getPrefs();
    await prefs.setBool(_keyDeepSearchDefault, value);
    notifyListeners();
  }
}
