import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/core/ledger/hlc.dart';
import 'package:zen/src/core/storage/binary_store.dart';
import 'package:zen/src/domain/friends/friend_profile.dart';
import 'package:zen/src/domain/signals/signal_queue_store.dart';
import 'package:zen/src/features/account/account_routing_transport.dart';
import 'package:zen/src/features/chat/message_timeline_store.dart';
import 'package:zen/src/features/runtime/locked_receiver.dart';
import 'package:zen/src/features/runtime/runtime_signal_parser.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';
import 'package:zen/src/features/settings/app_settings.dart';
import 'package:zen/src/features/settings/app_settings_controller.dart';
import 'package:zen/src/features/social/block_book.dart';
import 'package:zen/src/features/social/friendship_book.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';
import 'package:zen/src/features/social/social_hub_controller.dart';
import 'package:zen/src/features/social/social_hub_state.dart';
import 'package:zen/src/features/social/social_snapshot_store.dart';

/// One block list: who this account blocked, by person, the same on every
/// device of the account, back from every copy, read by every feature.

final String _eve1 = PeerShareCodec.normalizeAddress('200::e1');
final String _eve2 = PeerShareCodec.normalizeAddress('200::e2');
final String _bob = PeerShareCodec.normalizeAddress('200::b0');

FriendshipTick _at(int millis, [String device = 'A']) =>
    FriendshipTick(millis, device);

/// The ledger's word on accounts: Eve has two devices.
final class _Accounts implements AccountDeviceDirectory {
  @override
  String get ownAccount => 'ME';

  @override
  String? accountOf(String address) =>
      address == _eve1 || address == _eve2 ? 'EVE' : null;

  @override
  List<String> addressesOf(String account) =>
      account == 'EVE' ? <String>[_eve1, _eve2] : const <String>[];

  @override
  String? contactAddressOf(String account) => null;

  @override
  String? unlinkedAccountOf(String address) => null;
}

/// One device of the account: its social hub (where the list lives).
final class _Device {
  _Device(Directory dir, {SocialSnapshotStore? store}) {
    container = ProviderContainer(
      overrides: [
        signalQueueStoreProvider.overrideWithValue(MemorySignalQueueStore()),
        socialSnapshotStoreProvider.overrideWithValue(
          store ?? MemorySocialSnapshotStore(),
        ),
        messageTimelineStoreProvider.overrideWithValue(
          MemoryMessageTimelineStore(),
        ),
        signalTransportProvider.overrideWithValue(transport),
        supportDirectoryResolverProvider.overrideWithValue(() async => dir),
      ],
    );
    addTearDown(container.dispose);
    container.read(accountDirectoryHolderProvider).directory = _Accounts();
  }

  final MemorySignalTransport transport = MemorySignalTransport();
  late final ProviderContainer container;

  Future<void> start() async {
    await transport.start();
    await hub.whenHydrated;
  }

  SocialHubController get hub =>
      container.read(socialHubControllerProvider.notifier);

  SocialHubState get state => container.read(socialHubControllerProvider);

  Future<void> deliver(String from, Map<String, dynamic> payload) async {
    await hub.receiveSignal(
      zenSignalFromTransportPayload(sender: from, payload: payload)!,
      receivedAtMillis: DateTime.now().millisecondsSinceEpoch,
    );
    await Future<void>.delayed(Duration.zero);
  }

  /// What another device of the account (or a copy) does with this one's
  /// copy of friends and blocks.
  Future<void> takeFrom(_Device other) => hub.importContactsBackup(
    jsonDecode(jsonEncode(other.hub.contactsBackup())) as Map<String, dynamic>,
  );
}

