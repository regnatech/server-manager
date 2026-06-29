import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// A primary filled button with a tactile press-scale animation and an
/// optional inline loading spinner.
///
/// The primary (non-[tonal]) variant uses a subtle accent gradient
/// ([Palette.accentGradient]) with a soft glow that strengthens on hover and
/// press, so the main action reads as lit rather than flat. Tonal buttons stay
/// calm (a flat secondary-container fill).
class AppButton extends StatefulWidget {
  const AppButton({
    super.key,
    required this.label,
    this.onPressed,
    this.icon,
    this.loading = false,
    this.tonal = false,
  });

  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final bool loading;

  /// When true, renders as a lower-emphasis tonal button.
  final bool tonal;

  @override
  State<AppButton> createState() => _AppButtonState();
}

class _AppButtonState extends State<AppButton> {
  bool _pressed = false;
  bool _hovered = false;

  bool get _enabled => widget.onPressed != null && !widget.loading;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;

    final Widget child = AnimatedSwitcher(
      duration: AppMotion.fast,
      child: widget.loading
          ? const SizedBox(
              key: ValueKey<String>('spinner'),
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : Row(
              key: const ValueKey<String>('label'),
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                if (widget.icon != null) ...<Widget>[
                  Icon(widget.icon, size: 18),
                  const SizedBox(width: 8),
                ],
                Text(widget.label),
              ],
            ),
    );

    final ButtonStyle style = widget.tonal
        ? FilledButton.styleFrom(
            backgroundColor: scheme.secondaryContainer,
            foregroundColor: scheme.onSecondaryContainer,
          )
        : FilledButton.styleFrom(
            // The gradient is painted by the wrapping container; keep the
            // button itself transparent so the gradient shows through, but
            // preserve the proper on-accent foreground/ink.
            backgroundColor: Colors.transparent,
            foregroundColor: scheme.onSecondary,
            shadowColor: Colors.transparent,
          );

    final Widget button = FilledButton(
      style: style,
      onPressed: _enabled ? widget.onPressed : null,
      child: child,
    );

    return Listener(
      onPointerDown: (_) {
        if (_enabled) setState(() => _pressed = true);
      },
      onPointerUp: (_) {
        if (_pressed) setState(() => _pressed = false);
      },
      onPointerCancel: (_) {
        if (_pressed) setState(() => _pressed = false);
      },
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: AnimatedScale(
          scale: _pressed ? 0.96 : 1.0,
          duration: AppMotion.fast,
          curve: AppMotion.standard,
          child: widget.tonal
              ? button
              : _GradientShell(
                  enabled: _enabled,
                  glow: _pressed ? 0.42 : (_hovered ? 0.28 : 0.16),
                  child: button,
                ),
        ),
      ),
    );
  }
}

/// Paints the accent gradient + soft glow behind a transparent [FilledButton]
/// so the primary action reads as lit. Desaturates when disabled.
class _GradientShell extends StatelessWidget {
  const _GradientShell({
    required this.child,
    required this.enabled,
    required this.glow,
  });

  final Widget child;
  final bool enabled;
  final double glow;

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: AppMotion.fast,
      curve: AppMotion.standard,
      decoration: BoxDecoration(
        gradient: enabled
            ? Palette.accentGradient
            : LinearGradient(
                colors: <Color>[
                  Palette.tealDeep.withValues(alpha: 0.4),
                  Palette.tealDeep.withValues(alpha: 0.4),
                ],
              ),
        borderRadius: BorderRadius.circular(Insets.radiusMd),
        boxShadow: enabled
            ? <BoxShadow>[
                BoxShadow(
                  color: Palette.teal.withValues(alpha: glow),
                  blurRadius: 18,
                  offset: const Offset(0, 6),
                ),
              ]
            : const <BoxShadow>[],
      ),
      child: child,
    );
  }
}
