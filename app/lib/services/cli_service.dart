import '../transport/cli_event.dart';
import '../transport/ndjson.dart';
import '../transport/ssh_session.dart';

/// Abstract contract for driving the `server --json` backend.
///
/// Two implementations exist: [LiveCliService] (real SSH) and
/// `DemoCliService` (canned data, see `demo_data.dart`). Screens depend only on
/// this interface, so demo mode is a drop-in substitution.
abstract class CliService {
  /// `server --json version` → resolves to a single [VersionEvent].
  Future<VersionEvent> version();

  /// `server --json list` → streams NDJSON ending in a sites [DataEvent].
  Stream<CliEvent> listSitesEvents();

  /// `server --json servers` → emits a servers [DataEvent].
  Stream<CliEvent> listServersEvents();

  /// `server --json update <domain>` → streamed deploy events.
  Stream<CliEvent> deploy(String domain);

  /// `server --json rollback <domain>` → streamed rollback events.
  Stream<CliEvent> rollback(String domain);

  /// `server --json cron list <domain>` → scheduler entries.
  Stream<CliEvent> cronList(String domain);

  /// `server --json workers list <domain>` → worker entries.
  Stream<CliEvent> workersList(String domain);

  /// `server --json logs <domain>` → recent log lines.
  Stream<CliEvent> logs(String domain);

  /// `server --json ssl status <domain>` → certificate info.
  Stream<CliEvent> sslStatus(String domain);

  /// `server --json add --plan` → emits a plan [DataEvent].
  Stream<CliEvent> addPlan();

  /// Uploads answers (live) and runs `add --apply --answers <file>`.
  Future<Stream<CliEvent>> addApply({
    required List<int> answersBytes,
    String remotePath,
  });
}

/// SSH-backed implementation. Builds `server --json <args>` strings with
/// shell-safe quoting and parses stdout via [NdjsonTransformer].
class LiveCliService implements CliService {
  LiveCliService(this._session);

  final SshSession _session;
  static const String _bin = 'server';

  /// POSIX single-quote escaping so domains/paths cannot break out of argv.
  static String shellQuote(String arg) {
    if (arg.isEmpty) return "''";
    return "'${arg.replaceAll("'", r"'\''")}'";
  }

  /// Builds `server --json <args...>` with every argument quoted.
  static String buildCommand(List<String> args) {
    final String quoted = args.map(shellQuote).join(' ');
    return '$_bin --json $quoted';
  }

  Stream<CliEvent> _stream(List<String> args) {
    return _session.run(buildCommand(args)).transform(const NdjsonTransformer());
  }

  @override
  Future<VersionEvent> version() async {
    await for (final CliEvent e in _stream(<String>['version'])) {
      if (e is VersionEvent) return e;
    }
    throw const CliException('No version event returned by control node.');
  }

  @override
  Stream<CliEvent> listSitesEvents() => _stream(<String>['list']);

  @override
  Stream<CliEvent> listServersEvents() => _stream(<String>['servers']);

  @override
  Stream<CliEvent> deploy(String domain) =>
      _stream(<String>['update', domain]);

  @override
  Stream<CliEvent> rollback(String domain) =>
      _stream(<String>['rollback', domain]);

  @override
  Stream<CliEvent> cronList(String domain) =>
      _stream(<String>['cron', 'list', domain]);

  @override
  Stream<CliEvent> workersList(String domain) =>
      _stream(<String>['workers', 'list', domain]);

  @override
  Stream<CliEvent> logs(String domain) => _stream(<String>['logs', domain]);

  @override
  Stream<CliEvent> sslStatus(String domain) =>
      _stream(<String>['ssl', 'status', domain]);

  @override
  Stream<CliEvent> addPlan() => _stream(<String>['add', '--plan']);

  @override
  Future<Stream<CliEvent>> addApply({
    required List<int> answersBytes,
    String remotePath = '/tmp/server-manager-answers.json',
  }) async {
    await _session.uploadFile(answersBytes, remotePath);
    return _stream(<String>['add', '--apply', '--answers', remotePath]);
  }
}

/// Raised for CLI-level protocol failures (e.g. missing expected events).
class CliException implements Exception {
  const CliException(this.message);
  final String message;
  @override
  String toString() => 'CliException: $message';
}
