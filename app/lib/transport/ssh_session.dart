import '../models/connection_profile.dart';
import 'ssh_session_stub.dart'
    if (dart.library.io) 'ssh_session_io.dart' as impl;

/// Thrown when an SSH connection or auth attempt fails.
class SshConnectionException implements Exception {
  SshConnectionException(this.message);
  final String message;
  @override
  String toString() => 'SshConnectionException: $message';
}

/// Abstract SSH session contract.
///
/// The concrete implementation is chosen by conditional import: the native
/// build uses `ssh_session_io.dart` (dartssh2, which depends on `dart:io`);
/// the web build uses `ssh_session_stub.dart`, which throws if a live session
/// is ever attempted. Demo mode never constructs a session, so the web build
/// compiles and runs without dartssh2.
abstract class SshSession {
  /// Constructs the platform-appropriate session.
  factory SshSession({
    required String host,
    required int port,
    required String username,
    String? password,
    String? privateKeyPem,
    String? passphrase,
  }) = impl.SshSessionImpl;

  /// Builds a session from a [ConnectionProfile] plus in-memory secrets.
  factory SshSession.fromProfile(
    ConnectionProfile profile, {
    String? password,
    String? privateKeyPem,
    String? passphrase,
  }) {
    return SshSession(
      host: profile.host,
      port: profile.port,
      username: profile.username,
      password: password,
      privateKeyPem: privateKeyPem,
      passphrase: passphrase,
    );
  }

  bool get isConnected;

  /// Opens the socket, performs the handshake and authenticates.
  Future<void> connect();

  /// Runs [cmd] and yields decoded stdout/stderr as string chunks.
  Stream<String> run(String cmd);

  /// Runs [cmd] to completion and returns the full output as one string.
  Future<String> runToCompletion(String cmd);

  /// Uploads [bytes] to [remotePath] over SFTP, overwriting if present.
  Future<void> uploadFile(List<int> bytes, String remotePath);

  /// Opens an interactive PTY shell on the control node sized to
  /// [columns] x [rows]. The returned [RemoteShell] streams decoded output and
  /// accepts keystrokes. Not supported on the web build (see the stub).
  Future<RemoteShell> openShell({int columns, int rows});

  /// Closes the SSH connection and underlying socket.
  Future<void> close();
}

/// A live interactive shell attached to a PTY on the remote host.
///
/// Backs the terminal screen: [output] carries decoded stdout+stderr, [write]
/// feeds keystrokes, [resize] reports terminal geometry changes, and [close]
/// tears the channel down. The demo build provides a simulated implementation
/// (see `services/demo_data.dart`) so the terminal renders offline and on web.
abstract class RemoteShell {
  /// Decoded (utf8) stdout and stderr, merged in arrival order.
  Stream<String> get output;

  /// Sends raw input (keystrokes / pasted text) to the shell.
  void write(String data);

  /// Notifies the remote PTY that the terminal was resized.
  void resize(int columns, int rows);

  /// Closes the shell channel.
  void close();
}
