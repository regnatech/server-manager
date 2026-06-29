import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// A subtly elevated surface that lifts and brightens on hover.
///
/// Hover state is animated with [AnimatedContainer] using [AppMotion.fast] so
/// pointer feedback feels immediate but smooth on desktop.
class GlassCard extends StatefulWidget {
  const GlassCard({
    super.key,
    required this.child,
    this.onTap,
    this.padding = const EdgeInsets.all(Insets.md),
    this.borderRadius = Insets.radiusLg,
  });

  final Widget child;
  final VoidCallback? onTap;
  final EdgeInsetsGeometry padding;
  final double borderRadius;

  @override
  State<GlassCard> createState() => _GlassCardState();
}

class _GlassCardState extends State<GlassCard> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final bool interactive = widget.onTap != null;

    return MouseRegion(
      cursor: interactive ? SystemMouseCursors.click : MouseCursor.defer,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: AppMotion.fast,
          curve: AppMotion.standard,
          transform: Matrix4.translationValues(0, _hovered ? -3 : 0, 0),
          padding: widget.padding,
          decoration: BoxDecoration(
            color: Color.lerp(
              Theme.of(context).cardTheme.color,
              scheme.surfaceContainerHighest,
              _hovered ? 0.5 : 0.0,
            ),
            borderRadius: BorderRadius.circular(widget.borderRadius),
            border: Border.all(
              color: _hovered
                  ? scheme.primary.withValues(alpha: 0.55)
                  : scheme.outline.withValues(alpha: 0.6),
            ),
            boxShadow: <BoxShadow>[
              BoxShadow(
                color: Colors.black.withValues(alpha: _hovered ? 0.30 : 0.16),
                blurRadius: _hovered ? 26 : 14,
                offset: Offset(0, _hovered ? 12 : 6),
              ),
            ],
          ),
          child: widget.child,
        ),
      ),
    );
  }
}
