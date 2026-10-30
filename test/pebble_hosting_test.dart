import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/core/ledger/ledger_codec.dart';
import 'package:zen/src/core/ledger/ledger_identity.dart';
import 'package:zen/src/domain/friends/friend_profile.dart';
import 'package:zen/src/features/pebbles/pebble_card.dart';
import 'package:zen/src/features/pebbles/pebble_hosting.dart';
import 'package:zen/src/features/pebbles/pebble_store.dart';
import 'package:zen/src/features/runtime/runtime_signal_parser.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';

import 'support/friends_world.dart';

// The pebbles' hosting protocol between simulated friends: keepers drawn
// and asked, the design found when the author is away, collectors serving
// copies, blocked people left out, and an older Zen that knows nothing of
// pebbles taking their frames in its stride.

const PebbleCardLook _look = PebbleCardLook(
  shape: 2,
  seed: 42,
  material: 1,
  mainColour: 0xAA3322,
  secondColour: 0x112233,
);

/// What a phone of the world knows of the people around it: friends from
/// its own friend list, accounts of friends only (as its ledger would).
final class _Peers implements PebblePeers {
  _Peers(this.net, this.phone);

  final _Net net;
  final FriendsPhone phone;

  /// Restricts the keepers the phone may draw (null: every friend).
  List<String>? candidates;

  /// How well each friend's device answers (0.5 when not set).
  final Map<String, double> quality = <String, double>{};

  FriendProfile? _profile(String address) =>
      phone.state.friendByAddress(address);

  @override
  List<String> friends() => <String>[
    for (final FriendProfile f in phone.state.acceptedFriends) f.address,
  ];

  @override
  bool isFriend(String address) =>
      _profile(address)?.status == FriendRelationshipStatus.accepted;

  @override
  bool isBlocked(String address) =>
      _profile(address)?.status == FriendRelationshipStatus.blocked;

  @override
  String? accountOf(String address) =>
      isFriend(address) ? net.accountAt(address) : null;

  @override
  List<String> addressesOfAccount(String account) {
    final FriendsPhone? owner = net.phoneOf(account);
    return owner != null && isFriend(owner.address)
        ? <String>[owner.address]
        : const <String>[];
  }

  @override
  List<PebbleKeeperCandidate> keeperCandidates() => <PebbleKeeperCandidate>[
    for (final String f in friends())
      if (candidates == null ||
          candidates!.contains(PeerShareCodec.normalizeAddress(f)))
        PebbleKeeperCandidate(
          address: f,
          desktop:
              net.world.phones
                  .firstWhere((FriendsPhone p) => p.address == f)
                  .device ==
              SimDevice.desktop,
          quality: quality[PeerShareCodec.normalizeAddress(f)] ?? 0.5,
        ),
  ];
}

/// The pebbles of every phone of a world.
final class _Net {
  _Net(this.world, {this.keeperTarget = 3});

  final FriendsWorld world;
  final int keeperTarget;
  final Map<FriendsPhone, LedgerKeyPair> keys = <FriendsPhone, LedgerKeyPair>{};
  final Map<FriendsPhone, PebbleHosting> hosts =
      <FriendsPhone, PebbleHosting>{};
  final Map<FriendsPhone, _Peers> peers = <FriendsPhone, _Peers>{};

  /// Whether a phone serves what it collected (the settings' switch).
  final Map<FriendsPhone, bool> serves = <FriendsPhone, bool>{};

  /// Whether a phone's person agrees to keep pebbles (null: never answers).
  final Map<FriendsPhone, bool?> agrees = <FriendsPhone, bool?>{};

  static Future<_Net> of(FriendsWorld world, {int keeperTarget = 3}) async {
    final _Net net = _Net(world, keeperTarget: keeperTarget);
    for (final FriendsPhone p in world.phones) {
      await net._add(p);
    }
    return net;
  }

  Future<void> _add(FriendsPhone p) async {
    keys[p] = await LedgerKeyPair.generate();
    final _Peers pp = peers[p] = _Peers(this, p);
    final PebbleHosting h = hosts[p] = PebbleHosting(
      transport: p.appTransport,
      store: PebbleStore(MemoryLedgerDisk(), clock: () => world.now),
      peers: pp,
      accountKey: () => keys[p],
      serveCollected: () => serves[p] ?? true,
      clock: () => world.now,
      keeperTarget: keeperTarget,
      askTimeout: const Duration(hours: 1),
      askAgainAfter: const Duration(minutes: 5),
      random: Random(1),
    );
    h.onKeepRequest = (PebbleKeepRequest r) {
      if (agrees.containsKey(p) && agrees[p] == null) {
        return;
      }
      final bool yes = agrees[p] ?? true;
      // The person answers the notification a moment later.
      Future<void>.microtask(
        () => yes ? h.acceptKeep(r.card.id) : h.declineKeep(r.card.id),
      );
    };
    await h.start();
  }

