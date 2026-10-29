import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/app/persistent_stores.dart';
import 'package:zen/src/core/storage/binary_store.dart';
import 'package:zen/src/domain/friends/friend_profile.dart';
import 'package:zen/src/domain/messages/chat_message.dart';
import 'package:zen/src/domain/runtime/lifecycle_snapshot.dart';
import 'package:zen/src/domain/signals/queued_signal.dart';
import 'package:zen/src/domain/signals/zen_signal.dart';
import 'package:zen/src/features/runtime/runtime_route_intent.dart';
import 'package:zen/src/features/settings/app_settings.dart';
import 'package:zen/src/features/social/friendship_book.dart';
import 'package:zen/src/features/social/social_hub_state.dart';

void main() {
  test('persistent store builder returns working file-backed stores', () async {
    final Directory tempDir = await Directory.systemTemp.createTemp(
      'zen-persistent-stores-',
    );
    addTearDown(() => tempDir.delete(recursive: true));

    final ZenPersistentStores stores = buildZenPersistentStoresForDirectory(
      tempDir,
      codec: BinaryCodec(compressor: const _PassThroughCompressor()),
    );

    await stores.signalQueueStore.save(<QueuedSignal>[
      const QueuedSignal(
        id: 'q-1',
        signal: ZenSignal(
          type: ZenSignalType.friendAccept,
          sender: 'ada.ygg',
          displayName: 'Ada',
        ),
        receivedAtMillis: 1,
      ),
    ]);
    await stores.socialSnapshotStore.save(
      SocialHubState(
        lifecycle: const LifecycleSnapshot(
          visibility: AppVisibilityState.foregroundFocused,
          generation: 2,
          capturedAtMillis: 3,
        ),
        book: FriendshipBook.restore(
          profiles: const <String, FriendProfile>{
            'ada.ygg': FriendProfile(
              address: 'ada.ygg',
              displayName: 'Ada',
              status: FriendRelationshipStatus.accepted,
            ),
          },
        ),
        inbox: const <InboxEntry>[
          InboxEntry(
            id: 'i-1',
            type: InboxEntryType.friendAccepted,
            title: 'Ada zaakceptował(a) zaproszenie',
            body: 'Czat jest gotowy.',
            createdAtMillis: 3,
            routeKey: 'zen://inbox',
            peerAddress: 'ada.ygg',
          ),
        ],
        pendingSignalCount: 1,
        backgroundAlerts: const <InboxEntry>[],
        pendingLaunchIntent: RuntimeRouteIntent.inbox(id: 'intent-1'),
      ),
    );
    await stores.messageTimelineStore.save('ada.ygg', <ChatMessage>[
      const ChatMessage(
        id: 'm-1',
        sender: 'ada.ygg',
        text: 'Hej',
        sentAtMillis: 4,
        direction: ChatMessageDirection.incoming,
      ),
    ]);
    await stores.appSettingsStore.save(
      const AppSettings(inboxLimitMb: 64, autoCleanupDays: 21),
    );

    final List<QueuedSignal> queue = await stores.signalQueueStore.load();
    final SocialHubState? snapshot = await stores.socialSnapshotStore.load();
    final List<ChatMessage> thread = await stores.messageTimelineStore.load(
      'ada.ygg',
    );
    final AppSettings? settings = await stores.appSettingsStore.load();

    expect(queue.single.signal.type, ZenSignalType.friendAccept);
    expect(snapshot, isNotNull);
    expect(
      snapshot!.friends['ada.ygg']?.status,
      FriendRelationshipStatus.accepted,
    );
    expect(thread.single.text, 'Hej');
    expect(settings!.inboxLimitMb, 64);
    expect(settings.autoCleanupDays, 21);

    final Directory dataDirectory = Directory(
      '${tempDir.path}${Platform.pathSeparator}data',
    );
    expect(
      File(
        '${dataDirectory.path}${Platform.pathSeparator}signals${Platform.pathSeparator}pending.zenbin',
      ).existsSync(),
      isTrue,
    );
    expect(
      File(
        '${dataDirectory.path}${Platform.pathSeparator}social${Platform.pathSeparator}hub.zenbin',
      ).existsSync(),
      isTrue,
    );
    expect(dataDirectory.existsSync(), isTrue);
  });
}

final class _PassThroughCompressor implements BinaryCompressor {
  const _PassThroughCompressor();

  @override
  Future<Uint8List?> compress(Uint8List payload, int level) async => payload;

  @override
  Future<Uint8List?> decompress(Uint8List payload) async => payload;
}
