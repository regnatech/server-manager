import 'package:animations/animations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../screens/add_wizard_screen.dart';
import '../screens/connect_screen.dart';
import '../screens/dashboard_screen.dart';
import '../screens/site_detail_screen.dart';
import '../state/connection_provider.dart';
import '../theme/app_theme.dart';

/// Wraps a screen in a shared-axis (Z) / fade-through transition from the
/// `animations` package for cohesive page motion.
CustomTransitionPage<void> _fadeThrough(Widget child, GoRouterState state) {
  return CustomTransitionPage<void>(
    key: state.pageKey,
    transitionDuration: AppMotion.base,
    reverseTransitionDuration: AppMotion.base,
    child: child,
    transitionsBuilder: (
      BuildContext context,
      Animation<double> animation,
      Animation<double> secondaryAnimation,
      Widget child,
    ) {
      return FadeThroughTransition(
        animation: animation,
        secondaryAnimation: secondaryAnimation,
        child: child,
      );
    },
  );
}

/// Builds the app router. Redirects to /connect whenever there is no live
/// connection, so deep screens cannot be reached without a session.
/// The route the app opens on. Overridden at startup (e.g. a demo deep-link or
/// the SM_ROUTE env var) so a specific screen can be launched directly.
final bootRouteProvider = StateProvider<String>((ref) => '/connect');

final appRouterProvider = Provider<GoRouter>((ref) {
  return GoRouter(
    initialLocation: ref.read(bootRouteProvider),
    redirect: (BuildContext context, GoRouterState state) {
      final bool connected = ref.read(connectionProvider).isConnected;
      final bool atConnect = state.matchedLocation == '/connect';
      if (!connected && !atConnect) return '/connect';
      if (connected && atConnect) return '/dashboard';
      return null;
    },
    refreshListenable: _RouterRefresh(ref),
    routes: <RouteBase>[
      GoRoute(
        path: '/connect',
        pageBuilder: (BuildContext context, GoRouterState state) =>
            _fadeThrough(const ConnectScreen(), state),
      ),
      GoRoute(
        path: '/dashboard',
        pageBuilder: (BuildContext context, GoRouterState state) =>
            _fadeThrough(const DashboardScreen(), state),
      ),
      GoRoute(
        path: '/site/:domain',
        pageBuilder: (BuildContext context, GoRouterState state) {
          final String domain = state.pathParameters['domain'] ?? '';
          return _fadeThrough(SiteDetailScreen(domain: domain), state);
        },
      ),
      GoRoute(
        path: '/add',
        pageBuilder: (BuildContext context, GoRouterState state) =>
            _fadeThrough(const AddWizardScreen(), state),
      ),
    ],
  );
});

/// Bridges Riverpod connection changes to go_router's redirect re-evaluation.
class _RouterRefresh extends ChangeNotifier {
  _RouterRefresh(Ref ref) {
    ref.listen<ConnState>(
      connectionProvider,
      (ConnState? prev, ConnState next) => notifyListeners(),
    );
  }
}
