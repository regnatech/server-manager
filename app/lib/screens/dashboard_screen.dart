import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../models/site.dart';
import '../services/cli_service.dart';
import '../state/connection_provider.dart';
import '../state/sites_provider.dart';
import '../theme/app_theme.dart';
import '../theme/breakpoints.dart';
import '../transport/cli_event.dart';
import '../widgets/app_button.dart';
import '../widgets/framework_chip.dart';
import '../widgets/glass_card.dart';
import '../widgets/section_header.dart';
import '../widgets/status_dot.dart';

/// The home screen: a staggered, animated grid of site cards with refresh and
/// an "add site" entry point.
class DashboardScreen extends ConsumerWidget {
  const DashboardScreen({super.key});

  /// Confirms, then opens the streaming multi-site deploy dialog.
  Future<void> _confirmDeployAll(BuildContext context, WidgetRef ref) async {
    final bool? go = await showDialog<bool>(
      context: context,
      builder: (BuildContext _) => AlertDialog(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(Insets.radiusLg),
        ),
        title: const Text('Deploy all sites?'),
        content: const Text(
          'This pulls the latest changes and deploys every site in turn. '
          'You can watch each step stream live.',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          AppButton(
            label: 'Deploy all',
            icon: Icons.rocket_launch,
            onPressed: () => Navigator.of(context).pop(true),
          ),
        ],
      ),
    );
    if (go != true || !context.mounted) return;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext _) => const _DeployAllDialog(),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AsyncValue<List<Site>> sites = ref.watch(sitesProvider);
    final bool demo = ref.watch(demoModeProvider);
    final String? version = ref.watch(connectionProvider).version;

    final bool phone = context.isPhone;

    Future<void> disconnect() async {
      await ref.read(connectionProvider.notifier).disconnect();
      if (context.mounted) context.go('/connect');
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Sites'),
        actions: <Widget>[
          if (version != null && !phone)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: Insets.sm),
              child: Center(
                child: _Pill(
                  label: demo ? 'DEMO • v$version' : 'connected • v$version',
                  color: demo ? Palette.warn : Palette.ok,
                ),
              ),
            ),
          if (phone) ...<Widget>[
            // Keep refresh handy; tuck the rest behind an overflow menu so the
            // bar never overflows on a narrow screen.
            IconButton(
              tooltip: 'Refresh',
              icon: const Icon(Icons.refresh),
              onPressed: () => ref.invalidate(sitesProvider),
            ),
            PopupMenuButton<String>(
              tooltip: 'More',
              icon: const Icon(Icons.more_vert),
              onSelected: (String v) {
                switch (v) {
                  case 'deploy':
                    _confirmDeployAll(context, ref);
                  case 'logout':
                    disconnect();
                }
              },
              // Health / Audit / Terminal / Settings now live in the phone
              // bottom navigation bar, so they are omitted here to avoid
              // duplication; only the actions without a bottom-bar home remain.
              itemBuilder: (BuildContext context) =>
                  const <PopupMenuEntry<String>>[
                PopupMenuItem<String>(
                  value: 'deploy',
                  child: ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(Icons.rocket_launch),
                    title: Text('Deploy all sites'),
                  ),
                ),
                PopupMenuItem<String>(
                  value: 'logout',
                  child: ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(Icons.logout),
                    title: Text('Disconnect'),
                  ),
                ),
              ],
            ),
          ] else ...<Widget>[
            IconButton(
              tooltip: 'Deploy all sites',
              icon: const Icon(Icons.rocket_launch),
              onPressed: () => _confirmDeployAll(context, ref),
            ),
            IconButton(
              tooltip: 'Server health',
              icon: const Icon(Icons.monitor_heart_outlined),
              onPressed: () => context.go('/health'),
            ),
            IconButton(
              tooltip: 'Security audit',
              icon: const Icon(Icons.shield_outlined),
              onPressed: () => context.go('/audit'),
            ),
            IconButton(
              tooltip: 'Terminal',
              icon: const Icon(Icons.terminal),
              onPressed: () => context.go('/terminal'),
            ),
            IconButton(
              tooltip: 'Settings',
              icon: const Icon(Icons.settings_outlined),
              onPressed: () => context.go('/settings'),
            ),
            IconButton(
              tooltip: 'Refresh',
              icon: const Icon(Icons.refresh),
              onPressed: () => ref.invalidate(sitesProvider),
            ),
            IconButton(
              tooltip: 'Disconnect',
              icon: const Icon(Icons.logout),
              onPressed: disconnect,
            ),
            const SizedBox(width: Insets.sm),
          ],
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => context.go('/add'),
        icon: const Icon(Icons.add),
        label: const Text('Add site'),
      ),
      body: RefreshIndicator(
        onRefresh: () async => ref.invalidate(sitesProvider),
        child: sites.when(
          loading: () => const _LoadingGrid(),
          error: (Object e, _) => _ErrorState(
            message: e.toString(),
            onRetry: () => ref.invalidate(sitesProvider),
          ),
          data: (List<Site> list) => _Grid(sites: list),
        ),
      ),
    );
  }
}

