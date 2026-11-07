import 'package:app/models/ssh_profile.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('SshCredentialCrypto encrypt and decrypt roundtrip', () {
    const rawSecret = 'MySecureP@ssw0rd!#2026';
    final encrypted = SshCredentialCrypto.encrypt(rawSecret);
    expect(encrypted.startsWith('v1:'), isTrue);
    expect(encrypted.contains(rawSecret), isFalse);

    final decrypted = SshCredentialCrypto.decrypt(encrypted);
    expect(decrypted, equals(rawSecret));
  });

  test('SshProfile with encrypted credentials serialization', () {
    final profile = SshProfile.withCredentials(
      name: 'Aliyun Prod',
      host: '47.253.208.133',
      port: 22222,
      username: 'root',
      authMethod: SshAuthMethod.password,
      password: 'RemotePassword123',
      rememberCredentials: true,
    );

    expect(profile.rememberCredentials, isTrue);
    expect(profile.encryptedPassword, isNotNull);
    expect(profile.encryptedPassword!.contains('RemotePassword123'), isFalse);
    expect(profile.password, equals('RemotePassword123'));

    final json = profile.toJson();
    expect(json['encryptedPassword'], isNotNull);
    expect(json.toString().contains('RemotePassword123'), isFalse);

    final restored = SshProfile.fromJson(json);
    expect(restored.name, equals('Aliyun Prod'));
    expect(restored.host, equals('47.253.208.133'));
    expect(restored.port, equals(22222));
    expect(restored.username, equals('root'));
    expect(restored.rememberCredentials, isTrue);
    expect(restored.password, equals('RemotePassword123'));
  });
}
