import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// A compact chip labeling a site's framework (Laravel, Next.js, ...).
///
/// Each known framework gets a stable accent color so cards are scannable.
class FrameworkChip extends StatelessWidget {
  const FrameworkChip({super.key, required this.framework});

  final String framework;

  /// The stable accent color for a framework name. Exposed so cards can tint
  /// themselves to match their framework chip without duplicating the mapping.
  static Color accentFor(String framework) {
    switch (framework.toLowerCase()) {
      case 'laravel':
        return const Color(0xFFFF2D20);
      case 'next':
      case 'nextjs':
      case 'next.js':
        return const Color(0xFF8AB4F8);
      case 'node':
      case 'nodejs':
        return const Color(0xFF68A063);
      case 'django':
        return const Color(0xFF0C4B33);
      case 'rails':
        return const Color(0xFFCC0000);
      case 'static':
        return Palette.info;
      default:
        return Palette.violet;
    }
  }

  Color get _accent => accentFor(framework);

  @override
  Widget build(BuildContext context) {
    final Color c = _accent;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(Insets.radiusSm),
        border: Border.all(color: c.withValues(alpha: 0.5)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Container(
            width: 7,
            height: 7,
            decoration: BoxDecoration(color: c, shape: BoxShape.circle),
          ),
          const SizedBox(width: 6),
          Text(
            framework,
            style: Theme.of(context)
                .textTheme
                .labelMedium
                ?.copyWith(fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }
}
