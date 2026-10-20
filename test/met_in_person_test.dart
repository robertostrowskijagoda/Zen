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

/// The pyramid key from the account key (A7, §6.1), signed "met in person"
/// attestations (§6.2), "w tym N zweryfikowanych" (§11) and referendum
/// votes only from members met in person by 2 others (§20.6).
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
  'n': name,
  'nat': 'PL',
  'dc': 'x',
};

void main() {
  group('the pyramid key comes from the account key (A7)', () {
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

  group('"met in person" attestations (§6.2)', () {
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

  test('"w tym N zweryfikowanych": likers met in person by a friend '
      '(§11)', () async {
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
  });

  group('referenda only from members met in person by 2 (§20.6)', () {
    late LedgerKeyPair s;
    late LedgerKeyPair a;
    late LedgerKeyPair b;
    late List<PyramidRecord> base;
    late String py;
    late PyramidRecord ref;

    setUp(() async {
      s = await LedgerKeyPair.generate();
      a = await LedgerKeyPair.generate();
      b = await LedgerKeyPair.generate();
      final PyramidRecord g = await _rec(
        PyrT.genesis,
        '',
        t0,
        <LedgerKeyPair>[s],
        <String, dynamic>{'name': 'Test', 'founder': _member(s, 'S')},
      );
      py = g.id;
      base = <PyramidRecord>[
        g,
        await _rec(
          PyrT.admit,
          py,
          t0 + 1,
          <LedgerKeyPair>[s, a],
          <String, dynamic>{'head': s.id, 'm': _member(a, 'A')},
        ),
        await _rec(
          PyrT.admit,
          py,
          t0 + 2,
          <LedgerKeyPair>[s, b],
          <String, dynamic>{'head': s.id, 'm': _member(b, 'B')},
        ),
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
          'kind': 'normal',
        },
      );
    });

    Future<PyramidRecord> met(LedgerKeyPair by, LedgerKeyPair about, int at) =>
        _rec(
          PyrT.met,
          py,
          at,
          <LedgerKeyPair>[by],
          <String, dynamic>{'k': about.id},
        );

    Future<PyramidRecord> tally(List<int> counts, int at) => _rec(
      PyrT.tally,
      py,
      at,
      <LedgerKeyPair>[s],
      <String, dynamic>{
        'ref': ref.id,
        'counts': counts,
        'kids': <String>[],
        'extra': false,
      },
    );

    PyramidState fold(List<PyramidRecord> more) => PyramidState.fold(
      py,
      <PyramidRecord>[...base, ref, ...more],
      now: t0 + 30 * h,
    );

    test('a meeting counts once, between two members', () async {
      final PyramidRecord self = await met(a, a, t0 + 10);
      final PyramidRecord ok = await met(s, a, t0 + 11);
      final PyramidRecord again = await met(s, a, t0 + 12);
      final PyramidState st = fold(<PyramidRecord>[self, ok, again]);
      expect(st.rejected[self.id], 'nie członek');
      expect(st.rejected[again.id], 'już potwierdzone');
      expect(st.metCount(a.id), 1);
      expect(st.metInPerson(a.id), isFalse, reason: 'one is not enough');
      expect(st.eligible(st.referenda[ref.id]!, a.id), isFalse);
      expect(st.inScope(st.referenda[ref.id]!, a.id), isTrue);
    });

    test('nobody met in person: no vote counts; a top cannot sum votes of '
        'members nobody met', () async {
      final PyramidRecord t = await tally(<int>[1, 0], t0 + 3 * h);
      final PyramidState st = fold(<PyramidRecord>[t]);
      expect(st.rejected[t.id], 'zawyżona suma');
      expect(st.quorumBase(t0 + 2 * h), 1);
    });

    test('A met by S and B votes, B met only by S does not', () async {
      final List<PyramidRecord> meetings = <PyramidRecord>[
        await met(s, a, t0 + 10),
        await met(b, a, t0 + 11),
        await met(s, b, t0 + 12),
      ];
      final PyramidRecord two = await tally(<int>[2, 0], t0 + 3 * h);
      final PyramidRecord one = await tally(<int>[1, 0], t0 + 3 * h + 1);
      final PyramidState st = fold(<PyramidRecord>[...meetings, two, one]);
      expect(st.metInPerson(a.id), isTrue);
      expect(st.metInPerson(b.id), isFalse);
      expect(st.eligible(st.referenda[ref.id]!, a.id), isTrue);
      expect(st.rejected[two.id], 'zawyżona suma');
      expect(st.applied, contains(one.id));
      expect(st.resultOf(ref.id), <int>[1, 0]);
      // Turnout is counted from those who may vote.
      expect(st.quorumBase(t0 + 2 * h), 1);
    });
  });
}
