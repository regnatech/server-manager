import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../transport/cli_event.dart';
import 'connection_provider.dart';

/// Lifecycle of a single step in a streamed operation.
enum StepStatus { pending, running, ok, failed }

/// A single node in the deploy/provision timeline, accumulated from
/// [StepStart] / [StepEnd] / [LogEvent] events.
class DeployStep {
  DeployStep({
    required this.id,
    required this.label,
    this.status = StepStatus.running,
    this.durationSeconds,
    this.error,
    List<LogLine>? logs,
  }) : logs = logs ?? <LogLine>[];

  final String id;
  String label;
  StepStatus status;
  double? durationSeconds;
  String? error;
  final List<LogLine> logs;

  DeployStep copy() => DeployStep(
        id: id,
        label: label,
        status: status,
        durationSeconds: durationSeconds,
        error: error,
        logs: List<LogLine>.of(logs),
      );
}

/// A captured log line with its severity level.
class LogLine {
  const LogLine(this.level, this.msg);
  final String level;
  final String msg;
}

/// Aggregate state for an in-flight or finished operation.
class DeployState {
  const DeployState({
    this.banner,
    this.section,
    this.steps = const <DeployStep>[],
    this.preamble = const <LogLine>[],
    this.progressLabel,
    this.progressFraction,
    this.report,
    this.running = false,
    this.done = false,
    this.ok,
    this.needsMoreAnswers = false,
    this.errorMessage,
  });

  final String? banner;
  final String? section;

  /// Ordered timeline nodes.
  final List<DeployStep> steps;

  /// Logs emitted before any step started (e.g. under a banner).
  final List<LogLine> preamble;

  final String? progressLabel;
  final double? progressFraction;

  /// Final report card, if a [ReportEvent] was received.
  final ReportEvent? report;

  final bool running;
  final bool done;

  /// Terminal success flag from [DoneEvent], null until done.
  final bool? ok;

  /// True if a [NeedEvent] requested more answers (re-run required).
  final bool needsMoreAnswers;

  final String? errorMessage;

  DeployState copyWith({
    String? banner,
    String? section,
    List<DeployStep>? steps,
    List<LogLine>? preamble,
    String? progressLabel,
    double? progressFraction,
    ReportEvent? report,
    bool? running,
    bool? done,
    bool? ok,
    bool? needsMoreAnswers,
    String? errorMessage,
  }) {
    return DeployState(
      banner: banner ?? this.banner,
      section: section ?? this.section,
      steps: steps ?? this.steps,
      preamble: preamble ?? this.preamble,
      progressLabel: progressLabel ?? this.progressLabel,
      progressFraction: progressFraction ?? this.progressFraction,
      report: report ?? this.report,
      running: running ?? this.running,
      done: done ?? this.done,
      ok: ok ?? this.ok,
      needsMoreAnswers: needsMoreAnswers ?? this.needsMoreAnswers,
      errorMessage: errorMessage ?? this.errorMessage,
    );
  }
}

/// Consumes a [CliEvent] stream and folds it into a live [DeployState].
///
/// Used both by the site Deploy tab and the add-wizard Provision step. Call
/// [start] with a freshly-built event stream; watch [state] for live updates.
class DeployController extends StateNotifier<DeployState> {
  DeployController() : super(const DeployState());

  StreamSubscription<CliEvent>? _sub;

  /// Begins consuming [events]. Resets any prior run.
  void start(Stream<CliEvent> events) {
    _sub?.cancel();
    state = const DeployState(running: true);
    _sub = events.listen(
      _onEvent,
      onError: (Object e) {
        state = state.copyWith(
          running: false,
          done: true,
          ok: false,
          errorMessage: e.toString(),
        );
      },
      onDone: () {
        if (state.running) {
          state = state.copyWith(running: false, done: true);
        }
      },
    );
  }

  void _onEvent(CliEvent e) {
    switch (e) {
      case BannerEvent(:final String label):
        state = state.copyWith(banner: label);
      case SectionEvent(:final String label):
        state = state.copyWith(section: label);
      case StepStart(:final String id, :final String label):
        final List<DeployStep> steps = _cloneSteps();
        steps.add(DeployStep(id: id, label: label, status: StepStatus.running));
        state = state.copyWith(steps: steps);
      case StepEnd(:final String id, :final bool ok, :final double dur, :final String? err):
        final List<DeployStep> steps = _cloneSteps();
        final DeployStep? step = _find(steps, id);
        if (step != null) {
          step.status = ok ? StepStatus.ok : StepStatus.failed;
          step.durationSeconds = dur;
          step.error = err;
        }
        state = state.copyWith(steps: steps);
      case LogEvent(:final String level, :final String msg):
        _appendLog(level, msg);
      case ProgressEvent(:final String label):
        state = state.copyWith(
          progressLabel: label,
          progressFraction: e.fraction,
        );
      case NeedEvent():
        state = state.copyWith(needsMoreAnswers: true);
      case ReportEvent():
        state = state.copyWith(report: e);
      case DoneEvent(:final bool ok):
        state = state.copyWith(running: false, done: true, ok: ok);
      case DataEvent():
      case VersionEvent():
      case UnknownEvent():
        // Not relevant to the timeline view.
        break;
    }
  }

  /// Appends a log line to the most recent running/finished step, or to the
  /// preamble if no step has started yet.
  void _appendLog(String level, String msg) {
    final List<DeployStep> steps = _cloneSteps();
    if (steps.isEmpty) {
      final List<LogLine> pre = List<LogLine>.of(state.preamble)
        ..add(LogLine(level, msg));
      state = state.copyWith(preamble: pre);
      return;
    }
    steps.last.logs.add(LogLine(level, msg));
    state = state.copyWith(steps: steps);
  }

  List<DeployStep> _cloneSteps() =>
      state.steps.map((DeployStep s) => s.copy()).toList();

  DeployStep? _find(List<DeployStep> steps, String id) {
    for (final DeployStep s in steps) {
      if (s.id == id) return s;
    }
    return null;
  }

  /// Resets to an empty, idle state.
  void reset() {
    _sub?.cancel();
    _sub = null;
    state = const DeployState();
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }
}

/// Per-domain deploy controller. `.family` keeps each site's timeline distinct.
final deployProvider = StateNotifierProvider.autoDispose
    .family<DeployController, DeployState, String>((ref, domain) {
  return DeployController();
});

/// Standalone controller used by the add wizard's Provision step.
final addProvisionProvider =
    StateNotifierProvider.autoDispose<DeployController, DeployState>((ref) {
  return DeployController();
});
