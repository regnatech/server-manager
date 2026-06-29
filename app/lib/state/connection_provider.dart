import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/connection_profile.dart';
import '../services/cli_service.dart';
import '../services/connection_store.dart';
import '../services/demo_data.dart';
import '../transport/ssh_session.dart';

/// Provides the secure connection store (single instance).
final connectionStoreProvider = Provider<ConnectionStore>((ref) {
  return ConnectionStore();
});

/// Whether the app is in DEMO mode (no SSH; canned data from [DemoCliService]).
///
/// When true, [cliServiceProvider] returns a [DemoCliService] regardless of any
/// live session, and the router treats the app as "connected". Toggled by the
/// "Explore demo" button on the connect screen.
final demoModeProvider = StateProvider<bool>((ref) => false);

/// The set of credentials gathered on the connect screen but held only in
/// memory until a connection is established.
class ConnectionCredentials {
  const ConnectionCredentials({
    required this.profile,
    this.password,
    this.privateKeyPem,
    this.passphrase,
  });

  final ConnectionProfile profile;
  final String? password;
  final String? privateKeyPem;
  final String? passphrase;
}

/// Lifecycle phases of the live SSH connection.
enum ConnectionPhase { disconnected, connecting, connected, error }

/// Immutable snapshot of the connection state.
class ConnState {
  const ConnState({
    this.phase = ConnectionPhase.disconnected,
    this.session,
    this.cli,
    this.profile,
    this.version,
    this.errorMessage,
  });

  final ConnectionPhase phase;
  final SshSession? session;
  final CliService? cli;
  final ConnectionProfile? profile;

  /// Backend version string, populated after a successful `version()` probe.
  final String? version;
  final String? errorMessage;

  bool get isConnected => phase == ConnectionPhase.connected && cli != null;

  ConnState copyWith({
    ConnectionPhase? phase,
    SshSession? session,
    CliService? cli,
    ConnectionProfile? profile,
    String? version,
    String? errorMessage,
  }) {
    return ConnState(
      phase: phase ?? this.phase,
      session: session ?? this.session,
      cli: cli ?? this.cli,
      profile: profile ?? this.profile,
      version: version ?? this.version,
      errorMessage: errorMessage,
    );
  }
}

/// Owns the live SSH session and exposes connect/disconnect actions.
class ConnectionController extends StateNotifier<ConnState> {
  ConnectionController(this._ref) : super(const ConnState());

  final Ref _ref;

  /// Opens an SSH session, probes the backend version, and—on success—
  /// optionally persists the profile (without secrets) and its secret.
  Future<bool> connect(
    ConnectionCredentials creds, {
    bool remember = false,
  }) async {
    state = state.copyWith(
      phase: ConnectionPhase.connecting,
      profile: creds.profile,
    );

    final SshSession session = SshSession.fromProfile(
      creds.profile,
      password: creds.password,
      privateKeyPem: creds.privateKeyPem,
      passphrase: creds.passphrase,
    );

    try {
      await session.connect();
      final CliService cli = LiveCliService(session);
      final version = await cli.version();

      state = ConnState(
        phase: ConnectionPhase.connected,
        session: session,
        cli: cli,
        profile: creds.profile,
        version: version.version,
      );

      if (remember) {
        await _persist(creds);
      }
      return true;
    } on Object catch (e) {
      await session.close();
      state = state.copyWith(
        phase: ConnectionPhase.error,
        errorMessage: e.toString(),
      );
      return false;
    }
  }

  Future<void> _persist(ConnectionCredentials creds) async {
    final ConnectionStore store = _ref.read(connectionStoreProvider);
    await store.saveProfile(creds.profile);
    final String? secret = creds.profile.authMethod == AuthMethod.password
        ? creds.password
        : creds.passphrase;
    if (secret != null && secret.isNotEmpty) {
      await store.saveSecret(creds.profile, secret);
    }
  }

  /// Enters demo mode: marks the app "connected" with a [DemoCliService] and
  /// no real session, so screens render canned data.
  void enterDemo() {
    _ref.read(demoModeProvider.notifier).state = true;
    state = const ConnState(
      phase: ConnectionPhase.connected,
      cli: DemoCliService(),
      version: DemoData.backendVersion,
    );
  }

  /// Closes the session and resets to disconnected (also exits demo mode).
  Future<void> disconnect() async {
    await state.session?.close();
    _ref.read(demoModeProvider.notifier).state = false;
    state = const ConnState();
  }

  @override
  void dispose() {
    state.session?.close();
    super.dispose();
  }
}

final connectionProvider =
    StateNotifierProvider<ConnectionController, ConnState>((ref) {
  return ConnectionController(ref);
});

/// Convenience accessor for the active [CliService]; throws if disconnected.
final cliServiceProvider = Provider<CliService>((ref) {
  final CliService? cli = ref.watch(connectionProvider).cli;
  if (cli == null) {
    throw StateError('Not connected: no CliService available.');
  }
  return cli;
});
