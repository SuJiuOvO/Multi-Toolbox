import 'dart:convert';
import 'package:app/models/bulletin_settings.dart';
import 'package:app/pages/handheld_bulletin_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test(
      'settings normalize malformed saved values and preserve a valid round trip',
      () {
    final result = BulletinSettings.fromJson({
      'fontSize': 9000,
      'speed': -3,
      'lineHeight': 'NaN',
      'direction': 'unknown',
      'textColor': -10,
      'flash': 'yes',
      'quarterTurns': 99,
    });
    expect(result.fontSize, 320);
    expect(result.speed, 10);
    expect(result.lineHeight, 1.2);
    expect(result.direction, 'left');
    expect(result.textColor, const BulletinSettings().textColor);
    expect(result.flash, isFalse);
    expect(result.quarterTurns, 3);
    expect(BulletinSettings.decode('{broken').fontSize, 112);
    expect(
        BulletinSettings.decode('[1,2,3]').text, const BulletinSettings().text);
    final custom = const BulletinSettings().copyWith(
        text: '欢迎\nHello 世界', direction: 'up', mirror: true, stroke: true);
    expect(BulletinSettings.decode(jsonEncode(custom.toJson())).toJson(),
        custom.toJson());
  });

  testWidgets(
      'editor loads a local sign, applies presets and saves the chosen settings',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    SharedPreferences.setMockInitialValues({
      HandheldBulletinPage.preferenceKey: jsonEncode(
          const BulletinSettings(text: '保存的举牌', direction: 'still').toJson())
    });
    await tester.pumpWidget(const MaterialApp(
        home: HandheldBulletinPage(
            animatePreview: false, managePresentationSystem: false)));
    await tester.pumpAndSettle();
    expect(find.text('保存的举牌'), findsOneWidget);
    await tester.ensureVisible(find.text('接机举牌'));
    await tester.tap(find.text('接机举牌'));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('欢迎回家'), findsOneWidget);
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 10));
      final preferences = await SharedPreferences.getInstance();
      final value = BulletinSettings.decode(
          preferences.getString(HandheldBulletinPage.preferenceKey));
      expect(value.text, '欢迎回家');
      expect(value.direction, 'still');
    });
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('full screen controls pause and resume, Escape returns to editor',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(const MaterialApp(
        home: HandheldBulletinPage(
            animatePreview: false, managePresentationSystem: false)));
    await tester.pump();
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('开始全屏举牌'));
    await tester.tap(find.text('开始全屏举牌'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(BulletinPresentationPage), findsOneWidget);
    expect(find.byTooltip('暂停'), findsOneWidget);
    await tester.tap(find.byTooltip('暂停'));
    await tester.pump();
    expect(find.byTooltip('继续'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump();
    expect(find.byTooltip('暂停'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle(const Duration(milliseconds: 100),
        EnginePhase.sendSemanticsUpdate, const Duration(seconds: 5));
    expect(find.byType(BulletinPresentationPage), findsNothing);
    expect(find.text('手持弹幕举牌'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
      'each moving/rotated/mirrored LED display paints without a layout failure',
      (tester) async {
    for (final direction in BulletinSettings.directions) {
      await tester.pumpWidget(MaterialApp(
          home: Scaffold(
              body: SizedBox(
                  width: 390,
                  height: 180,
                  child: BulletinCanvas(
                      settings: BulletinSettings(
                    text: '测试\nHELLO ♡',
                    direction: direction,
                    mirror: true,
                    quarterTurns: 1,
                    stroke: true,
                    led: true,
                    flash: true,
                  ))))));
      await tester.pump(const Duration(milliseconds: 250));
      expect(tester.takeException(), isNull, reason: direction);
    }
    await tester.pumpWidget(const SizedBox());
  });
}
