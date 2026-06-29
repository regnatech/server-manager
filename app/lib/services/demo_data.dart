import '../transport/cli_event.dart';
import 'cli_service.dart';

/// Realistic canned backend data plus a recorded event stream, enabling the
/// app to run and be screenshotted with NO live SSH control node.
///
/// Used by [DemoCliService], which replays these with artificial delays so the
/// timeline and dashboard animate as they would against a real backend.
class DemoData {
  const DemoData._();

  static const String contractVersion = '1';
  static const String backendVersion = '0.1.0';

  /// Site rows, matching the `server --json list` item shape.
  static const List<Map<String, dynamic>> sites = <Map<String, dynamic>>[
    <String, dynamic>{
      'domain': 'clicketta.site',
      'server': 'prod-1',
      'framework': 'Laravel',
      'tls': true,
      'last_deploy': '2026-06-28 21:14',
      'health': 'ok',
    },
    <String, dynamic>{
      'domain': 'shop.example.com',
      'server': 'prod-1',
      'framework': 'Statamic',
      'tls': true,
      'last_deploy': '2026-06-27 09:02',
      'health': 'ok',
    },
    <String, dynamic>{
      'domain': 'api.example.com',
      'server': 'prod-2',
      'framework': 'Node',
      'tls': true,
      'last_deploy': '2026-06-29 06:48',
      'health': 'degraded',
    },
    <String, dynamic>{
      'domain': 'blog.example.com',
      'server': 'prod-2',
      'framework': 'WordPress',
      'tls': false,
      'last_deploy': '2026-05-19 17:33',
      'health': 'down',
    },
    <String, dynamic>{
      'domain': 'staging.app.dev',
      'server': 'staging',
      'framework': 'Laravel',
      'tls': true,
      'last_deploy': '2026-06-29 02:10',
      'health': 'ok',
    },
    <String, dynamic>{
      'domain': 'cdn.example.com',
      'server': 'prod-2',
      'framework': 'Static',
      'tls': true,
      'last_deploy': '2026-06-20 11:55',
      'health': 'ok',
    },
  ];

  /// Server rows, matching the `server --json servers` item shape.
  static const List<Map<String, dynamic>> servers = <Map<String, dynamic>>[
    <String, dynamic>{
      'name': 'prod-1',
      'host': '10.0.4.11',
      'user': 'deploy',
      'become': true,
    },
    <String, dynamic>{
      'name': 'prod-2',
      'host': '10.0.4.12',
      'user': 'deploy',
      'become': true,
    },
    <String, dynamic>{
      'name': 'staging',
      'host': '10.0.9.20',
      'user': 'deploy',
      'become': false,
    },
  ];

