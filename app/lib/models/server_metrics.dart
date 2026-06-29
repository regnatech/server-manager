/// Live host metrics returned by `server --json metrics`.
///
/// Mirrors the `value` payload of the metrics [DataEvent]:
/// ```
/// {"server","host","uptime_seconds","load":[1,5,15],"cpu_count","cpu_pct",
///  "mem":{"used","total","pct"},"disk":{"used","total","pct"},
///  "services":[{"name","active"}]}
/// ```
/// All fields are parsed defensively so a partial backend payload still renders.
class ServerMetrics {
  const ServerMetrics({
    required this.server,
    required this.host,
    required this.uptimeSeconds,
    required this.load,
    required this.cpuCount,
    required this.cpuPct,
    required this.mem,
    required this.disk,
    required this.services,
  });

  final String server;
  final String host;
  final int uptimeSeconds;

  /// Load average over 1, 5 and 15 minutes (may be shorter if absent).
  final List<double> load;
  final int cpuCount;
  final num cpuPct;
  final ResourceUsage mem;
  final ResourceUsage disk;
  final List<ServiceStatus> services;

  /// Parses the metrics `value` map, tolerating missing or mistyped fields.
  factory ServerMetrics.fromJson(Map<String, dynamic> json) {
    return ServerMetrics(
      server: json['server']?.toString() ?? '',
      host: json['host']?.toString() ?? '',
      uptimeSeconds: _toInt(json['uptime_seconds']),
      load: <double>[
        for (final dynamic v in (json['load'] as List<dynamic>?) ?? const [])
          _toDouble(v),
      ],
      cpuCount: _toInt(json['cpu_count']),
      cpuPct: _toNum(json['cpu_pct']),
      mem: ResourceUsage.fromJson(
        json['mem'] is Map ? (json['mem'] as Map).cast<String, dynamic>() : null,
      ),
      disk: ResourceUsage.fromJson(
        json['disk'] is Map
            ? (json['disk'] as Map).cast<String, dynamic>()
            : null,
      ),
      services: <ServiceStatus>[
        for (final dynamic s
            in (json['services'] as List<dynamic>?) ?? const [])
          if (s is Map) ServiceStatus.fromJson(s.cast<String, dynamic>()),
      ],
    );
  }

  /// A compact human uptime such as `14d 6h`, `6h 12m`, or `5m`.
  String get uptimeHuman {
    final int s = uptimeSeconds;
    if (s <= 0) return '—';
    final int days = s ~/ 86400;
    final int hours = (s % 86400) ~/ 3600;
    final int minutes = (s % 3600) ~/ 60;
    if (days > 0) return '${days}d ${hours}h';
    if (hours > 0) return '${hours}h ${minutes}m';
    if (minutes > 0) return '${minutes}m';
    return '${s}s';
  }
}

/// Used/total/percentage triple for a resource (memory or disk).
class ResourceUsage {
  const ResourceUsage({
    required this.used,
    required this.total,
    required this.pct,
  });

  /// Bytes in use.
  final int used;

  /// Total bytes.
  final int total;

  /// Percentage used (0–100); falls back to a derived value if absent.
  final num pct;

  factory ResourceUsage.fromJson(Map<String, dynamic>? json) {
    final Map<String, dynamic> j = json ?? const <String, dynamic>{};
    final int used = _toInt(j['used']);
    final int total = _toInt(j['total']);
    final num pct = j.containsKey('pct')
        ? _toNum(j['pct'])
        : (total > 0 ? (used / total * 100).round() : 0);
    return ResourceUsage(used: used, total: total, pct: pct);
  }

  /// e.g. `2.1 / 8.0 GB` — both sides rendered in the larger unit.
  String get humanUsedOfTotal =>
      '${_bytesValue(used, total)} / ${humanBytes(total)}';
}

/// One systemd-style service and whether it is active.
class ServiceStatus {
  const ServiceStatus({required this.name, required this.active});

  final String name;
  final bool active;

  factory ServiceStatus.fromJson(Map<String, dynamic> json) {
    return ServiceStatus(
      name: json['name']?.toString() ?? '',
      active: json['active'] == true,
    );
  }
}

const List<String> _byteUnits = <String>['B', 'KB', 'MB', 'GB', 'TB', 'PB'];

/// Formats [bytes] into a 1-decimal human string, e.g. `8.0 GB`.
String humanBytes(int bytes) {
  if (bytes <= 0) return '0 B';
  double value = bytes.toDouble();
  int unit = 0;
  while (value >= 1024 && unit < _byteUnits.length - 1) {
    value /= 1024;
    unit++;
  }
  final String text = unit == 0 ? value.toStringAsFixed(0) : value.toStringAsFixed(1);
  return '$text ${_byteUnits[unit]}';
}

/// Renders [bytes] using the unit appropriate for [scale] (so "used" and
/// "total" share a unit, e.g. `2.1` next to `8.0 GB`).
String _bytesValue(int bytes, int scale) {
  if (scale <= 0) return '0';
  int unit = 0;
  double s = scale.toDouble();
  while (s >= 1024 && unit < _byteUnits.length - 1) {
    s /= 1024;
    unit++;
  }
  final double value = bytes / (1 << (unit * 10));
  return unit == 0 ? value.toStringAsFixed(0) : value.toStringAsFixed(1);
}

int _toInt(Object? v) {
  if (v is int) return v;
  if (v is num) return v.round();
  if (v is String) return int.tryParse(v) ?? double.tryParse(v)?.round() ?? 0;
  return 0;
}

num _toNum(Object? v) {
  if (v is num) return v;
  if (v is String) return num.tryParse(v) ?? 0;
  return 0;
}

double _toDouble(Object? v) {
  if (v is num) return v.toDouble();
  if (v is String) return double.tryParse(v) ?? 0;
  return 0;
}
