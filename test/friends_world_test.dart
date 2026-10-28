import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/domain/friends/friend_profile.dart';
import 'package:zen/src/domain/friends/peer_presence.dart';
import 'package:zen/src/domain/messages/chat_message.dart';
import 'package:zen/src/domain/runtime/lifecycle_snapshot.dart';
import 'package:zen/src/domain/signals/zen_signal.dart';
import 'package:zen/src/features/account/circle_backup.dart';
import 'package:zen/src/features/account/circle_backup_service.dart';
import 'package:zen/src/features/account/device_chat_sync.dart';
import 'package:zen/src/features/account/recovery_providers.dart';
import 'package:zen/src/features/ledger/bridge_book.dart';
import 'package:zen/src/features/ledger/ledger_identity_store.dart';
import 'package:zen/src/features/ledger/ledger_node.dart';
import 'package:zen/src/features/media/media_vault.dart';
import 'package:zen/src/features/profile/user_profile_store.dart';
import 'package:zen/src/features/relay/relay_models.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';

import 'support/friends_world.dart';

/// Messaging end to end between simulated friends (`FriendsWorld`): the real
/// relay engines, social controllers and reliable transports of several
/// phones on a network with a virtual clock. What the unit tests of the
/// engine prove piece by piece, these prove for the whole way a message
/// goes, without real devices.

/// How many copies of mail for [owner] the phone [holder] keeps.
Future<int> _heldFor(FriendsPhone holder, FriendsPhone owner) async =>
    (await holder.relayStore.load()).mailbox[owner.address]?.length ?? 0;

/// A world of [names] with [mailboxes] chosen as [owner]'s mailboxes.
Future<FriendsWorld> _withMailboxes(
  List<String> names,
  String owner,
  List<String> mailboxes,
) async {
  final FriendsWorld w = await FriendsWorld.create(names);
  await w.chooseMailboxes(w[owner], <FriendsPhone>[
    for (final String m in mailboxes) w[m],
  ]);
  return w;
}

/// The recovery circle's copy of [source]'s conversations, and where a copy
/// goes back to on [restoreInto].
final class _CircleData implements CircleBackupData {
  _CircleData({this.source, this.restoreInto});

  final FriendsPhone? source;
  final FriendsPhone? restoreInto;

  @override
  Future<CircleBackupContent> collect({required bool chats}) async {
    final FriendsPhone? phone = source;
    if (phone == null) {
      return const CircleBackupContent();
    }
    return CircleBackupContent(
      chats: <String, List<Map<String, dynamic>>>{
        for (final String key in phone.hub.conversationKeys())
          key: <Map<String, dynamic>>[
            for (final ChatMessage m in await phone.hub.conversationMessages(
              key,
            ))
              // What a person wrote, not the "connected" notes of the app.
              if (m.direction != ChatMessageDirection.system)
                chatMessageToSync(m),
          ],
      },
    );
  }

  @override
  Future<void> restore(
    CircleBackupContent content,
    void Function(int done, int total) progress,
  ) async {
    final FriendsPhone? phone = restoreInto;
    if (phone != null) {
      // Only conversations are put back here: the node is used for friends'
      // levels, which this copy does not carry.
      final LedgerNode node = LedgerNode(
        transport: MemorySignalTransport(),
        disk: MemoryLedgerDisk(),
        friendAddresses: () => const <String>[],
        bridges: BridgeBook(probe: (String _) async => null),
        localAddress: () => phone.address,
        syncInterval: Duration.zero,
      );
      final Provider<AppCircleBackupData> restorer =
          Provider<AppCircleBackupData>(
            (Ref ref) => AppCircleBackupData(ref, node),
          );
      await phone.container.read(restorer).restore(content, progress);
    }
    progress(1, 1);
  }
}

CircleBackupIdentity _identityOf(LedgerIdentity i) => CircleBackupIdentity(
  account: i.account,
  selfKey: i.selfKey!,
  deviceKey: i.deviceKey,
  certificate: i.certificate,
);

