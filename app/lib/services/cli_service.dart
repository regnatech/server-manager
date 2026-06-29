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

  /// `server --json logs <domain> [type] -n <lines>` → a `logs_meta`
  /// [DataEvent] (`value:{type,file}`) then a `logs` [DataEvent]
  /// (`value:{type,file,lines:[...]}`) then a [DoneEvent].
  Stream<CliEvent> logs(String domain, {String? type, int lines = 200});

  /// `server --json logs <domain> [type] -f` → a `logs_meta` [DataEvent] then
  /// an indefinite stream of [LogEvent]s (live tail). Cancel the subscription
  /// to stop following.
  Stream<CliEvent> logsFollow(String domain, {String? type});

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

  /// `server --json notify status` → emits a `kind:"notify"` [DataEvent]
  /// (`value:{slack:bool, telegram:bool}`) then a [DoneEvent].
  Stream<CliEvent> notifyStatus();

  /// `server --json notify set slack <url>` → log/step events then a
  /// [DoneEvent]. Configures the Slack incoming-webhook destination.
  Stream<CliEvent> notifySetSlack(String url);

  /// `server --json notify set telegram <token> <chat>` → step events then a
  /// [DoneEvent]. Configures the Telegram bot token + target chat id.
  Stream<CliEvent> notifySetTelegram(String token, String chat);

  /// `server --json notify test` → a "Sending test notification" step then a
  /// [DoneEvent].
  Stream<CliEvent> notifyTest();

  /// `server --json notify off` → clears all destinations, then a [DoneEvent].
  Stream<CliEvent> notifyOff();

  /// `server --json uptime --all` → emits an `uptime` [DataEvent] (items:
  /// `{domain, url, up, code, ms}`) then a [DoneEvent].
  Stream<CliEvent> uptimeAll();

  /// `server --json release list <domain>` → a `releases` [DataEvent]
  /// (`value:{current, items:[{name, current}]}`) then a [DoneEvent].
  Stream<CliEvent> releaseList(String domain);

  /// `server --json release rollback <domain> [name]` → step events then a
  /// [DoneEvent]. Omitting [name] rolls back to the previous release.
  Stream<CliEvent> releaseRollback(String domain, [String? name]);

  /// `server --json release deploy <domain>` → an atomic clone/build/migrate/
  /// switch/reload step stream then a [DoneEvent].
  Stream<CliEvent> releaseDeploy(String domain);

  /// `server --json diff <domain>` → a `deploy_diff` [DataEvent]
  /// (`value:{branch, from, to, ahead, commits:[…], migrations:[…]}`) then a
  /// [DoneEvent].
  Stream<CliEvent> deployDiff(String domain);

  /// `server --json update --all [--framework <fw>]` → per-site section/step
  /// events then a `deploy_all` [DataEvent] (`value:{total, deployed, failed}`)
  /// then a [DoneEvent]. [framework] scopes the run to a single framework.
  Stream<CliEvent> updateAll({String? framework});

  /// `server --json audit history [domain]` → an `audit_history` [DataEvent]
  /// (items: `{at, critical, high, medium, low, total}`) then a [DoneEvent].
  /// [domain] scopes to a site; omit it for the server-level history.
  Stream<CliEvent> auditHistory([String? domain]);

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
  Stream<CliEvent> logs(String domain, {String? type, int lines = 200}) =>
      _stream(<String>[
        'logs',
        domain,
        if (type != null) type,
        '-n',
        '$lines',
      ]);

  @override
  Stream<CliEvent> logsFollow(String domain, {String? type}) => _stream(<String>[
        'logs',
        domain,
        if (type != null) type,
        '-f',
      ]);

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
  Stream<CliEvent> notifyStatus() => _stream(<String>['notify', 'status']);

  @override
  Stream<CliEvent> notifySetSlack(String url) =>
      _stream(<String>['notify', 'set', 'slack', url]);

  @override
  Stream<CliEvent> notifySetTelegram(String token, String chat) =>
      _stream(<String>['notify', 'set', 'telegram', token, chat]);

  @override
  Stream<CliEvent> notifyTest() => _stream(<String>['notify', 'test']);

  @override
  Stream<CliEvent> notifyOff() => _stream(<String>['notify', 'off']);

  @override
  Stream<CliEvent> uptimeAll() => _stream(<String>['uptime', '--all']);

  @override
  Stream<CliEvent> releaseList(String domain) =>
      _stream(<String>['release', 'list', domain]);

  @override
  Stream<CliEvent> releaseRollback(String domain, [String? name]) =>
      _stream(<String>[
        'release',
        'rollback',
        domain,
        if (name != null && name.isNotEmpty) name,
      ]);

  @override
  Stream<CliEvent> releaseDeploy(String domain) =>
      _stream(<String>['release', 'deploy', domain]);

  @override
  Stream<CliEvent> deployDiff(String domain) =>
      _stream(<String>['diff', domain]);

  @override
  Stream<CliEvent> updateAll({String? framework}) => _stream(<String>[
        'update',
        '--all',
        if (framework != null && framework.isNotEmpty) ...<String>[
          '--framework',
          framework,
        ],
      ]);

  @override
  Stream<CliEvent> auditHistory([String? domain]) => _stream(<String>[
        'audit',
        'history',
        if (domain != null && domain.isNotEmpty) domain,
      ]);

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
