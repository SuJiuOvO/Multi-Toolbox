import 'dart:async';
import 'dart:convert';

import 'package:app/models/ssh_profile.dart';
import 'package:app/pages/ssh_terminal_page.dart';
import 'package:app/services/ssh_connection_service.dart';
import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xterm/xterm.dart';

class _Socket extends SSHSocket {
  bool destroyed = false;
  final incoming = StreamController<Uint8List>();
  final outgoing = StreamController<List<int>>();
  final completer = Completer<void>();
  @override
  Stream<Uint8List> get stream => incoming.stream;
  @override
  StreamSink<List<int>> get sink => outgoing.sink;
  @override
  Future<void> get done => completer.future;
  @override
  Future<void> close() async => destroy();
  @override
  void destroy() {
    if (destroyed) return;
    destroyed = true;
    incoming.close();
    outgoing.close();
    completer.complete();
  }
}

class _FakeSshService extends SshConnectionService {
  bool connected = false;
  final sent = <String>[];

  @override
  bool get isConnected => connected;

  @override
  Future<void> connect({
    required SshProfile profile,
    required String password,
    required String privateKey,
    required String passphrase,
    required Future<bool> Function(String algorithm, String fingerprint)
        confirmHostKey,
    required void Function(String text) onOutput,
    required void Function(String message) onClosed,
    int columns = 80,
    int rows = 24,
  }) async {
    connected = true;
  }

  @override
  void send(String text) {
    if (connected) sent.add(text);
  }

