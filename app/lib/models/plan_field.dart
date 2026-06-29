import 'package:json_annotation/json_annotation.dart';

part 'plan_field.g.dart';

/// Field kinds the `add --plan` contract can request.
enum PlanFieldType {
  domain,
  abspath,
  string,
  bool,
  @JsonValue('enum')
  enumeration,
  secret;

  /// Parses the backend's `type` string, defaulting to [string].
  static PlanFieldType fromWire(String? wire) {
    switch (wire) {
      case 'domain':
        return PlanFieldType.domain;
      case 'abspath':
        return PlanFieldType.abspath;
      case 'bool':
        return PlanFieldType.bool;
      case 'enum':
        return PlanFieldType.enumeration;
      case 'secret':
        return PlanFieldType.secret;
      case 'string':
      default:
        return PlanFieldType.string;
    }
  }
}

/// A conditional gate: this field is only shown when another field's value
/// matches. Shape: `{"field":"x","equals":"y"}`.
@JsonSerializable()
class PlanFieldCondition {
  const PlanFieldCondition({required this.field, required this.equals});

  factory PlanFieldCondition.fromJson(Map<String, dynamic> json) =>
      _$PlanFieldConditionFromJson(json);
  Map<String, dynamic> toJson() => _$PlanFieldConditionToJson(this);

  final String field;

  /// Expected value, compared as a string against the dependency's value.
  final String equals;
}

/// One field in an `add` plan returned by `server --json add --plan`.
///
/// Shape: `{"id","type","label","value","required":bool,"options":[...]?,"when":{...}?}`.
@JsonSerializable()
class PlanField {
  const PlanField({
    required this.id,
    required this.type,
    required this.label,
    this.value,
    this.required = false,
    this.options,
    this.when,
  });

  factory PlanField.fromJson(Map<String, dynamic> json) {
    return PlanField(
      id: json['id']?.toString() ?? '',
      type: PlanFieldType.fromWire(json['type']?.toString()),
      label: json['label']?.toString() ?? '',
      value: json['value']?.toString(),
      required: json['required'] == true,
      options: (json['options'] as List<dynamic>?)
          ?.map((dynamic e) => e.toString())
          .toList(),
      when: json['when'] is Map
          ? PlanFieldCondition.fromJson(
              (json['when'] as Map).cast<String, dynamic>(),
            )
          : null,
    );
  }

  final String id;
  final PlanFieldType type;
  final String label;

  /// Default/initial value supplied by the backend, if any.
  final String? value;
  final bool required;

  /// Allowed values when [type] is [PlanFieldType.enumeration].
  final List<String>? options;

  /// Visibility condition; when non-null the field is shown only if satisfied.
  final PlanFieldCondition? when;

  /// Evaluates [when] against the current answer map. Always visible if null.
  bool isVisible(Map<String, String> answers) {
    final PlanFieldCondition? cond = when;
    if (cond == null) return true;
    return answers[cond.field] == cond.equals;
  }
}

/// The full plan: a command name plus an ordered list of fields.
///
/// Shape: `{"command":"add","fields":[...]}`.
class AddPlan {
  const AddPlan({required this.command, required this.fields});

  factory AddPlan.fromValue(Map<String, dynamic> value) {
    return AddPlan(
      command: value['command']?.toString() ?? 'add',
      fields: (value['fields'] as List<dynamic>? ?? const <dynamic>[])
          .map((dynamic e) => PlanField.fromJson((e as Map).cast()))
          .toList(),
    );
  }

  final String command;
  final List<PlanField> fields;
}
