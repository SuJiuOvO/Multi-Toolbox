import 'dart:convert';
import 'dart:io';

import 'package:shared_preferences/shared_preferences.dart';

enum SshAuthMethod { password, privateKey }

/// Connection metadata only. Credentials never belong in this object or JSON.
class SshProfile {
  final String name;
  final String host;
  final int port;
  final String username;
  final SshAuthMethod authMethod;

  const SshProfile({
    required this.name,
    required this.host,
    this.port = 22,
    required this.username,
    this.authMethod = SshAuthMethod.password,
  });

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
      };

  factory SshProfile.fromJson(Map<String, dynamic> json) => SshProfile(
        name: json['name'] is String ? json['name'] as String : '',
        host: json['host'] is String ? json['host'] as String : '',
        port: json['port'] is int ? json['port'] as int : 22,
        username: json['username'] is String ? json['username'] as String : '',
        authMethod: json['authMethod'] == 'privateKey'
            ? SshAuthMethod.privateKey
            : SshAuthMethod.password,
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
