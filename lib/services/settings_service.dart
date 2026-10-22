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
  String _themeId = 'tech_blue';
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

  Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
    _themeId = _prefs?.getString(_keyThemeId) ?? 'tech_blue';
    _runInBackground = _prefs?.getBool(_keyRunInBackground) ?? true;
    _notifyOnComplete = _prefs?.getBool(_keyNotifyOnComplete) ?? true;
    _bannerDismissedPermanently = _prefs?.getBool(_keyBannerDismissedPermanently) ?? false;
    _bannerDismissPromptShown = _prefs?.getBool(_keyBannerDismissPromptShown) ?? false;
    _deepSearchDefault = _prefs?.getBool(_keyDeepSearchDefault) ?? false;
    notifyListeners();
  }

  Future<void> setThemeId(String id) async {
    _themeId = id;
    await _prefs?.setString(_keyThemeId, id);
    notifyListeners();
  }

  Future<void> setRunInBackground(bool value) async {
    _runInBackground = value;
    await _prefs?.setBool(_keyRunInBackground, value);
    notifyListeners();
  }

  Future<void> setNotifyOnComplete(bool value) async {
    _notifyOnComplete = value;
    await _prefs?.setBool(_keyNotifyOnComplete, value);
    notifyListeners();
  }

  Future<void> setBannerDismissedPermanently(bool value) async {
    _bannerDismissedPermanently = value;
    await _prefs?.setBool(_keyBannerDismissedPermanently, value);
    notifyListeners();
  }

  Future<void> setBannerDismissPromptShown(bool value) async {
    _bannerDismissPromptShown = value;
    await _prefs?.setBool(_keyBannerDismissPromptShown, value);
    notifyListeners();
  }

  Future<void> setDeepSearchDefault(bool value) async {
    _deepSearchDefault = value;
    await _prefs?.setBool(_keyDeepSearchDefault, value);
    notifyListeners();
  }
}
