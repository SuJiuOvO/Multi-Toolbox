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

    test('file selector capabilities support files, folders and both', () {
      final filesOnly = PluginInputDef.fromJson({
        'id': 'files',
        'label': 'Files',
        'type': 'file_picker',
        'allowFiles': true,
        'allowFolder': false,
      });
      final foldersOnly = PluginInputDef.fromJson({
        'id': 'folders',
        'label': 'Folders',
        'type': 'file_picker',
        'allowFiles': false,
        'allowFolder': true,
      });
      final both = PluginInputDef.fromJson({
        'id': 'both',
        'label': 'Both',
        'type': 'file_picker',
        'allowFiles': true,
        'allowFolder': true,
      });
      final folderPicker = PluginInputDef.fromJson({
        'id': 'folder',
        'label': 'Folder',
        'type': 'folder_picker',
      });

      expect(filesOnly.acceptsFiles, isTrue);
      expect(filesOnly.acceptsFolders, isFalse);
      expect(foldersOnly.acceptsFiles, isFalse);
      expect(foldersOnly.acceptsFolders, isTrue);
      expect(both.acceptsFiles, isTrue);
      expect(both.acceptsFolders, isTrue);
      expect(folderPicker.acceptsFiles, isFalse);
      expect(folderPicker.acceptsFolders, isTrue);
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

    test('DynamicToolRunnerPage.parseHexColor parses hex, 3-char, 8-char, and transparent correctly', () {
      expect(DynamicToolRunnerPage.parseHexColor('#FFFFFF'), const Color(0xFFFFFFFF));
      expect(DynamicToolRunnerPage.parseHexColor('#000000'), const Color(0xFF000000));
      expect(DynamicToolRunnerPage.parseHexColor('#FF0000'), const Color(0xFFFF0000));
      expect(DynamicToolRunnerPage.parseHexColor('#F00'), const Color(0xFFFF0000));
      expect(DynamicToolRunnerPage.parseHexColor('#80FF0000'), const Color(0x80FF0000));
      expect(DynamicToolRunnerPage.parseHexColor('transparent'), Colors.transparent);
      expect(DynamicToolRunnerPage.parseHexColor('none'), Colors.transparent);
      expect(DynamicToolRunnerPage.parseHexColor('invalid'), Colors.white);
    });

    testWidgets('color_picker UI renders swatches, badge, and custom picker button', (tester) async {
      tester.view.physicalSize = const Size(1200, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final colorPlugin = PluginManifest(
        id: 'test-color-plugin',
        name: 'Color Picker Demo Tool',
        version: '1.0.0',
        category: 'image',
        description: 'Demonstrating color_picker input component',
        icon: 'palette',
        author: 'Toolbox Team',
        isOfficial: true,
        engineType: 'quickjs',
        executionType: 'quickjs',
        platforms: ['universal'],
        inputs: [
          PluginInputDef(
            id: 'bgColor',
            type: 'color_picker',
            label: '背景填充颜色',
            defaultValue: '#FFFFFF',
          ),
        ],
        outputs: [],
        action: PluginActionDef(
          handler: 'quickjs_eval',
          params: {
            'script': "async function run(ctx) { return { success: true, text: ctx.inputs.bgColor }; }"
          },
        ),
      );

      await tester.pumpWidget(
        MaterialApp(
          home: DynamicToolRunnerPage(plugin: colorPlugin),
        ),
      );
      await tester.pumpAndSettle();

      // 验证官方认证徽章正确显示
      expect(find.text('官方认证'), findsOneWidget);
      expect(find.byIcon(Icons.verified_user_rounded), findsOneWidget);

      // 验证 color_picker 标题与默认值
      expect(find.text('背景填充颜色'), findsOneWidget);
      expect(find.text('#FFFFFF'), findsOneWidget);
      expect(find.text('自定义'), findsOneWidget);

      // 验证预设调色板中的图标
      expect(find.byIcon(Icons.colorize), findsOneWidget);
      expect(find.byIcon(Icons.check), findsOneWidget); // 选中的颜色带对勾

      // 点击切换为预设红色 #EF4444
      final redSwatchFinder = find.byTooltip('#EF4444');
      expect(redSwatchFinder, findsOneWidget);
      await tester.tap(redSwatchFinder);
      await tester.pumpAndSettle();

      // 状态栏应更新显示为 #EF4444
      expect(find.text('#EF4444'), findsOneWidget);

      // 点击执行，验证 QuickJS 接收到了选择的 Hex 颜色
      await tester.tap(find.text('开始执行处理'));
      await tester.pump();

      await tester.runAsync(() async {
        for (int i = 0; i < 15; i++) {
          await Future.delayed(const Duration(milliseconds: 100));
        }
      });
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.textContaining('#EF4444'), findsWidgets);
    });

    testWidgets('file picker supports file-only, folder-only and combined controls', (tester) async {
      tester.view.physicalSize = const Size(1000, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      PluginManifest pickerPlugin({
        String type = 'file_picker',
        bool allowFiles = true,
        bool allowFolder = false,
        bool allowMultiple = true,
      }) => PluginManifest(
        id: 'picker-mode-test',
        name: 'Picker Mode Test',
        version: '1.1.2',
        category: 'other',
        description: 'Selection mode test',
        icon: 'folder',
        author: 'Toolbox Team',
        isOfficial: true,
        engineType: 'quickjs',
        executionType: 'quickjs',
        platforms: const ['universal'],
        inputs: [
          PluginInputDef(
            id: 'inputPath',
            type: type,
            label: '选择输入',
            allowMultiple: allowMultiple,
            allowFiles: allowFiles,
            allowFolder: allowFolder,
            pickButtonText: allowFiles && type != 'folder_picker' ? '选择文件' : '选择文件夹入口',
          ),
        ],
        outputs: const [],
        action: PluginActionDef(
          handler: 'quickjs_eval',
          params: {'script': 'async function run() { return { success: true }; }'},
        ),
      );

      await tester.pumpWidget(MaterialApp(home: DynamicToolRunnerPage(plugin: pickerPlugin())));
      await tester.pumpAndSettle();
      expect(find.text('选择文件'), findsOneWidget);
      expect(find.text('添加文件夹'), findsNothing);

      await tester.pumpWidget(MaterialApp(
        home: DynamicToolRunnerPage(
          plugin: pickerPlugin(allowFiles: false, allowFolder: true, allowMultiple: false),
        ),
      ));
      await tester.pumpAndSettle();
      expect(find.text('选择文件夹入口'), findsOneWidget);
      expect(find.text('添加文件 (多选)'), findsNothing);
      expect(find.text('添加文件夹'), findsNothing);

      await tester.pumpWidget(MaterialApp(
        home: DynamicToolRunnerPage(
          plugin: pickerPlugin(allowFiles: true, allowFolder: true),
        ),
      ));
      await tester.pumpAndSettle();
      expect(find.text('选择文件'), findsOneWidget);
      expect(find.text('添加文件夹'), findsOneWidget);

      await tester.pumpWidget(MaterialApp(
        home: DynamicToolRunnerPage(
          plugin: pickerPlugin(type: 'folder_picker', allowFiles: true, allowFolder: false),
        ),
      ));
      await tester.pumpAndSettle();
      expect(find.text('选择文件夹入口'), findsOneWidget);
      expect(find.text('添加文件 (多选)'), findsNothing);
    });

    testWidgets('Community plugin shows community badge in AppBar', (tester) async {
      final communityPlugin = PluginManifest(
        id: 'test-community-plugin',
        name: 'Community Tool',
        version: '1.0.0',
        category: 'other',
        description: 'Community plugin description',
        icon: 'extension',
        author: 'Community Contributor',
        isOfficial: false,
        engineType: 'quickjs',
        executionType: 'quickjs',
        platforms: ['universal'],
        inputs: [],
        outputs: [],
        action: PluginActionDef(
          handler: 'quickjs_eval',
          params: {'script': "async function run() { return { success: true }; }"},
        ),
      );

      await tester.pumpWidget(
        MaterialApp(
          home: DynamicToolRunnerPage(plugin: communityPlugin),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('社区插件'), findsOneWidget);
      expect(find.text('官方认证'), findsNothing);
    });

    testWidgets('ImageCompareSliderWidget renders before/after images and handles drag events', (tester) async {
      final tempDir = Directory.systemTemp.createTempSync('compare_test_');
      final f1 = File(p.join(tempDir.path, 'before.png'))..writeAsBytesSync([137, 80, 78, 71, 13, 10, 26, 10]);
      final f2 = File(p.join(tempDir.path, 'after.png'))..writeAsBytesSync([137, 80, 78, 71, 13, 10, 26, 10]);

      try {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: ImageCompareSliderWidget(
                beforeImagePath: f1.path,
                afterImagePath: f2.path,
                beforeLabel: '测试前',
                afterLabel: '测试后',
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.text('测试前'), findsOneWidget);
        expect(find.text('测试后'), findsOneWidget);
        expect(find.byIcon(Icons.compare_arrows), findsOneWidget);

        // 模拟横向拖动滑块
        await tester.drag(find.byIcon(Icons.compare_arrows), const Offset(50, 0));
        await tester.pumpAndSettle();

        final clipper = HorizontalRectClipper(0.7);
        final rect = clipper.getClip(const Size(100, 100));
        expect(rect.width, 70);
        expect(clipper.shouldReclip(HorizontalRectClipper(0.5)), isTrue);
        expect(clipper.shouldReclip(HorizontalRectClipper(0.7)), isFalse);
      } finally {
        if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
      }
    });

    testWidgets('DynamicToolRunnerPage renders generic PluginBannerDef at top-level and input-level', (tester) async {
      final bannerPlugin = PluginManifest(
        id: 'banner-test-tool',
        name: 'Banner Test Tool',
        version: '1.0.0',
        category: 'other',
        description: 'Testing generic banners',
        icon: 'extension',
        author: 'Tester',
        engineType: 'custom',
        executionType: 'internal',
        platforms: ['universal'],
        banners: [
          PluginBannerDef(
            message: '全局顶级测试横幅提示消息',
            type: 'info',
            icon: 'desktop_windows',
          ),
        ],
        inputs: [
          PluginInputDef(
            id: 'testInput',
            label: '测试输入组件',
            type: 'file_picker',
            banners: [
              PluginBannerDef(
                message: '组件级别专属黄色告警横幅',
                type: 'warning',
              ),
            ],
          ),
        ],
      );

      await tester.pumpWidget(
        MaterialApp(
          home: DynamicToolRunnerPage(plugin: bannerPlugin),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('全局顶级测试横幅提示消息'), findsOneWidget);
      expect(find.text('组件级别专属黄色告警横幅'), findsOneWidget);
    });

    test('formatBytes correctly formats byte sizes', () {
      expect(DynamicToolRunnerPage.formatBytes(0), '0 B');
      expect(DynamicToolRunnerPage.formatBytes(512), '512 B');
      expect(DynamicToolRunnerPage.formatBytes(1024), '1.0 KB');
      expect(DynamicToolRunnerPage.formatBytes(1536), '1.5 KB');
      expect(DynamicToolRunnerPage.formatBytes(1024 * 1024 * 2), '2.0 MB');
      expect(DynamicToolRunnerPage.formatBytes(1024 * 1024 * 1024 * 3), '3.00 GB');
    });

    test('PluginInputDef isColorInput correctly identifies explicit and semantic color fields', () {
      // 显式声明为 color_picker
      final explicit = PluginInputDef(id: 'col', label: 'Color', type: 'color_picker');
      expect(explicit.isColorInput, isTrue);

      // 声明为 text，但 id 为 bgColor
      final petpetColor = PluginInputDef(id: 'bgColor', label: '背景颜色', type: 'text', defaultValue: '#FFFFFF');
      expect(petpetColor.isColorInput, isTrue);

      // 声明为 text，但 label 包含底色
      final bgLabel = PluginInputDef(id: 'custom_bg', label: '生成底色', type: 'text');
      expect(bgLabel.isColorInput, isTrue);

      // 声明为 text，但 defaultValue 为 Hex 色值
      final hexDefault = PluginInputDef(id: 'accent', label: '强调色', type: 'text', defaultValue: '#1E40AF');
      expect(hexDefault.isColorInput, isTrue);

      // 普通文本输入框
      final plainText = PluginInputDef(id: 'username', label: '用户名称', type: 'text', defaultValue: 'admin');
      expect(plainText.isColorInput, isFalse);
    });

    testWidgets('Legacy text input with bgColor automatically upgrades to visual color picker UI', (WidgetTester tester) async {
      tester.view.physicalSize = const Size(1200, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);

      final legacyColorPlugin = PluginManifest(
        id: 'legacy-color-tool',
        name: '旧版颜色工具',
        version: '1.0.0',
        minAppVersion: '1.0.0',
        category: 'utility',
        description: '测试向下兼容旧版 text 格式的颜色字段',
        icon: 'palette',
        author: 'Tester',
        engineType: 'native_tool',
        inputs: [
          PluginInputDef(
            id: 'bgColor',
            label: '背景底色 (原 text 类型)',
            type: 'text',
            defaultValue: '#FFFFFF',
          ),
        ],
      );

      await tester.pumpWidget(
        MaterialApp(
          home: DynamicToolRunnerPage(plugin: legacyColorPlugin),
        ),
      );
      await tester.pumpAndSettle();

      // 应该自动渲染出颜色选择组件的“自定义”按钮与色块
      expect(find.text('背景底色 (原 text 类型)'), findsWidgets);
      expect(find.text('自定义'), findsOneWidget);
      expect(find.text('#FFFFFF'), findsWidgets);
    });

    testWidgets('DynamicToolRunnerPage renders Dev Drawer with form values snapshot and VFS table', (tester) async {
      final testPlugin = PluginManifest(
        id: 'test-dev-drawer-tool',
        name: 'Dev Drawer Test Tool',
        version: '1.2.3',
        minAppVersion: '1.0.0',
        category: 'utility',
        description: 'Test Dev Drawer functionality',
        icon: 'build',
        author: 'Tester',
        engineType: 'quickjs',
        executionType: 'quickjs',
        isDevLink: true,
        inputs: [
          PluginInputDef(
            id: 'mode',
            label: '处理模式',
            type: 'text',
            defaultValue: 'fast',
          ),
        ],
      );

      await tester.pumpWidget(
        MaterialApp(
          home: DynamicToolRunnerPage(plugin: testPlugin),
        ),
      );
      await tester.pumpAndSettle();

      final devIconFinder = find.byIcon(Icons.bug_report_outlined);
      expect(devIconFinder, findsOneWidget);
      await tester.tap(devIconFinder);
      await tester.pumpAndSettle();

      expect(find.text('开发者调试抽屉 (Dev Drawer)'), findsOneWidget);
      expect(find.text('实时表单参数快照 (Form Values)'), findsOneWidget);
      expect(find.text('VFS 虚拟目录映射表 (WASI / POSIX)'), findsOneWidget);
      expect(find.text('宿主注入环境变量 (Toolbox.env)'), findsOneWidget);
      expect(find.text('🔗 Dev Link 本地软链'), findsOneWidget);
    });
  });
}
