import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/core/ledger/ledger_identity.dart';
import 'package:zen/src/features/pyramid/pyramid_record.dart';
import 'package:zen/src/features/pyramid/pyramid_state.dart';

/// The rules of generation 2 ([kPyrRules]), switched on by the genesis (or
/// a constitution): S18 (a rule failing halfway leaves no trace), the
/// quorum from active members and the time-bound full count (§6 pt 11),
/// emission above the limit by referendum (§23.4) — and the new kinds a
/// 1.10.0 phone rejects without folding anything else differently: the
/// national section's pins (§22.2), badges (§20.2a), bans of entries (S36).
const int t0 = 1700000000000;
const int h = 3600 * 1000;
const int day = 24 * h;

Future<PyramidRecord> rec(
  String type,
  String py,
  int at,
  List<LedgerKeyPair> signers,
  Map<String, dynamic> fields,
) async {
  PyramidRecord r = PyramidRecord(
    body: <String, dynamic>{
      't': type,
      'py': py,
      'at': at,
      'by': <String>[for (final LedgerKeyPair k in signers) k.id],
      ...fields,
    },
  );
  for (final LedgerKeyPair k in signers) {
    r = await r.signedBy(k);
  }
  return r;
}

Map<String, dynamic> member(
  LedgerKeyPair k,
  String name, {
  String nat = 'PL',
  String dc = 'x',
}) => <String, dynamic>{'k': k.id, 'n': name, 'nat': nat, 'dc': dc};

const Map<String, String> allScope = <String, String>{
  'k': 'all',
  'p': '',
  'nat': '',
};

/// S on top, A and B under S, A1 and A2 under A, B1 under B; the genesis
/// sets [params] (the rules generation among them).
final class World {
  World._(this.s, this.a, this.b, this.a1, this.a2, this.b1, this.records);

  final LedgerKeyPair s;
  final LedgerKeyPair a;
  final LedgerKeyPair b;
  final LedgerKeyPair a1;
  final LedgerKeyPair a2;
  final LedgerKeyPair b1;
  final List<PyramidRecord> records;

  String get py => records.first.id;

  static Future<World> make({
    int rules = 2,
    Map<String, dynamic> params = const <String, dynamic>{},
    String a1Commit = 'x',
  }) async {
    final List<LedgerKeyPair> k = <LedgerKeyPair>[
      for (int i = 0; i < 6; i++) await LedgerKeyPair.generate(),
    ];
    final PyramidRecord g = await rec(
      PyrT.genesis,
      '',
      t0,
      <LedgerKeyPair>[k[0]],
      <String, dynamic>{
        'name': 'Test',
        'founder': member(k[0], 'S'),
        'params': <String, dynamic>{'rules': rules, ...params},
      },
    );
    final String py = g.id;
    return World._(k[0], k[1], k[2], k[3], k[4], k[5], <PyramidRecord>[
      g,
      await rec(
        PyrT.admit,
        py,
        t0 + 1,
        <LedgerKeyPair>[k[0], k[1]],
        <String, dynamic>{'head': k[0].id, 'm': member(k[1], 'A')},
      ),
      await rec(
        PyrT.admit,
        py,
        t0 + 2,
        <LedgerKeyPair>[k[0], k[2]],
        <String, dynamic>{'head': k[0].id, 'm': member(k[2], 'B')},
      ),
      await rec(
        PyrT.admit,
        py,
        t0 + 3,
        <LedgerKeyPair>[k[1], k[3]],
        <String, dynamic>{
          'head': k[1].id,
          'm': member(k[3], 'A1', dc: a1Commit),
        },
      ),
      await rec(
        PyrT.admit,
        py,
        t0 + 4,
        <LedgerKeyPair>[k[1], k[4]],
        <String, dynamic>{'head': k[1].id, 'm': member(k[4], 'A2')},
      ),
      await rec(
        PyrT.admit,
        py,
        t0 + 5,
        <LedgerKeyPair>[k[2], k[5]],
        <String, dynamic>{'head': k[2].id, 'm': member(k[5], 'B1')},
      ),
    ]);
  }