void main() {
  group('the book', () {
    test('a key block becomes a block of the person once their address and '
        'account are known; lifting it lifts all of it', () {
      BlockBook book = BlockBook.empty.block(
        datingKeys: <String>['K1'],
        name: 'Eve',
        origin: BlockOrigin.dating,
        tick: _at(1000),
      );
      expect(book.datingKeyState('K1'), isTrue);
      expect(book.blocksAddress(_eve1), isFalse);
      book = book.learn(
        account: 'EVE',
        addresses: <String>[_eve1],
        datingKeys: <String>['K1'],
      );
      expect(book.blocksAccount('EVE'), isTrue);
      expect(book.blocksAddress(_eve1), isTrue);
      expect(book.records.keys, containsAll(<String>['d:K1', 'a:EVE']));
      // A later key of theirs joins the same block.
      book = book.learn(addresses: <String>[_eve1], datingKeys: <String>['K2']);
      expect(book.datingKeyState('K2'), isTrue);
      // Someone not blocked learns nothing.
      expect(identical(book.learn(addresses: <String>[_bob]), book), isTrue);

      book = book.lift(account: 'EVE', tick: _at(2000));
      expect(book.active, isEmpty);
      expect(book.datingKeyState('K1'), isFalse);
      expect(book.datingKeyState('K2'), isFalse);
      expect(book.datingKeyState('K9'), isNull);
    });

    test('two devices end with the same records whatever the order; a lifted '
        'block is never brought back by an older copy', () {
      final BlockBook a = BlockBook.empty.block(
        account: 'EVE',
        addresses: <String>[_eve1],
        tick: _at(1000, 'A'),
      );
      // B, at the same time, knows another key of hers.
      final BlockBook b = BlockBook.empty.block(
        account: 'EVE',
        datingKeys: <String>['K1'],
        tick: _at(1000, 'B'),
      );
      final BlockBook ab = a.mergeAll(b, wallMillis: 5000);
      final BlockBook ba = b.mergeAll(a, wallMillis: 5000);
      expect(
        jsonEncode(blockRecordsToJson(ab.records)),
        jsonEncode(blockRecordsToJson(ba.records)),
      );
      expect(ab.blocksAddress(_eve1), isTrue);
      expect(ab.datingKeyState('K1'), isTrue);

      // A lifts it; B was away and still says "blocked" (older).
      final BlockBook lifted = ab.lift(account: 'EVE', tick: _at(3000, 'A'));
      expect(lifted.active, isEmpty);
      final BlockBook back = lifted.mergeAll(ba, wallMillis: 5000);
      expect(back.active, isEmpty);
      expect(ba.mergeAll(lifted, wallMillis: 5000).active, isEmpty);
      expect(lifted.aheadOf(ba), isTrue);
      expect(ba.mergeAll(lifted, wallMillis: 5000).aheadOf(lifted), isFalse);
      // A record dated far ahead is not taken (it would win for good).
      final BlockBook ahead = BlockBook.empty.block(
        account: 'BOB',
        tick: _at(10 * 60 * 1000 * 10),
      );
      expect(
        lifted.mergeAll(ahead, wallMillis: 5000).blocksAccount('BOB'),
        isFalse,
      );
    });

    test('blocks and unblocks made by Zen 1.16.5 in the messenger come in '
        'line', () {
      FriendshipBook friends = FriendshipBook.empty.block(_eve1, _at(1000));
      BlockBook book = BlockBook.empty.reconcile(
        friends,
        accountOf: (String a) => a == _eve1 ? 'EVE' : null,
      );
      expect(book.blocksAccount('EVE'), isTrue);
      expect(book.blocksAddress(_eve1), isTrue);
      // Done again: nothing new.
      expect(identical(book.reconcile(friends), book), isTrue);
      // Unblocked there later: lifted here at that stamp.
      friends = friends.unblock(_eve1, _at(2000));
      book = book.reconcile(friends);
      expect(book.active, isEmpty);
    });

    test('who is blocked, as features ask it: a device of a blocked account '
        'counts as them; this account never does', () {
      final BlockedPeople people = BlockedPeople(
        book: BlockBook.empty.block(account: 'EVE', tick: _at(1000)),
        blockedAddresses: <String>[_bob],
        accountOf: (String a) => a == _eve2
            ? 'EVE'
            : a == '200::111'
            ? 'ME'
            : null,
        addressesOf: (String acc) =>
            acc == 'EVE' ? <String>[_eve2] : const <String>[],
        ownAccount: 'ME',
      );
      expect(people.address(_eve2), isTrue);
      expect(people.address(_bob), isTrue);
      expect(people.address('200::111'), isFalse);
      expect(people.account('EVE'), isTrue);
      expect(people.addresses, containsAll(<String>[_eve2, _bob]));
      expect(BlockedPeople.nobody.address(_eve2), isFalse);
    });
  });

  group('the app', () {
    late Directory dir;
    setUp(() {
      dir = Directory.systemTemp.createTempSync('zen-block-book-');
      addTearDown(() {
        try {
          dir.deleteSync(recursive: true);
        } on FileSystemException {
          // Still open on Windows.
        }
      });
    });

    test('a messenger block is a block of the account: nothing comes in from '
        'another device of theirs (a message, an invitation, a group '
        'invitation); unblocking lets them in again', () async {
      final _Device phone = _Device(dir);
      await phone.start();
      await phone.container
          .read(appSettingsControllerProvider.notifier)
          .setGroupInviteFrom(GroupInviteFrom.everyone);
      await phone.hub.blockFriend(peerAddress: _eve1);
      final BlockRecord record = phone.state.blocks.active.single;
      expect(record.account, 'EVE');
      expect(record.addresses, <String>[_eve1]);

      // Her second device writes, invites and asks to a group.
      await phone.deliver(_eve2, <String, dynamic>{
        'type': 'friend_request',
        'senderName': 'Ewa',
      });
      await phone.deliver(_eve2, <String, dynamic>{
        'type': 'group_invite',
        'groupId': 'g-eve',
        'groupName': 'Ewa i przyjaciele',
        'memberAddresses': <String>[_eve2],
      });
      await phone.deliver(_eve2, <String, dynamic>{
        'type': 'message',
        'msgId': 'm-1',
        'text': 'Hej',
      });
      expect(phone.state.friendByAddress(_eve2), isNull);
      expect(phone.state.groups, isEmpty);
      expect(phone.state.inbox, isEmpty);

      await phone.hub.unblockFriend(peerAddress: _eve1);
      expect(phone.state.blocks.active, isEmpty);
      await phone.deliver(_eve2, <String, dynamic>{
        'type': 'friend_request',
        'senderName': 'Ewa',
      });
      expect(
        phone.state.friendByAddress(_eve2)?.status,
        FriendRelationshipStatus.pendingIncoming,
      );
    });

    test('while the app is locked the background takes nothing from any '
        'device of a blocked account', () async {
      final _Device phone = _Device(dir);
      await phone.start();
      await phone.hub.blockFriend(peerAddress: _eve1);
      final Set<String> refused = backgroundCapabilityDraftOf(
        phone.state,
        inboxPublicKey: Uint8List(32),
        directory: _Accounts(),
      ).blocked;
      expect(refused, containsAll(<String>[_eve1, _eve2]));
      expect(
        backgroundContactsSignature(phone.state),
        isNot(backgroundContactsSignature(SocialHubState.empty())),
      );
    });

    test('two devices of the account agree: a block and its lifting travel '
        'in the copy, and a device away with the old copy brings nothing '
        'back', () async {
      final _Device phone = _Device(dir);
      final _Device desktop = _Device(dir);
      await phone.start();
      await desktop.start();
      await phone.hub.blockPerson(
        datingKey: 'K1',
        name: 'Eve',
        origin: BlockOrigin.dating,
      );
      await phone.hub.blockFriend(peerAddress: _bob);
      await desktop.takeFrom(phone);
      expect(desktop.state.blocks.datingKeyState('K1'), isTrue);
      expect(
        desktop.state.friendByAddress(_bob)?.status,
        FriendRelationshipStatus.blocked,
      );
      expect(
        desktop.hub.contactsBackupBehind(phone.hub.contactsBackup()),
        isFalse,
      );

      // The phone was away with this copy; the desktop lifts both.
      final Map<String, dynamic> old =
          jsonDecode(jsonEncode(phone.hub.contactsBackup()))
              as Map<String, dynamic>;
      await Future<void>.delayed(const Duration(milliseconds: 5));
      await desktop.hub.unblockPerson('d:K1');
      await desktop.hub.unblockFriend(peerAddress: _bob);
      expect(desktop.state.blocks.active, isEmpty);
      await phone.takeFrom(desktop);
      expect(phone.state.blocks.active, isEmpty);
      expect(phone.state.blocks.datingKeyState('K1'), isFalse);
      expect(
        phone.state.friendByAddress(_bob)?.status,
        isNot(FriendRelationshipStatus.blocked),
      );
      // The old copy comes again (a device back after a long time): still
      // lifted on both.
      await phone.hub.importContactsBackup(old);
      await desktop.hub.importContactsBackup(old);
      expect(phone.state.blocks.active, isEmpty);
      expect(desktop.state.blocks.active, isEmpty);
    });

    test('the list comes back from a copy and from the device\'s own '
        'store', () async {
      final Directory files = Directory('${dir.path}/store')..createSync();
      final FileSocialSnapshotStore store = FileSocialSnapshotStore(
        store: FileBinaryStore(
          files,
          codec: BinaryCodec(compressor: const _PassThroughCompressor()),
        ),
      );
      final _Device phone = _Device(dir, store: store);
      await phone.start();
      await phone.hub.blockPerson(
        datingKey: 'K1',
        name: 'Eve',
        origin: BlockOrigin.dating,
      );
      await phone.hub.blockFriend(peerAddress: _eve1);
      final Map<String, BlockRecord> made = phone.state.blocks.records;

      // A new phone restored from the copy.
      final _Device restored = _Device(dir);
      await restored.start();
      await restored.takeFrom(phone);
      expect(
        jsonEncode(blockRecordsToJson(restored.state.blocks.records)),
        jsonEncode(blockRecordsToJson(made)),
      );

      // The same phone started again.
      final SocialHubState? read = await FileSocialSnapshotStore(
        store: FileBinaryStore(
          files,
          codec: BinaryCodec(compressor: const _PassThroughCompressor()),
        ),
      ).load();
      expect(
        jsonEncode(blockRecordsToJson(read!.blocks.records)),
        jsonEncode(blockRecordsToJson(made)),
      );
      expect(read.blocks.clock, isNot(Hlc.zero));
    });
  });
}

final class _PassThroughCompressor implements BinaryCompressor {
  const _PassThroughCompressor();

  @override
  Future<Uint8List?> compress(Uint8List input, int level) async => input;

  @override
  Future<Uint8List?> decompress(Uint8List input) async => input;
}