  String? accountAt(String address) {
    for (final MapEntry<FriendsPhone, LedgerKeyPair> e in keys.entries) {
      if (e.key.address == PeerShareCodec.normalizeAddress(address)) {
        return e.value.id;
      }
    }
    return null;
  }

  FriendsPhone? phoneOf(String account) {
    for (final MapEntry<FriendsPhone, LedgerKeyPair> e in keys.entries) {
      if (e.value.id == account) {
        return e.key;
      }
    }
    return null;
  }

  PebbleStore store(FriendsPhone p) => hosts[p]!.store;

  /// Lets every frame land and every phone's pebble work finish.
  Future<void> settle() async {
    for (int i = 0; i < 40; i++) {
      final int before = world.net.stats.sent;
      await world.settle();
      for (final PebbleHosting h in hosts.values) {
        await h.idle;
      }
      await world.settle();
      if (world.net.stats.sent == before) {
        return;
      }
    }
  }

  /// One wake beat on every phone that is on.
  Future<void> beat() async {
    for (final MapEntry<FriendsPhone, PebbleHosting> e in hosts.entries) {
      if (e.key.online) {
        await e.value.tick();
      }
    }
    await settle();
  }

  /// Beats while time passes, until [done] holds (fails after [within]).
  Future<void> until(
    bool Function() done, {
    Duration within = const Duration(minutes: 30),
    String reason = 'the condition',
  }) async {
    final int end = world.now + within.inMilliseconds;
    while (!done()) {
      if (world.now >= end) {
        fail('$reason did not happen within $within');
      }
      await world.advance(const Duration(seconds: 30));
      await beat();
    }
  }

  /// [author] makes and publishes a pebble (keepers drawn at once).
  Future<PebbleCard> publish(FriendsPhone author, {int size = 3000}) async {
    final Uint8List design = Uint8List.fromList(
      List<int>.generate(
        size,
        (int i) => (i * 13 + author.name.hashCode) & 0xFF,
      ),
    );
    final PebbleCard card = await PebbleCard.sign(
      key: keys[author]!,
      design: design,
      createdSeconds: world.now ~/ 1000,
      look: _look,
      name: 'Kamyk ${author.name}',
      note: 'przy ławce',
      authorName: author.name,
    );
    await hosts[author]!.publish(card, design);
    await settle();
    return card;
  }

  /// [finder] scans the card: saved at once, the design looked for.
  Future<void> collect(
    FriendsPhone finder,
    PebbleCard card, {
    List<String> hinted = const <String>[],
  }) async {
    await store(finder).addCollected(card, findNote: 'w parku', hinted: hinted);
    await hosts[finder]!.want(card.id);
    await settle();
  }

  bool hasDesign(FriendsPhone p, PebbleCard card) =>
      store(p).entry(card.id)?.hasDesign ?? false;

  List<FriendsPhone> acceptedKeepers(FriendsPhone author, PebbleCard card) =>
      <FriendsPhone>[
        for (final PebbleKeeperStatus k in store(author).keepersOf(card.id))
          if (k.state == PebbleKeeperState.accepted)
            world.phones.firstWhere((FriendsPhone p) => p.address == k.address),
      ];
}

Future<FriendsWorld> _world(
  List<String> names,
  List<(String, String)> friendships,
) async {
  final FriendsWorld w = await FriendsWorld.create(names, allFriends: false);
  for (final (String a, String b) in friendships) {
    await w.befriend(w[a], w[b]);
  }
  await w.settleMailboxes();
  return w;
}

