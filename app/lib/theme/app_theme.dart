import 'package:flutter/material.dart';

/// Centralized color palette for the design system.
///
/// The brand axis runs from a deep indigo/violet primary toward a teal accent,
/// with explicit semantic colors and a small ladder of surface elevations.
class Palette {
  const Palette._();

  // Brand
  static const Color violet = Color(0xFF6C5CE7);
  static const Color violetDeep = Color(0xFF4B3FCB);
  static const Color teal = Color(0xFF1ED9C0);
  static const Color tealDeep = Color(0xFF12A892);

  // Semantic
  static const Color ok = Color(0xFF3FD27E);
  static const Color warn = Color(0xFFF5B14C);
  static const Color err = Color(0xFFF2596B);
  static const Color info = Color(0xFF5AA9FF);

  // Dark surfaces (low → high elevation)
  static const Color darkBg = Color(0xFF0E0F17);
  static const Color darkSurface0 = Color(0xFF14161F);
  static const Color darkSurface1 = Color(0xFF1B1E2A);
  static const Color darkSurface2 = Color(0xFF232737);
  static const Color darkSurface3 = Color(0xFF2D3247);
  static const Color darkBorder = Color(0xFF333A52);
  static const Color darkText = Color(0xFFE7E9F2);
  static const Color darkTextDim = Color(0xFF9AA0BC);

  // Light surfaces
  static const Color lightBg = Color(0xFFF5F6FB);
  static const Color lightSurface0 = Color(0xFFFFFFFF);
  static const Color lightSurface1 = Color(0xFFF0F2F9);
  static const Color lightSurface2 = Color(0xFFE7EAF4);
  static const Color lightSurface3 = Color(0xFFDCE0EF);
  static const Color lightBorder = Color(0xFFD3D8EA);
  static const Color lightText = Color(0xFF161826);
  static const Color lightTextDim = Color(0xFF5C6280);

  /// Returns the semantic color for a CLI log level string.
  static Color forLevel(String level) {
    switch (level) {
      case 'ok':
        return ok;
      case 'warn':
        return warn;
      case 'err':
        return err;
      case 'info':
      default:
        return info;
    }
  }

  /// Returns a health-dot color for a site health string.
  static Color forHealth(String? health) {
    switch (health) {
      case 'ok':
      case 'healthy':
        return ok;
      case 'degraded':
      case 'warn':
        return warn;
      case 'down':
      case 'err':
        return err;
      default:
        return darkTextDim;
    }
  }

  /// The brand accent gradient (teal → deeper teal), used to lift primary
  /// surfaces (buttons, header bars) above a flat fill. Diagonal so the
  /// highlight reads top-left.
  static const LinearGradient accentGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: <Color>[teal, tealDeep],
  );

  /// The brand "brand axis" gradient (violet → teal) for accent bars / strokes.
  static const LinearGradient brandGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: <Color>[violet, teal],
  );

  /// A very low-alpha top-lit sheen layered over a card surface so elevated
  /// panels feel lit from above. [accent] keys the tint (defaults to [violet]).
  static LinearGradient cardSheen({Color accent = violet, double alpha = 0.06}) {
    return LinearGradient(
      begin: Alignment.topCenter,
      end: Alignment.bottomCenter,
      colors: <Color>[
        accent.withValues(alpha: alpha),
        accent.withValues(alpha: 0.0),
      ],
    );
  }
}

/// Centralized motion tokens so every animation in the app stays in sync.
class AppMotion {
  const AppMotion._();

  static const Duration fast = Duration(milliseconds: 150);
  static const Duration base = Duration(milliseconds: 250);
  static const Duration slow = Duration(milliseconds: 400);

  /// Material 3 "emphasized" curve, good for entrances and hero motion.
  static const Curve emphasized = Cubic(0.2, 0.0, 0.0, 1.0);
  static const Curve standard = Curves.easeInOutCubic;
  static const Curve decelerate = Curves.easeOutCubic;
}

/// Small spacing / radius scale used across widgets.
class Insets {
  const Insets._();
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 16;
  static const double lg = 24;
  static const double xl = 32;

  static const double radiusSm = 8;
  static const double radiusMd = 14;
  static const double radiusLg = 20;
}

/// Builds the app's themes. Use [AppTheme.dark] / [AppTheme.light].
class AppTheme {
  const AppTheme._();

  static ThemeData get dark => _build(Brightness.dark);
  static ThemeData get light => _build(Brightness.light);

