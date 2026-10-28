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
void main() {
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
