import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/features/pyramid/pyramid_ledger.dart';
import 'package:zen/src/features/pyramid/pyramid_record.dart';
import 'package:zen/src/features/pyramid/pyramid_service.dart';
import 'package:zen/src/features/pyramid/pyramid_state.dart';

import 'support/pyramid_world.dart';

/// The fold done incrementally: new records extend the pyramid in place
/// (exactly as folding everything again would), time moves it on, and
/// only a record into the past folds it again — in the background for a
/// big pyramid.
void main() {
  const int t0 = FoldWorld.t0;
  const int h = FoldWorld.hour;
  const int day = FoldWorld.day;

  /// What two folds must agree on.
  void same(PyramidState a, PyramidState b) {
    expect(a.describe(), b.describe());
    expect(a.applied, b.applied);
    expect(a.rejected, b.rejected);
    expect(
      a.history.map((PyrHistory x) => '${x.at} ${x.text}').toList(),
      b.history.map((PyrHistory x) => '${x.at} ${x.text}').toList(),
    );
    expect(a.params.toJson(), b.params.toJson());
    expect(a.posts.keys.toSet(), b.posts.keys.toSet());
    expect(
      <String, bool>{
        for (final PyrEmission e in a.emissions.values) e.id: e.done,
      },
      <String, bool>{
        for (final PyrEmission e in b.emissions.values) e.id: e.done,
      },
    );
  }

  late FoldWorld w;
  late PyramidRecord post1;
  late PyramidRecord emit;
  late PyramidRecord post2;
  late PyramidRecord rules;

  setUp(() async {
    w = await FoldWorld.make();
    post1 = await w.rec(
      PyrT.post,
      t0 + day,
      <String>['A'],
      <String, dynamic>{'text': 'Pierwszy', 'lvl': 1},
    );
    emit = await w.rec(
      PyrT.emit,
      t0 + day + h,
      <String>['S', 'A'],
      <String, dynamic>{'rc': pyrEmitCommit(w.id('A1'), 'sol'), 'amount': 1000},
    );
    post2 = await w.rec(
      PyrT.post,
      t0 + 3 * day,
      <String>['B'],
      <String, dynamic>{'text': 'Drugi', 'lvl': 1},
    );
    rules = await w.rec(
      PyrT.emitRule,
      t0 + 3 * day + h,
      <String>['S', 'A'],
      <String, dynamic>{'xfers': 10},
    );
  });

  test('new records extend a fold in place, as folding everything again '
      'would; time moves it on', () {
    final PyramidState whole = w.fold(<PyramidRecord>[
      post1,
      emit,
      post2,
      rules,
    ], now: t0 + 4 * day);
    final PyramidState part = w.fold(<PyramidRecord>[post1], now: t0 + day);
    expect(part.extend(<PyramidRecord>[emit], now: t0 + day + 2 * h), isTrue);
    expect(part.emissions[emit.id]!.done, isFalse);
    final int revision = part.revision;
    // The emission's day passes: done, in place.
    part.advanceTo(t0 + 2 * day + 2 * h);
    expect(part.emissions[emit.id]!.done, isTrue);
    expect(part.revision, greaterThan(revision));
    expect(
      part.extend(<PyramidRecord>[rules, post2], now: t0 + 4 * day),
      isTrue,
    );
    same(part, whole);
    expect(part.params.xferLimit, 10);
  });

  test('a record into the past is not taken in place: the pyramid is folded '
      'again', () async {
    // Before the last record applied.
    PyramidState st = w.fold(<PyramidRecord>[post2], now: t0 + 3 * day);
    expect(st.extend(<PyramidRecord>[post1], now: t0 + 3 * day), isFalse);
    // After the last record, but before a change by time already made
    // (the emission's day ended at t0 + 2 days + 1 h).
    st = w.fold(<PyramidRecord>[emit], now: t0 + 3 * day);
    final PyramidRecord before = await w.rec(
      PyrT.post,
      t0 + 2 * day,
      <String>['B'],
      <String, dynamic>{'text': 'Wcześniej', 'lvl': 1},
    );
    expect(st.extend(<PyramidRecord>[before], now: t0 + 3 * day), isFalse);
    // One kept already (another copy, more signatures).
    st = w.fold(<PyramidRecord>[post1], now: t0 + 2 * day);
    expect(st.extend(<PyramidRecord>[post1], now: t0 + 2 * day), isFalse);
    // One seen late: it folds at another time.
    st = w.fold(<PyramidRecord>[post1], now: t0 + 2 * day);
    expect(
      st.extend(
        <PyramidRecord>[emit],
        now: t0 + 2 * day,
        late: <String, int>{emit.id: t0 + 2 * day},
      ),
      isFalse,
    );
    // Nothing new: only time moves.
    st = w.fold(<PyramidRecord>[post1], now: t0 + day);
    expect(st.extend(const <PyramidRecord>[], now: t0 + 2 * day), isTrue);
  });

  test('a whole fold in a background isolate gives the same pyramid', () async {
    final List<PyramidRecord> all = <PyramidRecord>[
      ...w.records,
      post1,
      emit,
      post2,
      rules,
    ];
    final PyramidState away = await pyrFoldInBackground(
      w.py,
      all,
      now: t0 + 4 * day,
    );
    same(away, PyramidState.fold(w.py, all, now: t0 + 4 * day));
  });

  test('on a phone new records do not fold the pyramid again; a record '
      'into the past does, with the same result', () async {
    final PyramidWorld world = await PyramidWorld.six();
    final PyramidService s = world['S'];
    // A few hours in the pyramid: a post dated back two hours is then from
    // when its author already had the level (one dated before that would
    // be rejected).
    await world.net.advance(const Duration(hours: 3));
    expect(s.state, isNotNull);
    final int folds = s.foldCount;
    for (int i = 0; i < 4; i++) {
      expect(await world['A'].post('Post $i'), isNotNull);
      await world.net.run();
    }
    expect(s.state!.posts, hasLength(4));
    expect(s.foldCount, folds, reason: 'extended in place');
    same(s.state!, s.foldedAfresh()!);
    // Minutes pass: moved on in place.
    await world.net.advance(const Duration(minutes: 3));
    expect(s.state, isNotNull);
    expect(s.foldCount, folds);
    // A record dated before the newest S has: folded again.
    final PyramidService b = world['B'];
    final PyramidRecord back = await b.signAsMe(
      PyramidRecord(
        body: <String, dynamic>{
          't': PyrT.post,
          'py': s.current,
          'at': world.net.now - 2 * 3600 * 1000,
          'by': <String>[b.myKey!],
          'text': 'Wcześniej',
          'lvl': 1,
        },
      ),
    );
    expect(await s.ingest(back), isTrue);
    expect(s.foldCount, folds + 1);
    expect(s.state!.posts.keys, contains(back.id));
    same(s.state!, s.foldedAfresh()!);
  });
}
