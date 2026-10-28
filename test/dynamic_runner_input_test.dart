import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:app/models/plugin_manifest.dart';
import 'package:app/pages/dynamic_tool_runner_page.dart';
import 'package:path/path.dart' as p;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('DynamicToolRunnerPage Input Flattening & Directory Expansion Tests', () {
    late Directory tempDir;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('flatten_test_');
    });

    tearDown(() {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('Single files are passed through without alteration', () {
      final f1 = File(p.join(tempDir.path, 'song1.ncm'))..writeAsStringSync('dummy');
      final f2 = File(p.join(tempDir.path, 'song2.mp3'))..writeAsStringSync('dummy');

      final result = DynamicToolRunnerPage.flattenInputEntries(
        rawEntries: [f1.path, f2.path],
        allowedExtensions: ['ncm', 'mp3'],
      );

      expect(result.length, 2);
      expect(result.contains(f1.path), isTrue);
      expect(result.contains(f2.path), isTrue);
    });

    test('Directory is recursively flattened into constituent files', () {
      final subDir = Directory(p.join(tempDir.path, 'album'))..createSync();
      final f1 = File(p.join(tempDir.path, 'track0.flac'))..writeAsStringSync('audio');
      final f2 = File(p.join(subDir.path, 'track1.ncm'))..writeAsStringSync('audio');
      final f3 = File(p.join(subDir.path, 'track2.ncm'))..writeAsStringSync('audio');

      final result = DynamicToolRunnerPage.flattenInputEntries(
        rawEntries: [f1.path, subDir.path],
      );

      expect(result.length, 3);
      expect(result.contains(f1.path), isTrue);
      expect(result.contains(f2.path), isTrue);
      expect(result.contains(f3.path), isTrue);
    });

    test('Filtering with allowedExtensions only extracts matching formats', () {
      final musicDir = Directory(p.join(tempDir.path, 'music'))..createSync();
      final ncmFile = File(p.join(musicDir.path, 'song.ncm'))..writeAsStringSync('ncm');
      final qmcFile = File(p.join(musicDir.path, 'song.qmc3'))..writeAsStringSync('qmc');
      final txtFile = File(p.join(musicDir.path, 'readme.txt'))..writeAsStringSync('text');
      final imgFile = File(p.join(musicDir.path, 'cover.jpg'))..writeAsStringSync('img');

      final result = DynamicToolRunnerPage.flattenInputEntries(
        rawEntries: [musicDir.path],
        allowedExtensions: ['.ncm', 'qmc3'],
      );

      expect(result.length, 2);
      expect(result.contains(ncmFile.path), isTrue);
      expect(result.contains(qmcFile.path), isTrue);
      expect(result.contains(txtFile.path), isFalse);
      expect(result.contains(imgFile.path), isFalse);
    });

    test('Hidden and system files (.DS_Store, Thumbs.db, desktop.ini) are automatically excluded', () {
      final workDir = Directory(p.join(tempDir.path, 'work'))..createSync();
      final valid = File(p.join(workDir.path, 'sample.wav'))..writeAsStringSync('wav');
      final dsStore = File(p.join(workDir.path, '.DS_Store'))..writeAsStringSync('dummy');
      final thumbs = File(p.join(workDir.path, 'Thumbs.db'))..writeAsStringSync('dummy');
      final ini = File(p.join(workDir.path, 'desktop.ini'))..writeAsStringSync('dummy');
      final dotHidden = File(p.join(workDir.path, '.hidden_file'))..writeAsStringSync('dummy');

      final result = DynamicToolRunnerPage.flattenInputEntries(
        rawEntries: [workDir.path],
      );

      expect(result.length, 1);
      expect(result.first, valid.path);
      expect(result.contains(dsStore.path), isFalse);
      expect(result.contains(thumbs.path), isFalse);
      expect(result.contains(ini.path), isFalse);
      expect(result.contains(dotHidden.path), isFalse);
    });

    test('Archive compress mode (isArchiveCompress: true) preserves folder paths intact', () {
      final folderToPack = Directory(p.join(tempDir.path, 'folder_to_zip'))..createSync();
      File(p.join(folderToPack.path, 'file1.txt')).writeAsStringSync('hello');

      final result = DynamicToolRunnerPage.flattenInputEntries(
        rawEntries: [folderToPack.path],
        isArchiveCompress: true,
      );

      expect(result.length, 1);
      expect(result.first, folderToPack.path);
    });

    test('Empty paths and whitespace entries are safely ignored', () {
      final f = File(p.join(tempDir.path, 'test.bin'))..writeAsStringSync('data');

      final result = DynamicToolRunnerPage.flattenInputEntries(
        rawEntries: ['', '   ', f.path],
      );

      expect(result.length, 1);
      expect(result.first, f.path);
    });

    test('Mixed file and directory inputs de-duplicate repeated files via canonical path', () {
      final musicDir = Directory(p.join(tempDir.path, 'mixed_music'))..createSync();
      final track1 = File(p.join(musicDir.path, 'track1.ncm'))..writeAsStringSync('ncm1');
      final track2 = File(p.join(musicDir.path, 'track2.ncm'))..writeAsStringSync('ncm2');

      // 用户同时选中了单个 track1.ncm 以及包含 track1.ncm 和 track2.ncm 的整个目录，
      // 并可能包含 redundant relative/cased 路径
      final result = DynamicToolRunnerPage.flattenInputEntries(
        rawEntries: [
          track1.path,
          musicDir.path,
          p.join(musicDir.path, '.', 'track1.ncm'),
        ],
        allowedExtensions: ['ncm'],
      );

      // 应严格去重，仅包含 2 个唯一文件
      expect(result.length, 2);
      expect(result.contains(track1.path), isTrue);
      expect(result.contains(track2.path), isTrue);
    });

    test('PluginInputCondition parses or/and/in conditions correctly', () {
      final json = {
        'field': 'format',
        'in': ['mp3', 'wav'],
        'or': [
          {'field': 'bitrate', 'equals': 320},
          {'field': 'quality', 'equals': 'high'}
        ],
        'and': [
          {'field': 'stereo', 'equals': true}
        ]
      };

      final cond = PluginInputCondition.fromJson(json);
      expect(cond.field, 'format');
      expect(cond.inValues, ['mp3', 'wav']);
      expect(cond.or?.length, 2);
      expect(cond.or?[0].field, 'bitrate');
      expect(cond.or?[0].equals, 320);
      expect(cond.and?.length, 1);
      expect(cond.and?[0].field, 'stereo');
      expect(cond.and?[0].equals, true);
    });

    testWidgets('Multi-Output Streaming layout renders distinct sequential cards mapped by id', (tester) async {
      tester.view.physicalSize = const Size(1200, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final plugin = PluginManifest(
        id: 'test-multi-output-plugin',
        name: 'Multi Output Demo Tool',
        version: '1.0.0',
        category: 'text',
        description: 'Demonstrating sequential compound outputs',
        icon: 'text_snippet',
        author: 'Toolbox Team',
        engineType: 'quickjs',
        executionType: 'quickjs',
        platforms: ['universal'],
        inputs: [],
        outputs: [
          PluginOutputDef(
            id: 'summary',
            type: 'copyable_text',
            label: '摘要概览信息',
            description: '任务简要描述',
          ),
          PluginOutputDef(
            id: 'metrics',
            type: 'key_value_table',
            label: '性能指标参数',
            description: '耗时与吞吐量表格',
          ),
          PluginOutputDef(
            id: 'raw_json',
            type: 'json_tree',
            label: '原始 JSON 详情',
          ),
        ],
        action: PluginActionDef(
          handler: 'quickjs_eval',
          params: {
            'script': """
              async function run() {
                return {
                  success: true,
                  message: '全流程执行完毕',
                  data: {
                    summary: 'All nodes processed in 42ms with 0 failures',
                    metrics: {
                      'duration_ms': 42,
                      'throughput_rps': 9900,
                      'status': 'HEALTHY'
                    },
                    raw_json: {
                      'node_id': 'cluster-alpha-01',
                      'active': true
                    }
                  }
                };
              }
            """
          },
        ),
      );

      await tester.pumpWidget(
        MaterialApp(
          home: DynamicToolRunnerPage(plugin: plugin),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Multi Output Demo Tool'), findsOneWidget);
      expect(find.text('开始执行处理'), findsOneWidget);

      // 点击“开始执行处理”
      await tester.tap(find.text('开始执行处理'));
      await tester.pump();

      // 在真实异步区域中等待 QuickJS 原生执行完毕
      await tester.runAsync(() async {
        for (int i = 0; i < 20; i++) {
          await Future.delayed(const Duration(milliseconds: 100));
        }
      });
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      // 验证三大独立复合输出卡片按顺序流式排布呈现
      expect(find.text('摘要概览信息'), findsOneWidget);
      expect(find.text('All nodes processed in 42ms with 0 failures'), findsOneWidget);

      expect(find.text('性能指标参数'), findsOneWidget);
      expect(find.text('duration_ms'), findsOneWidget);
      expect(find.text('42'), findsOneWidget);
      expect(find.text('throughput_rps'), findsOneWidget);

      expect(find.text('原始 JSON 详情'), findsOneWidget);
      expect(find.textContaining('cluster-alpha-01'), findsWidgets);

      // 验证一键复制按钮均正常渲染
      expect(find.text('一键复制'), findsNWidgets(3));
      expect(find.byIcon(Icons.copy), findsNWidgets(3));
    });
  });
}
