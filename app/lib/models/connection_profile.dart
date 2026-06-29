import 'package:json_annotation/json_annotation.dart';

part 'connection_profile.g.dart';

/// How the user authenticates to the control node.
enum AuthMethod { key, password }

/// A persisted, NON-SECRET connection profile.
///
/// Secrets (private keys, passphrases, passwords) are intentionally NOT stored
/// here — only a reference id. They live in flutter_secure_storage, keyed by
/// [secretRef]. See `services/connection_store.dart`.
@JsonSerializable()
class ConnectionProfile {
  const ConnectionProfile({
    required this.id,
    required this.label,
    required this.host,
    required this.port,
    required this.username,
    required this.authMethod,
    this.keyPath,
  });

  factory ConnectionProfile.fromJson(Map<String, dynamic> json) =>
      _$ConnectionProfileFromJson(json);
  Map<String, dynamic> toJson() => _$ConnectionProfileToJson(this);

  /// Stable identifier; also used to derive secure-storage keys.
  final String id;

  /// Human-friendly name shown in the UI.
  final String label;
  final String host;
  final int port;
  final String username;
  final AuthMethod authMethod;

  /// Path to the on-disk private key file (the key contents are not persisted
  /// here; they are read at connect time). Null for password auth.
  final String? keyPath;

  /// Secure-storage key under which this profile's secret is stored.
  String get secretRef => 'sm_secret_$id';

  ConnectionProfile copyWith({
    String? label,
    String? host,
    int? port,
    String? username,
    AuthMethod? authMethod,
    String? keyPath,
  }) {
    return ConnectionProfile(
      id: id,
      label: label ?? this.label,
      host: host ?? this.host,
      port: port ?? this.port,
      username: username ?? this.username,
      authMethod: authMethod ?? this.authMethod,
      keyPath: keyPath ?? this.keyPath,
    );
  }
}
