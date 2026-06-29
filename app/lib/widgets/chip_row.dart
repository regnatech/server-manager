import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// A single-row, horizontally scrollable run of chips.
///
/// Use this anywhere a horizontal sequence of chips could overflow on a narrow
/// screen: instead of a [Wrap] that line-breaks (or a fixed [Row] that
/// overflows), the children stay on one swipeable line. The scrollbar is hidden
/// and content is clipped so it reads as a clean, contained strip.
class ChipRow extends StatelessWidget {
  const ChipRow({
    super.key,
    required this.children,
    this.spacing = Insets.sm,
    this.padding = EdgeInsets.zero,
  });

  /// The chips to lay out, left to right.
  final List<Widget> children;

  /// Horizontal gap between adjacent chips.
  final double spacing;

  /// Edge padding around the row (e.g. to inset the first/last chip).
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    return ScrollConfiguration(
      // Hide the scrollbar so the strip stays clean; the row is still
      // drag/scroll-wheel scrollable on every platform.
      behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        clipBehavior: Clip.hardEdge,
        padding: padding,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            for (int i = 0; i < children.length; i++) ...<Widget>[
              if (i > 0) SizedBox(width: spacing),
              children[i],
            ],
          ],
        ),
      ),
    );
  }
}
