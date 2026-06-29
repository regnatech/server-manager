import 'package:flutter/widgets.dart';

/// Shared responsive breakpoints for the app.
///
/// Below [phone] is a handset; [phone]–[tablet] is a small tablet / split view;
/// at or above [tablet] is the desktop layout that must stay unchanged.
class Breakpoints {
  const Breakpoints._();

  static const double phone = 600;
  static const double tablet = 1000;
}

/// Convenience size queries on [BuildContext] so widgets can branch on width
/// without threading [MediaQuery] / [LayoutBuilder] everywhere.
extension BuildContextResponsive on BuildContext {
  double get width => MediaQuery.sizeOf(this).width;

  bool get isPhone => width < Breakpoints.phone;

  bool get isTablet => width >= Breakpoints.phone && width < Breakpoints.tablet;

  /// Phone or small tablet — i.e. anything narrower than the desktop layout.
  bool get isCompact => width < Breakpoints.tablet;
}
