import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/core/ledger/ledger_identity.dart';
import 'package:zen/src/core/ledger/log_entry.dart';
import 'package:zen/src/features/account/account_recovery.dart';
import 'package:zen/src/features/feed/feed_model.dart';
import 'package:zen/src/features/ledger/bridge_book.dart';
import 'package:zen/src/features/ledger/ledger_identity_store.dart';
import 'package:zen/src/features/ledger/ledger_node.dart';
import 'package:zen/src/features/ledger/met_attestation.dart';
import 'package:zen/src/features/pyramid/pyramid_record.dart';
import 'package:zen/src/features/pyramid/pyramid_state.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';

/// The pyramid key from the account key, signed "met in person"
/// attestations, "w tym N zweryfikowanych", and the pyramid's vote: 14
/// days in, or known by somebody of the cell.
final class _Linked extends MemorySignalTransport {
  _Linked(this.address, this.nodes);

  final String address;
  final Map<String, _Linked> nodes;

  @override
  Future<void> send({
    required String remoteAddress,
    required Map<String, dynamic> payload,
  }) async {
    final _Linked? target =
        nodes[PeerShareCodec.normalizeAddress(remoteAddress)];
    if (target != null) {
      scheduleMicrotask(
        () => target.injectIncoming(from: address, payload: payload),
      );
    }
  }
}