  PyramidState fold(Iterable<PyramidRecord> more, {int now = t0 + 400 * day}) =>
      PyramidState.fold(py, <PyramidRecord>[...records, ...more], now: now);

  Future<PyramidRecord> referendum(
    int at,
    int end, {
    String kind = 'constitution',
    Map<String, dynamic>? params,
  }) => rec(
    PyrT.referendum,
    py,
    at,
    <LedgerKeyPair>[s, a],
    <String, dynamic>{
      'q': 'Pytanie?',
      'opts': <String>['Tak', 'Nie'],
      'end': end,
      'scope': allScope,
      'kind': kind,
      'params': params ?? <String, dynamic>{'version': 2, 'emitLimit': 5},
    },
  );

  Future<PyramidRecord> tally(
    LedgerKeyPair by,
    int at,
    String ref,
    List<int> counts, {
    List<String> kids = const <String>[],
    bool extra = false,
  }) => rec(
    PyrT.tally,
    py,
    at,
    <LedgerKeyPair>[by],
    <String, dynamic>{
      'ref': ref,
      'counts': counts,
      'kids': kids,
      'extra': extra,
    },
  );

  Future<PyramidRecord> constitution(int at, String ref) => rec(
    PyrT.constitution,
    py,
    at,
    <LedgerKeyPair>[s, a],
    <String, dynamic>{'ref': ref},
  );

  Future<PyramidRecord> alive(LedgerKeyPair k, int at) =>
      rec(PyrT.alive, py, at, <LedgerKeyPair>[k], <String, dynamic>{'k': k.id});

  Future<PyramidRecord> emit(
    int at,
    LedgerKeyPair to,
    int amount, {
    String? ref,
  }) => rec(
    PyrT.emit,
    py,
    at,
    <LedgerKeyPair>[s, a],
    <String, dynamic>{'to': to.id, 'amount': amount, 'why': 'x', 'ref': ?ref},
  );
}

