import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:app/models/plugin_manifest.dart';
import 'package:app/services/plugin_manager_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Version and Compatibility Tests', () {
    test('compareVersions correctly evaluates semantic versions', () {
      expect(PluginManagerService.compareVersions('1.0.0', '1.0.0'), 0);
      expect(PluginManagerService.compareVersions('1.0.1', '1.0.0'), 1);
      expect(PluginManagerService.compareVersions('1.0.0', '1.0.1'), -1);
      expect(PluginManagerService.compareVersions('v2.1.0', '2.0.9'), 1);
      expect(PluginManagerService.compareVersions('1.0.0+1', '1.0.0+2'), 0);
      expect(PluginManagerService.compareVersions('1.10.0', '1.2.0'), 1);
      expect(PluginManagerService.compareVersions('0.9.5', '1.0.0'), -1);
    });

    test('isAppVersionCompatible checks against currentAppVersion (1.0.0)', () {
      // currentAppVersion is 1.0.0
      expect(PluginManagerService.isAppVersionCompatible('1.0.0'), isTrue);
      expect(PluginManagerService.isAppVersionCompatible('0.9.0'), isTrue);
      expect(PluginManagerService.isAppVersionCompatible(''), isTrue);
      expect(PluginManagerService.isAppVersionCompatible('1.1.0'), isFalse);
      expect(PluginManagerService.isAppVersionCompatible('2.0.0'), isFalse);
    });

    test('PluginManifest parses minAppVersion and rich description correctly', () {
      final jsonMap = {
        'id': 'test_tool',
        'name': '测试工具',
        'version': '1.0.0',
        'minAppVersion': '1.2.0',
        'category': 'image',
        'description': '这是一个高精度的图片特征提取与智能剪裁工具，支持深度检索。',
        'icon': 'compress',
        'author': 'Tester',
        'engineType': 'native_image',
        'inputs': [
          {
            'id': 'mode',
            'label': '转换模式',
            'type': 'select',
            'options': [
              {'label': '无损模式', 'value': 'lossless'},
              {'label': '极速模式', 'value': 'fast'}
            ]
          }
        ],
        'action': {
          'handler': 'custom_handler',
          'params': {}
        }
      };

      final manifest = PluginManifest.fromJson(jsonMap);
      expect(manifest.id, 'test_tool');
      expect(manifest.minAppVersion, '1.2.0');
      expect(manifest.description, contains('高精度的图片特征提取'));
      expect(PluginManagerService.isAppVersionCompatible(manifest.minAppVersion), isFalse);
    });
  });

  group('Local Plugin Validation & Installation Tests', () {
    late Directory tempDir;
    late PluginManagerService service;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('toolbox_test_');
      service = PluginManagerService();
    });

    tearDown(() async {
      if (tempDir.existsSync()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('Rejects non-existent file and unsupported extensions', () async {
      final res1 = await service.installLocalPlugin('non_existent_file.json');
      expect(res1.success, isFalse);
      expect(res1.message, contains('不存在'));

      final txtFile = File('${tempDir.path}/test.txt');
      await txtFile.writeAsString('hello');
      final res2 = await service.installLocalPlugin(txtFile.path);
      expect(res2.success, isFalse);
      expect(res2.message, contains('不支持的文件类型'));
    });

    test('Rejects corrupted JSON or invalid structure', () async {
      final badJsonFile = File('${tempDir.path}/bad.json');
      await badJsonFile.writeAsString('{not valid json}');
      final res1 = await service.installLocalPlugin(badJsonFile.path);
      expect(res1.success, isFalse);
      expect(res1.message, contains('JSON 语法解析失败'));

      final listJsonFile = File('${tempDir.path}/list.json');
      await listJsonFile.writeAsString('[1, 2, 3]');
      final res2 = await service.installLocalPlugin(listJsonFile.path);
      expect(res2.success, isFalse);
      expect(res2.message, contains('顶级对象结构'));
    });

    test('Rejects missing required fields and invalid ID', () async {
      final missingFieldFile = File('${tempDir.path}/missing.json');
      await missingFieldFile.writeAsString(jsonEncode({
        'id': 'my_tool',
        'name': '缺少简介的插件',
        'version': '1.0.0',
        'category': 'image',
        // description missing!
      }));
      final res = await service.installLocalPlugin(missingFieldFile.path);
      expect(res.success, isFalse);
      expect(res.message, contains('description'));

      final invalidIdFile = File('${tempDir.path}/invalid_id.json');
      await invalidIdFile.writeAsString(jsonEncode({
        'id': 'my tool with space!',
        'name': '名称',
        'version': '1.0.0',
        'category': 'image',
        'description': '简介',
        'engineType': 'test'
      }));
      final resId = await service.installLocalPlugin(invalidIdFile.path);
      expect(resId.success, isFalse);
      expect(resId.message, contains('英文字母、数字、下划线或连字符'));
    });

    test('Rejects plugin when minAppVersion exceeds client version (1.0.0)', () async {
      final highVersionFile = File('${tempDir.path}/high_min_ver.json');
      await highVersionFile.writeAsString(jsonEncode({
        'id': 'future_tool',
        'name': '次世代功能模块',
        'version': '2.0.0',
        'minAppVersion': '2.0.0',
        'category': 'media',
        'description': '需要百宝箱 2.0.0 客户端才支持运行的功能模块',
        'engineType': 'future_engine',
        'inputs': [],
      }));

      final res = await service.installLocalPlugin(highVersionFile.path);
      expect(res.success, isFalse);
      expect(res.message, contains('客户端版本过低'));
      expect(res.message, contains('v2.0.0'));
    });

    test('Successfully accepts and validates compliant plugin with minAppVersion <= 1.0.0', () async {
      final validPluginFile = File('${tempDir.path}/valid_tool.json');
      await validPluginFile.writeAsString(jsonEncode({
        'id': 'sample_offline_tool',
        'name': '离线合规工具',
        'version': '1.0.0',
        'minAppVersion': '1.0.0',
        'category': 'image',
        'description': '完全符合规范的本地离线功能模块',
        'engineType': 'native_image',
        'inputs': [],
      }));

      final res = await service.installLocalPlugin(validPluginFile.path);
      expect(res.success, isTrue);
      expect(res.plugin, isNotNull);
      expect(res.plugin!.id, 'sample_offline_tool');
    });
  });

  group('Deep Search vs Regular Search Simulation Tests', () {
    final plugins = [
      PluginManifest(
        id: 'img_compress',
        name: '图片格式与质量压缩',
        version: '1.0.0',
        minAppVersion: '1.0.0',
        category: 'image',
        description: '采用高保真有损/无损压缩算法，大幅减小 JPG、PNG、WebP 文件体积',
        icon: 'compress',
        author: 'Toolbox Team',
        engineType: 'native_image',
        inputs: [
          PluginInputDef(
            id: 'quality',
            label: '压缩质量比率',
            type: 'slider',
          )
        ],
      ),
      PluginManifest(
        id: 'cad_dxf',
        name: 'CAD (DXF) 矢量图转换',
        version: '1.0.0',
        minAppVersion: '1.0.0',
        category: 'document',
        description: '解析 AutoCAD DXF 工业图纸图元，高质量导出为高清 PDF 或 PNG 预览图',
        icon: 'transform',
        author: 'Toolbox Team',
        engineType: 'native_dart',
        inputs: [
          PluginInputDef(
            id: 'colorScheme',
            label: '图纸底色风格',
            type: 'select',
            options: [
              PluginSelectOption(label: '经典工程黑底', value: 'black'),
              PluginSelectOption(label: '白底蓝图打印', value: 'white'),
            ],
          )
        ],
      ),
    ];

    test('Regular search matches only name, category, or ID', () {
      // Searching '压缩' matches img_compress name
      final q1 = '压缩';
      final match1 = plugins.where((p) =>
          p.name.contains(q1) || p.category.contains(q1) || p.id.contains(q1)).toList();
      expect(match1.length, 1);
      expect(match1.first.id, 'img_compress');

      // Searching 'AutoCAD' fails in regular search because it only exists in description
      final q2 = 'autocad';
      final match2 = plugins.where((p) =>
          p.name.toLowerCase().contains(q2) ||
          p.category.toLowerCase().contains(q2) ||
          p.id.toLowerCase().contains(q2)).toList();
      expect(match2.isEmpty, isTrue);
    });

    test('Deep search matches keywords inside description and parameter labels/options', () {
      final q = 'autocad';
      final match = plugins.where((p) {
        final nameMatch = p.name.toLowerCase().contains(q);
        final categoryMatch = p.category.toLowerCase().contains(q);
        final idMatch = p.id.toLowerCase().contains(q);
        final descMatch = p.description.toLowerCase().contains(q);
        final inputMatch = p.inputs.any((inp) {
          final labelMatch = inp.label.toLowerCase().contains(q);
          final idMatch = inp.id.toLowerCase().contains(q);
          final optionMatch = inp.options.any((opt) =>
              opt.label.toLowerCase().contains(q) || opt.value.toLowerCase().contains(q));
          return labelMatch || idMatch || optionMatch;
        });
        return nameMatch || categoryMatch || idMatch || descMatch || inputMatch;
      }).toList();

      expect(match.length, 1);
      expect(match.first.id, 'cad_dxf');

      // Test searching an option label: '蓝图'
      final qOpt = '蓝图';
      final matchOpt = plugins.where((p) {
        final nameMatch = p.name.contains(qOpt);
        final categoryMatch = p.category.contains(qOpt);
        final idMatch = p.id.contains(qOpt);
        final descMatch = p.description.contains(qOpt);
        final inputMatch = p.inputs.any((inp) =>
            inp.options.any((opt) => opt.label.contains(qOpt)));
        return nameMatch || categoryMatch || idMatch || descMatch || inputMatch;
      }).toList();

      expect(matchOpt.length, 1);
      expect(matchOpt.first.id, 'cad_dxf');
    });
  });
}
