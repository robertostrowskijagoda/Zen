import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/domain/friends/friend_profile.dart';
import 'package:zen/src/domain/signals/signal_queue_store.dart';
import 'package:zen/src/features/chat/message_timeline_store.dart';
import 'package:zen/src/features/dating/dating_model.dart';
import 'package:zen/src/features/dating/dating_service.dart';
import 'package:zen/src/features/ledger/ledger_providers.dart';
import 'package:zen/src/features/meet/events/event_service.dart';
import 'package:zen/src/features/runtime/runtime_system_notifications.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';
import 'package:zen/src/features/social/block_book.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';
import 'package:zen/src/features/social/social_hub_controller.dart';
import 'package:zen/src/features/social/social_hub_state.dart';
import 'package:zen/src/features/social/social_snapshot_store.dart';

/// One block list in Dating: a person blocked in the messenger never gets
/// this person's dating profile and is never shown here, also through a
/// mutual friend; a block made in Dating blocks the person, and once the
/// address behind a blocked dating key is known, a new key of theirs is
/// refused too.

final class _Net {
  final Map<String, _Phone> phones = <String, _Phone>{};
  final Map<String, Set<String>> friends = <String, Set<String>>{};
  int clock = 1000000;

  void link(_Phone a, _Phone b) {
    (friends[a.address] ??= <String>{}).add(b.address);
    (friends[b.address] ??= <String>{}).add(a.address);
  }

  void unlink(_Phone a, _Phone b) {
    friends[a.address]?.remove(b.address);
    friends[b.address]?.remove(a.address);
  }
}

/// A phone: its Dating, and the app's social hub (where the one block list
/// lives) wired to it as `datingServiceProvider` wires them.
final class _Phone implements EventHost {
  _Phone._(this.net, this.name, this.container)
    : address = PeerShareCodec.normalizeAddress(
        '200::${(0xc0 + net.phones.length).toRadixString(16)}',
      ) {
    net.phones[address] = this;
    service = _make(disk);
  }

  static Future<_Phone> start(_Net net, String name, Directory dir) async {
    final MemorySignalTransport out = MemorySignalTransport();
    await out.start();
    final ProviderContainer container = ProviderContainer(
      overrides: [
        signalQueueStoreProvider.overrideWithValue(MemorySignalQueueStore()),
        socialSnapshotStoreProvider.overrideWithValue(
          MemorySocialSnapshotStore(),
        ),
        messageTimelineStoreProvider.overrideWithValue(
          MemoryMessageTimelineStore(),
        ),
        socialHubSeedProvider.overrideWithValue(SocialHubState.empty()),
        signalTransportProvider.overrideWithValue(out),
        supportDirectoryResolverProvider.overrideWithValue(() async => dir),
      ],
    );
    addTearDown(container.dispose);
    final _Phone phone = _Phone._(net, name, container);
    await phone.hub.whenHydrated;
    await phone.service.load();
    return phone;
  }

  final _Net net;
  final String name;
  final String address;
  final ProviderContainer container;
  MemoryLedgerDisk disk = MemoryLedgerDisk();
  late DatingService service;

  /// The people of this person's chat groups who are not friends.
  final Set<String> groupPeers = <String>{};

  SocialHubController get hub =>
      container.read(socialHubControllerProvider.notifier);

  SocialHubState get social => container.read(socialHubControllerProvider);

  DatingService _make(MemoryLedgerDisk d) => DatingService(
    host: this,
    disk: d,
    now: () => net.clock,
    groupPeers: () => groupPeers,
    blocked: () => blockedPeopleOf(null, social),
    onBlock: (String key, String? address, String name) => hub.blockPerson(
      address: address ?? '',
      datingKey: key,
      name: name,
      origin: BlockOrigin.dating,
    ),
    onBlockedKey: (String key, String address) =>
        hub.learnBlocked(address: address, datingKey: key),
  );

