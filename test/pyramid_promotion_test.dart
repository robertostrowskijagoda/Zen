import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/features/pyramid/pyramid_feed.dart';
import 'package:zen/src/features/pyramid/pyramid_record.dart';
import 'package:zen/src/features/pyramid/pyramid_state.dart';

import 'support/pyramid_world.dart';

/// Promotion goes step by step: one level at a time, each with the
/// consent of that level, at most once a week; moving to another cell
/// goes sideways or down, or one level up; a whole branch never moves up;
/// a member who left comes back no higher. And no minimum number of
/// people anywhere: the highest member of a nationality leads its section.
const int t0 = FoldWorld.t0;
const int day = FoldWorld.day;
const int h = FoldWorld.hour;

/// S on top with a free place beside A; A1 under A; X and Y under A1.
const List<(String, String?, String)> kNarrow = <(String, String?, String)>[
  ('S', null, ''),
  ('A', 'S', '0'),
  ('A1', 'A', '00'),
  ('X', 'A1', '000'),
  ('Y', 'A1', '001'),
];

void main() {
  Future<PyramidRecord> migrate(
    FoldWorld w,
    int at,
    String who,
    String to, {
    bool branch = false,
    List<String>? signers,
  }) => w.rec(PyrT.migrate, at, signers ?? <String>[who, to], <String, dynamic>{
    'k': w.id(who),
    'to': w.id(to),
    if (branch) 'branch': true,
  });

  test('moving to another cell: never more than one level up, and not '
      'again within a week', () async {
    final FoldWorld w = await FoldWorld.make(tree: kNarrow);
    // X (level 4) under S would land on level 2: two levels up.
    final PyramidRecord jump = await migrate(w, t0 + day, 'X', 'S');
    // One level up, under A: A agrees.
    final PyramidRecord step = await migrate(w, t0 + day + 1, 'X', 'A');
    // Under S at once: one more level, too soon.
    final PyramidRecord soon = await migrate(w, t0 + 2 * day, 'X', 'S');
    final PyramidRecord week = await migrate(
      w,
      t0 + day + 1 + kPyrRiseCooldownMs,
      'X',
      'S',
    );
    final PyramidState st = w.fold(<PyramidRecord>[jump, step, soon, week]);
    expect(st.rejected[jump.id], contains('jeden poziom'));
    expect(st.rejected[soon.id], contains('7 dni'));
    expect(st.applied, contains(step.id));
    expect(st.applied, contains(week.id));
    expect(st.pathOf(w.id('X')), '1');
  });

  test('a whole branch never moves up; sideways or down it may', () async {
    final FoldWorld w = await FoldWorld.make(tree: kNarrow);
    // A1 with X and Y below under S: one level up for all three.
    final PyramidRecord up = await migrate(
      w,
      t0 + day,
      'A1',
      'S',
      branch: true,
      signers: <String>['A1', 'S', 'X', 'Y'],
    );
    final PyramidState st = w.fold(<PyramidRecord>[up]);
    expect(st.rejected[up.id], contains('gałąź'));
    expect(st.pathOf(w.id('A1')), '00');
  });

  test('swaps and free places above: one level, then a week', () async {
    final FoldWorld w = await FoldWorld.make(tree: kNarrow);
    // X and Y make X the head of A1's cell.
    final PyramidRecord first = await w.rec(
      PyrT.swap,
      t0 + day,
      <String>['X', 'Y'],
      <String, dynamic>{'cell': '00', 'head': w.id('A1'), 'up': w.id('X')},
    );
    // A's cell (A, X) at once: too soon.
    Future<PyramidRecord> second(int at) => w.rec(
      PyrT.swap,
      at,
      <String>['X', 'A'],
      <String, dynamic>{'cell': '0', 'head': w.id('A'), 'up': w.id('X')},
    );
    final PyramidRecord soon = await second(t0 + day + h);
    final PyramidRecord later = await second(t0 + day + kPyrRiseCooldownMs);
    final PyramidState st = w.fold(<PyramidRecord>[first, soon, later]);
    expect(st.rejected[soon.id], contains('7 dni'));
    expect(st.pathOf(w.id('X')), '0');
    expect(st.pathOf(w.id('A')), '00');
    expect(st.lastRise[w.id('X')], t0 + day + kPyrRiseCooldownMs);

    // A free place above is taken one level up — and counts as a rise:
    // A1 leaves, X and Y below agree that Y moves up; Y moves up again
    // only a week later.
    final PyramidRecord leave = await w.rec(
      PyrT.leave,
      t0 + 2 * day,
      <String>['A1'],
      <String, dynamic>{'k': w.id('A1')},
    );
    final PyramidRecord fill = await w.rec(
      PyrT.fill,
      t0 + 2 * day + h,
      <String>['X', 'Y'],
      <String, dynamic>{'cell': '00', 'up': w.id('Y')},
    );
    final PyramidRecord upAgain = await w.rec(
      PyrT.swap,
      t0 + 3 * day,
      <String>['Y', 'A'],
      <String, dynamic>{'cell': '0', 'head': w.id('A'), 'up': w.id('Y')},
    );
    final PyramidState st2 = w.fold(<PyramidRecord>[leave, fill, upAgain]);
    expect(st2.applied, contains(fill.id));
    expect(st2.pathOf(w.id('Y')), '00');
    expect(st2.lastRise[w.id('Y')], t0 + 2 * day + h);
    expect(st2.rejected[upAgain.id], contains('7 dni'));
  });

  test('leaving and coming back is no way up', () async {
    final FoldWorld w = await FoldWorld.make(tree: kNarrow);
    final PyramidRecord leave = await w.rec(
      PyrT.leave,
      t0 + day,
      <String>['X'],
      <String, dynamic>{'k': w.id('X')},
    );
    Future<PyramidRecord> admit(int at, String head, String slot) => w.rec(
      PyrT.admit,
      at,
      <String>[head, 'X'],
      <String, dynamic>{
        'sp': w.id(head),
        'head': w.id(head),
        'slot': slot,
        'm': memberData(w['X'], 'X'),
      },
    );
    final PyramidRecord higher = await admit(t0 + 2 * day, 'S', '1');
    final PyramidRecord same = await admit(t0 + 2 * day + 1, 'A1', '000');
    final PyramidState st = w.fold(<PyramidRecord>[leave, higher, same]);
    expect(st.rejected[higher.id], contains('powrót'));
    expect(st.pathOf(w.id('X')), '000');
    expect(st.members[w.id('X')]!.addrs, contains(FoldWorld.addrOf('X')));
  });

  test('no minimum number of people: the highest of a nationality leads its '
      'section', () async {
    final FoldWorld w = await FoldWorld.make(
      nats: const <String, String>{'B1': 'DE', 'Y': 'UA'},
    );
    final PyramidState st = w.fold(const <PyramidRecord>[]);
    expect(st.nationalLead('PL'), w.id('S'));
    expect(st.nationalLead('DE'), w.id('B1'));
    expect(st.nationalLead('UA'), w.id('Y'));
    expect(st.nationalLead('FR'), isNull);
    expect(PyrParams().toJson().containsKey('nationalMin'), isFalse);
  });

  test('the national section is ordered as the pyramid: the higher the '
      'author, the higher the post; pinned on top', () {
    PyrFeedPost post(
      String id, {
      required int level,
      required int at,
      bool priority = false,
      int pinnedAt = -1,
    }) => PyrFeedPost(
      id: id,
      kind: PyrFeedKind.national,
      author: id,
      name: id,
      text: id,
      at: at,
      level: level,
      nat: 'PL',
      priority: priority,
      pinnedAt: pinnedAt,
    );
    final PyramidFeed feed = PyramidFeed(
      member: true,
      nat: 'PL',
      posts: <PyrFeedPost>[
        post('deepNew', level: 5, at: 90),
        post('priorityDeep', level: 4, at: 10, priority: true),
        post('high', level: 1, at: 5),
        post('midOld', level: 3, at: 1),
        post('midNew', level: 3, at: 50),
        post('pinned', level: 7, at: 2, pinnedAt: 3),
      ],
    );
    expect(feed.national.map((PyrFeedPost p) => p.id), <String>[
      'pinned',
      'high',
      'midNew',
      'midOld',
      'priorityDeep',
      'deepNew',
    ]);
  });
}
