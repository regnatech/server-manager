import 'dart:async';

import '../transport/cli_event.dart';
import '../transport/ssh_session.dart';
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

  /// The full set of demo audit findings, keyed by id. The demo `audit`
  /// stream omits any id present in [DemoCliService]'s fixed set so the list
  /// visibly shrinks after a fix is applied.
  static List<Map<String, dynamic>> auditFindings(String domain) =>
      <Map<String, dynamic>>[
        <String, dynamic>{
          'id': 'env_exposed',
          'severity': 'critical',
          'title': '.env is downloadable over HTTP',
          'detail': 'https://$domain/.env returns 200.',
          'recommendation': 'Deny dotfiles in nginx.',
          'fixable': true,
          'fix_label': 'Block .env over HTTP',
        },
        <String, dynamic>{
          'id': 'ssh_root_login',
          'severity': 'high',
          'title': 'SSH permits root login',
          'detail': "PermitRootLogin is 'yes'.",
          'recommendation': 'Set PermitRootLogin to no and use a sudo user.',
          'fixable': true,
          'fix_label': 'Disable root SSH login',
        },
        <String, dynamic>{
          'id': 'firewall',
          'severity': 'high',
          'title': 'No active firewall',
          'detail': 'ufw is inactive.',
          'recommendation': 'Enable ufw (22/80/443 only).',
          'fixable': true,
          'fix_label': 'Enable the firewall',
        },
        <String, dynamic>{
          'id': 'fail2ban',
          'severity': 'medium',
          'title': 'fail2ban is not running',
          'detail': 'Brute-force attempts are not throttled.',
          'recommendation': 'Install fail2ban.',
          'fixable': true,
          'fix_label': 'Install fail2ban',
        },
        <String, dynamic>{
          'id': 'https',
          'severity': 'medium',
          'title': 'Site served over plain HTTP',
          'detail': 'Traffic is unencrypted.',
          'recommendation': "Issue a Let's Encrypt certificate.",
          'fixable': true,
          'fix_label': 'Enable HTTPS',
        },
        <String, dynamic>{
          'id': 'db_bind',
          'severity': 'low',
          'title': 'Database listens on 0.0.0.0',
          'detail': 'MySQL is reachable from the network.',
          'recommendation': 'Bind MySQL to 127.0.0.1.',
          'fixable': false,
          'fix_label': '',
        },
      ];

  /// The server-scoped audit findings (no site-specific items). Powers the
  /// server-level audit reached from the dashboard. Like [auditFindings], the
  /// demo stream omits any id already in the fixed set so the list shrinks
  /// after a fix.
  static List<Map<String, dynamic>> serverAuditFindings() =>
      <Map<String, dynamic>>[
        <String, dynamic>{
          'id': 'ssh_root_login',
          'severity': 'high',
          'title': 'SSH permits root login',
          'detail': "PermitRootLogin is 'yes'.",
          'recommendation': 'Set PermitRootLogin to no and use a sudo user.',
          'fixable': true,
          'fix_label': 'Disable root SSH login',
        },
        <String, dynamic>{
          'id': 'firewall',
          'severity': 'high',
          'title': 'No active firewall',
          'detail': 'ufw is inactive.',
          'recommendation': 'Enable ufw (allow 22/80/443 only).',
          'fixable': true,
          'fix_label': 'Enable the firewall',
        },
        <String, dynamic>{
          'id': 'fail2ban',
          'severity': 'medium',
          'title': 'fail2ban is not running',
          'detail': 'Brute-force attempts are not throttled.',
          'recommendation': 'Install and enable fail2ban.',
          'fixable': true,
          'fix_label': 'Install fail2ban',
        },
        <String, dynamic>{
          'id': 'auto_updates',
          'severity': 'medium',
          'title': 'Unattended security updates are off',
          'detail': 'unattended-upgrades is not configured.',
          'recommendation': 'Enable automatic security updates.',
          'fixable': true,
          'fix_label': 'Enable auto-updates',
        },
        <String, dynamic>{
          'id': 'nginx_server_tokens',
          'severity': 'low',
          'title': 'nginx leaks its version',
          'detail': 'server_tokens is on; responses expose the nginx version.',
          'recommendation': 'Set server_tokens off in nginx.conf.',
          'fixable': true,
          'fix_label': 'Hide nginx version',
        },
        <String, dynamic>{
          'id': 'php_expose',
          'severity': 'low',
          'title': 'PHP advertises itself via X-Powered-By',
          'detail': 'expose_php is On.',
          'recommendation': 'Set expose_php = Off in php.ini.',
          'fixable': true,
          'fix_label': 'Hide PHP version',
        },
        <String, dynamic>{
          'id': 'open_ports',
          'severity': 'low',
          'title': 'Unexpected listening ports',
          'detail': 'Ports 6379 (redis) and 3306 (mysql) are listening.',
          'recommendation': 'Bind internal services to 127.0.0.1.',
          'fixable': false,
          'fix_label': '',
        },
      ];

  /// Human-readable progress label for a demo `audit fix <id>` run.
  static String auditFixLabel(String id) {
    switch (id) {
      case 'env_exposed':
        return 'Blocking .env over HTTP';
      case 'ssh_root_login':
        return 'Disabling root SSH login';
      case 'firewall':
        return 'Enabling the firewall';
      case 'fail2ban':
        return 'Installing fail2ban';
      case 'https':
        return 'Issuing a TLS certificate';
      case 'auto_updates':
        return 'Enabling unattended security updates';
      case 'nginx_server_tokens':
        return 'Disabling nginx server_tokens';
      case 'php_expose':
        return 'Disabling expose_php';
      default:
        return 'Applying remediation';
    }
  }

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

  /// Ids whose remediation has already been applied in this demo session, so a
  /// subsequent [audit] omits them and the posture visibly improves.
  static final Set<String> _fixedAuditIds = <String>{};

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
  Stream<CliEvent> metrics() async* {
    // Mildly dynamic per call so successive refreshes visibly differ.
    final int seed = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    int jitter(int base, int spread) => base + (seed % (2 * spread + 1)) - spread;

    yield BannerEvent(label: 'Reading server metrics');
    final List<(String, String)> steps = <(String, String)>[
      ('m1', 'Reading load & CPU'),
      ('m2', 'Reading memory & disk'),
      ('m3', 'Checking services'),
    ];
    for (final (String, String) s in steps) {
      yield StepStart(id: s.$1, label: s.$2);
      await Future<void>.delayed(const Duration(milliseconds: 420));
      yield StepEnd(id: s.$1, ok: true, dur: 0.4);
      await Future<void>.delayed(const Duration(milliseconds: 140));
    }

    final int cpuPct = jitter(23, 8).clamp(2, 99);
    const int memTotal = 8000000000;
    final int memUsed =
        (memTotal * (jitter(26, 6).clamp(5, 95)) / 100).round();
    const int diskTotal = 50000000000;
    final int diskUsed =
        (diskTotal * (jitter(24, 3).clamp(5, 95)) / 100).round();

    yield DataEvent(
      kind: 'metrics',
      value: <String, dynamic>{
        'server': 'prod-1',
        'host': '203.0.113.10',
        'uptime_seconds': 1234567,
        'load': <double>[
          (jitter(42, 12) / 100),
          (jitter(55, 10) / 100),
          (jitter(61, 8) / 100),
        ],
        'cpu_count': 4,
        'cpu_pct': cpuPct,
        'mem': <String, dynamic>{
          'used': memUsed,
          'total': memTotal,
          'pct': (memUsed / memTotal * 100).round(),
        },
        'disk': <String, dynamic>{
          'used': diskUsed,
          'total': diskTotal,
          'pct': (diskUsed / diskTotal * 100).round(),
        },
        'services': <Map<String, dynamic>>[
          <String, dynamic>{'name': 'nginx', 'active': true},
          <String, dynamic>{'name': 'php8.3-fpm', 'active': true},
          <String, dynamic>{'name': 'mysql', 'active': true},
          <String, dynamic>{'name': 'redis', 'active': false},
          <String, dynamic>{'name': 'supervisor', 'active': true},
        ],
      },
    );
    yield const DoneEvent(ok: true);
  }

  @override
  Stream<CliEvent> audit([String? domain]) async* {
    final bool server = domain == null || domain.isEmpty;
    yield BannerEvent(
      label: server ? 'Auditing server' : 'Auditing $domain',
    );
    yield const SectionEvent(label: 'Security audit');
    final List<(String, String)> checks = server
        ? const <(String, String)>[
            ('c1', 'Checking SSH configuration'),
            ('c2', 'Checking the firewall'),
            ('c3', 'Checking fail2ban'),
            ('c4', 'Checking automatic updates'),
            ('c5', 'Checking nginx hardening'),
            ('c6', 'Checking PHP configuration'),
            ('c7', 'Checking listening ports'),
          ]
        : const <(String, String)>[
            ('c1', 'Checking SSH configuration'),
            ('c2', 'Checking the firewall'),
            ('c3', 'Checking fail2ban'),
            ('c4', 'Checking automatic updates'),
            ('c5', 'Checking .env permissions'),
            ('c6', 'Checking HTTPS'),
          ];
    for (final (String, String) c in checks) {
      yield StepStart(id: c.$1, label: c.$2);
      await Future<void>.delayed(const Duration(milliseconds: 380));
      yield StepEnd(id: c.$1, ok: true, dur: 0.4);
      await Future<void>.delayed(const Duration(milliseconds: 140));
    }
    final List<Map<String, dynamic>> source = server
        ? DemoData.serverAuditFindings()
        : DemoData.auditFindings(domain);
    final List<Map<String, dynamic>> items = source
        .where((Map<String, dynamic> f) =>
            !_fixedAuditIds.contains(f['id'] as String))
        .toList();
    await Future<void>.delayed(_shortGap);
    yield DataEvent(kind: 'audit', items: items);
    yield const DoneEvent(ok: true);
  }

  @override
  Stream<CliEvent> auditFix(String id, [String? domain]) async* {
    final String scope = (domain == null || domain.isEmpty)
        ? 'the server'
        : domain;
    yield BannerEvent(label: 'Fixing $id on $scope');
    final String label = DemoData.auditFixLabel(id);
    yield StepStart(id: 'fix-$id', label: label);
    await Future<void>.delayed(const Duration(milliseconds: 700));
    yield StepEnd(id: 'fix-$id', ok: true, dur: 0.7);
    _fixedAuditIds.add(id);
    await Future<void>.delayed(const Duration(milliseconds: 120));
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

/// A fully simulated [RemoteShell] — a believable bash session with NO network.
///
/// Echoes keystrokes, parses a handful of commands, and re-emits a colored
/// prompt. Powers the terminal screen offline and on web, and auto-plays a
/// short scripted intro so a screenshot taken shortly after launch already
/// shows a populated session.
class DemoShell implements RemoteShell {
  DemoShell({
    String user = 'deploy',
    String host = 'control-node',
    String cwd = '~',
    List<String>? intro,
  })  : _user = user,
        _hostShort = host,
        _cwd = cwd,
        _intro = intro {
    // Emit the intro on the next microtask so listeners attach first.
    scheduleMicrotask(_playIntro);
  }

  final String _user;
  final String _hostShort;
  final String _cwd;

  /// Optional scripted lines already-"run" before the first live prompt. Each
  /// entry is echoed as a typed command followed by its [_respond] output.
  final List<String>? _intro;

  // ANSI colors (works in xterm): bright green user@host, blue cwd.
  static const String _reset = '\x1b[0m';
  static const String _green = '\x1b[1;32m';
  static const String _blue = '\x1b[1;34m';
  static const String _dim = '\x1b[2m';

  final StreamController<String> _controller =
      StreamController<String>.broadcast();
  final StringBuffer _line = StringBuffer();
  bool _introDone = false;
  bool _closed = false;

  String get _prompt =>
      '$_green$_user@$_hostShort$_reset:$_blue$_cwd$_reset\$ ';

  @override
  Stream<String> get output => _controller.stream;

  void _emit(String s) {
    if (!_closed) _controller.add(s);
  }

  /// Auto-plays a couple of already-"run" commands then a fresh prompt, so the
  /// terminal looks alive immediately for screenshots.
  Future<void> _playIntro() async {
    final List<String> script = _intro ?? const <String>['whoami', 'server list'];

    _emit('${_dim}Server Manager — interactive shell (demo)$_reset\r\n');
    await Future<void>.delayed(const Duration(milliseconds: 250));

    for (final String cmd in script) {
      _emit(_prompt);
      await Future<void>.delayed(const Duration(milliseconds: 500));
      _emit('$cmd\r\n');
      await Future<void>.delayed(const Duration(milliseconds: 250));
      final String out = _respond(cmd);
      if (out.isNotEmpty) _emit('$out\r\n');
    }

    _emit(_prompt);
    _introDone = true;
  }

  @override
  void write(String data) {
    // Until the scripted intro finishes, swallow input so it doesn't interleave.
    if (!_introDone) return;
    for (final int code in data.runes) {
      switch (code) {
        case 0x0d: // Enter (\r)
        case 0x0a: // Newline (\n)
          _emit('\r\n');
          _runLine(_line.toString());
          _line.clear();
          _emit(_prompt);
        case 0x7f: // Backspace (DEL)
        case 0x08: // Backspace (BS)
          final String current = _line.toString();
          if (current.isNotEmpty) {
            _line
              ..clear()
              ..write(current.substring(0, current.length - 1));
            // Erase one char on screen.
            _emit('\b \b');
          }
        default:
          final String ch = String.fromCharCode(code);
          _line.write(ch);
          _emit(ch); // local echo
      }
    }
  }

  void _runLine(String raw) {
    final String line = raw.trim();
    if (line.isEmpty) return;
    final String out = _respond(line);
    if (out.isNotEmpty) _emit('$out\r\n');
  }

  /// Returns the (multi-line, \r\n-joined) response body for [line].
  String _respond(String line) {
    final List<String> parts = line.split(RegExp(r'\s+'));
    final String cmd = parts.first;
    final List<String> args = parts.skip(1).toList();

    switch (cmd) {
      case 'ls':
        return 'sites.index  servers  config';
      case 'whoami':
        return _user;
      case 'pwd':
        return _cwd == '~' ? '/home/$_user' : _cwd;
      case 'git':
        if (args.isNotEmpty && args.first == 'log') {
          return 'a77b3e1 Tighten checkout rate limiting';
        }
        if (args.isNotEmpty && args.first == 'status') {
          return 'On branch main\r\nnothing to commit, working tree clean';
        }
        return 'usage: git <log|status|pull> ...';
      case 'php':
        if (args.isNotEmpty && args.first == 'artisan') {
          if (args.length >= 2 && args[1] == '--version') {
            return 'Laravel Framework 11.9.2';
          }
          return 'Laravel Framework 11.9.2 (artisan)';
        }
        return 'PHP 8.3.8 (cli)';
      case 'uname':
        return 'Linux $_hostShort 6.8.0-45-generic #45-Ubuntu SMP '
            'x86_64 GNU/Linux';
      case 'echo':
        return args.join(' ');
      case 'server':
        if (args.isNotEmpty && args.first == 'list') {
          return _serverListTable();
        }
        return 'usage: server <list|update|rollback> ...';
      case 'clear':
        // Clear screen + home cursor.
        return '\x1b[2J\x1b[H';
      default:
        return 'bash: $cmd: command not found';
    }
  }

  /// A compact table of the demo sites, reusing [DemoData].
  String _serverListTable() {
    final StringBuffer b = StringBuffer();
    b.write('${_dim}DOMAIN                 SERVER   FRAMEWORK   HEALTH$_reset');
    for (final Map<String, dynamic> s in DemoData.sites) {
      final String domain = (s['domain'] as String).padRight(22);
      final String server = (s['server'] as String).padRight(8);
      final String fw = (s['framework'] as String).padRight(11);
      final String health = s['health'] as String;
      b.write('\r\n$domain $server $fw $health');
    }
    return b.toString();
  }

  @override
  void resize(int columns, int rows) {
    // No-op: the simulated shell ignores geometry.
  }

  @override
  void close() {
    _closed = true;
    if (!_controller.isClosed) _controller.close();
  }
}
