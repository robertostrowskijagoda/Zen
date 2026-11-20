import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/dev/sim/sim_network.dart';
import 'package:zen/src/features/pyramid/pyramid_record.dart';
import 'package:zen/src/features/pyramid/pyramid_service.dart';
import 'package:zen/src/features/pyramid/pyramid_state.dart';

import 'support/pyramid_world.dart';

/// The close of a cell vote on the phones: each member's app signs what
/// came to it by the end and the clock-skew tolerance, and the close lists
/// the votes most of the ring saw, so members who saw different votes
/// still close it, and a vote that came late to one counts there too.
void main() {
  /// A vote asked for in cell A (A, A1, A2), its ballot of three cards.
  Future<(PyramidWorld, PyrElection)> started() async {
    final PyramidWorld w = await PyramidWorld.six();
    expect(await w['A2'].requestElection('0'), isTrue);
    await w.net.run();
    await w.duties(rounds: 2);
    final PyrElection e = w['A'].state!.elections.values.single;
    expect(e.tokens, hasLength(3));
    return (w, e);
  }

  /// Cuts [who] off from every other phone.
  void isolate(PyramidWorld w, SimPhone who) => w.net.partition(<SimPhone>[
    who,
  ], w.net.phones.where((SimPhone p) => p != who));

  /// The view ([PyrT.voteSeen]) [who] signed for [e].
  List<String> viewOf(PyramidWorld w, String who, PyrElection e) {
    final PyramidService s = w[who];
    for (final String id in s.recordIds) {
      final PyramidRecord r = s.recordOf(id)!;
      if (r.type == PyrT.voteSeen &&
          r.str('elect') == e.id &&
          r.signers.single == s.myKey) {
        return (r.body['votes'] as List).cast<String>();
      }
    }
    fail('$who signed no view');
  }

  test('members who saw different votes still close the vote', () async {
    final (PyramidWorld w, PyrElection e) = await started();
    final PyramidService a1 = w['A1'];
    final PyramidService a2 = w['A2'];
    // A1 votes while A2 is cut off, A2 while A1 is: A has both votes,
    // A1 and A2 one each. Each one's own close (the rule before) differed
    // from the other two, and the vote never closed.
    isolate(w, w.net['A2']);
    expect(await a1.voteInCell(e.id, a1.myKey!), isTrue);
    await w.net.run();
    w.net.heal();
    isolate(w, w.net['A1']);
    expect(await a2.voteInCell(e.id, a1.myKey!), isTrue);
    await w.net.run();
    isolate(w, w.net['A2']);
    expect(w['A'].state!.elections[e.id]!.votes, hasLength(2));
    expect(a1.state!.elections[e.id]!.votes, hasLength(1));
    expect(a2.state!.elections[e.id]!.votes, hasLength(1));
    // The vote ends while A1 and A2 are still cut off: each signs what it
    // saw, then two hours later they are back.
    await w.net.advance(
      Duration(milliseconds: e.deadline + 11 * 60 * 1000 - w.net.now),
    );
    await w.duties(rounds: 1);
    await w.net.advance(const Duration(hours: 2));
    w.net.heal();
    await w.sync();
    await w.duties();
    await w.sync();
    for (final String who in <String>['A', 'A1', 'A2', 'S']) {
      final PyramidState st = w[who].state!;
      expect(st.elections[e.id]!.close, isNotNull, reason: who);
      expect(st.elections[e.id]!.winner, a1.myKey, reason: who);
      expect(st.pathOf(a1.myKey!), '0', reason: who);
      expect(st.voteCheaters, isEmpty, reason: who);
    }
    expect(w.views().values.toSet(), hasLength(1));
  });

  test('a vote that reaches a member within the clock-skew tolerance after '
      'the end is in its view; later, whatever its date, it is not', () async {
    final (PyramidWorld w, PyrElection e) = await started();
    final PyramidService a = w['A'];
    final PyramidService a2 = w['A2'];
    expect(await a.voteInCell(e.id, a2.myKey!), isTrue);
    await w.net.run();
    // A minute before the end A2 votes while A and A1 are cut off.
    await w.net.advance(
      Duration(milliseconds: e.deadline - 60 * 1000 - w.net.now),
    );
    w.net.partition(<SimPhone>[
      w.net['A'],
      w.net['A1'],
    ], w.net.phones.where((SimPhone p) => p != w.net['A'] && p != w.net['A1']));
    expect(await a2.voteInCell(e.id, a2.myKey!), isTrue);
    await w.net.run();
    // A1 gets it five minutes after the end, A fifteen.
    await w.net.advance(
      Duration(milliseconds: e.deadline + 5 * 60 * 1000 - w.net.now),
    );
    w.net.heal();
    isolate(w, w.net['A']);
    await w.sync();
    expect(w['A1'].state!.elections[e.id]!.votes, hasLength(2));
    await w.net.advance(
      Duration(milliseconds: e.deadline + 15 * 60 * 1000 - w.net.now),
    );
    w.net.heal();
    await w.sync();
    await w.duties();
    await w.sync();
    await w.duties();
    final String late = <String>[
      for (final String id in a2.recordIds)
        if (a2.recordOf(id)!.type == PyrT.vote &&
            a2.recordOf(id)!.at > e.deadline - 2 * 60 * 1000)
          id,
    ].single;
    expect(viewOf(w, 'A1', e), contains(late));
    expect(viewOf(w, 'A2', e), contains(late));
    expect(viewOf(w, 'A', e), isNot(contains(late)));
    expect(viewOf(w, 'A', e), hasLength(1));
    // Two of three saw it in time: it counts everywhere.
    for (final String who in <String>['A', 'A1', 'A2']) {
      final PyramidState st = w[who].state!;
      final PyrElection x = st.elections[e.id]!;
      expect(x.close, isNotNull, reason: who);
      expect(x.voteIds.values, contains(late), reason: who);
      expect(st.pathOf(a2.myKey!), '0', reason: who);
    }
  });
}
