import 'dart:async';
import 'dart:convert';

import 'cli_event.dart';

/// Transforms a stream of raw stdout string chunks into a stream of
/// [CliEvent]s, one per newline-delimited JSON object.
///
/// dartssh2 delivers stdout in arbitrarily-sized chunks, so a single chunk may
/// contain a partial line, several lines, or a line split across chunks. This
/// transformer buffers the trailing partial line until its newline arrives.
///
/// Non-JSON lines (e.g. stray bash output) are tolerated: they are wrapped as
/// an info [LogEvent] so nothing is silently dropped.
class NdjsonTransformer extends StreamTransformerBase<String, CliEvent> {
  const NdjsonTransformer();

  @override
  Stream<CliEvent> bind(Stream<String> stream) {
    return Stream<CliEvent>.eventTransformed(
      stream,
      (EventSink<CliEvent> sink) => _NdjsonSink(sink),
    );
  }
}

class _NdjsonSink implements EventSink<String> {
  _NdjsonSink(this._out);

  final EventSink<CliEvent> _out;
  final StringBuffer _buffer = StringBuffer();

  @override
  void add(String chunk) {
    _buffer.write(chunk);
    final String contents = _buffer.toString();

    final int lastNewline = contents.lastIndexOf('\n');
    if (lastNewline < 0) {
      // No complete line yet; keep buffering.
      return;
    }

    final String complete = contents.substring(0, lastNewline);
    final String remainder = contents.substring(lastNewline + 1);

    _buffer
      ..clear()
      ..write(remainder);

    for (final String line in complete.split('\n')) {
      _emitLine(line);
    }
  }

  void _emitLine(String rawLine) {
    final String line = rawLine.trim();
    if (line.isEmpty) return;

    try {
      final Object? decoded = jsonDecode(line);
      if (decoded is Map<String, dynamic>) {
        _out.add(CliEvent.fromJson(decoded));
        return;
      }
      // Valid JSON but not an object — surface it as a log line.
      _out.add(LogEvent(level: 'info', msg: line));
    } on FormatException {
      // Not JSON at all — surface verbatim so the user still sees it.
      _out.add(LogEvent(level: 'info', msg: line));
    }
  }

  @override
  void addError(Object error, [StackTrace? stackTrace]) {
    _out.addError(error, stackTrace);
  }

  @override
  void close() {
    // Flush any trailing line that lacked a final newline.
    final String tail = _buffer.toString();
    if (tail.trim().isNotEmpty) {
      _emitLine(tail);
    }
    _buffer.clear();
    _out.close();
  }
}
