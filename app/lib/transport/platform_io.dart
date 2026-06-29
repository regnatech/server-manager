import 'dart:io';

/// Native implementation backed by `dart:io`'s [Platform].
bool isDesktopImpl() =>
    Platform.isWindows || Platform.isMacOS || Platform.isLinux;

/// Reads an environment variable (native only).
String? envVarImpl(String name) => Platform.environment[name];
