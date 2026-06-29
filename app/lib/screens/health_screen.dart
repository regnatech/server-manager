import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../models/server_metrics.dart';
import '../services/cli_service.dart';
import '../state/connection_provider.dart';
import '../transport/cli_event.dart';
import '../theme/app_theme.dart';
import '../widgets/glass_card.dart';
import '../widgets/section_header.dart';

/// Live "Server Health" screen, reached from the dashboard.
///
/// Runs `server --json metrics`, showing a spinner with the current step until
/// the metrics [DataEvent] arrives, then renders CPU/memory/disk gauges, load &
/// uptime tiles, and a wrap of service pills. Auto-runs on first frame so a
/// screenshot launched at `SM_ROUTE=/health` lands on populated data.
class HealthScreen extends ConsumerStatefulWidget {
  const HealthScreen({super.key});

  @override
  ConsumerState<HealthScreen> createState() => _HealthScreenState();
}

class _HealthScreenState extends ConsumerState<HealthScreen> {
  bool _running = false;
  bool _hasRun = false;
  String _statusLabel = '';
  ServerMetrics? _metrics;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _run());
  }

  Future<void> _run() async {
    if (_running) return;
    setState(() {
      _running = true;
      _hasRun = true;
      _statusLabel = 'Reading server metrics…';
    });
    ServerMetrics? result;
    try {
      final CliService cli = ref.read(cliServiceProvider);
      await for (final CliEvent e in cli.metrics()) {
        if (!mounted) return;
        switch (e) {
          case BannerEvent(label: final String l):
            setState(() => _statusLabel = l);
          case StepStart(label: final String l):
            setState(() => _statusLabel = l);
          case DataEvent(kind: 'metrics', value: final Map<String, dynamic>? v):
            if (v != null) result = ServerMetrics.fromJson(v);
          default:
            break;
        }
      }
    } finally {
      if (mounted) {
        setState(() {
          _running = false;
          _metrics = result ?? _metrics;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final bool demo = ref.watch(demoModeProvider);
    final ServerMetrics? m = _metrics;

    final String label;
    if (m != null && (m.server.isNotEmpty || m.host.isNotEmpty)) {
      label = m.host.isNotEmpty ? '${m.server} • ${m.host}' : m.server;
    } else {
      final String? host = ref.watch(connectionProvider).profile?.host;
      label = demo ? 'demo' : (host ?? 'control node');
    }

    final bool showProgress = (_running || !_hasRun) && m == null;

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => context.go('/dashboard'),
        ),
        title: Text('Server Health — $label'),
        actions: <Widget>[
          IconButton(
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh),
            onPressed: _running ? null : _run,
          ),
          const SizedBox(width: Insets.sm),
        ],
      ),
      body: showProgress
          ? _Progress(label: _statusLabel)
          : (m == null
              ? _Progress(label: _statusLabel)
              : _MetricsBody(metrics: m)),
    );
  }
}

/// Threshold color: green below 70, amber 70–89, red at/above 90.
Color _thresholdColor(num pct) {
  if (pct >= 90) return Palette.err;
  if (pct >= 70) return Palette.warn;
  return Palette.ok;
}

/// A live spinner with the current step label while metrics are read.
class _Progress extends StatelessWidget {
  const _Progress({required this.label});
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
            label.isEmpty ? 'Reading metrics…' : label,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

/// The populated metrics layout: gauges, stat tiles, and services.
class _MetricsBody extends StatelessWidget {
  const _MetricsBody({required this.metrics});
  final ServerMetrics metrics;

  @override
  Widget build(BuildContext context) {
    final ServerMetrics m = metrics;
    final List<double> load = m.load;
    String loadAt(int i) =>
        i < load.length ? load[i].toStringAsFixed(2) : '—';

    return ListView(
      padding: const EdgeInsets.all(Insets.lg),
      children: <Widget>[
        const SectionHeader(
          title: 'Resources',
          subtitle: 'Live CPU, memory and disk utilisation',
        ),
        const SizedBox(height: Insets.md),
        LayoutBuilder(
          builder: (BuildContext context, BoxConstraints c) {
            final bool wide = c.maxWidth >= 720;
            final List<Widget> cards = <Widget>[
              _MetricCard(
                title: 'CPU',
                icon: Icons.memory,
                pct: m.cpuPct,
                subLabel: '${m.cpuCount} cores',
              ),
              _MetricCard(
                title: 'Memory',
                icon: Icons.developer_board,
                pct: m.mem.pct,
                subLabel: m.mem.humanUsedOfTotal,
              ),
              _MetricCard(
                title: 'Disk',
                icon: Icons.storage,
                pct: m.disk.pct,
                subLabel: m.disk.humanUsedOfTotal,
              ),
            ];
            return _staggered(
              wide
                  ? Row(
                      children: <Widget>[
                        for (int i = 0; i < cards.length; i++) ...<Widget>[
                          if (i > 0) const SizedBox(width: Insets.md),
                          Expanded(child: cards[i]),
                        ],
                      ],
                    )
                  : Column(
                      children: <Widget>[
                        for (int i = 0; i < cards.length; i++) ...<Widget>[
                          if (i > 0) const SizedBox(height: Insets.md),
                          cards[i],
                        ],
                      ],
                    ),
              0,
            );
          },
        ),
        const SizedBox(height: Insets.lg),
        _staggered(
          Row(
            children: <Widget>[
              Expanded(
                child: _StatTile(
                  icon: Icons.speed,
                  label: 'Load average',
                  value: '${loadAt(0)}  ${loadAt(1)}  ${loadAt(2)}',
                  caption: '1 / 5 / 15 min',
                ),
              ),
              const SizedBox(width: Insets.md),
              Expanded(
                child: _StatTile(
                  icon: Icons.timer_outlined,
                  label: 'Uptime',
                  value: m.uptimeHuman,
                  caption: 'since last boot',
                ),
              ),
            ],
          ),
          1,
        ),
        const SizedBox(height: Insets.lg),
        const SectionHeader(
          title: 'Services',
          subtitle: 'systemd units and their current state',
        ),
        const SizedBox(height: Insets.md),
        _staggered(
          Wrap(
            spacing: Insets.sm,
            runSpacing: Insets.sm,
            children: <Widget>[
              for (final ServiceStatus s in m.services)
                _ServicePill(service: s),
            ],
          ),
          2,
        ),
      ],
    );
  }

