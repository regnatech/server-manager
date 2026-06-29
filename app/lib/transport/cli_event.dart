import 'dart:convert';

/// Sealed hierarchy of events emitted by `server --json <cmd>`.
///
/// The backend emits ONE JSON object per line (NDJSON). Each object carries a
/// discriminator field `t`. [CliEvent.fromJson] dispatches on that field.
sealed class CliEvent {
  const CliEvent();

  /// Parses a single decoded JSON object into the matching event subtype.
  ///
  /// Unknown discriminators map to [UnknownEvent] rather than throwing, so the
  /// UI never crashes on a forward-compatible backend.
  factory CliEvent.fromJson(Map<String, dynamic> json) {
    final String t = (json['t'] as String?) ?? 'unknown';
    switch (t) {
      case 'version':
        return VersionEvent(
          contract: json['contract']?.toString() ?? '',
          version: json['version']?.toString() ?? '',
        );
      case 'banner':
        return BannerEvent(label: json['label']?.toString() ?? '');
      case 'section':
        return SectionEvent(label: json['label']?.toString() ?? '');
      case 'step_start':
        return StepStart(
          id: json['id']?.toString() ?? '',
          label: json['label']?.toString() ?? '',
        );
      case 'step_end':
        return StepEnd(
          id: json['id']?.toString() ?? '',
          ok: json['ok'] == true,
          dur: _toDouble(json['dur']),
          err: json['err']?.toString(),
        );
      case 'log':
        return LogEvent(
          level: json['level']?.toString() ?? 'info',
          msg: json['msg']?.toString() ?? '',
        );
      case 'progress':
        return ProgressEvent(
          cur: _toDouble(json['cur']),
          total: _toDouble(json['total']),
          label: json['label']?.toString() ?? '',
        );
      case 'need':
        return NeedEvent(id: json['id']?.toString() ?? '');
      case 'report':
        return ReportEvent(
          title: json['title']?.toString() ?? '',
          fields: <String, String>{
            for (final MapEntry<String, dynamic> e
                in (json['fields'] as Map<String, dynamic>? ?? const {})
                    .entries)
              e.key: e.value?.toString() ?? '',
          },
        );
      case 'data':
        return DataEvent(
          kind: json['kind']?.toString() ?? '',
          items: (json['items'] as List<dynamic>?)
              ?.cast<dynamic>()
              .map((dynamic e) => e is Map ? e.cast<String, dynamic>() : e)
              .toList(),
          value: json['value'] is Map
              ? (json['value'] as Map).cast<String, dynamic>()
              : null,
        );
      case 'done':
        return DoneEvent(ok: json['ok'] == true);
      default:
        return UnknownEvent(raw: json);
    }
  }

  static double _toDouble(Object? v) {
    if (v is num) return v.toDouble();
    if (v is String) return double.tryParse(v) ?? 0;
    return 0;
  }
}

/// `{"t":"version","contract":"1","version":"0.1.0"}`
class VersionEvent extends CliEvent {
  const VersionEvent({required this.contract, required this.version});
  final String contract;
  final String version;
}

/// `{"t":"banner","label":string}`
class BannerEvent extends CliEvent {
  const BannerEvent({required this.label});
  final String label;
}

/// `{"t":"section","label":string}`
class SectionEvent extends CliEvent {
  const SectionEvent({required this.label});
  final String label;
}

/// `{"t":"step_start","id":string,"label":string}`
class StepStart extends CliEvent {
  const StepStart({required this.id, required this.label});
  final String id;
  final String label;
}

/// `{"t":"step_end","id":string,"ok":bool,"dur":number,"err":string?}`
class StepEnd extends CliEvent {
  const StepEnd({
    required this.id,
    required this.ok,
    required this.dur,
    this.err,
  });
  final String id;
  final bool ok;
  final double dur;
  final String? err;
}

/// `{"t":"log","level":"info|ok|warn|err","msg":string}`
class LogEvent extends CliEvent {
  const LogEvent({required this.level, required this.msg});
  final String level;
  final String msg;
}

/// `{"t":"progress","cur":number,"total":number,"label":string}`
class ProgressEvent extends CliEvent {
  const ProgressEvent({
    required this.cur,
    required this.total,
    required this.label,
  });
  final double cur;
  final double total;
  final String label;

  double get fraction => total <= 0 ? 0 : (cur / total).clamp(0, 1).toDouble();
}

/// `{"t":"need","id":string}` — backend needs more answers; re-run with them.
class NeedEvent extends CliEvent {
  const NeedEvent({required this.id});
  final String id;
}

/// `{"t":"report","title":string,"fields":{string:string}}`
class ReportEvent extends CliEvent {
  const ReportEvent({required this.title, required this.fields});
  final String title;
  final Map<String, String> fields;
}

/// `{"t":"data","kind":string,"items":[...]}` or `{...,"value":{...}}`
class DataEvent extends CliEvent {
  const DataEvent({required this.kind, this.items, this.value});
  final String kind;
  final List<dynamic>? items;
  final Map<String, dynamic>? value;
}

/// `{"t":"done","ok":bool}` — terminal event for a streamed operation.
class DoneEvent extends CliEvent {
  const DoneEvent({required this.ok});
  final bool ok;
}

/// Fallback for unrecognized discriminators or non-JSON lines.
class UnknownEvent extends CliEvent {
  const UnknownEvent({required this.raw});
  final Map<String, dynamic> raw;

  @override
  String toString() => jsonEncode(raw);
}
