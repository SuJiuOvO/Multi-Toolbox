import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';

import '../models/ssh_profile.dart';

typedef SshSocketConnector = Future<SSHSocket> Function(
  String host,
  int port, {
  Duration? timeout,
});

class SshConnectionException implements Exception {
  final String message;
  const SshConnectionException(this.message);
  @override
  String toString() => message;
}

/// One interactive PTY. Closing invalidates all pending asynchronous operations.
class SshConnectionService {
  SshConnectionService({
    SshSocketConnector? socketConnector,
    SshKnownHostsStore? knownHosts,
  })  : _socketConnector = socketConnector ?? SSHSocket.connect,
        knownHosts = knownHosts ?? SshKnownHostsStore();

  final SshSocketConnector _socketConnector;
  final SshKnownHostsStore knownHosts;
  SSHSocket? _socket;
  SSHClient? _client;
  SSHSession? _session;
  StreamSubscription<String>? _stdout;
  StreamSubscription<String>? _stderr;
  int _generation = 0;
  bool get isConnected => _session != null;

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
    disconnect();
    final generation = _generation;
    bool current() => generation == _generation;
    final validation = profile.validate();
    if (validation != null) throw SshConnectionException(validation);
    List<SSHKeyPair>? identities;
    if (profile.authMethod == SshAuthMethod.privateKey) {
      if (privateKey.trim().isEmpty) {
        throw const SshConnectionException('请导入或粘贴私钥');
      }
      try {
        identities = SSHKeyPair.fromPem(
            privateKey.trim(), passphrase.isEmpty ? null : passphrase);
        if (identities.isEmpty) throw const FormatException();
      } catch (_) {
        throw const SshConnectionException('无法读取私钥：请检查 PEM / OpenSSH 格式及私钥口令');
      }
    } else if (password.isEmpty) {
      throw const SshConnectionException('请输入 SSH 密码');
    }

    SshHostKeyChanged? changedKey;
    var rejectedKey = false;
    SSHSocket? localSocket;
    SSHClient? localClient;
    try {
      localSocket = await _socketConnector(profile.host.trim(), profile.port,
          timeout: const Duration(seconds: 15));
      if (!current()) {
        localSocket.destroy();
        throw const SshConnectionException('连接已取消');
      }
      _socket = localSocket;
      localClient = SSHClient(
        localSocket,
        username: profile.username.trim(),
        identities: identities,
        onPasswordRequest: profile.authMethod == SshAuthMethod.password
            ? () => current() ? password : null
            : null,
        // Host trust is verified before any credential is sent.
        onVerifyHostKey: (algorithm, bytes) async {
          if (!current()) return false;
          try {
            final trusted = await knownHosts.verify(
              authority: profile.authority,
              algorithm: algorithm,
              fingerprint: utf8.decode(bytes),
              confirm: confirmHostKey,
              isCurrent: current,
            );
            rejectedKey = !trusted;
            return current() && trusted;
          } on SshHostKeyChanged catch (error) {
            changedKey = error;
            return false;
          }
        },
        handshakeTimeout: const Duration(seconds: 90),
        authTimeout: const Duration(seconds: 30),
        keepAliveInterval: const Duration(seconds: 20),
      );
      _client = localClient;
      // Attach immediately: transport errors can precede authenticated.
      unawaited(localClient.done.then<void>((_) {}, onError: (_, __) {}));
      await localClient.authenticated;
      if (!current()) throw const SshConnectionException('连接已取消');
      final session = await localClient
          .shell(
            pty: SSHPtyConfig(
              type: 'xterm-256color',
              width: columns.clamp(1, 1000),
              height: rows.clamp(1, 1000),
            ),
          )
          .timeout(const Duration(seconds: 15));
      if (!current()) {
        session.close();
        throw const SshConnectionException('连接已取消');
      }
      _session = session;
      void output(String text) {
        if (current()) onOutput(text);
      }

      void closed([Object? error]) {
        if (!current()) return;
        disconnect();
        onClosed(error == null ? '远程会话已结束' : 'SSH 连接中断，请检查网络后重新连接');
      }

      _stdout = session.stdout
          .cast<List<int>>()
          .transform(const Utf8Decoder(allowMalformed: true))
          .listen(output, onError: closed);
      _stderr = session.stderr
          .cast<List<int>>()
          .transform(const Utf8Decoder(allowMalformed: true))
          .listen(output, onError: closed);
      // Wait for streams after channel closure to preserve final output.
      unawaited(session.done.then<void>((_) async {
        await Future<void>.delayed(Duration.zero);
        closed();
      }, onError: closed));
      unawaited(localClient.done.then<void>((_) => closed(), onError: closed));
    } catch (error) {
      if (current()) disconnect();
      if (localClient != null) unawaited(_closeClient(localClient));
      localSocket?.destroy();
      if (changedKey != null) throw changedKey!;
      if (rejectedKey) {
        throw const SshConnectionException('未信任服务器主机指纹，连接已取消');
      }
      if (error is SshConnectionException) rethrow;
      if (error is TimeoutException) {
        throw const SshConnectionException('SSH 连接超时，请检查地址、端口和服务器状态');
      }
      if (error is SSHAuthError) {
        throw const SshConnectionException('SSH 认证失败，请检查用户名、密码或私钥及服务器认证配置');
      }
      if (error is SocketException) {
        throw const SshConnectionException('无法连接服务器，请检查网络、主机地址和端口');
      }
      if (error is SSHHostkeyError) {
        throw const SshConnectionException('服务器主机密钥验证失败');
      }
      throw const SshConnectionException(
          '无法建立 SSH 终端，请检查服务器是否支持 SSH 和交互式 Shell');
    }
  }

  void send(String text) {
    final session = _session;
    if (session != null) session.write(Uint8List.fromList(utf8.encode(text)));
  }

  void resize(int columns, int rows,
      [int pixelWidth = 0, int pixelHeight = 0]) {
    _session?.resizeTerminal(columns.clamp(1, 1000), rows.clamp(1, 1000),
        pixelWidth.clamp(0, 100000), pixelHeight.clamp(0, 100000));
  }

  void disconnect() {
    _generation++;
    final session = _session;
    final client = _client;
    final socket = _socket;
    _session = null;
    _client = null;
    _socket = null;
    unawaited(_stdout?.cancel());
    unawaited(_stderr?.cancel());
    _stdout = null;
    _stderr = null;
    session?.close();
    if (client != null) unawaited(_closeClient(client));
    socket?.destroy();
  }

  static Future<void> _closeClient(SSHClient client) async {
    try {
      await client.close();
    } catch (_) {
      // Closing is best-effort; destroying the socket always follows.
    }
  }
}
