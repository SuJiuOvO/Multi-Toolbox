import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:app/pages/windows_uninstaller_page.dart';
import 'package:app/services/windows_uninstaller_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

InstalledWindowsApp app({
  String name = '测试软件',
  String command = r'"C:\Program Files\Example\uninstall.exe" /S /D="C:\测试目录"',
  bool system = false,
  String hive = 'LocalMachine',
  String id = 'test',
  String displayIcon = '',
  String iconPath = '',
}) =>
    InstalledWindowsApp(
      id: id,
      name: name,
      registryHive: hive,
      registryView: 'Registry64',
      registryKey: 'Example',
      uninstallString: command,
      publisher: 'Example Team',
      displayIcon: displayIcon,
      iconPath: iconPath,
      estimatedBytes: 20 * 1024 * 1024,
      systemComponent: system,
    );

String decodeScript(List<String> arguments) {
  final bytes = base64Decode(arguments.last);
  return String.fromCharCodes([
    for (var i = 0; i < bytes.length; i += 2) bytes[i] | bytes[i + 1] << 8,
  ]);
}

class FakeUninstaller extends WindowsUninstallerService {
  FakeUninstaller() : super(supported: true);
  int uninstallCalls = 0;
  int deleteCalls = 0;
  @override
  Future<WindowsAppInventory> loadApps() async => WindowsAppInventory([
        app(),
        app(name: 'Alpha Tool', id: 'alpha', hive: 'CurrentUser'),
        app(name: 'Protected Component', id: 'system', system: true),
      ]);

  @override
  Future<Map<String, String>> loadIconPaths(
          List<InstalledWindowsApp> apps) async =>
      const {};
  @override
  Future<WindowsUninstallResult> uninstall(InstalledWindowsApp app,
      {bool elevate = false}) async {
    uninstallCalls++;
    return const WindowsUninstallResult(0);
  }

  @override
  Future<List<WindowsResidueCandidate>> scanResidue(
          InstalledWindowsApp app) async =>
      const [
        WindowsResidueCandidate(
          path: r'C:\Users\Test\AppData\Local\Alpha Tool',
          kind: '用户数据目录',
          note: '测试残留目录',
          targetType: 'directory',
          canDelete: true,
        ),
      ];

  @override
  Future<WindowsResidueActionResult> deleteResidue(
      List<WindowsResidueCandidate> candidates) async {
    deleteCalls++;
    return WindowsResidueActionResult(
      deletedPaths:
          candidates.map((candidate) => candidate.path).toList(growable: false),
    );
  }
}

class WaitingUninstaller extends FakeUninstaller {
  final result = Completer<WindowsUninstallResult>();

  @override
  Future<WindowsUninstallResult> uninstall(InstalledWindowsApp app,
      {bool elevate = false}) {
    uninstallCalls++;
    return result.future;
  }
}

