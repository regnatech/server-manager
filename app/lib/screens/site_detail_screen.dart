import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../models/git_models.dart';
import '../models/site.dart';
import '../services/cli_service.dart';
import '../state/connection_provider.dart';
import '../state/deploy_provider.dart';
import '../state/sites_provider.dart';
import '../theme/app_theme.dart';
import '../transport/cli_event.dart';
import '../transport/platform.dart';
import '../widgets/app_button.dart';
import '../widgets/audit_view.dart';
import '../widgets/deploy_timeline.dart';
import '../widgets/framework_chip.dart';
import '../widgets/glass_card.dart';
import '../widgets/merge_conflict_view.dart';
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
  _Tool('releases', 'Releases', Icons.layers_outlined),
  _Tool('git', 'Git', Icons.account_tree_outlined),
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
  // SM_TAB=overview|deploy|releases|git|cron|workers|logs|ssl|database|audit.
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
                      _ReleasesTab(domain: widget.domain),
                      _GitTab(domain: widget.domain),
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

    void previewChanges() {
      showDialog<void>(
        context: context,
        builder: (BuildContext _) => _DiffDialog(domain: domain),
      );
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
                label: 'Preview changes',
                icon: Icons.difference_outlined,
                tonal: true,
                onPressed: state.running ? null : previewChanges,
              ),
              const SizedBox(width: Insets.sm),
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

/// One atomic release row from `release list`.
class _Release {
  const _Release({required this.name, required this.current});
  final String name;
  final bool current;

  factory _Release.fromJson(Map<String, dynamic> json) => _Release(
        name: json['name']?.toString() ?? '',
        current: json['current'] == true,
      );
}

/// The Releases tool: an atomic "Deploy (atomic)" action plus the list of
/// existing releases (current badged; others rollback-able). Loads
/// `release list <domain>` on first build; re-lists after deploy/rollback.
class _ReleasesTab extends ConsumerStatefulWidget {
  const _ReleasesTab({required this.domain});
  final String domain;

  @override
  ConsumerState<_ReleasesTab> createState() => _ReleasesTabState();
}

class _ReleasesTabState extends ConsumerState<_ReleasesTab> {
  List<_Release> _releases = const <_Release>[];
  bool _loading = true;
  bool _loadStarted = false;