void main() {
  test(
    'keepers are drawn, asked and serve; the signed list reaches them',
    () async {
      final FriendsWorld w = await FriendsWorld.create(
        <String>['A', 'B', 'C', 'D', 'E'],
        devices: <String, SimDevice>{'C': SimDevice.desktop},
      );
      final _Net net = await _Net.of(w);
      final PebbleCard card = await net.publish(w['A']);
      await net.until(
        () => net.acceptedKeepers(w['A'], card).length == 3,
        reason: 'three keepers agreeing',
      );
      final List<FriendsPhone> keepers = net.acceptedKeepers(w['A'], card);
      expect(keepers, contains(w['C']), reason: 'a computer comes first');
      await net.until(
        () => keepers.every(
          (FriendsPhone k) =>
              net.hasDesign(k, card) &&
              (net.store(k).entry(card.id)?.keepers?.keepers.length ?? 0) == 3,
        ),
        reason: 'every keeper holding the design and the list',
      );
      for (final FriendsPhone k in keepers) {
        final PebbleEntry e = net.store(k).entry(card.id)!;
        expect(e.kept, isTrue);
        expect(await e.keepers!.verifyFor(card), isTrue);
      }
    },
  );

  test('a friend who says no is replaced by another', () async {
    final FriendsWorld w = await FriendsWorld.create(<String>[
      'A',
      'B',
      'C',
      'D',
      'E',
    ]);
    final _Net net = await _Net.of(w, keeperTarget: 2);
    // B and C are asked first, and say no.
    net.peers[w['A']]!.quality
      ..[w['B'].address] = 0.9
      ..[w['C'].address] = 0.9
      ..[w['D'].address] = 0.2
      ..[w['E'].address] = 0.2;
    net.agrees[w['B']] = false;
    net.agrees[w['C']] = false;
    final PebbleCard card = await net.publish(w['A']);
    await net.until(
      () => net.acceptedKeepers(w['A'], card).length == 2,
      reason: 'two keepers agreeing after refusals',
    );
    final PebbleStore a = net.store(w['A']);
    expect(
      net.acceptedKeepers(w['A'], card),
      unorderedEquals(<FriendsPhone>[w['D'], w['E']]),
    );
    expect(
      a.keeperStatus(card.id, w['B'].address)?.state,
      PebbleKeeperState.declined,
    );
    expect(
      a.keeperStatus(card.id, w['C'].address)?.state,
      PebbleKeeperState.declined,
    );
  });

  test('a keeper who never answers is replaced after a while', () async {
    final FriendsWorld w = await FriendsWorld.create(<String>['A', 'B', 'C']);
    final _Net net = await _Net.of(w, keeperTarget: 1);
    net.peers[w['A']]!.candidates = <String>[w['B'].address, w['C'].address];
    net.agrees[w['B']] = null;
    net.agrees[w['C']] = null;
    final PebbleCard card = await net.publish(w['A']);
    final PebbleStore a = net.store(w['A']);
    final String first = a.keepersOf(card.id).single.address;
    net.agrees[w['B']] = true;
    net.agrees[w['C']] = true;
    // The first one asked stays silent: their app never answers.
    final FriendsPhone silent = w.phones.firstWhere(
      (FriendsPhone p) => p.address == first,
    );
    await w.setOnline(silent, false);
    await net.until(
      () => net.acceptedKeepers(w['A'], card).length == 1,
      within: const Duration(hours: 2),
      reason: 'a replacement for the silent keeper',
    );
    expect(a.keeperStatus(card.id, first)?.state, PebbleKeeperState.silent);
  });

  test('a keeper resigning is replaced', () async {
    final FriendsWorld w = await FriendsWorld.create(<String>[
      'A',
      'B',
      'C',
      'D',
    ]);
    final _Net net = await _Net.of(w, keeperTarget: 2);
    final PebbleCard card = await net.publish(w['A']);
    await net.until(() => net.acceptedKeepers(w['A'], card).length == 2);
    final FriendsPhone quitter = net.acceptedKeepers(w['A'], card).first;
    await net.hosts[quitter]!.resign(card.id);
    await net.settle();
    expect(net.store(quitter).entry(card.id), isNull);
    await net.until(
      () =>
          net.acceptedKeepers(w['A'], card).length == 2 &&
          !net.acceptedKeepers(w['A'], card).contains(quitter),
      reason: 'a new keeper in place of the one who resigned',
    );
    expect(
      net.store(w['A']).keeperStatus(card.id, quitter.address)?.state,
      PebbleKeeperState.resigned,
    );
  });

  test('the author offline: a keeper serves, found through a friend', () async {
    // F knows only E; E is the author's friend; B and C keep the pebble
    // and are E's friends, not F's.
    final FriendsWorld w = await _world(
      <String>['A', 'B', 'C', 'E', 'F'],
      <(String, String)>[
        ('A', 'B'),
        ('A', 'C'),
        ('A', 'E'),
        ('E', 'B'),
        ('E', 'C'),
        ('E', 'F'),
      ],
    );
    final _Net net = await _Net.of(w, keeperTarget: 2);
    net.peers[w['A']]!.candidates = <String>[w['B'].address, w['C'].address];
    final PebbleCard card = await net.publish(w['A']);
    await net.until(() => net.acceptedKeepers(w['A'], card).length == 2);
    await net.until(
      () => net.hasDesign(w['B'], card) && net.hasDesign(w['C'], card),
    );
    await w.setOnline(w['A'], false);
    await net.collect(w['F'], card);
    await net.until(
      () => net.hasDesign(w['F'], card),
      reason: 'the design reaching F from a keeper',
    );
    final Uint8List? design = await net.store(w['F']).design(card.id);
    expect(card.matchesDesign(design!), isTrue);
    expect(net.store(w['F']).entry(card.id)!.keepers?.keepers, hasLength(2));
  });

  test('a finder who knows nobody gets the design from a keeper the QR '
      'code named, the author offline', () async {
    final FriendsWorld w = await _world(
      <String>['A', 'B', 'F'],
      <(String, String)>[('A', 'B')],
    );
    final _Net net = await _Net.of(w, keeperTarget: 1);
    net.peers[w['A']]!.candidates = <String>[w['B'].address];
    final PebbleCard card = await net.publish(w['A']);
    await net.until(() => net.hasDesign(w['B'], card));
    await w.setOnline(w['A'], false);
    await net.collect(w['F'], card.qrCard, hinted: <String>[w['B'].address]);
    await net.until(
      () => net.hasDesign(w['F'], card),
      reason: 'the design reaching F from the keeper in the code',
    );
    expect(net.store(w['F']).entry(card.id)!.card, card);
  });

  test('the author back: the design is asked of them at their first word, '
      'not at the next round hours later', () async {
    final FriendsWorld w = await _world(
      <String>['A', 'B'],
      <(String, String)>[('A', 'B')],
    );
    final _Net net = await _Net.of(w, keeperTarget: 1);
    net.peers[w['A']]!.candidates = <String>[];
    final PebbleCard card = await net.publish(w['A']);
    await w.setOnline(w['A'], false);
    await net.collect(w['B'], card);
    // Two rounds pass while the author's app is closed.
    for (int i = 0; i < 8; i++) {
      await w.advance(const Duration(minutes: 1));
      await net.beat();
    }
    expect(net.hasDesign(w['B'], card), isFalse);
    await w.setOnline(w['A'], true);
    await w.settleMailboxes();
    await net.settle();
    // Any word from the author (here a status) brings the question.
    await w['A'].appTransport.send(
      remoteAddress: w['B'].address,
      payload: <String, dynamic>{'type': 'presence'},
    );
    await net.settle();
    expect(net.hasDesign(w['B'], card), isTrue);
  });

  test('a pebble published with no friends asks the first friends who '
      'come, without a press of "Losuj ponownie"', () async {
    final FriendsWorld w = await _world(<String>['A', 'B', 'C'], const []);
    final _Net net = await _Net.of(w, keeperTarget: 2);
    final PebbleCard card = await net.publish(w['A']);
    final PebbleHosting a = net.hosts[w['A']]!;
    expect(net.store(w['A']).keepersOf(card.id), isEmpty);
    expect(a.hasFriends, isFalse);
    expect(a.freshKeeperCandidates(card.id), 0);
    // Nobody to ask: pressing it changes nothing and says so.
    expect(await a.redraw(card.id), 0);
    await w.befriend(w['A'], w['B']);
    await w.befriend(w['A'], w['C']);
    await w.settleMailboxes();
    expect(a.freshKeeperCandidates(card.id), 2);
    // The app calls this as friends come; the beat would do it as well.
    await a.drawShort();
    await net.settle();
    await net.until(
      () => net.acceptedKeepers(w['A'], card).length == 2,
      reason: 'the new friends keeping the pebble',
    );
  });

  test('the beat asks friends who came after publishing', () async {
    final FriendsWorld w = await _world(<String>['A', 'B'], const []);
    final _Net net = await _Net.of(w, keeperTarget: 2);
    final PebbleCard card = await net.publish(w['A']);
    await w.befriend(w['A'], w['B']);
    await w.settleMailboxes();
    await net.until(
      () => net.acceptedKeepers(w['A'], card).length == 1,
      reason: 'the new friend asked on the beat',
    );
  });

  test('"Losuj ponownie" with nobody new keeps those still asked', () async {
    final FriendsWorld w = await _world(
      <String>['A', 'B', 'C'],
      const <(String, String)>[('A', 'B'), ('A', 'C')],
    );
    final _Net net = await _Net.of(w, keeperTarget: 3);
    net.agrees[w['B']] = null;
    net.agrees[w['C']] = null;
    final PebbleCard card = await net.publish(w['A']);
    final PebbleHosting a = net.hosts[w['A']]!;
    expect(a.freshKeeperCandidates(card.id), 0);
    expect(await a.redraw(card.id), 0);
    expect(
      net
          .store(w['A'])
          .keepersOf(card.id)
          .map((PebbleKeeperStatus k) => k.state),
      everyElement(PebbleKeeperState.asked),
    );
  });

  test('a keeper the author removed as a friend still serves', () async {
    final FriendsWorld w = await _world(
      <String>['A', 'B', 'E', 'F'],
      <(String, String)>[('A', 'B'), ('A', 'E'), ('E', 'B'), ('E', 'F')],
    );
    final _Net net = await _Net.of(w, keeperTarget: 1);
    net.peers[w['A']]!.candidates = <String>[w['B'].address];
    final PebbleCard card = await net.publish(w['A']);
    await net.until(() => net.hasDesign(w['B'], card));
    await w['A'].hub.removeFriend(peerAddress: w['B'].address);
    await net.settle();
    expect(
      w['A'].state.friendByAddress(w['B'].address)?.status,
      isNot(FriendRelationshipStatus.accepted),
    );
    await net.beat();
    // The role belongs to the pebble, not to the friendship.
    expect(net.acceptedKeepers(w['A'], card), <FriendsPhone>[w['B']]);
    expect(net.store(w['B']).entry(card.id)!.kept, isTrue);
    await w.setOnline(w['A'], false);
    await net.collect(w['F'], card);
    await net.until(
      () => net.hasDesign(w['F'], card),
      reason: 'the removed friend serving the design',
    );
  });

  test(
    'every keeper gone: a collector serves; one who opted out does not',
    () async {
      final FriendsWorld w = await _world(
        <String>['A', 'B', 'C', 'D', 'F'],
        <(String, String)>[('A', 'B'), ('A', 'C'), ('C', 'F'), ('D', 'F')],
      );
      final _Net net = await _Net.of(w, keeperTarget: 1);
      net.peers[w['A']]!.candidates = <String>[w['B'].address];
      final PebbleCard card = await net.publish(w['A']);
      await net.until(() => net.hasDesign(w['B'], card));
      // C collects it from the author.
      await net.collect(w['C'], card);
      await net.until(() => net.hasDesign(w['C'], card));
      expect(net.store(w['C']).entry(card.id)!.collected, isTrue);
      await w.setOnline(w['A'], false);
      await w.setOnline(w['B'], false);
      // C opted out: F gets nothing.
      net.serves[w['C']] = false;
      await net.collect(w['F'], card);
      await w.advance(const Duration(minutes: 3));
      await net.beat();
      expect(net.hasDesign(w['F'], card), isFalse);
      expect(
        net.store(w['F']).entry(card.id)!.collected,
        isTrue,
        reason: 'saved from the card at once',
      );
      // C serves again.
      net.serves[w['C']] = true;
      await net.until(
        () => net.hasDesign(w['F'], card),
        reason: 'a collector serving the design',
      );
    },
  );

  test('blocked people neither fetch from nor serve to each other', () async {
    final FriendsWorld w = await _world(
      <String>['A', 'B', 'F'],
      <(String, String)>[('A', 'B'), ('B', 'F'), ('A', 'F')],
    );
    final _Net net = await _Net.of(w, keeperTarget: 1);
    net.peers[w['A']]!.candidates = <String>[w['B'].address];
    final PebbleCard card = await net.publish(w['A']);
    await net.until(() => net.hasDesign(w['B'], card));
    await w.setOnline(w['A'], false);

    // B blocked F: F's asking gets no answer.
    await w['B'].hub.blockFriend(peerAddress: w['F'].address);
    await net.settle();
    await net.collect(w['F'], card);
    await w.advance(const Duration(minutes: 3));
    await net.beat();
    expect(net.hasDesign(w['F'], card), isFalse);

    // A design B sends anyway is not taken from someone F blocked.
    await w['F'].hub.blockFriend(peerAddress: w['B'].address);
    await net.settle();
    final Uint8List design = (await net.store(w['B']).design(card.id))!;
    await w['B'].appTransport.send(
      remoteAddress: w['F'].address,
      payload: <String, dynamic>{
        'type': PebbleFrames.design,
        'c': card.text,
        'd': b64(design),
      },
    );
    await net.settle();
    expect(net.hasDesign(w['F'], card), isFalse);
  });

  test(
    'a design that is not the card\'s, or unasked for, is not taken',
    () async {
      final FriendsWorld w = await FriendsWorld.create(<String>['A', 'F']);
      final _Net net = await _Net.of(w, keeperTarget: 0);
      final PebbleCard card = await net.publish(w['A']);
      final Uint8List wrong = Uint8List.fromList(List<int>.filled(100, 7));
      // Unasked: F has no such pebble.
      await w['A'].appTransport.send(
        remoteAddress: w['F'].address,
        payload: <String, dynamic>{
          'type': PebbleFrames.design,
          'c': card.text,
          'd': b64((await net.store(w['A']).design(card.id))!),
        },
      );
      await net.settle();
      expect(net.store(w['F']).entry(card.id), isNull);
      // Asked, but the bytes are not the design the card was signed for.
      await net.store(w['F']).addCollected(card);
      await w['A'].appTransport.send(
        remoteAddress: w['F'].address,
        payload: <String, dynamic>{
          'type': PebbleFrames.design,
          'c': card.text,
          'd': b64(wrong),
        },
      );
      await net.settle();
      expect(net.hasDesign(w['F'], card), isFalse);
    },
  );

  test('a pebble collected from its QR card gets the full signed card '
      'with the design', () async {
    final FriendsWorld w = await FriendsWorld.create(<String>['A', 'F']);
    final _Net net = await _Net.of(w, keeperTarget: 0);
    final PebbleCard card = await net.publish(w['A']);
    // The sticker carries only the QR card: no note, date or signature.
    await net.collect(w['F'], card.qrCard);
    await net.until(
      () => net.hasDesign(w['F'], card),
      reason: 'the design reaching F',
    );
    final PebbleEntry e = net.store(w['F']).entry(card.id)!;
    expect(e.card, card);
    expect(e.card.isFull, isTrue);
    expect(e.card.note, 'przy ławce');
    expect(e.collected, isTrue);
    expect(e.findNote, 'w parku');
  });

  test('a QR card is not replaced by a full card someone else signed, nor '
      'by another pebble\'s', () async {
    final FriendsWorld w = await FriendsWorld.create(<String>['A', 'F', 'M']);
    final _Net net = await _Net.of(w, keeperTarget: 0);
    final PebbleCard card = await net.publish(w['A']);
    final Uint8List design = (await net.store(w['A']).design(card.id))!;
    await w.setOnline(w['A'], false);
    await net.store(w['F']).addCollected(card.qrCard);
    // M copies the author's key and id into a card it signs itself.
    final PebbleCard mine = await PebbleCard.sign(
      key: net.keys[w['M']]!,
      design: design,
      createdSeconds: card.createdSeconds,
      look: card.look,
      name: 'Podróbka',
      note: '',
      authorName: 'A',
    );
    final Uint8List forged = Uint8List.fromList(mine.bytes)
      ..setRange(1, 17, card.id.bytes)
      ..setRange(17, 49, card.author);
    // And a real card of another pebble by A.
    await w.setOnline(w['A'], true);
    final PebbleCard other = await net.publish(w['A'], size: 2000);
    final Uint8List otherDesign = (await net.store(w['A']).design(other.id))!;
    await w.setOnline(w['A'], false);
    for (final (Uint8List c, Uint8List d) in <(Uint8List, Uint8List)>[
      (forged, design),
      (other.bytes, otherDesign),
      // The QR card itself never stands for the full one.
      (card.qrCard.bytes, design),
    ]) {
      await w['M'].appTransport.send(
        remoteAddress: w['F'].address,
        payload: <String, dynamic>{
          'type': PebbleFrames.design,
          'c': b64(c),
          'd': b64(d),
        },
      );
      await net.settle();
    }
    expect(net.hasDesign(w['F'], card), isFalse);
    expect(net.store(w['F']).entry(card.id)!.card, card.qrCard);
    expect(net.store(w['F']).entry(other.id), isNull);
  });

  test('"znaleziono" reaches the author once per finder', () async {
    final FriendsWorld w = await FriendsWorld.create(<String>['A', 'F', 'G']);
    final _Net net = await _Net.of(w, keeperTarget: 0);
    final PebbleCard card = await net.publish(w['A']);
    await net.collect(w['F'], card);
    await net.beat();
    await net.collect(w['G'], card);
    await net.beat();
    await net.beat();
    expect(net.store(w['A']).finderCount(card.id), 2);
    expect(net.store(w['F']).entry(card.id)!.foundSent, isTrue);
  });

  test('a retired pebble leaves its keepers, collectors keep it', () async {
    final FriendsWorld w = await FriendsWorld.create(<String>['A', 'B', 'C']);
    final _Net net = await _Net.of(w, keeperTarget: 1);
    net.peers[w['A']]!.candidates = <String>[w['B'].address];
    final PebbleCard card = await net.publish(w['A']);
    await net.until(() => net.hasDesign(w['B'], card));
    await net.collect(w['C'], card);
    await net.until(() => net.hasDesign(w['C'], card));
    expect(await net.hosts[w['A']]!.retire(card.id), isTrue);
    await net.settle();
    expect(net.store(w['B']).entry(card.id), isNull);
    expect(net.hasDesign(w['C'], card), isTrue);
  });

  test('an older Zen takes every pebble frame in its stride', () async {
    final FriendsWorld w = await FriendsWorld.create(<String>['A', 'Old']);
    // Only A runs the pebbles; "Old" is the app before 1.15.0.
    final LedgerKeyPair key = await LedgerKeyPair.generate();
    final Uint8List design = Uint8List.fromList(List<int>.filled(60000, 3));
    final PebbleCard card = await PebbleCard.sign(
      key: key,
      design: design,
      createdSeconds: 1,
      look: _look,
      name: 'x',
      note: 'y',
      authorName: 'z',
    );
    final PebbleKeeperList list = await PebbleKeeperList.sign(
      key: key,
      id: card.id,
      version: 1,
      keepers: <String>[w['A'].address],
    );
    final List<Map<String, dynamic>> frames = <Map<String, dynamic>>[
      <String, dynamic>{'type': PebbleFrames.get, 'id': card.id.text, 'h': 1},
      <String, dynamic>{
        'type': PebbleFrames.design,
        'c': card.text,
        'd': b64(design),
        'k': list.toJson(),
      },
      <String, dynamic>{
        'type': PebbleFrames.keepAsk,
        'c': card.text,
        'n': 60000,
      },
      <String, dynamic>{'type': PebbleFrames.keepYes, 'id': card.id.text},
      <String, dynamic>{'type': PebbleFrames.keepNo, 'id': card.id.text},
      <String, dynamic>{'type': PebbleFrames.keepQuit, 'id': card.id.text},
      <String, dynamic>{'type': PebbleFrames.keepers, 'k': list.toJson()},
      <String, dynamic>{'type': PebbleFrames.found, 'n': <String, dynamic>{}},
    ];
    expect(
      frames.map((Map<String, dynamic> f) => f['type']).toSet(),
      PebbleFrames.all,
    );
    for (final Map<String, dynamic> f in frames) {
      expect(
        zenSignalFromTransportPayload(sender: w['A'].address, payload: f),
        isNull,
        reason: '${f['type']} is no signal of the app',
      );
    }
    final int friendsBefore = w['Old'].state.acceptedFriends.length;
    final int noticesBefore = w['Old'].notices.posted.length;
    for (final Map<String, dynamic> f in frames) {
      await w['A'].appTransport.send(
        remoteAddress: w['Old'].address,
        payload: f,
      );
    }
    await w.deliver();
    expect(w['Old'].notices.posted.length, noticesBefore);
    expect(w['Old'].state.acceptedFriends.length, friendsBefore);
    expect(await w['Old'].textsFrom(w['A']), isEmpty);
    // And the old phone still talks normally afterwards.
    await w.send(w['A'], w['Old'], 'hej');
    await w.assertDelivered(w['Old'], 'hej', from: w['A']);
  });
}