  @override
  Future<void> send(String to, Map<String, dynamic> payload) async {
    final _Phone? other = net.phones[to];
    if (other == null) {
      return;
    }
    await other.service.handle(
      SignalTransportFrame(
        from: address,
        payload: jsonDecode(jsonEncode(payload)) as Map<String, dynamic>,
        receivedAtMillis: 0,
      ),
    );
  }

  @override
  List<String> friends() => (net.friends[address] ?? const <String>{}).toList();

  @override
  bool isFriend(String a) => net.friends[address]?.contains(a) ?? false;

  @override
  String ownAddress() => address;

  @override
  String ownName() => name;

  @override
  String nameOf(String a) => net.phones[a]?.name ?? '?';

  @override
  Future<void> notify(RuntimeSystemNotification n) async {}

  Future<void> date(String n, DatingGender g) async {
    await service.saveMine((MyDating m) {
      m
        ..enabled = true
        ..name = n
        ..gender = g
        ..wants = DatingWants(
          genders: DatingGender.values.toSet(),
          hops: kDatingMaxHops,
          intent: DatingIntent.dates,
          friendGenders: kDatingAllGenders,
        );
    });
    await service.maybePublish(force: true);
  }

  bool sees(String n) =>
      service.toDecide.any((SeenProfile s) => s.profile.name == n);

  /// The same person on the same phone takes a new dating key (what a
  /// modified app does at will) and forgets what it saw and decided.
  Future<void> newDatingKey() async {
    final Map<String, dynamic> state =
        jsonDecode(utf8.decode((await disk.read('dating/state'))!))
              as Map<String, dynamic>
          ..remove('id')
          ..remove('vs')
          ..remove('ps')
          ..remove('blocked')
          ..remove('profiles')
          ..remove('dec')
          ..remove('ksent');
    disk = MemoryLedgerDisk();
    await disk.write('dating/state', utf8.encode(jsonEncode(state)));
    service = _make(disk);
    await service.load();
    await service.maybePublish(force: true);
  }
}

