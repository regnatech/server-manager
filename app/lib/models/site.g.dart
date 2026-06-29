// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'site.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

Site _$SiteFromJson(Map<String, dynamic> json) => Site(
      domain: json['domain'] as String,
      server: json['server'] as String,
      framework: json['framework'] as String,
      tls: json['tls'] as bool,
      lastDeploy: json['last_deploy'] as String?,
      health: json['health'] as String?,
    );

Map<String, dynamic> _$SiteToJson(Site instance) => <String, dynamic>{
      'domain': instance.domain,
      'server': instance.server,
      'framework': instance.framework,
      'tls': instance.tls,
      'last_deploy': instance.lastDeploy,
      'health': instance.health,
    };
