import 'dart:async';
import 'dart:io';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/app/start_trace.dart';
import 'package:zen/src/core/logging/zen_log.dart';

const ZenStartStep _lock = ZenStartStep('app-lock', label: 'blokada aplikacji');
const ZenStartStep _service = ZenStartStep(
  'background-service',
  label: 'usługa w tle',
  optional: true,
);

void main() {
  late Directory folder;

  setUp(() {
    ZenStartTrace.debugReset();
    folder = Directory.systemTemp.createTempSync('zen-start-trace-');
  });

  tearDown(() {
    ZenStartTrace.debugReset();
    folder.deleteSync(recursive: true);
  });

  File startLog() => File(
    '${folder.path}${Platform.pathSeparator}'
    '${ZenDiagnosticsLog.fileNameFor(ZenStartTrace.logSource)}',
  );

  test('a step is on disk before it runs, and its end with how long it '
      'took', () async {
    ZenStartTrace.begin();
    ZenStartTrace.attach(folder);
    final Completer<int> gate = Completer<int>();
    final Future<int> running = ZenStartTrace.run<int>(
      _lock,
      () => gate.future,
      timeout: const Duration(seconds: 30),
    );
    // Written at once, not queued: a start ended here leaves it behind.
    expect(startLog().readAsStringSync(), contains('step app-lock begins'));
    expect(ZenStartTrace.current.value, _lock);
    gate.complete(7);
    expect(await running, 7);
    expect(ZenStartTrace.current.value, isNull);
    expect(
      startLog().readAsStringSync(),
      matches(RegExp(r'step app-lock ok \d+ ms')),
    );
  });

  test('an optional step that takes too long gives its fallback; a needed '
      'one fails with the step named', () {
    fakeAsync((FakeAsync async) {
      ZenStartTrace.begin();
      String? optional;
      Object? needed;
      ZenStartTrace.run<String>(
        _service,
        () => Completer<String>().future,
        timeout: const Duration(seconds: 5),
        fallback: () => 'without',
      ).then((String value) => optional = value);
      async.elapse(const Duration(seconds: 6));
      expect(optional, 'without');

      ZenStartTrace.run<String>(
        _lock,
        () => Completer<String>().future,
        timeout: const Duration(seconds: 5),
      ).catchError((Object error) {
        needed = error;
        return '';
      });
      async.elapse(const Duration(seconds: 6));
      expect(needed, isA<ZenStartStepTimeout>());
      expect((needed! as ZenStartStepTimeout).step, _lock);
    });
  });

  test('"Uruchom bez …" skips the optional step running now', () async {
    ZenStartTrace.begin();
    final Future<String> running = ZenStartTrace.run<String>(
      _service,
      () => Completer<String>().future,
      timeout: const Duration(minutes: 5),
      fallback: () => 'skipped',
    );
    expect(ZenStartTrace.canSkip, isTrue);
    ZenStartTrace.skip();
    expect(await running, 'skipped');
    expect(ZenStartTrace.canSkip, isFalse);
  });

  test('a needed step can never be skipped', () async {
    ZenStartTrace.begin();
    final Completer<String> gate = Completer<String>();
    final Future<String> running = ZenStartTrace.run<String>(
      _lock,
      () => gate.future,
      timeout: const Duration(minutes: 5),
    );
    expect(ZenStartTrace.canSkip, isFalse);
    ZenStartTrace.skip();
    gate.complete('done');
    expect(await running, 'done');
  });

  test('the next start says where the previous one stopped', () async {
    ZenStartTrace.begin();
    ZenStartTrace.attach(folder);
    unawaited(
      ZenStartTrace.run<void>(
        _lock,
        () => Completer<void>().future,
        timeout: const Duration(minutes: 5),
      ),
    );
    // The process ends here (killed, or the person gave up).
    ZenStartTrace.debugReset();

    ZenStartTrace.begin();
    ZenStartTrace.attach(folder);
    expect(ZenStartTrace.previousStop, 'app-lock');
    // The earlier start's log stays beside the new one.
    expect(File('${startLog().path}.1').existsSync(), isTrue);
    ZenStartTrace.reached();
    ZenStartTrace.debugReset();

    ZenStartTrace.attach(folder);
    expect(ZenStartTrace.previousStop, isNull);
  });

  test('reading where a logged start stopped', () {
    expect(ZenStartTrace.stopOf(''), isNull);
    expect(
      ZenStartTrace.stopOf(
        't [start] START begins\n'
        't [start] step settings begins\n'
        't [start] step settings ok 12 ms\n'
        't [start] step app-lock begins\n',
      ),
      'app-lock',
    );
    expect(
      ZenStartTrace.stopOf(
        't [start] START begins\n'
        't [start] step network begins\n'
        't [start] step receive-in-background begins\n'
        't [start] step receive-in-background timeout 6000 ms\n',
      ),
      'network',
    );
    expect(
      ZenStartTrace.stopOf(
        't [start] START begins\n'
        't [start] step network ok 3 ms\n'
        't [start] ${ZenStartTrace.reachedMarker} after 900 ms\n',
      ),
      isNull,
    );
  });

  test('every step leaves a TECH line in the diagnostics log', () async {
    ZenStartTrace.begin();
    await ZenStartTrace.run<int>(
      _lock,
      () async => 1,
      timeout: const Duration(seconds: 5),
    );
    final List<String> lines = await ZenDiagnosticsLog.entries();
    expect(
      lines.where((String line) => line.contains('TECH  start step=app-lock')),
      isNotEmpty,
    );
    expect(
      lines.firstWhere((String l) => l.contains('step=app-lock')),
      matches(RegExp(r'ms=\d+ result=ok')),
    );
  });
}
