import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/features/pyramid/pyramid_record.dart';
import 'package:zen/src/features/pyramid/pyramid_state.dart';

import 'support/pyramid_world.dart';

/// A head who leaves never cuts a branch off: for a week the two under the
/// free place may take it, then the one longer on their level moves up by
/// itself and the hole moves one level down, with a week of its own.
/// Until then votes and branch sums go round the hole to the nearest head
/// above. And whoever comes into a cell of people they do not know votes
/// there only once one of them says "Poznaliśmy się", or after 14 days.
const int t0 = FoldWorld.t0;
const int day = FoldWorld.day;
const int h = FoldWorld.hour;

/// S on top, A and B under S; A1 and A2 under A; X and Y under A1; P and Q
/// under A2. Everybody admitted by their head (so known by them).
const List<(String, String?, String)> kHoleTree = <(String, String?, String)>[
  ('S', null, ''),
  ('A', 'S', '0'),
  ('B', 'S', '1'),
  ('A1', 'A', '00'),
  ('A2', 'A', '01'),
  ('X', 'A1', '000'),
  ('Y', 'A1', '001'),
  ('P', 'A2', '010'),
  ('Q', 'A2', '011'),
];

void main() {
  Future<PyramidRecord> leave(FoldWorld w, int at, String who) =>
      w.rec(PyrT.leave, at, <String>[who], <String, dynamic>{'k': w.id(who)});

  Future<PyramidRecord> swap(
    FoldWorld w,
    int at,
    String cell,
    String head,
    String up,
    List<String> by,
  ) => w.rec(PyrT.swap, at, by, <String, dynamic>{
    'cell': cell,
    'head': w.id(head),
    'up': w.id(up),
  });

  /// A1 goes down a level and comes back up: on level 2 again only from
  /// day 9 (A2 has been there from the start), though A1 joined earlier.
  Future<List<PyramidRecord>> a1DownAndUp(FoldWorld w) async => <PyramidRecord>[
    await swap(w, t0 + day, '00', 'A1', 'X', <String>['X', 'Y']),
    await swap(w, t0 + 9 * day, '00', 'X', 'A1', <String>['A1', 'Y']),
  ];

  test('after 7 days the one longer on their level takes the free place by '
      'itself; the hole moves down with a week of its own', () async {
    final FoldWorld w = await FoldWorld.make(tree: kHoleTree);
    final List<PyramidRecord> recs = <PyramidRecord>[
      ...await a1DownAndUp(w),
      await leave(w, t0 + 10 * day, 'A'),
    ];
    const int freed = t0 + 10 * day;
    String? path(PyramidState s, String who) => s.pathOf(w.id(who));

    // The week of the two under it: nothing happens by itself.
    final PyramidState inWeek = w.fold(recs, now: freed + kPyrAutoFillMs - 1);
    expect(inWeek.vacant, contains('0'));
    expect(inWeek.vacantSince['0'], freed);
    expect(inWeek.autoFillOf('0'), (freed + kPyrAutoFillMs, w.id('A2')));
    expect(path(inWeek, 'A2'), '01');
    expect(inWeek.levelSince(w.id('A1')), t0 + 9 * day);

    // Then A2 (on level 2 from the start) moves up, not A1 (joined earlier,
    // left of A2, but back on level 2 only since day 9).
    final PyramidState after = w.fold(recs, now: freed + kPyrAutoFillMs);
    expect(path(after, 'A2'), '0');
    expect(path(after, 'A1'), '00');
    expect(after.lastRise[w.id('A2')], freed + kPyrAutoFillMs);
    expect(after.vacant, isNot(contains('0')));
    // A2's old place is free now, P and Q still under it, with a new week.
    expect(after.vacant, contains('01'));
    expect(after.vacantSince['01'], freed + kPyrAutoFillMs);
    expect(
      after.history.map((PyrHistory x) => x.text),
      contains(contains('po 7 dniach')),
    );
    expect(
      after.moves.where((PyrMove m) => m.key == w.id('A2')).last.cause,
      startsWith('auto|0|'),
    );

    // No cascade at once: P and Q get their own week.
    final PyramidState weekTwo = w.fold(
      recs,
      now: freed + 2 * kPyrAutoFillMs - 1,
    );
    expect(weekTwo.vacant, contains('01'));
    expect(path(weekTwo, 'P'), '010');
    final PyramidState cascaded = w.fold(recs, now: freed + 2 * kPyrAutoFillMs);
    // P and Q both on level 3 since they joined: P joined first.
    expect(path(cascaded, 'P'), '01');
    expect(path(cascaded, 'Q'), '011');
    expect(cascaded.vacant, isEmpty, reason: 'nobody left under P');

    // Never cut off: everybody but A is still in the tree, all the time.
    for (final PyramidState s in <PyramidState>[
      inWeek,
      after,
      weekTwo,
      cascaded,
    ]) {
      expect(s.position, hasLength(8));
      expect(s.branchSize(''), 8);
      expect(s.pathOf(w.id('A')), isNull);
    }
  });

  test('within the week the two under it decide; a fill after the week comes '
      'too late', () async {
    final FoldWorld w = await FoldWorld.make(tree: kHoleTree);
    final PyramidRecord left = await leave(w, t0 + day, 'A');
    Future<PyramidRecord> fill(int at, String up) => w.rec(
      PyrT.fill,
      at,
      <String>['A1', 'A2'],
      <String, dynamic>{'cell': '0', 'up': w.id(up)},
    );
    // A2 by agreement on day 6 of the week.
    final PyramidRecord inTime = await fill(t0 + day + 6 * day, 'A2');
    final PyramidState agreed = w.fold(<PyramidRecord>[left, inTime]);
    expect(agreed.applied, contains(inTime.id));
    expect(agreed.pathOf(w.id('A2')), '0');

    // Nobody signs in time: A1 (as long on level 2, joined first) moves up
    // by itself, and a fill signed later finds no free place there.
    final PyramidRecord late = await fill(t0 + day + kPyrAutoFillMs + h, 'A2');
    final PyramidState missed = w.fold(<PyramidRecord>[left, late]);
    expect(missed.pathOf(w.id('A1')), '0');
    expect(missed.rejected[late.id], 'miejsce nie jest wolne');
  });

  test('nobody moves up twice within a week: the place waits until one of '
      'the two may', () async {
    final FoldWorld w = await FoldWorld.make(tree: kHoleTree);
    const int freed = t0 + day;
    final List<PyramidRecord> recs = <PyramidRecord>[
      await leave(w, freed, 'A'),
      // In the week, X and P each become the head of their cell.
      await swap(w, freed + 3 * day, '00', 'A1', 'X', <String>['X', 'Y']),
      await swap(w, freed + 3 * day + 1, '01', 'A2', 'P', <String>['P', 'Q']),
    ];
    final PyramidState waiting = w.fold(recs, now: freed + 9 * day);
    expect(waiting.vacant, contains('0'), reason: 'both rose 6 days ago');
    expect(waiting.autoFillOf('0'), (freed + 10 * day, w.id('X')));
    final PyramidState filled = w.fold(recs, now: freed + 10 * day);
    expect(filled.pathOf(w.id('X')), '0', reason: 'X may first');
    expect(filled.pathOf(w.id('P')), '01');
  });

  test('votes and branch sums go round a free place to the nearest head '
      'above', () async {
    final FoldWorld w = await FoldWorld.make(tree: kHoleTree);
    const int freed = t0 + day;
    final PyramidRecord left = await leave(w, freed, 'A');
    const int end = freed + 3 * h;
    final PyramidRecord ref = await w.rec(
      PyrT.referendum,
      freed + h,
      <String>['S', 'B'],
      <String, dynamic>{
        'q': 'Świetlica?',
        'opts': <String>['Tak', 'Nie'],
        'end': end,
      },
    );
    Future<PyramidRecord> tally(
      String who,
      int at,
      List<int> counts, [
      List<PyramidRecord> kids = const <PyramidRecord>[],
    ]) => w.rec(
      PyrT.tally,
      at,
      <String>[who],
      <String, dynamic>{
        'ref': ref.id,
        'counts': counts,
        'kids': <String>[for (final PyramidRecord k in kids) k.id],
      },
    );
    // A1 counts X and Y, A2 counts P and Q (each the only ones under them).
    final PyramidRecord a1 = await tally('A1', end + 1, <int>[2, 0]);
    final PyramidRecord a2 = await tally('A2', end + 2, <int>[1, 1]);
    // S, past the free place: A1's and A2's branches as its own, and the
    // votes of A1, A2 and B (three people reporting to S).
    final PyramidRecord tooMany = await tally(
      'S',
      end + 3,
      <int>[6, 2],
      <PyramidRecord>[a1, a2],
    );
    final PyramidRecord top = await tally(
      'S',
      end + 4,
      <int>[5, 2],
      <PyramidRecord>[a1, a2],
    );
    final PyramidState st = w.fold(<PyramidRecord>[
      left,
      ref,
      a1,
      a2,
      tooMany,
      top,
    ], now: freed + day);
    expect(st.vacant, contains('0'));
    expect(st.headAbove('00'), '');
    expect(st.headAbove('010'), '01');
    expect(st.reportsTo(''), <String>['00', '01', '1']);
    expect(st.rejected[tooMany.id], 'zawyżona suma');
    expect(st.applied, containsAll(<String>[a1.id, a2.id, top.id]));
    expect(st.resultOf(ref.id, strict: true), <int>[5, 2]);
  });

  test('new in a cell of strangers: the vote counts there after "Poznaliśmy '
      'się" or 14 days', () async {
    final FoldWorld w = await FoldWorld.make(tree: kHoleTree);
    const int freed = t0 + day;
    const int filled = freed + kPyrAutoFillMs;
    final PyramidRecord left = await leave(w, freed, 'A');
    // A1 moves up by itself and comes into the top cell: S and B do not
    // know A1. B wants S's place; A1's signature is the second.
    Future<PyramidRecord> bUp(int at) =>
        swap(w, at, '', 'S', 'B', <String>['B', 'A1']);
    final PyramidRecord soon = await bUp(filled + day);
    final PyramidState st = w.fold(<PyramidRecord>[left, soon]);
    expect(st.rejected[soon.id], contains('2 z 3'));

    final PyramidState before = w.fold(<PyramidRecord>[
      left,
    ], now: filled + day);
    final String a1 = w.id('A1');
    expect(before.pathOf(a1), '0');
    expect(before.canVote(a1, filled + day), isTrue, reason: 'in referenda');
    expect(before.votesInCell(a1, '', filled + day), isFalse);
    expect(before.cellVoters('', filled + day).toSet(), <String>{
      w.id('S'),
      w.id('B'),
    });
    expect(before.togetherSince(a1, w.id('S')), filled);
    expect(before.cellVoteFrom(a1, '', filled + day), filled + kPyrVoteAfterMs);
    expect(before.metWith(a1, w.id('S'), filled + day), isFalse);

    // 14 days together: it counts.
    final PyramidRecord later = await bUp(filled + kPyrVoteAfterMs);
    final PyramidState st2 = w.fold(<PyramidRecord>[left, later]);
    expect(st2.applied, contains(later.id));
    expect(st2.pathOf(w.id('B')), '');

    // Or at once, when S confirms knowing A1.
    final PyramidRecord known = await w.rec(
      PyrT.known,
      filled + h,
      <String>['S'],
      <String, dynamic>{'k': a1},
    );
    final PyramidState st3 = w.fold(<PyramidRecord>[left, known, soon]);
    expect(st3.applied, contains(known.id));
    expect(st3.metWith(a1, w.id('S'), filled + day), isTrue);
    expect(st3.votesInCell(a1, '', filled + day), isTrue);
    expect(st3.applied, contains(soon.id));
    expect(st3.pathOf(w.id('B')), '');
  });

  test('every phone works out the same promotions: a fold now, a fold moved '
      'on in time and records added in place agree', () async {
    final FoldWorld w = await FoldWorld.make(tree: kHoleTree);
    final List<PyramidRecord> recs = <PyramidRecord>[
      ...await a1DownAndUp(w),
      await leave(w, t0 + 10 * day, 'A'),
    ];
    final PyramidRecord alive = await w.rec(
      PyrT.alive,
      t0 + 26 * day,
      <String>['S'],
      <String, dynamic>{'k': w.id('S')},
    );
    const int now = t0 + 30 * day;
    String look(PyramidState s) =>
        '${PyramidWorld.fingerprint(s)}|${s.vacant.toList()..sort()}|'
        '${s.vacantSince}|${s.moves.length}|${s.lastRise}';

    final PyramidState whole = w.fold(<PyramidRecord>[
      ...recs,
      alive,
    ], now: now);
    // Moved on in time past both promotions (no record in between).
    final PyramidState moved = w.fold(recs, now: t0 + 12 * day)..advanceTo(now);
    expect(look(moved), look(w.fold(recs, now: now)));
    // A record after the second promotion, added in place.
    final PyramidState extended = w.fold(recs, now: t0 + 20 * day);
    expect(extended.extend(<PyramidRecord>[alive], now: now), isTrue);
    expect(look(extended), look(whole));
    expect(whole.pathOf(w.id('A2')), '0');
    expect(whole.pathOf(w.id('P')), '01');
  });

  test('on the phones: votes go past the free place to the head above, and '
      'after a week everybody sees the same promotion', () async {
    final PyramidWorld w = await PyramidWorld.six();
    await w.knowAll();
    await w['A'].leave();
    await w.net.run();
    await w.sync();
    expect(w['S'].state!.vacant, contains('0'));

    // The top is S and B now: a referendum, 2 of them.
    await w['S'].referendum(
      question: 'Świetlica?',
      options: <String>['Tak', 'Nie'],
      end: w.net.now + 3600 * 1000,
    );
    await w.net.run();
    await w.approve('B', PyrT.referendum);
    final PyrReferendum ref = w['B1'].state!.referenda.values.single;
    final Map<String, int> votes = <String, int>{
      'S': 0,
      'B': 1,
      'A1': 0,
      'A2': 1,
      'B1': 0,
    };
    for (final MapEntry<String, int> v in votes.entries) {
      expect(
        await w[v.key].voteReferendum(ref.id, v.value),
        isTrue,
        reason: '${v.key}: A1 and A2 vote to S, past the free place',
      );
    }
    await w.net.run();
    await w.net.advance(
      Duration(milliseconds: ref.end - w.net.now + 60 * 1000),
    );
    await w.duties();
    expect(w['B1'].state!.resultOf(ref.id, strict: true), <int>[3, 2]);

    // Nobody took the place in the week: A1 (joined before A2) moves up by
    // itself, on every phone alike.
    await w.net.advance(const Duration(days: 7));
    await w.sync();
    for (final String who in <String>['S', 'B', 'A1', 'A2', 'B1']) {
      final PyramidState st = w[who].state!;
      expect(st.pathOf(w['A1'].myKey!), '0', reason: who);
      expect(st.vacant, isEmpty, reason: who);
    }
    final Map<String, String> views = w.views()..remove('A');
    expect(views.values.toSet(), hasLength(1), reason: views.toString());
  });
}
