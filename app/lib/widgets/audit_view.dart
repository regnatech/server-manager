import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/audit_finding.dart';
import '../theme/app_theme.dart';
import '../transport/cli_event.dart';
import 'app_button.dart';
import 'glass_card.dart';
import 'section_header.dart';

/// Per-finding fix lifecycle on the audit view.
enum _FixState { idle, running, fixed, failed }

/// A reusable security-audit presentation: runs an audit stream, shows live
/// check progress, then lists findings (sorted by severity) as [GlassCard]s
/// with a posture header, per-severity count chips, a "Re-run audit" button,
/// and a per-finding "Fix" button that streams remediation progress and
/// re-runs the audit on success so the finding disappears.
///
/// The data path is injected so the same widget serves both the per-site audit
/// (`cli.audit(domain)` / `cli.auditFix(id, domain)`) and the server-level
/// audit (`cli.audit()` / `cli.auditFix(id)`).
class AuditView extends ConsumerStatefulWidget {
  const AuditView({
    super.key,
    required this.runAudit,
    required this.runFix,
    this.runFixAll,
    this.runHistory,
    this.autoRun = false,
  });

  /// Starts a fresh audit run.
  final Stream<CliEvent> Function() runAudit;

  /// Starts a remediation for the finding [id].
  final Stream<CliEvent> Function(String id) runFix;

  /// Starts a remediation for every auto-fixable finding at once. When null
  /// the "Fix all" button is hidden.
  final Stream<CliEvent> Function()? runFixAll;

  /// Fetches the posture history (`audit history`). When null the "History"
  /// affordance is hidden.
  final Stream<CliEvent> Function()? runHistory;

  /// When true, the audit runs once automatically on first build (used by demo
  /// deep-links and the server audit screen).
  final bool autoRun;

  @override
  ConsumerState<AuditView> createState() => _AuditViewState();
}

class _AuditViewState extends ConsumerState<AuditView> {
  bool _running = false;
  bool _hasRun = false;
  String _statusLabel = '';
  List<AuditFinding>? _findings;

  /// Per-finding-id fix state and last step status line.
  final Map<String, _FixState> _fixState = <String, _FixState>{};
  final Map<String, String> _fixStatus = <String, String>{};

  /// "Fix all" lifecycle: true while the batch remediation stream runs.
  bool _fixingAll = false;
  String _fixAllStatus = '';