  static ThemeData _build(Brightness brightness) {
    final bool isDark = brightness == Brightness.dark;

    final ColorScheme scheme = ColorScheme(
      brightness: brightness,
      primary: Palette.violet,
      onPrimary: Colors.white,
      primaryContainer: Palette.violetDeep,
      onPrimaryContainer: Colors.white,
      secondary: Palette.teal,
      onSecondary: const Color(0xFF06231F),
      secondaryContainer: Palette.tealDeep,
      onSecondaryContainer: Colors.white,
      tertiary: Palette.info,
      onTertiary: Colors.white,
      error: Palette.err,
      onError: Colors.white,
      surface: isDark ? Palette.darkSurface0 : Palette.lightSurface0,
      onSurface: isDark ? Palette.darkText : Palette.lightText,
      surfaceContainerHighest:
          isDark ? Palette.darkSurface3 : Palette.lightSurface3,
      onSurfaceVariant: isDark ? Palette.darkTextDim : Palette.lightTextDim,
      outline: isDark ? Palette.darkBorder : Palette.lightBorder,
    );

    // Bundled fonts (no runtime network fetch) so text renders offline and in
    // locked-down environments. AppSans is the UI face; AppMono is for logs.
    final TextTheme baseText =
        (isDark ? ThemeData.dark().textTheme : ThemeData.light().textTheme)
            .apply(fontFamily: 'AppSans');

    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: scheme,
      scaffoldBackgroundColor: isDark ? Palette.darkBg : Palette.lightBg,
      canvasColor: isDark ? Palette.darkBg : Palette.lightBg,
      textTheme: baseText.copyWith(
        titleLarge: baseText.titleLarge?.copyWith(
          fontWeight: FontWeight.w700,
          letterSpacing: -0.4,
        ),
        titleMedium: baseText.titleMedium?.copyWith(fontWeight: FontWeight.w600),
        labelLarge: baseText.labelLarge?.copyWith(fontWeight: FontWeight.w600),
      ),
      dividerColor: isDark ? Palette.darkBorder : Palette.lightBorder,
      appBarTheme: AppBarTheme(
        backgroundColor: isDark ? Palette.darkBg : Palette.lightBg,
        foregroundColor: scheme.onSurface,
        elevation: 0,
        centerTitle: false,
        titleTextStyle: baseText.titleLarge?.copyWith(
          color: scheme.onSurface,
          fontWeight: FontWeight.w700,
        ),
      ),
      cardTheme: CardThemeData(
        color: isDark ? Palette.darkSurface1 : Palette.lightSurface0,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(Insets.radiusLg),
          side: BorderSide(color: scheme.outline.withValues(alpha: 0.6)),
        ),
        margin: EdgeInsets.zero,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: isDark ? Palette.darkSurface2 : Palette.lightSurface1,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: Insets.md,
          vertical: Insets.md,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(Insets.radiusMd),
          borderSide: BorderSide(color: scheme.outline),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(Insets.radiusMd),
          borderSide: BorderSide(color: scheme.outline.withValues(alpha: 0.6)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(Insets.radiusMd),
          borderSide: BorderSide(color: scheme.primary, width: 2),
        ),
        labelStyle: TextStyle(color: scheme.onSurfaceVariant),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          padding: const EdgeInsets.symmetric(
            horizontal: Insets.lg,
            vertical: Insets.md,
          ),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(Insets.radiusMd),
          ),
          textStyle: baseText.labelLarge,
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          padding: const EdgeInsets.symmetric(
            horizontal: Insets.lg,
            vertical: Insets.md,
          ),
          side: BorderSide(color: scheme.outline),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(Insets.radiusMd),
          ),
        ),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: isDark ? Palette.darkSurface2 : Palette.lightSurface2,
        side: BorderSide(color: scheme.outline.withValues(alpha: 0.5)),
        labelStyle: baseText.labelMedium,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(Insets.radiusSm),
        ),
      ),
      tabBarTheme: TabBarThemeData(
        labelColor: scheme.primary,
        unselectedLabelColor: scheme.onSurfaceVariant,
        indicatorColor: scheme.primary,
        dividerColor: Colors.transparent,
        labelStyle: baseText.labelLarge,
      ),
    );
  }

  /// Monospace style for logs and command output.
  static TextStyle mono(BuildContext context, {double size = 13, Color? color}) {
    return TextStyle(
      fontFamily: 'AppMono',
      fontSize: size,
      height: 1.45,
      color: color ?? Theme.of(context).colorScheme.onSurface,
    );
  }
}
