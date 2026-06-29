import 'ssh_session.dart';

/// Web fallback implementation of [SshSession].
///
/// The web build never references `dart:io` or dartssh2. Live SSH is not
/// supported in the browser, so any attempt to use this throws; the web target
/// is intended for demo mode (canned data) only. See `services/demo_data.dart`.
class SshSessionImpl implements SshSession {
  SshSessionImpl({
    required String host,
    required int port,
    required String username,
    String? password,
    String? privateKeyPem,
    String? passphrase,
  });

  Never _unsupported() => throw SshConnectionException(
        'Live SSH is not available on the web build. Use the desktop app, or '
        'explore demo mode.',
      );

  @override
  bool get isConnected => false;

  @override
  Future<void> connect() async => _unsupported();

  @override
  Stream<String> run(String cmd) => _unsupported();

  @override
  Future<String> runToCompletion(String cmd) async => _unsupported();

  @override
  Future<void> uploadFile(List<int> bytes, String remotePath) async =>
      _unsupported();

  @override
  Future<void> close() async {}
}
