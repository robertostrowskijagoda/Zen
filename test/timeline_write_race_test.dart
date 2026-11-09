import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/domain/friends/friend_profile.dart';
import 'package:zen/src/domain/messages/chat_message.dart';
import 'package:zen/src/domain/signals/signal_queue_store.dart';
import 'package:zen/src/domain/signals/zen_signal.dart';
import 'package:zen/src/features/chat/message_timeline_store.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';
import 'package:zen/src/features/social/friendship_book.dart';
import 'package:zen/src/features/social/social_hub_controller.dart';
import 'package:zen/src/features/social/social_hub_state.dart';
import 'package:zen/src/features/social/social_snapshot_store.dart';

const String _ada = '200:1111:2222:3333:4444:5555:6666:7777';

/// A disk that takes a few milliseconds for every read and write, as a
/// phone's encrypted storage does.
final class _SlowDisk implements LedgerDisk {
  final MemoryLedgerDisk inner = MemoryLedgerDisk();

  Future<void> _pause() =>
      Future<void>.delayed(const Duration(milliseconds: 3));

  @override
  Future<Uint8List?> read(String key) async {
    await _pause();
    return inner.read(key);
  }

  @override
  Future<void> write(String key, Uint8List data) async {
    await _pause();
    await inner.write(key, data);
  }

  @override
  Future<void> delete(String key) async {
    await _pause();
    await inner.delete(key);
  }
}

ChatMessage _m(String id, int at, {String text = ''}) => ChatMessage(
  id: id,
  sender: 'self',
  text: text.isEmpty ? id : text,
  sentAtMillis: at,
  direction: ChatMessageDirection.outgoing,
);

void main() {
  group('applyTimelineChanges', () {
    final ChatMessage a = _m('a', 1);
    final ChatMessage b = _m('b', 2);
    final ChatMessage c = _m('c', 3);

    test('a message added since the read stays', () {
      final List<ChatMessage> before = <ChatMessage>[a, b];
      final List<ChatMessage> after = <ChatMessage>[
        a,
        b.copyWith(deliveryState: ChatMessageDeliveryState.delivered),
      ];
      final List<ChatMessage> out = applyTimelineChanges(
        <ChatMessage>[a, b, c],
        before,
        after,
      );
      expect(out.map((ChatMessage m) => m.id), <String>['a', 'b', 'c']);
      expect(out[1].deliveryState, ChatMessageDeliveryState.delivered);
    });

    test('what the caller removed goes, what it added comes in by time', () {
      final List<ChatMessage> out = applyTimelineChanges(
        <ChatMessage>[a, b, c],
        <ChatMessage>[a, b],
        <ChatMessage>[b, _m('x', 4)],
      );
      expect(out.map((ChatMessage m) => m.id), <String>['b', 'c', 'x']);
    });

    test('a message changed by someone else meanwhile keeps that change '
        'when the caller left it as it was', () {
      final ChatMessage read = a.copyWith(readAtMillis: 9);
      final List<ChatMessage> out = applyTimelineChanges(
        <ChatMessage>[read, b],
        <ChatMessage>[a, b],
        <ChatMessage>[a, b.copyWith(text: 'edited')],
      );
      expect(out.first.readAtMillis, 9);
      expect(out.last.text, 'edited');
    });

    test('a message deleted meanwhile is not brought back', () {
      final List<ChatMessage> out = applyTimelineChanges(
        <ChatMessage>[b],
        <ChatMessage>[a, b],
        <ChatMessage>[a, b.copyWith(text: 'edited')],
      );
      expect(out.map((ChatMessage m) => m.id), <String>['b']);
    });
  });

  for (int delay = 0; delay <= 30; delay += 2) {
    test(
      'a receipt coming in while a new message is sent keeps both ($delay ms)',
      () async {
        final MessageTimelineStore store = FileMessageTimelineStore.onDisk(
          _SlowDisk(),
        );
        final MemorySignalTransport transport = MemorySignalTransport();
        final ProviderContainer container = ProviderContainer(
          overrides: [
            signalQueueStoreProvider.overrideWithValue(
              MemorySignalQueueStore(),
            ),
            socialSnapshotStoreProvider.overrideWithValue(
              MemorySocialSnapshotStore(),
            ),
            messageTimelineStoreProvider.overrideWithValue(store),
            signalTransportProvider.overrideWithValue(transport),
            socialHubSeedProvider.overrideWithValue(
              SocialHubState.empty().copyWith(
                book: FriendshipBook.restore(
                  profiles: const <String, FriendProfile>{
                    _ada: FriendProfile(
                      address: _ada,
                      displayName: 'Ada',
                      status: FriendRelationshipStatus.accepted,
                    ),
                  },
                ),
              ),
            ),
          ],
        );
        addTearDown(container.dispose);
        await transport.start();
        final SocialHubController hub = container.read(
          socialHubControllerProvider.notifier,
        );
        final String first = await hub.sendLocalMessage(
          peerAddress: _ada,
          text: 'pierwsza',
        );
        // Ada's receipt for the first one, and a second one sent meanwhile.
        final Future<void> receipt = hub.receiveSignal(
          ZenSignal(
            type: ZenSignalType.ack,
            sender: _ada,
            messageId: first,
            content: 'message',
          ),
          receivedAtMillis: DateTime.now().millisecondsSinceEpoch,
        );
        await Future<void>.delayed(Duration(milliseconds: delay));
        final Future<String> second = hub.sendLocalMessage(
          peerAddress: _ada,
          text: 'druga',
        );
        await Future.wait(<Future<Object?>>[receipt, second]);
        await Future<void>.delayed(const Duration(milliseconds: 50));
        final List<String> texts = <String>[
          for (final ChatMessage m in await store.load(_ada)) m.text,
        ];
        expect(texts, <String>['pierwsza', 'druga']);
      },
    );
  }
}