class _Grid extends StatelessWidget {
  const _Grid({required this.sites});
  final List<Site> sites;

  @override
  Widget build(BuildContext context) {
    if (sites.isEmpty) {
      return const Center(child: Text('No sites yet. Add one to get started.'));
    }
    return ListView(
      padding: const EdgeInsets.all(Insets.lg),
      children: <Widget>[
        const SectionHeader(
          title: 'Deployed sites',
          subtitle: 'Tap a card to manage deploys, cron, workers and SSL',
        ),
        const SizedBox(height: Insets.md),
        LayoutBuilder(
          builder: (BuildContext context, BoxConstraints c) {
            // 1 column on phone, 2 on tablet, 3+ on desktop.
            final int cols = c.maxWidth < Breakpoints.phone
                ? 1
                : c.maxWidth < Breakpoints.tablet
                    ? 2
                    : (c.maxWidth ~/ 340).clamp(3, 6);
            return GridView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: sites.length,
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: cols,
                mainAxisSpacing: Insets.md,
                crossAxisSpacing: Insets.md,
                mainAxisExtent: 168,
              ),
              itemBuilder: (BuildContext context, int i) {
                return _SiteCard(site: sites[i])
                    .animate(delay: Duration(milliseconds: 60 * i))
                    .fadeIn(duration: AppMotion.base)
                    .slideY(begin: 0.12, curve: AppMotion.emphasized);
              },
            );
          },
        ),
      ],
    );
  }
}

class _SiteCard extends StatelessWidget {
  const _SiteCard({required this.site});
  final Site site;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return GlassCard(
      onTap: () => context.go('/site/${site.domain}'),
      padding: const EdgeInsets.all(Insets.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              StatusDot(health: site.health),
              const SizedBox(width: Insets.sm),
              Expanded(
                child: Hero(
                  tag: 'site-title-${site.domain}',
                  child: Material(
                    type: MaterialType.transparency,
                    child: Text(
                      site.domain,
                      style: theme.textTheme.titleMedium,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
              ),
              _TlsBadge(tls: site.tls),
            ],
          ),
          const SizedBox(height: Insets.sm),
          Row(
            children: <Widget>[
              FrameworkChip(framework: site.framework),
              const SizedBox(width: Insets.sm),
              _Pill(label: site.server, color: theme.colorScheme.primary),
            ],
          ),
          const Spacer(),
          Row(
            children: <Widget>[
              Icon(
                Icons.schedule,
                size: 14,
                color: theme.colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: Insets.xs),
              Text(
                site.lastDeploy ?? 'never deployed',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const Spacer(),
              Icon(
                Icons.arrow_forward,
                size: 16,
                color: theme.colorScheme.primary,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _TlsBadge extends StatelessWidget {
  const _TlsBadge({required this.tls});
  final bool tls;

  @override
  Widget build(BuildContext context) {
    final Color c = tls ? Palette.ok : Palette.warn;
    return Tooltip(
      message: tls ? 'TLS enabled' : 'No TLS',
      child: Icon(
        tls ? Icons.lock : Icons.lock_open,
        size: 16,
        color: c,
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill({required this.label, required this.color});
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(Insets.radiusSm),
        border: Border.all(color: color.withValues(alpha: 0.5)),
      ),
      child: Text(
        label,
        style: Theme.of(context)
            .textTheme
            .labelSmall
            ?.copyWith(color: color, fontWeight: FontWeight.w600),
      ),
    );
  }
}

class _LoadingGrid extends StatelessWidget {
  const _LoadingGrid();

  @override
  Widget build(BuildContext context) {
    final double w = context.width;
    final int cols = w < Breakpoints.phone
        ? 1
        : w < Breakpoints.tablet
            ? 2
            : 3;
    return GridView.builder(
      padding: const EdgeInsets.all(Insets.lg),
      itemCount: 6,
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: cols,
        mainAxisSpacing: Insets.md,
        crossAxisSpacing: Insets.md,
        mainAxisExtent: 168,
      ),
      itemBuilder: (BuildContext context, int i) {
        return Container(
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(Insets.radiusLg),
          ),
        )
            .animate(onPlay: (AnimationController c) => c.repeat())
            .shimmer(duration: const Duration(milliseconds: 1200));
      },
    );
  }
}

class _ErrorState extends StatelessWidget {
  const _ErrorState({required this.message, required this.onRetry});
  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          const Icon(Icons.cloud_off, size: 48, color: Palette.err),
          const SizedBox(height: Insets.md),
          Text('Could not load sites', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: Insets.xs),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: Text(
              message,
              textAlign: TextAlign.center,
              style: AppTheme.mono(context, size: 12),
            ),
          ),
          const SizedBox(height: Insets.md),
          FilledButton.icon(
            onPressed: onRetry,
            icon: const Icon(Icons.refresh),
            label: const Text('Retry'),
          ),
        ],
      ),
    );
  }
}

/// A streaming multi-site deploy dialog: runs `update --all`, listing each
/// site section + its steps as they arrive, ending with a deployed/failed
/// summary banner.
class _DeployAllDialog extends ConsumerStatefulWidget {
  const _DeployAllDialog();