  /// Inline step progress for an in-flight deploy/rollback (null when idle).
  String? _busyLabel;
  String? _runningId;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    if (_loadStarted && !mounted) return;
    _loadStarted = true;
    final CliService cli = ref.read(cliServiceProvider);
    List<_Release> releases = const <_Release>[];
    await for (final CliEvent e in cli.releaseList(widget.domain)) {
      if (e is DataEvent && e.kind == 'releases') {
        final List<dynamic> items =
            (e.value?['items'] as List<dynamic>?) ?? const <dynamic>[];
        releases = <_Release>[
          for (final dynamic item in items)
            if (item is Map<String, dynamic>) _Release.fromJson(item),
        ];
      } else if (e is DoneEvent) {
        break;
      }
    }
    if (!mounted) return;
    setState(() {
      _releases = releases;
      _loading = false;
    });
  }

  Future<void> _deployAtomic() async {
    if (_busyLabel != null) return;
    setState(() {
      _runningId = '__deploy';
      _busyLabel = 'Starting atomic deploy…';
    });
    await _drive(ref.read(cliServiceProvider).releaseDeploy(widget.domain));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Atomic deploy complete')),
      );
    }
  }

  Future<void> _rollback(String name) async {
    if (_busyLabel != null) return;
    setState(() {
      _runningId = name;
      _busyLabel = 'Rolling back…';
    });
    await _drive(
        ref.read(cliServiceProvider).releaseRollback(widget.domain, name));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Rolled back to $name')),
      );
    }
  }

  /// Streams [events], surfacing each step label inline, then re-lists.
  Future<void> _drive(Stream<CliEvent> events) async {
    await for (final CliEvent e in events) {
      if (!mounted) return;
      if (e is StepStart) {
        setState(() => _busyLabel = e.label);
      } else if (e is DoneEvent) {
        break;
      }
    }
    if (!mounted) return;
    setState(() {
      _busyLabel = null;
      _runningId = null;
    });
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final bool busy = _busyLabel != null;
    return Padding(
      padding: const EdgeInsets.fromLTRB(Insets.lg, Insets.lg, Insets.lg, Insets.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            children: <Widget>[
              const Expanded(
                child: SectionHeader(
                  title: 'Releases',
                  subtitle: 'Atomic deploys with instant rollback',
                ),
              ),
              AppButton(
                label: 'Deploy (atomic)',
                icon: Icons.rocket_launch,
                loading: busy && _runningId == '__deploy',
                onPressed: busy ? null : _deployAtomic,
              ),
            ],
          ),
          if (busy && _busyLabel != null) ...<Widget>[
            const SizedBox(height: Insets.sm),
            Row(
              children: <Widget>[
                const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                const SizedBox(width: Insets.sm),
                Expanded(
                  child: Text(
                    _busyLabel!,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
          ],
          const SizedBox(height: Insets.md),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _releases.isEmpty
                    ? const Center(child: Text('No releases yet'))
                    : ListView.separated(
                        itemCount: _releases.length,
                        separatorBuilder: (_, __) =>
                            const SizedBox(height: Insets.sm),
                        itemBuilder: (BuildContext context, int i) {
                          final _Release r = _releases[i];
                          return _ReleaseRow(
                            release: r,
                            busy: busy,
                            rollingBack: _runningId == r.name,
                            onRollback: () => _rollback(r.name),
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

/// One release rendered as a [GlassCard]: timestamp, a "current" badge on the
/// active release, or a "Rollback" button on the others.
class _ReleaseRow extends StatelessWidget {
  const _ReleaseRow({
    required this.release,
    required this.busy,
    required this.rollingBack,
    required this.onRollback,
  });

  final _Release release;
  final bool busy;
  final bool rollingBack;
  final VoidCallback onRollback;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return GlassCard(
      padding: const EdgeInsets.all(Insets.md),
      child: Row(
        children: <Widget>[
          Icon(
            release.current ? Icons.check_circle : Icons.layers_outlined,
            size: 18,
            color: release.current
                ? Palette.ok
                : theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: Insets.md),
          Expanded(
            child: Text(
              release.name,
              style: AppTheme.mono(context, size: 13).copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          const SizedBox(width: Insets.sm),
          if (release.current)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(
                color: Palette.ok.withValues(alpha: 0.14),
                borderRadius: BorderRadius.circular(Insets.radiusSm),
                border: Border.all(color: Palette.ok.withValues(alpha: 0.5)),
              ),
              child: Text(
                'current',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: Palette.ok,
                  fontWeight: FontWeight.w700,
                ),
              ),
            )
          else
            AppButton(
              label: 'Rollback',
              icon: Icons.history,
              tonal: true,
              loading: rollingBack,
              onPressed: busy ? null : onRollback,
            ),
        ],
      ),
    );
  }
}

/// The deploy-diff preview dialog: runs `diff <domain>` and shows the commits
/// ahead plus pending migrations (or "Already up to date").
class _DiffDialog extends ConsumerStatefulWidget {
  const _DiffDialog({required this.domain});
  final String domain;

  @override
  ConsumerState<_DiffDialog> createState() => _DiffDialogState();
}

class _DiffDialogState extends ConsumerState<_DiffDialog> {
  bool _loading = true;
  Map<String, dynamic>? _diff;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    final CliService cli = ref.read(cliServiceProvider);
    Map<String, dynamic>? diff;
    await for (final CliEvent e in cli.deployDiff(widget.domain)) {
      if (e is DataEvent && e.kind == 'deploy_diff') {
        diff = e.value;
      } else if (e is DoneEvent) {
        break;
      }
    }
    if (!mounted) return;
    setState(() {
      _diff = diff;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Map<String, dynamic>? d = _diff;
    final int ahead = (d?['ahead'] as num?)?.toInt() ?? 0;
    final List<GitCommit> commits = <GitCommit>[
      for (final dynamic c in (d?['commits'] as List<dynamic>?) ?? const <dynamic>[])
        if (c is Map<String, dynamic>) GitCommit.fromJson(c),
    ];
    final List<String> migrations = <String>[
      for (final dynamic m in (d?['migrations'] as List<dynamic>?) ?? const <dynamic>[])
        m.toString(),
    ];

    return AlertDialog(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Insets.radiusLg),
      ),
      title: Row(
        children: <Widget>[
          Icon(Icons.difference_outlined,
              color: theme.colorScheme.primary, size: 20),
          const SizedBox(width: Insets.sm),
          const Text('Preview changes'),
        ],
      ),
      content: SizedBox(
        width: 480,
        child: _loading
            ? const SizedBox(
                height: 120,
                child: Center(child: CircularProgressIndicator()),
              )
            : d == null
                ? const Text('Could not compute the diff.')
                : ahead == 0
                    ? Row(
                        mainAxisSize: MainAxisSize.min,
                        children: <Widget>[
                          const Icon(
                            Icons.check_circle,
                            color: Palette.ok,
                            size: 20,
                          ),
                          const SizedBox(width: Insets.sm),
                          Text(
                            'Already up to date',
                            style: theme.textTheme.titleSmall
                                ?.copyWith(color: Palette.ok),
                          ),
                        ],
                      )
                    : SingleChildScrollView(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            Text(
                              '${d['from'] ?? '?'} → ${d['to'] ?? '?'} '
                              '($ahead commit${ahead == 1 ? '' : 's'})',
                              style: AppTheme.mono(context, size: 13).copyWith(
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            const SizedBox(height: Insets.md),
                            for (final GitCommit c in commits)
                              Padding(
                                padding:
                                    const EdgeInsets.only(bottom: Insets.sm),
                                child: Row(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.start,
                                  children: <Widget>[
                                    Text(
                                      c.short,
                                      style: AppTheme.mono(
                                        context,
                                        size: 12,
                                        color: theme.colorScheme.primary,
                                      ),
                                    ),
                                    const SizedBox(width: Insets.sm),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: <Widget>[
                                          Text(
                                            c.subject,
                                            style: theme.textTheme.bodyMedium
                                                ?.copyWith(
                                              fontWeight: FontWeight.w600,
                                            ),
                                          ),
                                          Text(
                                            '${c.author} · ${c.relative}',
                                            style: theme.textTheme.labelSmall
                                                ?.copyWith(
                                              color: theme
                                                  .colorScheme.onSurfaceVariant,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            const SizedBox(height: Insets.sm),
                            Text(
                              'Pending migrations',
                              style: theme.textTheme.labelLarge?.copyWith(
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            const SizedBox(height: Insets.xs),
                            if (migrations.isEmpty)
                              Text(
                                'No pending migrations',
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: theme.colorScheme.onSurfaceVariant,
                                ),
                              )
                            else
                              for (final String m in migrations)
                                Padding(
                                  padding: const EdgeInsets.symmetric(
                                      vertical: 2),
                                  child: Row(
                                    children: <Widget>[
                                      const Icon(
                                        Icons.schema_outlined,
                                        size: 14,
                                        color: Palette.warn,
                                      ),
                                      const SizedBox(width: Insets.sm),
                                      Expanded(
                                        child: Text(
                                          m,
                                          style: AppTheme.mono(context,
                                              size: 12),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                          ],
                        ),
                      ),
      ),
      actions: <Widget>[
        AppButton(
          label: 'Close',
          onPressed: () => Navigator.of(context).pop(),
        ),
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

/// The selectable log types (CLI arg ↔ display label).
const List<(String, String)> _logTypes = <(String, String)>[
  ('nginx', 'nginx'),
  ('php', 'php'),
  ('laravel', 'laravel'),
  ('queue', 'queue'),
];

/// A rich log viewer: a type selector, live case-insensitive search, a live
/// "tail" toggle and a refresh, over a virtualized monospace log body with
/// per-line severity coloring and search-term highlighting.
///
/// One-shot `logs(domain, type:…)` loads the recent lines on first build and on
/// type change / refresh. Flipping "Live tail" ON subscribes to
/// `logsFollow(domain, type:…)` and appends each [LogEvent] as it arrives;
/// flipping it OFF (or changing type, or disposing) cancels the subscription.
class _LogsTab extends ConsumerStatefulWidget {
  const _LogsTab({required this.domain});
  final String domain;

  @override
  ConsumerState<_LogsTab> createState() => _LogsTabState();
}

class _LogsTabState extends ConsumerState<_LogsTab> {
  final List<String> _lines = <String>[];
  final ScrollController _scroll = ScrollController();
  final TextEditingController _search = TextEditingController();

  String _type = 'laravel';
  String? _file;
  String _query = '';
  bool _loading = true;
  bool _live = false;

  /// The active follow subscription when [_live] is on; null otherwise. Managed
  /// entirely in State and cancelled on dispose / toggle-off / type change.
  StreamSubscription<CliEvent>? _follow;

  @override
  void initState() {
    super.initState();
    // Auto-load on first build (one-shot, live OFF) so a screenshot — including
    // SM_TAB=logs — lands on a populated viewer without interaction.
    _search.addListener(() {
      if (_query != _search.text) setState(() => _query = _search.text);
    });
    _refresh();
  }

  @override
  void dispose() {
    _follow?.cancel();
    _scroll.dispose();
    _search.dispose();
    super.dispose();
  }

  /// Visible lines after the case-insensitive search filter.
  List<String> get _filtered {
    if (_query.isEmpty) return _lines;
    final String q = _query.toLowerCase();
    return <String>[
      for (final String l in _lines)
        if (l.toLowerCase().contains(q)) l,
    ];
  }

  /// One-shot fetch of the recent lines for the current [_type]. Cancels any
  /// live tail first (it is re-armed by the toggle, not here).
  Future<void> _refresh() async {
    await _follow?.cancel();
    _follow = null;
    if (!mounted) return;
    setState(() {
      _live = false;
      _loading = true;
      _lines.clear();
    });
    final CliService cli = ref.read(cliServiceProvider);
    await for (final CliEvent e in cli.logs(widget.domain, type: _type)) {
      if (!mounted) return;
      if (e is DataEvent && e.kind == 'logs_meta') {
        _file = e.value?['file']?.toString();
      } else if (e is DataEvent && e.kind == 'logs') {
        _file = e.value?['file']?.toString() ?? _file;
        final List<dynamic> raw =
            (e.value?['lines'] as List<dynamic>?) ?? const <dynamic>[];
        final List<String> parsed =
            raw.map((dynamic l) => l.toString()).toList();
        setState(() {
          _lines
            ..clear()
            ..addAll(parsed);
        });
      } else if (e is DoneEvent) {
        break;
      }
    }
    if (!mounted) return;
    setState(() => _loading = false);
    _autoScroll();
  }

  /// Switches the selected log type: cancels any tail, then reloads one-shot.
  void _selectType(String type) {
    if (type == _type) return;
    setState(() => _type = type);
    _refresh();
  }

  /// Arms or disarms the live tail. ON → subscribe to [CliService.logsFollow]
  /// and append each line; OFF → cancel the subscription.
  void _toggleLive(bool on) {
    setState(() => _live = on);
    if (!on) {
      _follow?.cancel();
      _follow = null;
      return;
    }
    final CliService cli = ref.read(cliServiceProvider);
    _follow = cli.logsFollow(widget.domain, type: _type).listen(
      (CliEvent e) {
        if (!mounted) return;
        if (e is DataEvent && e.kind == 'logs_meta') {
          setState(() => _file = e.value?['file']?.toString() ?? _file);
        } else if (e is LogEvent) {
          setState(() => _lines.add(e.msg));
          _autoScroll();
        }
      },
      onDone: () {
        if (mounted) setState(() => _live = false);
        _follow = null;
      },
      onError: (_) {
        if (mounted) setState(() => _live = false);
        _follow = null;
      },
    );
  }

  /// Jumps to the bottom on the next frame (new data / first load).
  void _autoScroll() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final List<String> lines = _filtered;
    return Padding(
      padding: const EdgeInsets.fromLTRB(Insets.lg, Insets.lg, Insets.lg, Insets.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          SectionHeader(
            title: 'Logs',
            subtitle: _file ?? 'server --json logs',
            trailing: _live
                ? Row(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      Container(
                        width: 8,
                        height: 8,
                        decoration: const BoxDecoration(
                          color: Palette.err,
                          shape: BoxShape.circle,
                        ),
                      )
                          .animate(onPlay: (AnimationController c) => c.repeat(reverse: true))
                          .fadeIn(duration: AppMotion.slow)
                          .then()
                          .fade(begin: 1, end: 0.2, duration: AppMotion.slow),
                      const SizedBox(width: Insets.sm),
                      Text(
                        'LIVE',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: Palette.err,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 1,
                        ),
                      ),
                    ],
                  )
                : null,
          ),
          const SizedBox(height: Insets.sm),
          _LogsToolbar(
            type: _type,
            onType: _selectType,
            search: _search,
            live: _live,
            onLive: _toggleLive,
            onRefresh: _loading ? null : _refresh,
            loading: _loading,
          ),
          const SizedBox(height: Insets.sm),
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(Insets.radiusMd),
              child: Container(
                decoration: BoxDecoration(
                  color: Palette.darkBg,
                  borderRadius: BorderRadius.circular(Insets.radiusMd),
                  border: Border.all(
                    color: theme.colorScheme.outline.withValues(alpha: 0.6),
                  ),
                ),
                child: _loading && _lines.isEmpty
                    ? const Center(child: CircularProgressIndicator())
                    : lines.isEmpty
                        ? Center(
                            child: Text(
                              _lines.isEmpty
                                  ? 'No log lines'
                                  : 'No lines match “$_query”',
                              style: theme.textTheme.bodyMedium?.copyWith(
                                color: Palette.darkTextDim,
                              ),
                            ),
                          )
                        : Scrollbar(
                            controller: _scroll,
                            child: ListView.builder(
                              controller: _scroll,
                              padding: const EdgeInsets.symmetric(
                                horizontal: Insets.md,
                                vertical: Insets.sm,
                              ),
                              itemCount: lines.length,
                              itemBuilder: (BuildContext context, int i) =>
                                  _LogLine(
                                number: i + 1,
                                line: lines[i],
                                query: _query,
                              ),
                            ),
                          ),
              ),
            ),
          ),
          const SizedBox(height: Insets.xs),
          Text(
            '${lines.length}${_query.isNotEmpty ? ' / ${_lines.length}' : ''} '
            'line${lines.length == 1 ? '' : 's'}'
            '${_live ? ' · following' : ''}',
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

/// The Logs toolbar: type segments, a live search field, a live-tail switch and
/// a refresh button.
class _LogsToolbar extends StatelessWidget {
  const _LogsToolbar({
    required this.type,
    required this.onType,
    required this.search,
    required this.live,
    required this.onLive,
    required this.onRefresh,
    required this.loading,
  });

  final String type;
  final ValueChanged<String> onType;
  final TextEditingController search;
  final bool live;
  final ValueChanged<bool> onLive;
  final VoidCallback? onRefresh;
  final bool loading;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Wrap(
      spacing: Insets.md,
      runSpacing: Insets.sm,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: <Widget>[
        _TypeSelector(value: type, onChanged: onType),
        SizedBox(
          width: 240,
          child: TextField(
            controller: search,
            style: AppTheme.mono(context, size: 12),
            decoration: InputDecoration(
              isDense: true,
              hintText: 'Filter lines…',
              prefixIcon: const Icon(Icons.search, size: 18),
              suffixIcon: search.text.isEmpty
                  ? null
                  : IconButton(
                      icon: const Icon(Icons.close, size: 16),
                      onPressed: search.clear,
                      tooltip: 'Clear',
                    ),
              contentPadding: const EdgeInsets.symmetric(
                horizontal: Insets.sm,
                vertical: Insets.sm,
              ),
            ),
          ),
        ),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(
              Icons.sensors,
              size: 16,
              color: live ? Palette.err : theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(width: 6),
            Text(
              'Live tail',
              style: theme.textTheme.labelMedium?.copyWith(
                color: live
                    ? theme.colorScheme.onSurface
                    : theme.colorScheme.onSurfaceVariant,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(width: Insets.xs),
            Switch(value: live, onChanged: onLive),
          ],
        ),
        IconButton(
          tooltip: 'Refresh',
          onPressed: onRefresh,
          icon: loading
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.refresh),
        ),
      ],
    );
  }
}

/// A segmented selector over [_logTypes].
class _TypeSelector extends StatelessWidget {
  const _TypeSelector({required this.value, required this.onChanged});
  final String value;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Color accent = theme.colorScheme.primary;
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(Insets.radiusSm),
        border: Border.all(color: theme.colorScheme.outline.withValues(alpha: 0.6)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          for (final (String, String) t in _logTypes)
            Material(
              color: t.$1 == value
                  ? accent.withValues(alpha: 0.16)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(Insets.radiusSm - 2),
              child: InkWell(
                onTap: () => onChanged(t.$1),
                borderRadius: BorderRadius.circular(Insets.radiusSm - 2),
                child: AnimatedContainer(
                  duration: AppMotion.fast,
                  curve: AppMotion.standard,
                  padding: const EdgeInsets.symmetric(
                    horizontal: Insets.md,
                    vertical: 6,
                  ),
                  child: Text(
                    t.$2,
                    style: AppTheme.mono(
                      context,
                      size: 12,
                      color: t.$1 == value
                          ? accent
                          : theme.colorScheme.onSurfaceVariant,
                    ).copyWith(
                      fontWeight:
                          t.$1 == value ? FontWeight.w700 : FontWeight.w500,
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

/// One virtualized log row: a muted line number plus the line, tinted by
/// severity, with the active search term highlighted.
class _LogLine extends StatelessWidget {
  const _LogLine({
    required this.number,
    required this.line,
    required this.query,
  });

  final int number;
  final String line;
  final String query;

  /// Severity tint for a line, or null for the default muted color.
  static Color? _tint(String line) {
    final String u = line.toUpperCase();
    if (u.contains('ERROR') ||
        u.contains('CRITICAL') ||
        u.contains('EXCEPTION') ||
        u.contains('FATAL') ||
        u.contains(' 500 ')) {
      return Palette.err;
    }
    if (u.contains('WARN')) return Palette.warn;
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final Color base = _tint(line) ?? Palette.darkText.withValues(alpha: 0.86);
    final TextStyle style = AppTheme.mono(context, size: 12, color: base)
        .copyWith(height: 1.3);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SizedBox(
            width: 36,
            child: Text(
              '$number',
              textAlign: TextAlign.right,
              style: AppTheme.mono(context, size: 11)
                  .copyWith(color: Palette.darkTextDim.withValues(alpha: 0.5)),
            ),
          ),
          const SizedBox(width: Insets.sm),
          Expanded(child: _highlighted(style)),
        ],
      ),
    );
  }

  /// The line as a [SelectableText.rich] with case-insensitive matches of
  /// [query] highlighted; plain text when there is no query.
  Widget _highlighted(TextStyle style) {
    if (query.isEmpty) {
      return SelectableText(line, style: style);
    }
    final String lower = line.toLowerCase();
    final String q = query.toLowerCase();
    final List<TextSpan> spans = <TextSpan>[];
    int start = 0;
    while (true) {
      final int idx = lower.indexOf(q, start);
      if (idx < 0) {
        spans.add(TextSpan(text: line.substring(start)));
        break;
      }
      if (idx > start) spans.add(TextSpan(text: line.substring(start, idx)));
      spans.add(
        TextSpan(
          text: line.substring(idx, idx + q.length),
          style: TextStyle(
            backgroundColor: Palette.warn.withValues(alpha: 0.35),
            color: Palette.darkText,
            fontWeight: FontWeight.w700,
          ),
        ),
      );
      start = idx + q.length;
    }
    return SelectableText.rich(TextSpan(style: style, children: spans));
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

/// One-shot guard for the SM_GIT_MERGE demo auto-merge.
final Set<String> _autoMerged = <String>{};

/// The Security Audit tool: a per-site [AuditView] wired to the site-scoped
/// `audit <domain>` / `audit fix <id> <domain>` CLI calls. Auto-runs once when
/// deep-linked via SM_TAB=audit so a screenshot lands on a populated list.
class _AuditTab extends ConsumerWidget {
  const _AuditTab({required this.domain});
  final String domain;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final CliService cli = ref.read(cliServiceProvider);
    final bool autoRun = (envVar('SM_TAB') ?? '').toLowerCase() == 'audit' &&
        _autoAudited.add(domain);
    return AuditView(
      runAudit: () => cli.audit(domain),
      runFix: (String id) => cli.auditFix(id, domain),
      runFixAll: () => cli.auditFixAll(domain),
      runHistory: () => cli.auditHistory(domain),
      autoRun: autoRun,
    );
  }
}

// --- Git --------------------------------------------------------------------

/// A GitKraken-style Git manager: branch header, commit graph, and a headline
/// "Push & Deploy" action that pushes then runs the deploy (reusing the deploy
/// timeline). Loads `git log`/`git status`/`git branches` on first build.
class _GitTab extends ConsumerStatefulWidget {
  const _GitTab({required this.domain});
  final String domain;

  @override
  ConsumerState<_GitTab> createState() => _GitTabState();
}

class _GitTabState extends ConsumerState<_GitTab> {
  List<GitCommit>? _commits;
  GitStatus? _status;
  List<GitBranch>? _branches;
  String? _selectedBranch;
  bool _loading = true;
  bool _dirtyExpanded = false;
  bool _loadStarted = false;

  @override
  void initState() {
    super.initState();
    // Auto-load on first open (always — the graph is the whole point of the
    // tab). With SM_TAB=git the tab is the initial one, so a screenshot lands
    // on a populated commit graph without any manual interaction.
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    if (_loadStarted) return;
    _loadStarted = true;
    final CliService cli = ref.read(cliServiceProvider);

    final List<GitCommit> commits = <GitCommit>[];
    await for (final CliEvent e in cli.gitLog(widget.domain)) {
      if (e is DataEvent && e.kind == 'git_log') {
        for (final dynamic item in e.items ?? const <dynamic>[]) {
          if (item is Map<String, dynamic>) commits.add(GitCommit.fromJson(item));
        }
      } else if (e is DoneEvent) {
        break;
      }
    }

    GitStatus? status;
    await for (final CliEvent e in cli.gitStatus(widget.domain)) {
      if (e is DataEvent && e.kind == 'git_status' && e.value != null) {
        status = GitStatus.fromJson(e.value!);
      } else if (e is DoneEvent) {
        break;
      }
    }

    final List<GitBranch> branches = <GitBranch>[];
    await for (final CliEvent e in cli.gitBranches(widget.domain)) {
      if (e is DataEvent && e.kind == 'git_branches') {
        for (final dynamic item in e.items ?? const <dynamic>[]) {
          if (item is Map<String, dynamic>) branches.add(GitBranch.fromJson(item));
        }
      } else if (e is DoneEvent) {
        break;
      }
    }

    if (!mounted) return;
    setState(() {
      _commits = commits;
      _status = status;
      _branches = branches;
      _selectedBranch ??= status?.branch ??
          branches
              .firstWhere(
                (GitBranch b) => b.current,
                orElse: () => branches.isNotEmpty
                    ? branches.first
                    : const GitBranch(name: 'main', current: true, remote: false),
              )
              .name;
      _loading = false;
    });

    // Demo/screenshot: SM_GIT_MERGE=<branch> auto-runs a merge after load so a
    // screenshot can land on the conflict-resolution view.
    final String autoMerge = envVar('SM_GIT_MERGE') ?? '';
    if (autoMerge.isNotEmpty && _autoMerged.add(widget.domain)) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _runMerge(autoMerge));
    }
  }

  /// Re-fetches only the status (after a push the ahead count drops to 0).
  Future<void> _refreshStatus() async {
    final CliService cli = ref.read(cliServiceProvider);
    GitStatus? status;
    await for (final CliEvent e in cli.gitStatus(widget.domain)) {
      if (e is DataEvent && e.kind == 'git_status' && e.value != null) {
        status = GitStatus.fromJson(e.value!);
      } else if (e is DoneEvent) {
        break;
      }
    }
    if (mounted && status != null) setState(() => _status = status);
  }

  void _pushAndDeploy() {
    final Stream<CliEvent> events =
        ref.read(cliServiceProvider).gitPushDeploy(widget.domain);
    _runDeploy(events, 'Pushed & deployed ${widget.domain}');
  }

  void _deployBranch() {
    final String branch = _selectedBranch ?? _status?.branch ?? 'main';
    final Stream<CliEvent> events =
        ref.read(cliServiceProvider).gitDeploy(widget.domain, branch);
    _runDeploy(events, 'Deployed $branch to ${widget.domain}');
  }

  /// Re-fetches branches + log (after creating a branch/tag) so the graph and
  /// dropdown reflect the new state. Optionally switches the selected branch.
  Future<void> _refreshBranchesAndLog({String? switchTo}) async {
    final CliService cli = ref.read(cliServiceProvider);

    final List<GitCommit> commits = <GitCommit>[];
    await for (final CliEvent e in cli.gitLog(widget.domain)) {
      if (e is DataEvent && e.kind == 'git_log') {
        for (final dynamic item in e.items ?? const <dynamic>[]) {
          if (item is Map<String, dynamic>) commits.add(GitCommit.fromJson(item));
        }
      } else if (e is DoneEvent) {
        break;
      }
    }

    final List<GitBranch> branches = <GitBranch>[];
    await for (final CliEvent e in cli.gitBranches(widget.domain)) {
      if (e is DataEvent && e.kind == 'git_branches') {
        for (final dynamic item in e.items ?? const <dynamic>[]) {
          if (item is Map<String, dynamic>) branches.add(GitBranch.fromJson(item));
        }
      } else if (e is DoneEvent) {
        break;
      }
    }

    if (!mounted) return;
    setState(() {
      _commits = commits;
      _branches = branches;
      if (switchTo != null) _selectedBranch = switchTo;
    });
  }

  /// Opens a dialog to create a branch, then refreshes and switches onto it.
  Future<void> _newBranch() async {
    final String? name = await _promptText(
      title: 'New branch',
      icon: Icons.account_tree_outlined,
      fieldLabel: 'Branch name',
      hint: 'feature/my-change',
      confirmLabel: 'Create branch',
      runLabel: 'Creating branch',
      run: (CliService cli, String value, [String? _]) =>
          cli.gitCreateBranch(widget.domain, value),
    );
    if (name != null) {
      await _refreshBranchesAndLog(switchTo: name);
      await _refreshStatus();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Created & checked out $name')),
        );
      }
    }
  }

  /// Opens a dialog to create a tag (with optional message), then refreshes.
  Future<void> _newTag() async {
    final String? name = await _promptText(
      title: 'New tag',
      icon: Icons.sell_outlined,
      fieldLabel: 'Tag name',
      hint: 'v1.5.0',
      secondLabel: 'Message (optional)',
      confirmLabel: 'Create tag',
      runLabel: 'Tagging',
      run: (CliService cli, String value, [String? message]) =>
          cli.gitCreateTag(widget.domain, value, message: message),
    );
    if (name != null) {
      await _refreshBranchesAndLog();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Created tag $name')),
        );
      }
    }
  }

  /// Opens the PR dialog (its own widget — it has bespoke success/failure UI).
  Future<void> _openPr() async {
    await showDialog<void>(
      context: context,
      builder: (BuildContext _) => _PrDialog(domain: widget.domain),
    );
  }

  /// Picks a branch to merge into the current one, runs `git merge`, and routes
  /// the outcome: clean → snackbar + refresh; conflicts → conflict-resolution.
  Future<void> _merge() async {
    final String current = _status?.branch ?? 'main';
    final List<GitBranch> options = (_branches ?? const <GitBranch>[])
        .where((GitBranch b) => !b.remote && b.name != current)
        .toList();
    if (options.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No other local branches to merge')),
      );
      return;
    }
    final String? branch = await showDialog<String>(
      context: context,
      builder: (BuildContext _) =>
          _MergePickerDialog(current: current, branches: options),
    );
    if (branch == null || !mounted) return;
    await _runMerge(branch);
  }

  /// Runs `git merge <branch>` and routes the outcome (clean → snackbar;
  /// conflicts → the conflict-resolution view). Extracted so it can also be
  /// auto-triggered (SM_GIT_MERGE) for demos/screenshots.
  Future<void> _runMerge(String branch) async {
    final CliService cli = ref.read(cliServiceProvider);
    List<GitConflict> conflicts = const <GitConflict>[];
    bool clean = false;
    await for (final CliEvent e in cli.gitMerge(widget.domain, branch)) {
      if (e is DataEvent && e.kind == 'git_merge') {
        clean = e.value?['clean'] == true;
      } else if (e is DataEvent && e.kind == 'git_conflicts') {
        conflicts = <GitConflict>[
          for (final dynamic item in e.items ?? const <dynamic>[])
            if (item is Map<String, dynamic>) GitConflict.fromJson(item),
        ];
      } else if (e is DoneEvent) {
        break;
      }
    }
    if (!mounted) return;

    if (clean) {
      await _refreshBranchesAndLog();
      await _refreshStatus();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Merged $branch cleanly')),
        );
      }
      return;
    }

    if (conflicts.isNotEmpty) {
      final bool? completed = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (BuildContext _) => MergeConflictView(
          domain: widget.domain,
          branch: branch,
          conflicts: conflicts,
        ),
      );
      if (!mounted) return;
      await _refreshBranchesAndLog();
      await _refreshStatus();
      if (completed == true && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Merged $branch')),
        );
      }
    }
  }

  /// Shows a one- or two-field dialog that runs [run] as a short stream with
  /// inline progress and resolves to the primary value on `done(ok:true)`, or
  /// null if cancelled/failed.
  Future<String?> _promptText({
    required String title,
    required IconData icon,
    required String fieldLabel,
    required String hint,
    required String confirmLabel,
    required String runLabel,
    required Stream<CliEvent> Function(CliService, String, [String?]) run,
    String? secondLabel,
  }) {
    return showDialog<String>(
      context: context,
      builder: (BuildContext _) => _CreateDialog(
        title: title,
        icon: icon,
        fieldLabel: fieldLabel,
        hint: hint,
        secondLabel: secondLabel,
        confirmLabel: confirmLabel,
        runLabel: runLabel,
        cli: ref.read(cliServiceProvider),
        run: run,
      ),
    );
  }

  /// Routes [events] through the git deploy controller (reusing the deploy
  /// timeline) and refreshes status + snackbars on success.
  void _runDeploy(Stream<CliEvent> events, String successMsg) {
    final DeployController controller =
        ref.read(gitDeployProvider(widget.domain).notifier);
    final Stream<CliEvent> tapped = events.map((CliEvent e) {
      if (e is DoneEvent && e.ok) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _refreshStatus();
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text(successMsg)),
            );
          }
        });
      }
      return e;
    });
    controller.start(tapped);
  }

  @override
  Widget build(BuildContext context) {
    final DeployState deployState = ref.watch(gitDeployProvider(widget.domain));

    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }

    final List<GitCommit> commits = _commits ?? const <GitCommit>[];
    final List<GitBranch> branches = _branches ?? const <GitBranch>[];
    final GitStatus? status = _status;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _GitHeader(
          status: status,
          branches: branches,
          selectedBranch: _selectedBranch,
          running: deployState.running,
          dirtyExpanded: _dirtyExpanded,
          onToggleDirty: () =>
              setState(() => _dirtyExpanded = !_dirtyExpanded),
          onSelectBranch: (String b) => setState(() => _selectedBranch = b),
          onPushDeploy: deployState.running ? null : _pushAndDeploy,
          onDeployBranch: deployState.running ? null : _deployBranch,
          onNewBranch: deployState.running ? null : _newBranch,
          onNewTag: deployState.running ? null : _newTag,
          onOpenPr: deployState.running ? null : _openPr,
          onMerge: deployState.running ? null : _merge,
        ),
        Expanded(
          child: (deployState.running || deployState.done)
              ? DeployTimeline(state: deployState)
              : _CommitGraph(commits: commits),
        ),
      ],
    );
  }
}

/// The Git tool header: branch dropdown, ahead/behind, clean/dirty chip and the
/// headline Push & Deploy action.
class _GitHeader extends StatelessWidget {
  const _GitHeader({
    required this.status,
    required this.branches,
    required this.selectedBranch,
    required this.running,
    required this.dirtyExpanded,
    required this.onToggleDirty,
    required this.onSelectBranch,
    required this.onPushDeploy,
    required this.onDeployBranch,
    required this.onNewBranch,
    required this.onNewTag,
    required this.onOpenPr,
    required this.onMerge,
  });

  final GitStatus? status;
  final List<GitBranch> branches;
  final String? selectedBranch;
  final bool running;
  final bool dirtyExpanded;
  final VoidCallback onToggleDirty;
  final ValueChanged<String> onSelectBranch;
  final VoidCallback? onPushDeploy;
  final VoidCallback? onDeployBranch;
  final VoidCallback? onNewBranch;
  final VoidCallback? onNewTag;
  final VoidCallback? onOpenPr;
  final VoidCallback? onMerge;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final GitStatus? s = status;
    final String currentBranch = s?.branch ?? '';
    // Local (non-remote) branches are the selectable deploy targets.
    final List<GitBranch> local =
        branches.where((GitBranch b) => !b.remote).toList();
    final bool nonCurrentSelected =
        selectedBranch != null && selectedBranch != currentBranch;

    return Container(
      padding: const EdgeInsets.fromLTRB(Insets.lg, Insets.lg, Insets.lg, Insets.md),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        border: Border(
          bottom: BorderSide(
            color: theme.colorScheme.outline.withValues(alpha: 0.6),
          ),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: <Widget>[
              Expanded(
                child: Wrap(
                  spacing: Insets.sm,
                  runSpacing: Insets.sm,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: <Widget>[
                    _BranchDropdown(
                      branches: local,
                      value: selectedBranch,
                      onChanged: onSelectBranch,
                    ),
                    if (s != null)
                      _AheadBehindChip(ahead: s.ahead, behind: s.behind),
                    if (s != null)
                      _CleanDirtyChip(
                        status: s,
                        expanded: dirtyExpanded,
                        onToggle: onToggleDirty,
                      ),
                  ],
                ),
              ),
              const SizedBox(width: Insets.sm),
              Wrap(
                spacing: Insets.sm,
                runSpacing: Insets.sm,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: <Widget>[
                  _GitActionsMenu(
                    onNewBranch: onNewBranch,
                    onNewTag: onNewTag,
                    onOpenPr: onOpenPr,
                    onMerge: onMerge,
                  ),
                  if (nonCurrentSelected)
                    AppButton(
                      label: 'Deploy this branch',
                      icon: Icons.alt_route,
                      tonal: true,
                      loading: running,
                      onPressed: onDeployBranch,
                    ),
                  AppButton(
                    label: 'Push & Deploy',
                    icon: Icons.rocket_launch,
                    loading: running,
                    onPressed: onPushDeploy,
                  ),
                ],
              ),
            ],
          ),
          if (s != null && !s.clean && dirtyExpanded) ...<Widget>[
            const SizedBox(height: Insets.sm),
            _DirtyFileList(files: s.dirty),
          ],
        ],
      ),
    );
  }
}

/// A small dropdown of local branches with a branch icon.
class _BranchDropdown extends StatelessWidget {
  const _BranchDropdown({
    required this.branches,
    required this.value,
    required this.onChanged,
  });

  final List<GitBranch> branches;
  final String? value;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: Insets.sm),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(Insets.radiusSm),
        border: Border.all(
          color: theme.colorScheme.primary.withValues(alpha: 0.5),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(Icons.account_tree_outlined,
              size: 15, color: theme.colorScheme.primary),
          const SizedBox(width: 6),
          DropdownButtonHideUnderline(
            child: DropdownButton<String>(
              value: value,
              isDense: true,
              borderRadius: BorderRadius.circular(Insets.radiusSm),
              style: theme.textTheme.labelLarge?.copyWith(
                color: theme.colorScheme.onSurface,
                fontWeight: FontWeight.w600,
              ),
              items: <DropdownMenuItem<String>>[
                for (final GitBranch b in branches)
                  DropdownMenuItem<String>(
                    value: b.name,
                    child: Text(b.current ? '${b.name}  ✓' : b.name),
                  ),
              ],
              onChanged: (String? v) {
                if (v != null) onChanged(v);
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// An "↑2 ↓0" ahead/behind indicator.
class _AheadBehindChip extends StatelessWidget {
  const _AheadBehindChip({required this.ahead, required this.behind});
  final int ahead;
  final int behind;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final bool synced = ahead == 0 && behind == 0;
    final Color c = synced ? Palette.ok : Palette.info;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(Insets.radiusSm),
        border: Border.all(color: c.withValues(alpha: 0.5)),
      ),
      child: Text(
        synced ? 'in sync' : '↑$ahead  ↓$behind',
        style: AppTheme.mono(context, size: 12, color: c),
      ),
    );
  }
}

/// A clean/dirty chip; dirty shows the changed-file count and is tappable to
/// expand the file list.
class _CleanDirtyChip extends StatelessWidget {
  const _CleanDirtyChip({
    required this.status,
    required this.expanded,
    required this.onToggle,
  });

  final GitStatus status;
  final bool expanded;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final bool clean = status.clean;
    final Color c = clean ? Palette.ok : Palette.warn;
    final ThemeData theme = Theme.of(context);
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: clean ? null : onToggle,
        borderRadius: BorderRadius.circular(Insets.radiusSm),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            color: c.withValues(alpha: 0.14),
            borderRadius: BorderRadius.circular(Insets.radiusSm),
            border: Border.all(color: c.withValues(alpha: 0.5)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(
                clean ? Icons.check_circle_outline : Icons.edit_note,
                size: 14,
                color: c,
              ),
              const SizedBox(width: 6),
              Text(
                clean
                    ? 'clean'
                    : '${status.dirty.length} changed',
                style: theme.textTheme.labelMedium?.copyWith(
                  color: c,
                  fontWeight: FontWeight.w600,
                ),
              ),
              if (!clean) ...<Widget>[
                const SizedBox(width: 4),
                Icon(
                  expanded ? Icons.expand_less : Icons.expand_more,
                  size: 16,
                  color: c,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// The expandable list of dirty (working-tree) files.
class _DirtyFileList extends StatelessWidget {
  const _DirtyFileList({required this.files});
  final List<String> files;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(Insets.sm),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(Insets.radiusSm),
        border: Border.all(color: theme.colorScheme.outline.withValues(alpha: 0.6)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          for (final String f in files)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(
                children: <Widget>[
                  const Icon(Icons.circle, size: 7, color: Palette.warn),
                  const SizedBox(width: Insets.sm),
                  Expanded(
                    child: Text(f, style: AppTheme.mono(context, size: 12)),
                  ),
                ],
              ),
            ),
        ],
      ),
    ).animate().fadeIn(duration: AppMotion.fast);
  }
}

/// The GitKraken-style commit list with a single main lane and merge hints.
class _CommitGraph extends StatelessWidget {
  const _CommitGraph({required this.commits});
  final List<GitCommit> commits;

  @override
  Widget build(BuildContext context) {
    if (commits.isEmpty) {
      return const Center(child: Text('No commits'));
    }
    return ListView.builder(
      padding: const EdgeInsets.symmetric(
        horizontal: Insets.lg,
        vertical: Insets.md,
      ),
      itemCount: commits.length,
      itemBuilder: (BuildContext context, int i) {
        return _CommitRow(
          commit: commits[i],
          isFirst: i == 0,
          isLast: i == commits.length - 1,
        )
            .animate()
            .fadeIn(duration: AppMotion.base, delay: (40 * i).ms)
            .slideX(begin: -0.04, curve: AppMotion.emphasized);
      },
    );
  }
}

/// One row in the commit graph: lane painter + hash + subject + refs + meta.
class _CommitRow extends StatelessWidget {
  const _CommitRow({
    required this.commit,
    required this.isFirst,
    required this.isLast,
  });

  final GitCommit commit;
  final bool isFirst;
  final bool isLast;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          // Lane: vertical line + commit dot (merge commits get an extra dot).
          SizedBox(
            width: 28,
            child: CustomPaint(
              painter: _LanePainter(
                color: theme.colorScheme.primary,
                mergeColor: Palette.teal,
                isFirst: isFirst,
                isLast: isLast,
                isMerge: commit.isMerge,
              ),
            ),
          ),
          const SizedBox(width: Insets.sm),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: Insets.sm),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Row(
                    children: <Widget>[
                      Text(
                        commit.short,
                        style: AppTheme.mono(
                          context,
                          size: 12,
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(width: Insets.sm),
                      Expanded(
                        child: Text(
                          commit.subject,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      const SizedBox(width: Insets.sm),
                      Text(
                        '${commit.author} · ${commit.relative}',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                  if (commit.refs.isNotEmpty) ...<Widget>[
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 6,
                      runSpacing: 4,
                      children: <Widget>[
                        for (final String ref in commit.refs)
                          _RefBadge(ref: ref),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// A ref pill: branch=accent, origin/remote=muted, tag=amber.
class _RefBadge extends StatelessWidget {
  const _RefBadge({required this.ref});
  final String ref;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final bool isTag = ref.startsWith('tag:');
    final bool isRemote = ref.startsWith('origin/') || ref.contains('/');
    final bool isHead = ref.startsWith('HEAD');

    final Color c;
    final IconData icon;
    if (isTag) {
      c = Palette.warn;
      icon = Icons.sell_outlined;
    } else if (isRemote && !isHead) {
      c = theme.colorScheme.onSurfaceVariant;
      icon = Icons.cloud_outlined;
    } else {
      c = theme.colorScheme.primary;
      icon = Icons.account_tree_outlined;
    }

    final String label = isTag ? ref.substring(4).trim() : ref;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(Insets.radiusSm),
        border: Border.all(color: c.withValues(alpha: 0.5)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(icon, size: 11, color: c),
          const SizedBox(width: 5),
          Text(
            label,
            style: AppTheme.mono(context, size: 11, color: c),
          ),
        ],
      ),
    );
  }
}

/// Paints the commit lane: a vertical line through the row with a dot at the
/// commit point, plus a small branch-off curve + extra dot for merge commits.
class _LanePainter extends CustomPainter {
  const _LanePainter({
    required this.color,
    required this.mergeColor,
    required this.isFirst,
    required this.isLast,
    required this.isMerge,
  });

  final Color color;
  final Color mergeColor;
  final bool isFirst;
  final bool isLast;
  final bool isMerge;

  @override
  void paint(Canvas canvas, Size size) {
    final double cx = size.width / 2;
    final double cy = size.height / 2;
    const double radius = 5;

    final Paint line = Paint()
      ..color = color.withValues(alpha: 0.6)
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke;

    // Vertical lane line (skip the half above the first / below the last dot).
    if (!isFirst) {
      canvas.drawLine(Offset(cx, 0), Offset(cx, cy), line);
    }
    if (!isLast) {
      canvas.drawLine(Offset(cx, cy), Offset(cx, size.height), line);
    }

    // Merge hint: a curved stub from a second lane into this commit dot.
    if (isMerge) {
      final Paint mergeLine = Paint()
        ..color = mergeColor.withValues(alpha: 0.7)
        ..strokeWidth = 2
        ..style = PaintingStyle.stroke;
      final Path path = Path()
        ..moveTo(cx, cy)
        ..cubicTo(
          cx + 9, cy + 2,
          cx + 9, size.height - 6,
          cx + 9, size.height,
        );
      canvas.drawPath(path, mergeLine);
      canvas.drawCircle(
        Offset(cx + 9, size.height - 3),
        2.5,
        Paint()..color = mergeColor,
      );
    }

    // Commit dot: filled core + ring.
    canvas.drawCircle(Offset(cx, cy), radius, Paint()..color = color);
    canvas.drawCircle(
      Offset(cx, cy),
      radius,
      Paint()
        ..color = color.withValues(alpha: 0.35)
        ..strokeWidth = 3
        ..style = PaintingStyle.stroke,
    );
  }

  @override
  bool shouldRepaint(_LanePainter old) =>
      old.color != color ||
      old.mergeColor != mergeColor ||
      old.isFirst != isFirst ||
      old.isLast != isLast ||
      old.isMerge != isMerge;
}

/// A "+" popup menu in the Git header offering New branch / New tag / Open PR.
class _GitActionsMenu extends StatelessWidget {
  const _GitActionsMenu({
    required this.onNewBranch,
    required this.onNewTag,
    required this.onOpenPr,
    required this.onMerge,
  });

  final VoidCallback? onNewBranch;
  final VoidCallback? onNewTag;
  final VoidCallback? onOpenPr;
  final VoidCallback? onMerge;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final bool enabled = onNewBranch != null ||
        onNewTag != null ||
        onOpenPr != null ||
        onMerge != null;
    return PopupMenuButton<String>(
      enabled: enabled,
      tooltip: 'Git actions',
      position: PopupMenuPosition.under,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Insets.radiusMd),
        side: BorderSide(color: theme.colorScheme.outline.withValues(alpha: 0.6)),
      ),
      onSelected: (String v) {
        switch (v) {
          case 'branch':
            onNewBranch?.call();
          case 'tag':
            onNewTag?.call();
          case 'pr':
            onOpenPr?.call();
          case 'merge':
            onMerge?.call();
        }
      },
      itemBuilder: (BuildContext context) => const <PopupMenuEntry<String>>[
        PopupMenuItem<String>(
          value: 'branch',
          child: ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.account_tree_outlined),
            title: Text('New branch'),
          ),
        ),
        PopupMenuItem<String>(
          value: 'tag',
          child: ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.sell_outlined),
            title: Text('New tag'),
          ),
        ),
        PopupMenuItem<String>(
          value: 'merge',
          child: ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.call_merge),
            title: Text('Merge…'),
          ),
        ),
        PopupMenuItem<String>(
          value: 'pr',
          child: ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.merge_outlined),
            title: Text('Open PR'),
          ),
        ),
      ],
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
          borderRadius: BorderRadius.circular(Insets.radiusSm),
          border: Border.all(color: theme.colorScheme.outline.withValues(alpha: 0.6)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(Icons.add, size: 16, color: theme.colorScheme.onSurface),
            const SizedBox(width: 4),
            Icon(Icons.arrow_drop_down,
                size: 18, color: theme.colorScheme.onSurfaceVariant),
          ],
        ),
      ),
    );
  }
}

