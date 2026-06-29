import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// A primary filled button with a tactile press-scale animation and an
/// optional inline loading spinner.
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
        : const ButtonStyle();

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
      child: AnimatedScale(
        scale: _pressed ? 0.96 : 1.0,
        duration: AppMotion.fast,
        curve: AppMotion.standard,
        child: FilledButton(
          style: style,
          onPressed: _enabled ? widget.onPressed : null,
          child: child,
        ),
      ),
    );
  }
}
