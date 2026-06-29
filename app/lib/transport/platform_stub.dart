/// Web fallback: no `dart:io`, so never a desktop platform.
bool isDesktopImpl() => false;

/// Web has no process environment.
String? envVarImpl(String name) => null;
