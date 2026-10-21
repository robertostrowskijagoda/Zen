import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/domain/messages/chat_message.dart';
import 'package:zen/src/domain/signals/signal_queue_store.dart';
import 'package:zen/src/domain/signals/zen_signal.dart';
import 'package:zen/src/features/chat/message_timeline_store.dart';
import 'package:zen/src/features/chat/stranger_chats.dart';
import 'package:zen/src/features/feed/mini_profile_tag.dart';
import 'package:zen/src/features/meet/intro/gate_route.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';
import 'package:zen/src/features/social/social_hub_controller.dart';
import 'package:zen/src/features/social/social_hub_state.dart';
import 'package:zen/src/features/social/social_snapshot_store.dart';

const String _zed = '200:1111:2222:3333:4444:5555:6666:7777';

void main() {
  group('the book', () {
    test('who may write first', () async {
      bool fof = false;
      final StrangerChatBook book = StrangerChatBook(
        disk: MemoryLedgerDisk(),
        isFriendOfFriend: (String _) => fof,
      );
      await book.load();
      expect(book.from, StrangerMessagesFrom.friendsOfFriends);
      expect(book.admits(_zed), isFalse);
      fof = true;
      expect(book.admits(_zed), isTrue);
      await book.setFrom(StrangerMessagesFrom.nobody);
      expect(book.admits(_zed), isFalse);
      await book.setFrom(StrangerMessagesFrom.everyone);
      fof = false;
      expect(book.admits(_zed), isTrue);
    });

    test(
      'three messages before an answer, then the conversation opens',
      () async {
        final MemoryLedgerDisk disk = MemoryLedgerDisk();
        final StrangerChatBook book = StrangerChatBook(disk: disk);
        await book.load();
        for (int i = 0; i < kStrangerMessagesBeforeReply; i++) {
          expect(book.refusalToSend(_zed, 'hej'), isNull);
          await book.noteSent(_zed, 'hej $i', name: 'Zed');
        }
        expect(book.refusalToSend(_zed, 'hej'), isNotNull);
        expect(book.refusalToSend('200::1', 'x' * 2000), isNotNull);
        // Their answer always comes in and opens the conversation.
        expect(book.admits(_zed), isTrue);
        await book.noteReceived(
          _zed,
          'cześć',
          mini: const MiniProfileTag(name: 'Zed'),
        );
        expect(book.chatWith(_zed)!.open, isTrue);
        expect(book.refusalToSend(_zed, 'hej'), isNull);

        // Kept on disk.
        final StrangerChatBook again = StrangerChatBook(disk: disk);
        await again.load();
        expect(again.chatWith(_zed)!.open, isTrue);
        expect(again.conversations.single.name, 'Zed');
      },
    );

    test('a request stops at three until this person answers', () async {
      final StrangerChatBook book = StrangerChatBook(disk: MemoryLedgerDisk());
      await book.setFrom(StrangerMessagesFrom.everyone);
      for (int i = 0; i < kStrangerMessagesBeforeReply; i++) {
        expect(book.admits(_zed), isTrue);
        await book.noteReceived(
          _zed,
          'hej $i',
          mini: const MiniProfileTag(name: 'Zed'),
        );
      }
      expect(book.requests.single.unread, kStrangerMessagesBeforeReply);
      expect(book.admits(_zed), isFalse);
      await book.noteSent(_zed, 'cześć');
      expect(book.requests, isEmpty);
      expect(book.admits(_zed), isTrue);
    });
  });

  group('the price of a first message', () {
    test('0 is free; with a price nobody gets in unpaid; a payment or a '
        'friend\'s gate lets in, also when closed', () async {
      final MemoryLedgerDisk disk = MemoryLedgerDisk();
      int now = 1000000;
      int changed = 0;
      final StrangerChatBook book = StrangerChatBook(
        disk: disk,
        now: () => now,
        onPriceChanged: () => changed++,
      );
      await book.setFrom(StrangerMessagesFrom.everyone);
      expect(book.priceFrom(_zed), 0);
      expect(book.admits(_zed), isTrue);
      await book.setPrice(500);
      expect(changed, 2);
      expect(book.priceFrom(_zed), 500);
      expect(book.admits(_zed), isFalse);
      await book.letIn(_zed, paid: true);
      expect(book.passFrom(_zed)!.paid, isTrue);
      expect(book.admits(_zed), isTrue);
      expect(strangerPriceLevels(book), <String, int>{
        'friend': 0,
        'fof': 500,
        'stranger': 500,
      });

      // Closed ("Nikt"): nobody may write first …
      const String other = '200::2';
      await book.setFrom(StrangerMessagesFrom.nobody);
      expect(book.priceFrom(other), isNull);
      expect(book.admits(other), isFalse);
      expect(strangerPriceLevels(book), <String, int>{'friend': 0});
      // … but someone a friend opened a gate for does.
      await book.letIn(other, paid: false, via: '200::3');
      expect(book.admits(other), isTrue);
      expect(
        book.passFrom(other)!.via,
        PeerShareCodec.normalizeAddress('200::3'),
      );

      // Kept on disk; a month later the passes are gone.
      final StrangerChatBook again = StrangerChatBook(
        disk: disk,
        now: () => now,
      );
      await again.load();
      expect(again.price, 500);
      expect(again.passFrom(other), isNotNull);
      now += kStrangerPassLife.inMilliseconds + 1;
      expect(again.passFrom(other), isNull);
      expect(again.admits(other), isFalse);
    });

    test('writing first: as the other side published it — closed, a price, '
        'free; once paid or through a gate, the usual limit', () async {
      DirectTerms terms = const DirectTerms.unknown();
      final StrangerChatBook book = StrangerChatBook(
        disk: MemoryLedgerDisk(),
        termsOf: (String _) => terms,
      );
      await book.load();
      expect(book.refusalToSend(_zed, 'hej'), isNull);
      terms = const DirectTerms.closed();
      expect(book.refusalToSend(_zed, 'hej'), contains('nie przyjmuje'));
      terms = const DirectTerms.price(300, payable: true);
      expect(book.refusalToSend(_zed, 'hej'), contains('3 pkt'));
      terms = const DirectTerms.price(0);
      expect(book.refusalToSend(_zed, 'hej'), isNull);

      // Paid once: then up to three before an answer, no price per message.
      terms = const DirectTerms.price(300, payable: true);
      await book.mayWrite(_zed, paid: true);
      for (int i = 0; i < kStrangerMessagesBeforeReply; i++) {
        expect(book.refusalToSend(_zed, 'hej'), isNull);
        await book.noteSent(_zed, 'hej $i');
      }
      expect(book.refusalToSend(_zed, 'hej'), contains('Poczekaj'));
    });
  });

  test('the day\'s budget of new strangers survives a restart', () async {
    final MemoryLedgerDisk disk = MemoryLedgerDisk();
    int now = 1000000;
    StrangerChatBook open() => StrangerChatBook(disk: disk, now: () => now);
    String stranger(int i) =>
        '200:1111:2222:3333:4444:5555:6666:${(0x1000 + i).toRadixString(16)}';
    final StrangerChatBook book = open();
    await book.setFrom(StrangerMessagesFrom.everyone);
    for (int i = 0; i < kStrangerFirstContactsPerDay; i++) {
      expect(book.admits(stranger(i)), isTrue);
      await book.noteReceived(
        stranger(i),
        'hej',
        mini: const MiniProfileTag(name: 'Obcy'),
      );
    }
    final String late = stranger(kStrangerFirstContactsPerDay);
    expect(book.admits(late), isFalse);

    // Restarting the app does not give a new budget ...
    final StrangerChatBook again = open();
    await again.load();
    expect(again.admits(late), isFalse);
    // ... and neither does dropping their conversations.
    await again.forget(stranger(0));
    expect(again.admits(late), isFalse);

    // A day later it does.
    now += 25 * 3600 * 1000;
    expect(again.admits(late), isTrue);
  });

  group('in the chats', () {
    late MemorySignalTransport transport;
    late MemoryMessageTimelineStore timelines;
    late StrangerChatBook book;
    late ProviderContainer container;

    setUp(() async {
      transport = MemorySignalTransport();
      timelines = MemoryMessageTimelineStore();
      book = StrangerChatBook(disk: MemoryLedgerDisk());
      container = ProviderContainer(
        overrides: [
          signalQueueStoreProvider.overrideWithValue(MemorySignalQueueStore()),
          socialSnapshotStoreProvider.overrideWithValue(
            MemorySocialSnapshotStore(),
          ),
          messageTimelineStoreProvider.overrideWithValue(timelines),
          signalTransportProvider.overrideWithValue(transport),
          socialHubSeedProvider.overrideWithValue(SocialHubState.empty()),
          strangerChatsProvider.overrideWithValue(book),
        ],
      );
      addTearDown(container.dispose);
      await transport.start();
    });

    SocialHubController hub() =>
        container.read(socialHubControllerProvider.notifier);

    ZenSignal message(String id, {Map<String, dynamic>? mini}) => ZenSignal(
      type: ZenSignalType.message,
      sender: _zed,
      messageId: id,
      content: 'Cześć, tu Zed',
      miniProfile: mini,
    );

    test('a message from someone who is not a friend comes in with their '
        'mini-profile, within the limits', () async {
      await book.setFrom(StrangerMessagesFrom.everyone);
      // Without a mini-profile: dropped.
      await hub().receiveSignal(message('m0'), receivedAtMillis: 1);
      expect(await timelines.load(_zed), isEmpty);

      for (int i = 1; i <= kStrangerMessagesBeforeReply + 1; i++) {
        await hub().receiveSignal(
          message('m$i', mini: <String, dynamic>{'n': 'Zed'}),
          receivedAtMillis: 1 + i,
        );
      }
      final List<ChatMessage> thread = await timelines.load(_zed);
      expect(thread, hasLength(kStrangerMessagesBeforeReply));
      expect(book.requests.single.name, 'Zed');
      expect(
        container.read(socialHubControllerProvider).friendByAddress(_zed),
        isNull,
        reason: 'a message does not make anyone a friend',
      );
    });

    test('nobody may write first: nothing comes in', () async {
      await book.setFrom(StrangerMessagesFrom.nobody);
      await hub().receiveSignal(
        message('m1', mini: <String, dynamic>{'n': 'Zed'}),
        receivedAtMillis: 1,
      );
      expect(await timelines.load(_zed), isEmpty);
    });

    test('writing to someone who is not a friend sends the mini-profile and '
        'stops at the limit', () async {
      for (int i = 0; i < kStrangerMessagesBeforeReply; i++) {
        await hub().sendLocalMessage(
          peerAddress: _zed,
          text: 'Hej $i',
          sentAtMillis: 10 + i,
        );
      }
      final Map<String, dynamic> sent = transport.sentSignals
          .lastWhere(
            (({String remoteAddress, Map<String, dynamic> payload}) s) =>
                s.payload['type'] == 'message',
          )
          .payload;
      expect(sent['mp'], isA<Map<String, dynamic>>());
      await expectLater(
        hub().sendLocalMessage(peerAddress: _zed, text: 'Hej?'),
        throwsA(isA<StrangerMessageRefused>()),
      );
      expect(
        container.read(socialHubControllerProvider).friendByAddress(_zed),
        isNull,
      );

      // Their answer comes in even though they may not write first, and
      // the conversation opens.
      await book.setFrom(StrangerMessagesFrom.nobody);
      await hub().receiveSignal(
        message('r1', mini: <String, dynamic>{'n': 'Zed'}),
        receivedAtMillis: 50,
      );
      expect(book.chatWith(_zed)!.open, isTrue);
      await hub().sendLocalMessage(peerAddress: _zed, text: 'Super');
    });
  });
}
