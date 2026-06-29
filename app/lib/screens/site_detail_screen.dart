import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../models/audit_finding.dart';
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
import '../widgets/glass_card.dart';
import '../widgets/section_header.dart';
import '../widgets/status_dot.dart';
import '../widgets/terminal_panel.dart';

/// One selectable tool in the site detail toolbar.
class _Tool {
  const _Tool(this.key, this.label, this.icon);
  final String key;
  final String label;
  final IconData icon;
}

/// All tools shown at the top of the site detail screen, in display order.
/// The [key] doubles as the SM_TAB deep-link value.
const List<_Tool> _tools = <_Tool>[
  _Tool('overview', 'Overview', Icons.dashboard_outlined),
  _Tool('deploy', 'Deploy', Icons.rocket_launch_outlined),
  _Tool('cron', 'Cron', Icons.schedule_outlined),
  _Tool('workers', 'Workers', Icons.memory_outlined),
  _Tool('logs', 'Logs', Icons.article_outlined),
  _Tool('ssl', 'SSL', Icons.lock_outline),
  _Tool('database', 'Database', Icons.storage_outlined),
  _Tool('audit', 'Audit', Icons.shield_outlined),
];

/// Single-screen management view for a site: every tool selectable at the top,
/// and an always-connected per-site shell pinned to the bottom.
///
/// The Deploy tool hosts the live timeline; the others are scaffolded against
/// the right CLI calls. SM_TAB deep-links the initial tool; SM_AUTODEPLOY=1
/// auto-kicks a deploy on the Deploy tool.
class SiteDetailScreen extends ConsumerStatefulWidget {
  const SiteDetailScreen({super.key, required this.domain});

  final String domain;

  @override
  ConsumerState<SiteDetailScreen> createState() => _SiteDetailScreenState();
}

class _SiteDetailScreenState extends ConsumerState<SiteDetailScreen> {
  late int _selectedTool = _initialToolIndex();

  // Optional deep-link to a specific tool (used by demo/screenshot launches):
  // SM_TAB=overview|deploy|cron|workers|logs|ssl|database|audit.
  static int _initialToolIndex() {
    final String want = (envVar('SM_TAB') ?? '').toLowerCase();
    final int i = _tools.indexWhere((_Tool t) => t.key == want);
    return i < 0 ? 0 : i;
  }

  void _select(int index) {
    if (_selectedTool != index) setState(() => _selectedTool = index);
  }

