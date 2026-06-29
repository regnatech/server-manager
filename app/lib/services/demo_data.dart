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

  /// A realistic `git log` graph (item shape matches `GitCommit.fromJson`).
  /// Includes a merge commit (two parents) and a tag/branch ref mix. [head]
  /// names the branch the `HEAD ->` ref points at; [extraTags] are demo-created
  /// tags appended to the tip commit's refs.
  static List<Map<String, dynamic>> gitLog({
    String head = 'main',
    List<String> extraTags = const <String>[],
  }) =>
      <Map<String, dynamic>>[
        <String, dynamic>{
          'hash': 'a77b3e1f4c8d2b9e0a1f6c7d8e9f0a1b2c3d4e5f',
          'short': 'a77b3e1',
          'parents': <String>['4f1c2a9'],
          'author': 'Dana Ortiz',
          'date': '2026-06-29 18:42',
          'relative': '2h ago',
          'subject': 'Fix checkout rate limiting',
          'refs': <String>[
            'HEAD -> $head',
            'origin/main',
            for (final String t in extraTags) 'tag: $t',
          ],
        },
        <String, dynamic>{
          'hash': '4f1c2a9b8e7d6c5a4b3c2d1e0f9a8b7c6d5e4f3a',
          'short': '4f1c2a9',
          'parents': <String>['9b2d11c', 'c0ffee1'],
          'author': 'Dana Ortiz',
          'date': '2026-06-29 12:10',
          'relative': '8h ago',
          'subject': "Merge branch 'develop'",
          'refs': <String>['tag: v1.4.0'],
        },
        <String, dynamic>{
          'hash': 'c0ffee1a2b3c4d5e6f7a8b9c0d1e2f3a4b5c6d7e',
          'short': 'c0ffee1',
          'parents': <String>['7a3e9d2'],
          'author': 'Priya Nair',
          'date': '2026-06-28 21:14',
          'relative': 'yesterday',
          'subject': 'Add idempotency keys to webhook handler',
          'refs': <String>[],
        },
        <String, dynamic>{
          'hash': '9b2d11c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9',
          'short': '9b2d11c',
          'parents': <String>['7a3e9d2'],
          'author': 'Marco Steele',
          'date': '2026-06-28 16:03',
          'relative': 'yesterday',
          'subject': 'Bump deps (laravel/framework 11.9, vite 5.3)',
          'refs': <String>[],
        },
        <String, dynamic>{
          'hash': '7a3e9d2b1c0f9e8d7c6b5a4f3e2d1c0b9a8f7e6d',
          'short': '7a3e9d2',
          'parents': <String>['1d5f8b0'],
          'author': 'Priya Nair',
          'date': '2026-06-27 09:02',
          'relative': '2 days ago',
          'subject': 'Cache product listing query',
          'refs': <String>[],
        },
        <String, dynamic>{
          'hash': '1d5f8b0a9c8b7d6e5f4a3b2c1d0e9f8a7b6c5d4e',
          'short': '1d5f8b0',
          'parents': <String>['e2c4a77'],
          'author': 'Dana Ortiz',
          'date': '2026-06-26 14:48',
          'relative': '3 days ago',
          'subject': 'Refactor order state machine',
          'refs': <String>['tag: v1.3.2'],
        },
        <String, dynamic>{
          'hash': 'e2c4a77b6d5e4f3a2b1c0d9e8f7a6b5c4d3e2f1a',
          'short': 'e2c4a77',
          'parents': <String>['b9911aa'],
          'author': 'Marco Steele',
          'date': '2026-06-25 11:20',
          'relative': '4 days ago',
          'subject': 'Add database index to orders.created_at',
          'refs': <String>[],
        },
        <String, dynamic>{
          'hash': 'b9911aa0c1d2e3f4a5b6c7d8e9f0a1b2c3d4e5f6',
          'short': 'b9911aa',
          'parents': <String>[],
          'author': 'Priya Nair',
          'date': '2026-06-24 08:55',
          'relative': '5 days ago',
          'subject': 'Initial Laravel scaffolding',
          'refs': <String>[],
        },
      ];

  /// `git status` value (matches `GitStatus.fromJson`). [ahead] is overridden
  /// by [DemoCliService] once a push has run this session; [branch] follows the
  /// currently checked-out branch (e.g. after a `git branch` create).
  static Map<String, dynamic> gitStatus({
    int ahead = 2,
    String branch = 'main',
  }) =>
      <String, dynamic>{
        'branch': branch,
        'upstream': branch == 'main' ? 'origin/main' : '',
        'ahead': ahead,
        'behind': 0,
        'clean': false,
        'dirty': <String>[
          'app/Http/Kernel.php',
          'resources/views/home.blade.php',
        ],
      };

  /// `git branches` items (match `GitBranch.fromJson`). [current] is the
  /// checked-out branch; [extra] are demo-created local branches appended in
  /// order.
  static List<Map<String, dynamic>> gitBranches({
    String current = 'main',
    List<String> extra = const <String>[],
  }) {
    final List<String> locals = <String>[
      'main',
      'develop',
      'feature/checkout-v2',
      ...extra,
    ];
    return <Map<String, dynamic>>[
      for (final String name in locals)
        <String, dynamic>{
          'name': name,
          'current': name == current,
          'remote': false,
        },
      <String, dynamic>{'name': 'origin/main', 'current': false, 'remote': true},
      <String, dynamic>{
        'name': 'origin/develop',
        'current': false,
        'remote': true,
      },
    ];
  }

  /// Two realistic merge conflicts (item shape: path/ours/theirs/conflicted)
  /// produced when merging `develop` into `main` in the demo.
  static List<Map<String, dynamic>> gitConflicts() => <Map<String, dynamic>>[
        <String, dynamic>{
          'path': 'composer.json',
          'ours': '{\n'
              '    "require": {\n'
              '        "php": "^8.3",\n'
              '        "laravel/framework": "^11.9",\n'
              '        "laravel/sanctum": "^4.0"\n'
              '    }\n'
              '}\n',
          'theirs': '{\n'
              '    "require": {\n'
              '        "php": "^8.3",\n'
              '        "laravel/framework": "^11.10",\n'
              '        "laravel/horizon": "^5.24"\n'
              '    }\n'
              '}\n',
          'conflicted': '{\n'
              '    "require": {\n'
              '        "php": "^8.3",\n'
              '<<<<<<< HEAD\n'
              '        "laravel/framework": "^11.9",\n'
              '        "laravel/sanctum": "^4.0"\n'
              '=======\n'
              '        "laravel/framework": "^11.10",\n'
              '        "laravel/horizon": "^5.24"\n'
              '>>>>>>> develop\n'
              '    }\n'
              '}\n',
        },
        <String, dynamic>{
          'path': 'resources/views/home.blade.php',
          'ours': '<x-layout>\n'
              '    <h1>Welcome back</h1>\n'
              '    <p>Your dashboard is ready.</p>\n'
              '</x-layout>\n',
          'theirs': '<x-layout>\n'
              '    <h1>Welcome to Clicketta</h1>\n'
              '    <p>Book tickets in seconds.</p>\n'
              '</x-layout>\n',
          'conflicted': '<x-layout>\n'
              '<<<<<<< HEAD\n'
              '    <h1>Welcome back</h1>\n'
              '    <p>Your dashboard is ready.</p>\n'
              '=======\n'
              '    <h1>Welcome to Clicketta</h1>\n'
              '    <p>Book tickets in seconds.</p>\n'
              '>>>>>>> develop\n'
              '</x-layout>\n',
        },
      ];

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

  /// The log file path the demo backend reports for a (domain, type) pair.
  static String logFile(String domain, String type) {
    switch (type) {
      case 'nginx':
        return '/var/log/nginx/$domain.access.log';
      case 'php':
        return '/var/log/php8.3-fpm.log';
      case 'queue':
        return '/var/www/$domain/storage/logs/worker.log';
      case 'laravel':
      default:
        return '/var/www/$domain/storage/logs/laravel.log';
    }
  }

  /// ~40 realistic recent log lines for the one-shot `logs` view, varying by
  /// [type] (Laravel app log, nginx access log, php-fpm, queue worker).
  static List<String> logLines(String domain, String type) {
    switch (type) {
      case 'nginx':
        return <String>[
          '203.0.113.7 - - [29/Jun/2026:10:12:01 +0000] "GET / HTTP/2.0" 200 8421 "-" "Mozilla/5.0"',
          '203.0.113.7 - - [29/Jun/2026:10:12:01 +0000] "GET /css/app.css HTTP/2.0" 200 18233 "-" "Mozilla/5.0"',
          '198.51.100.22 - - [29/Jun/2026:10:12:03 +0000] "POST /checkout HTTP/2.0" 302 0 "https://$domain/cart" "Mozilla/5.0"',
          '198.51.100.22 - - [29/Jun/2026:10:12:03 +0000] "GET /checkout/success HTTP/2.0" 200 5120 "-" "Mozilla/5.0"',
          '203.0.113.91 - - [29/Jun/2026:10:12:05 +0000] "GET /api/products HTTP/2.0" 200 44210 "-" "okhttp/4.12"',
          '203.0.113.91 - - [29/Jun/2026:10:12:06 +0000] "GET /favicon.ico HTTP/2.0" 304 0 "-" "okhttp/4.12"',
          '45.146.0.18 - - [29/Jun/2026:10:12:08 +0000] "GET /.env HTTP/1.1" 403 153 "-" "curl/8.4.0"',
          '45.146.0.18 - - [29/Jun/2026:10:12:08 +0000] "GET /wp-login.php HTTP/1.1" 404 209 "-" "curl/8.4.0"',
          '203.0.113.7 - - [29/Jun/2026:10:12:10 +0000] "GET /dashboard HTTP/2.0" 200 13302 "-" "Mozilla/5.0"',
          '192.0.2.55 - - [29/Jun/2026:10:12:12 +0000] "POST /api/webhooks/stripe HTTP/2.0" 200 12 "-" "Stripe/1.0"',
          '203.0.113.7 - - [29/Jun/2026:10:12:14 +0000] "GET /orders/8841 HTTP/2.0" 200 9981 "-" "Mozilla/5.0"',
          '198.51.100.7 - - [29/Jun/2026:10:12:15 +0000] "GET /health HTTP/1.1" 200 2 "-" "ELB-HealthChecker/2.0"',
          '203.0.113.7 - - [29/Jun/2026:10:12:18 +0000] "GET /assets/app.js HTTP/2.0" 200 220148 "-" "Mozilla/5.0"',
          '203.0.113.44 - - [29/Jun/2026:10:12:20 +0000] "GET /search?q=tickets HTTP/2.0" 200 6620 "-" "Mozilla/5.0"',
          '198.51.100.22 - - [29/Jun/2026:10:12:21 +0000] "GET /api/products/214 HTTP/2.0" 500 482 "-" "okhttp/4.12"',
          '203.0.113.7 - - [29/Jun/2026:10:12:24 +0000] "GET / HTTP/2.0" 200 8421 "-" "Mozilla/5.0"',
          '192.0.2.55 - - [29/Jun/2026:10:12:26 +0000] "POST /api/webhooks/stripe HTTP/2.0" 200 12 "-" "Stripe/1.0"',
          '203.0.113.7 - - [29/Jun/2026:10:12:28 +0000] "GET /orders HTTP/2.0" 200 11203 "-" "Mozilla/5.0"',
          '45.146.0.18 - - [29/Jun/2026:10:12:30 +0000] "GET /admin HTTP/1.1" 403 153 "-" "curl/8.4.0"',
          '203.0.113.7 - - [29/Jun/2026:10:12:33 +0000] "GET /logout HTTP/2.0" 302 0 "-" "Mozilla/5.0"',
        ];
      case 'php':
        return <String>[
          '[29-Jun-2026 10:11:40] NOTICE: fpm is running, pid 1442',
          '[29-Jun-2026 10:11:40] NOTICE: ready to handle connections',
          '[29-Jun-2026 10:12:03] WARNING: [pool www] server reached pm.max_children setting (10), consider raising it',
          '[29-Jun-2026 10:12:05] NOTICE: [pool www] child 4821 started',
          '[29-Jun-2026 10:12:21] WARNING: [pool www] child 4719, script \'/var/www/$domain/public/index.php\' (request: "GET /api/products/214") execution timed out (31.02 sec), terminating',
          '[29-Jun-2026 10:12:21] WARNING: [pool www] child 4719 exited on signal 15 (SIGTERM) after 902.41 seconds from start',
          '[29-Jun-2026 10:12:21] NOTICE: [pool www] child 4901 started',
          '[29-Jun-2026 10:12:48] NOTICE: [pool www] child 4602 exited with code 0 after 1810.55 seconds from start',
          '[29-Jun-2026 10:12:48] NOTICE: [pool www] child 4977 started',
        ];
      case 'queue':
        return <String>[
          '[2026-06-29 10:11:31] production.INFO: Processing App\\Jobs\\SendOrderConfirmation',
          '[2026-06-29 10:11:31] production.INFO: Processed  App\\Jobs\\SendOrderConfirmation',
          '[2026-06-29 10:11:44] production.INFO: Processing App\\Jobs\\GenerateInvoicePdf',
          '[2026-06-29 10:11:46] production.INFO: Processed  App\\Jobs\\GenerateInvoicePdf',
          '[2026-06-29 10:12:02] production.INFO: Processing App\\Jobs\\SyncInventory',
          '[2026-06-29 10:12:09] production.ERROR: Failed   App\\Jobs\\SyncInventory',
          '[2026-06-29 10:12:09] production.ERROR: GuzzleHttp\\Exception\\ConnectException: cURL error 28: Operation timed out after 10001 ms',
          '   at /var/www/$domain/vendor/guzzlehttp/guzzle/src/Handler/CurlFactory.php:211',
          '   at /var/www/$domain/app/Jobs/SyncInventory.php:48',
          '[2026-06-29 10:12:09] production.WARNING: App\\Jobs\\SyncInventory will be retried (attempt 2/3)',
          '[2026-06-29 10:12:24] production.INFO: Processing App\\Jobs\\SyncInventory',
          '[2026-06-29 10:12:27] production.INFO: Processed  App\\Jobs\\SyncInventory',
          '[2026-06-29 10:12:40] production.INFO: Processing App\\Jobs\\SendOrderConfirmation',
          '[2026-06-29 10:12:41] production.INFO: Processed  App\\Jobs\\SendOrderConfirmation',
        ];
      case 'laravel':
      default:
        return <String>[
          '[2026-06-29 10:11:58] production.INFO: schedule:run completed in 0.42s',
          '[2026-06-29 10:12:01] production.INFO: User authenticated {"user_id":4821,"ip":"203.0.113.7"}',
          '[2026-06-29 10:12:02] production.DEBUG: Cache hit for key products.featured',
          '[2026-06-29 10:12:03] production.INFO: Order placed {"order_id":8841,"total":129.00,"currency":"USD"}',
          '[2026-06-29 10:12:03] production.INFO: Dispatched App\\Jobs\\SendOrderConfirmation onto queue [default]',
          '[2026-06-29 10:12:04] production.WARNING: Slow query (1842ms): select * from `orders` where `status` = ? order by `created_at` desc',
          '[2026-06-29 10:12:06] production.INFO: Stripe webhook received {"type":"payment_intent.succeeded","id":"pi_3PqL"}',
          '[2026-06-29 10:12:08] production.NOTICE: Rate limiter hit for 45.146.0.18 on route api.login',
          '[2026-06-29 10:12:12] production.DEBUG: Mail queued {"mailable":"OrderShipped","to":"dana@example.com"}',
          '[2026-06-29 10:12:15] production.INFO: Cache warmed: 214 product entries',
          '[2026-06-29 10:12:21] production.ERROR: Call to a member function format() on null',
          '[2026-06-29 10:12:21] production.ERROR: [stacktrace]',
          '#0 /var/www/$domain/app/Http/Controllers/ProductController.php(88): App\\Support\\Money::display(NULL)',
          '#1 /var/www/$domain/vendor/laravel/framework/src/Illuminate/Routing/Controller.php(54): App\\Http\\Controllers\\ProductController->show(214)',
          '#2 /var/www/$domain/vendor/laravel/framework/src/Illuminate/Routing/ControllerDispatcher.php(43): Illuminate\\Routing\\Controller->callAction()',
          '#3 {main}',
          '[2026-06-29 10:12:22] production.CRITICAL: Uncaught TypeError thrown while rendering /api/products/214',
          '[2026-06-29 10:12:24] production.INFO: Exception reported to Sentry {"event_id":"a1b2c3d4"}',
          '[2026-06-29 10:12:26] production.INFO: Stripe webhook received {"type":"charge.refunded","id":"ch_3PqM"}',
          '[2026-06-29 10:12:28] production.DEBUG: Session regenerated for user 4821',
          '[2026-06-29 10:12:30] production.WARNING: Deprecated config value mail.driver; use mail.default',
          '[2026-06-29 10:12:31] production.INFO: User logged out {"user_id":4821}',
          '[2026-06-29 10:12:33] production.INFO: schedule:run completed in 0.39s',
          '[2026-06-29 10:12:36] production.DEBUG: Cache hit for key settings.global',
          '[2026-06-29 10:12:38] production.INFO: Health check GET / -> 200 in 86ms',
          '[2026-06-29 10:12:40] production.INFO: Order placed {"order_id":8842,"total":58.50,"currency":"USD"}',
          '[2026-06-29 10:12:40] production.INFO: Dispatched App\\Jobs\\SendOrderConfirmation onto queue [default]',
          '[2026-06-29 10:12:42] production.DEBUG: Eager loaded relations [items, customer] for order 8842',
          '[2026-06-29 10:12:44] production.WARNING: Low stock for SKU TIX-GA-2026 (3 remaining)',
          '[2026-06-29 10:12:46] production.INFO: Invalidated cache tag [products]',
          '[2026-06-29 10:12:48] production.INFO: Backup snapshot scheduled for 03:00',
          '[2026-06-29 10:12:50] production.DEBUG: Queue size default=2 mail=0',
          '[2026-06-29 10:12:52] production.INFO: Stripe webhook received {"type":"payout.paid","id":"po_3PqN"}',
          '[2026-06-29 10:12:54] production.NOTICE: Feature flag checkout_v2 enabled for 5% of traffic',
          '[2026-06-29 10:12:56] production.INFO: User authenticated {"user_id":5012,"ip":"203.0.113.44"}',
          '[2026-06-29 10:12:58] production.DEBUG: Cache hit for key products.featured',
          '[2026-06-29 10:13:00] production.INFO: schedule:run completed in 0.41s',
          '[2026-06-29 10:13:02] production.INFO: Order placed {"order_id":8843,"total":212.75,"currency":"USD"}',
          '[2026-06-29 10:13:04] production.INFO: Cache warmed: 214 product entries',
        ];
    }
  }

  /// A handful of live-tail lines for the demo `logs -f` follow stream, by type.
  static List<String> logTail(String domain, String type) {
    switch (type) {
      case 'nginx':
        return <String>[
          '203.0.113.7 - - [29/Jun/2026:10:13:06 +0000] "GET /orders HTTP/2.0" 200 11203 "-" "Mozilla/5.0"',
          '198.51.100.22 - - [29/Jun/2026:10:13:08 +0000] "POST /checkout HTTP/2.0" 302 0 "-" "Mozilla/5.0"',
          '45.146.0.18 - - [29/Jun/2026:10:13:10 +0000] "GET /.git/config HTTP/1.1" 403 153 "-" "curl/8.4.0"',
          '203.0.113.91 - - [29/Jun/2026:10:13:12 +0000] "GET /api/products HTTP/2.0" 200 44210 "-" "okhttp/4.12"',
          '192.0.2.55 - - [29/Jun/2026:10:13:14 +0000] "POST /api/webhooks/stripe HTTP/2.0" 200 12 "-" "Stripe/1.0"',
          '203.0.113.7 - - [29/Jun/2026:10:13:16 +0000] "GET /dashboard HTTP/2.0" 200 13302 "-" "Mozilla/5.0"',
          '198.51.100.22 - - [29/Jun/2026:10:13:18 +0000] "GET /api/products/214 HTTP/2.0" 500 482 "-" "okhttp/4.12"',
          '203.0.113.44 - - [29/Jun/2026:10:13:20 +0000] "GET /search?q=tickets HTTP/2.0" 200 6620 "-" "Mozilla/5.0"',
        ];
      case 'php':
        return <String>[
          '[29-Jun-2026 10:13:05] NOTICE: [pool www] child 4977 started',
          '[29-Jun-2026 10:13:09] WARNING: [pool www] server reached pm.max_children setting (10)',
          '[29-Jun-2026 10:13:14] NOTICE: [pool www] child 4602 exited with code 0',
          '[29-Jun-2026 10:13:18] NOTICE: [pool www] child 5012 started',
          '[29-Jun-2026 10:13:22] WARNING: [pool www] child 4901 execution timed out (31.0 sec)',
          '[29-Jun-2026 10:13:23] NOTICE: [pool www] child 5040 started',
          '[29-Jun-2026 10:13:28] NOTICE: [pool www] child 4977 exited with code 0',
          '[29-Jun-2026 10:13:31] NOTICE: [pool www] child 5061 started',
        ];
      case 'queue':
        return <String>[
          '[2026-06-29 10:13:05] production.INFO: Processing App\\Jobs\\SendOrderConfirmation',
          '[2026-06-29 10:13:06] production.INFO: Processed  App\\Jobs\\SendOrderConfirmation',
          '[2026-06-29 10:13:12] production.INFO: Processing App\\Jobs\\GenerateInvoicePdf',
          '[2026-06-29 10:13:14] production.INFO: Processed  App\\Jobs\\GenerateInvoicePdf',
          '[2026-06-29 10:13:20] production.INFO: Processing App\\Jobs\\SyncInventory',
          '[2026-06-29 10:13:24] production.ERROR: Failed   App\\Jobs\\SyncInventory (cURL error 28: timed out)',
          '[2026-06-29 10:13:24] production.WARNING: App\\Jobs\\SyncInventory will be retried (attempt 2/3)',
          '[2026-06-29 10:13:31] production.INFO: Processed  App\\Jobs\\SyncInventory',
        ];
      case 'laravel':
      default:
        return <String>[
          '[2026-06-29 10:13:06] production.INFO: Order placed {"order_id":8844,"total":74.00,"currency":"USD"}',
          '[2026-06-29 10:13:08] production.DEBUG: Cache hit for key products.featured',
          '[2026-06-29 10:13:11] production.INFO: Stripe webhook received {"type":"payment_intent.succeeded","id":"pi_3PqP"}',
          '[2026-06-29 10:13:14] production.WARNING: Slow query (1320ms): select count(*) from `sessions`',
          '[2026-06-29 10:13:17] production.ERROR: Call to a member function format() on null',
          '[2026-06-29 10:13:20] production.INFO: User authenticated {"user_id":5012,"ip":"203.0.113.44"}',
          '[2026-06-29 10:13:23] production.INFO: Cache warmed: 214 product entries',
          '[2026-06-29 10:13:26] production.INFO: schedule:run completed in 0.40s',
        ];
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

  /// Initial atomic-release timestamps for a demo site (newest last). The first
  /// entry of [releaseTimestamps] reversed is the current release.
  static const List<String> releaseTimestamps = <String>[
    '2026-06-29_06-48-12',
    '2026-06-28_21-14-03',
    '2026-06-27_09-02-55',
    '2026-06-26_14-48-31',
    '2026-06-25_11-20-09',
  ];

  /// A two-site multi-deploy (`update --all`) run: a section + a couple of
  /// steps per demo site, then the `deploy_all` summary.
  static List<String> updateAllDomains() => <String>[
        for (final Map<String, dynamic> s in sites.take(2))
          s['domain'] as String,
      ];

  /// The `diff` payload (matches the `deploy_diff` contract). Reuses the demo
  /// git commit style for [commits]; lists a couple of pending migrations.
  static Map<String, dynamic> deployDiff(String domain) {
    final List<Map<String, dynamic>> log = gitLog();
    return <String, dynamic>{
      'branch': 'main',
      'from': '4f1c2a9',
      'to': 'a77b3e1',
      'ahead': 3,
      'commits': log.take(3).toList(),
      'migrations': <String>[
        '2026_06_25_140000_add_index_to_orders.php',
        '2026_06_28_090000_create_webhook_events_table.php',
      ],
    };
  }

  /// Four audit-posture snapshots over time with a decreasing total, for the
  /// `audit history` view (newest last).
  static List<Map<String, dynamic>> auditHistory(String scope) =>
      <Map<String, dynamic>>[
        <String, dynamic>{
          'at': '2026-06-12 09:00',
          'critical': 1,
          'high': 3,
          'medium': 3,
          'low': 1,
          'total': 8,
        },
        <String, dynamic>{
          'at': '2026-06-19 09:00',
          'critical': 0,
          'high': 2,
          'medium': 3,
          'low': 1,
          'total': 6,
        },
        <String, dynamic>{
          'at': '2026-06-26 09:00',
          'critical': 0,
          'high': 2,
          'medium': 2,
          'low': 1,
          'total': 5,
        },
        <String, dynamic>{
          'at': '2026-06-29 09:00',
          'critical': 0,
          'high': 1,
          'medium': 1,
          'low': 1,
          'total': 3,
        },
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

  /// Domains pushed in this demo session, so a subsequent [gitStatus] reports
  /// `ahead:0` and the working tree looks freshly synced after a push+deploy.
  static final Set<String> _pushed = <String>{};

  /// Demo-session Git mutations, keyed by domain: the currently checked-out
  /// branch, extra local branches created, and extra tags created. Lets a
  /// `git branch`/`git tag` visibly update subsequent log/status/branches.
  static final Map<String, String> _currentBranch = <String, String>{};
  static final Map<String, List<String>> _createdBranches =
      <String, List<String>>{};
  static final Map<String, List<String>> _createdTags = <String, List<String>>{};

  /// Paths still unresolved in an in-progress demo merge, keyed by domain. Set
  /// when [gitMerge] hits conflicts; decremented by [gitResolve]; cleared by
  /// [gitMergeContinue]/[gitMergeAbort].
  static final Map<String, Set<String>> _conflicts = <String, Set<String>>{};

  /// Whether each notification destination is configured in this demo session.
  /// Mutated by [notifySetSlack]/[notifySetTelegram]/[notifyOff] so a
  /// subsequent [notifyStatus] reflects the change. Starts unconfigured so the
  /// settings form is the focus of an SM_ROUTE=/settings screenshot.
  static bool _slackConfigured = false;
  static bool _telegramConfigured = false;

  /// Per-domain atomic-release timestamps (newest first), so a demo
  /// `release deploy` / `release rollback` visibly mutates a subsequent
  /// `release list`. Seeded lazily from [DemoData.releaseTimestamps].
  static final Map<String, List<String>> _releases = <String, List<String>>{};

  /// Current (active) release timestamp per domain, mutated by rollback/deploy.
  static final Map<String, String> _currentRelease = <String, String>{};

  /// Returns the demo releases for [domain], seeding from the canned list on
  /// first access. Index 0 is the newest; [_currentRelease] tracks the active.
  static List<String> _releasesFor(String domain) {
    return _releases.putIfAbsent(
      domain,
      () => List<String>.from(DemoData.releaseTimestamps),
    );
  }

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
  Stream<CliEvent> logs(String domain, {String? type, int lines = 200}) async* {
    final String t = type ?? 'laravel';
    final String file = DemoData.logFile(domain, t);
    await Future<void>.delayed(_shortGap);
    yield DataEvent(
      kind: 'logs_meta',
      value: <String, dynamic>{'type': t, 'file': file},
    );
    await Future<void>.delayed(_shortGap);
    final List<String> all = DemoData.logLines(domain, t);
    yield DataEvent(
      kind: 'logs',
      value: <String, dynamic>{
        'type': t,
        'file': file,
        'lines': all.length > lines ? all.sublist(all.length - lines) : all,
      },
    );
    yield const DoneEvent(ok: true);
  }

  @override
  Stream<CliEvent> logsFollow(String domain, {String? type}) async* {
    final String t = type ?? 'laravel';
    final String file = DemoData.logFile(domain, t);
    await Future<void>.delayed(_shortGap);
    yield DataEvent(
      kind: 'logs_meta',
      value: <String, dynamic>{'type': t, 'file': file},
    );
    // Emit a burst of tail lines with visible gaps so the live tail appends on
    // screen, then keep the stream open briefly before completing.
    for (final String line in DemoData.logTail(domain, t)) {
      await Future<void>.delayed(const Duration(milliseconds: 700));
      yield LogEvent(level: 'info', msg: line);
    }
    await Future<void>.delayed(const Duration(seconds: 2));
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
  Stream<CliEvent> auditFixAll([String? domain]) async* {
    final bool server = domain == null || domain.isEmpty;
    yield BannerEvent(
      label: server ? 'Fixing all findings on the server' : 'Fixing all findings on $domain',
    );
    yield const SectionEvent(label: 'Applying fixes');
    final List<Map<String, dynamic>> source = server
        ? DemoData.serverAuditFindings()
        : DemoData.auditFindings(domain);
    // Every currently-unfixed, auto-fixable finding in scope.
    final List<String> ids = <String>[
      for (final Map<String, dynamic> f in source)
        if ((f['fixable'] as bool? ?? false) &&
            !_fixedAuditIds.contains(f['id'] as String))
          f['id'] as String,
    ];
    int applied = 0;
    for (final String id in ids) {
      final String label = DemoData.auditFixLabel(id);
      yield StepStart(id: 'fixall-$id', label: label);
      await Future<void>.delayed(const Duration(milliseconds: 500));
      yield StepEnd(id: 'fixall-$id', ok: true, dur: 0.5);
      _fixedAuditIds.add(id);
      applied++;
      await Future<void>.delayed(const Duration(milliseconds: 120));
    }
    yield DataEvent(
      kind: 'audit_fixall',
      value: <String, dynamic>{'applied': applied, 'failed': 0},
    );
    yield const DoneEvent(ok: true);
  }

  String _branchOf(String domain) => _currentBranch[domain] ?? 'main';

  @override
  Stream<CliEvent> gitLog(String domain) async* {
    yield BannerEvent(label: 'Reading git history for $domain');
    await Future<void>.delayed(_shortGap);
    yield DataEvent(
      kind: 'git_log',
      items: DemoData.gitLog(
        head: _branchOf(domain),
        extraTags: _createdTags[domain] ?? const <String>[],
      ),
    );
    yield const DoneEvent(ok: true);
  }

  @override
  Stream<CliEvent> gitStatus(String domain) async* {
    await Future<void>.delayed(_shortGap);
    yield DataEvent(
      kind: 'git_status',
      value: DemoData.gitStatus(
        ahead: _pushed.contains(domain) ? 0 : 2,
        branch: _branchOf(domain),
      ),
    );
    yield const DoneEvent(ok: true);
  }

  @override
  Stream<CliEvent> gitBranches(String domain) async* {
    await Future<void>.delayed(_shortGap);
    yield DataEvent(
      kind: 'git_branches',
      items: DemoData.gitBranches(
        current: _branchOf(domain),
        extra: _createdBranches[domain] ?? const <String>[],
      ),
    );
    yield const DoneEvent(ok: true);
  }

  @override
  Stream<CliEvent> gitPushDeploy(String domain) async* {
    yield BannerEvent(label: 'Pushing & deploying $domain');
    yield const StepStart(id: 'push', label: 'Pushing main to origin');
    await Future<void>.delayed(const Duration(milliseconds: 700));
    yield const LogEvent(level: 'ok', msg: 'main -> main (2 commits)');
    yield const StepEnd(id: 'push', ok: true, dur: 0.7);
    _pushed.add(domain);
    // Reuse the standard deploy sequence so the timeline animates identically.
    // Skip the recorded banner/done — they're emitted around this run already.
    yield* _replay(_deployBody(domain));
    yield const DoneEvent(ok: true);
  }

  @override
  Stream<CliEvent> gitDeploy(String domain, String branch) async* {
    yield BannerEvent(label: 'Deploying $branch to $domain');
    for (final (String, String) s in <(String, String)>[
      ('fetch', 'Fetching origin'),
      ('checkout', 'Checking out $branch'),
      ('pull', 'Pulling $branch'),
    ]) {
      yield StepStart(id: s.$1, label: s.$2);
      await Future<void>.delayed(const Duration(milliseconds: 500));
      yield StepEnd(id: s.$1, ok: true, dur: 0.5);
      await Future<void>.delayed(_shortGap);
    }
    yield* _replay(_deployBody(domain));
    yield const DoneEvent(ok: true);
  }

  /// The recorded deploy steps with the leading banner and trailing done
  /// stripped, so a push/branch-deploy can wrap them in its own framing.
  static List<CliEvent> _deployBody(String domain) =>
      DemoData.deployEvents(domain)
          .where((CliEvent e) => e is! BannerEvent && e is! DoneEvent)
          .toList();

  @override
  Stream<CliEvent> gitCreateBranch(String domain, String name) async* {
    yield BannerEvent(label: 'Creating branch $name on $domain');
    yield StepStart(id: 'branch', label: 'Creating & checking out $name');
    await Future<void>.delayed(const Duration(milliseconds: 650));
    yield StepEnd(id: 'branch', ok: true, dur: 0.6);
    // Record so subsequent branches/log/status reflect the new HEAD.
    (DemoCliService._createdBranches[domain] ??= <String>[]).add(name);
    DemoCliService._currentBranch[domain] = name;
    await Future<void>.delayed(const Duration(milliseconds: 120));
    yield const DoneEvent(ok: true);
  }

  @override
  Stream<CliEvent> gitCreateTag(String domain, String name,
      {String? message}) async* {
    yield BannerEvent(label: 'Tagging $domain');
    yield StepStart(id: 'tag', label: 'Creating tag $name');
    await Future<void>.delayed(const Duration(milliseconds: 500));
    yield StepEnd(id: 'tag', ok: true, dur: 0.5);
    yield StepStart(id: 'tag-push', label: 'Pushing tag $name to origin');
    await Future<void>.delayed(const Duration(milliseconds: 600));
    yield StepEnd(id: 'tag-push', ok: true, dur: 0.6);
    (DemoCliService._createdTags[domain] ??= <String>[]).add(name);
    await Future<void>.delayed(const Duration(milliseconds: 120));
    yield const DoneEvent(ok: true);
  }

  @override
  Stream<CliEvent> gitCreatePr(String domain, String title,
      {String base = 'main'}) async* {
    yield BannerEvent(label: 'Opening pull request for $domain');
    final String branch = _branchOf(domain);
    yield StepStart(id: 'pr-push', label: 'Pushing $branch to origin');
    await Future<void>.delayed(const Duration(milliseconds: 600));
    yield StepEnd(id: 'pr-push', ok: true, dur: 0.6);
    yield StepStart(id: 'pr-create', label: 'Creating pull request (gh)');
    await Future<void>.delayed(const Duration(milliseconds: 700));
    yield StepEnd(id: 'pr-create', ok: true, dur: 0.7);
    await Future<void>.delayed(const Duration(milliseconds: 120));
    yield DataEvent(
      kind: 'pr',
      value: <String, dynamic>{
        'url': 'https://github.com/acme/clicketta/pull/42',
        'title': title,
        'base': base,
      },
    );
    yield const DoneEvent(ok: true);
  }

  @override
  Stream<CliEvent> gitMerge(String domain, String branch) async* {
    yield BannerEvent(label: 'Merging $branch into ${_branchOf(domain)}');
    yield StepStart(id: 'merge', label: 'Merging $branch');
    await Future<void>.delayed(const Duration(milliseconds: 700));
    // `develop` conflicts in the demo; everything else merges cleanly.
    if (branch == 'develop') {
      yield const StepEnd(
        id: 'merge',
        ok: false,
        dur: 0.7,
        err: 'merge conflicts',
      );
      yield const LogEvent(
        level: 'warn',
        msg: 'CONFLICT (content): 2 files need manual resolution',
      );
      final List<Map<String, dynamic>> conflicts = DemoData.gitConflicts();
      _conflicts[domain] = <String>{
        for (final Map<String, dynamic> c in conflicts) c['path'] as String,
      };
      await Future<void>.delayed(_shortGap);
      yield DataEvent(kind: 'git_conflicts', items: conflicts);
      yield const DoneEvent(ok: false);
      return;
    }
    yield const StepEnd(id: 'merge', ok: true, dur: 0.7);
    await Future<void>.delayed(_shortGap);
    yield DataEvent(kind: 'git_merge', value: <String, dynamic>{'clean': true});
    yield const DoneEvent(ok: true);
  }

  @override
  Stream<CliEvent> gitResolve(String domain, String path, String content) async* {
    yield StepStart(id: 'resolve', label: 'Resolving $path');
    await Future<void>.delayed(const Duration(milliseconds: 450));
    final Set<String> remaining = _conflicts[domain] ??= <String>{};
    remaining.remove(path);
    yield const StepEnd(id: 'resolve', ok: true, dur: 0.4);
    yield DataEvent(
      kind: 'git_resolved',
      value: <String, dynamic>{'path': path, 'remaining': remaining.length},
    );
    yield const DoneEvent(ok: true);
  }

  @override
  Stream<CliEvent> gitMergeContinue(String domain) async* {
    yield StepStart(id: 'merge-continue', label: 'Completing merge');
    await Future<void>.delayed(const Duration(milliseconds: 600));
    _conflicts.remove(domain);
    yield const StepEnd(id: 'merge-continue', ok: true, dur: 0.6);
    yield const DoneEvent(ok: true);
  }

  @override
  Stream<CliEvent> gitMergeAbort(String domain) async* {
    yield StepStart(id: 'merge-abort', label: 'Aborting merge');
    await Future<void>.delayed(const Duration(milliseconds: 400));
    _conflicts.remove(domain);
    yield const StepEnd(id: 'merge-abort', ok: true, dur: 0.4);
    yield const DoneEvent(ok: true);
  }

  @override
  Stream<CliEvent> notifyStatus() async* {
    await Future<void>.delayed(_shortGap);
    yield DataEvent(
      kind: 'notify',
      value: <String, dynamic>{
        'slack': _slackConfigured,
        'telegram': _telegramConfigured,
      },
    );
    yield const DoneEvent(ok: true);
  }

  @override
  Stream<CliEvent> notifySetSlack(String url) async* {
    yield const StepStart(id: 'notify-slack', label: 'Saving Slack webhook');
    await Future<void>.delayed(const Duration(milliseconds: 500));
    yield const StepEnd(id: 'notify-slack', ok: true, dur: 0.5);
    _slackConfigured = true;
    await Future<void>.delayed(const Duration(milliseconds: 120));
    yield const DoneEvent(ok: true);
  }

  @override
  Stream<CliEvent> notifySetTelegram(String token, String chat) async* {
    yield const StepStart(id: 'notify-telegram', label: 'Saving Telegram bot');
    await Future<void>.delayed(const Duration(milliseconds: 500));
    yield const StepEnd(id: 'notify-telegram', ok: true, dur: 0.5);
    _telegramConfigured = true;
    await Future<void>.delayed(const Duration(milliseconds: 120));
    yield const DoneEvent(ok: true);
  }

  @override
  Stream<CliEvent> notifyTest() async* {
    yield const StepStart(id: 'notify-test', label: 'Sending test notification');
    await Future<void>.delayed(const Duration(milliseconds: 600));
    yield const StepEnd(id: 'notify-test', ok: true, dur: 0.6);
    await Future<void>.delayed(const Duration(milliseconds: 120));
    yield const DoneEvent(ok: true);
  }

  @override
  Stream<CliEvent> notifyOff() async* {
    yield const StepStart(id: 'notify-off', label: 'Disabling notifications');
    await Future<void>.delayed(const Duration(milliseconds: 400));
    yield const StepEnd(id: 'notify-off', ok: true, dur: 0.4);
    _slackConfigured = false;
    _telegramConfigured = false;
    await Future<void>.delayed(const Duration(milliseconds: 120));
    yield const DoneEvent(ok: true);
  }

  @override
  Stream<CliEvent> uptimeAll() async* {
    await Future<void>.delayed(_shortGap);
    // Most sites up (200/301), one down to exercise the err StatusDot.
    final List<Map<String, dynamic>> items = <Map<String, dynamic>>[];
    final List<int> codes = <int>[200, 200, 301, 200, 200];
    final List<int> times = <int>[142, 88, 213, 47, 296];
    int i = 0;
    for (final Map<String, dynamic> s in DemoData.sites) {
      final String domain = s['domain'] as String;
      final bool down = (s['health'] as String?) == 'down';
      items.add(<String, dynamic>{
        'domain': domain,
        'url': 'https://$domain',
        'up': !down,
        'code': down ? 503 : codes[i % codes.length],
        'ms': down ? 0 : times[i % times.length],
      });
      i++;
    }
    yield DataEvent(kind: 'uptime', items: items);
    yield const DoneEvent(ok: true);
  }

  @override
  Stream<CliEvent> releaseList(String domain) async* {
    await Future<void>.delayed(_shortGap);
    final List<String> releases = _releasesFor(domain);
    final String current = _currentRelease[domain] ?? releases.first;
    yield DataEvent(
      kind: 'releases',
      value: <String, dynamic>{
        'current': current,
        'items': <Map<String, dynamic>>[
          for (final String name in releases)
            <String, dynamic>{'name': name, 'current': name == current},
        ],
      },
    );
    yield const DoneEvent(ok: true);
  }

  @override
  Stream<CliEvent> releaseRollback(String domain, [String? name]) async* {
    final List<String> releases = _releasesFor(domain);
    final String target = (name != null && name.isNotEmpty)
        ? name
        : (releases.length > 1 ? releases[1] : releases.first);
    yield BannerEvent(label: 'Rolling back $domain');
    yield StepStart(id: 'switch', label: 'Switching current → $target');
    await Future<void>.delayed(const Duration(milliseconds: 700));
    yield const StepEnd(id: 'switch', ok: true, dur: 0.7);
    yield const StepStart(id: 'reload', label: 'Reloading services');
    await Future<void>.delayed(const Duration(milliseconds: 500));
    yield const StepEnd(id: 'reload', ok: true, dur: 0.5);
    _currentRelease[domain] = target;
    await Future<void>.delayed(const Duration(milliseconds: 120));
    yield const DoneEvent(ok: true);
  }

  @override
  Stream<CliEvent> releaseDeploy(String domain) async* {
    final String ts = _newReleaseTimestamp();
    yield BannerEvent(label: 'Deploying $domain (atomic)');
    yield SectionEvent(label: 'Release $ts');
    for (final (String, String) s in <(String, String)>[
      ('clone', 'Cloning into releases/$ts'),
      ('build', 'Installing dependencies & building assets'),
      ('migrate', 'Running migrations'),
      ('switch', 'Switching current → $ts'),
      ('reload', 'Reloading PHP-FPM & workers'),
    ]) {
      yield StepStart(id: s.$1, label: s.$2);
      await Future<void>.delayed(const Duration(milliseconds: 620));
      yield StepEnd(id: s.$1, ok: true, dur: 0.6);
      await Future<void>.delayed(const Duration(milliseconds: 120));
    }
    // Prepend the new release as current so a re-list reflects it.
    _releasesFor(domain).insert(0, ts);
    _currentRelease[domain] = ts;
    yield const DoneEvent(ok: true);
  }

  /// A fresh release timestamp (current wall clock) for a demo atomic deploy.
  static String _newReleaseTimestamp() {
    final DateTime now = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${now.year}-${two(now.month)}-${two(now.day)}_'
        '${two(now.hour)}-${two(now.minute)}-${two(now.second)}';
  }

  @override
  Stream<CliEvent> deployDiff(String domain) async* {
    await Future<void>.delayed(_shortGap);
    yield DataEvent(kind: 'deploy_diff', value: DemoData.deployDiff(domain));
    yield const DoneEvent(ok: true);
  }

  @override
  Stream<CliEvent> updateAll({String? framework}) async* {
    yield BannerEvent(label: 'Deploying all sites');
    final List<String> domains = DemoData.updateAllDomains();
    int deployed = 0;
    for (final String domain in domains) {
      yield SectionEvent(label: '▶ $domain');
      for (final (String, String) s in <(String, String)>[
        ('pull-$domain', 'Pulling latest changes'),
        ('deploy-$domain', 'Building & switching release'),
      ]) {
        yield StepStart(id: s.$1, label: s.$2);
        await Future<void>.delayed(const Duration(milliseconds: 520));
        yield StepEnd(id: s.$1, ok: true, dur: 0.5);
        await Future<void>.delayed(const Duration(milliseconds: 120));
      }
      deployed++;
    }
    yield DataEvent(
      kind: 'deploy_all',
      value: <String, dynamic>{
        'total': domains.length,
        'deployed': deployed,
        'failed': 0,
      },
    );
    yield const DoneEvent(ok: true);
  }

  @override
  Stream<CliEvent> auditHistory([String? domain]) async* {
    await Future<void>.delayed(_shortGap);
    yield DataEvent(
      kind: 'audit_history',
      items: DemoData.auditHistory(domain ?? ''),
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
