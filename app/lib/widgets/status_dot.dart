import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// A small colored health indicator with a soft pulsing glow.
///
/// The glow gently breathes via an [AnimatedContainer]-driven repeating
/// animation so a healthy dashboard feels alive without being noisy.
class StatusDot extends StatefulWidget {
  const StatusDot({
    super.key,
    required this.health,
    this.size = 10,
    this.pulse = true,
  });

  /// Health string, e.g. `ok`, `degraded`, `down`.
  final String? health;
  final double size;
  final bool pulse;

  @override
  State<StatusDot> createState() => _StatusDotState();
}

class _StatusDotState extends State<StatusDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1600),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final Color color = Palette.forHealth(widget.health);
    if (!widget.pulse) {
      return _dot(color, glow: 0.4);
    }
    return AnimatedBuilder(
      animation: _controller,
      builder: (BuildContext context, _) {
        final double t = Curves.easeInOut.transform(_controller.value);
        return _dot(color, glow: 0.25 + t * 0.55);
      },
    );
  }

  Widget _dot(Color color, {required double glow}) {
    return Container(
      width: widget.size,
      height: widget.size,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        boxShadow: <BoxShadow>[
          BoxShadow(
            color: color.withValues(alpha: glow),
            blurRadius: widget.size * 1.2,
            spreadRadius: widget.size * 0.18,
          ),
        ],
      ),
    );
  }
}