  /// Switches to the Deploy tool (used by the always-visible quick action).
  void _goDeploy() => _select(_tools.indexWhere((_Tool t) => t.key == 'deploy'));

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
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
      ),
      body: Column(
        children: <Widget>[
          // TOP: tools + selected tool content.
          Expanded(
            flex: 3,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                _SiteSummaryStrip(
                  site: site,
                  onDeploy: _goDeploy,
                ),
                _ToolBar(
                  selected: _selectedTool,
                  onSelect: _select,
                ),
                Expanded(
                  child: IndexedStack(
                    index: _selectedTool,
                    children: <Widget>[
                      _OverviewTab(site: site, domain: widget.domain),
                      _DeployTab(domain: widget.domain),
                      _DataListTab(
                        domain: widget.domain,
                        kind: 'cron',
                        emptyLabel: 'No scheduled tasks',
                        builder: (CliService c) => c.cronList(widget.domain),
                        columns: const <String>[
                          'schedule', 'command', 'last', 'status'
                        ],
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
                      _DatabaseTab(site: site, domain: widget.domain),
                      _AuditTab(domain: widget.domain),
                    ],
                  ),
                ),
              ],
            ),
          ),
          // Splitter.
          Container(
            height: 1,
            color: theme.colorScheme.outline.withValues(alpha: 0.6),
          ),
          // BOTTOM: always-on per-site shell.
          Expanded(
            flex: 2,
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 200),
              child: ClipRRect(
                borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(Insets.radiusMd),
                ),
                child: ColoredBox(
                  color: Palette.darkBg,
                  child: TerminalPanel(
                    shellProvider: siteShellProvider(widget.domain),
                    title: 'Shell — ${site?.server ?? widget.domain}'
                        ':${siteAppRoot(widget.domain)}',
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// A compact one-line site summary with the always-visible quick actions.
class _SiteSummaryStrip extends StatelessWidget {
  const _SiteSummaryStrip({required this.site, required this.onDeploy});

  final Site? site;
  final VoidCallback onDeploy;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Site? s = site;
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: Insets.lg,
        vertical: Insets.sm,
      ),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        border: Border(
          bottom: BorderSide(
            color: theme.colorScheme.outline.withValues(alpha: 0.6),
          ),
        ),
      ),
      child: Row(
        children: <Widget>[
          Expanded(
            child: s == null
                ? Text(
                    'Loading…',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  )
                : Wrap(
                    spacing: Insets.sm,
                    runSpacing: Insets.xs,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: <Widget>[
                      _MetaChip(icon: Icons.dns_outlined, label: s.server),
                      _MetaChip(
                        icon: Icons.layers_outlined,
                        label: s.framework,
                      ),
                      _MetaChip(
                        icon: s.tls ? Icons.lock_outline : Icons.lock_open,
                        label: s.tls ? 'TLS on' : 'TLS off',
                        color: s.tls ? Palette.ok : Palette.warn,
                      ),
                      _MetaChip(
                        icon: Icons.favorite_outline,
                        label: s.health ?? 'unknown',
                        color: Palette.forHealth(s.health),
                      ),
                      _MetaChip(
                        icon: Icons.schedule_outlined,
                        label: s.lastDeploy ?? 'never',
                      ),
                    ],
                  ),
          ),
          const SizedBox(width: Insets.sm),
          IconButton(
            tooltip: 'Open https://${site?.domain ?? ''}',
            icon: const Icon(Icons.open_in_new, size: 18),
            onPressed: site == null ? null : () {},
          ),
          const SizedBox(width: Insets.xs),
          AppButton(
            label: 'Deploy',
            icon: Icons.rocket_launch,
            onPressed: onDeploy,
          ),
        ],
      ),
    );
  }
}

/// A tiny labeled chip used in the summary strip.
class _MetaChip extends StatelessWidget {
  const _MetaChip({required this.icon, required this.label, this.color});
  final IconData icon;
  final String label;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Color c = color ?? theme.colorScheme.onSurfaceVariant;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(Insets.radiusSm),
        border: Border.all(color: c.withValues(alpha: 0.4)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(icon, size: 13, color: c),
          const SizedBox(width: 6),
          Text(
            label,
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurface,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

/// The horizontal "Tools" selector: all tools as small tappable cards.
class _ToolBar extends StatelessWidget {
  const _ToolBar({required this.selected, required this.onSelect});

  final int selected;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        Insets.lg,
        Insets.md,
        Insets.lg,
        Insets.sm,
      ),
      child: Wrap(
        spacing: Insets.sm,
        runSpacing: Insets.sm,
        children: <Widget>[
          for (int i = 0; i < _tools.length; i++)
            _ToolButton(
              tool: _tools[i],
              selected: i == selected,
              onTap: () => onSelect(i),
            ),
        ],
      ),
    );
  }
}

class _ToolButton extends StatelessWidget {
  const _ToolButton({
    required this.tool,
    required this.selected,
    required this.onTap,
  });