void main() {
  late Directory dir;
  setUp(() {
    dir = Directory.systemTemp.createTempSync('zen-block-dating-');
    addTearDown(() {
      try {
        dir.deleteSync(recursive: true);
      } on FileSystemException {
        // Still open on Windows.
      }
    });
  });

  test('a person blocked in the messenger never gets the dating profile and '
      'is never shown, also through a mutual friend; unblocking restores '
      'both', () async {
    final _Net net = _Net();
    final _Phone hub = await _Phone.start(net, 'hub', dir);
    final _Phone ania = await _Phone.start(net, 'ania', dir);
    final _Phone eve = await _Phone.start(net, 'eve', dir);
    net
      ..link(hub, ania)
      ..link(hub, eve)
      ..link(ania, eve);
    // Eve dates; her phone tells her friends (Ania among them) its key.
    await eve.date('Eve', DatingGender.man);
    expect(ania.service.knownKeyOf(eve.address), eve.service.myKey);

    // Ania blocks Eve in the messenger: no longer friends, Hub is mutual.
    await ania.hub.blockFriend(peerAddress: eve.address);
    net.unlink(ania, eve);
    await ania.date('Ania', DatingGender.woman);
    await eve.service.maybePublish(force: true);
    await ania.service.maybePublish(force: true);
    // ignore: avoid_print
    print(
      'Eve sees Ania after a messenger block: ${eve.sees('Ania')}, '
      'Ania sees Eve: ${ania.sees('Eve')}',
    );
    expect(eve.sees('Ania'), isFalse);
    expect(ania.sees('Eve'), isFalse);

    // Unblocked: both see each other again through Hub.
    await ania.hub.unblockFriend(peerAddress: eve.address);
    await ania.service.maybePublish(force: true);
    await eve.service.maybePublish(force: true);
    expect(eve.sees('Ania'), isTrue);
    expect(ania.sees('Eve'), isTrue);
  });

  test('a dating block holds after a new key once its owner is known: the '
      'blocked key told from an address makes it a block of that person, '
      'and their next key is refused', () async {
    final _Net net = _Net();
    final _Phone hub = await _Phone.start(net, 'hub', dir);
    final _Phone ania = await _Phone.start(net, 'ania', dir);
    final _Phone eve = await _Phone.start(net, 'eve', dir);
    net
      ..link(hub, ania)
      ..link(hub, eve);
    await ania.date('Ania', DatingGender.woman);
    await eve.date('Eve', DatingGender.man);
    await ania.service.maybePublish(force: true);
    expect(eve.sees('Ania'), isTrue);
    expect(ania.sees('Eve'), isTrue);

    // Ania blocks Eve's profile; nobody here knows whose key it is.
    final String eveKey = eve.service.myKey!;
    await ania.service.block(eveKey);
    final BlockRecord keyBlock = ania.social.blocks.active.single;
    expect(keyBlock.datingKeys, <String>[eveKey]);
    expect(keyBlock.addresses, isEmpty);
    await eve.service.forget(ania.service.myKey!);
    await eve.newDatingKey();
    await ania.service.maybePublish(force: true);

    // They end up in a chat group: Eve's phone tells its (blocked) key to
    // the group's people, from her address. The block is Eve's now, in the
    // messenger too.
    ania.groupPeers.add(eve.address);
    eve.groupPeers.add(ania.address);
    final String eveSecond = eve.service.myKey!;
    await eve.service.maybePublish(force: true);
    // A key Ania's phone never blocked, told from an address it does not
    // know as anyone's yet: nothing to refuse (the limit the dialog tells).
    expect(ania.social.blocks.datingKeys, isNot(contains(eveSecond)));

    // Now with the first key: Eve's app had kept it (a phone tells the key
    // it has; here the old one comes back on a restart).
    await ania.service.handle(
      SignalTransportFrame(
        from: eve.address,
        payload: <String, dynamic>{'type': DatingTypes.key, 'k': eveKey},
        receivedAtMillis: 0,
      ),
    );
    await Future<void>.delayed(Duration.zero);
    expect(
      ania.social.friendByAddress(eve.address)?.status,
      FriendRelationshipStatus.blocked,
    );
    expect(ania.social.blocks.addresses, contains(eve.address));

    // Eve's app takes yet another key and tells it to her group: refused,
    // on every device of Ania's account (it is in the block's record).
    await eve.service.forget(ania.service.myKey!);
    await eve.newDatingKey();
    final String eveThird = eve.service.myKey!;
    await Future<void>.delayed(Duration.zero);
    expect(ania.social.blocks.datingKeys, contains(eveThird));
    await ania.service.maybePublish(force: true);
    // ignore: avoid_print
    print(
      'Eve sees Ania with a new key once the block is hers: '
      '${eve.sees('Ania')}',
    );
    expect(eve.sees('Ania'), isFalse);
    await eve.service.maybePublish(force: true);
    expect(ania.sees('Eve'), isFalse);
  });

  test('a dating block of a known friend\'s profile blocks the friend '
      'everywhere; unblocking from the list shows the profile again', () async {
    final _Net net = _Net();
    final _Phone ania = await _Phone.start(net, 'ania', dir);
    final _Phone bob = await _Phone.start(net, 'bob', dir);
    net.link(ania, bob);
    await ania.date('Ania', DatingGender.woman);
    await bob.date('Bob', DatingGender.man);
    expect(ania.sees('Bob'), isTrue);
    final String bobKey = bob.service.myKey!;

    await ania.service.block(bobKey);
    expect(ania.sees('Bob'), isFalse);
    expect(
      ania.social.friendByAddress(bob.address)?.status,
      FriendRelationshipStatus.blocked,
    );
    final MapEntry<String, BlockRecord> record =
        ania.social.blocks.records.entries.single;
    expect(record.value.origin, BlockOrigin.dating);
    expect(record.value.addresses, <String>[bob.address]);
    expect(record.value.datingKeys, <String>[bobKey]);

    await ania.hub.unblockPerson(record.key);
    expect(ania.social.blocks.active, isEmpty);
    expect(
      ania.social.friendByAddress(bob.address)?.status,
      isNot(FriendRelationshipStatus.blocked),
    );
    expect(ania.sees('Bob'), isTrue);
  });
}
