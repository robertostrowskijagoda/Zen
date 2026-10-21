import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/features/pyramid/presentation/pyramid_timeline_view.dart';
import 'package:zen/src/features/pyramid/pyramid_record.dart';
import 'package:zen/src/features/pyramid/pyramid_state.dart';
import 'package:zen/src/features/pyramid/pyramid_timeline.dart';

import 'support/pyramid_world.dart';

/// The animated history: the fold notes every change of a place, the
/// timeline replays them from keyframes, and the view plays them.
const int t0 = FoldWorld.t0;
const int day = FoldWorld.day;

/// S, A, B, A1, A2, B1, X, Y joined; X and Y make X the head of A1's cell;
/// B1 leaves; A1 and X remove Y.
Future<(FoldWorld, PyramidState)> history() async {
  final FoldWorld w = await FoldWorld.make();
  final PyramidState st = w.fold(<PyramidRecord>[
    await w.rec(
      PyrT.swap,
      t0 + day,
      <String>['X', 'Y'],
      <String, dynamic>{'cell': '00', 'head': w.id('A1'), 'up': w.id('X')},
    ),
    await w.rec(
      PyrT.leave,
      t0 + 2 * day,
      <String>['B1'],
      <String, dynamic>{'k': w.id('B1')},
    ),
    await w.rec(
      PyrT.remove,
      t0 + 3 * day,
      <String>['X', 'A1'],
      <String, dynamic>{'k': w.id('Y')},
    ),
  ]);
  return (w, st);
}

