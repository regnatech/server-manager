import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../models/site.dart';
import '../state/connection_provider.dart';
import '../state/sites_provider.dart';
import '../theme/app_theme.dart';
import '../widgets/framework_chip.dart';
import '../widgets/glass_card.dart';
import '../widgets/section_header.dart';
import '../widgets/status_dot.dart';

/// The home screen: a staggered, animated grid of site cards with refresh and
/// an "add site" entry point.
class DashboardScreen extends ConsumerWidget {
  const DashboardScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AsyncValue<List<Site>> sites = ref.watch(sitesProvider);
    final bool demo = ref.watch(demoModeProvider);
    final String? version = ref.watch(connectionProvider).version;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Sites'),
        actions: <Widget>[
          if (version != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: Insets.sm),
              child: Center(
                child: _Pill(
                  label: demo ? 'DEMO • v$version' : 'connected • v$version',
                  color: demo ? Palette.warn : Palette.ok,
                ),
              ),
            ),
          IconButton(
            tooltip: 'Terminal',
            icon: const Icon(Icons.terminal),
            onPressed: () => context.go('/terminal'),
          ),
          IconButton(
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh),
            onPressed: () => ref.invalidate(sitesProvider),
          ),
          IconButton(
            tooltip: 'Disconnect',
            icon: const Icon(Icons.logout),
            onPressed: () async {
              await ref.read(connectionProvider.notifier).disconnect();
              if (context.mounted) context.go('/connect');
            },
          ),
          const SizedBox(width: Insets.sm),
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
            final int cols = c.maxWidth ~/ 340 < 1 ? 1 : c.maxWidth ~/ 340;
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
    return GridView.builder(
      padding: const EdgeInsets.all(Insets.lg),
      itemCount: 6,
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
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
