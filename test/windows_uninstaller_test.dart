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
}) =>
    InstalledWindowsApp(
      id: id,
      name: name,
      registryHive: hive,
      registryView: 'Registry64',
      registryKey: 'Example',
      uninstallString: command,
      publisher: 'Example Team',
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
  @override
  Future<WindowsAppInventory> loadApps() async => WindowsAppInventory([
        app(),
        app(name: 'Alpha Tool', id: 'alpha', hive: 'CurrentUser'),
        app(name: 'Protected Component', id: 'system', system: true),
      ]);
  @override
  Future<WindowsUninstallResult> uninstall(InstalledWindowsApp app,
      {bool elevate = false}) async {
    uninstallCalls++;
    return const WindowsUninstallResult(0);
  }

  @override
  Future<List<WindowsResidueCandidate>> scanResidue(
          InstalledWindowsApp app) async =>
      [];
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
    expect(result.warnings, ['部分不可读']);
    expect(script, contains('OpenBaseKey'));
    expect(script, isNot(contains('Win32_Product')));
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
