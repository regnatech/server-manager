import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../models/connection_profile.dart';

/// Persists connection profiles and their secrets.
///
/// Design: the non-secret [ConnectionProfile] list is stored as a single JSON
/// blob; the matching secret (password OR key passphrase) is stored under a
/// per-profile key. Both live in [FlutterSecureStorage], which is backed by the
/// OS credential vault (Credential Manager on Windows, Keychain on macOS,
/// libsecret on Linux). Private key *contents* are never persisted — only the
/// on-disk path in the profile and, optionally, its passphrase as a secret.
class ConnectionStore {
  ConnectionStore([FlutterSecureStorage? storage])
      : _storage = storage ??
            const FlutterSecureStorage(
              aOptions: AndroidOptions(encryptedSharedPreferences: true),
            );

  final FlutterSecureStorage _storage;

  static const String _profilesKey = 'sm_profiles_v1';

  /// Loads all saved profiles, newest-first by insertion order.
  Future<List<ConnectionProfile>> loadProfiles() async {
    final String? raw = await _storage.read(key: _profilesKey);
    if (raw == null || raw.isEmpty) return const <ConnectionProfile>[];
    final List<dynamic> list = jsonDecode(raw) as List<dynamic>;
    return list
        .map((dynamic e) =>
            ConnectionProfile.fromJson((e as Map).cast<String, dynamic>()))
        .toList();
  }

  /// Inserts or updates [profile] (matched by id) and persists the list.
  Future<void> saveProfile(ConnectionProfile profile) async {
    final List<ConnectionProfile> profiles = await loadProfiles();
    final int idx = profiles.indexWhere((ConnectionProfile p) => p.id == profile.id);
    if (idx >= 0) {
      profiles[idx] = profile;
    } else {
      profiles.add(profile);
    }
    await _writeProfiles(profiles);
  }

  /// Removes a profile and its associated secret.
  Future<void> deleteProfile(String id) async {
    final List<ConnectionProfile> profiles = await loadProfiles();
    profiles.removeWhere((ConnectionProfile p) => p.id == id);
    await _writeProfiles(profiles);
    await _storage.delete(key: 'sm_secret_$id');
  }

  Future<void> _writeProfiles(List<ConnectionProfile> profiles) async {
    final String raw = jsonEncode(
      profiles.map((ConnectionProfile p) => p.toJson()).toList(),
    );
    await _storage.write(key: _profilesKey, value: raw);
  }

  // --- Secrets -------------------------------------------------------------

  /// Stores the secret (password or key passphrase) for [profile].
  Future<void> saveSecret(ConnectionProfile profile, String secret) {
    return _storage.write(key: profile.secretRef, value: secret);
  }

  /// Reads the secret for [profile], or null if none is stored.
  Future<String?> readSecret(ConnectionProfile profile) {
    return _storage.read(key: profile.secretRef);
  }

  /// Deletes only the secret, keeping the profile.
  Future<void> deleteSecret(ConnectionProfile profile) {
    return _storage.delete(key: profile.secretRef);
  }
}
