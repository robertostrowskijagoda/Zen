import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/core/ledger/log_entry.dart';
import 'package:zen/src/features/feed/feed_model.dart';
import 'package:zen/src/features/ledger/audience_keys.dart';
import 'package:zen/src/features/ledger/bridge_book.dart';
import 'package:zen/src/features/ledger/ledger_node.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';

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

List<String> _texts(LedgerNode node, String account) => <String>[
  for (final FeedPost p in buildFeed(node, nameOf: (String x) => x))
    if (p.account == account) p.text,
];

void main() {
  test('a sealed body opens only with the key and for its account', () async {
    final AudienceKeyring mine = AudienceKeyring()..ensureOwn(1);
    final Map<String, dynamic> sealed = await sealBody(
      <String, dynamic>{'text': 'Tajne'},
      mine.current(Audience.mid),
      account: 'acc-a',
    );
    expect(isSealed(sealed), isTrue);
    expect(sealed.containsKey('text'), isFalse);
    expect(
      await openBody(sealed, mine, account: 'acc-a', self: 'acc-a'),
      <String, dynamic>{'text': 'Tajne'},
    );

    final AudienceKeyring friend = AudienceKeyring()..ensureOwn(1);
    expect(
      await openBody(sealed, friend, account: 'acc-a', self: 'acc-b'),
      isNull,
    );
    friend.acceptFrom('acc-a', <Map<String, dynamic>>[
      for (final AudienceKey k in mine.entitled(FriendLevel.friend)) k.toJson(),
    ]);
    expect(
      await openBody(sealed, friend, account: 'acc-a', self: 'acc-b'),
      isNotNull,
    );
    // The same box claimed by another account does not open.
    friend.acceptFrom('acc-x', <Map<String, dynamic>>[
      for (final AudienceKey k in mine.entitled(FriendLevel.friend)) k.toJson(),
    ]);
    expect(
      await openBody(sealed, friend, account: 'acc-x', self: 'acc-b'),
      isNull,
    );

    // Survives a save and restore.
    final AudienceKeyring restored = AudienceKeyring()
      ..restore(friend.toJson());
    expect(
      await openBody(sealed, restored, account: 'acc-a', self: 'acc-b'),
      isNotNull,
    );
    // A weak friend never gets the "Znajomi i przyjaciele" key.
    expect(
      mine.entitled(FriendLevel.weak).map((AudienceKey k) => k.audience),
      everyElement(Audience.all),
    );
  });

  group('levels on the network', () {
    final String ada = PeerShareCodec.normalizeAddress('200::a');
    final String bob = PeerShareCodec.normalizeAddress('200::b');
    final String cel = PeerShareCodec.normalizeAddress('200::c');
    final String dan = PeerShareCodec.normalizeAddress('200::d');
    late Map<String, _Linked> nodes;
    late List<String> adaFriends;
    late LedgerNode a;
    late LedgerNode b;
    late LedgerNode c;

    Future<LedgerNode> make(String address, List<String> friends) async {
      final _Linked t = nodes[address] = _Linked(address, nodes);
      await t.start();
      final LedgerNode n = LedgerNode(
        transport: t,
        disk: MemoryLedgerDisk(),
        friendAddresses: () => friends,
        bridges: BridgeBook(probe: (String _) async => null),
      );
      addTearDown(n.stop);
      await n.start();
      return n;
    }

    Future<LogEntry> post(String text, Audience audience) async => a.publish(
      kPostKind,
      await a.seal(audience, newPostBody(text, audience: audience)),
    );

    setUp(() async {
      nodes = <String, _Linked>{};
      adaFriends = <String>[bob, cel];
      a = await make(ada, adaFriends);
      b = await make(bob, <String>[ada]);
      c = await make(cel, <String>[ada]);
      await a.setLevel(cel, FriendLevel.weak);
      await _settle();
    });

    test('each level reads only its audiences', () async {
      await post('Dla wszystkich znajomych', Audience.all);
      await post('Dla znajomych i przyjaciół', Audience.mid);
      await post('Tylko przyjaciele', Audience.close);
      await _settle();

      expect(
        _texts(a, a.account),
        containsAll(<String>[
          'Dla wszystkich znajomych',
          'Dla znajomych i przyjaciół',
          'Tylko przyjaciele',
        ]),
      );
      expect(
        _texts(b, a.account),
        unorderedEquals(<String>[
          'Dla wszystkich znajomych',
          'Dla znajomych i przyjaciół',
        ]),
      );
      expect(_texts(c, a.account), <String>['Dla wszystkich znajomych']);
      expect(
        buildFeed(b, nameOf: (String x) => x).first.audience,
        isNot(Audience.public),
      );

      // Promoting Bob opens the close post, even the one written before.
      await a.setLevel(bob, FriendLevel.close);
      await _settle();
      expect(_texts(b, a.account), contains('Tylko przyjaciele'));
    });

    test('going down a level locks out what is written next', () async {
      await post('Stary', Audience.mid);
      await _settle();
      await a.setLevel(bob, FriendLevel.weak);
      await post('Nowy', Audience.mid);
      await _settle();
      expect(_texts(b, a.account), <String>['Stary']);
      expect(a.levelOf(bob), FriendLevel.weak);
    });

    test('a removed friend cannot read new posts', () async {
      await post('Przed', Audience.all);
      await _settle();
      adaFriends.remove(cel);
      await a.onFriendsChanged();
      await post('Po', Audience.all);
      await _settle();
      expect(_texts(c, a.account), <String>['Przed']);
      expect(_texts(b, a.account), unorderedEquals(<String>['Przed', 'Po']));
    });

    test(
      'followers see nothing sealed and sealed posts cannot be reshared',
      () async {
        final LedgerNode d = await make(dan, const <String>[]);
        final LogEntry secret = await post('Nie dla obcych', Audience.all);
        await a.publish(kPostKind, newPostBody('Dla obcych'));
        await d.follow(ada);
        await _settle();
        expect(_texts(d, a.account), <String>['Dla obcych']);
        expect(() => reshareBody(secret), throwsArgumentError);
      },
    );
  });
}
