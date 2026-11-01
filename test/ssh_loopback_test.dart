import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:app/models/ssh_profile.dart';
import 'package:app/services/ssh_connection_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

// Opt in with TOOLBOX_SSH_FIXTURE pointing to the JSON emitted by the
// disposable 127.0.0.1 fixture in tools/ssh_loopback_server.py.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final fixturePath = Platform.environment['TOOLBOX_SSH_FIXTURE'];

  test('loopback password, private keys, trust pinning and interactive PTY',
      () async {
    SharedPreferences.setMockInitialValues({});
    final fixture = jsonDecode(await File(fixturePath!).readAsString())
        as Map<String, dynamic>;
    var prompts = 0;
    Future<bool> trust(String algorithm, String fingerprint) async {
      prompts++;
      expect(fingerprint, fixture['fingerprint']);
      expect(algorithm, contains('rsa'));
      return true;
    }

    SshProfile profile(SshAuthMethod method) => SshProfile(
        name: 'Disposable loopback fixture',
        host: '127.0.0.1',
        port: fixture['port'] as int,
        username: 'toolbox-test',
        authMethod: method);

    for (final mode in ['password', 'privateKey', 'encryptedKey']) {
      final service = SshConnectionService();
      final output = StringBuffer();
      final closed = Completer<void>();
      try {
        await service.connect(
          profile: profile(mode == 'password'
              ? SshAuthMethod.password
              : SshAuthMethod.privateKey),
          password: mode == 'password' ? 'loopback-password' : '',
          privateKey: mode == 'password' ? '' : fixture[mode] as String,
          passphrase: mode == 'encryptedKey' ? 'loopback-passphrase' : '',
          confirmHostKey: trust,
          onOutput: output.write,
          onClosed: (_) {
            if (!closed.isCompleted) closed.complete();
          },
          columns: 90,
          rows: 30,
        );
        expect(service.isConnected, isTrue, reason: mode);
        await _until(() => output.toString().contains('READY:90x30'));
        service.send('hello SSH 世界\n');
        await _until(() => output.toString().contains('ECHO:hello SSH 世界'));
        service.resize(120, 42);
        await _until(() => output.toString().contains('RESIZE:120x42'));
        service.send('exit\n');
        await closed.future.timeout(const Duration(seconds: 10));
        expect(service.isConnected, isFalse);
      } finally {
        service.disconnect();
      }
    }
    expect(prompts, 1, reason: 'The pinned host is reused across auth modes');

    final rejected = SshConnectionService();
    await expectLater(
        rejected.connect(
            profile: profile(SshAuthMethod.password),
            password: 'incorrect-test-password',
            privateKey: '',
            passphrase: '',
            confirmHostKey: trust,
            onOutput: (_) {},
            onClosed: (_) {}),
        throwsA(isA<SshConnectionException>()));
    expect(rejected.isConnected, isFalse);
    rejected.disconnect();

    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(
        SshKnownHostsStore.storageKey,
        jsonEncode({
          profile(SshAuthMethod.password).authority: 'ssh-rsa SHA256:changed'
        }));
    final changed = SshConnectionService();
    await expectLater(
        changed.connect(
            profile: profile(SshAuthMethod.password),
            password: 'loopback-password',
            privateKey: '',
            passphrase: '',
            confirmHostKey: trust,
            onOutput: (_) {},
            onClosed: (_) {}),
        throwsA(isA<SshHostKeyChanged>()));
    expect(changed.isConnected, isFalse);
    expect(prompts, 1);
    changed.disconnect();
  },
      skip: fixturePath == null
          ? 'Opt-in local SSH fixture is not running'
          : false,
      timeout: const Timeout(Duration(seconds: 90)));
}

Future<void> _until(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 10));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('Timed out waiting for loopback SSH output');
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}
