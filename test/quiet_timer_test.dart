import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/core/utils/quiet_timer.dart';

void main() {
  testWidgets('runs once things go quiet, once for a whole burst', (
    WidgetTester tester,
  ) async {
    int runs = 0;
    final QuietTimer timer = QuietTimer(
      quiet: const Duration(seconds: 5),
      atMost: const Duration(seconds: 30),
      action: () => runs++,
    );
    timer.nudge();
    await tester.pump(const Duration(seconds: 2));
    timer.nudge();
    await tester.pump(const Duration(seconds: 4));
    expect(runs, 0);
    expect(timer.isPending, isTrue);
    await tester.pump(const Duration(seconds: 2));
    expect(runs, 1);
    expect(timer.isPending, isFalse);
    await tester.pump(const Duration(minutes: 1));
    expect(runs, 1);
  });

  testWidgets('a steady trickle holds it off no longer than atMost', (
    WidgetTester tester,
  ) async {
    int runs = 0;
    final QuietTimer timer = QuietTimer(
      quiet: const Duration(seconds: 5),
      atMost: const Duration(seconds: 30),
      action: () => runs++,
    );
    // News every 3 seconds: never 5 quiet seconds.
    for (int second = 0; second < 29; second += 3) {
      timer.nudge();
      await tester.pump(const Duration(seconds: 3));
    }
    expect(runs, 1);
    timer.cancel();
    await tester.pump(const Duration(minutes: 1));
    expect(runs, 1);
  });
}
