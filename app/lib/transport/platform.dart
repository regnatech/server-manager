/// Web-safe platform detection.
///
/// Uses conditional imports so `dart:io` is never referenced on the web build.
/// On the web, [isDesktop] is always false.
library;

import 'platform_stub.dart'
    if (dart.library.io) 'platform_io.dart' as impl;

/// True on Windows / macOS / Linux desktop; false on web and mobile.
bool get isDesktop => impl.isDesktopImpl();

/// Reads a process environment variable on native platforms; null on web.
String? envVar(String name) => impl.envVarImpl(name);