  @override
  void disconnect() {
    connected = false;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('profiles validate addresses and ports and persist no credentials',
      () async {
    const profile =
        SshProfile(name: '开发机', host: 'Example.COM', username: 'dev');
    expect(profile.validate(), isNull);
    expect(profile.authority, 'example.com:22');
    for (final host in [
      '',
      'ssh://server',
      'server:22/path',
      'hello world',
      'dev@host'
    ]) {
      expect(SshProfile(name: '', host: host, username: 'dev').validate(),
          isNotNull);
    }
    expect(
        const SshProfile(name: '', host: '::1', port: 65535, username: 'dev')
            .validate(),
        isNull);
    expect(
        const SshProfile(name: '', host: 'localhost', port: 0, username: 'dev')
            .validate(),
        isNotNull);
    await SshProfileStore().save([profile]);
    final preferences = await SharedPreferences.getInstance();
    final raw = preferences.getString(SshProfileStore.storageKey)!;
    expect(jsonDecode(raw).single.keys,
        unorderedEquals(['name', 'host', 'port', 'username', 'authMethod']));
    expect((await SshProfileStore().load()).single.identity, profile.identity);
  });

  test(
      'first-use trust persists, matching key skips prompt and changed key blocks',
      () async {
    final store = SshKnownHostsStore();
    var prompts = 0;
    Future<bool> confirm(String algorithm, String fingerprint) async {
      prompts++;
      return true;
    }

    Future<bool> verify(String fingerprint) => store.verify(
        authority: 'host:22',
        algorithm: 'ssh-ed25519',
        fingerprint: fingerprint,
        confirm: confirm);
    expect(await verify('SHA256:first'), isTrue);
    expect(await verify('SHA256:first'), isTrue);
    expect(prompts, 1);
    await expectLater(
        verify('SHA256:changed'), throwsA(isA<SshHostKeyChanged>()));
    expect(prompts, 1);
    await store.remove('host:22');
    expect(await store.load(), isEmpty);
  });

  test('rejected or canceled trust is never saved', () async {
    final store = SshKnownHostsStore();
    expect(
        await store.verify(
            authority: 'host:22',
            algorithm: 'rsa',
            fingerprint: 'SHA256:a',
            confirm: (_, __) async => false),
        isFalse);
    var active = true;
    expect(
        await store.verify(
            authority: 'host:22',
            algorithm: 'rsa',
            fingerprint: 'SHA256:a',
            isCurrent: () => active,
            confirm: (_, __) async {
              active = false;
              return true;
            }),
        isFalse);
    expect(await store.load(), isEmpty);
  });

  test(
      'invalid private key fails before opening network socket without echoing secrets',
      () async {
    var socketCalled = false;
    final service =
        SshConnectionService(socketConnector: (_, __, {timeout}) async {
      socketCalled = true;
      return _Socket();
    });
    await expectLater(
        service.connect(
            profile: const SshProfile(
                name: '',
                host: 'host',
                username: 'dev',
                authMethod: SshAuthMethod.privateKey),
            password: '',
            privateKey: 'PRIVATE_SECRET_VALUE',
            passphrase: 'PASSPHRASE_SECRET',
            confirmHostKey: (_, __) async => true,
            onOutput: (_) {},
            onClosed: (_) {}),
        throwsA(isA<SshConnectionException>().having(
            (error) => error.message.contains('SECRET'),
            'secret redaction',
            isFalse)));
    expect(socketCalled, isFalse);
  });

  test('canceling a pending socket connection destroys late socket', () async {
    final pendingSocket = Completer<SSHSocket>();
    final socket = _Socket();
    final service = SshConnectionService(
        socketConnector: (_, __, {timeout}) => pendingSocket.future);
    final connection = service.connect(
        profile: const SshProfile(name: '', host: 'host', username: 'dev'),
        password: 'secret',
        privateKey: '',
        passphrase: '',
        confirmHostKey: (_, __) async => true,
        onOutput: (_) {},
        onClosed: (_) {});
    final expectation =
        expectLater(connection, throwsA(isA<SshConnectionException>()));
    service.disconnect();
    pendingSocket.complete(socket);
    await expectation;
    expect(socket.destroyed, isTrue);
    expect(service.isConnected, isFalse);
  });

  testWidgets(
      'SSH editor switches to private-key authentication and validates empty host',
      (tester) async {
    tester.view.physicalSize = const Size(1280, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(const MaterialApp(home: SshTerminalPage()));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('ssh-connect')));
    await tester.pump();
    expect(find.byKey(const Key('ssh-error')), findsOneWidget);
    await tester.tap(find.text('私钥', skipOffstage: false).first);
    await tester.pumpAndSettle();
    expect(find.text('导入私钥文件'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('SSH layout remains scrollable on short mobile keyboard viewport',
      (tester) async {
    tester.view.physicalSize = const Size(360, 340);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(const MaterialApp(home: SshTerminalPage()));
    await tester.pumpAndSettle();
    expect(find.text('连接配置'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.drag(
        find.byType(SingleChildScrollView).first, const Offset(0, -250));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('SSH terminal preview is hidden until a connection is active',
      (tester) async {
    tester.view.physicalSize = const Size(1280, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(const MaterialApp(home: SshTerminalPage()));
    await tester.pumpAndSettle();

    expect(find.byType(TerminalView), findsNothing);
    expect(find.byKey(const Key('ssh-connect')), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('connected SSH terminal accepts physical keyboard input',
      (tester) async {
    tester.view.physicalSize = const Size(1280, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final service = _FakeSshService();
    await tester
        .pumpWidget(MaterialApp(home: SshTerminalPage(service: service)));
    await tester.pump();

    await tester.enterText(find.byKey(const Key('ssh-host')), 'server.example');
    await tester.tap(find.byKey(const Key('ssh-connect')));
    await tester.pump();
    await tester.pump();

    expect(find.byType(TerminalView), findsOneWidget);
    final terminal = tester.widget<TerminalView>(find.byType(TerminalView));
    expect(terminal.focusNode?.hasFocus, isTrue);

    await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyB);
    expect(service.sent.join(), contains('ab'));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
      'SSH form keeps focus when the soft keyboard changes viewport height',
      (tester) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetViewInsets);
    await tester.pumpWidget(const MaterialApp(home: SshTerminalPage()));
    await tester.pump();

    final hostFinder = find.byKey(const Key('ssh-host'));
    await tester.ensureVisible(hostFinder);
    await tester.tap(hostFinder);
    await tester.enterText(hostFinder, '192.168.1.10');
    await tester.pump();
    final editable =
        find.descendant(of: hostFinder, matching: find.byType(EditableText));
    final focusNode = tester.widget<EditableText>(editable).focusNode;
    expect(focusNode.hasFocus, isTrue);
    expect(tester.testTextInput.isVisible, isTrue);

    // This mimics the Android soft keyboard reducing the body to the short
    // layout branch that previously replaced the focused form subtree.
    tester.view.viewInsets = const FakeViewPadding(bottom: 320);
    await tester.pumpAndSettle();

    expect(focusNode.hasFocus, isTrue);
    expect(tester.testTextInput.isVisible, isTrue);
    expect(
        tester.widget<TextField>(hostFinder).controller?.text, '192.168.1.10');
    expect(find.byType(TerminalView), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