  final _Tool tool;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Color accent = theme.colorScheme.primary;
    final Color fg = selected ? accent : theme.colorScheme.onSurfaceVariant;
    return Material(
      color: selected
          ? accent.withValues(alpha: 0.14)
          : theme.colorScheme.surface,
      borderRadius: BorderRadius.circular(Insets.radiusMd),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(Insets.radiusMd),
        child: AnimatedContainer(
          duration: AppMotion.fast,
          curve: AppMotion.standard,
          padding: const EdgeInsets.symmetric(
            horizontal: Insets.md,
            vertical: Insets.sm,
          ),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(Insets.radiusMd),
            border: Border.all(
              color: selected
                  ? accent.withValues(alpha: 0.6)
                  : theme.colorScheme.outline.withValues(alpha: 0.6),
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(tool.icon, size: 16, color: fg),
              const SizedBox(width: Insets.sm),
              Text(
                tool.label,
                style: theme.textTheme.labelLarge?.copyWith(
                  color: fg,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
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

// --- Database ---------------------------------------------------------------

class _DatabaseTab extends StatelessWidget {
  const _DatabaseTab({required this.site, required this.domain});
  final Site? site;
  final String domain;

  @override
  Widget build(BuildContext context) {
    if (site == null) {
      return const Center(child: CircularProgressIndicator());
    }
    final ThemeData theme = Theme.of(context);
    final String db = '${domain.split('.').first}_prod';
    final List<(String, String)> rows = <(String, String)>[
      ('Engine', 'MySQL 8.0'),
      ('Database', db),
      ('User', 'deploy'),
      ('Host', '127.0.0.1:3306'),
      ('Status', site!.health == 'down' ? 'unreachable' : 'connected'),
    ];
    return ListView(
      padding: const EdgeInsets.all(Insets.lg),
      children: <Widget>[
        const SectionHeader(
          title: 'Database',
          subtitle: 'Connection details for this site',
        ),
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

// --- Audit ------------------------------------------------------------------

/// Domains whose demo audit has already auto-run once (one-shot guard, mirrors
/// [_autoDeployed]). Lets SM_TAB=audit open onto a populated finding list.
final Set<String> _autoAudited = <String>{};

/// Per-finding fix lifecycle on the audit tab.
enum _FixState { idle, running, fixed, failed }

/// The Security Audit tool: runs `server --json audit <domain>`, shows live
/// check progress, then lists findings grouped by severity with a per-finding
/// "Fix" button that calls `auditFix` and re-runs the audit on success.
class _AuditTab extends ConsumerStatefulWidget {
  const _AuditTab({required this.domain});
  final String domain;

  @override
  ConsumerState<_AuditTab> createState() => _AuditTabState();
}

class _AuditTabState extends ConsumerState<_AuditTab> {
  bool _running = false;
  bool _hasRun = false;
  String _statusLabel = '';
  List<AuditFinding>? _findings;

  /// Per-finding-id fix state and last step status line.
  final Map<String, _FixState> _fixState = <String, _FixState>{};
  final Map<String, String> _fixStatus = <String, String>{};

  @override
  void initState() {
    super.initState();
    // Auto-run once in demo so SM_TAB=audit shows findings without a click.
    if ((envVar('SM_TAB') ?? '').toLowerCase() == 'audit' &&
        _autoAudited.add(widget.domain)) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _runAudit());
    }
  }

  Future<void> _runAudit() async {
    if (_running) return;
    setState(() {
      _running = true;
      _hasRun = true;
      _statusLabel = 'Starting audit…';
    });
    final CliService cli = ref.read(cliServiceProvider);
    List<AuditFinding>? result;
    try {
      await for (final CliEvent e in cli.audit(widget.domain)) {
        if (!mounted) return;
        switch (e) {
          case SectionEvent(label: final String l):
            setState(() => _statusLabel = l);
          case StepStart(label: final String l):
            setState(() => _statusLabel = l);
          case DataEvent(kind: 'audit', items: final List<dynamic>? items):
            result = <AuditFinding>[
              for (final dynamic item in items ?? const <dynamic>[])
                if (item is Map<String, dynamic>) AuditFinding.fromJson(item),
            ]..sort((AuditFinding a, AuditFinding b) =>
                a.severityRank.compareTo(b.severityRank));
          case DoneEvent():
            break;
          default:
            break;
        }
      }
    } finally {
      if (mounted) {
        setState(() {
          _running = false;
          _findings = result ?? _findings ?? const <AuditFinding>[];
          _fixState.clear();
          _fixStatus.clear();
        });
      }
    }
  }

  Future<void> _runFix(AuditFinding finding) async {
    final String id = finding.id;
    if (_fixState[id] == _FixState.running) return;
    setState(() {
      _fixState[id] = _FixState.running;
      _fixStatus[id] = 'Applying…';
    });
    final CliService cli = ref.read(cliServiceProvider);
    bool ok = false;
    try {
      await for (final CliEvent e in cli.auditFix(id, widget.domain)) {
        if (!mounted) return;
        switch (e) {
          case StepStart(label: final String l):
            setState(() => _fixStatus[id] = l);
          case DoneEvent(ok: final bool done):
            ok = done;
          default:
            break;
        }
      }
    } catch (_) {
      ok = false;
    }
    if (!mounted) return;
    setState(() {
      _fixState[id] = ok ? _FixState.fixed : _FixState.failed;
      _fixStatus[id] = ok ? 'Fixed' : 'Fix failed';
    });
    // On success, re-run the audit shortly so the finding disappears.
    if (ok) {
      await Future<void>.delayed(const Duration(milliseconds: 900));
      if (mounted) await _runAudit();
    }
  }

  @override
  Widget build(BuildContext context) {
    final List<AuditFinding>? findings = _findings;
    final bool showProgress =
        (_running || !_hasRun) && (findings == null || findings.isEmpty);

    return Padding(
      padding: const EdgeInsets.all(Insets.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          _AuditHeader(
            findings: findings,
            running: _running,
            onRerun: _running ? null : _runAudit,
          ),
          const SizedBox(height: Insets.md),
          Expanded(
            child: showProgress
                ? _AuditProgress(label: _statusLabel)
                : (findings == null || findings.isEmpty)
                    ? const _AuditClean()
                    : ListView.separated(
                        itemCount: findings.length,
                        separatorBuilder: (_, __) =>
                            const SizedBox(height: Insets.sm),
                        itemBuilder: (BuildContext context, int i) {
                          final AuditFinding f = findings[i];
                          return _FindingCard(
                            finding: f,
                            state: _fixState[f.id] ?? _FixState.idle,
                            statusLine: _fixStatus[f.id],
                            onFix: () => _runFix(f),
                          )
                              .animate(delay: Duration(milliseconds: 50 * i))
                              .fadeIn(duration: AppMotion.base)
                              .slideY(
                                begin: 0.12,
                                curve: AppMotion.emphasized,
                              );
                        },
                      ),
          ),
        ],
      ),
    );
  }
}

/// Maps a severity string to its semantic color.
Color _severityColor(String severity) {
  switch (severity) {
    case 'critical':
    case 'high':
      return Palette.err;
    case 'medium':
      return Palette.warn;
    case 'low':
    case 'info':
    default:
      return Palette.info;
  }
}

/// Header with a posture line, per-severity count chips, and a re-run button.
class _AuditHeader extends StatelessWidget {
  const _AuditHeader({
    required this.findings,
    required this.running,
    required this.onRerun,
  });

  final List<AuditFinding>? findings;
  final bool running;
  final VoidCallback? onRerun;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final List<AuditFinding> list = findings ?? const <AuditFinding>[];

    final Map<String, int> counts = <String, int>{};
    for (final AuditFinding f in list) {
      counts[f.severity] = (counts[f.severity] ?? 0) + 1;
    }

    final String posture;
    if (findings == null) {
      posture = running ? 'Running audit…' : 'Run a security audit';
    } else if (list.isEmpty) {
      posture = 'All checks passed';
    } else {
      posture =
          '${list.length} ${list.length == 1 ? 'finding' : 'findings'}';
    }

    const List<String> order = <String>[
      'critical', 'high', 'medium', 'low', 'info'
    ];

    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: <Widget>[
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              SectionHeader(title: 'Security audit', subtitle: posture),
              if (counts.isNotEmpty) ...<Widget>[
                const SizedBox(height: Insets.xs),
                Wrap(
                  spacing: Insets.sm,
                  runSpacing: Insets.xs,
                  children: <Widget>[
                    for (final String sev in order)
                      if ((counts[sev] ?? 0) > 0)
                        _SeverityChip(severity: sev, count: counts[sev]!),
                  ],
                ),
              ],
            ],
          ),
        ),
        const SizedBox(width: Insets.sm),
        AppButton(
          label: 'Re-run audit',
          icon: Icons.refresh,
          tonal: true,
          loading: running,
          onPressed: onRerun,
        ),
      ],
    );
  }
}

/// A small colored "N critical" pill summarizing a severity bucket.
class _SeverityChip extends StatelessWidget {
  const _SeverityChip({required this.severity, required this.count});
  final String severity;
  final int count;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Color c = _severityColor(severity);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(Insets.radiusSm),
        border: Border.all(color: c.withValues(alpha: 0.5)),
      ),
      child: Text(
        '$count $severity',
        style: theme.textTheme.labelSmall?.copyWith(
          color: c,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

/// A live spinner with the current section/step label while the audit runs.
class _AuditProgress extends StatelessWidget {
  const _AuditProgress({required this.label});
  final String label;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          const SizedBox(
            width: 28,
            height: 28,
            child: CircularProgressIndicator(strokeWidth: 2.5),
          ),
          const SizedBox(height: Insets.md),
          Text(
            label.isEmpty ? 'Auditing…' : label,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

/// The "all clear" empty state shown when no findings remain.
class _AuditClean extends StatelessWidget {
  const _AuditClean();

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(Icons.verified_user_outlined, size: 40, color: Palette.ok),
          const SizedBox(height: Insets.md),
          Text(
            'All checks passed',
            style: theme.textTheme.titleMedium?.copyWith(color: Palette.ok),
          ),
          const SizedBox(height: Insets.xs),
          Text(
            'No security findings for this site.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

/// One finding rendered as a [GlassCard]: severity badge, title, detail,
/// recommendation, and a Fix button (or a 'manual' tag when not fixable).
class _FindingCard extends StatelessWidget {
  const _FindingCard({
    required this.finding,
    required this.state,
    required this.statusLine,
    required this.onFix,
  });

  final AuditFinding finding;
  final _FixState state;
  final String? statusLine;
  final VoidCallback onFix;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Color sev = _severityColor(finding.severity);
    final bool fixed = state == _FixState.fixed;
    final bool failed = state == _FixState.failed;

    return GlassCard(
      padding: const EdgeInsets.all(Insets.md),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          _SeverityBadge(severity: finding.severity, color: sev),
          const SizedBox(width: Insets.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  finding.title,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                if (finding.detail.isNotEmpty) ...<Widget>[
                  const SizedBox(height: Insets.xs),
                  Text(
                    finding.detail,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
                if (finding.recommendation.isNotEmpty) ...<Widget>[
                  const SizedBox(height: Insets.sm),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        '→ ',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: Palette.teal,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      Expanded(
                        child: Text(
                          finding.recommendation,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurface,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
                if (statusLine != null && !fixed) ...<Widget>[
                  const SizedBox(height: Insets.sm),
                  Text(
                    statusLine!,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: failed
                          ? Palette.err
                          : theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: Insets.md),
          _FindingAction(finding: finding, state: state, onFix: onFix),
        ],
      ),
    );
  }
}

/// The colored severity badge on the left of a finding card.
class _SeverityBadge extends StatelessWidget {
  const _SeverityBadge({required this.severity, required this.color});
  final String severity;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(Insets.radiusSm),
        border: Border.all(color: color.withValues(alpha: 0.6)),
      ),
      child: Text(
        severity.toUpperCase(),
        style: theme.textTheme.labelSmall?.copyWith(
          color: color,
          fontWeight: FontWeight.w800,
          letterSpacing: 0.5,
        ),
      ),
    );
  }
}

/// The trailing action on a finding card: Fix button, inline spinner, a green
/// "Fixed" state, or a subtle "manual" tag for non-fixable findings.
class _FindingAction extends StatelessWidget {
  const _FindingAction({
    required this.finding,
    required this.state,
    required this.onFix,
  });

  final AuditFinding finding;
  final _FixState state;
  final VoidCallback onFix;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);

    if (state == _FixState.fixed) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(Icons.check_circle, size: 18, color: Palette.ok),
          const SizedBox(width: 6),
          Text(
            'Fixed',
            style: theme.textTheme.labelLarge?.copyWith(
              color: Palette.ok,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      );
    }

    if (!finding.fixable) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest
              .withValues(alpha: 0.4),
          borderRadius: BorderRadius.circular(Insets.radiusSm),
          border: Border.all(
            color: theme.colorScheme.outline.withValues(alpha: 0.6),
          ),
        ),
        child: Text(
          'manual',
          style: theme.textTheme.labelSmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
            fontWeight: FontWeight.w600,
          ),
        ),
      );
    }

    final bool running = state == _FixState.running;
    return AppButton(
      label: state == _FixState.failed
          ? 'Retry'
          : (finding.fixLabel.isEmpty ? 'Fix' : finding.fixLabel),
      icon: state == _FixState.failed ? Icons.refresh : Icons.build_outlined,
      loading: running,
      onPressed: running ? null : onFix,
    );
  }
}