/// A compact create-branch / create-tag dialog. Runs a short CLI stream with
/// inline step progress and pops the primary field value on `done(ok:true)`.
class _CreateDialog extends StatefulWidget {
  const _CreateDialog({
    required this.title,
    required this.icon,
    required this.fieldLabel,
    required this.hint,
    required this.confirmLabel,
    required this.runLabel,
    required this.cli,
    required this.run,
    this.secondLabel,
  });

  final String title;
  final IconData icon;
  final String fieldLabel;
  final String hint;
  final String? secondLabel;
  final String confirmLabel;
  final String runLabel;
  final CliService cli;
  final Stream<CliEvent> Function(CliService, String, [String?]) run;

  @override
  State<_CreateDialog> createState() => _CreateDialogState();
}

class _CreateDialogState extends State<_CreateDialog> {
  final TextEditingController _name = TextEditingController();
  final TextEditingController _second = TextEditingController();
  bool _running = false;
  String? _progressLabel;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    _second.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final String value = _name.text.trim();
    if (value.isEmpty || _running) return;
    setState(() {
      _running = true;
      _error = null;
    });
    final String? message =
        widget.secondLabel != null && _second.text.trim().isNotEmpty
            ? _second.text.trim()
            : null;
    bool ok = false;
    try {
      await for (final CliEvent e in widget.run(widget.cli, value, message)) {
        if (e is StepStart && mounted) {
          setState(() => _progressLabel = e.label);
        } else if (e is DoneEvent) {
          ok = e.ok;
          break;
        }
      }
    } on Object catch (e) {
      _error = e.toString();
    }
    if (!mounted) return;
    if (ok) {
      Navigator.of(context).pop(value);
    } else {
      setState(() {
        _running = false;
        _error ??= 'Operation failed';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return AlertDialog(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Insets.radiusLg),
      ),
      title: Row(
        children: <Widget>[
          Icon(widget.icon, color: theme.colorScheme.primary, size: 20),
          const SizedBox(width: Insets.sm),
          Text(widget.title),
        ],
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          TextField(
            controller: _name,
            autofocus: true,
            enabled: !_running,
            decoration: InputDecoration(
              labelText: widget.fieldLabel,
              hintText: widget.hint,
            ),
            onSubmitted: (_) => _submit(),
          ),
          if (widget.secondLabel != null) ...<Widget>[
            const SizedBox(height: Insets.md),
            TextField(
              controller: _second,
              enabled: !_running,
              decoration: InputDecoration(labelText: widget.secondLabel),
            ),
          ],
          if (_running) ...<Widget>[
            const SizedBox(height: Insets.md),
            Row(
              children: <Widget>[
                const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                const SizedBox(width: Insets.sm),
                Expanded(
                  child: Text(
                    _progressLabel ?? '${widget.runLabel}…',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
          ],
          if (_error != null) ...<Widget>[
            const SizedBox(height: Insets.md),
            Text(
              _error!,
              style: theme.textTheme.bodySmall?.copyWith(color: Palette.err),
            ),
          ],
        ],
      ),
      actions: <Widget>[
        TextButton(
          onPressed: _running ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        AppButton(
          label: widget.confirmLabel,
          loading: _running,
          onPressed: _submit,
        ),
      ],
    );
  }
}

/// A compact dialog to pick which branch to merge into the current one.
class _MergePickerDialog extends StatefulWidget {
  const _MergePickerDialog({required this.current, required this.branches});
  final String current;
  final List<GitBranch> branches;

  @override
  State<_MergePickerDialog> createState() => _MergePickerDialogState();
}

class _MergePickerDialogState extends State<_MergePickerDialog> {
  late String _value = widget.branches.first.name;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return AlertDialog(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Insets.radiusLg),
      ),
      title: Row(
        children: <Widget>[
          Icon(Icons.call_merge, color: theme.colorScheme.primary, size: 20),
          const SizedBox(width: Insets.sm),
          const Text('Merge branch'),
        ],
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            'Merge a branch into ${widget.current}.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: Insets.md),
          DropdownButtonFormField<String>(
            value: _value,
            decoration: const InputDecoration(labelText: 'Branch'),
            items: <DropdownMenuItem<String>>[
              for (final GitBranch b in widget.branches)
                DropdownMenuItem<String>(value: b.name, child: Text(b.name)),
            ],
            onChanged: (String? v) {
              if (v != null) setState(() => _value = v);
            },
          ),
        ],
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        AppButton(
          label: 'Merge',
          icon: Icons.call_merge,
          onPressed: () => Navigator.of(context).pop(_value),
        ),
      ],
    );
  }
}