  /// Wraps [child] in the dashboard's staggered fade+slide entrance.
  Widget _staggered(Widget child, int index) {
    return child
        .animate(delay: Duration(milliseconds: 80 * index))
        .fadeIn(duration: AppMotion.base)
        .slideY(begin: 0.12, curve: AppMotion.emphasized);
  }
}

/// A big resource card: circular gauge, large percent, and a sub-label.
class _MetricCard extends StatelessWidget {
  const _MetricCard({
    required this.title,
    required this.icon,
    required this.pct,
    required this.subLabel,
  });

  final String title;
  final IconData icon;
  final num pct;
  final String subLabel;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Color color = _thresholdColor(pct);

    return GlassCard(
      padding: const EdgeInsets.all(Insets.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(icon, size: 18, color: color),
              const SizedBox(width: Insets.sm),
              Text(
                title,
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
          const SizedBox(height: Insets.md),
          Center(
            child: _Gauge(pct: pct, color: color),
          ),
          const SizedBox(height: Insets.md),
          Center(
            child: Text(
              subLabel,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// A circular progress gauge with the percentage centered inside it.
class _Gauge extends StatelessWidget {
  const _Gauge({required this.pct, required this.color, this.size = 116});

  final num pct;
  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final double fraction = (pct / 100).clamp(0, 1).toDouble();

    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        alignment: Alignment.center,
        children: <Widget>[
          SizedBox(
            width: size,
            height: size,
            child: CustomPaint(
              painter: _GaugePainter(
                fraction: fraction,
                color: color,
                track: theme.colorScheme.surfaceContainerHighest
                    .withValues(alpha: 0.6),
                stroke: 10,
              ),
            ),
          ),
          Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text(
                '${pct.round()}',
                style: theme.textTheme.headlineMedium?.copyWith(
                  fontWeight: FontWeight.w800,
                  color: color,
                  height: 1.0,
                ),
              ),
              Text(
                '%',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Paints a rounded arc gauge from the 12-o'clock position, clockwise.
class _GaugePainter extends CustomPainter {
  const _GaugePainter({
    required this.fraction,
    required this.color,
    required this.track,
    required this.stroke,
  });

  final double fraction;
  final Color color;
  final Color track;
  final double stroke;

  @override
  void paint(Canvas canvas, Size size) {
    final Offset center = size.center(Offset.zero);
    final double radius = (math.min(size.width, size.height) - stroke) / 2;
    final Rect rect = Rect.fromCircle(center: center, radius: radius);
    const double start = -math.pi / 2;

    final Paint trackPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round
      ..color = track;
    canvas.drawArc(rect, start, 2 * math.pi, false, trackPaint);

    if (fraction > 0) {
      final Paint arc = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke
        ..strokeCap = StrokeCap.round
        ..color = color;
      canvas.drawArc(rect, start, 2 * math.pi * fraction, false, arc);
    }
  }

  @override
  bool shouldRepaint(_GaugePainter old) =>
      old.fraction != fraction ||
      old.color != color ||
      old.track != track ||
      old.stroke != stroke;
}

/// A small labelled stat (load average / uptime) inside a [GlassCard].
class _StatTile extends StatelessWidget {
  const _StatTile({
    required this.icon,
    required this.label,
    required this.value,
    required this.caption,
  });

  final IconData icon;
  final String label;
  final String value;
  final String caption;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return GlassCard(
      padding: const EdgeInsets.all(Insets.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(icon, size: 16, color: theme.colorScheme.primary),
              const SizedBox(width: Insets.sm),
              Text(
                label,
                style: theme.textTheme.labelMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
          const SizedBox(height: Insets.sm),
          Text(
            value,
            style: AppTheme.mono(context, size: 18).copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: Insets.xs),
          Text(
            caption,
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

/// One service rendered as a pill: colored dot + name + active/inactive.
class _ServicePill extends StatelessWidget {
  const _ServicePill({required this.service});
  final ServiceStatus service;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Color color = service.active ? Palette.ok : Palette.err;

    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: Insets.md,
        vertical: Insets.sm,
      ),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(Insets.radiusSm),
        border: Border.all(color: color.withValues(alpha: 0.45)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Container(
            width: 9,
            height: 9,
            decoration: BoxDecoration(
              color: color,
              shape: BoxShape.circle,
              boxShadow: <BoxShadow>[
                BoxShadow(
                  color: color.withValues(alpha: 0.5),
                  blurRadius: 8,
                  spreadRadius: 1,
                ),
              ],
            ),
          ),
          const SizedBox(width: Insets.sm),
          Text(
            service.name,
            style: theme.textTheme.labelMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(width: Insets.sm),
          Text(
            service.active ? 'active' : 'inactive',
            style: theme.textTheme.labelSmall?.copyWith(
              color: color,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}
