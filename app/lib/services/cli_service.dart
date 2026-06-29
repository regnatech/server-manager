import 'dart:convert';
import 'dart:math';

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

  /// `server --json audit [<domain>]` → step events then an audit [DataEvent].
  ///
  /// With a non-empty [domain] the audit is scoped to that site; omitted (or
  /// null/empty) it runs a server-level audit (`server --json audit`).
  Stream<CliEvent> audit([String? domain]);

  /// `server --json audit fix <id> [<domain>]` → step events then a [DoneEvent].
  ///
  /// [domain] scopes the fix to a site; omit it for a server-level fix.
  Stream<CliEvent> auditFix(String id, [String? domain]);

  /// `server --json audit fixall [<domain>]` → a step event per applied fix
  /// then an `audit_fixall` [DataEvent] (`value:{applied, failed}`) then a
  /// [DoneEvent]. [domain] scopes to a site; omit it for a server-level run.
  Stream<CliEvent> auditFixAll([String? domain]);

  /// `server --json metrics` → step events then a metrics [DataEvent]
  /// (`kind:"metrics"`, `value` matching `ServerMetrics.fromJson`).
  Stream<CliEvent> metrics();

  /// `server --json git log <domain>` → a commit-graph [DataEvent]
  /// (`kind:"git_log"`, items matching `GitCommit.fromJson`).
  Stream<CliEvent> gitLog(String domain);

  /// `server --json git status <domain>` → a working-tree [DataEvent]
  /// (`kind:"git_status"`, value matching `GitStatus.fromJson`).
  Stream<CliEvent> gitStatus(String domain);

  /// `server --json git branches <domain>` → a branches [DataEvent]
  /// (`kind:"git_branches"`, items matching `GitBranch.fromJson`).
  Stream<CliEvent> gitBranches(String domain);

  /// `server --json git push <domain> --deploy` → a push step then the full
  /// deploy step stream (reuses the deploy timeline) then a [DoneEvent].
  Stream<CliEvent> gitPushDeploy(String domain);

  /// `server --json git deploy <domain> <branch>` → fetch/checkout/pull steps
  /// then the deploy step stream then a [DoneEvent].
  Stream<CliEvent> gitDeploy(String domain, String branch);

  /// `server --json git branch <domain> <name>` → create+checkout steps then
  /// a [DoneEvent].
  Stream<CliEvent> gitCreateBranch(String domain, String name);

  /// `server --json git tag <domain> <name> [message]` → create+push steps
  /// then a [DoneEvent].
  Stream<CliEvent> gitCreateTag(String domain, String name, {String? message});

  /// `server --json git pr <domain> <title> [base]` → push+create steps then a
  /// `kind:"pr"` [DataEvent] (value: url/title/base) then a [DoneEvent]. A
  /// `done(ok:false)` means the server's `gh` CLI is missing/unauthenticated.
  Stream<CliEvent> gitCreatePr(String domain, String title, {String base});

  /// `server --json git merge <domain> <branch>` → either a `kind:"git_merge"`
  /// [DataEvent] (`value.clean == true`) + `done(ok:true)`, or a
  /// `kind:"git_conflicts"` [DataEvent] (items: path/ours/theirs/conflicted) +
  /// `done(ok:false)` when the merge conflicts.
  Stream<CliEvent> gitMerge(String domain, String branch);

  /// `server --json git resolve <domain> <path> --tmp <remoteTmp>` → applies a
  /// resolved file then `git add`. [content] is uploaded (live) to a temp path
  /// first. Emits a `kind:"git_resolved"` [DataEvent]
  /// (`value:{path, remaining}`) then a [DoneEvent].
  Stream<CliEvent> gitResolve(String domain, String path, String content);

  /// `server --json git merge-continue <domain>` → commits the merge + done.
  Stream<CliEvent> gitMergeContinue(String domain);

  /// `server --json git merge-abort <domain>` → aborts the merge + done.
  Stream<CliEvent> gitMergeAbort(String domain);

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
  Stream<CliEvent> audit([String? domain]) => _stream(<String>[
        'audit',
        if (domain != null && domain.isNotEmpty) domain,
      ]);

  @override
  Stream<CliEvent> auditFix(String id, [String? domain]) => _stream(<String>[
        'audit',
        'fix',
        id,
        if (domain != null && domain.isNotEmpty) domain,
      ]);

  @override
  Stream<CliEvent> auditFixAll([String? domain]) => _stream(<String>[
        'audit',
        'fixall',
        if (domain != null && domain.isNotEmpty) domain,
      ]);

  @override
  Stream<CliEvent> metrics() => _stream(<String>['metrics']);

  @override
  Stream<CliEvent> gitLog(String domain) =>
      _stream(<String>['git', 'log', domain]);

  @override
  Stream<CliEvent> gitStatus(String domain) =>
      _stream(<String>['git', 'status', domain]);

  @override
  Stream<CliEvent> gitBranches(String domain) =>
      _stream(<String>['git', 'branches', domain]);

  @override
  Stream<CliEvent> gitPushDeploy(String domain) =>
      _stream(<String>['git', 'push', domain, '--deploy']);

  @override
  Stream<CliEvent> gitDeploy(String domain, String branch) =>
      _stream(<String>['git', 'deploy', domain, branch]);

  @override
  Stream<CliEvent> gitCreateBranch(String domain, String name) =>
      _stream(<String>['git', 'branch', domain, name]);

  @override
  Stream<CliEvent> gitCreateTag(String domain, String name, {String? message}) =>
      _stream(<String>[
        'git',
        'tag',
        domain,
        name,
        if (message != null && message.isNotEmpty) message,
      ]);

  @override
  Stream<CliEvent> gitCreatePr(String domain, String title,
          {String base = 'main'}) =>
      _stream(<String>['git', 'pr', domain, title, base]);

  @override
  Stream<CliEvent> gitMerge(String domain, String branch) =>
      _stream(<String>['git', 'merge', domain, branch]);

  @override
  Stream<CliEvent> gitResolve(String domain, String path, String content) async* {
    // Upload the resolved file to a unique temp path, then ask the backend to
    // apply it and `git add` the resolution.
    final int rand = Random().nextInt(1 << 32);
    final String tmp = '/tmp/sm-resolve-${rand.toRadixString(16)}';
    await _session.uploadFile(utf8.encode(content), tmp);
    yield* _stream(<String>['git', 'resolve', domain, path, '--tmp', tmp]);
  }

  @override
  Stream<CliEvent> gitMergeContinue(String domain) =>
      _stream(<String>['git', 'merge-continue', domain]);

  @override
  Stream<CliEvent> gitMergeAbort(String domain) =>
      _stream(<String>['git', 'merge-abort', domain]);

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
