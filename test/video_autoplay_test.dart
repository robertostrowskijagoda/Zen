import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/features/feed/presentation/video_autoplay.dart';

void main() {
  testWidgets('a video in a hidden tab or under another page does not play', (
    WidgetTester tester,
  ) async {
    final List<bool> seen = <bool>[];
    Widget probe(String label) => Builder(
      builder: (BuildContext context) {
        seen.add(mayAutoplayAt(context));
        return Text(label);
      },
    );

    // The shell's tabs: an IndexedStack whose hidden children have their
    // tickers off.
    await tester.pumpWidget(
      MaterialApp(
        home: Column(
          children: <Widget>[
            TickerMode(enabled: true, child: probe('shown')),
            TickerMode(enabled: false, child: probe('hidden')),
          ],
        ),
      ),
    );
    expect(seen, <bool>[true, false]);

    // A page pushed over the feed.
    seen.clear();
    final GlobalKey<NavigatorState> navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigator,
        home: Scaffold(body: probe('feed')),
      ),
    );
    expect(seen.last, isTrue);
    navigator.currentState!.push(
      MaterialPageRoute<void>(
        builder: (BuildContext _) => const Scaffold(body: Text('rozmowa')),
      ),
    );
    await tester.pumpAndSettle();
    expect(seen.last, isFalse);
    navigator.currentState!.pop();
    await tester.pumpAndSettle();
    expect(seen.last, isTrue);
  });

  test('the autoplay picks only what is seen enough', () {
    final VideoAutoplay auto = VideoAutoplay.instance;
    final Object a = Object();
    final Object b = Object();
    auto
      ..report(a, visible: 1, top: 10)
      ..report(b, visible: 1, top: 200);
    expect(auto.active, same(a));
    // The first one went out of sight (a hidden tab reports nothing seen).
    auto.report(a, visible: 0, top: double.infinity);
    expect(auto.active, same(b));
    auto.report(b, visible: 0, top: double.infinity);
    expect(auto.active, isNull);
    auto
      ..remove(a)
      ..remove(b);
  });
}