void main() {
  test('quoted executable and raw Windows argument quotes remain intact', () {
    final command = UninstallCommand.fromApp(app());
    expect(command.executable, r'C:\Program Files\Example\uninstall.exe');
    expect(command.arguments, r'/S /D="C:\测试目录"');
  });

  test('unquoted absolute executable with spaces is supported', () {
    final command = UninstallCommand.fromApp(app(
        command:
            r'C:\Program Files\Example\uninstall.exe /remove /config="a b.json"'));
    expect(command.executable, r'C:\Program Files\Example\uninstall.exe');
    expect(command.arguments, '/remove /config="a b.json"');
  });

  test(
      'MSI modify operation becomes uninstall and remaining flags are preserved',
      () {
    final command = UninstallCommand.fromApp(app(
        command:
            r'MsiExec.exe /I{12345678-1234-1234-1234-123456789ABC} REBOOT=ReallySuppress'));
    expect(
        command.executable.toLowerCase(), endsWith(r'\system32\msiexec.exe'));
    expect(command.arguments,
        '/X{12345678-1234-1234-1234-123456789ABC} REBOOT=ReallySuppress');
  });

  test('protected components and ambiguous shell commands are rejected', () {
    expect(() => UninstallCommand.fromApp(app(system: true)),
        throwsFormatException);
    expect(() => UninstallCommand.fromApp(app(command: 'cmd /c anything')),
        throwsFormatException);
    expect(() => UninstallCommand.fromApp(app(command: 'uninstall.exe /S')),
        throwsFormatException);
  });

  test('MSI quoted product codes and quoted property contents are preserved',
      () {
    final command = UninstallCommand.fromApp(app(
        command:
            r'MsiExec.exe PROPERTY="literal /I text" /I"{12345678-1234-1234-1234-123456789ABC}" /L*v "C:\test log.txt"'));
    expect(command.arguments,
        r'PROPERTY="literal /I text" /X"{12345678-1234-1234-1234-123456789ABC}" /L*v "C:\test log.txt"');
  });

  test('inventory decoding handles UTF8, duplicate registry views and size',
      () async {
    String? script;
    final service = WindowsUninstallerService(
        supported: true,
        processRunner: (exe, args) async {
          expect(
              args,
              containsAllInOrder(
                  ['-WindowStyle', 'Hidden', '-EncodedCommand']));
          script = decodeScript(args);
          return ProcessResult(
              1,
              0,
              '\uFEFF${jsonEncode({
                    'apps': [
                      {
                        'id': 'first',
                        'name': '中文应用',
                        'registryHive': 'CurrentUser',
                        'registryKey': 'Example',
                        'registryView': 'Registry64',
                        'uninstallString': 'same',
                        'displayIcon': r'C:\Program Files\Example\app.exe',
                        'iconPath': r'C:\Temp\icon.png',
                        'estimatedBytes': 1048576
                      },
                      {
                        'id': 'second',
                        'name': '中文应用',
                        'registryHive': 'CurrentUser',
                        'registryKey': 'Example',
                        'registryView': 'Registry32',
                        'uninstallString': 'same',
                        'estimatedBytes': 1048576
                      },
                    ],
                    'warnings': ['部分不可读'],
                  })}',
              '');
        });
    final result = await service.loadApps();
    expect(result.apps.single.name, '中文应用');
    expect(result.apps.single.formattedSize, '1.0 MB');
    expect(result.apps.single.iconPath, r'C:\Temp\icon.png');
    expect(result.apps.single.displayIcon, r'C:\Program Files\Example\app.exe');
    expect(result.warnings, ['部分不可读']);
    expect(script, contains('OpenBaseKey'));
    expect(script, isNot(contains('Win32_Product')));
    expect(script, isNot(contains('ExtractAssociatedIcon')));
  });

  test('icon extraction is deferred to a separate background bridge', () async {
    String? script;
    final service = WindowsUninstallerService(
        supported: true,
        processRunner: (exe, args) async {
          script = decodeScript(args);
          return ProcessResult(
              1,
              0,
              jsonEncode([
                {'id': 'test', 'path': r'C:\Temp\cached.png'}
              ]),
              '');
        });
    final icons = await service.loadIconPaths([
      app(displayIcon: r'C:\Program Files\Example\app.exe'),
    ]);
    expect(icons['test'], r'C:\Temp\cached.png');
    expect(script, contains('ExtractAssociatedIcon'));
    expect(script, contains('MultiToolboxAppIcons'));
  });

  test('different HKCU versions and distinct HKLM registry views are retained',
      () async {
    Map<String, dynamic> registration(
            String id, String hive, String view, String version) =>
        {
          'id': id,
          'name': 'Same Application',
          'registryHive': hive,
          'registryKey': 'Example',
          'registryView': view,
          'uninstallString': 'same',
          'version': version,
        };
    final service = WindowsUninstallerService(
        supported: true,
        processRunner: (exe, args) async => ProcessResult(
            1,
            0,
            jsonEncode({
              'apps': [
                registration('user64', 'CurrentUser', 'Registry64', '1.0'),
                registration('user32copy', 'CurrentUser', 'Registry32', '1.0'),
                registration('user32other', 'CurrentUser', 'Registry32', '2.0'),
                registration('machine64', 'LocalMachine', 'Registry64', '1.0'),
                registration('machine32', 'LocalMachine', 'Registry32', '1.0'),
              ]
            }),
            ''));
    final result = await service.loadApps();
    expect(result.apps.map((app) => app.id),
        containsAll(['user64', 'user32other', 'machine64', 'machine32']));
    expect(result.apps, hasLength(4));
  });

  test('uninstall bridge encodes payload and invokes no shell expression',
      () async {
    String? script;
    final service = WindowsUninstallerService(
        supported: true,
        processRunner: (exe, args) async {
          script = decodeScript(args);
          return ProcessResult(1, 0, '{"exitCode":3010}', '');
        });
    final result = await service.uninstall(app(), elevate: true);
    expect(result.succeeded, isTrue);
    expect(result.restartRequired, isTrue);
    expect(script, contains("Verb = 'runas'"));
    expect(script, contains('ProcessStartInfo'));
    expect(script, isNot(contains('Invoke-Expression')));
    expect(script, isNot(contains('测试目录')));
  });

  test('residue deletion bridge only sends selected candidates', () async {
    String? script;
    final service = WindowsUninstallerService(
        supported: true,
        processRunner: (exe, args) async {
          script = decodeScript(args);
          return ProcessResult(
              1,
              0,
              jsonEncode({
                'deletedPaths': [r'C:\Users\Test\AppData\Local\Alpha Tool'],
                'errors': [],
              }),
              '');
        });
    final result = await service.deleteResidue(const [
      WindowsResidueCandidate(
        path: r'C:\Users\Test\AppData\Local\Alpha Tool',
        kind: '用户数据目录',
        note: '',
        targetType: 'directory',
        canDelete: true,
      ),
    ]);
    expect(result.succeeded, isTrue);
    expect(result.deletedPaths, hasLength(1));
    expect(script, contains('Remove-Item'));
    expect(script, contains('DeleteSubKeyTree'));
    expect(script, isNot(contains('Invoke-Expression')));
  });

  test('residue scan decodes typed targets and checks common locations',
      () async {
    String? script;
    final service = WindowsUninstallerService(
        supported: true,
        processRunner: (exe, args) async {
          script = decodeScript(args);
          return ProcessResult(
              1,
              0,
              jsonEncode([
                {
                  'path': r'HKEY_CURRENT_USER\SOFTWARE\Example\测试软件',
                  'kind': '用户设置残留',
                  'note': '测试',
                  'targetType': 'registry',
                  'registryHive': 'CurrentUser',
                  'registryView': 'Registry64',
                  'registryPath': r'SOFTWARE\Example\测试软件',
                  'canDelete': true,
                }
              ]),
              '');
        });
    final result = await service.scanResidue(app());
    expect(result.single.targetType, 'registry');
    expect(result.single.registryPath, r'SOFTWARE\Example\测试软件');
    expect(result.single.canDelete, isTrue);
    expect(script, contains('Add-PathCandidate'));
    expect(script, contains('LOCALAPPDATA'));
    expect(script, contains('Start Menu'));
  });

  test('unsupported platforms never start a process', () async {
    var called = false;
    final service = WindowsUninstallerService(
        supported: false,
        processRunner: (exe, args) async {
          called = true;
          return ProcessResult(1, 0, '{}', '');
        });
    await expectLater(service.loadApps(), throwsUnsupportedError);
    expect(called, isFalse);
  });

  test('PowerShell failures propagate without marking success', () async {
    final service = WindowsUninstallerService(
        supported: true,
        processRunner: (exe, args) async =>
            ProcessResult(1, 1, '', '用户取消 UAC'));
    await expectLater(
        service.uninstall(app()), throwsA(isA<ProcessException>()));
  });

  testWidgets(
      'search and uninstall confirmation cancellation never invoke uninstall',
      (tester) async {
    final service = FakeUninstaller();
    await tester.pumpWidget(
        MaterialApp(home: WindowsUninstallerPage(service: service)));
    await tester.pumpAndSettle();
    expect(find.text('Protected Component'), findsNothing);
    await tester.enterText(find.byType(TextField), '测试软件');
    await tester.pumpAndSettle();
    expect(find.text('Alpha Tool'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('test')));
    await tester.pump();
    await tester
        .ensureVisible(find.byKey(const ValueKey('uninstall-selected-app')));
    await tester.tap(find.byKey(const ValueKey('uninstall-selected-app')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('confirm-windows-uninstall')),
        findsOneWidget);
    expect(service.uninstallCalls, 0);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(service.uninstallCalls, 0);
  });

  testWidgets('residue scan supports selecting and deleting leftovers',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final service = FakeUninstaller();
    await tester.pumpWidget(
        MaterialApp(home: WindowsUninstallerPage(service: service)));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('test')));
    await tester.pump();
    final scanButton = find.text('扫描并清理所选软件残留');
    await tester.ensureVisible(scanButton);
    await tester.tap(scanButton);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('测试软件 · 扫描并清理残留'), findsOneWidget);
    expect(find.text('用户数据目录'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('select-all-residue')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('delete-selected-residue')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('确认永久删除这些残留？'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('confirm-delete-residue')));
    await tester.pumpAndSettle();

    expect(service.deleteCalls, 1);
    expect(find.textContaining('已清理 1 项残留'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('successful uninstall automatically opens residue scan',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final service = FakeUninstaller();
    await tester.pumpWidget(
        MaterialApp(home: WindowsUninstallerPage(service: service)));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('test')));
    await tester.pump();
    await tester
        .ensureVisible(find.byKey(const ValueKey('uninstall-selected-app')));
    await tester.tap(find.byKey(const ValueKey('uninstall-selected-app')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('confirm-windows-uninstall')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(service.uninstallCalls, 1);
    expect(find.text('测试软件 · 扫描并清理残留'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('stopping a wait releases the page and ignores late completion',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final service = WaitingUninstaller();
    await tester.pumpWidget(
        MaterialApp(home: WindowsUninstallerPage(service: service)));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('test')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('uninstall-selected-app')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('confirm-windows-uninstall')));
    await tester.pump(const Duration(milliseconds: 400));
    expect(service.uninstallCalls, 1);
    await tester.tap(find.byKey(const ValueKey('stop-waiting-uninstall')));
    await tester.pumpAndSettle();
    const stopped = '已停止等待，外部卸载程序仍会继续。完成后请刷新软件列表。';
    expect(find.text(stopped), findsOneWidget);
    service.result.complete(const WindowsUninstallResult(0));
    await tester.pumpAndSettle();
    expect(find.text(stopped), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  for (final size in [const Size(360, 640), const Size(800, 400)]) {
    testWidgets('inventory fits a narrow or short window $size',
        (tester) async {
      await tester.binding.setSurfaceSize(size);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(MaterialApp(
          home: WindowsUninstallerPage(service: FakeUninstaller())));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester
          .ensureVisible(find.byKey(const ValueKey('uninstall-selected-app')));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets('unsupported platform shows a clear message', (tester) async {
    await tester.pumpWidget(MaterialApp(
        home: WindowsUninstallerPage(
      service: WindowsUninstallerService(supported: false),
    )));
    expect(find.text('此插件仅在 Windows 上管理已安装的桌面软件。'), findsOneWidget);
  });
}