  /// A recorded 12-step `update` run: banner, three sections, step pairs with
  /// plausible durations (one fails then recovers on retry), and a report.
  ///
  /// Note the durations are *display* values inside [StepEnd]; the replay
  /// pacing comes from [DemoCliService], not these numbers.
  static List<CliEvent> deployEvents(String domain) => <CliEvent>[
        BannerEvent(label: 'Deploying $domain'),
        const SectionEvent(label: 'Preflight'),
        const StepStart(id: 's1', label: 'Validating git repository'),
        const LogEvent(level: 'info', msg: 'remote: origin git@github.com:acme/$_repo'),
        const StepEnd(id: 's1', ok: true, dur: 0.6),
        const StepStart(id: 's2', label: 'Checking disk space & permissions'),
        const LogEvent(level: 'ok', msg: '18.4G free on /var/www'),
        const StepEnd(id: 's2', ok: true, dur: 0.4),
        const SectionEvent(label: 'Backup'),
        const StepStart(id: 's3', label: 'Backing up .env, nginx config & database'),
        const LogEvent(level: 'info', msg: 'dumping database (mysqldump)…'),
        const LogEvent(level: 'ok', msg: 'snapshot saved: backups/2026-06-29.tar.gz'),
        const StepEnd(id: 's3', ok: true, dur: 3.2),
        const StepStart(id: 's4', label: 'Enabling maintenance mode'),
        const StepEnd(id: 's4', ok: true, dur: 0.3),
        const SectionEvent(label: 'Deploy'),
        const StepStart(id: 's5', label: 'Pulling main from origin'),
        const LogEvent(level: 'info', msg: 'Fast-forward 4f1c2a9..a77b3e1'),
        const StepEnd(id: 's5', ok: true, dur: 1.1),
        const StepStart(id: 's6', label: 'Installing Composer dependencies'),
        const LogEvent(level: 'info', msg: 'composer install --no-dev --optimize-autoloader'),
        const ProgressEvent(cur: 42, total: 118, label: 'Resolving packages'),
        const ProgressEvent(cur: 118, total: 118, label: 'Generating autoload files'),
        const StepEnd(id: 's6', ok: true, dur: 6.7),
        const StepStart(id: 's7', label: 'Building frontend assets'),
        const LogEvent(level: 'err', msg: 'npm ERR! network timeout fetching registry'),
        const StepEnd(id: 's7', ok: false, dur: 4.0, err: 'asset build failed (network)'),
        const StepStart(id: 's7r', label: 'Building frontend assets (retry)'),
        const LogEvent(level: 'warn', msg: 'retrying with cached registry mirror'),
        const ProgressEvent(cur: 60, total: 100, label: 'vite build'),
        const LogEvent(level: 'ok', msg: 'built 214 modules in 9.83s'),
        const StepEnd(id: 's7r', ok: true, dur: 11.2),
        const StepStart(id: 's8', label: 'Running migrations'),
        const LogEvent(level: 'info', msg: '2 migrations to run'),
        const LogEvent(level: 'ok', msg: 'Migrated: 2026_06_25_add_index_to_orders'),
        const StepEnd(id: 's8', ok: true, dur: 0.9),
        const StepStart(id: 's9', label: 'Rebuilding caches'),
        const LogEvent(level: 'info', msg: 'config:cache route:cache view:cache'),
        const StepEnd(id: 's9', ok: true, dur: 1.3),
        const StepStart(
          id: 's10',
          label: 'Restarting PHP-FPM & queue workers',
        ),
        const LogEvent(level: 'ok', msg: 'php-fpm reloaded; 4 workers restarted'),
        const StepEnd(id: 's10', ok: true, dur: 2.1),
        const StepStart(id: 's11', label: 'Disabling maintenance mode'),
        const StepEnd(id: 's11', ok: true, dur: 0.3),
        const StepStart(id: 's12', label: 'Health check'),
        const LogEvent(level: 'ok', msg: 'GET / → 200 in 88ms'),
        const StepEnd(id: 's12', ok: true, dur: 0.5),
        ReportEvent(
          title: 'Deploy complete',
          fields: <String, String>{
            'Domain': domain,
            'Commit': 'a77b3e1',
            'Duration': '34.7s',
            'Migrations': '2 applied',
            'Result': 'success',
          },
        ),
        const DoneEvent(ok: true),
      ];

  static const String _repo = 'clicketta.git';

  /// Cron entries for the scheduler tab.
  static const List<Map<String, dynamic>> cron = <Map<String, dynamic>>[
    <String, dynamic>{
      'schedule': '* * * * *',
      'command': 'php artisan schedule:run',
      'last': '2026-06-29 06:50',
      'status': 'ok',
    },
    <String, dynamic>{
      'schedule': '0 3 * * *',
      'command': 'php artisan backup:run',
      'last': '2026-06-29 03:00',
      'status': 'ok',
    },
  ];

  /// Worker entries for the workers tab.
  static const List<Map<String, dynamic>> workers = <Map<String, dynamic>>[
    <String, dynamic>{'name': 'queue:default', 'procs': 4, 'status': 'running'},
    <String, dynamic>{'name': 'queue:mail', 'procs': 2, 'status': 'running'},
    <String, dynamic>{'name': 'horizon', 'procs': 1, 'status': 'running'},
  ];

