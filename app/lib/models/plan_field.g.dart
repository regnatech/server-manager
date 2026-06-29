// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'plan_field.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

PlanFieldCondition _$PlanFieldConditionFromJson(Map<String, dynamic> json) =>
    PlanFieldCondition(
      field: json['field'] as String,
      equals: json['equals'] as String,
    );

Map<String, dynamic> _$PlanFieldConditionToJson(PlanFieldCondition instance) =>
    <String, dynamic>{
      'field': instance.field,
      'equals': instance.equals,
    };

PlanField _$PlanFieldFromJson(Map<String, dynamic> json) => PlanField(
      id: json['id'] as String,
      type: $enumDecode(_$PlanFieldTypeEnumMap, json['type']),
      label: json['label'] as String,
      value: json['value'] as String?,
      required: json['required'] as bool? ?? false,
      options:
          (json['options'] as List<dynamic>?)?.map((e) => e as String).toList(),
      when: json['when'] == null
          ? null
          : PlanFieldCondition.fromJson(json['when'] as Map<String, dynamic>),
    );

Map<String, dynamic> _$PlanFieldToJson(PlanField instance) => <String, dynamic>{
      'id': instance.id,
      'type': _$PlanFieldTypeEnumMap[instance.type]!,
      'label': instance.label,
      'value': instance.value,
      'required': instance.required,
      'options': instance.options,
      'when': instance.when,
    };

const _$PlanFieldTypeEnumMap = {
  PlanFieldType.domain: 'domain',
  PlanFieldType.abspath: 'abspath',
  PlanFieldType.string: 'string',
  PlanFieldType.bool: 'bool',
  PlanFieldType.enumeration: 'enum',
  PlanFieldType.secret: 'secret',
};
