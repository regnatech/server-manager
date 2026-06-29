import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/deploy_provider.dart';
import '../transport/cli_event.dart';
import '../theme/app_theme.dart';
import 'animated_step_node.dart';
import 'section_header.dart';

/// Renders a live [DeployState] as an animated vertical timeline.
///
/// New step nodes slide+fade in as they arrive; the active progress bar and
/// the final report card animate in/out. Each node's log section is
/// independently expandable.
class DeployTimeline extends StatefulWidget {
  const DeployTimeline({super.key, required this.state});

  final DeployState state;

  @override
  State<DeployTimeline> createState() => _DeployTimelineState();
}

class _DeployTimelineState extends State<DeployTimeline> {
  /// Step ids whose log panel is expanded.
  final Set<String> _expanded = <String>{};

  @override
  Widget build(BuildContext context) {
    final DeployState s = widget.state;
    final ThemeData theme = Theme.of(context);

    if (!s.running && !s.done && s.steps.isEmpty) {
      return _Idle(theme: theme);
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.all(Insets.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          if (s.banner != null)
            Text(
              s.banner!,
              style: theme.textTheme.titleMedium
                  ?.copyWith(color: theme.colorScheme.primary),
            ).animate().fadeIn(duration: AppMotion.base),
          if (s.section != null) ...<Widget>[
            const SizedBox(height: Insets.sm),
            SectionHeader(title: s.section!),
          ],
          const SizedBox(height: Insets.md),

          // Live progress bar.
          if (s.running && s.progressFraction != null) ...<Widget>[
            _ProgressBar(
              fraction: s.progressFraction!,
              label: s.progressLabel,
            ),
            const SizedBox(height: Insets.lg),
          ],

          // Preamble logs (before any step).
          if (s.preamble.isNotEmpty) _Preamble(lines: s.preamble),

          // Timeline nodes.
          for (int i = 0; i < s.steps.length; i++)
            AnimatedStepNode(
              key: ValueKey<String>(s.steps[i].id),
              step: s.steps[i],
              isLast: i == s.steps.length - 1,
              expanded: _expanded.contains(s.steps[i].id),
              onToggle: () => _toggle(s.steps[i].id),
            )
                .animate()
                .fadeIn(duration: AppMotion.base)
                .slideX(begin: -0.05, curve: AppMotion.emphasized),

          if (s.report != null) ...<Widget>[
            const SizedBox(height: Insets.md),
            _ReportCard(report: s.report!),
          ],

          if (s.done) ...<Widget>[
            const SizedBox(height: Insets.md),
            _DoneBanner(ok: s.ok ?? false, error: s.errorMessage),
          ],
        ],
      ),
    );
  }

  void _toggle(String id) {
    setState(() {
      if (!_expanded.add(id)) _expanded.remove(id);
    });
  }
}

class _Idle extends StatelessWidget {
  const _Idle({required this.theme});
  final ThemeData theme;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(
            Icons.rocket_launch_outlined,
            size: 48,
            color: theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(height: Insets.md),
          Text(
            'No deploy running',
            style: theme.textTheme.titleMedium,
          ),
          const SizedBox(height: Insets.xs),
          Text(
            'Start a deploy to watch each step stream in real time.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

class _ProgressBar extends StatelessWidget {
  const _ProgressBar({required this.fraction, this.label});
  final double fraction;
  final String? label;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        if (label != null)
          Text(label!, style: theme.textTheme.labelMedium),
        const SizedBox(height: Insets.xs),
        ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: TweenAnimationBuilder<double>(
            tween: Tween<double>(end: fraction),
            duration: AppMotion.base,
            curve: AppMotion.standard,
            builder: (BuildContext context, double value, _) {
              return LinearProgressIndicator(
                value: value,
                minHeight: 8,
                backgroundColor:
                    theme.colorScheme.surfaceContainerHighest,
              );
            },
          ),
        ),
      ],
    );
  }
}

class _Preamble extends StatelessWidget {
  const _Preamble({required this.lines});
  final List<LogLine> lines;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: Insets.md),
      padding: const EdgeInsets.all(Insets.sm),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(Insets.radiusSm),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          for (final LogLine l in lines)
            Text(
              l.msg,
              style: AppTheme.mono(
                context,
                size: 12,
                color: Palette.forLevel(l.level),
              ),
            ),
        ],
      ),
    );
  }
}

class _ReportCard extends StatelessWidget {
  const _ReportCard({required this.report});
  final ReportEvent report;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(Insets.lg),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: <Color>[
            Palette.violet.withValues(alpha: 0.18),
            Palette.teal.withValues(alpha: 0.12),
          ],
        ),
        borderRadius: BorderRadius.circular(Insets.radiusLg),
        border: Border.all(color: Palette.violet.withValues(alpha: 0.5)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(report.title, style: theme.textTheme.titleMedium),
          const SizedBox(height: Insets.md),
          for (final MapEntry<String, String> e in report.fields.entries)
            Padding(
              padding: const EdgeInsets.only(bottom: Insets.xs),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
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
                    child: SelectableText(
                      e.value,
                      style: AppTheme.mono(context, size: 12),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    ).animate().fadeIn(duration: AppMotion.slow).scaleXY(
          begin: 0.97,
          curve: AppMotion.emphasized,
        );
  }
}

class _DoneBanner extends StatelessWidget {
  const _DoneBanner({required this.ok, this.error});
  final bool ok;
  final String? error;

  @override
  Widget build(BuildContext context) {
    final Color color = ok ? Palette.ok : Palette.err;
    final ThemeData theme = Theme.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(Insets.md),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(Insets.radiusMd),
        border: Border.all(color: color.withValues(alpha: 0.6)),
      ),
      child: Row(
        children: <Widget>[
          Icon(ok ? Icons.verified_rounded : Icons.error_rounded, color: color),
          const SizedBox(width: Insets.md),
          Expanded(
            child: Text(
              ok ? 'Completed successfully' : (error ?? 'Operation failed'),
              style: theme.textTheme.titleSmall?.copyWith(color: color),
            ),
          ),
        ],
      ),
    ).animate().fadeIn(duration: AppMotion.base);
  }
}
