import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:pointycastle/export.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum SshAuthMethod { password, privateKey }

/// AES-256-CBC with PKCS7 padding and HMAC-SHA256 authentication for local vault storage.
class SshCredentialCrypto {
  static const _masterSeed = 'MultiToolbox_SSH_Vault_Secure_Key_2026_V1';

  static Uint8List _deriveKey() {
    return Uint8List.fromList(sha256.convert(utf8.encode(_masterSeed)).bytes);
  }

  static String encrypt(String plainText) {
    if (plainText.isEmpty) return '';
    try {
      final key = _deriveKey();
      final rnd = Random.secure();
      final iv = Uint8List.fromList(List<int>.generate(16, (_) => rnd.nextInt(256)));
      final plainBytes = Uint8List.fromList(utf8.encode(plainText));

      final cipher = PaddedBlockCipherImpl(
        PKCS7Padding(),
        CBCBlockCipher(AESEngine()),
      )..init(
          true,
          PaddedBlockCipherParameters<CipherParameters, CipherParameters>(
            ParametersWithIV<KeyParameter>(KeyParameter(key), iv),
            null,
          ),
        );
      final cipherBytes = cipher.process(plainBytes);

      // Compute HMAC-SHA256 for integrity and authenticity
      final hmac = Hmac(sha256, key);
      final hmacDigest = hmac.convert([...iv, ...cipherBytes]).bytes;

      return 'v1:${base64Encode(iv)}:${base64Encode(hmacDigest)}:${base64Encode(cipherBytes)}';
    } catch (_) {
      return '';
    }
  }

  static String decrypt(String encryptedText) {
    if (encryptedText.isEmpty || !encryptedText.startsWith('v1:')) return '';
    try {
      final parts = encryptedText.split(':');
      if (parts.length != 4) return '';
      final iv = base64Decode(parts[1]);
      final hmacExpected = base64Decode(parts[2]);
      final cipherBytes = base64Decode(parts[3]);
      final key = _deriveKey();

      // Verify HMAC first
      final hmac = Hmac(sha256, key);
      final computedDigest = hmac.convert([...iv, ...cipherBytes]).bytes;
      if (computedDigest.length != hmacExpected.length) return '';
      for (int i = 0; i < computedDigest.length; i++) {
        if (computedDigest[i] != hmacExpected[i]) return '';
      }

      final cipher = PaddedBlockCipherImpl(
        PKCS7Padding(),
        CBCBlockCipher(AESEngine()),
      )..init(
          false,
          PaddedBlockCipherParameters<CipherParameters, CipherParameters>(
            ParametersWithIV<KeyParameter>(KeyParameter(key), Uint8List.fromList(iv)),
            null,
          ),
        );
      final decrypted = cipher.process(Uint8List.fromList(cipherBytes));
      return utf8.decode(decrypted);
    } catch (_) {
      return '';
    }
  }
}

/// Connection metadata and locally encrypted credentials.
class SshProfile {
  final String name;
  final String host;
  final int port;
  final String username;
  final SshAuthMethod authMethod;
  final String? encryptedPassword;
  final String? encryptedPrivateKey;
  final String? encryptedPassphrase;
  final bool rememberCredentials;

  const SshProfile({
    required this.name,
    required this.host,
    this.port = 22,
    required this.username,
    this.authMethod = SshAuthMethod.password,
    this.encryptedPassword,
    this.encryptedPrivateKey,
    this.encryptedPassphrase,
    this.rememberCredentials = false,
  });

  String get password =>
      encryptedPassword != null ? SshCredentialCrypto.decrypt(encryptedPassword!) : '';
  String get privateKey =>
      encryptedPrivateKey != null ? SshCredentialCrypto.decrypt(encryptedPrivateKey!) : '';
  String get passphrase =>
      encryptedPassphrase != null ? SshCredentialCrypto.decrypt(encryptedPassphrase!) : '';

  static SshProfile withCredentials({
    required String name,
    required String host,
    int port = 22,
    required String username,
    SshAuthMethod authMethod = SshAuthMethod.password,
    String? password,
    String? privateKey,
    String? passphrase,
    bool rememberCredentials = true,
  }) {
    return SshProfile(
      name: name,
      host: host,
      port: port,
      username: username,
      authMethod: authMethod,
      encryptedPassword: (rememberCredentials && password != null && password.isNotEmpty)
          ? SshCredentialCrypto.encrypt(password)
          : null,
      encryptedPrivateKey: (rememberCredentials && privateKey != null && privateKey.isNotEmpty)
          ? SshCredentialCrypto.encrypt(privateKey)
          : null,
      encryptedPassphrase: (rememberCredentials && passphrase != null && passphrase.isNotEmpty)
          ? SshCredentialCrypto.encrypt(passphrase)
          : null,
      rememberCredentials: rememberCredentials,
    );
  }

