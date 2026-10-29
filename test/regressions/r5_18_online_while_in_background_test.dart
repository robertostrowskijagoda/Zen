// Owner report R5-#18 (28.10.2026, after 1.14.0): a friend shown online for a while although their app was in the background.
//
// docs/TESTING.md, "Field report -> regression test": the test that fails
// while the bug is there and passes once it is fixed replaces the skipped
// one below, under the same name prefix; skip only while the fix is not in.
//
// Fixed in peer_presence.dart / runtime_signal_module.dart (presence taken
// in the order it was told, 0fe709dd), runtime_signal_bridge.dart (the node
// hears "off screen" within the lifecycle event, 385110c2), the Go bridge's
// node_identity.go (the app's "on screen" lapses unless said again,
// b23e4620) with runtime_native_signal_transport.dart (3bc763a0),
// android_background_runtime.dart (8b810d10) and runtime_signal_module.dart
// (an iPhone asleep at once, 3a0a39d9); guarded by the tests below,
// test/presence_test.dart, test/runtime_signal_bridge_test.dart,
// test/runtime_node_owner_test.dart, test/android_background_runtime_test.dart
// and node_identity_test.go.
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/app/app.dart';
import 'package:zen/src/domain/friends/friend_profile.dart';
import 'package:zen/src/domain/friends/peer_presence.dart';
import 'package:zen/src/features/runtime/runtime_native_signal_transport.dart';
import 'package:zen/src/features/runtime/runtime_signal_module.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';
import 'package:zen/src/features/settings/app_settings.dart';
import 'package:zen/src/features/settings/app_settings_controller.dart';
import 'package:zen/src/features/settings/app_settings_store.dart';
import 'package:zen/src/features/social/friendship_book.dart';
import 'package:zen/src/features/social/social_hub_controller.dart';
import 'package:zen/src/features/social/social_hub_state.dart';

const String _ada = '200:1111:2222:3333:4444:5555:6666:7777';

/// The app unlocked on this phone with Ada among the friends, on [transport]
/// (and [runtime] for the node, when given).
Future<void> _pumpApp(
  WidgetTester tester,
  MemorySignalTransport transport, {
  RuntimeNodeRuntime? runtime,
}) async {
  final ValueNotifier<bool> reachable = ValueNotifier<bool>(true);
  addTearDown(reachable.dispose);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        signalTransportProvider.overrideWithValue(transport),
        appSettingsStoreProvider.overrideWithValue(
          MemoryAppSettingsStore(const AppSettings()),
        ),
        presenceAsleepOffScreenProvider.overrideWithValue(false),
        meshReachableProvider.overrideWithValue(reachable),
        if (runtime != null)
          runtimeNodeRuntimeProvider.overrideWithValue(runtime),
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
      child: const ZenRewriteApp(),
    ),
  );
  await tester.pumpAndSettle();
}

FriendProfile _adaIn(WidgetTester tester) => ProviderScope.containerOf(
  tester.element(find.byType(ZenRewriteApp)),
).read(socialHubControllerProvider).friends[_ada]!;

void main() {
  testWidgets('R5-#18: a friend whose Zen is in the background is not shown '
      'online, also when an older "online" comes after their "w tle"', (
    WidgetTester tester,
  ) async {
    final MemorySignalTransport transport = MemorySignalTransport();
    await _pumpApp(tester, transport);
    final int now = DateTime.now().millisecondsSinceEpoch;
    // `sq`: when the friend told it (their Zen sends it with every word).
    Future<void> hear(String type, String state, int told) async {
      await transport.injectIncoming(
        from: _ada,
        payload: <String, dynamic>{'type': type, 'state': state, 'sq': told},
      );
      await tester.pumpAndSettle();
    }

    // Ada leaves the screen; the answer she sent just before, held on the
    // way, comes after it. Before: the last frame to come won, and she
    // showed online until "online" ran out.
    await hear('away', 'background', now - 2000);
    await hear('pong', 'foreground', now - 5000);
    expect(_adaIn(tester).shownPresence, PeerPresence.background);

    // Back on her screen: what she tells next is taken.
    await hear('ping', 'foreground', now - 1000);
    expect(_adaIn(tester).shownPresence, PeerPresence.online);
  });

  testWidgets('R5-#18: closing Zen with "back" tells its node at once that it '
      'is off the screen', (WidgetTester tester) async {
    // Android ends the app's engine right after the last lifecycle events:
    // what waits for a later turn never runs, and the node went on telling
    // friends "online".
    final RuntimeNodeRuntime runtime = RuntimeNodeRuntime.preview();
    addTearDown(runtime.dispose);
    await _pumpApp(tester, MemorySignalTransport(), runtime: runtime);
    expect(runtime.owner.onScreen, isTrue);

    for (final AppLifecycleState state in <AppLifecycleState>[
      AppLifecycleState.inactive,
      AppLifecycleState.hidden,
      AppLifecycleState.paused,
      AppLifecycleState.detached,
    ]) {
      tester.binding.handleAppLifecycleStateChanged(state);
    }

    // No pump: the engine may be gone by then.
    expect(runtime.owner.onScreen, isFalse);
  });
}
