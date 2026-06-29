import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';

import '../state/deploy_provider.dart';
import '../theme/app_theme.dart';

/// One node in the deploy timeline: an animated status indicator, the step
/// label + duration, an animated connector to the next node, and an
/// expandable log section.
///
/// The indicator morphs from a rotating spinner (running) to a check or cross
/// (finished). The connector "fills" from top to bottom as the step completes.
class AnimatedStepNode extends StatelessWidget {
  const AnimatedStepNode({
    super.key,
    required this.step,
    required this.isLast,
    required this.expanded,
    required this.onToggle,
  });

  final DeployStep step;
  final bool isLast;
  final bool expanded;
  final VoidCallback onToggle;

  Color _statusColor(BuildContext context) {
    switch (step.status) {
      case StepStatus.ok:
        return Palette.ok;
      case StepStatus.failed:
        return Palette.err;
      case StepStatus.running:
        return Palette.info;
      case StepStatus.pending:
        return Theme.of(context).colorScheme.onSurfaceVariant;
    }
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Color color = _statusColor(context);
    final bool hasLogs = step.logs.isNotEmpty || step.error != null;

    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          // Indicator + connector rail.
          Column(
            children: <Widget>[
              _StatusIndicator(status: step.status, color: color),
              if (!isLast)
                Expanded(
                  child: _Connector(
                    filled: step.status == StepStatus.ok ||
                        step.status == StepStatus.failed,
                    color: color,
                  ),
                ),
            ],
          ),
          const SizedBox(width: Insets.md),
          // Body.
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(bottom: Insets.md),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  InkWell(
                    onTap: hasLogs ? onToggle : null,
                    borderRadius: BorderRadius.circular(Insets.radiusSm),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 2),
                      child: Row(
                        children: <Widget>[
                          Expanded(
                            child: Text(
                              step.label,
                              style: theme.textTheme.titleSmall?.copyWith(
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          if (step.durationSeconds != null)
                            Padding(
                              padding: const EdgeInsets.only(left: Insets.sm),
                              child: Text(
                                '${step.durationSeconds!.toStringAsFixed(1)}s',
                                style: theme.textTheme.labelSmall?.copyWith(
                                  color: theme.colorScheme.onSurfaceVariant,
                                ),
                              ),
                            ),
                          if (hasLogs)
                            AnimatedRotation(
                              turns: expanded ? 0.25 : 0,
                              duration: AppMotion.fast,
                              child: Icon(
                                Icons.chevron_right,
                                size: 18,
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                  AnimatedSize(
                    duration: AppMotion.base,
                    curve: AppMotion.emphasized,
                    alignment: Alignment.topCenter,
                    child: (expanded && hasLogs)
                        ? _LogPanel(step: step)
                        : const SizedBox(width: double.infinity),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _StatusIndicator extends StatelessWidget {
  const _StatusIndicator({required this.status, required this.color});

  final StepStatus status;
  final Color color;

  @override
  Widget build(BuildContext context) {
    const double size = 26;
    final Widget inner = switch (status) {
      StepStatus.running => SizedBox(
          width: size,
          height: size,
          child: CircularProgressIndicator(
            strokeWidth: 2.4,
            valueColor: AlwaysStoppedAnimation<Color>(color),
          ),
        ),
      StepStatus.ok => _badge(Icons.check_rounded, color),
      StepStatus.failed => _badge(Icons.close_rounded, color),
      StepStatus.pending => _badge(Icons.circle_outlined, color),
    };

    // Animate the check/cross "popping" in when a step finishes.
    if (status == StepStatus.ok || status == StepStatus.failed) {
      return inner
          .animate()
          .scale(
            duration: AppMotion.base,
            curve: Curves.elasticOut,
            begin: const Offset(0.4, 0.4),
            end: const Offset(1, 1),
          )
          .fadeIn(duration: AppMotion.fast);
    }
    return inner;
  }

  Widget _badge(IconData icon, Color color) {
    const double size = 26;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.16),
        shape: BoxShape.circle,
        border: Border.all(color: color, width: 1.6),
      ),
      child: Icon(icon, size: 16, color: color),
    );
  }
}

/// Vertical connector between two nodes. When [filled], an accent line grows
/// from top to bottom over the connector track.
class _Connector extends StatelessWidget {
  const _Connector({required this.filled, required this.color});

  final bool filled;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final Color track =
        Theme.of(context).colorScheme.outline.withValues(alpha: 0.4);
    return Container(
      width: 2,
      margin: const EdgeInsets.symmetric(vertical: 2),
      color: track,
      child: AnimatedAlign(
        duration: AppMotion.slow,
        curve: AppMotion.emphasized,
        alignment: Alignment.topCenter,
        heightFactor: filled ? 1.0 : 0.0,
        child: Container(width: 2, color: color),
      ),
    );
  }
}

class _LogPanel extends StatelessWidget {
  const _LogPanel({required this.step});

  final DeployStep step;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(top: Insets.sm),
      padding: const EdgeInsets.all(Insets.sm),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(Insets.radiusSm),
        border: Border.all(
          color: theme.colorScheme.outline.withValues(alpha: 0.5),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          for (final LogLine line in step.logs)
            Text.rich(
              TextSpan(
                children: <InlineSpan>[
                  TextSpan(
                    text: '${line.level.padRight(4)} ',
                    style: AppTheme.mono(
                      context,
                      size: 12,
                      color: Palette.forLevel(line.level),
                    ),
                  ),
                  TextSpan(
                    text: line.msg,
                    style: AppTheme.mono(context, size: 12),
                  ),
                ],
              ),
            ),
          if (step.error != null)
            Padding(
              padding: const EdgeInsets.only(top: Insets.xs),
              child: Text(
                step.error!,
                style: AppTheme.mono(context, size: 12, color: Palette.err),
              ),
            ),
        ],
      ),
    );
  }
}
