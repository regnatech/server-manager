import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:window_manager/window_manager.dart';

import 'router/app_router.dart';
import 'state/connection_provider.dart';
import 'theme/app_theme.dart';
import 'transport/platform.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Desktop window setup. Skipped on web (kIsWeb) and non-desktop platforms.
  if (!kIsWeb && isDesktop) {
    await windowManager.ensureInitialized();
    const WindowOptions windowOptions = WindowOptions(
      size: Size(1200, 800),
      minimumSize: Size(960, 640),
      center: true,
      backgroundColor: Colors.transparent,
      titleBarStyle: TitleBarStyle.normal,
      title: 'Server Manager',
    );
    await windowManager.waitUntilReadyToShow(windowOptions, () async {
      await windowManager.show();
      await windowManager.focus();
    });
  }

  // Demo mode + initial route can be requested at startup (no SSH server
  // needed), so any screen can be launched directly. On web via ?demo=1 /
  // #/route; on native (Windows/Linux/macOS) via the SM_DEMO / SM_ROUTE env
  // vars. Applied before runApp so the router's first redirect already sees a
  // connected session and the deep link is preserved.
  final bool startInDemo = kIsWeb
      ? (Uri.base.queryParameters['demo'] == '1' ||
          Uri.base.fragment.contains('demo=1'))
      : envVar('SM_DEMO') == '1';
  final String? bootRoute = kIsWeb ? null : envVar('SM_ROUTE');

  final ProviderContainer container = ProviderContainer();
  if (bootRoute != null && bootRoute.isNotEmpty) {
    container.read(bootRouteProvider.notifier).state = bootRoute;
  }
  if (startInDemo) {
    container.read(connectionProvider.notifier).enterDemo();
  }

  runApp(
    UncontrolledProviderScope(
      container: container,
      child: const ServerManagerApp(),
    ),
  );
}

class ServerManagerApp extends ConsumerWidget {
  const ServerManagerApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final router = ref.watch(appRouterProvider);
    return MaterialApp.router(
      title: 'Server Manager',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light,
      darkTheme: AppTheme.dark,
      themeMode: ThemeMode.dark,
      routerConfig: router,
    );
  }
}