/// The Open-PR dialog: title + base, runs `git pr`, and renders a success card
/// (with the PR url + open/copy) or a friendly "gh not available" message.
class _PrDialog extends ConsumerStatefulWidget {
  const _PrDialog({required this.domain});
  final String domain;

  @override
  ConsumerState<_PrDialog> createState() => _PrDialogState();
}

class _PrDialogState extends ConsumerState<_PrDialog> {
  final TextEditingController _title = TextEditingController();
  final TextEditingController _base = TextEditingController(text: 'main');
  bool _running = false;
  String? _progressLabel;
  Map<String, dynamic>? _result;
  bool _failed = false;

  @override
  void dispose() {
    _title.dispose();
    _base.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final String title = _title.text.trim();
    if (title.isEmpty || _running) return;
    final String base = _base.text.trim().isEmpty ? 'main' : _base.text.trim();
    setState(() {
      _running = true;
      _failed = false;
    });
    final CliService cli = ref.read(cliServiceProvider);
    Map<String, dynamic>? pr;
    bool ok = false;
    try {
      await for (final CliEvent e in cli.gitCreatePr(widget.domain, title,
          base: base)) {
        if (e is StepStart && mounted) {
          setState(() => _progressLabel = e.label);
        } else if (e is DataEvent && e.kind == 'pr') {
          pr = e.value;
        } else if (e is DoneEvent) {
          ok = e.ok;
          break;
        }
      }
    } on Object {
      ok = false;
    }
    if (!mounted) return;
    setState(() {
      _running = false;
      if (ok && pr != null) {
        _result = pr;
      } else {
        _failed = true;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return AlertDialog(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Insets.radiusLg),
      ),
      title: Row(
        children: <Widget>[
          Icon(Icons.merge_outlined, color: theme.colorScheme.primary, size: 20),
          const SizedBox(width: Insets.sm),
          const Text('Open pull request'),
        ],
      ),
      content: SizedBox(
        width: 420,
        child: _result != null
            ? _PrSuccess(pr: _result!)
            : _failed
                ? _PrFailure(onRetry: () => setState(() => _failed = false))
                : Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      TextField(
                        controller: _title,
                        autofocus: true,
                        enabled: !_running,
                        decoration: const InputDecoration(
                          labelText: 'Title',
                          hintText: 'Add idempotency keys to webhooks',
                        ),
                        onSubmitted: (_) => _submit(),
                      ),
                      const SizedBox(height: Insets.md),
                      TextField(
                        controller: _base,
                        enabled: !_running,
                        decoration: const InputDecoration(
                          labelText: 'Base branch',
                        ),
                      ),
                      if (_running) ...<Widget>[
                        const SizedBox(height: Insets.md),
                        Row(
                          children: <Widget>[
                            const SizedBox(
                              width: 16,
                              height: 16,
                              child:
                                  CircularProgressIndicator(strokeWidth: 2),
                            ),
                            const SizedBox(width: Insets.sm),
                            Expanded(
                              child: Text(
                                _progressLabel ?? 'Opening pull request…',
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: theme.colorScheme.onSurfaceVariant,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ],
                  ),
      ),
      actions: _result != null
          ? <Widget>[
              AppButton(
                label: 'Done',
                onPressed: () => Navigator.of(context).pop(),
              ),
            ]
          : <Widget>[
              TextButton(
                onPressed: _running ? null : () => Navigator.of(context).pop(),
                child: const Text('Close'),
              ),
              if (!_failed)
                AppButton(
                  label: 'Create PR',
                  icon: Icons.merge_outlined,
                  loading: _running,
                  onPressed: _submit,
                ),
            ],
    );
  }
}

/// Success card shown after a PR is created: title, base, url + open/copy.
class _PrSuccess extends StatelessWidget {
  const _PrSuccess({required this.pr});
  final Map<String, dynamic> pr;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final String url = pr['url']?.toString() ?? '';
    final String title = pr['title']?.toString() ?? '';
    final String base = pr['base']?.toString() ?? 'main';
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          children: <Widget>[
            const Icon(Icons.check_circle, color: Palette.ok, size: 20),
            const SizedBox(width: Insets.sm),
            Expanded(
              child: Text(
                'Pull request opened',
                style: theme.textTheme.titleSmall?.copyWith(color: Palette.ok),
              ),
            ),
          ],
        ),
        const SizedBox(height: Insets.md),
        if (title.isNotEmpty)
          Text(title, style: theme.textTheme.bodyMedium),
        const SizedBox(height: Insets.xs),
        Text(
          'into $base',
          style: theme.textTheme.labelSmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: Insets.md),
        Container(
          padding: const EdgeInsets.all(Insets.sm),
          decoration: BoxDecoration(
            color:
                theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
            borderRadius: BorderRadius.circular(Insets.radiusSm),
            border:
                Border.all(color: theme.colorScheme.outline.withValues(alpha: 0.6)),
          ),
          child: Row(
            children: <Widget>[
              Expanded(
                child: Text(url, style: AppTheme.mono(context, size: 12)),
              ),
              IconButton(
                tooltip: 'Copy URL',
                icon: const Icon(Icons.copy, size: 16),
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: url));
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('PR URL copied')),
                  );
                },
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Friendly failure card when the server's `gh` CLI is missing/unauthenticated.
class _PrFailure extends StatelessWidget {
  const _PrFailure({required this.onRetry});
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          children: <Widget>[
            const Icon(Icons.error_outline, color: Palette.warn, size: 20),
            const SizedBox(width: Insets.sm),
            Expanded(
              child: Text(
                "Couldn't open the pull request",
                style:
                    theme.textTheme.titleSmall?.copyWith(color: Palette.warn),
              ),
            ),
          ],
        ),
        const SizedBox(height: Insets.md),
        Text(
          'The GitHub CLI (gh) is not installed or not authenticated on the '
          'server. Install gh and run `gh auth login` there, then try again.',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: Insets.md),
        Align(
          alignment: Alignment.centerRight,
          child: TextButton.icon(
            onPressed: onRetry,
            icon: const Icon(Icons.refresh, size: 16),
            label: const Text('Try again'),
          ),
        ),
      ],
    );
  }
}
