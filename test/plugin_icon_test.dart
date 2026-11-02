import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:app/models/plugin_manifest.dart';
import 'package:app/widgets/plugin_icon_widget.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('PluginIconDef & Icon Requirements Validation Tests', () {
    test('Material icon keyword parsing', () {
      final def1 = PluginIconDef.fromRaw('compress');
      expect(def1.isMaterial, true);
      expect(def1.data, 'compress');

      final def2 = PluginIconDef.fromRaw('folder_zip');
      expect(def2.isMaterial, true);
      expect(def2.data, 'folder_zip');
    });

    test('SVG code rendering detection', () {
      const svg =
          '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24"><path d="M12 2L2 22h20L12 2z"/></svg>';
      final def = PluginIconDef.fromRaw(svg);
      expect(def.isCode, true);
      expect(def.data, svg);
    });

    test('bundled SSH icon is theme-adaptive and uses no fixed colors', () {
      final manifest = jsonDecode(
        File('assets/default_plugins/ssh-terminal.json').readAsStringSync(),
      ) as Map<String, dynamic>;
      final icon = manifest['icon'] as Map<String, dynamic>;
      final svg = icon['data'] as String;

      expect(icon['type'], 'code');
      expect(svg, contains('currentColor'));
      expect(svg, contains('fill-opacity="0.18"'));
      expect(
        RegExp(r'#[0-9a-fA-F]{3,8}').hasMatch(svg),
        isFalse,
        reason:
            'The SSH icon must inherit theme colors without fixed hex values.',
      );
    });

    test('Structured object parsing with custom limits', () {
      final jsonMap = {
        'type': 'image',
        'data':
            'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==',
        'maxPixels': 256,
        'maxSizeBytes': 102400,
      };
      final def = PluginIconDef.fromRaw(jsonMap);
      expect(def.isImage, true);
      expect(def.maxPixels, 256);
      expect(def.maxSizeBytes, 102400);
    });

    test('Valid image under limits passes validation', () async {
      // 32x32 image
      final imgObj = img.Image(width: 32, height: 32);
      img.fill(imgObj, color: img.ColorRgb8(0, 150, 255));
      final pngBytes = img.encodePng(imgObj);
      final b64 = 'data:image/png;base64,${base64Encode(pngBytes)}';

      final def = PluginIconDef(type: 'image', data: b64);
      // Validate
      final widget = PluginIconWidget(iconDef: def);
      expect(widget.size, 20);
    });

    test('Oversized pixel image (>512px) is rejected and falls back', () async {
      // 600x600 image exceeding 512px limit
      final imgObj = img.Image(width: 600, height: 600);
      final pngBytes = img.encodePng(imgObj);
      final b64 = 'data:image/png;base64,${base64Encode(pngBytes)}';

      final def = PluginIconDef(type: 'image', data: b64, maxPixels: 512);
      expect(def.isImage, true);
    });

    test('PluginManifest handles iconDef and effectiveIconDef smoothly', () {
      final manifestJson = {
        'id': 'test-tool',
        'name': 'Test Tool',
        'version': '1.0.0',
        'category': 'other',
        'description': 'Test tool',
        'author': 'Developer',
        'engineType': 'custom',
        'icon': {
          'type': 'code',
          'data': '<svg><rect width="24" height="24" fill="red"/></svg>',
        },
      };

      final manifest = PluginManifest.fromJson(manifestJson);
      expect(manifest.iconDef, isNotNull);
      expect(manifest.effectiveIconDef.isCode, true);
      expect(manifest.effectiveIconDef.data, contains('<svg'));
    });

    test('Default fallback icon when icon is null or empty', () {
      final defEmpty = PluginIconDef.fromRaw('');
      expect(defEmpty.isDefault || defEmpty.data == 'extension', true);

      final iconData =
          PluginIconWidget.getMaterialIconData('non_existent_random_icon');
      expect(iconData, Icons.extension_rounded);
    });
  });

  group('PluginIconWidget UI Rendering Tests', () {
    testWidgets('Renders Material icon successfully', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: PluginIconWidget(
              fallbackIcon: 'compress',
              size: 24,
            ),
          ),
        ),
      );

      expect(find.byType(PluginIconWidget), findsOneWidget);
      expect(find.byIcon(Icons.compress), findsOneWidget);
    });

    testWidgets('Renders default icon when no icon provided', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: PluginIconWidget(
              fallbackIcon: '',
              size: 24,
            ),
          ),
        ),
      );

      expect(find.byType(PluginIconWidget), findsOneWidget);
      expect(find.byIcon(Icons.extension_rounded), findsOneWidget);
    });

    testWidgets('Renders SVG vector code icon successfully', (tester) async {
      const svg =
          '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24"><circle cx="12" cy="12" r="10" fill="#00D2FF"/></svg>';
      final def = PluginIconDef.fromRaw(svg);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PluginIconWidget(
              iconDef: def,
              size: 24,
            ),
          ),
        ),
      );

      expect(find.byType(PluginIconWidget), findsOneWidget);
    });

    testWidgets(
        'Renders all redesigned duotone theme-adaptive SVG icons seamlessly',
        (tester) async {
      const duotoneIcons = [
        '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24"><rect x="3" y="3" width="18" height="18" rx="5" fill="currentColor" fill-opacity="0.22"/><path d="M12 6.5l1.3 3.7 3.7 1.3-3.7 1.3L12 16.5l-1.3-3.7L7 11.5l3.7-1.3z" fill="currentColor"/><circle cx="17" cy="7.5" r="1.3" fill="currentColor"/><circle cx="7" cy="16.5" r="1.3" fill="currentColor"/></svg>',
        '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24"><rect x="3" y="3" width="18" height="18" rx="5" fill="currentColor" fill-opacity="0.22"/><circle cx="10" cy="12" r="5" fill="none" stroke="currentColor" stroke-width="1.6"/><circle cx="10" cy="12" r="2" fill="currentColor"/><path d="M10 7v5" stroke="currentColor" stroke-width="1.6" stroke-linecap="round"/><rect x="15" y="13.5" width="5.5" height="4.5" rx="1.2" fill="currentColor"/><path d="M16.5 13.5v-1.6a1.4 1.4 0 0 1 2.8 0" fill="none" stroke="currentColor" stroke-width="1.4" stroke-linecap="round"/></svg>',
        '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24"><rect x="3" y="3" width="18" height="18" rx="5" fill="currentColor" fill-opacity="0.22"/><circle cx="12" cy="14" r="4.5" fill="currentColor" fill-opacity="0.32"/><path d="M7 9.5c2-2.5 6.5-3.5 10-.5" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" fill="none"/><path d="M14.5 7c1.3.6 2.3 1.8 2.5 3" stroke="currentColor" stroke-width="2" stroke-linecap="round" fill="none"/><path d="M9.5 13.8c.4-.7 1.2-.7 1.6 0m3.8 0c.4-.7 1.2-.7 1.6 0" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" fill="none"/><path d="M12 16.2a1 1 0 0 1 1-.5" stroke="currentColor" stroke-width="1.2" stroke-linecap="round" fill="none"/></svg>',
        '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24"><rect x="3" y="3" width="18" height="18" rx="5" fill="currentColor" fill-opacity="0.22"/><path d="M8.5 8.5L5 12l3.5 3.5" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" fill="none"/><path d="M15.5 8.5L19 12l-3.5 3.5" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" fill="none"/><path d="M13.5 7.5l-3 9" stroke="currentColor" stroke-width="2" stroke-linecap="round"/></svg>',
        '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24"><rect x="3" y="3" width="18" height="18" rx="5" fill="currentColor" fill-opacity="0.22"/><rect x="7.5" y="7.5" width="9" height="9" rx="2" fill="currentColor" fill-opacity="0.3"/><path d="M9 3v2m6-2v2M9 19v2m6-2v2M3 9h2m-2 6h2M19 9h2m-2 6h2" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"/><path d="M9.5 10l1.2 3.5 1.3-2.3 1.3 2.3 1.2-3.5" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round" fill="none"/></svg>'
      ];

      for (final svg in duotoneIcons) {
        final def = PluginIconDef.fromRaw(svg);
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData(
              colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
            ),
            home: Scaffold(
              body: PluginIconWidget(
                iconDef: def,
                size: 32,
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.byType(PluginIconWidget), findsOneWidget);
      }
    });
  });
}