  /// The `add --plan` payload (value for `kind:"plan"`).
  static const Map<String, dynamic> addPlan = <String, dynamic>{
    'command': 'add',
    'fields': <Map<String, dynamic>>[
      <String, dynamic>{
        'id': 'domain',
        'type': 'domain',
        'label': 'Domain name',
        'value': '',
        'required': true,
      },
      <String, dynamic>{
        'id': 'server',
        'type': 'enum',
        'label': 'Target server',
        'value': 'prod-1',
        'required': true,
        'options': <String>['prod-1', 'prod-2', 'staging'],
      },
      <String, dynamic>{
        'id': 'framework',
        'type': 'enum',
        'label': 'Framework',
        'value': 'Laravel',
        'required': true,
        'options': <String>['Laravel', 'Statamic', 'Node', 'WordPress', 'Static'],
      },
      <String, dynamic>{
        'id': 'repo',
        'type': 'string',
        'label': 'Git repository URL',
        'value': '',
        'required': true,
      },
      <String, dynamic>{
        'id': 'path',
        'type': 'abspath',
        'label': 'Deploy path',
        'value': '/var/www',
        'required': true,
      },
      <String, dynamic>{
        'id': 'tls',
        'type': 'bool',
        'label': 'Provision TLS certificate (Let\'s Encrypt)',
        'value': 'true',
        'required': false,
      },
      <String, dynamic>{
        'id': 'tls_email',
        'type': 'string',
        'label': 'ACME contact email',
        'value': '',
        'required': true,
        'when': <String, dynamic>{'field': 'tls', 'equals': 'true'},
      },
      <String, dynamic>{
        'id': 'db_password',
        'type': 'secret',
        'label': 'Database password',
        'value': '',
        'required': true,
        'when': <String, dynamic>{'field': 'framework', 'equals': 'Laravel'},
      },
    ],
  };

  /// A recorded provisioning run for `add --apply`.
  static List<CliEvent> addApplyEvents(String domain) => <CliEvent>[
        BannerEvent(label: 'Provisioning $domain'),
        const SectionEvent(label: 'Prepare'),
        const StepStart(id: 'a1', label: 'Creating system user & directories'),
        const StepEnd(id: 'a1', ok: true, dur: 0.7),
        const StepStart(id: 'a2', label: 'Cloning repository'),
        const LogEvent(level: 'ok', msg: 'cloned in 2.4s'),
        const StepEnd(id: 'a2', ok: true, dur: 2.4),
        const SectionEvent(label: 'Configure'),
        const StepStart(id: 'a3', label: 'Writing nginx vhost'),
        const StepEnd(id: 'a3', ok: true, dur: 0.5),
        const StepStart(id: 'a4', label: 'Requesting TLS certificate'),
        const LogEvent(level: 'info', msg: 'acme: order finalized'),
        const StepEnd(id: 'a4', ok: true, dur: 5.1),
        const StepStart(id: 'a5', label: 'Installing dependencies & first deploy'),
        const ProgressEvent(cur: 80, total: 100, label: 'composer install'),
        const StepEnd(id: 'a5', ok: true, dur: 8.3),
        const StepStart(id: 'a6', label: 'Health check'),
        const LogEvent(level: 'ok', msg: 'GET / → 200'),
        const StepEnd(id: 'a6', ok: true, dur: 0.5),
        ReportEvent(
          title: 'Site provisioned',
          fields: <String, String>{
            'Domain': domain,
            'TLS': 'issued (90 days)',
            'Server': 'prod-1',
            'Result': 'success',
          },
        ),
        const DoneEvent(ok: true),
      ];
}

/// A [CliService] that replays [DemoData] with artificial pacing so the UI
/// animates realistically without any SSH connection. Safe on Flutter web.
class DemoCliService implements CliService {
  const DemoCliService();