void main() {
  group('a message between friends who are both online', () {
    test(
      'arrives once, is shown once, and the sender sees it delivered',
      () async {
        final FriendsWorld w = await FriendsWorld.create(<String>['A', 'B']);
        await w.send(w['A'], w['B'], 'cześć');
        await w.assertDelivered(w['B'], 'cześć', from: w['A']);
        await w.until(
          () async =>
              await w['A'].deliveryOf(w['B'], 'cześć') ==
              ChatMessageDeliveryState.delivered,
          reason: 'the delivery mark',
        );
        expect(await w['B'].textsFrom(w['A']), <String>['cześć']);
        expect(w['B'].messageNotices, hasLength(1));
        expect(
          (await w['A'].relayStore.load()).outbox,
          isEmpty,
          reason: 'nothing left waiting at the sender',
        );
      },
    );

    // A GIF from the picker to a friend whose app was open showed "waiting
    // in the mailbox" on the sender's side: it has to go straight there.
    test('a GIF to a friend with the app open arrives directly, never '
        'through the mailboxes', () async {
      final FriendsWorld w = await _withMailboxes(
        <String>['A', 'B', 'M1', 'M2'],
        'B',
        <String>['M1', 'M2'],
      );
      final Uint8List gif = Uint8List.fromList(<int>[
        ...'GIF89a'.codeUnits,
        ...List<int>.generate(120 * 1000, (int i) => (i * 13 + 5) & 0xff),
      ]);
      await w['A'].hub.sendLocalAttachment(
        peerAddress: w['B'].address,
        bytes: gif,
        fileName: 'kot.gif',
        mimeType: 'image/gif',
        type: ChatMessageType.image,
        sentAtMillis: w.now,
      );
      await w.settle();
      await w.until(
        () async => (await w['B'].thread(
          w['A'],
        )).any((ChatMessage m) => m.attachmentPath != null),
        reason: 'the GIF reaching B',
        within: const Duration(seconds: 30),
      );
      final ChatMessage got = (await w['B'].thread(
        w['A'],
      )).firstWhere((ChatMessage m) => m.attachmentPath != null);
      expect(
        await w['B'].container
            .read(mediaVaultProvider)
            .read(got.attachmentPath!),
        gif,
      );
      await w.until(
        () async => (await w['A'].thread(w['B'])).any(
          (ChatMessage m) =>
              m.direction == ChatMessageDirection.outgoing &&
              m.deliveryState == ChatMessageDeliveryState.delivered,
        ),
        reason: 'the delivery mark',
        within: const Duration(seconds: 30),
      );
      for (final String mailbox in <String>['M1', 'M2']) {
        final RelayState held = await w[mailbox].relayStore.load();
        expect(
          held.heldBlobs[w['B'].address] ?? const <String, Object>{},
          isEmpty,
          reason: '$mailbox holds no copy',
        );
        expect(
          held.mailbox[w['B'].address] ?? const <String, Object>{},
          isEmpty,
          reason: '$mailbox holds no mail',
        );
      }
    });
  });

  group('mail for a friend who is offline', () {
    test('is held by the friend\'s phone mailboxes and handed over when the '
        'friend is back, with the sender gone', () async {
      final FriendsWorld w = await _withMailboxes(
        <String>['A', 'B', 'M1', 'M2'],
        'B',
        <String>['M1', 'M2'],
      );
      await w.setOnline(w['B'], false);
      await w.send(w['A'], w['B'], 'czekam na Ciebie');
      await w.advance(const Duration(seconds: 10)); // past the deposit delay

      expect(await _heldFor(w['M1'], w['B']), 1);
      expect(await _heldFor(w['M2'], w['B']), 1);
      expect(
        await w['A'].deliveryOf(w['B'], 'czekam na Ciebie'),
        isNot(ChatMessageDeliveryState.delivered),
      );

      // The sender leaves, then the friend returns: only the mailboxes can
      // deliver now.
      await w.setOnline(w['A'], false);
      await w.setOnline(w['B'], true);
      await w.assertDelivered(w['B'], 'czekam na Ciebie', from: w['A']);
      expect(await w['B'].textsFrom(w['A']), <String>['czekam na Ciebie']);

      // The mailboxes let go of their copies once the friend has it.
      await w.until(
        () async =>
            await _heldFor(w['M1'], w['B']) == 0 &&
            await _heldFor(w['M2'], w['B']) == 0,
        reason: 'the mailboxes dropping the delivered copy',
      );

      // The sender comes back and learns it was delivered, from the
      // receipt that waited for it in its own mailboxes.
      await w.setOnline(w['A'], true);
      await w.until(
        () async =>
            await w['A'].deliveryOf(w['B'], 'czekam na Ciebie') ==
            ChatMessageDeliveryState.delivered,
        reason: 'the sender seeing the delivery',
      );
      expect(await w['B'].textsFrom(w['A']), <String>['czekam na Ciebie']);
    });

    test('reaches the friend even when the sender went offline right after '
        'sending, before any mailbox had a copy', () async {
      final FriendsWorld w = await _withMailboxes(
        <String>['A', 'B', 'M1'],
        'B',
        <String>['M1'],
      );
      await w.setOnline(w['B'], false);
      await w.send(w['A'], w['B'], 'zaraz znikam');
      // Gone before the deposit delay: the message waits in A's own outbox.
      await w.setOnline(w['A'], false);
      await w.advance(const Duration(minutes: 20));
      expect(await _heldFor(w['M1'], w['B']), 0);
      expect(await w['B'].textsFrom(w['A']), isEmpty);

      // Back online, the sender's phone takes up the queue again; the
      // friend is still away, so the mailbox gets it, and then the friend.
      await w.setOnline(w['A'], true);
      await w.until(
        () async => await _heldFor(w['M1'], w['B']) == 1,
        reason: 'the mailbox receiving the deposit',
      );
      await w.setOnline(w['A'], false);
      await w.setOnline(w['B'], true);
      await w.assertDelivered(w['B'], 'zaraz znikam', from: w['A']);
    });

    test('is still covered when one of the mailboxes is offline too', () async {
      final FriendsWorld w = await _withMailboxes(
        <String>['A', 'B', 'M1', 'M2', 'M3'],
        'B',
        <String>['M1', 'M2', 'M3'],
      );
      await w.setOnline(w['B'], false);
      await w.setOnline(w['M1'], false);
      await w.send(w['A'], w['B'], 'jedna skrzynka śpi');
      await w.advance(const Duration(seconds: 10));
      expect(await _heldFor(w['M2'], w['B']), 1);
      expect(await _heldFor(w['M3'], w['B']), 1);

      // The sender is gone, the sleeping mailbox is still asleep.
      await w.setOnline(w['A'], false);
      await w.setOnline(w['B'], true);
      await w.assertDelivered(w['B'], 'jedna skrzynka śpi', from: w['A']);
      expect(await w['B'].textsFrom(w['A']), <String>['jedna skrzynka śpi']);

      // The sleeping mailbox wakes up and does not hand a second copy out.
      await w.setOnline(w['M1'], true);
      await w.advance(const Duration(minutes: 15));
      expect(await w['B'].textsFrom(w['A']), <String>['jedna skrzynka śpi']);
    });

    test('is held when the mailbox is offline at the time of sending, by '
        'the others, and by the late one once it is back', () async {
      final FriendsWorld w = await _withMailboxes(
        <String>['A', 'B', 'M1', 'M2'],
        'B',
        <String>['M1', 'M2'],
      );
      await w.setOnline(w['B'], false);
      await w.setOnline(w['M1'], false);
      await w.send(w['A'], w['B'], 'dla obu skrzynek');
      await w.advance(const Duration(seconds: 10));
      expect(await _heldFor(w['M1'], w['B']), 0);
      expect(await _heldFor(w['M2'], w['B']), 1);

      // The late mailbox is back while the sender is still trying.
      await w.setOnline(w['M1'], true);
      await w.until(
        () async => await _heldFor(w['M1'], w['B']) == 1,
        reason: 'the late mailbox getting its copy',
        within: const Duration(minutes: 30),
      );
    });
  });

  group('a group message', () {
    test('reaches online members at once and offline ones when they return, '
        'each once', () async {
      final FriendsWorld w = await FriendsWorld.create(<String>[
        'A',
        'B',
        'C',
        'D',
        'E',
      ]);
      final String id = await w.createGroup(w['A'], 'Ekipa', <FriendsPhone>[
        w['B'],
        w['C'],
        w['D'],
        w['E'],
      ]);
      await w.setOnline(w['C'], false);
      await w.setOnline(w['D'], false);

      await w.sendGroup(w['B'], id, 'wypad w góry?');
      await w.advance(const Duration(seconds: 10));

      expect(await w.groupTexts(w['A'], id), <String>['wypad w góry?']);
      expect(await w.groupTexts(w['E'], id), <String>['wypad w góry?']);
      expect(await w.groupTexts(w['C'], id), isEmpty);
      expect(await w.groupTexts(w['D'], id), isEmpty);

      // One of the sleeping members is back while the sender is gone.
      await w.setOnline(w['B'], false);
      await w.setOnline(w['C'], true);
      await w.until(
        () async => (await w.groupTexts(w['C'], id)).length == 1,
        reason: 'C getting the group message',
      );
      await w.setOnline(w['D'], true);
      await w.until(
        () async => (await w.groupTexts(w['D'], id)).length == 1,
        reason: 'D getting the group message',
      );
      for (final String name in <String>['A', 'C', 'D', 'E']) {
        expect(await w.groupTexts(w[name], id), <String>[
          'wypad w góry?',
        ], reason: name);
      }
      await w.advance(const Duration(minutes: 15));
      for (final String name in <String>['A', 'C', 'D', 'E']) {
        expect(
          await w.groupTexts(w[name], id),
          hasLength(1),
          reason: '$name must not get a copy again',
        );
      }
    });

    test('is delivered for the sender once every member has it', () async {
      final FriendsWorld w = await FriendsWorld.create(<String>['A', 'B', 'C']);
      final String id = await w.createGroup(w['A'], 'Trójka', <FriendsPhone>[
        w['B'],
        w['C'],
      ]);
      await w.setOnline(w['C'], false);
      await w.sendGroup(w['A'], id, 'dla wszystkich');
      await w.advance(const Duration(seconds: 10));
      ChatMessageDeliveryState? state() => null;
      expect(state(), isNull);
      final List<ChatMessage> before = await w['A'].thread('group:$id');
      expect(
        before.single.deliveryState,
        isNot(ChatMessageDeliveryState.delivered),
        reason: 'C has not got it yet',
      );
      await w.setOnline(w['C'], true);
      await w.until(
        () async =>
            (await w['A'].thread('group:$id')).single.deliveryState ==
            ChatMessageDeliveryState.delivered,
        reason: 'the group message turning delivered',
      );
    });
  });

  group('a new friendship', () {
    LifecycleSnapshot foreground(FriendsWorld w) => LifecycleSnapshot(
      visibility: AppVisibilityState.foreground,
      generation: 99,
      capturedAtMillis: w.now,
    );

    test('stays when the app comes to the screen: the invitation kept for '
        'that moment is not replayed over the answer', () async {
      final FriendsWorld w = await FriendsWorld.create(<String>['A', 'B']);
      for (final (FriendsPhone me, FriendsPhone friend)
          in <(FriendsPhone, FriendsPhone)>[
            (w['B'], w['A']),
            (w['A'], w['B']),
          ]) {
        await me.hub.setLifecycle(foreground(w));
        expect(
          me.state.friendByAddress(friend.address)?.status,
          FriendRelationshipStatus.accepted,
          reason: '${me.name} about ${friend.name}',
        );
      }
      // Still friends in what is stored too, and messages go both ways.
      await w.send(w['A'], w['B'], 'po powrocie');
      await w.assertDelivered(w['B'], 'po powrocie', from: w['A']);
    });

    test('an answer given while the app comes back is not undone by the '
        'stored state read at that moment', () async {
      final FriendsWorld w = await FriendsWorld.create(<String>[
        'A',
        'B',
      ], allFriends: false);
      await w['A'].hub.sendFriendRequest(
        peerAddress: w['B'].address,
        senderDisplayName: 'A',
      );
      await w.settle();
      expect(
        w['B'].state.friendByAddress(w['A'].address)?.status,
        FriendRelationshipStatus.pendingIncoming,
      );
      // Both at once: the app comes to the screen and the person accepts.
      final Future<void> back = w['B'].hub.setLifecycle(foreground(w));
      final Future<void> yes = w['B'].hub.acceptFriendRequest(
        peerAddress: w['A'].address,
        senderDisplayName: 'B',
      );
      await Future.wait(<Future<void>>[back, yes]);
      await w.settle();
      expect(
        w['B'].state.friendByAddress(w['A'].address)?.status,
        FriendRelationshipStatus.accepted,
      );
      expect(
        w['A'].state.friendByAddress(w['B'].address)?.status,
        FriendRelationshipStatus.accepted,
      );
      // And again later: nothing replayed.
      await w['B'].hub.setLifecycle(
        LifecycleSnapshot(
          visibility: AppVisibilityState.background,
          generation: 100,
          capturedAtMillis: w.now,
        ),
      );
      await w['B'].hub.setLifecycle(
        LifecycleSnapshot(
          visibility: AppVisibilityState.foreground,
          generation: 101,
          capturedAtMillis: w.now,
        ),
      );
      expect(
        w['B'].state.friendByAddress(w['A'].address)?.status,
        FriendRelationshipStatus.accepted,
      );
    });

    test('a friend asking again (our answer got lost) stays a friend and '
        'gets the answer again, without a new request', () async {
      final FriendsWorld w = await FriendsWorld.create(<String>['A', 'B']);
      final int inbox = w['B'].state.inbox.length;
      await w['B'].hub.receiveSignal(
        ZenSignal(
          type: ZenSignalType.friendRequest,
          sender: w['A'].address,
          displayName: 'A',
        ),
        receivedAtMillis: w.now,
      );
      await w.settle();
      expect(
        w['B'].state.friendByAddress(w['A'].address)?.status,
        FriendRelationshipStatus.accepted,
      );
      expect(w['B'].state.inbox.length, inbox);
      expect(
        w['A'].state.friendByAddress(w['B'].address)?.status,
        FriendRelationshipStatus.accepted,
      );
    });
  });

  group('notifications', () {
    test('a message that reaches the phone directly and from several '
        'mailboxes is shown once', () async {
      final FriendsWorld w = await _withMailboxes(
        <String>['A', 'B', 'M1', 'M2', 'M3'],
        'B',
        <String>['M1', 'M2', 'M3'],
      );
      await w.setOnline(w['B'], false);
      await w.send(w['A'], w['B'], 'jedno powiadomienie');
      await w.advance(const Duration(seconds: 10));
      expect(await _heldFor(w['M1'], w['B']), 1);

      // The phone comes back while the sender is still online and trying
      // directly: the direct copy and three mailbox copies all race.
      w.net.tracing = true;
      await w.setOnline(w['B'], true);
      await w.advance(const Duration(minutes: 15));

      // The copies did race: B was handed the same message by several
      // senders, and still showed it once.
      expect(
        w.net.trace.where(
          (String t) =>
              t.contains('→B ') &&
              (t.endsWith(' rly_mail') || t.endsWith(' message')),
        ),
        hasLength(greaterThan(1)),
      );
      expect(await w['B'].textsFrom(w['A']), <String>['jedno powiadomienie']);
      expect(w['B'].messageNotices, hasLength(1));
    });

    test('every message of a burst makes exactly one notification', () async {
      final FriendsWorld w = await _withMailboxes(
        <String>['A', 'B', 'M1', 'M2'],
        'B',
        <String>['M1', 'M2'],
      );
      await w.setOnline(w['B'], false);
      for (final String text in <String>['raz', 'dwa', 'trzy']) {
        await w.send(w['A'], w['B'], text);
      }
      await w.advance(const Duration(seconds: 10));
      await w.setOnline(w['A'], false);
      await w.setOnline(w['B'], true);
      await w.until(
        () async => (await w['B'].textsFrom(w['A'])).length == 3,
        reason: 'the three messages',
      );
      await w.advance(const Duration(minutes: 15));
      expect(w['B'].messageNotices, hasLength(3));
    });
  });

  group('a locked phone', () {
    test('keeps what arrives in its sealed inbox, notifies once without '
        'saying what, and the chat has it after the unlock', () async {
      final FriendsWorld w = await FriendsWorld.create(<String>['A', 'B']);
      await w.lock(w['B']);
      await w.send(w['A'], w['B'], 'tajna treść');
      await w.advance(const Duration(seconds: 20));

      expect(await w['B'].textsFrom(w['A']), isEmpty, reason: 'still locked');
      expect(w['B'].messageNotices, hasLength(1));
      expect(
        w['B'].messageNotices.single.contentRedacted,
        isTrue,
        reason: 'a locked phone cannot say what came or from whom',
      );
      expect(w['B'].messageNotices.single.title, isNot(contains('A')));
      // The sender was told it is safe on the other phone (the service
      // acknowledged it only once it was on the disk).
      expect((await w['A'].relayStore.load()).outbox, isEmpty);

      await w.unlock(w['B']);
      expect(await w['B'].textsFrom(w['A']), <String>['tajna treść']);
      expect(
        w['B'].shownMessageNotices,
        hasLength(1),
        reason: 'one message, one notification in the shade after the unlock',
      );
    });

    test('phones locked as mailboxes still hold and hand over mail for an '
        'offline friend', () async {
      final FriendsWorld w = await _withMailboxes(
        <String>['A', 'B', 'M1', 'M2'],
        'B',
        <String>['M1', 'M2'],
      );
      await w.lock(w['M1']);
      await w.lock(w['M2']);
      await w.setOnline(w['B'], false);

      await w.send(w['A'], w['B'], 'przez zablokowane skrzynki');
      await w.advance(const Duration(seconds: 10));
      await w.setOnline(w['A'], false);
      await w.setOnline(w['B'], true);
      await w.assertDelivered(
        w['B'],
        'przez zablokowane skrzynki',
        from: w['A'],
      );
      expect(w['B'].messageNotices, hasLength(1));
      await w.advance(const Duration(minutes: 15));
      expect(await w['B'].textsFrom(w['A']), hasLength(1));
    });
  });

  group('the network misbehaves', () {
    test('a split and its healing: mail sent across the split arrives once '
        'it is healed, once', () async {
      final FriendsWorld w = await FriendsWorld.create(<String>[
        'A',
        'B',
        'C',
        'D',
      ]);
      w.partition(
        <FriendsPhone>[w['A'], w['B']],
        <FriendsPhone>[w['C'], w['D']],
      );
      await w.send(w['A'], w['C'], 'przez mur');
      await w.send(w['D'], w['B'], 'w drugą stronę');
      await w.advance(const Duration(minutes: 5));
      expect(await w['C'].textsFrom(w['A']), isEmpty);
      expect(await w['B'].textsFrom(w['D']), isEmpty);

      // Inside each half everything still works.
      await w.send(w['A'], w['B'], 'po tej stronie');
      await w.assertDelivered(w['B'], 'po tej stronie', from: w['A']);

      w.heal();
      await w.until(
        () async =>
            (await w['C'].textsFrom(w['A'])).isNotEmpty &&
            (await w['B'].textsFrom(w['D'])).isNotEmpty,
        reason: 'the mail crossing the healed split',
        within: const Duration(minutes: 30),
      );
      await w.advance(const Duration(minutes: 15));
      expect(await w['C'].textsFrom(w['A']), <String>['przez mur']);
      expect(await w['B'].textsFrom(w['D']), <String>['w drugą stronę']);
    });

    test('with 30% of the datagrams lost, all messages arrive, each once '
        'and in order', () async {
      final FriendsWorld w = await FriendsWorld.create(<String>[
        'A',
        'B',
        'C',
        'D',
      ], seed: 7);
      w.dropRate = 0.3;
      final List<String> texts = <String>[
        for (int i = 1; i <= 15; i++) 'wiadomość $i',
      ];
      for (final String text in texts) {
        await w.send(w['A'], w['B'], text);
      }
      await w.until(
        () async => (await w['B'].textsFrom(w['A'])).length == texts.length,
        reason: 'all messages through the loss',
        within: const Duration(hours: 2),
      );
      await w.advance(const Duration(minutes: 30));
      expect(await w['B'].textsFrom(w['A']), texts);
      expect(w.net.stats.dropped, greaterThan(0), reason: 'loss did happen');
      expect(w['B'].messageNotices, hasLength(texts.length));
    });

    test('with loss and the receiver offline for a while, mail still comes '
        'out of the mailboxes', () async {
      final FriendsWorld w = await _withMailboxes(
        <String>['A', 'B', 'M1', 'M2', 'M3'],
        'B',
        <String>['M1', 'M2', 'M3'],
      );
      w.dropRate = 0.3;
      await w.setOnline(w['B'], false);
      await w.send(w['A'], w['B'], 'przez straty');
      await w.advance(const Duration(minutes: 10));
      await w.setOnline(w['A'], false);
      await w.setOnline(w['B'], true);
      await w.until(
        () async => (await w['B'].textsFrom(w['A'])).isNotEmpty,
        reason: 'the message after the loss',
        within: const Duration(hours: 1),
      );
      expect(await w['B'].textsFrom(w['A']), <String>['przez straty']);
    });
  });

  group('order', () {
    test('messages of a conversation arrive in the order they were sent, '
        'also when they come out of the mailboxes together', () async {
      final FriendsWorld w = await _withMailboxes(
        <String>['A', 'B', 'M1', 'M2'],
        'B',
        <String>['M1', 'M2'],
      );
      await w.setOnline(w['B'], false);
      final List<String> texts = <String>[
        for (int i = 1; i <= 12; i++) 'numer $i',
      ];
      for (final String text in texts) {
        await w.send(w['A'], w['B'], text);
      }
      await w.advance(const Duration(seconds: 10));
      await w.setOnline(w['A'], false);
      await w.setOnline(w['B'], true);
      await w.until(
        () async => (await w['B'].textsFrom(w['A'])).length == texts.length,
        reason: 'all twelve messages',
      );
      expect(await w['B'].textsFrom(w['A']), texts);
      // And the conversation in both directions keeps each side's order.
      await w.setOnline(w['A'], true);
      await w.send(w['B'], w['A'], 'b1');
      await w.send(w['A'], w['B'], 'a13');
      await w.send(w['B'], w['A'], 'b2');
      await w.advance(const Duration(seconds: 10));
      expect(await w['B'].textsFrom(w['A']), <String>[...texts, 'a13']);
      expect(await w['A'].textsFrom(w['B']), <String>['b1', 'b2']);
    });
  });

  group('mailbox choice', () {
    test('an iPhone, which receives only while Zen is open, is the one '
        'friend left out when there are more friends than mailboxes', () async {
      final FriendsWorld w = await FriendsWorld.create(
        <String>['A', 'B', 'C', 'D', 'E', 'F', 'G', 'P'],
        devices: <String, SimDevice>{
          'D': SimDevice.desktop,
          'P': SimDevice.iphone,
        },
      );
      final List<FriendsPhone> boxes = await w.mailboxesOf(w['A']);
      expect(boxes, hasLength(6));
      expect(boxes, isNot(contains(w['P'])));
    });
  });

  group('files', () {
    test('a file waits in the mailboxes and the friend gets it whole after '
        'the sender is gone', () async {
      final FriendsWorld w = await _withMailboxes(
        <String>['A', 'B', 'M1', 'M2'],
        'B',
        <String>['M1', 'M2'],
      );
      final Uint8List file = Uint8List.fromList(
        List<int>.generate(100 * 1000, (int i) => (i * 31 + 7) & 0xff),
      );
      await w.setOnline(w['B'], false);
      await w['A'].hub.sendLocalAttachment(
        peerAddress: w['B'].address,
        bytes: file,
        fileName: 'glosowka.m4a',
        mimeType: 'audio/mp4',
        type: ChatMessageType.voice,
        durationMs: 60000,
        sentAtMillis: w.now,
      );
      await w.settle();
      await w.until(
        () async =>
            (await w['M1'].relayStore.load())
                .heldBlobs[w['B'].address]
                ?.isNotEmpty ??
            false,
        reason: 'the mailboxes holding the file',
        within: const Duration(minutes: 5),
      );
      await w.advance(const Duration(seconds: 10));
      await w.setOnline(w['A'], false);

      await w.setOnline(w['B'], true);
      await w.until(
        () async => (await w['B'].thread(
          w['A'],
        )).any((ChatMessage m) => m.attachmentPath != null),
        reason: 'the file reaching B',
        within: const Duration(minutes: 5),
      );
      final ChatMessage got = (await w['B'].thread(
        w['A'],
      )).firstWhere((ChatMessage m) => m.attachmentPath != null);
      expect(got.attachmentSizeBytes, file.length);
      expect(
        await w['B'].container
            .read(mediaVaultProvider)
            .read(got.attachmentPath!),
        file,
      );
    });

    test('a file comes only from a holder that still has it: mailboxes that '
        'lost it deliver nothing (not a half message), the sender, who has '
        'it, brings it when it is back', () async {
      final FriendsWorld w = await _withMailboxes(
        <String>['A', 'B', 'M1', 'M2'],
        'B',
        <String>['M1', 'M2'],
      );
      final Uint8List file = Uint8List.fromList(
        List<int>.generate(100 * 1000, (int i) => (i * 17 + 3) & 0xff),
      );
      await w.setOnline(w['B'], false);
      await w['A'].hub.sendLocalAttachment(
        peerAddress: w['B'].address,
        bytes: file,
        fileName: 'glosowka.m4a',
        mimeType: 'audio/mp4',
        type: ChatMessageType.voice,
        durationMs: 60000,
        sentAtMillis: w.now,
      );
      await w.settle();
      await w.until(
        () async =>
            (await w['M1'].relayStore.load())
                .heldBlobs[w['B'].address]
                ?.isNotEmpty ??
            false,
        reason: 'the mailboxes holding the file',
        within: const Duration(minutes: 5),
      );
      await w.advance(const Duration(seconds: 10));
      await w.setOnline(w['A'], false);
      // Both mailboxes lose what they held (a wiped disk, a full phone).
      w['M1'].relayStore.blobChunks.clear();
      w['M2'].relayStore.blobChunks.clear();

      await w.setOnline(w['B'], true);
      await w.advance(const Duration(minutes: 10));
      expect(
        <ChatMessage>[
          for (final ChatMessage m in await w['B'].thread(w['A']))
            if (m.direction != ChatMessageDirection.system) m,
        ],
        isEmpty,
        reason: 'nobody that has the file is there',
      );

      // The sender is back and still has the file.
      await w.setOnline(w['A'], true);
      await w.until(
        () async => (await w['B'].thread(
          w['A'],
        )).any((ChatMessage m) => m.attachmentPath != null),
        reason: 'the file coming from the sender',
        within: const Duration(minutes: 10),
      );
      final ChatMessage got = (await w['B'].thread(
        w['A'],
      )).firstWhere((ChatMessage m) => m.attachmentPath != null);
      expect(
        await w['B'].container
            .read(mediaVaultProvider)
            .read(got.attachmentPath!),
        file,
      );
      await w.until(
        () async => (await w['A'].thread(w['B'])).any(
          (ChatMessage m) =>
              m.direction == ChatMessageDirection.outgoing &&
              m.deliveryState == ChatMessageDeliveryState.delivered,
        ),
        reason: 'the sender seeing the file delivered',
        within: const Duration(minutes: 10),
      );
    });
  });

  group('account recovery', () {
    test('a new phone gets the conversations back from the friend that holds '
        'the recovery copy; a photo comes back as a message without its '
        'file', () async {
      final FriendsWorld w = await FriendsWorld.create(<String>['A', 'B', 'C']);
      await w.send(w['A'], w['B'], 'cześć Bartek');
      await w.send(w['B'], w['A'], 'cześć Ala');
      await w.send(w['A'], w['B'], 'jak tam?');
      await w.send(w['A'], w['C'], 'pisz do mnie');
      await w['A'].hub.importSyncedMessage(
        w['B'].address,
        ChatMessage(
          id: 'p1',
          sender: 'self',
          text: '',
          sentAtMillis: w.now + 1000,
          direction: ChatMessageDirection.outgoing,
          deliveryState: ChatMessageDeliveryState.delivered,
          type: ChatMessageType.image,
          fileName: 'kot.jpg',
          attachmentSizeBytes: 4,
        ),
        bytes: Uint8List.fromList(<int>[1, 2, 3, 4]),
      );

      // Ala's account makes its copy; Bartek keeps it for her.
      final LedgerIdentity me = await LedgerIdentity.loadOrCreate(
        MemoryLedgerDisk(),
      );
      final CircleBackupService owner = CircleBackupService(
        transport: w['A'].appTransport,
        disk: MemoryLedgerDisk(),
        data: _CircleData(source: w['A']),
        identity: () => _identityOf(me),
        holders: () => <String>[w['B'].address],
        isInCircle: (_) => false,
        restoreCandidates: () => const <String>[],
        clock: () => w.now,
      );
      final CircleBackupService holder = CircleBackupService(
        transport: w['B'].appTransport,
        disk: MemoryLedgerDisk(),
        data: _CircleData(),
        identity: () => null,
        holders: () => const <String>[],
        isInCircle: (String account) => account == me.account,
        restoreCandidates: () => const <String>[],
        clock: () => w.now,
      );
      addTearDown(owner.stop);
      addTearDown(holder.stop);
      await holder.start();
      await owner.start();
      await w.until(() async {
        await owner.idle;
        await holder.idle;
        return holder.holder.kept.containsKey(me.account);
      }, reason: 'the friend keeping the copy');

      // Ala's phone is lost; the new one has the account key and asks the
      // friend named as a helper.
      final FriendsPhone fresh = await w.add('A2');
      final MemoryLedgerDisk freshDisk = MemoryLedgerDisk();
      final LedgerIdentity recovered = await LedgerIdentity.adoptAccount(
        freshDisk,
        me.accountKey!.seed,
      );
      await CircleBackupService.markRestore(
        freshDisk,
        helpers: <String>[w['B'].address],
        at: w.now,
      );
      final CircleBackupService restoring = CircleBackupService(
        transport: fresh.appTransport,
        disk: freshDisk,
        data: _CircleData(restoreInto: fresh),
        identity: () => _identityOf(recovered),
        holders: () => const <String>[],
        isInCircle: (_) => false,
        restoreCandidates: () => const <String>[],
        clock: () => w.now,
      );
      addTearDown(restoring.stop);
      await restoring.start();
      await w.until(() async {
        await restoring.idle;
        await holder.idle;
        return restoring.restore.value.phase == CircleBackupRestorePhase.done;
      }, reason: 'the recovery finishing');

      final List<ChatMessage> withBartek = await fresh.thread(w['B']);
      expect(
        <String>[
          for (final ChatMessage m in withBartek)
            if (m.direction != ChatMessageDirection.system) m.text,
        ],
        <String>['cześć Bartek', 'cześć Ala', 'jak tam?', ''],
      );
      final ChatMessage photo = withBartek.firstWhere(
        (ChatMessage m) => m.id == 'p1',
      );
      expect(photo.fileName, 'kot.jpg');
      expect(photo.hasAttachment, isFalse, reason: 'files are not in the copy');
      expect(photo.attachmentUnavailable, isTrue);
      expect(
        (await fresh.thread(
          w['C'],
        )).where((ChatMessage m) => m.direction != ChatMessageDirection.system),
        hasLength(1),
      );
    });
  });

  group('an account restored on a new phone', () {
    test('its friends know the new phone within a minute of it being online, '
        'though its first greetings were lost: they see it present and '
        'messages go both ways', () async {
      final FriendsWorld w = await FriendsWorld.create(<String>[
        'A',
        'B',
        'C',
      ], ledgers: true);
      final String account = w['A'].ledger!.account;
      expect(w['B'].accounts.accountOf(w['A'].address), account);

      // A's phone is lost; the account comes back on A2 (a new address),
      // whose node is down at first: its greetings go nowhere.
      final FriendsPhone a2 = await w.restoreOnNewDevice(
        w['A'],
        'A2',
        online: false,
      );
      expect(a2.ledger!.account, account);
      await w.advance(const Duration(minutes: 3));
      expect(w['B'].accounts.accountOf(a2.address), isNull);

      await w.setOnline(a2, true);
      await w.until(
        () async =>
            w['B'].accounts.accountOf(a2.address) == account &&
            w['C'].accounts.accountOf(a2.address) == account,
        within: const Duration(minutes: 1),
        reason: 'the friends knowing the restored phone as A',
      );

      // A2's ping is A's presence on B's phone; B's answer reaches A2.
      await w.ping(a2, w['B']);
      expect(
        w['B'].state.friendByAddress(w['A'].address)!.presence,
        PeerPresence.online,
      );
      expect(
        a2.state.friendByAddress(w['B'].address)!.presence,
        PeerPresence.online,
      );

      // Messages: from A2 into B's chat with A, and from B (writing to A
      // as it knows A) to A2.
      await w.send(a2, w['B'], 'wróciłem');
      await w.assertDelivered(w['B'], 'wróciłem', from: w['A']);
      await w.send(w['B'], w['A'], 'witaj z powrotem');
      await w.until(
        () async => (await a2.textsFrom(w['B'])).contains('witaj z powrotem'),
        reason: 'B\'s message reaching the restored phone',
      );
    });

    test('names and photos go both ways as soon as the friends know the new '
        'phone: a copy brings the friends back, not their profiles', () async {
      final FriendsWorld w = await FriendsWorld.create(<String>[
        'A',
        'B',
      ], ledgers: true);
      await w['B'].container
          .read(userProfileControllerProvider.notifier)
          .updateProfile(displayName: 'Bartek');
      await w.settle();

      final FriendsPhone a2 = await w.restoreOnNewDevice(
        w['A'],
        'A2',
        online: false,
      );
      expect(a2.state.peerProfileOf(w['B'].address), isNull);
      // The restore brings the person's own profile back.
      await a2.container
          .read(userProfileControllerProvider.notifier)
          .updateProfile(displayName: 'Ania');
      await w.setOnline(a2, true);

      await w.until(
        () async =>
            a2.state.peerProfileOf(w['B'].address)?.name == 'Bartek' &&
            w['B'].state.friendByAddress(w['A'].address)?.displayName == 'Ania',
        within: const Duration(minutes: 1),
        reason: 'the profiles crossing',
      );
      expect(
        a2.state.nameFor(a2.state.friendByAddress(w['B'].address)!),
        'Bartek',
      );
    });
  });

  group('the world itself', () {
    test('the same seed makes the same run, and hours pass without any '
        'real waiting', () async {
      Future<String> run() async {
        final FriendsWorld w = await FriendsWorld.create(<String>[
          'A',
          'B',
          'C',
        ], seed: 11);
        w.dropRate = 0.3;
        await w.setOnline(w['B'], false);
        await w.send(w['A'], w['B'], 'raz');
        await w.send(w['A'], w['C'], 'dwa');
        await w.advance(const Duration(hours: 6));
        return '${w.net.stats} ${w.now}';
      }

      final Stopwatch clock = Stopwatch()..start();
      final String first = await run();
      expect(await run(), first);
      expect(
        clock.elapsed,
        lessThan(const Duration(seconds: 60)),
        reason: 'twelve virtual hours, no real timers',
      );
    });
  });
}
