import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../theme/breakpoints.dart';

/// A single top-level destination reachable from the phone bottom navigation.
class _Destination {
  const _Destination({
    required this.label,
    required this.path,
    required this.icon,
    required this.selectedIcon,
  });

  final String label;
  final String path;
  final IconData icon;
  final IconData selectedIcon;
}

/// The five top-level destinations, in display order. The bottom nav and the
/// selected-index derivation both read from this list so they never drift.
const List<_Destination> _destinations = <_Destination>[
  _Destination(
    label: 'Sites',
    path: '/dashboard',
    icon: Icons.dashboard_outlined,
    selectedIcon: Icons.dashboard,
  ),
  _Destination(
    label: 'Health',
    path: '/health',
    icon: Icons.monitor_heart_outlined,
    selectedIcon: Icons.monitor_heart,
  ),
  _Destination(
    label: 'Audit',
    path: '/audit',
    icon: Icons.shield_outlined,
    selectedIcon: Icons.shield,
  ),
  _Destination(
    label: 'Terminal',
    path: '/terminal',
    icon: Icons.terminal_outlined,
    selectedIcon: Icons.terminal,
  ),
  _Destination(
    label: 'Settings',
    path: '/settings',
    icon: Icons.settings_outlined,
    selectedIcon: Icons.settings,
  ),
];

/// Persistent scaffold shared by the five top-level destinations.
///
/// On phones it pins a Material 3 [NavigationBar] to the bottom so the main
/// destinations are reachable without the dashboard's app-bar icons / overflow
/// menu. On wider layouts it renders just the [child] so the desktop UI — with
/// its app-bar destination icons — stays exactly as it was.
class AppShell extends ConsumerWidget {
  const AppShell({
    required this.location,
    required this.child,
    super.key,
  });

  /// The current router location (`GoRouterState.uri.path`), used to derive the
  /// selected destination.
  final String location;

  /// The shell's active route subtree (one of the five destination screens,
  /// each of which supplies its own [Scaffold]/[AppBar]).
  final Widget child;

  /// Index of the destination whose [path] the current [location] sits under.
  /// Falls back to 0 (Sites) when nothing matches.
  int get _selectedIndex {
    final int i = _destinations.indexWhere(
      (_Destination d) => location == d.path || location.startsWith('${d.path}/'),
    );
    return i < 0 ? 0 : i;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Desktop / tablet: no bottom bar — leave the existing chrome untouched.
    if (!context.isPhone) return child;

    final ColorScheme scheme = Theme.of(context).colorScheme;

    return Scaffold(
      extendBody: false,
      body: child,
      bottomNavigationBar: NavigationBarTheme(
        data: NavigationBarThemeData(
          backgroundColor: scheme.surface,
          indicatorColor: scheme.secondary.withValues(alpha: 0.22),
          surfaceTintColor: Colors.transparent,
          elevation: 0,
          labelTextStyle: WidgetStateProperty.resolveWith<TextStyle?>(
            (Set<WidgetState> states) {
              final bool selected = states.contains(WidgetState.selected);
              return Theme.of(context).textTheme.labelMedium?.copyWith(
                    color: selected
                        ? scheme.onSurface
                        : scheme.onSurfaceVariant,
                    fontWeight:
                        selected ? FontWeight.w600 : FontWeight.w500,
                  );
            },
          ),
          iconTheme: WidgetStateProperty.resolveWith<IconThemeData?>(
            (Set<WidgetState> states) {
              final bool selected = states.contains(WidgetState.selected);
              return IconThemeData(
                color: selected ? scheme.secondary : scheme.onSurfaceVariant,
              );
            },
          ),
        ),
        child: DecoratedBox(
          decoration: BoxDecoration(
            border: Border(
              top: BorderSide(color: scheme.outline.withValues(alpha: 0.6)),
            ),
          ),
          child: NavigationBar(
            selectedIndex: _selectedIndex,
            onDestinationSelected: (int i) {
              final String target = _destinations[i].path;
              if (target != location) context.go(target);
            },
            destinations: <Widget>[
              for (final _Destination d in _destinations)
                NavigationDestination(
                  icon: Icon(d.icon),
                  selectedIcon: Icon(d.selectedIcon),
                  label: d.label,
                ),
            ],
          ),
        ),
      ),
    );
  }
}
