import 'package:flutter_test/flutter_test.dart';
import 'package:app/services/settings_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('SettingsService Robustness & Persistence Tests', () {
    test('Settings setters update state and notify immediately', () async {
      final settings = SettingsService();
      bool notified = false;
      void listener() {
        notified = true;
      }

      settings.addListener(listener);

      // 1. Banner Dismissed Permanently
      notified = false;
      await settings.setBannerDismissedPermanently(true);
      expect(settings.bannerDismissedPermanently, isTrue);
      expect(notified, isTrue);

      notified = false;
      await settings.setBannerDismissedPermanently(false);
      expect(settings.bannerDismissedPermanently, isFalse);
      expect(notified, isTrue);

      // 2. Theme ID
      notified = false;
      await settings.setThemeId('dark_liquid');
      expect(settings.themeId, 'dark_liquid');
      expect(notified, isTrue);

      // 3. Run In Background
      notified = false;
      await settings.setRunInBackground(false);
      expect(settings.runInBackground, isFalse);
      expect(notified, isTrue);

      // 4. Deep Search Default
      notified = false;
      await settings.setDeepSearchDefault(true);
      expect(settings.deepSearchDefault, isTrue);
      expect(notified, isTrue);

      settings.removeListener(listener);
    });
  });
}