  @override
  void initState() {
    super.initState();
    if (widget.autoRun) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _runAudit());
    }
  }

  Future<void> _runAudit() async {
    if (_running) return;
    setState(() {
      _running = true;
      _hasRun = true;
      _statusLabel = 'Starting audit…';
    });
    List<AuditFinding>? result;
    try {
      await for (final CliEvent e in widget.runAudit()) {
        if (!mounted) return;
        switch (e) {
          case SectionEvent(label: final String l):
            setState(() => _statusLabel = l);
          case StepStart(label: final String l):
            setState(() => _statusLabel = l);
          case DataEvent(kind: 'audit', items: final List<dynamic>? items):
            result = <AuditFinding>[
              for (final dynamic item in items ?? const <dynamic>[])
                if (item is Map<String, dynamic>) AuditFinding.fromJson(item),
            ]..sort((AuditFinding a, AuditFinding b) =>
                a.severityRank.compareTo(b.severityRank));
          case DoneEvent():
            break;
          default:
            break;
        }
      }
    } finally {
      if (mounted) {
        setState(() {
          _running = false;
          _findings = result ?? _findings ?? const <AuditFinding>[];
          _fixState.clear();
          _fixStatus.clear();
        });
      }
    }
  }

  Future<void> _runFix(AuditFinding finding) async {
    final String id = finding.id;
    if (_fixState[id] == _FixState.running) return;
    setState(() {
      _fixState[id] = _FixState.running;
      _fixStatus[id] = 'Applying…';
    });
    bool ok = false;
    try {
      await for (final CliEvent e in widget.runFix(id)) {
        if (!mounted) return;
        switch (e) {
          case StepStart(label: final String l):
            setState(() => _fixStatus[id] = l);
          case DoneEvent(ok: final bool done):
            ok = done;
          default:
            break;
        }
      }
    } catch (_) {
      ok = false;
    }
    if (!mounted) return;
    setState(() {
      _fixState[id] = ok ? _FixState.fixed : _FixState.failed;
      _fixStatus[id] = ok ? 'Fixed' : 'Fix failed';
    });
    // On success, re-run the audit shortly so the finding disappears.
    if (ok) {
      await Future<void>.delayed(const Duration(milliseconds: 900));
      if (mounted) await _runAudit();
    }
  }

  Future<void> _runFixAll() async {
    final Stream<CliEvent> Function()? run = widget.runFixAll;
    if (run == null || _fixingAll || _running) return;
    final int fixableCount = (_findings ?? const <AuditFinding>[])
        .where((AuditFinding f) => f.fixable)
        .length;
    setState(() {
      _fixingAll = true;
      _fixAllStatus = 'Applying $fixableCount '
          '${fixableCount == 1 ? 'fix' : 'fixes'}…';
    });
    bool ok = false;
    int applied = 0;
    try {
      await for (final CliEvent e in run()) {
        if (!mounted) return;
        switch (e) {
          case SectionEvent(label: final String l):
            setState(() => _fixAllStatus = l);
          case StepStart(label: final String l):
            setState(() => _fixAllStatus = l);
          case DataEvent(
              kind: 'audit_fixall',
              value: final Map<String, dynamic>? value,
            ):
            applied = (value?['applied'] as num?)?.toInt() ?? 0;
          case DoneEvent(ok: final bool done):
            ok = done;
          default:
            break;
        }
      }
    } catch (_) {
      ok = false;
    }
    if (!mounted) return;
    setState(() {
      _fixingAll = false;
      _fixAllStatus = '';
    });
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    if (ok) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            'Applied $applied ${applied == 1 ? 'fix' : 'fixes'}',
          ),
        ),
      );
      // Re-run the audit so the list visibly shrinks.
      await _runAudit();
    } else {
      messenger.showSnackBar(
        const SnackBar(content: Text('Could not apply all fixes')),
      );
    }
  }

  /// Loads the posture history stream and shows it in a dialog.
  Future<void> _showHistory() async {
    final Stream<CliEvent> Function()? run = widget.runHistory;
    if (run == null) return;
    final List<Map<String, dynamic>> snapshots = <Map<String, dynamic>>[];
    await for (final CliEvent e in run()) {
      switch (e) {
        case DataEvent(kind: 'audit_history', items: final List<dynamic>? items):
          for (final dynamic item in items ?? const <dynamic>[]) {
            if (item is Map<String, dynamic>) snapshots.add(item);
          }
        case DoneEvent():
          break;
        default:
          break;
      }
    }
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (BuildContext _) => _AuditHistoryDialog(snapshots: snapshots),
    );
  }

  @override
  Widget build(BuildContext context) {
    final List<AuditFinding>? findings = _findings;
    final bool showProgress =
        (_running || !_hasRun) && (findings == null || findings.isEmpty);

    return Padding(
      padding: const EdgeInsets.all(Insets.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          _AuditHeader(
            findings: findings,
            running: _running,
            onRerun: _running ? null : _runAudit,
            onFixAll: widget.runFixAll != null ? _runFixAll : null,
            onHistory: widget.runHistory != null ? _showHistory : null,
            fixingAll: _fixingAll,
            fixAllStatus: _fixAllStatus,
          ),
          const SizedBox(height: Insets.md),
          Expanded(
            child: showProgress
                ? _AuditProgress(label: _statusLabel)
                : (findings == null || findings.isEmpty)
                    ? const _AuditClean()
                    : ListView.separated(
                        itemCount: findings.length,
                        separatorBuilder: (_, __) =>
                            const SizedBox(height: Insets.sm),
                        itemBuilder: (BuildContext context, int i) {
                          final AuditFinding f = findings[i];
                          return _FindingCard(
                            finding: f,
                            state: _fixState[f.id] ?? _FixState.idle,
                            statusLine: _fixStatus[f.id],
                            onFix: () => _runFix(f),
                          )
                              .animate(delay: Duration(milliseconds: 50 * i))
                              .fadeIn(duration: AppMotion.base)
                              .slideY(
                                begin: 0.12,
                                curve: AppMotion.emphasized,
                              );
                        },
                      ),
          ),
        ],
      ),
    );
  }
}

/// Maps a severity string to its semantic color.
Color _severityColor(String severity) {
  switch (severity) {
    case 'critical':
    case 'high':
      return Palette.err;
    case 'medium':
      return Palette.warn;
    case 'low':
    case 'info':
    default:
      return Palette.info;
  }
}

/// Header with a posture line, per-severity count chips, and a re-run button.
class _AuditHeader extends StatelessWidget {
  const _AuditHeader({
    required this.findings,
    required this.running,
    required this.onRerun,
    required this.onFixAll,
    required this.onHistory,
    required this.fixingAll,
    required this.fixAllStatus,
  });

  final List<AuditFinding>? findings;
  final bool running;
  final VoidCallback? onRerun;

  /// Applies every auto-fixable finding at once; null hides the button.
  final VoidCallback? onFixAll;

  /// Opens the posture-history dialog; null hides the affordance.
  final VoidCallback? onHistory;
  final bool fixingAll;
  final String fixAllStatus;