  String get authority => '${host.trim().toLowerCase()}:$port';
  String get identity => '$username@$authority';

  String? validate() {
    final address = host.trim();
    if (address.isEmpty ||
        address.length > 253 ||
        RegExp(r'[\s/\\@\x00-\x1f]').hasMatch(address) ||
        address.contains('://') ||
        (address.contains(':') &&
            InternetAddress.tryParse(address)?.type !=
                InternetAddressType.IPv6)) {
      return '请输入主机名或 IP 地址，不含协议、端口和空格';
    }
    if (port < 1 || port > 65535) return '端口必须在 1–65535 之间';
    if (username.trim().isEmpty ||
        RegExp(r'[\x00-\x1f\r\n]').hasMatch(username)) {
      return '请输入有效的 SSH 用户名';
    }
    return null;
  }

  Map<String, dynamic> toJson() => {
        'name': name,
        'host': host.trim(),
        'port': port,
        'username': username.trim(),
        'authMethod': authMethod.name,
        if (encryptedPassword != null) 'encryptedPassword': encryptedPassword,
        if (encryptedPrivateKey != null) 'encryptedPrivateKey': encryptedPrivateKey,
        if (encryptedPassphrase != null) 'encryptedPassphrase': encryptedPassphrase,
        if (rememberCredentials) 'rememberCredentials': true,
      };

  factory SshProfile.fromJson(Map<String, dynamic> json) => SshProfile(
        name: json['name'] is String ? json['name'] as String : '',
        host: json['host'] is String ? json['host'] as String : '',
        port: json['port'] is int ? json['port'] as int : 22,
        username: json['username'] is String ? json['username'] as String : '',
        authMethod: json['authMethod'] == 'privateKey'
            ? SshAuthMethod.privateKey
            : SshAuthMethod.password,
        encryptedPassword: json['encryptedPassword'] as String?,
        encryptedPrivateKey: json['encryptedPrivateKey'] as String?,
        encryptedPassphrase: json['encryptedPassphrase'] as String?,
        rememberCredentials: json['rememberCredentials'] as bool? ?? false,
      );
}

class SshProfileStore {
  static const storageKey = 'ssh_terminal.profiles.v1';

  Future<List<SshProfile>> load() async {
    final preferences = await SharedPreferences.getInstance();
    try {
      final entries = jsonDecode(preferences.getString(storageKey) ?? '[]');
      if (entries is! List) return [];
      return entries
          .whereType<Map>()
          .map((entry) => SshProfile.fromJson(Map<String, dynamic>.from(entry)))
          .where((profile) => profile.validate() == null)
          .toList();
    } on FormatException {
      return [];
    }
  }

  Future<void> save(List<SshProfile> profiles) async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(
      storageKey,
      jsonEncode(profiles.map((profile) => profile.toJson()).toList()),
    );
  }
}

class SshHostKeyChanged implements Exception {
  const SshHostKeyChanged();

  @override
  String toString() => '服务器主机密钥已改变，连接已阻止。请先向管理员核实新指纹。';
}

/// Trust is pinned by host and port, independent of username/authentication.
class SshKnownHostsStore {
  static const storageKey = 'ssh_terminal.known_hosts.v1';

  Future<Map<String, String>> load() async {
    final preferences = await SharedPreferences.getInstance();
    try {
      final value = jsonDecode(preferences.getString(storageKey) ?? '{}');
      if (value is! Map) return {};
      return value.map((key, value) => MapEntry('$key', '$value'));
    } on FormatException {
      return {};
    }
  }

  Future<bool> verify({
    required String authority,
    required String algorithm,
    required String fingerprint,
    required Future<bool> Function(String algorithm, String fingerprint)
        confirm,
    bool Function()? isCurrent,
  }) async {
    final hosts = await load();
    if (isCurrent != null && !isCurrent()) return false;
    final stored = hosts[authority];
    final candidate = '$algorithm $fingerprint';
    if (stored != null) {
      if (stored != candidate) throw const SshHostKeyChanged();
      return true;
    }
    if (!await confirm(algorithm, fingerprint)) return false;
    if (isCurrent != null && !isCurrent()) return false;
    // Read again because another view may have trusted this host meanwhile.
    final current = await load();
    if (isCurrent != null && !isCurrent()) return false;
    if (current[authority] != null && current[authority] != candidate) {
      throw const SshHostKeyChanged();
    }
    current[authority] = candidate;
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(storageKey, jsonEncode(current));
    return true;
  }

  Future<void> remove(String authority) async {
    final hosts = await load();
    hosts.remove(authority);
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(storageKey, jsonEncode(hosts));
  }
}
