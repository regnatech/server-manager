import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';

import 'ssh_session.dart';

/// Native (dart:io) implementation of [SshSession] backed by dartssh2.
///
/// One instance maps to one long-lived SSH connection, reused across many
/// `server --json ...` invocations.
class SshSessionImpl implements SshSession {
  SshSessionImpl({
    required this.host,
    required this.port,
    required this.username,
    this.password,
    this.privateKeyPem,
    this.passphrase,
  }) : assert(
          password != null || privateKeyPem != null,
          'Either a password or a private key must be provided.',
        );

  final String host;
  final int port;
  final String username;
  final String? password;
  final String? privateKeyPem;
  final String? passphrase;

  SSHClient? _client;
  SSHSocket? _socket;

  @override
  bool get isConnected => _client != null;

  @override
  Future<void> connect() async {
    if (_client != null) return;

    try {
      _socket = await SSHSocket.connect(host, port);
    } on Exception catch (e) {
      throw SshConnectionException('Could not reach $host:$port — $e');
    }

    try {
      _client = SSHClient(
        _socket!,
        username: username,
        onPasswordRequest: password == null ? null : () => password!,
        identities: _buildIdentities(),
      );
      // Force authentication to complete now so errors surface here.
      await _client!.authenticated;
    } on Exception catch (e) {
      await close();
      throw SshConnectionException('Authentication failed — $e');
    }
  }

  List<SSHKeyPair>? _buildIdentities() {
    final String? pem = privateKeyPem;
    if (pem == null || pem.trim().isEmpty) return null;
    try {
      return SSHKeyPair.fromPem(pem, passphrase);
    } on Exception catch (e) {
      throw SshConnectionException('Invalid private key — $e');
    }
  }

  @override
  Stream<String> run(String cmd) {
    final SSHClient client = _requireClient();
    final StreamController<String> controller = StreamController<String>();

    () async {
      try {
        final SSHSession session = await client.execute(cmd);
        const Utf8Decoder decoder = Utf8Decoder(allowMalformed: true);

        final StreamSubscription<Uint8List> outSub = session.stdout.listen(
          (Uint8List data) => controller.add(decoder.convert(data)),
        );
        final StreamSubscription<Uint8List> errSub = session.stderr.listen(
          (Uint8List data) => controller.add(decoder.convert(data)),
        );

        await session.done;
        await outSub.cancel();
        await errSub.cancel();
      } on Exception catch (e, st) {
        controller.addError(e, st);
      } finally {
        await controller.close();
      }
    }();

    return controller.stream;
  }

  @override
  Future<String> runToCompletion(String cmd) async {
    final StringBuffer out = StringBuffer();
    await for (final String chunk in run(cmd)) {
      out.write(chunk);
    }
    return out.toString();
  }

  @override
  Future<void> uploadFile(List<int> bytes, String remotePath) async {
    final SSHClient client = _requireClient();
    final SftpClient sftp = await client.sftp();
    try {
      final SftpFile file = await sftp.open(
        remotePath,
        mode: SftpFileOpenMode.create |
            SftpFileOpenMode.write |
            SftpFileOpenMode.truncate,
      );
      await file.writeBytes(Uint8List.fromList(bytes));
      await file.close();
    } finally {
      sftp.close();
    }
  }

  @override
  Future<void> close() async {
    _client?.close();
    _client = null;
    _socket?.close();
    _socket = null;
  }

  SSHClient _requireClient() {
    final SSHClient? c = _client;
    if (c == null) {
      throw SshConnectionException('Session is not connected. Call connect().');
    }
    return c;
  }
}