  @override
  ConsumerState<_DeployAllDialog> createState() => _DeployAllDialogState();
}

class _DeployAllDialogState extends ConsumerState<_DeployAllDialog> {
  /// Rendered lines: ('section'|'step', label).
  final List<(String, String)> _lines = <(String, String)>[];
  bool _running = true;
  Map<String, dynamic>? _summary;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _run());
  }

  Future<void> _run() async {
    final CliService cli = ref.read(cliServiceProvider);
    Map<String, dynamic>? summary;
    await for (final CliEvent e in cli.updateAll()) {
      if (!mounted) return;
      switch (e) {
        case SectionEvent(label: final String l):
          setState(() => _lines.add(('section', l)));
        case StepStart(label: final String l):
          setState(() => _lines.add(('step', l)));
        case DataEvent(
            kind: 'deploy_all',
            value: final Map<String, dynamic>? v,
          ):
          summary = v;
        case DoneEvent():
          break;
        default:
          break;
      }
    }
    if (!mounted) return;
    setState(() {
      _running = false;
      _summary = summary;
    });
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Map<String, dynamic>? s = _summary;
    final int deployed = (s?['deployed'] as num?)?.toInt() ?? 0;
    final int failed = (s?['failed'] as num?)?.toInt() ?? 0;
    final int total = (s?['total'] as num?)?.toInt() ?? 0;
    final double availWidth = context.width - 2 * Insets.lg;
    final double dialogWidth = availWidth < 460 ? availWidth : 460.0;

    return AlertDialog(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Insets.radiusLg),
      ),
      title: Row(
        children: <Widget>[
          if (_running)
            const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          else
            Icon(Icons.rocket_launch, color: theme.colorScheme.primary, size: 20),
          const SizedBox(width: Insets.sm),
          Text(_running ? 'Deploying all sites…' : 'Deploy all complete'),
        ],
      ),
      content: SizedBox(
        width: dialogWidth,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 320),
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    for (final (String, String) line in _lines)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 3),
                        child: line.$1 == 'section'
                            ? Text(
                                line.$2,
                                style: theme.textTheme.titleSmall?.copyWith(
                                  color: theme.colorScheme.primary,
                                  fontWeight: FontWeight.w700,
                                ),
                              )
                            : Row(
                                children: <Widget>[
                                  const Icon(
                                    Icons.check,
                                    size: 14,
                                    color: Palette.ok,
                                  ),
                                  const SizedBox(width: Insets.sm),
                                  Expanded(
                                    child: Text(
                                      line.$2,
                                      style: theme.textTheme.bodySmall,
                                    ),
                                  ),
                                ],
                              ),
                      ),
                  ],
                ),
              ),
            ),
            if (!_running && s != null) ...<Widget>[
              const SizedBox(height: Insets.md),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(Insets.md),
                decoration: BoxDecoration(
                  color: (failed == 0 ? Palette.ok : Palette.warn)
                      .withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(Insets.radiusMd),
                  border: Border.all(
                    color: (failed == 0 ? Palette.ok : Palette.warn)
                        .withValues(alpha: 0.6),
                  ),
                ),
                child: Text(
                  '$deployed/$total deployed'
                  '${failed > 0 ? ' · $failed failed' : ''}',
                  style: theme.textTheme.titleSmall?.copyWith(
                    color: failed == 0 ? Palette.ok : Palette.warn,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
      actions: <Widget>[
        AppButton(
          label: 'Close',
          onPressed:
              _running ? null : () => Navigator.of(context).pop(),
        ),
      ],
    );
  }
}