void main() {
  tearDown(() => PyramidState.debugAfterApply = null);

  group('S18: a rule failing halfway', () {
    Future<(World, PyramidRecord, PyramidRecord)> setUpZ(int rules) async {
      final World w = await World.make(rules: rules);
      final LedgerKeyPair z = await LedgerKeyPair.generate();
      // A2 admits Z, and the rule fails after placing Z.
      final PyramidRecord admitZ = await rec(
        PyrT.admit,
        w.py,
        t0 + day,
        <LedgerKeyPair>[w.a2, z],
        <String, dynamic>{'head': w.a2.id, 'm': member(z, 'Z')},
      );
      final PyramidRecord aliveZ = await w.alive(z, t0 + 2 * day);
      PyramidState.debugAfterApply = (PyramidRecord r) {
        if (r.id == admitZ.id) {
          throw StateError('halfway');
        }
      };
      return (w, admitZ, aliveZ);
    }

    test('with rules 2 the record leaves no trace', () async {
      final (World w, PyramidRecord admitZ, PyramidRecord aliveZ) =
          await setUpZ(2);
      final PyramidState st = w.fold(<PyramidRecord>[admitZ, aliveZ]);
      expect(st.rejected[admitZ.id], 'błędny rekord');
      expect(st.members, hasLength(6), reason: 'Z never got in');
      expect(st.occupant.keys, isNot(contains('010')));
      // What follows sees the pyramid without Z.
      expect(st.rejected[aliveZ.id], 'nie członek');
    });

    test(
      'with the old rules the half-done change stays, as in 1.10.0',
      () async {
        final (World w, PyramidRecord admitZ, PyramidRecord aliveZ) =
            await setUpZ(1);
        final PyramidState st = w.fold(<PyramidRecord>[admitZ, aliveZ]);
        expect(st.rejected[admitZ.id], 'błędny rekord');
        // A 1.10.0 phone keeps Z placed: the old fold is kept exactly.
        expect(st.members, hasLength(7));
        expect(st.applied, contains(aliveZ.id));
      },
    );
  });

  group('quorum from the active members (§6 pt 11)', () {
    Future<List<PyramidRecord>> vote(World w, int at, int end) async {
      final PyramidRecord ref = await w.referendum(at, end);
      // A's branch: A1, and S's own vote passed down to A.
      final PyramidRecord tA = await w.tally(w.a, end + 60000, ref.id, <int>[
        2,
        0,
      ], extra: true);
      // B's branch never counts (offline); the top counts without it once
      // the branches had their time: A's sum plus A's own vote.
      final PyramidRecord top = await w.tally(
        w.s,
        end + 7 * h,
        ref.id,
        <int>[3, 0],
        kids: <String>[tA.id],
      );
      final PyramidRecord change = await w.constitution(end + 8 * h, ref.id);
      return <PyramidRecord>[ref, tA, top, change];
    }

    Future<List<PyramidRecord>> onlyThreeAlive(World w, int at) async =>
        <PyramidRecord>[
          await w.alive(w.s, at - 5 * day),
          await w.alive(w.a, at - 5 * day),
          await w.alive(w.a1, at - 5 * day),
        ];

    test('rules 2: half of those seen in the last 60 days is enough', () async {
      final World w = await World.make();
      const int at = t0 + 200 * day;
      const int end = at + 72 * h;
      final List<PyramidRecord> rs = <PyramidRecord>[
        ...await onlyThreeAlive(w, at),
        ...await vote(w, at, end),
      ];
      final PyramidState st = w.fold(rs);
      expect(st.quorumBase(end), 3);
      expect(st.constitutionPasses(rs[3].id), isTrue);
      expect(st.applied, contains(rs.last.id));
      expect(st.params.emitLimit, 5);
    });

    test('rules 1: every place counts, the dead ones too', () async {
      final World w = await World.make(rules: 1);
      const int at = t0 + 200 * day;
      const int end = at + 72 * h;
      final List<PyramidRecord> rs = <PyramidRecord>[
        ...await onlyThreeAlive(w, at),
        ...await vote(w, at, end),
      ];
      final PyramidState st = w.fold(rs);
      expect(st.quorumBase(end), 6);
      expect(st.rejected[rs.last.id], 'referendum nie przeszło');
      expect(st.params.emitLimit, PyrParams().emitLimit);
    });

    test(
      'a constitution can switch the new rules on (the gate for old phones)',
      () async {
        final World w = await World.make(rules: 1);
        const int at = t0 + day;
        const int end = at + 72 * h;
        final PyramidRecord ref = await w.referendum(
          at,
          end,
          params: <String, dynamic>{'rules': 2},
        );
        final PyramidRecord tA = await w.tally(w.a, end + 60000, ref.id, <int>[
          3,
          0,
        ], extra: true);
        final PyramidRecord tB = await w.tally(w.b, end + 60000, ref.id, <int>[
          1,
          0,
        ]);
        final PyramidRecord top = await w.tally(
          w.s,
          end + 7 * h,
          ref.id,
          <int>[6, 0],
          kids: <String>[tA.id, tB.id],
        );
        final PyramidRecord change = await w.constitution(end + 8 * h, ref.id);
        final PyramidState st = w.fold(<PyramidRecord>[
          ref,
          tA,
          tB,
          top,
          change,
        ]);
        expect(st.applied, contains(change.id));
        expect(st.params.rules, 2);
      },
    );
  });

  group('a full count with a time limit (§6 pt 11)', () {
    Future<(List<PyramidRecord>, PyramidRecord)> withLateBranch(World w) async {
      const int at = t0 + day;
      const int end = at + 72 * h;
      final PyramidRecord ref = await w.referendum(at, end);
      final PyramidRecord tA = await w.tally(w.a, end + 60000, ref.id, <int>[
        3,
        0,
      ], extra: true);
      final PyramidRecord top = await w.tally(
        w.s,
        end + 7 * h,
        ref.id,
        <int>[4, 0],
        kids: <String>[tA.id],
      );
      // B's branch sums up only after the top has counted.
      final PyramidRecord lateB = await w.tally(
        w.b,
        end + 7 * h + 60000,
        ref.id,
        <int>[1, 0],
      );
      final PyramidRecord change = await w.constitution(end + 8 * h, ref.id);
      return (<PyramidRecord>[ref, tA, top, lateB, change], change);
    }

    test(
      'rules 2: a branch sum after the top\'s count does not void it',
      () async {
        final World w = await World.make();
        final (List<PyramidRecord> rs, PyramidRecord change) =
            await withLateBranch(w);
        final PyramidState st = w.fold(rs);
        expect(st.resultOf(rs.first.id, strict: true), <int>[4, 0]);
        expect(st.applied, contains(change.id));
      },
    );

    test('rules 1: the late sum still voids the count', () async {
      final World w = await World.make(rules: 1);
      final (List<PyramidRecord> rs, PyramidRecord change) =
          await withLateBranch(w);
      final PyramidState st = w.fold(rs);
      expect(st.resultOf(rs.first.id, strict: true), isNull);
      expect(st.rejected[change.id], 'referendum nie przeszło');
    });
  });

  group('emission above the limit by referendum (§23.4)', () {
    Future<List<PyramidRecord>> passedVote(
      World w,
      int at,
      int end,
      int amount,
    ) async {
      final PyramidRecord ref = await w.referendum(
        at,
        end,
        kind: 'emit',
        params: <String, dynamic>{'to': w.a1.id, 'amount': amount},
      );
      final PyramidRecord tA = await w.tally(w.a, end + 60000, ref.id, <int>[
        3,
        0,
      ], extra: true);
      final PyramidRecord tB = await w.tally(w.b, end + 60000, ref.id, <int>[
        1,
        0,
      ]);
      final PyramidRecord top = await w.tally(
        w.s,
        end + 7 * h,
        ref.id,
        <int>[6, 0],
        kids: <String>[tA.id, tB.id],
      );
      return <PyramidRecord>[ref, tA, tB, top];
    }

    test('a passed referendum allows exactly its emission, once', () async {
      final World w = await World.make();
      final int limit = PyrParams().emitLimit;
      const int at = t0 + day;
      const int end = at + 72 * h;
      final List<PyramidRecord> vote = await passedVote(w, at, end, 3 * limit);
      final String ref = vote.first.id;
      final PyramidRecord withoutRef = await w.emit(
        end + 7 * h,
        w.a1,
        3 * limit,
      );
      final PyramidRecord tooEarly = await w.emit(
        end + h,
        w.a1,
        3 * limit,
        ref: ref,
      );
      final PyramidRecord other = await w.emit(
        end + 7 * h + 1,
        w.a1,
        4 * limit,
        ref: ref,
      );
      final PyramidRecord ok = await w.emit(
        end + 7 * h + 2,
        w.a1,
        3 * limit,
        ref: ref,
      );
      final PyramidRecord again = await w.emit(
        end + 7 * h + 3,
        w.a1,
        3 * limit,
        ref: ref,
      );
      // An ordinary emission still fits the limit: the referendum's money
      // is not counted in it.
      final PyramidRecord normal = await w.emit(end + 7 * h + 4, w.a1, limit);
      final PyramidState st = w.fold(<PyramidRecord>[
        ...vote,
        withoutRef,
        tooEarly,
        other,
        ok,
        again,
        normal,
      ]);
      expect(st.rejected[withoutRef.id], contains('limit'));
      expect(st.rejected[tooEarly.id], contains('za wcześnie'));
      expect(st.rejected[other.id], 'emisja inna niż w referendum');
      expect(st.applied, contains(ok.id));
      expect(st.rejected[again.id], 'to referendum już wykorzystano');
      expect(st.applied, contains(normal.id));
      // It waited its day like any emission.
      expect(st.balanceOf(w.a1.id), 4 * limit);
    });

    test(
      'a short emission vote is refused; rules 1 knows no such vote',
      () async {
        final World w = await World.make();
        const int at = t0 + day;
        final PyramidRecord short = await w.referendum(
          at,
          at + 2 * h,
          kind: 'emit',
          params: <String, dynamic>{'to': w.a1.id, 'amount': 5},
        );
        expect(w.fold(<PyramidRecord>[short]).rejected[short.id], isNotNull);

        final World old = await World.make(rules: 1);
        final int limit = PyrParams().emitLimit;
        const int end = at + 72 * h;
        final List<PyramidRecord> vote = await passedVote(
          old,
          at,
          end,
          3 * limit,
        );
        final PyramidRecord e = await old.emit(
          end + 7 * h + 2,
          old.a1,
          3 * limit,
          ref: vote.first.id,
        );
        final PyramidState st = old.fold(<PyramidRecord>[...vote, e]);
        expect(st.rejected[e.id], contains('limit'));
      },
    );
  });

  group('kinds a 1.10.0 phone does not know', () {
    test('the national lead pins posts; nobody else can', () async {
      final World w = await World.make(
        params: const <String, dynamic>{'nationalMin': 1},
      );
      final PyramidRecord post = await rec(
        PyrT.natPost,
        w.py,
        t0 + day,
        <LedgerKeyPair>[w.s],
        <String, dynamic>{'nat': 'PL', 'text': 'Witajcie', 'lvl': 0},
      );
      final PyramidRecord pinByA = await rec(
        PyrT.natPin,
        w.py,
        t0 + day + 1,
        <LedgerKeyPair>[w.a],
        <String, dynamic>{'nat': 'PL', 'post': post.id, 'on': true},
      );
      final PyramidRecord pin = await rec(
        PyrT.natPin,
        w.py,
        t0 + 3 * day,
        <LedgerKeyPair>[w.s],
        <String, dynamic>{'nat': 'PL', 'post': post.id, 'on': true},
      );
      PyramidState st = w.fold(<PyramidRecord>[post, pinByA, pin]);
      expect(st.nationalLead('PL'), w.s.id);
      expect(st.rejected[pinByA.id], isNotNull);
      expect(st.natPins['PL']!.keys, <String>[post.id]);
      // Not a sign of life: a 1.10.0 phone, which rejects it, agrees on
      // who was seen when.
      expect(st.lastSeen[w.s.id], t0 + day);
      final PyramidRecord unpin = await rec(
        PyrT.natPin,
        w.py,
        t0 + 4 * day,
        <LedgerKeyPair>[w.s],
        <String, dynamic>{'nat': 'PL', 'post': post.id, 'on': false},
      );
      st = w.fold(<PyramidRecord>[post, pin, unpin]);
      expect(st.natPins['PL'], isEmpty);
    });

    test(
      'a badge opens the data confirmed at admission, nothing else',
      () async {
        final String commit = pyrDataCommit(1990, 'k', 'sol');
        final World w = await World.make(a1Commit: commit);
        Future<PyramidRecord> badge(int at, Map<String, dynamic> f) => rec(
          PyrT.badge,
          w.py,
          at,
          <LedgerKeyPair>[w.a1],
          <String, dynamic>{'k': w.a1.id, ...f},
        );
        final PyramidRecord lie = await badge(t0 + day, <String, dynamic>{
          'yr': 2000,
          'g': 'k',
          'salt': 'sol',
        });
        final PyramidRecord truth = await badge(t0 + day + 1, <String, dynamic>{
          'yr': 1990,
          'g': 'k',
          'salt': 'sol',
        });
        PyramidState st = w.fold(<PyramidRecord>[lie, truth]);
        expect(st.rejected[lie.id], contains('odznaka'));
        expect(st.badges[w.a1.id], (birthYear: 1990, gender: 'k'));
        final PyramidRecord off = await badge(t0 + 2 * day, <String, dynamic>{
          'off': true,
        });
        st = w.fold(<PyramidRecord>[truth, off]);
        expect(st.badges, isEmpty);
      },
    );

    test(
      'a content ban names the entry, and keeps the hash for old phones',
      () async {
        final World w = await World.make();
        final PyramidRecord ban = await rec(
          PyrT.ban,
          w.py,
          t0 + day,
          <LedgerKeyPair>[w.s, w.a],
          <String, dynamic>{
            'target': w.b1.id,
            'kind': 'content',
            'hash': 'a' * 64,
            'eid': 'entry-1',
          },
        );
        final PyramidState st = w.fold(<PyramidRecord>[ban]);
        expect(st.bannedEntries(t0 + 2 * day), <String>{'entry-1'});
        expect(st.bannedContent(t0 + 2 * day), <String>{'a' * 64});
      },
    );
  });
}
