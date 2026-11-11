import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/features/runtime/runtime_native_signal_transport.dart';
import 'package:zen/src/features/runtime/yggdrasil_bridge_ffi.dart';

/// A node start or stop blocks the thread that calls into the Go library
/// for as long as the library takes: taking an identity over from the
/// Android service stops the service's node inside that very call. Made
/// on the UI isolate, it froze the screen (the logo, or the lock screen)
/// and every timer of the start with it. The calls run on a helper
/// isolate now; these tests block a helper the same way a stuck bridge
/// call would.
Map<String, dynamic> _linksOf(int handle) => <String, dynamic>{
  'handle': handle,
  'up': 1,
};

void main() {
  test('the link check of a wake reaches the helper isolate: it carries '
      'nothing but the node handle', () async {
    // On a phone every check failed before it began ("object is
    // unsendable"): its closure was written inside the function that
    // starts the session and carried that function's context along, the
    // pin keeper and its futures included.
    expect(await checkNodeLinksOffThread(7, check: _linksOf), <String, dynamic>{
      'handle': 7,
      'up': 1,
    });

    // And nothing in the function that starts the session sends a closure
    // of its own to another isolate: what it sends goes through functions
    // that hold only what they are given.
    final String source = File(
      'lib/src/features/runtime/runtime_native_signal_transport.dart',
    ).readAsStringSync().replaceAll('\r\n', '\n');
    final int start = source.indexOf(
      'Future<RuntimeNodeSession> _bootstrapDefaultRuntimeSession({',
    );
    expect(start, greaterThan(0));
    final String body = source.substring(start, source.indexOf('\n}\n', start));
    expect(body, contains('checkNodeLinksOffThread(handle)'));
    expect(body, isNot(contains('runNodeCallOffThread<')));
    expect(body, isNot(contains('Isolate.run')));
  });

  test(
    'a bridge call that blocks its thread never stops this isolate',
    () async {
      int ticks = 0;
      final Timer clock = Timer.periodic(
        const Duration(milliseconds: 50),
        (_) => ticks += 1,
      );
      final int answer = await runNodeCallOffThread<int>(() {
        // What a takeover stuck in node shutdown looks like from Dart.
        sleep(const Duration(milliseconds: 1200));
        return 7;
      });
      clock.cancel();
      expect(answer, 7);
      // The timers of this isolate kept running all along.
      expect(ticks, greaterThanOrEqualTo(10));
    },
  );

  test(
    'a bridge call that does not come back is given up after its limit',
    () async {
      final Stopwatch watch = Stopwatch()..start();
      await expectLater(
        runNodeCallOffThread<int>(() {
          sleep(const Duration(seconds: 3));
          return 1;
        }, timeout: const Duration(milliseconds: 300)),
        throwsA(isA<TimeoutException>()),
      );
      expect(watch.elapsed, lessThan(const Duration(seconds: 2)));
    },
  );

  test('what the bridge says comes back as it said it', () async {
    await expectLater(
      runNodeCallOffThread<int>(
        () => throw const YggdrasilBridgeException(
          'a node with this identity already runs in this process',
        ),
      ),
      throwsA(
        isA<YggdrasilBridgeException>().having(
          (YggdrasilBridgeException e) => e.message,
          'message',
          contains('already runs'),
        ),
      ),
    );
  });
}
