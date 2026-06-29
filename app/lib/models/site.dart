import 'package:json_annotation/json_annotation.dart';

part 'site.g.dart';

/// A deployed site as reported by `server --json list`.
///
/// Shape: `{"domain","server","framework","tls":bool,"last_deploy","health"}`.
@JsonSerializable()
class Site {
  const Site({
    required this.domain,
    required this.server,
    required this.framework,
    required this.tls,
    this.lastDeploy,
    this.health,
  });

  factory Site.fromJson(Map<String, dynamic> json) => _$SiteFromJson(json);
  Map<String, dynamic> toJson() => _$SiteToJson(this);

  final String domain;
  final String server;
  final String framework;
  final bool tls;

  @JsonKey(name: 'last_deploy')
  final String? lastDeploy;

  /// Free-form health string, e.g. `ok`, `degraded`, `down`.
  final String? health;
}
