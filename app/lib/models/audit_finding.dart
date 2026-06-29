/// A single security finding returned by `server --json audit <site>`.
///
/// Mirrors one item from the audit [DataEvent]:
/// `{"id","severity","title","detail","recommendation","fixable","fix_label"}`.
/// When [fixable] is true the UI offers a "Fix" button that runs
/// `server --json audit fix <id> <site>`.
class AuditFinding {
  const AuditFinding({
    required this.id,
    required this.severity,
    required this.title,
    required this.detail,
    required this.recommendation,
    required this.fixable,
    required this.fixLabel,
  });

  final String id;

  /// One of: critical, high, medium, low, info.
  final String severity;
  final String title;
  final String detail;
  final String recommendation;
  final bool fixable;
  final String fixLabel;

  /// Parses one backend item, mapping `fix_label`→[fixLabel] and defaulting
  /// [fixable] to false when absent.
  factory AuditFinding.fromJson(Map<String, dynamic> json) {
    return AuditFinding(
      id: json['id']?.toString() ?? '',
      severity: json['severity']?.toString() ?? 'info',
      title: json['title']?.toString() ?? '',
      detail: json['detail']?.toString() ?? '',
      recommendation: json['recommendation']?.toString() ?? '',
      fixable: json['fixable'] == true,
      fixLabel: json['fix_label']?.toString() ?? '',
    );
  }

  /// Sort key: critical=0, high=1, medium=2, low=3, info=4 (unknown→5).
  int get severityRank {
    switch (severity) {
      case 'critical':
        return 0;
      case 'high':
        return 1;
      case 'medium':
        return 2;
      case 'low':
        return 3;
      case 'info':
        return 4;
      default:
        return 5;
    }
  }
}
