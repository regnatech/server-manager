import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// A subtly elevated surface that lifts and brightens on hover.
///
/// Hover state is animated with [AnimatedContainer] using [AppMotion.fast] so
/// pointer feedback feels immediate but smooth on desktop. A faint top-lit
/// sheen (keyed to [accent], default brand violet) makes the panel feel lit
/// from above; the border brightens toward [accent] on hover.
class GlassCard extends StatefulWidget {
  const GlassCard({
    super.key,
    required this.child,
    this.onTap,
    this.padding = const EdgeInsets.all(Insets.md),
    this.borderRadius = Insets.radiusLg,
    this.accent,
  });

  final Widget child;
  final VoidCallback? onTap;
  final EdgeInsetsGeometry padding;
  final double borderRadius;

  /// Tints the top-lit sheen and the hover border. Defaults to the brand
  /// violet via [Palette.cardSheen].
  final Color? accent;

  @override
  State<GlassCard> createState() => _GlassCardState();
}

class _GlassCardState extends State<GlassCard> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final bool interactive = widget.onTap != null;
    final Color accent = widget.accent ?? scheme.primary;

    return MouseRegion(
      cursor: interactive ? SystemMouseCursors.click : MouseCursor.defer,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedScale(
          scale: _hovered && interactive ? 1.012 : 1.0,
          duration: AppMotion.fast,
          curve: AppMotion.decelerate,
          child: AnimatedContainer(
            duration: AppMotion.fast,
            curve: AppMotion.standard,
            transform: Matrix4.translationValues(0, _hovered ? -3 : 0, 0),
            decoration: BoxDecoration(
              color: Color.lerp(
                Theme.of(context).cardTheme.color,
                scheme.surfaceContainerHighest,
                _hovered ? 0.5 : 0.0,
              ),
              borderRadius: BorderRadius.circular(widget.borderRadius),
              border: Border.all(
                color: _hovered
                    ? accent.withValues(alpha: 0.6)
                    : scheme.outline.withValues(alpha: 0.6),
              ),
              boxShadow: <BoxShadow>[
                BoxShadow(
                  color: Colors.black.withValues(alpha: _hovered ? 0.34 : 0.18),
                  blurRadius: _hovered ? 30 : 16,
                  offset: Offset(0, _hovered ? 14 : 7),
                ),
                if (_hovered)
                  BoxShadow(
                    color: accent.withValues(alpha: 0.12),
                    blurRadius: 24,
                    offset: const Offset(0, 6),
                  ),
              ],
            ),
            child: DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(widget.borderRadius),
                gradient: Palette.cardSheen(
                  accent: accent,
                  alpha: _hovered ? 0.10 : 0.06,
                ),
              ),
              child: Padding(padding: widget.padding, child: widget.child),
            ),
          ),
        ),
      ),
    );
  }
}