  @override
  Widget build(BuildContext context) {
    final List<AuditFinding> list = findings ?? const <AuditFinding>[];

    final Map<String, int> counts = <String, int>{};
    for (final AuditFinding f in list) {
      counts[f.severity] = (counts[f.severity] ?? 0) + 1;
    }

    final int fixableCount =
        list.where((AuditFinding f) => f.fixable).length;
    final bool showFixAll = onFixAll != null && fixableCount > 0;

    final String posture;
    if (findings == null) {
      posture = running ? 'Running audit…' : 'Run a security audit';
    } else if (list.isEmpty) {
      posture = 'All checks passed';
    } else {
      posture =
          '${list.length} ${list.length == 1 ? 'finding' : 'findings'}';
    }

    const List<String> order = <String>[
      'critical', 'high', 'medium', 'low', 'info'
    ];

    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: <Widget>[
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              SectionHeader(title: 'Security audit', subtitle: posture),
              if (counts.isNotEmpty) ...<Widget>[
                const SizedBox(height: Insets.xs),
                Wrap(
                  spacing: Insets.sm,
                  runSpacing: Insets.xs,
                  children: <Widget>[
                    for (final String sev in order)
                      if ((counts[sev] ?? 0) > 0)
                        _SeverityChip(severity: sev, count: counts[sev]!),
                  ],
                ),
              ],
            ],
          ),
        ),
        const SizedBox(width: Insets.sm),
        Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                if (onHistory != null) ...<Widget>[
                  IconButton(
                    tooltip: 'Posture history',
                    icon: const Icon(Icons.history_toggle_off),
                    onPressed: onHistory,
                  ),
                  const SizedBox(width: Insets.xs),
                ],
                if (showFixAll) ...<Widget>[
                  AppButton(
                    label: 'Fix all',
                    icon: Icons.auto_fix_high,
                    loading: fixingAll,
                    onPressed: (fixingAll || running) ? null : onFixAll,
                  ),
                  const SizedBox(width: Insets.sm),
                ],
                AppButton(
                  label: 'Re-run audit',
                  icon: Icons.refresh,
                  tonal: true,
                  loading: running,
                  onPressed: fixingAll ? null : onRerun,
                ),
              ],
            ),
            if (fixingAll && fixAllStatus.isNotEmpty) ...<Widget>[
              const SizedBox(height: Insets.xs),
              Text(
                fixAllStatus,
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
              ),
            ],
          ],
        ),
      ],
    );
  }
}

