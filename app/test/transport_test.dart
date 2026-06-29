// Pure-logic tests for the transport layer: NDJSON parsing and the CliEvent
// union. These exercise the exact wire format the bash backend emits
// (lib/core/json.sh + ui.sh) so the two stay in lockstep — no UI, no timers.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:server_manager_ui/transport/cli_event.dart';
import 'package:server_manager_ui/transport/ndjson.dart';

CliEvent parse(String json) =>
    CliEvent.fromJson(jsonDecode(json) as Map<String, dynamic>);

void main() {
  group('CliEvent.fromJson', () {
    test('version handshake', () {
      final e = parse('{"t":"version","contract":"1","version":"0.1.0"}');
      expect(e, isA<VersionEvent>());
      expect((e as VersionEvent).contract, '1');
      expect(e.version, '0.1.0');
    });

    test('step_start / step_end with duration and error', () {
      expect(parse('{"t":"step_start","id":"s1","label":"Pull"}'),
          isA<StepStart>());
      final ok = parse('{"t":"step_end","id":"s1","ok":true,"dur":1.4}');
      expect(ok, isA<StepEnd>());
      expect((ok as StepEnd).ok, isTrue);
      expect(ok.dur, 1.4);
      final fail = parse(
          '{"t":"step_end","id":"s2","ok":false,"dur":0.3,"err":"boom"}');
      expect((fail as StepEnd).ok, isFalse);
      expect(fail.err, 'boom');
    });

    test('log levels, section, banner, progress', () {
      expect((parse('{"t":"log","level":"warn","msg":"x"}') as LogEvent).level,
          'warn');
      expect((parse('{"t":"section","label":"Deploy"}') as SectionEvent).label,
          'Deploy');
      expect((parse('{"t":"banner","label":"update"}') as BannerEvent).label,
          'update');
      final p = parse('{"t":"progress","cur":3,"total":12,"label":"build"}')
          as ProgressEvent;
      expect(p.fraction, closeTo(0.25, 1e-9));
    });

    test('report fields and data payload', () {
      final r = parse(
              '{"t":"report","title":"Done","fields":{"URL":"https://x.test","PHP":"8.3"}}')
          as ReportEvent;
      expect(r.fields['URL'], 'https://x.test');
      expect(r.fields['PHP'], '8.3');
      final d = parse('{"t":"data","kind":"sites","items":[{"domain":"a"}]}')
          as DataEvent;
      expect(d.kind, 'sites');
      expect(d.items, hasLength(1));
    });

    test('need + done terminal', () {
      expect((parse('{"t":"need","id":"domain"}') as NeedEvent).id, 'domain');
      expect((parse('{"t":"done","ok":true}') as DoneEvent).ok, isTrue);
    });

    test('unknown discriminator is tolerated, not thrown', () {
      expect(parse('{"t":"future_event","x":1}'), isA<UnknownEvent>());
    });
  });

  group('NdjsonTransformer', () {
    Future<List<CliEvent>> run(List<String> chunks) {
      return Stream<String>.fromIterable(chunks)
          .transform(const NdjsonTransformer())
          .toList();
    }

    test('parses a clean multi-line deploy stream', () async {
      final events = await run(<String>[
        '{"t":"banner","label":"update"}\n'
            '{"t":"step_start","id":"s1","label":"Pull"}\n'
            '{"t":"step_end","id":"s1","ok":true,"dur":1.4}\n'
            '{"t":"done","ok":true}\n',
      ]);
      expect(events.map((e) => e.runtimeType.toString()), <String>[
        'BannerEvent', 'StepStart', 'StepEnd', 'DoneEvent',
      ]);
    });

    test('reassembles a JSON object split across chunks', () async {
      final events = await run(<String>['{"t":"sec', 'tion","label":"X"}\n']);
      expect(events, hasLength(1));
      expect((events.single as SectionEvent).label, 'X');
    });

    test('flushes a trailing line with no final newline on close', () async {
      final events = await run(<String>['{"t":"done","ok":true}']);
      expect(events.single, isA<DoneEvent>());
    });

    test('non-JSON lines are surfaced as logs, never dropped', () async {
      final events = await run(<String>['oops not json\n{"t":"done","ok":false}\n']);
      expect(events, hasLength(2));
      expect((events.first as LogEvent).msg, 'oops not json');
    });
  });
}
