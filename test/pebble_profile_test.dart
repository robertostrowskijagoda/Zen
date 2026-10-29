import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/core/ledger/ledger_identity.dart';
import 'package:zen/src/core/ledger/log_entry.dart';
import 'package:zen/src/features/ledger/audience_keys.dart';
import 'package:zen/src/features/ledger/bridge_book.dart';
import 'package:zen/src/features/ledger/ledger_node.dart';
import 'package:zen/src/features/pebbles/pebble_card.dart';
import 'package:zen/src/features/pebbles/pebble_hosting.dart';
import 'package:zen/src/features/pebbles/pebble_service.dart';
import 'package:zen/src/features/pebbles/pebble_store.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';

// "Kamyczki" on a profile: written into the ledger sealed for all friends,
// read by a friend, unreadable for a follower who holds the very entry.

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

final class _NoPeers implements PebblePeers {
  @override
  String? accountOf(String address) => null;

  @override
  List<String> addressesOfAccount(String account) => const <String>[];

  @override
  List<String> friends() => const <String>[];

  @override
  bool isBlocked(String address) => false;

  @override
  bool isFriend(String address) => false;

  @override
  List<PebbleKeeperCandidate> keeperCandidates() =>
      const <PebbleKeeperCandidate>[];
}

Future<void> _settle() async {
  for (int i = 0; i < 40; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

const PebbleCardLook _look = PebbleCardLook(
  shapePreset: 1,
  shapeSeed: 9,
  material: 2,
  mainColor: 0x808080,
  secondColor: 0x202020,
);

Future<PebbleCard> _card(LedgerKeyPair key, String name, int design) =>
    PebbleCard.sign(
      key: key,
      design: Uint8List.fromList(List<int>.filled(500, design)),
      createdSeconds: 1767225600,
      look: _look,
      name: name,
      note: '',
      authorName: 'Ada',
    );

PebbleService _service(LedgerNode node) {
  final PebbleStore store = PebbleStore(MemoryLedgerDisk());
  return PebbleService(
    store: store,
    hosting: PebbleHosting(
      transport: MemorySignalTransport(),
      store: store,
      peers: _NoPeers(),
      accountKey: () => null,
      serveCollected: () => true,
    ),
    node: node,
  );
}

void main() {
  final String ada = PeerShareCodec.normalizeAddress('200::a');
  final String bob = PeerShareCodec.normalizeAddress('200::b');
  final String cel = PeerShareCodec.normalizeAddress('200::c');
  late Map<String, _Linked> nodes;

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

  setUp(() => nodes = <String, _Linked>{});

  test(
    'friends see the pebbles, a follower holding the entry does not',
    () async {
      final LedgerNode a = await make(ada, <String>[bob]);
      final LedgerNode b = await make(bob, <String>[ada]);
      final LedgerNode c = await make(cel, const <String>[]);
      await _settle();
      final LedgerKeyPair adaKey = a.identity.accountKey!;
      final LedgerKeyPair other = await LedgerKeyPair.generate();
      final PebbleService service = _service(a);
      final PebbleCard made = await _card(adaKey, 'Sowa', 1);
      final PebbleCard found = await _card(other, 'Arbuz', 2);
      await service.store.addCreated(
        made,
        Uint8List.fromList(List<int>.filled(500, 1)),
      );
      await service.store.addCollected(found, findNote: 'pod mostem');
      expect(await service.publishProfile(), isTrue);
      expect(await service.publishProfile(), isFalse, reason: 'nothing new');
      await c.follow(ada);
      await _settle();

      final PebbleProfile onBob = (await verifyPebbleProfile(
        readPebbleProfile(b, a.account)!,
        a.account,
      ));
      expect(onBob.created.map((PebbleProfileItem i) => i.card), <PebbleCard>[
        made,
      ]);
      expect(onBob.collected.single.card, found);
      expect(onBob.collected.single.findNote, 'pod mostem');

      // Cela follows Ada: the public profile space reaches her, the sealed
      // "Kamyczki" part with it, but she has no key to it.
      final LogEntry held = c
          .entriesOf(spaceKind: 'profile', ofAccount: a.account)
          .firstWhere((LogEntry e) => e.kind == kPebblesProfileKind);
      expect(isSealed(held.body), isTrue);
      expect(readPebbleProfile(c, a.account), isNull);
    },
  );

  test('a made pebble in a profile must be signed by its owner', () async {
    final LedgerKeyPair ada = await LedgerKeyPair.generate();
    final LedgerKeyPair eve = await LedgerKeyPair.generate();
    final PebbleCard mine = await _card(ada, 'Mój', 1);
    final PebbleCard notMine = await _card(eve, 'Cudzy', 2);
    final PebbleStore store = PebbleStore(MemoryLedgerDisk());
    await store.addCreated(mine, Uint8List.fromList(List<int>.filled(500, 1)));
    await store.addCreated(
      notMine,
      Uint8List.fromList(List<int>.filled(500, 2)),
    );
    final PebbleProfile raw = pebbleProfileFromBody(
      pebbleProfileBody(created: store.created, collected: store.collected),
    )!;
    expect(raw.created, hasLength(2));
    final PebbleProfile checked = await verifyPebbleProfile(raw, ada.id);
    expect(checked.created.map((PebbleProfileItem i) => i.card), <PebbleCard>[
      mine,
    ]);
  });

  test(
    'a large collection is cut to fit, the oldest found ones first',
    () async {
      final LedgerKeyPair key = await LedgerKeyPair.generate();
      final PebbleStore store = PebbleStore(MemoryLedgerDisk());
      for (int i = 0; i < 300; i++) {
        final PebbleCard c = await PebbleCard.sign(
          key: key,
          design: Uint8List.fromList(<int>[i & 0xFF, i >> 8]),
          createdSeconds: i,
          look: _look,
          name: 'Kamyczek numer $i',
          note: 'o' * 90,
          authorName: 'Ktoś',
        );
        await store.addCollected(c, foundAtMillis: i);
      }
      final Map<String, dynamic> body = pebbleProfileBody(
        created: store.created,
        collected: store.collected,
      );
      final PebbleProfile p = pebbleProfileFromBody(body)!;
      expect(p.collected.length, lessThan(300));
      expect(p.collected.length, greaterThan(50));
    },
  );

  test('removals on another device apply here', () async {
    final LedgerKeyPair key = await LedgerKeyPair.generate();
    final PebbleCard c = await _card(key, 'x', 3);
    final PebbleStore here = PebbleStore(MemoryLedgerDisk(), clock: () => 10);
    await here.addCollected(c);
    await here.applyRemovals(<PebbleId, int>{c.id: 20});
    expect(here.entry(c.id), isNull);
    expect(here.removed[c.id], 20);
    final PebbleStore reloaded = PebbleStore(here.disk);
    await reloaded.load();
    expect(reloaded.entry(c.id), isNull);
    expect(reloaded.removed[c.id], 20);
  });

  test('the store keeps everything across a restart', () async {
    final LedgerKeyPair key = await LedgerKeyPair.generate();
    final Uint8List design = Uint8List.fromList(List<int>.filled(500, 4));
    final PebbleCard c = await _card(key, 'y', 4);
    final MemoryLedgerDisk disk = MemoryLedgerDisk();
    final PebbleStore s = PebbleStore(disk, clock: () => 1000);
    await s.addCollected(c, findNote: 'w lesie');
    expect(
      await s.putDesign(c.id, Uint8List.fromList(<int>[1, 2, 3])),
      isFalse,
      reason: 'not the design of the card',
    );
    expect(await s.putDesign(c.id, design), isTrue);
    await s.setKeeper(c.id, '200::9', PebbleKeeperState.accepted);
    await s.idle;
    final PebbleStore r = PebbleStore(disk);
    await r.load();
    final PebbleEntry e = r.entry(c.id)!;
    expect(e.collected, isTrue);
    expect(e.findNote, 'w lesie');
    expect(e.foundAtMillis, 1000);
    expect(e.hasDesign, isTrue);
    expect(await r.design(c.id), design);
    expect(r.keepersOf(c.id).single.state, PebbleKeeperState.accepted);
  });
}