Future<void> _settle() async {
  for (int i = 0; i < 40; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

/// Ledger nodes on one simulated mesh; friends as listed.
final class _Mesh {
  final Map<String, _Linked> transports = <String, _Linked>{};
  final Map<String, List<String>> friends = <String, List<String>>{};

  Future<LedgerNode> node(String raw) async {
    final String address = PeerShareCodec.normalizeAddress(raw);
    final _Linked t = transports[address] = _Linked(address, transports);
    await t.start();
    final List<String> mine = friends[address] = <String>[];
    final LedgerNode n = LedgerNode(
      transport: t,
      disk: MemoryLedgerDisk(),
      friendAddresses: () => mine,
      bridges: BridgeBook(probe: (String _) async => null),
    );
    addTearDown(n.stop);
    await n.start();
    return n;
  }

  Future<void> befriend((String, LedgerNode) a, (String, LedgerNode) b) async {
    friends[PeerShareCodec.normalizeAddress(a.$1)]!.add(
      PeerShareCodec.normalizeAddress(b.$1),
    );
    friends[PeerShareCodec.normalizeAddress(b.$1)]!.add(
      PeerShareCodec.normalizeAddress(a.$1),
    );
    await a.$2.onFriendsChanged();
    await b.$2.onFriendsChanged();
    await _settle();
  }
}

const int t0 = 1700000000000;
const int h = 3600 * 1000;

Future<PyramidRecord> _rec(
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

Map<String, dynamic> _member(LedgerKeyPair k, String name) => <String, dynamic>{
  'k': k.id,
  'pq': k.pqId,
  'n': name,
  'nat': 'PL',
  'yr': 1990,
  'dc': 'x',
};

void main() {
  group('the pyramid key comes from the account key', () {
    test('every device of the account, and a recovered one, has the same '
        'pyramid key; a password does not hide it', () async {
      final LedgerKeyPair account = await LedgerKeyPair.generate();
      final MemoryLedgerDisk phone = MemoryLedgerDisk();
      final LedgerIdentity a = await LedgerIdentity.adoptAccount(
        phone,
        account.seed,
      );
      final LedgerIdentity b = await LedgerIdentity.adoptAccount(
        MemoryLedgerDisk(),
        account.seed,
      );
      expect(a.deviceKey.id, isNot(b.deviceKey.id));
      expect(a.pyramidSeed, b.pyramidSeed);
      expect(a.pyramidSeed, isNot(account.seed));
      expect(a.pyramidSeed, isNot(a.selfKey));
      final LedgerKeyPair pyr = await LedgerKeyPair.fromSeed(a.pyramidSeed);
      expect(pyr.id, isNot(account.id));

      await a.setPassword(
        phone,
        'hasło konta',
        cost: const PasswordCost(memoryKiB: 64, iterations: 1),
      );
      final LedgerIdentity? again = await LedgerIdentity.read(phone);
      expect(again!.accountKey, isNull, reason: 'locked by the password');
      expect(again.pyramidSeed, a.pyramidSeed);

      final LedgerKeyPair other = await LedgerKeyPair.generate();
      expect(
        await LedgerIdentity.derivePyramidSeed(other.seed),
        isNot(a.pyramidSeed),
      );
    });
  });

  group('"met in person" attestations', () {
    test('a body says the other account and only the day', () {
      final Map<String, dynamic> body = metBody(
        'x' * 44,
        DateTime.utc(2026, 10, 21, 18, 5).millisecondsSinceEpoch,
      );
      expect(body, <String, dynamic>{'a': 'x' * 44, 'd': '2026-10-21'});
    });

    test('signed into acts, friends get it; a meeting before the friend '
        'request is answered is signed once the account is known', () async {
      final _Mesh mesh = _Mesh();
      final LedgerNode ada = await mesh.node('200::a');
      final LedgerNode bob = await mesh.node('200::b');
      final LedgerNode cela = await mesh.node('200::c');
      await mesh.befriend(('200::a', ada), ('200::b', bob));

      await ada.attestMet('200::b');
      await ada.attestMet('200::b');
      await _settle();
      expect(ada.metAccounts(), <String>{bob.account});
      expect(
        ada
            .entriesOf(spaceKind: 'acts')
            .where((LogEntry e) => e.kind == kMetKind)
            .length,
        1,
        reason: 'once per person',
      );
      expect(ada.hasMet('200::b'), isTrue);
      expect(ada.metAddresses(), <String>[
        PeerShareCodec.normalizeAddress('200::b'),
      ]);
      // Bob keeps Ada's acts: her word that she met him.
      expect(bob.metAccounts(ofAccount: ada.account), <String>{bob.account});
      expect(bob.metByCircle(), contains(bob.account));

      // Cela scanned in person, the request not answered yet.
      await ada.attestMet('200::c');
      expect(ada.hasMet('200::c'), isTrue);
      expect(ada.metAccounts(), isNot(contains(cela.account)));
      await mesh.befriend(('200::a', ada), ('200::c', cela));
      expect(ada.metAccounts(), <String>{bob.account, cela.account});
    });
  });

  test('"w tym N zweryfikowanych": likers met in person by a friend', () async {
    final _Mesh mesh = _Mesh();
    final LedgerNode ada = await mesh.node('200::a');
    final LedgerNode bob = await mesh.node('200::b');
    final LedgerNode cela = await mesh.node('200::c');
    await mesh.befriend(('200::a', ada), ('200::b', bob));
    await mesh.befriend(('200::a', ada), ('200::c', cela));
    await mesh.befriend(('200::b', bob), ('200::c', cela));
    await ada.publish(kPostKind, newPostBody('Polub mnie'));
    await _settle();
    final String postId = buildFeed(bob, nameOf: (_) => 'Ada').single.id;
    await bob.publish(kLikeKind, likeBody(postId), spaceKind: 'acts');
    await cela.publish(kLikeKind, likeBody(postId), spaceKind: 'acts');
    // Bob met Cela; nobody signed meeting Bob.
    await bob.attestMet('200::c');
    await _settle();

    final FeedPost post = buildFeed(
      ada,
      nameOf: (String a) =>
          a == PeerShareCodec.normalizeAddress('200::b') ? 'Bob' : 'Cela',
    ).single;
    expect(post.likeTotal, 2);
    expect(post.verifiedLikes, 1);
    expect(
      post.likes.where((FeedLiker l) => l.verified).single.account,
      cela.account,
    );
    expect(verifiedSummary(post), 'w tym 1 zweryfikowana');

    // A pyramid member counts as verified too ("piramida albo spotkani
    // osobiście").
    final FeedPost withPyramid = buildFeed(
      ada,
      nameOf: (String a) => a,
      pyramidAddresses: <String>{'200::b'},
    ).single;
    expect(withPyramid.verifiedLikes, 2);
    expect(verifiedSummary(withPyramid), 'w tym 2 zweryfikowane');
  });

  group('the vote: 14 days in, or known by somebody of the cell', () {
    late LedgerKeyPair s;
    late LedgerKeyPair a;
    late LedgerKeyPair b;
    late LedgerKeyPair c;
    late List<PyramidRecord> base;
    late String py;
    late PyramidRecord ref;

    setUp(() async {
      s = await LedgerKeyPair.generate();
      a = await LedgerKeyPair.generate();
      b = await LedgerKeyPair.generate();
      c = await LedgerKeyPair.generate();
      final LedgerKeyPair power = await LedgerKeyPair.generate();
      final PyramidRecord g = await _rec(
        PyrT.genesis,
        '',
        t0,
        <LedgerKeyPair>[power],
        <String, dynamic>{'name': 'Test', 'pk': power.id},
      );
      py = g.id;
      Future<PyramidRecord> admit(
        int at,
        LedgerKeyPair sponsor,
        LedgerKeyPair head,
        LedgerKeyPair who,
        String name,
        String slot,
      ) => _rec(
        PyrT.admit,
        py,
        at,
        <LedgerKeyPair>{sponsor, head, who}.toList(),
        <String, dynamic>{
          'sp': sponsor.id,
          'head': head.id,
          'slot': slot,
          'm': _member(who, name),
        },
      );
      base = <PyramidRecord>[
        g,
        await _rec(
          PyrT.found,
          py,
          t0,
          <LedgerKeyPair>[power, s],
          <String, dynamic>{'m': _member(s, 'S')},
        ),
        await admit(t0 + 1, s, s, a, 'A', '0'),
        await admit(t0 + 2, s, s, b, 'B', '1'),
        // "Polecenie": S brings C into A's cell.
        await admit(t0 + 3, s, a, c, 'C', '00'),
      ];
      ref = await _rec(
        PyrT.referendum,
        py,
        t0 + h,
        <LedgerKeyPair>[s, a],
        <String, dynamic>{
          'q': 'Świetlica?',
          'opts': <String>['Tak', 'Nie'],
          'end': t0 + 2 * h,
          'scope': <String, String>{'k': 'all', 'p': '', 'nat': ''},
        },
      );
    });

    Future<PyramidRecord> known(
      LedgerKeyPair by,
      LedgerKeyPair about,
      int at,
    ) => _rec(
      PyrT.known,
      py,
      at,
      <LedgerKeyPair>[by],
      <String, dynamic>{'k': about.id},
    );

    PyramidState fold(List<PyramidRecord> more) => PyramidState.fold(
      py,
      <PyramidRecord>[...base, ref, ...more],
      now: t0 + 30 * h,
    );

    test('the founder votes at once, so does whom a voter admits right under '
        'itself; a newcomer brought to another cell does not', () async {
      final PyramidState st = fold(const <PyramidRecord>[]);
      expect(st.pathOf(c.id), '00');
      expect(st.members[c.id]!.admittedBy, s.id, reason: 'S vouches');
      expect(st.canVote(s.id, t0), isTrue);
      expect(st.canVote(a.id, t0 + 1), isTrue);
      expect(st.knownByOf(a.id), <String>[s.id]);
      expect(st.canVote(c.id, t0 + 3), isFalse);
      expect(st.eligible(st.referenda[ref.id]!, c.id), isFalse);
      expect(st.inScope(st.referenda[ref.id]!, c.id), isTrue);
    });

    test(
      '"poznaliśmy się": only somebody of the cell who votes, once',
      () async {
        final PyramidRecord self = await known(c, c, t0 + 10);
        final PyramidRecord stranger = await known(b, c, t0 + 11);
        final PyramidRecord ok = await known(a, c, t0 + 12);
        final PyramidRecord again = await known(a, c, t0 + 13);
        final PyramidState st = fold(<PyramidRecord>[
          self,
          stranger,
          ok,
          again,
        ]);
        expect(st.rejected[self.id], 'nie członek');
        expect(st.rejected[stranger.id], 'potwierdza ktoś z tej samej komórki');
        expect(st.rejected[again.id], 'już potwierdzone');
        expect(st.knownByOf(c.id), <String>[a.id]);
        expect(st.canVote(c.id, t0 + 12), isTrue);
        expect(st.eligible(st.referenda[ref.id]!, c.id), isTrue);
      },
    );

    test('14 days after joining anybody votes', () {
      final PyramidState st = fold(const <PyramidRecord>[]);
      expect(st.canVote(c.id, t0 + 3 + kPyrVoteAfterMs - 1), isFalse);
      expect(st.canVote(c.id, t0 + 3 + kPyrVoteAfterMs), isTrue);
    });

    test('a swap in the cell counts only those with a vote', () async {
      Future<PyramidRecord> swap(int at) => _rec(
        PyrT.swap,
        py,
        at,
        <LedgerKeyPair>[a, c],
        <String, dynamic>{'cell': '0', 'head': a.id, 'up': c.id},
      );
      final PyramidRecord early = await swap(t0 + 20);
      PyramidState st = fold(<PyramidRecord>[early]);
      expect(
        st.rejected[early.id],
        'potrzeba 2 z 3 w komórce (z prawem głosu)',
      );
      final PyramidRecord later = await swap(t0 + 40);
      st = fold(<PyramidRecord>[early, await known(a, c, t0 + 30), later]);
      expect(st.applied, contains(later.id));
      expect(st.pathOf(c.id), '0');
    });
  });
}
