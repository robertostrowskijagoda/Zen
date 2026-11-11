import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/domain/friends/friend_profile.dart';
import 'package:zen/src/domain/runtime/lifecycle_snapshot.dart';
import 'package:zen/src/domain/signals/signal_queue_store.dart';
import 'package:zen/src/domain/signals/zen_signal.dart';
import 'package:zen/src/features/chat/message_timeline_store.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';
import 'package:zen/src/features/settings/app_settings_controller.dart';
import 'package:zen/src/features/settings/app_settings_store.dart';
import 'package:zen/src/features/social/friendship_book.dart';
import 'package:zen/src/features/social/social_hub_controller.dart';
import 'package:zen/src/features/social/social_hub_state.dart';
import 'package:zen/src/features/social/social_snapshot_store.dart';

import 'support/friends_world.dart';

/// "pisze…": shown while the friend types, gone when they stop, whatever
/// this app was doing when the "stopped" came, and gone by itself a few
/// seconds after their last word when no "stopped" comes at all.

const String _ada = 'ada.ygg';

LifecycleSnapshot _screen(int generation, {bool on = true}) =>
    LifecycleSnapshot(
      visibility: on
          ? AppVisibilityState.foregroundFocused
          : AppVisibilityState.background,
      generation: generation,
      capturedAtMillis: generation,
    );

Future<SocialHubController> _hub({required Duration shownFor}) async {
  final ProviderContainer container = ProviderContainer(
    overrides: [
      ...buildAppSettingsProviderOverrides(
        store: MemoryAppSettingsStore(),
        hydrationEnabled: false,
      ),
      typingShownForProvider.overrideWithValue(shownFor),
      signalTransportProvider.overrideWithValue(MemorySignalTransport()),
      signalQueueStoreProvider.overrideWithValue(MemorySignalQueueStore()),
      socialSnapshotStoreProvider.overrideWithValue(
        MemorySocialSnapshotStore(),
      ),
      messageTimelineStoreProvider.overrideWithValue(
        MemoryMessageTimelineStore(),
      ),
      socialHubSeedProvider.overrideWithValue(
        SocialHubState.empty(lifecycle: _screen(1)).copyWith(
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
  await hub.setLifecycle(_screen(2));
  return hub;
}

bool _typing(SocialHubController hub) =>
    hub.state.friendByAddress(_ada)?.isTyping ?? false;

Future<void> _says(SocialHubController hub, {required bool typing}) =>
    hub.receiveSignal(
      ZenSignal(type: ZenSignalType.typing, sender: _ada, isTyping: typing),
    );

void main() {
  test('"stopped typing" that comes while the app is in the background '
      'is taken: "pisze..." is gone on the return', () async {
    final FriendsWorld w = await FriendsWorld.create(<String>['A', 'B']);
    final FriendsPhone a = w['A'];
    final FriendsPhone b = w['B'];
    await b.hub.setLifecycle(_screen(10));
    await a.hub.sendTypingState(peerAddress: b.address, isTyping: true);
    await w.settle();
    expect(b.state.friendByAddress(a.address)?.isTyping, isTrue);
    // B switches to another app for a moment; A clears the composer.
    await b.hub.setLifecycle(_screen(11, on: false));
    await a.hub.sendTypingState(peerAddress: b.address, isTyping: false);
    await w.settle();
    await b.hub.setLifecycle(_screen(12));
    await w.advance(const Duration(hours: 1));
    expect(b.state.friendByAddress(a.address)?.isTyping, isFalse);
  });

  test('"pisze..." goes by itself when no "stopped" comes, and stays while '
      'the friend keeps saying it', () async {
    final SocialHubController hub = await _hub(
      shownFor: const Duration(milliseconds: 150),
    );
    await _says(hub, typing: true);
    expect(_typing(hub), isTrue);
    // Refreshed (as the friend's app does every 2.2 s while they type).
    for (int i = 0; i < 4; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 60));
      await _says(hub, typing: true);
    }
    expect(_typing(hub), isTrue);
    // Their app went away without a word.
    await Future<void>.delayed(const Duration(milliseconds: 400));
    expect(_typing(hub), isFalse);
  });

  test('"stopped typing" ends it at once', () async {
    final SocialHubController hub = await _hub(
      shownFor: const Duration(seconds: 30),
    );
    await _says(hub, typing: true);
    expect(_typing(hub), isTrue);
    await _says(hub, typing: false);
    expect(_typing(hub), isFalse);
  });
}
