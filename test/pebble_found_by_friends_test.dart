import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/core/ledger/ledger_identity.dart';
import 'package:zen/src/features/ledger/bridge_book.dart';
import 'package:zen/src/features/ledger/ledger_node.dart';
import 'package:zen/src/features/ledger/ledger_providers.dart';
import 'package:zen/src/features/pebbles/pebble_card.dart';
import 'package:zen/src/features/pebbles/pebble_hosting.dart';
import 'package:zen/src/features/pebbles/pebble_store.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';

// Who counts as a finder of a pebble, with the accounts the author's phone
// really knows: its ledger's directory names the account of anyone who sent
// a proven hello, and an account costs nothing to make. Only the author's
// friends count.

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

/// The author's peers as the app wires them (`AppPebblePeers`): friends
/// from the friend list, accounts from the ledger's directory.
final class _AppPeers implements PebblePeers {
  _AppPeers(this.directory, this.friendList);

  final LedgerAccountDirectory directory;
  final List<String> friendList;

  @override
  List<String> friends() => friendList;

  @override
  bool isFriend(String address) =>
      friendList.contains(PeerShareCodec.normalizeAddress(address));

  @override
  bool isBlocked(String address) => false;

  @override
  String? accountOf(String address) => directory.accountOf(address);

  @override
  List<String> addressesOfAccount(String account) => const <String>[];

  @override
  List<PebbleKeeperCandidate> keeperCandidates() =>
      const <PebbleKeeperCandidate>[];
}

void main() {
  final String ada = PeerShareCodec.normalizeAddress('200::a');
  final String fay = PeerShareCodec.normalizeAddress('200::f');
  final String sam = PeerShareCodec.normalizeAddress('200::5');
  late Map<String, _Linked> nodes;
  late PebbleHosting hosting;

  Future<LedgerNode> make(String address, List<String> friends) async {
    final _Linked t = nodes[address] = _Linked(address, nodes);
    await t.start();
    final LedgerNode n = LedgerNode(
      transport: t,
      disk: MemoryLedgerDisk(),
      friendAddresses: () => friends,
      bridges: BridgeBook(probe: (String _) async => null),
      localAddress: () => address,
    );
    addTearDown(n.stop);
    await n.start();
    return n;
  }

  setUp(() => nodes = <String, _Linked>{});

  /// Ada's pebble, hosted on her phone, whose friends are [friends].
  Future<(LedgerNode, PebbleStore, MemorySignalTransport, PebbleCard)> author(
    List<String> friends,
  ) async {
    final LedgerNode node = await make(ada, friends);
    final LedgerKeyPair key = await LedgerKeyPair.generate();
    final MemorySignalTransport transport = MemorySignalTransport();
    await transport.start();
    final PebbleStore store = PebbleStore(MemoryLedgerDisk());
    hosting = PebbleHosting(
      transport: transport,
      store: store,
      peers: _AppPeers(LedgerAccountDirectory(node, () => friends), friends),
      accountKey: () => key,
      serveCollected: () => true,
      keeperTarget: 0,
    );
    final Uint8List design = Uint8List.fromList(<int>[1, 2, 3, 4]);
    final PebbleCard card = await PebbleCard.sign(
      key: key,
      design: design,
      createdSeconds: 1000,
      look: const PebbleCardLook(
        shape: 2,
        seed: 42,
        material: 1,
        mainColour: 0xAA3322,
        secondColour: 0x112233,
      ),
      name: 'Kamyk',
      note: '',
      authorName: 'Ada',
    );
    await store.addCreated(card, design);
    await hosting.start();
    addTearDown(hosting.stop);
    return (node, store, transport, card);
  }

  Future<void> found(
    MemorySignalTransport transport,
    String from,
    LedgerNode finder,
    PebbleCard card,
  ) async {
    final PebbleFoundNote note = await PebbleFoundNote.sign(
      key: finder.identity.accountKey!,
      id: card.id,
      atSeconds: 2000,
    );
    await transport.injectIncoming(
      from: from,
      payload: <String, dynamic>{
        'type': PebbleFrames.found,
        'n': note.toJson(),
      },
    );
    await _settle();
    await hosting.idle;
  }

  test('a stranger with fresh accounts from one address adds no finders, '
      'though the author\'s ledger knows each account', () async {
    final (LedgerNode node, PebbleStore store, MemorySignalTransport t, card) =
        await author(const <String>[]);
    for (int i = 0; i < 5; i++) {
      final LedgerNode stranger = await make(sam, const <String>[]);
      stranger.greet(ada);
      for (
        int k = 0;
        k < 100 && node.accountOfAnyAddress(sam) != stranger.account;
        k++
      ) {
        await _settle();
      }
      expect(node.isFriendAddress(sam), isFalse);
      expect(
        LedgerAccountDirectory(node, () => const <String>[]).accountOf(sam),
        stranger.account,
      );
      await found(t, sam, stranger, card);
      await stranger.stop();
    }
    expect(store.finderCount(card.id), 0);
  });

  test('a friend who found it counts, once', () async {
    final (LedgerNode node, PebbleStore store, MemorySignalTransport t, card) =
        await author(<String>[fay]);
    final LedgerNode friend = await make(fay, <String>[ada]);
    for (int k = 0; k < 100 && node.accountOf(fay) != friend.account; k++) {
      await _settle();
    }
    expect(node.accountOf(fay), friend.account);
    await found(t, fay, friend, card);
    await found(t, fay, friend, card);
    expect(store.finderCount(card.id), 1);
  });
}