/// A small colored "N critical" pill summarizing a severity bucket.
class _SeverityChip extends StatelessWidget {
  const _SeverityChip({required this.severity, required this.count});
  final String severity;
  final int count;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Color c = _severityColor(severity);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(Insets.radiusSm),
        border: Border.all(color: c.withValues(alpha: 0.5)),
      ),
      child: Text(
        '$count $severity',
        style: theme.textTheme.labelSmall?.copyWith(
          color: c,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

/// A live spinner with the current section/step label while the audit runs.
class _AuditProgress extends StatelessWidget {
  const _AuditProgress({required this.label});
  final String label;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          const SizedBox(
            width: 28,
            height: 28,
            child: CircularProgressIndicator(strokeWidth: 2.5),
          ),
          const SizedBox(height: Insets.md),
          Text(
            label.isEmpty ? 'Auditing…' : label,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

/// The "all clear" empty state shown when no findings remain.
class _AuditClean extends StatelessWidget {
  const _AuditClean();

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(Icons.verified_user_outlined, size: 40, color: Palette.ok),
          const SizedBox(height: Insets.md),
          Text(
            'All checks passed',
            style: theme.textTheme.titleMedium?.copyWith(color: Palette.ok),
          ),
          const SizedBox(height: Insets.xs),
          Text(
            'No security findings.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

/// One finding rendered as a [GlassCard]: severity badge, title, detail,
/// recommendation, and a Fix button (or a 'manual' tag when not fixable).
class _FindingCard extends StatelessWidget {
  const _FindingCard({
    required this.finding,
    required this.state,
    required this.statusLine,
    required this.onFix,
  });

  final AuditFinding finding;
  final _FixState state;
  final String? statusLine;
  final VoidCallback onFix;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Color sev = _severityColor(finding.severity);
    final bool fixed = state == _FixState.fixed;
    final bool failed = state == _FixState.failed;

    return GlassCard(
      padding: const EdgeInsets.all(Insets.md),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          _SeverityBadge(severity: finding.severity, color: sev),
          const SizedBox(width: Insets.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  finding.title,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                if (finding.detail.isNotEmpty) ...<Widget>[
                  const SizedBox(height: Insets.xs),
                  Text(
                    finding.detail,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
                if (finding.recommendation.isNotEmpty) ...<Widget>[
                  const SizedBox(height: Insets.sm),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        '→ ',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: Palette.teal,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      Expanded(
                        child: Text(
                          finding.recommendation,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurface,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
                if (statusLine != null && !fixed) ...<Widget>[
                  const SizedBox(height: Insets.sm),
                  Text(
                    statusLine!,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: failed
                          ? Palette.err
                          : theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: Insets.md),
          _FindingAction(finding: finding, state: state, onFix: onFix),
        ],
      ),
    );
  }
}

/// The colored severity badge on the left of a finding card.
class _SeverityBadge extends StatelessWidget {
  const _SeverityBadge({required this.severity, required this.color});
  final String severity;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(Insets.radiusSm),
        border: Border.all(color: color.withValues(alpha: 0.6)),
      ),
      child: Text(
        severity.toUpperCase(),
        style: theme.textTheme.labelSmall?.copyWith(
          color: color,
          fontWeight: FontWeight.w800,
          letterSpacing: 0.5,
        ),
      ),
    );
  }
}

/// The trailing action on a finding card: Fix button, inline spinner, a green
/// "Fixed" state, or a subtle "manual" tag for non-fixable findings.
class _FindingAction extends StatelessWidget {
  const _FindingAction({
    required this.finding,
    required this.state,
    required this.onFix,
  });

  final AuditFinding finding;
  final _FixState state;
  final VoidCallback onFix;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);

    if (state == _FixState.fixed) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(Icons.check_circle, size: 18, color: Palette.ok),
          const SizedBox(width: 6),
          Text(
            'Fixed',
            style: theme.textTheme.labelLarge?.copyWith(
              color: Palette.ok,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      );
    }

    if (!finding.fixable) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest
              .withValues(alpha: 0.4),
          borderRadius: BorderRadius.circular(Insets.radiusSm),
          border: Border.all(
            color: theme.colorScheme.outline.withValues(alpha: 0.6),
          ),
        ),
        child: Text(
          'manual',
          style: theme.textTheme.labelSmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
            fontWeight: FontWeight.w600,
          ),
        ),
      );
    }

    final bool running = state == _FixState.running;
    return AppButton(
      label: state == _FixState.failed
          ? 'Retry'
          : (finding.fixLabel.isEmpty ? 'Fix' : finding.fixLabel),
      icon: state == _FixState.failed ? Icons.refresh : Icons.build_outlined,
      loading: running,
      onPressed: running ? null : onFix,
    );
  }
}

/// A dialog listing audit-posture snapshots over time: per-row date, a tiny
/// inline bar of the total (relative to the worst snapshot), per-severity
/// counts and the total.
class _AuditHistoryDialog extends StatelessWidget {
  const _AuditHistoryDialog({required this.snapshots});
  final List<Map<String, dynamic>> snapshots;

  int _i(Map<String, dynamic> m, String k) => (m[k] as num?)?.toInt() ?? 0;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final int maxTotal = snapshots.fold<int>(
      1,
      (int acc, Map<String, dynamic> m) =>
          _i(m, 'total') > acc ? _i(m, 'total') : acc,
    );

    return AlertDialog(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Insets.radiusLg),
      ),
      title: Row(
        children: <Widget>[
          Icon(Icons.history_toggle_off,
              color: theme.colorScheme.primary, size: 20),
          const SizedBox(width: Insets.sm),
          const Text('Posture history'),
        ],
      ),
      content: SizedBox(
        width: 460,
        child: snapshots.isEmpty
            ? const Text('No history available.')
            : SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    for (final Map<String, dynamic> s in snapshots)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 6),
                        child: Row(
                          children: <Widget>[
                            SizedBox(
                              width: 116,
                              child: Text(
                                s['at']?.toString() ?? '',
                                style: theme.textTheme.labelSmall?.copyWith(
                                  color: theme.colorScheme.onSurfaceVariant,
                                ),
                              ),
                            ),
                            const SizedBox(width: Insets.sm),
                            Expanded(
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(4),
                                child: LinearProgressIndicator(
                                  value: _i(s, 'total') / maxTotal,
                                  minHeight: 6,
                                  backgroundColor:
                                      theme.colorScheme.surfaceContainerHighest,
                                  valueColor: AlwaysStoppedAnimation<Color>(
                                    _i(s, 'total') == 0
                                        ? Palette.ok
                                        : Palette.warn,
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(width: Insets.sm),
                            Text(
                              'C${_i(s, 'critical')} H${_i(s, 'high')} '
                              'M${_i(s, 'medium')} L${_i(s, 'low')}',
                              style: AppTheme.mono(
                                context,
                                size: 11,
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                            const SizedBox(width: Insets.sm),
                            SizedBox(
                              width: 28,
                              child: Text(
                                '${_i(s, 'total')}',
                                textAlign: TextAlign.right,
                                style: theme.textTheme.labelMedium?.copyWith(
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
      ),
      actions: <Widget>[
        AppButton(
          label: 'Close',
          onPressed: () => Navigator.of(context).pop(),
        ),
      ],
    );
  }
}
