import 'package:json_annotation/json_annotation.dart';

part 'server.g.dart';

/// A managed control/target server as reported by `server --json servers`.
///
/// Shape: `{"name","host","user","become"}`.
@JsonSerializable()
class Server {
  const Server({
    required this.name,
    required this.host,
    required this.user,
    this.become = false,
  });

  factory Server.fromJson(Map<String, dynamic> json) => _$ServerFromJson(json);
  Map<String, dynamic> toJson() => _$ServerToJson(this);

  final String name;
  final String host;
  final String user;

  /// Whether privilege escalation (sudo) is used for operations on this server.
  final bool become;
}
