import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/features/pyramid/presentation/hold_to_confirm.dart';
import 'package:zen/src/features/pyramid/pyramid_court.dart';
import 'package:zen/src/features/pyramid/pyramid_feed.dart';
import 'package:zen/src/features/pyramid/pyramid_record.dart';
import 'package:zen/src/features/pyramid/pyramid_state.dart';

import 'support/pyramid_world.dart';

/// The emission limit as a hard rule: lower at once; anything that lets
/// more money out announced to everybody, in force 30 days later, and
/// cancelled by the top meanwhile if it wants. Lowering in the app asks
/// "Czy na pewno?" and a button held for 2 s.
const int t0 = FoldWorld.t0;
const int day = FoldWorld.day;

void main() {
  final int limit = PyrParams().emitLimit;

  Future<PyramidRecord> rule(
    FoldWorld w,
    int at,
    Map<String, dynamic> fields, {
    List<String> by = const <String>['S', 'A'],
  }) => w.rec(PyrT.emitRule, at, by, fields);

  Future<PyramidRecord> cancel(
    FoldWorld w,
    int at,
    PyramidRecord change, {
    List<String> by = const <String>['S', 'B'],
  }) => w.rec(PyrT.emitCancel, at, by, <String, dynamic>{'change': change.id});

  test('a lower limit applies at once; a higher one 30 days after it is '
      'announced, pinned for every member meanwhile', () async {
    final FoldWorld w = await FoldWorld.make();
    final PyramidRecord lower = await rule(w, t0 + day, <String, dynamic>{
      'limit': limit ~/ 2,
    });
    final PyramidRecord alone = await rule(
      w,
      t0 + day + 1,
      <String, dynamic>{'limit': 2 * limit},
      by: <String>['S'],
    );
    final PyramidRecord raise = await rule(w, t0 + 2 * day, <String, dynamic>{
      'limit': 2 * limit,
    });
    final List<PyramidRecord> all = <PyramidRecord>[lower, alone, raise];
    PyramidState st = w.fold(all, now: t0 + day + 10);
    expect(st.params.emitLimit, limit ~/ 2, reason: 'lower: at once');
    expect(st.rejected[alone.id], contains('2 z 3'));

    st = w.fold(all, now: t0 + 2 * day + 29 * day);
    expect(st.params.emitLimit, limit ~/ 2, reason: 'not yet');
    final PyrEmitChange c = st.pendingEmitChanges.single;
    expect(c.effectiveAt, t0 + 2 * day + kPyrEmitChangeWaitMs);
    expect(kPyrEmitChangeWaitMs, 30 * day);
    // Every member sees it on the Tablica, pinned.
    final PyramidFeed feed = pyramidFeedOf(
      state: st,
      me: w.id('Y'),
      now: t0 + 2 * day + 29 * day,
    );
    expect(feed.alarms.where((PyrFeedAlarm a) => a.notice), hasLength(1));

    st = w.fold(all, now: t0 + 2 * day + 30 * day);
    expect(st.params.emitLimit, 2 * limit);
    expect(st.pendingEmitChanges, isEmpty);
  });

  test('the top cancels a raise within the 30 days, never after', () async {
    final FoldWorld w = await FoldWorld.make();
    const int at = t0 + day;
    final PyramidRecord raise = await rule(w, at, <String, dynamic>{
      'limit': 3 * limit,
    });
    final PyramidRecord byOne = await cancel(
      w,
      at + day,
      raise,
      by: <String>['B'],
    );
    final PyramidRecord byTwo = await cancel(w, at + 10 * day, raise);
    PyramidState st = w.fold(<PyramidRecord>[raise, byOne, byTwo]);
    expect(st.rejected[byOne.id], contains('2 z 3'));
    expect(st.emitChanges[raise.id]!.cancelled, isTrue);
    expect(st.params.emitLimit, limit);

    final PyramidRecord raise2 = await rule(w, at + 11 * day, <String, dynamic>{
      'limit': 3 * limit,
    });
    final PyramidRecord tooLate = await cancel(w, at + 41 * day, raise2);
    st = w.fold(<PyramidRecord>[raise, byTwo, raise2, tooLate]);
    expect(st.rejected[tooLate.id], contains('za późno'));
    expect(st.params.emitLimit, 3 * limit);
  });

  test('a shorter wait before an emission counts is a raise too; it never '
      'goes under a day; one change waits at a time', () async {
    final FoldWorld w = await FoldWorld.make();
    final PyramidRecord longer = await rule(w, t0 + day, <String, dynamic>{
      'delayH': 72,
    });
    final PyramidRecord shorter = await rule(w, t0 + 2 * day, <String, dynamic>{
      'delayH': 1,
    });
    final PyramidRecord another = await rule(w, t0 + 3 * day, <String, dynamic>{
      'limit': 2 * limit,
    });
    PyramidState st = w.fold(<PyramidRecord>[
      longer,
      shorter,
      another,
    ], now: t0 + 4 * day);
    expect(st.params.emitDelayHours, 72, reason: 'longer: at once');
    final PyrEmitChange c = st.emitChanges[shorter.id]!;
    expect(c.delayHours, kPyrMinEmitDelayHours);
    expect(st.rejected[another.id], contains('już czeka'));
    st = w.fold(<PyramidRecord>[longer, shorter], now: t0 + 33 * day);
    expect(st.params.emitDelayHours, 24);
  });

  test(
    'a raise that came late counts its 30 days from when it was seen',
    () async {
      final FoldWorld w = await FoldWorld.make();
      final PyramidRecord raise = await rule(w, t0 + day, <String, dynamic>{
        'limit': 2 * limit,
      });
      const int seen = t0 + 20 * day;
      final PyramidState st = w.fold(
        <PyramidRecord>[raise],
        now: t0 + 32 * day,
        late: <String, int>{raise.id: seen},
      );
      expect(st.params.emitLimit, limit);
      expect(st.emitChanges[raise.id]!.effectiveAt, seen + 30 * day);
    },
  );

  group('holding to confirm', () {
    Widget app(void Function(bool) done) => MaterialApp(
      theme: ZenTheme.dark(),
      home: Scaffold(
        body: Builder(
          builder: (BuildContext context) => TextButton(
            onPressed: () async => done(
              await confirmByHolding(
                context,
                body: 'Nowy limit: 500,00',
                action: 'Przytrzymaj, aby obniżyć limit',
              ),
            ),
            child: const Text('open'),
          ),
        ),
      ),
    );

    testWidgets('"Czy na pewno?" and 2 s of holding: let go sooner, '
        'nothing happens', (WidgetTester tester) async {
      bool? result;
      await tester.pumpWidget(app((bool v) => result = v));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.text('Czy na pewno?'), findsOneWidget);
      final Finder hold = find.byKey(const Key('hold-to-confirm'));

      // A tap, and a hold of one second: nothing.
      await tester.tap(hold);
      await tester.pump(const Duration(milliseconds: 300));
      TestGesture g = await tester.startGesture(tester.getCenter(hold));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      final CircularProgressIndicator half = tester.widget(
        find.byKey(const Key('hold-to-confirm-progress')),
      );
      expect(half.value, closeTo(0.5, 0.05));
      await g.up();
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('Czy na pewno?'), findsOneWidget);
      expect(result, isNull);

      // Held to the end: confirmed.
      g = await tester.startGesture(tester.getCenter(hold));
      await tester.pump();
      for (int i = 0; i < 22; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      await g.up();
      await tester.pumpAndSettle();
      expect(find.text('Czy na pewno?'), findsNothing);
      expect(result, isTrue);
    });

    testWidgets('"Anuluj" says no', (WidgetTester tester) async {
      bool? result;
      await tester.pumpWidget(app((bool v) => result = v));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Anuluj'));
      await tester.pumpAndSettle();
      expect(result, isFalse);
    });
  });
}
