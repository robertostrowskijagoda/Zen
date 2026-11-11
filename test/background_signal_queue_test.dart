import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/domain/friends/friend_profile.dart';
import 'package:zen/src/domain/messages/chat_message.dart';
import 'package:zen/src/domain/runtime/lifecycle_snapshot.dart';
import 'package:zen/src/domain/signals/queued_signal.dart';
import 'package:zen/src/domain/signals/signal_queue_store.dart';
import 'package:zen/src/domain/signals/zen_signal.dart';
import 'package:zen/src/features/chat/message_timeline_store.dart';
import 'package:zen/src/features/runtime/runtime_system_notifications.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';
import 'package:zen/src/features/settings/app_settings_controller.dart';
import 'package:zen/src/features/settings/app_settings_store.dart';
import 'package:zen/src/features/social/friendship_book.dart';
import 'package:zen/src/features/social/social_hub_controller.dart';
import 'package:zen/src/features/social/social_hub_state.dart';
import 'package:zen/src/features/social/social_snapshot_store.dart';

import 'support/friends_world.dart';

/// The signals kept while Zen is away from the screen (the Android service
/// running, a computer in the tray), to be counted once it is back: no
/// files in them, no read receipts, and no more than a cap, past which a
/// chat's older copies are folded into a count.

const String _ada = 'ada.ygg';

LifecycleSnapshot _screen(int generation, {bool on = true}) =>
    LifecycleSnapshot(
      visibility: on
          ? AppVisibilityState.foregroundFocused
          : AppVisibilityState.background,
      generation: generation,
      capturedAtMillis: generation,
    );

void main() {
  test('messages received while the app is away are kept in the queue '
      'without their files (the chat has them)', () async {
    final FriendsWorld w = await FriendsWorld.create(<String>['A', 'B']);
    final FriendsPhone a = w['A'];
    final FriendsPhone b = w['B'];
    final SignalQueueStore queue = b.container.read(signalQueueStoreProvider);
    for (int i = 0; i < 6; i++) {
      final Uint8List photo = Uint8List.fromList(<int>[
        0xFF, 0xD8, 0xFF, 0xE0, //
        ...List<int>.generate(150 * 1000, (int j) => (j * 31 + i) & 0xff),
      ]);
      await a.hub.sendLocalAttachment(
        peerAddress: b.address,
        bytes: photo,
        fileName: 'zdjecie$i.jpg',
        mimeType: 'image/jpeg',
        type: ChatMessageType.image,
        sentAtMillis: w.now,
      );
      await w.deliver();
    }
    final List<QueuedSignal> pending = await queue.load();
    final int inlineChars = pending.fold<int>(
      0,
      (int sum, QueuedSignal q) => sum + (q.signal.attachmentData?.length ?? 0),
    );
    expect(pending, isNotEmpty);
    expect(inlineChars, 0);
    expect(
      (await b.thread(a)).where((ChatMessage m) => m.attachmentPath != null),
      hasLength(6),
    );
    // Back on the screen: all six counted as unread.
    await b.hub.setLifecycle(_screen(20));
    expect(b.state.friendByAddress(a.address)?.unreadCount, 6);
  });

  test('a read receipt that comes while the app is away is applied and '
      'leaves no copy in the queue', () async {
    final FriendsWorld w = await FriendsWorld.create(<String>['A', 'B']);
    final FriendsPhone a = w['A'];
    final FriendsPhone b = w['B'];
    await w.send(b, a, 'Przeczytasz?');
    await w.deliver();
    await a.hub.setLifecycle(_screen(30));
    await a.hub.enterConversation(b.address);
    await w.deliver();
    final ChatMessage mine = (await b.thread(
      a,
    )).singleWhere((ChatMessage m) => m.isOutgoing && m.text == 'Przeczytasz?');
    expect(mine.readAtMillis, isNotNull);
    final List<QueuedSignal> pending = await b.container
        .read(signalQueueStoreProvider)
        .load();
    expect(
      pending.where(
        (QueuedSignal q) => q.signal.type == ZenSignalType.messageRead,
      ),
      isEmpty,
    );
  });

  test('past its cap the queue folds a chat\'s older messages into a count: '
      'every one is still counted as unread', () async {
    final MemorySignalQueueStore queue = MemorySignalQueueStore();
    final ProviderContainer container = ProviderContainer(
      overrides: [
        ...buildAppSettingsProviderOverrides(
          store: MemoryAppSettingsStore(),
          hydrationEnabled: false,
        ),
        signalTransportProvider.overrideWithValue(MemorySignalTransport()),
        signalQueueStoreProvider.overrideWithValue(queue),
        socialSnapshotStoreProvider.overrideWithValue(
          MemorySocialSnapshotStore(),
        ),
        messageTimelineStoreProvider.overrideWithValue(
          MemoryMessageTimelineStore(),
        ),
        runtimeSystemNotificationServiceProvider.overrideWithValue(
          MemoryRuntimeSystemNotificationService(),
        ),
        socialHubSeedProvider.overrideWithValue(
          SocialHubState.empty(lifecycle: _screen(1, on: false)).copyWith(
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
    final SocialHubController hub = container.read(
      socialHubControllerProvider.notifier,
    );
    await hub.whenHydrated;
    const int sent = kMaxQueuedSignals + 25;
    final int start = DateTime.now().millisecondsSinceEpoch;
    for (int i = 0; i < sent; i++) {
      await hub.receiveSignal(
        ZenSignal(
          type: ZenSignalType.message,
          sender: _ada,
          messageId: 'msg-$i',
          content: 'Wiadomość $i',
          sentAtMillis: start + i,
        ),
        receivedAtMillis: start + i,
      );
    }
    final List<QueuedSignal> pending = await queue.load();
    expect(pending.length, kMaxQueuedSignals);
    expect(
      pending.fold<int>(0, (int sum, QueuedSignal q) => sum + q.count),
      sent,
    );
    await hub.setLifecycle(_screen(2));
    final FriendProfile ada = hub.state.friendByAddress(_ada)!;
    expect(ada.unreadCount, sent);
    expect(ada.lastMessagePreview, 'Wiadomość ${sent - 1}');
  });
}
