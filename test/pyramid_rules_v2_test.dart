import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/core/ledger/ledger_identity.dart';
import 'package:zen/src/features/pyramid/pyramid_record.dart';
import 'package:zen/src/features/pyramid/pyramid_state.dart';

/// The fold's rules: a rule failing halfway leaves no trace, advisory
/// referenda asked by the top and the time-bound full count, new rules
/// signed by the top (a day later, within hard limits), the
/// national section's pins, badges, bans of entries.
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
  Object? yr = 1990,
}) => <String, dynamic>{
  'k': k.id,
  'pq': k.pqId,
  'n': name,
  'nat': nat,
  'yr': ?yr,
  'dc': dc,
};

/// [head] admits [who] right under itself, at [slot].
Future<PyramidRecord> admitRec(
  String py,
  int at,
  LedgerKeyPair head,
  LedgerKeyPair who,
  Map<String, dynamic> m,
  String slot,
) => rec(
  PyrT.admit,
  py,
  at,
  <LedgerKeyPair>[head, who],
  <String, dynamic>{'sp': head.id, 'head': head.id, 'slot': slot, 'm': m},
);

const Map<String, String> allScope = <String, String>{
  'k': 'all',
  'p': '',
  'nat': '',
};

/// S on top, A and B under S and A2 under A, B1 under B; the genesis
/// sets [params].
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
    Map<String, dynamic> params = const <String, dynamic>{},
    String a1Commit = 'x',
  }) async {
    final List<LedgerKeyPair> k = <LedgerKeyPair>[
      for (int i = 0; i < 6; i++) await LedgerKeyPair.generate(),
    ];
    final LedgerKeyPair power = await LedgerKeyPair.generate();
    final PyramidRecord g = await rec(
      PyrT.genesis,
      '',
      t0,
      <LedgerKeyPair>[power],
      <String, dynamic>{'name': 'Test', 'pk': power.id, 'params': params},
    );
    final String py = g.id;
    // Each one right under who admits them: all vote at once.
    return World._(k[0], k[1], k[2], k[3], k[4], k[5], <PyramidRecord>[
      g,
      await rec(
        PyrT.found,
        py,
        t0,
        <LedgerKeyPair>[power, k[0]],
        <String, dynamic>{'m': member(k[0], 'S')},
      ),
      await admitRec(py, t0 + 1, k[0], k[1], member(k[1], 'A'), '0'),
      await admitRec(py, t0 + 2, k[0], k[2], member(k[2], 'B'), '1'),
      await admitRec(
        py,
        t0 + 3,
        k[1],
        k[3],
        member(k[3], 'A1', dc: a1Commit),
        '00',
      ),
      await admitRec(py, t0 + 4, k[1], k[4], member(k[4], 'A2'), '01'),
      await admitRec(py, t0 + 5, k[2], k[5], member(k[5], 'B1'), '10'),
    ]);
  }

  PyramidState fold(Iterable<PyramidRecord> more, {int now = t0 + 400 * day}) =>
      PyramidState.fold(py, <PyramidRecord>[...records, ...more], now: now);

  Future<PyramidRecord> referendum(
    int at,
    int end, {
    List<LedgerKeyPair>? by,
    List<String> opts = const <String>['Tak', 'Nie'],
    Map<String, dynamic> extra = const <String, dynamic>{},
  }) => rec(
    PyrT.referendum,
    py,
    at,
    by ?? <LedgerKeyPair>[s, a],
    <String, dynamic>{
      'q': 'Czy budujemy świetlicę?',
      'opts': opts,
      'end': end,
      'scope': allScope,
      ...extra,
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

  Future<PyramidRecord> rules(
    int at,
    Map<String, dynamic> params, {
    List<LedgerKeyPair>? by,
  }) => rec(
    PyrT.constitution,
    py,
    at,
    by ?? <LedgerKeyPair>[s, a],
    <String, dynamic>{'params': params},
  );

  Future<PyramidRecord> alive(LedgerKeyPair k, int at) =>
      rec(PyrT.alive, py, at, <LedgerKeyPair>[k], <String, dynamic>{'k': k.id});

  Future<PyramidRecord> emit(int at, LedgerKeyPair to, int amount) => rec(
    PyrT.emit,
    py,
    at,
    <LedgerKeyPair>[s, a],
    <String, dynamic>{'to': to.id, 'amount': amount, 'why': 'x'},
  );
}

void main() {
  tearDown(() => PyramidState.debugAfterApply = null);

  group('a rule failing halfway', () {
    Future<(World, PyramidRecord, PyramidRecord)> setUpZ() async {
      final World w = await World.make();
      final LedgerKeyPair z = await LedgerKeyPair.generate();
      // A2 admits Z, and the rule fails after placing Z.
      final PyramidRecord admitZ = await admitRec(
        w.py,
        t0 + day,
        w.a2,
        z,
        member(z, 'Z'),
        '010',
      );
      final PyramidRecord aliveZ = await w.alive(z, t0 + 2 * day);
      PyramidState.debugAfterApply = (PyramidRecord r) {
        if (r.id == admitZ.id) {
          throw StateError('halfway');
        }
      };
      return (w, admitZ, aliveZ);
    }

    test('the record leaves no trace', () async {
      final (World w, PyramidRecord admitZ, PyramidRecord aliveZ) =
          await setUpZ();
      final PyramidState st = w.fold(<PyramidRecord>[admitZ, aliveZ]);
      expect(st.rejected[admitZ.id], 'błędny rekord');
      expect(st.members, hasLength(6), reason: 'Z never got in');
      expect(st.occupant.keys, isNot(contains('010')));
      // What follows sees the pyramid without Z.
      expect(st.rejected[aliveZ.id], 'nie członek');
    });
  });

  group('a referendum: any question, asked by the top, advisory', () {
    test(
      'only 2 of 3 of the top ask; 2 to 6 options; at least 2 min',
      () async {
        final World w = await World.make();
        const int at = t0 + day;
        final PyramidRecord ok = await w.referendum(at, at + day);
        final PyramidRecord alone = await w.referendum(
          at + 1,
          at + day,
          by: <LedgerKeyPair>[w.s],
        );
        final PyramidRecord notTop = await w.referendum(
          at + 2,
          at + day,
          by: <LedgerKeyPair>[w.a, w.a1],
        );
        final PyramidRecord one = await w.referendum(
          at + 3,
          at + day,
          opts: <String>['Tak'],
        );
        final PyramidRecord seven = await w.referendum(
          at + 4,
          at + day,
          opts: <String>['1', '2', '3', '4', '5', '6', '7'],
        );
        final PyramidRecord six = await w.referendum(
          at + 5,
          at + day,
          opts: <String>['1', '2', '3', '4', '5', '6'],
        );
        final PyramidRecord short = await w.referendum(at + 6, at + 6 + 60000);
        final PyramidState st = w.fold(<PyramidRecord>[
          ok,
          alone,
          notTop,
          one,
          seven,
          six,
          short,
        ]);
        expect(st.referenda.keys, <String>[ok.id, six.id]);
        expect(st.referenda[ok.id]!.question, 'Czy budujemy świetlicę?');
        for (final PyramidRecord r in <PyramidRecord>[alone, notTop]) {
          expect(st.rejected[r.id], 'referendum ogłasza szczyt (2 z 3)');
        }
        for (final PyramidRecord r in <PyramidRecord>[one, seven, short]) {
          expect(st.rejected[r.id], contains('złe referendum'));
        }
      },
    );

    test('nobody else asks: no delegation for it, no national lead', () async {
      final World w = await World.make();
      const int at = t0 + day;
      final PyramidRecord deleg = await rec(
        PyrT.delegate,
        w.py,
        at,
        <LedgerKeyPair>[w.s, w.a],
        <String, dynamic>{
          'to': w.b1.id,
          'power': 'referendum',
          'scope': '',
          'limit': 0,
          'until': at + 30 * day,
        },
      );
      // S leads the PL section, alone.
      final PyramidRecord byLead = await w.referendum(
        at + 1,
        at + day,
        by: <LedgerKeyPair>[w.s],
        extra: const <String, dynamic>{
          'scope': <String, String>{'k': 'nat', 'p': '', 'nat': 'PL'},
        },
      );
      final PyramidState st = w.fold(<PyramidRecord>[deleg, byLead]);
      expect(st.nationalLead('PL'), w.s.id);
      expect(st.rejected[deleg.id], 'złe uprawnienie');
      expect(st.rejected[byLead.id], 'referendum ogłasza szczyt (2 z 3)');
    });

    test('the result is published and changes nothing by itself', () async {
      final World w = await World.make();
      const int at = t0 + day;
      const int end = at + day;
      // An old-style body: its kind and rules mean nothing now.
      final PyramidRecord ref = await w.referendum(
        at,
        end,
        extra: const <String, dynamic>{
          'kind': 'constitution',
          'params': <String, dynamic>{'emitLimit': 5},
        },
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
        end + 2 * 60000,
        ref.id,
        <int>[6, 0],
        kids: <String>[tA.id, tB.id],
      );
      // Enacting "by the referendum" is no longer a thing.
      final PyramidRecord byRef = await rec(
        PyrT.constitution,
        w.py,
        end + 8 * h,
        <LedgerKeyPair>[w.s, w.a],
        <String, dynamic>{'ref': ref.id},
      );
      final PyramidState st = w.fold(<PyramidRecord>[ref, tA, tB, top, byRef]);
      expect(st.resultOf(ref.id, strict: true), <int>[6, 0]);
      expect(st.rejected[byRef.id], 'złe zasady');
      expect(st.params.emitLimit, PyrParams().emitLimit);
      expect(st.params.version, 1);
    });
  });

  group('a full count with a time limit', () {
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
      return (<PyramidRecord>[ref, tA, top, lateB], lateB);
    }

    test('a branch sum after the top\'s count does not void it', () async {
      final World w = await World.make();
      final (List<PyramidRecord> rs, PyramidRecord lateB) =
          await withLateBranch(w);
      final PyramidState st = w.fold(rs);
      expect(st.applied, contains(lateB.id));
      expect(st.resultOf(rs.first.id, strict: true), <int>[4, 0]);
    });
  });

  group('new rules signed by the top', () {
    test('2 of 3 sign; public at once, applied 24 h later', () async {
      final World w = await World.make();
      const int at = t0 + day;
      final PyramidRecord change = await w.rules(at, <String, dynamic>{
        'absenceDays': 90,
        'electionHours': 48,
        // The version is counted, never signed.
        'version': 9,
      });
      PyramidState st = w.fold(<PyramidRecord>[change], now: at + 23 * h);
      expect(st.applied, contains(change.id));
      expect(st.paramsChanges[change.id]!.effectiveAt, at + kPyrParamsDelayMs);
      expect(st.paramsChanges[change.id]!.done, isFalse);
      expect(st.params.absenceDays, 60);
      expect(st.params.version, 1);
      st = w.fold(<PyramidRecord>[change], now: at + kPyrParamsDelayMs);
      expect(st.paramsChanges[change.id]!.done, isTrue);
      expect(st.params.absenceDays, 90);
      expect(st.params.electionHours, 48);
      expect(st.params.immunityDepth, 3, reason: 'the rest stays');
      expect(st.params.version, 2);
      expect(
        st.history.where((PyrHistory x) => x.recordId == change.id),
        hasLength(1),
      );
    });

    test('nobody but 2 of the top; nothing to change is refused', () async {
      final World w = await World.make();
      const int at = t0 + day;
      final PyramidRecord alone = await w.rules(
        at,
        <String, dynamic>{'absenceDays': 30},
        by: <LedgerKeyPair>[w.s],
      );
      final PyramidRecord notTop = await w.rules(
        at + 1,
        <String, dynamic>{'absenceDays': 30},
        by: <LedgerKeyPair>[w.a, w.a1, w.a2],
      );
      final PyramidRecord empty = await w.rules(at + 2, const <String, dynamic>{
        'absenceDays': 'trzydzieści',
      });
      final PyramidState st = w.fold(<PyramidRecord>[alone, notTop, empty]);
      expect(st.rejected[alone.id], 'zasady zmienia szczyt (2 z 3)');
      expect(st.rejected[notTop.id], 'zasady zmienia szczyt (2 z 3)');
      expect(st.rejected[empty.id], 'złe zasady');
      expect(st.params.absenceDays, 60);
      expect(st.paramsChanges, isEmpty);
    });

    test('the hard limits in code hold whatever the top signs', () async {
      final World w = await World.make();
      const int at = t0 + day;
      final PyramidRecord low = await w.rules(at, const <String, dynamic>{
        'absenceDays': 1,
        'immunityDepth': -5,
        'treasurerDepth': 0,
        'electionHours': 0,
        'reportEscalateHours': 0,
      });
      PyramidState st = w.fold(<PyramidRecord>[low]);
      // Sane floors: a month away, the top immune, the top three levels
      // treasurers, a day to vote and to escalate.
      expect(st.params.absenceDays, 30);
      expect(st.params.immunityDepth, 1);
      expect(st.params.treasurerDepth, 3);
      expect(st.params.electionHours, 24);
      expect(st.params.reportEscalateHours, 24);
      final PyramidRecord high = await w.rules(at, const <String, dynamic>{
        'absenceDays': 99999,
        'treasurerDepth': 99,
      });
      st = w.fold(<PyramidRecord>[high]);
      expect(st.params.absenceDays, 3650);
      expect(st.params.treasurerDepth, 6);
    });

    test('the emission limit is not among the rules the top changes in a '
        'day', () async {
      final World w = await World.make();
      const int at = t0 + day;
      final PyramidRecord limit = await w.rules(at, const <String, dynamic>{
        'emitLimit': kPyrMaxAmount,
      });
      final PyramidRecord delay = await w.rules(at + 1, const <String, dynamic>{
        'emitDelayHours': 1,
        'absenceDays': 90,
      });
      final PyramidState st = w.fold(<PyramidRecord>[limit, delay]);
      for (final PyramidRecord r in <PyramidRecord>[limit, delay]) {
        expect(st.rejected[r.id], contains('limit emisji'));
      }
      expect(st.params.emitLimit, PyrParams().emitLimit);
      expect(st.params.emitDelayHours, 24);
      expect(st.params.absenceDays, 60, reason: 'nothing of it applies');
    });

    test('no emission above the limit; a raise of the limit applies 30 days '
        'after it is announced', () async {
      final World w = await World.make();
      final int limit = PyrParams().emitLimit;
      const int at = t0 + day;
      final PyramidRecord raise = await rec(
        PyrT.emitRule,
        w.py,
        at,
        <LedgerKeyPair>[w.s, w.a],
        <String, dynamic>{'limit': 5 * limit},
      );
      final PyramidRecord tooSoon = await w.emit(at + h, w.a1, 3 * limit);
      // An old "by referendum" field allows nothing.
      final PyramidRecord byRef = await rec(
        PyrT.emit,
        w.py,
        at + 2 * h,
        <LedgerKeyPair>[w.s, w.a],
        <String, dynamic>{
          'to': w.a1.id,
          'amount': 3 * limit,
          'why': 'x',
          'ref': 'r1',
        },
      );
      final PyramidRecord stillSoon = await w.emit(
        at + 29 * day,
        w.a1,
        3 * limit,
      );
      final PyramidRecord later = await w.emit(
        at + 30 * day + h,
        w.a1,
        3 * limit,
      );
      final PyramidState st = w.fold(<PyramidRecord>[
        raise,
        tooSoon,
        byRef,
        stillSoon,
        later,
      ]);
      expect(st.rejected[tooSoon.id], contains('limit'));
      expect(st.rejected[byRef.id], contains('limit'));
      expect(st.rejected[stillSoon.id], contains('limit'));
      expect(st.applied, contains(later.id));
      expect(st.balanceOf(w.a1.id), 3 * limit);
    });
  });

  group('the birth year at entry', () {
    test('required and plausible; minors are admitted; the year is public '
        'in the member data', () async {
      final World w = await World.make();
      Future<PyramidRecord> admit(int at, LedgerKeyPair z, Object? yr) =>
          admitRec(w.py, at, w.a2, z, member(z, 'Z', yr: yr), '010');
      final LedgerKeyPair z = await LedgerKeyPair.generate();
      final PyramidRecord none = await admit(t0 + day, z, null);
      final PyramidRecord zero = await admit(t0 + day + 1, z, 0);
      final PyramidRecord old = await admit(t0 + day + 2, z, 1850);
      final PyramidRecord future = await admit(t0 + day + 3, z, 2100);
      final PyramidRecord text = await admit(t0 + day + 4, z, '2010');
      // Born the year before: a child, admitted all the same.
      final PyramidRecord child = await admit(t0 + day + 5, z, 2022);
      final PyramidState st = w.fold(<PyramidRecord>[
        none,
        zero,
        old,
        future,
        text,
        child,
      ]);
      for (final PyramidRecord r in <PyramidRecord>[
        none,
        zero,
        old,
        future,
        text,
      ]) {
        expect(st.rejected[r.id], contains('rok urodzenia'));
      }
      expect(st.applied, contains(child.id));
      expect(st.members[z.id]!.birthYear, 2022);
      expect(pyrAge(2022, t0 + day), 1);
    });
  });

  group('national pins, badges, entry bans', () {
    test('the national lead pins posts; nobody else can', () async {
      final World w = await World.make();
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
      expect(st.lastSeen[w.s.id], t0 + 3 * day);
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

    test('a gender badge opens the data confirmed at admission, nothing '
        'else', () async {
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
        'g': 'm',
        'salt': 'sol',
      });
      final PyramidRecord truth = await badge(t0 + day + 1, <String, dynamic>{
        'g': 'k',
        'salt': 'sol',
      });
      PyramidState st = w.fold(<PyramidRecord>[lie, truth]);
      expect(st.rejected[lie.id], contains('odznaka'));
      expect(st.badges[w.a1.id], 'k');
      // The age needs no badge: the confirmed year is in the member data.
      expect(st.members[w.a1.id]!.birthYear, 1990);
      final PyramidRecord off = await badge(t0 + 2 * day, <String, dynamic>{
        'off': true,
      });
      st = w.fold(<PyramidRecord>[truth, off]);
      expect(st.badges, isEmpty);
    });

    test('a content ban names the entry', () async {
      final World w = await World.make();
      final PyramidRecord ban = await rec(
        PyrT.ban,
        w.py,
        t0 + day,
        <LedgerKeyPair>[w.s, w.a],
        <String, dynamic>{
          'target': w.b1.id,
          'kind': 'content',
          'eid': 'entry-1',
        },
      );
      final PyramidState st = w.fold(<PyramidRecord>[ban]);
      expect(st.bannedEntries(t0 + 2 * day), <String>{'entry-1'});
    });
  });
}
