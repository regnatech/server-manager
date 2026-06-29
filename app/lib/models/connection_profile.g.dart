// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'connection_profile.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

ConnectionProfile _$ConnectionProfileFromJson(Map<String, dynamic> json) =>
    ConnectionProfile(
      id: json['id'] as String,
      label: json['label'] as String,
      host: json['host'] as String,
      port: (json['port'] as num).toInt(),
      username: json['username'] as String,
      authMethod: $enumDecode(_$AuthMethodEnumMap, json['authMethod']),
      keyPath: json['keyPath'] as String?,
    );

Map<String, dynamic> _$ConnectionProfileToJson(ConnectionProfile instance) =>
    <String, dynamic>{
      'id': instance.id,
      'label': instance.label,
      'host': instance.host,
      'port': instance.port,
      'username': instance.username,
      'authMethod': _$AuthMethodEnumMap[instance.authMethod]!,
      'keyPath': instance.keyPath,
    };

const _$AuthMethodEnumMap = {
  AuthMethod.key: 'key',
  AuthMethod.password: 'password',
};