  static const Duration _stepGap = Duration(milliseconds: 650);
  static const Duration _shortGap = Duration(milliseconds: 220);

  @override
  Future<VersionEvent> version() async {
    await Future<void>.delayed(const Duration(milliseconds: 300));
    return const VersionEvent(
      contract: DemoData.contractVersion,
      version: DemoData.backendVersion,
    );
  }

  @override
  Stream<CliEvent> listSitesEvents() async* {
    await Future<void>.delayed(_shortGap);
    yield DataEvent(kind: 'sites', items: DemoData.sites);
    yield const DoneEvent(ok: true);
  }

  @override
  Stream<CliEvent> listServersEvents() async* {
    await Future<void>.delayed(_shortGap);
    yield DataEvent(kind: 'servers', items: DemoData.servers);
    yield const DoneEvent(ok: true);
  }

  /// Replays recorded events, pausing longer between step boundaries so the
  /// spinner→check transitions read clearly on screen.
  Stream<CliEvent> _replay(List<CliEvent> events) async* {
    for (final CliEvent e in events) {
      final Duration gap = switch (e) {
        StepEnd() => _stepGap,
        StepStart() => _shortGap,
        ProgressEvent() => _shortGap,
        _ => const Duration(milliseconds: 120),
      };
      await Future<void>.delayed(gap);
      yield e;
    }
  }

  @override
  Stream<CliEvent> deploy(String domain) =>
      _replay(DemoData.deployEvents(domain));

  @override
  Stream<CliEvent> rollback(String domain) => _replay(<CliEvent>[
        BannerEvent(label: 'Rolling back $domain'),
        const StepStart(id: 'r1', label: 'Restoring previous release'),
        const StepEnd(id: 'r1', ok: true, dur: 1.4),
        const StepStart(id: 'r2', label: 'Reloading services'),
        const StepEnd(id: 'r2', ok: true, dur: 0.9),
        const DoneEvent(ok: true),
      ]);

  @override
  Stream<CliEvent> cronList(String domain) async* {
    await Future<void>.delayed(_shortGap);
    yield DataEvent(kind: 'cron', items: DemoData.cron);
    yield const DoneEvent(ok: true);
  }

  @override
  Stream<CliEvent> workersList(String domain) async* {
    await Future<void>.delayed(_shortGap);
    yield DataEvent(kind: 'workers', items: DemoData.workers);
    yield const DoneEvent(ok: true);
  }

  @override
  Stream<CliEvent> logs(String domain) async* {
    await Future<void>.delayed(_shortGap);
    for (final String line in <String>[
      '[06:50:01] production.INFO: schedule:run completed',
      '[06:48:12] production.WARN: slow query 1.8s on orders',
      '[06:45:33] production.INFO: cache warmed',
    ]) {
      yield LogEvent(level: 'info', msg: line);
      await Future<void>.delayed(const Duration(milliseconds: 120));
    }
    yield const DoneEvent(ok: true);
  }

  @override
  Stream<CliEvent> sslStatus(String domain) async* {
    await Future<void>.delayed(_shortGap);
    yield DataEvent(
      kind: 'ssl',
      value: <String, dynamic>{
        'issuer': "Let's Encrypt",
        'expires': '2026-09-26',
        'days_left': '89',
        'status': 'valid',
      },
    );
    yield const DoneEvent(ok: true);
  }

  @override
  Stream<CliEvent> addPlan() async* {
    await Future<void>.delayed(const Duration(milliseconds: 400));
    yield DataEvent(kind: 'plan', value: DemoData.addPlan);
    yield const DoneEvent(ok: true);
  }

  @override
  Future<Stream<CliEvent>> addApply({
    required List<int> answersBytes,
    String remotePath = '/tmp/server-manager-answers.json',
  }) async {
    await Future<void>.delayed(const Duration(milliseconds: 300));
    return _replay(DemoData.addApplyEvents('new-site.example.com'));
  }
}
