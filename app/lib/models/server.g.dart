// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'server.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

Server _$ServerFromJson(Map<String, dynamic> json) => Server(
      name: json['name'] as String,
      host: json['host'] as String,
      user: json['user'] as String,
      become: json['become'] as bool? ?? false,
    );

Map<String, dynamic> _$ServerToJson(Server instance) => <String, dynamic>{
      'name': instance.name,
      'host': instance.host,
      'user': instance.user,
      'become': instance.become,
    };