void main() {
  group('snapshots', () {
    test('one step per record that moved somebody; the last one is the '
        'pyramid now', () async {
      final (FoldWorld w, PyramidState st) = await history();
      final PyrTimeline tl = PyrTimeline.ofState(st);
      // Founding, 7 admissions, the swap, a leave, a removal.
      expect(tl.length, 11);
      expect(tl.positionsAfter(0), isEmpty);
      expect(tl.positionsAfter(1), <String, String>{w.id('S'): ''});
      expect(tl.positionsAfter(tl.length), st.position);
      final PyrTimelineStep swap = tl.steps[8];
      expect(swap.moves, hasLength(2));
      expect(swap.text, contains('zamienił'));
      expect(tl.positionsAfter(9)[w.id('X')], '00');
      expect(tl.positionsAfter(9)[w.id('A1')], '000');
      expect(tl.positionsAfter(10).containsKey(w.id('B1')), isFalse);
      expect(tl.names[w.id('Y')], 'Y');
    });

    test(
      'keyframes give the same places as replaying from the start',
      () async {
        final (FoldWorld _, PyramidState st) = await history();
        final PyrTimeline every = PyrTimeline.ofState(st, every: 1);
        final PyrTimeline none = PyrTimeline.ofState(st, every: 1000);
        final PyrTimeline three = PyrTimeline.ofState(st, every: 3);
        for (int i = 0; i <= every.length; i++) {
          expect(every.positionsAfter(i), none.positionsAfter(i), reason: '$i');
          expect(three.positionsAfter(i), none.positionsAfter(i), reason: '$i');
        }
        expect(every.keyframeCount, every.length + 1);
        expect(none.keyframeCount, 1);
      },
    );

    test('a long history keeps few keyframes and scrubs exactly', () {
      final List<PyrMove> moves = <PyrMove>[
        for (int i = 0; i < 20000; i++)
          PyrMove(i, 'r$i', 'k${i % 300}', i % 7 == 0 ? null : '${i % 2}1'),
      ];
      final PyrTimeline tl = PyrTimeline.build(
        moves,
        const <String, String>{},
        const <String, String>{},
      );
      expect(tl.length, 20000);
      expect(tl.keyframeCount, lessThanOrEqualTo(kPyrTimelineKeyframes + 1));
      final Map<String, String> naive = <String, String>{};
      for (final PyrMove m in moves.take(12345)) {
        if (m.path == null) {
          naive.remove(m.key);
        } else {
          naive[m.key] = m.path!;
        }
      }
      expect(tl.positionsAfter(12345), naive);
    });

    test('a big tree shows the top and the part around me and the people '
        'picked', () {
      // A full tree of 6 levels (63 people).
      final Map<String, String> all = <String, String>{};
      void add(String p) {
        all['k$p'] = p;
        if (p.length < 5) {
          add('${p}0');
          add('${p}1');
        }
      }

      add('');
      final Set<String> shown = pyrVisiblePaths(all, <String>['k01101']);
      expect(shown, containsAll(<String>['', '0', '1', '00', '11']));
      expect(shown, containsAll(<String>['011', '0110', '01100', '01101']));
      expect(shown, isNot(contains('11111')));
      expect(shown, isNot(contains('100')));
      expect(
        pyrVisiblePaths(<String, String>{'a': '', 'b': '0'}, const <String>[]),
        <String>{'', '0'},
      );
    });
  });

  group('the view', () {
    Widget app(PyramidState st, String me, {bool still = false}) => MaterialApp(
      theme: ZenTheme.dark(),
      home: MediaQuery(
        data: MediaQueryData(disableAnimations: still),
        child: Scaffold(
          body: SingleChildScrollView(
            child: PyramidTimelineView(s: st, me: me),
          ),
        ),
      ),
    );

    String event(WidgetTester tester) =>
        tester.widget<Text>(find.byKey(const Key('pyr-timeline-event'))).data!;

    testWidgets('starts now; the slider and play walk through the steps; '
        'people are picked', (WidgetTester tester) async {
      late FoldWorld w;
      late PyramidState st;
      await tester.runAsync(() async {
        (w, st) = await history();
      });
      final PyrTimeline tl = PyrTimeline.ofState(st);
      await tester.pumpWidget(app(st, w.id('X')));
      expect(event(tester), contains(tl.steps.last.text));
      // Y was removed: not in the tree now.
      expect(find.byKey(ValueKey<String>('pyr-tl-${w.id('Y')}')), findsNothing);
      expect(
        find.byKey(ValueKey<String>('pyr-tl-${w.id('X')}')),
        findsOneWidget,
      );

      // Back to the start.
      tester
          .widget<Slider>(find.byKey(const Key('pyr-timeline-slider')))
          .onChanged!(0);
      await tester.pump();
      expect(event(tester), contains('Początek'));
      expect(find.byKey(ValueKey<String>('pyr-tl-${w.id('S')}')), findsNothing);

      // Play at 4×: a step every 250 ms.
      await tester.tap(find.byKey(const Key('pyr-timeline-speed-3')));
      await tester.tap(find.byKey(const Key('pyr-timeline-play')));
      await tester.pump(const Duration(milliseconds: 260));
      expect(event(tester), contains(tl.steps[0].text));
      await tester.pump(const Duration(milliseconds: 250));
      expect(event(tester), contains(tl.steps[1].text));
      // Pause: it stays.
      await tester.tap(find.byKey(const Key('pyr-timeline-play')));
      await tester.pump(const Duration(seconds: 2));
      expect(event(tester), contains(tl.steps[1].text));

      // A step of the list jumps there; a tap on a person picks them.
      await tester.tap(find.byKey(const Key('pyr-timeline-step-0')));
      await tester.pump();
      expect(event(tester), contains(tl.steps[0].text));
      await tester.tap(find.byKey(ValueKey<String>('pyr-tl-${w.id('S')}')));
      await tester.pump();
      expect(
        find.byKey(Key('pyr-timeline-picked-${w.id('S')}')),
        findsOneWidget,
      );

      // Played to the end, it stops by itself.
      await tester.tap(find.byKey(const Key('pyr-timeline-play')));
      for (int i = 0; i < 12; i++) {
        await tester.pump(const Duration(milliseconds: 250));
      }
      expect(event(tester), contains(tl.steps.last.text));
      expect(find.byIcon(Icons.play_arrow_rounded), findsOneWidget);
    });

    testWidgets('people move animated, or at once with reduced motion', (
      WidgetTester tester,
    ) async {
      late FoldWorld w;
      late PyramidState st;
      await tester.runAsync(() async {
        (w, st) = await history();
      });
      Duration motion() => tester
          .widget<AnimatedPositioned>(
            find.byKey(ValueKey<String>('pyr-tl-${w.id('S')}')),
          )
          .duration;
      await tester.pumpWidget(app(st, w.id('X')));
      expect(motion(), greaterThan(Duration.zero));
      await tester.pumpWidget(app(st, w.id('X'), still: true));
      expect(motion(), Duration.zero);
    });
  });
}
