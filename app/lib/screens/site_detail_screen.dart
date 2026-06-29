import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../models/site.dart';
import '../services/cli_service.dart';
import '../state/connection_provider.dart';
import '../state/deploy_provider.dart';
import '../state/sites_provider.dart';
import '../theme/app_theme.dart';
import '../transport/cli_event.dart';
import '../transport/platform.dart';
import '../widgets/app_button.dart';
import '../widgets/deploy_timeline.dart';
import '../widgets/framework_chip.dart';
import '../widgets/section_header.dart';
import '../widgets/status_dot.dart';

/// Tabbed management view for a single site. Deploy tab hosts the live
/// timeline; secondary tabs are scaffolded against the right CLI calls.
class SiteDetailScreen extends ConsumerStatefulWidget {
  const SiteDetailScreen({super.key, required this.domain});

  final String domain;

  @override
  ConsumerState<SiteDetailScreen> createState() => _SiteDetailScreenState();
}

class _SiteDetailScreenState extends ConsumerState<SiteDetailScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs =
      TabController(length: 6, vsync: this, initialIndex: _initialTabIndex());

  // Optional deep-link to a specific tab (used by demo/screenshot launches):
  // SM_TAB=overview|deploy|cron|workers|logs|ssl.
  static int _initialTabIndex() {
    const List<String> order = <String>[
      'overview', 'deploy', 'cron', 'workers', 'logs', 'ssl'
    ];
    final int i = order.indexOf((envVar('SM_TAB') ?? '').toLowerCase());
    return i < 0 ? 0 : i;
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final Site? site = ref.watch(siteByDomainProvider(widget.domain));

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => context.go('/dashboard'),
        ),
        title: Row(
          children: <Widget>[
            if (site != null) StatusDot(health: site.health),
            const SizedBox(width: Insets.sm),
            Hero(
              tag: 'site-title-${widget.domain}',
              child: Material(
                type: MaterialType.transparency,
                child: Text(widget.domain),
              ),
            ),
            if (site != null) ...<Widget>[
              const SizedBox(width: Insets.md),
              FrameworkChip(framework: site.framework),
            ],
          ],
        ),
        bottom: TabBar(
          controller: _tabs,
          isScrollable: true,
          tabs: const <Tab>[
            Tab(text: 'Overview', icon: Icon(Icons.dashboard_outlined)),
            Tab(text: 'Deploy', icon: Icon(Icons.rocket_launch_outlined)),
            Tab(text: 'Cron', icon: Icon(Icons.schedule_outlined)),
            Tab(text: 'Workers', icon: Icon(Icons.memory_outlined)),
            Tab(text: 'Logs', icon: Icon(Icons.article_outlined)),
            Tab(text: 'SSL', icon: Icon(Icons.lock_outline)),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabs,
        children: <Widget>[
          _OverviewTab(site: site, domain: widget.domain),
          _DeployTab(domain: widget.domain),
          _DataListTab(
            domain: widget.domain,
            kind: 'cron',
            emptyLabel: 'No scheduled tasks',
            builder: (CliService c) => c.cronList(widget.domain),
            columns: const <String>['schedule', 'command', 'last', 'status'],
          ),
          _DataListTab(
            domain: widget.domain,
            kind: 'workers',
            emptyLabel: 'No workers configured',
            builder: (CliService c) => c.workersList(widget.domain),
            columns: const <String>['name', 'procs', 'status'],
          ),
          _LogsTab(domain: widget.domain),
          _SslTab(domain: widget.domain),
        ],
      ),
    );
  }
}

// --- Overview ---------------------------------------------------------------

class _OverviewTab extends StatelessWidget {
  const _OverviewTab({required this.site, required this.domain});
  final Site? site;
  final String domain;

