import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/features/feed/presentation/seen_tracker.dart';

/// „Przeczytało” counts a card only once it was really on the screen: at
/// least half of it, for a second, its page showing.
void main() {
  test('the visible share of an item in a viewport', () {
    expect(visibleShare(top: 0, height: 100, viewportHeight: 600), 1);
    expect(visibleShare(top: 550, height: 100, viewportHeight: 600), 0.5);
    expect(visibleShare(top: -60, height: 100, viewportHeight: 600), 0.4);
    expect(visibleShare(top: 620, height: 100, viewportHeight: 600), 0);
    expect(visibleShare(top: -100, height: 100, viewportHeight: 600), 0);
    expect(visibleShare(top: 0, height: 0, viewportHeight: 600), 0);
  });

  Widget list(List<Widget> children, {ScrollController? controller}) =>
      MaterialApp(
        home: Scaffold(
          body: ListView(controller: controller, children: children),
        ),
      );

  Widget tracked(int n, List<int> seen, {bool enabled = true}) => SeenTracker(
    enabled: enabled,
    onSeen: () => seen.add(n),
    child: SizedBox(height: 100, child: Text('card $n')),
  );

  testWidgets('on screen for a second: seen once; built below the fold or '
      'less than half shown: not', (WidgetTester tester) async {
    final List<int> seen = <int>[];
    final ScrollController controller = ScrollController();
    addTearDown(controller.dispose);
    // The test screen is 600 high: card 1 is in full view, card 2 shows 40,
    // card 3 is built ahead below the fold.
    await tester.pumpWidget(
      list(<Widget>[
        tracked(1, seen),
        const SizedBox(height: 460),
        tracked(2, seen),
        tracked(3, seen),
      ], controller: controller),
    );
    await tester.pump(const Duration(milliseconds: 900));
    expect(seen, isEmpty, reason: 'not a second yet');
    await tester.pump(const Duration(milliseconds: 200));
    expect(seen, <int>[1]);
    await tester.pump(const Duration(seconds: 3));
    expect(seen, <int>[1], reason: 'once; 2 and 3 not shown enough');

    // Card 3 scrolled into view, but away again within the second.
    controller.jumpTo(160);
    await tester.pump(const Duration(milliseconds: 500));
    controller.jumpTo(0);
    await tester.pump(const Duration(seconds: 2));
    expect(seen, <int>[1]);

    controller.jumpTo(160);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1100));
    expect(seen, <int>[1, 2, 3]);
  });

  testWidgets('a hidden page (another tab, a route on top) or a card off '
      'is not counted', (WidgetTester tester) async {
    final List<int> seen = <int>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: IndexedStack(
            index: 0,
            children: <Widget>[
              ListView(children: <Widget>[tracked(1, seen, enabled: false)]),
              ListView(children: <Widget>[tracked(2, seen)]),
            ],
          ),
        ),
      ),
    );
    await tester.pump(const Duration(seconds: 2));
    expect(seen, isEmpty);

    await tester.pumpWidget(
      MaterialApp(
        home: TickerMode(
          enabled: false,
          child: Scaffold(body: ListView(children: <Widget>[tracked(3, seen)])),
        ),
      ),
    );
    await tester.pump(const Duration(seconds: 2));
    expect(seen, isEmpty);
  });
}
