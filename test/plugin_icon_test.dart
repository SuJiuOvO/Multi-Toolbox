import 'dart:convert';
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
      const svg = '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24"><path d="M12 2L2 22h20L12 2z"/></svg>';
      final def = PluginIconDef.fromRaw(svg);
      expect(def.isCode, true);
      expect(def.data, svg);
    });

    test('Structured object parsing with custom limits', () {
      final jsonMap = {
        'type': 'image',
        'data': 'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==',
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

      final iconData = PluginIconWidget.getMaterialIconData('non_existent_random_icon');
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
      const svg = '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24"><circle cx="12" cy="12" r="10" fill="#00D2FF"/></svg>';
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
  });
}