  @override
  Widget build(BuildContext context) {
    if (site == null) {
      return const Center(child: CircularProgressIndicator());
    }
    final ThemeData theme = Theme.of(context);
    final List<(String, String)> rows = <(String, String)>[
      ('Domain', site!.domain),
      ('Server', site!.server),
      ('Framework', site!.framework),
      ('TLS', site!.tls ? 'enabled' : 'disabled'),
      ('Health', site!.health ?? 'unknown'),
      ('Last deploy', site!.lastDeploy ?? 'never'),
    ];
    return ListView(
      padding: const EdgeInsets.all(Insets.lg),
      children: <Widget>[
        const SectionHeader(title: 'Overview'),
        const SizedBox(height: Insets.md),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(Insets.lg),
            child: Column(
              children: <Widget>[
                for (final (String, String) r in rows)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Row(
                      children: <Widget>[
                        SizedBox(
                          width: 140,
                          child: Text(
                            r.$1,
                            style: theme.textTheme.labelMedium?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                        Expanded(
                          child: SelectableText(
                            r.$2,
                            style: theme.textTheme.bodyMedium,
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

// --- Deploy -----------------------------------------------------------------

/// Domains whose demo auto-deploy has already fired (one-shot guard).
final Set<String> _autoDeployed = <String>{};

class _DeployTab extends ConsumerWidget {
  const _DeployTab({required this.domain});
  final String domain;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final DeployState state = ref.watch(deployProvider(domain));
    final DeployController controller =
        ref.read(deployProvider(domain).notifier);

    void startDeploy() {
      final Stream<CliEvent> events =
          ref.read(cliServiceProvider).deploy(domain);
      controller.start(events);
    }

    void startRollback() {
      final Stream<CliEvent> events =
          ref.read(cliServiceProvider).rollback(domain);
      controller.start(events);
    }

    // Demo/screenshot convenience: auto-kick a deploy once so the live timeline
    // can be observed without a manual click. Enabled via SM_AUTODEPLOY=1.
    if (envVar('SM_AUTODEPLOY') == '1' && _autoDeployed.add(domain)) {
      WidgetsBinding.instance.addPostFrameCallback((_) => startDeploy());
    }

    return Column(
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(
            Insets.lg,
            Insets.lg,
            Insets.lg,
            0,
          ),
          child: Row(
            children: <Widget>[
              Expanded(
                child: SectionHeader(
                  title: 'Deploy',
                  subtitle: state.running
                      ? 'Streaming live from the control node…'
                      : 'Run an update and watch each step in real time',
                ),
              ),
              AppButton(
                label: 'Rollback',
                icon: Icons.history,
                tonal: true,
                onPressed: state.running ? null : startRollback,
              ),
              const SizedBox(width: Insets.sm),
              AppButton(
                label: 'Deploy',
                icon: Icons.rocket_launch,
                loading: state.running,
                onPressed: state.running ? null : startDeploy,
              ),
            ],
          ),
        ),
        Expanded(child: DeployTimeline(state: state)),
      ],
    );
  }
}

// --- Generic data-list tab (cron / workers) --------------------------------

class _DataListTab extends ConsumerStatefulWidget {
  const _DataListTab({
    required this.domain,
    required this.kind,
    required this.emptyLabel,
    required this.builder,
    required this.columns,
  });

  final String domain;
  final String kind;
  final String emptyLabel;
  final Stream<CliEvent> Function(CliService) builder;
  final List<String> columns;

  @override
  ConsumerState<_DataListTab> createState() => _DataListTabState();
}

class _DataListTabState extends ConsumerState<_DataListTab> {
  late Future<List<Map<String, dynamic>>> _future = _load();

  Future<List<Map<String, dynamic>>> _load() async {
    final CliService cli = ref.read(cliServiceProvider);
    final List<Map<String, dynamic>> rows = <Map<String, dynamic>>[];
    await for (final CliEvent e in widget.builder(cli)) {
      if (e is DataEvent && e.kind == widget.kind) {
        for (final dynamic item in e.items ?? const <dynamic>[]) {
          if (item is Map<String, dynamic>) rows.add(item);
        }
      } else if (e is DoneEvent) {
        break;
      }
    }
    return rows;
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<Map<String, dynamic>>>(
      future: _future,
      builder: (BuildContext context,
          AsyncSnapshot<List<Map<String, dynamic>>> snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snap.hasError) {
          return Center(child: Text(snap.error.toString()));
        }
        final List<Map<String, dynamic>> rows = snap.data ?? const <Map<String, dynamic>>[];
        if (rows.isEmpty) {
          return Center(child: Text(widget.emptyLabel));
        }
        return Padding(
          padding: const EdgeInsets.all(Insets.lg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Expanded(
                    child: SectionHeader(title: widget.kind.toUpperCase()),
                  ),
                  IconButton(
                    onPressed: () =>
                        setState(() => _future = _load()),
                    icon: const Icon(Icons.refresh),
                  ),
                ],
              ),
              const SizedBox(height: Insets.sm),
              Expanded(
                child: Card(
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: DataTable(
                      columns: <DataColumn>[
                        for (final String c in widget.columns)
                          DataColumn(label: Text(c)),
                      ],
                      rows: <DataRow>[
                        for (final Map<String, dynamic> row in rows)
                          DataRow(
                            cells: <DataCell>[
                              for (final String c in widget.columns)
                                DataCell(
                                  Text(
                                    '${row[c] ?? ''}',
                                    style: AppTheme.mono(context, size: 12),
                                  ),
                                ),
                            ],
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

// --- Logs -------------------------------------------------------------------

class _LogsTab extends ConsumerStatefulWidget {
  const _LogsTab({required this.domain});
  final String domain;

  @override
  ConsumerState<_LogsTab> createState() => _LogsTabState();
}

class _LogsTabState extends ConsumerState<_LogsTab> {
  final List<String> _lines = <String>[];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _tail();
  }

  Future<void> _tail() async {
    final CliService cli = ref.read(cliServiceProvider);
    await for (final CliEvent e in cli.logs(widget.domain)) {
      if (e is LogEvent && mounted) {
        setState(() => _lines.add(e.msg));
      } else if (e is DoneEvent) {
        break;
      }
    }
    if (mounted) setState(() => _loading = false);
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(Insets.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          const SectionHeader(title: 'Logs', subtitle: 'server --json logs'),
          const SizedBox(height: Insets.sm),
          Expanded(
            child: Container(
              padding: const EdgeInsets.all(Insets.md),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surface,
                borderRadius: BorderRadius.circular(Insets.radiusMd),
                border: Border.all(
                  color: Theme.of(context).colorScheme.outline,
                ),
              ),
              child: _lines.isEmpty && _loading
                  ? const Center(child: CircularProgressIndicator())
                  : ListView.builder(
                      itemCount: _lines.length,
                      itemBuilder: (BuildContext context, int i) => Text(
                        _lines[i],
                        style: AppTheme.mono(context, size: 12),
                      ),
                    ),
            ),
          ),
        ],
      ),
    );
  }
}

// --- SSL --------------------------------------------------------------------

class _SslTab extends ConsumerStatefulWidget {
  const _SslTab({required this.domain});
  final String domain;

  @override
  ConsumerState<_SslTab> createState() => _SslTabState();
}

class _SslTabState extends ConsumerState<_SslTab> {
  late Future<Map<String, dynamic>?> _future = _load();

  Future<Map<String, dynamic>?> _load() async {
    final CliService cli = ref.read(cliServiceProvider);
    await for (final CliEvent e in cli.sslStatus(widget.domain)) {
      if (e is DataEvent && e.kind == 'ssl') return e.value;
      if (e is DoneEvent) break;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return FutureBuilder<Map<String, dynamic>?>(
      future: _future,
      builder: (BuildContext context, AsyncSnapshot<Map<String, dynamic>?> snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }
        final Map<String, dynamic>? info = snap.data;
        if (info == null) {
          return const Center(child: Text('No certificate information'));
        }
        return Padding(
          padding: const EdgeInsets.all(Insets.lg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              const SectionHeader(title: 'TLS certificate'),
              const SizedBox(height: Insets.md),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(Insets.lg),
                  child: Column(
                    children: <Widget>[
                      for (final MapEntry<String, dynamic> e in info.entries)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 6),
                          child: Row(
                            children: <Widget>[
                              SizedBox(
                                width: 140,
                                child: Text(
                                  e.key,
                                  style: theme.textTheme.labelMedium?.copyWith(
                                    color: theme.colorScheme.onSurfaceVariant,
                                  ),
                                ),
                              ),
                              Expanded(
                                child: Text('${e.value}',
                                    style: theme.textTheme.bodyMedium),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
