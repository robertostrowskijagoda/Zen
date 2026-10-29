// Owner report R5-#15 (28.10.2026, after 1.14.0): status "?" after a restart although the friend\'s service was running.
//
// docs/TESTING.md, "Field report -> regression test": the test that fails
// while the bug is there and passes once it is fixed replaces the skipped
// one below, under the same name prefix; skip only while the fix is not in.
//
// Fixed in runtime_signal_module.dart (the first pings of a start are
// marked fresh and sent again within the first minute) and
// locked_receiver.dart (a locked friend answers a fresh ping at once),
// 0fe709dd, and the first contact after a restart in the Go bridge (R5-F5);
// guarded by the tests below and test/presence_test.dart ("after a start,
// a locked friend who answered just before it shows "w tle" within
// seconds …").
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/app/app.dart';
import 'package:zen/src/domain/friends/friend_profile.dart';
import 'package:zen/src/domain/friends/peer_presence.dart';
import 'package:zen/src/features/runtime/locked_presence.dart';
import 'package:zen/src/features/runtime/locked_receiver.dart';
import 'package:zen/src/features/runtime/runtime_signal_module.dart';
import 'package:zen/src/features/runtime/runtime_system_notifications.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';
import 'package:zen/src/features/security/background_keys.dart';
import 'package:zen/src/features/security/sealed_inbox.dart';
import 'package:zen/src/features/settings/app_settings.dart';
import 'package:zen/src/features/settings/app_settings_controller.dart';
import 'package:zen/src/features/settings/app_settings_store.dart';
import 'package:zen/src/features/social/friendship_book.dart';
import 'package:zen/src/features/social/social_hub_controller.dart';
import 'package:zen/src/features/social/social_hub_state.dart';

const String _ada = '200:1111:2222:3333:4444:5555:6666:7777';
const String _me = '200:1111:2222:3333:4444:5555:6666:1234';
const int _day = 24 * 60 * 60 * 1000;

void main() {
  test('R5-#15: after a restart a friend\'s presence settles while their '
      'Zen runs: their locked phone answers the first ping of the new '
      'start at once', () async {
    int clock = _day;
    final MemorySignalTransport air = MemorySignalTransport();
    // Ada's locked phone: her Android service answering pings, with this
    // phone ([_me]) among the friends who may see "w tle".
    final LockedReceiver adaPhone = LockedReceiver(
      transport: air,
      capability: BackgroundCapability.fromDraft(
        BackgroundCapabilityDraft(
          inboxPublicKey: Uint8List(32),
          friends: const <String>{_me},
        ),
        backgroundKey: Uint8List.fromList(List<int>.filled(32, 7)),
      ),
      inbox: SealedInboxWriter(
        file: File('${Directory.systemTemp.path}/zen-r5-15-unused.inbox'),
        recipientPublicKey: Uint8List(32),
      ),
      notices: MemoryRuntimeSystemNotificationService(),
      presence: const LockedPresenceKit(shownTo: <String>{_me}),
      mailboxPollInterval: Duration.zero,
      now: () => clock,
    );
    await adaPhone.start();
    addTearDown(adaPhone.stop);
    int pongs() =>
        air.sentSignals.where((e) => e.payload['type'] == 'pong').length;
    Future<void> ping({bool fresh = false}) => adaPhone.handleFrame(
      SignalTransportFrame(
        from: _me,
        payload: <String, dynamic>{
          'type': 'ping',
          if (fresh) kPresenceFreshKey: true,
        },
        receivedAtMillis: clock,
      ),
    );

    // This phone's Zen pinged her and she answered; then it started again
    // a minute later, and that answer went to the app that is gone.
    await ping();
    expect(pongs(), 1);
    clock += 60 * 1000;

    // Before: a locked phone answers once every few minutes, so this
    // start showed "?" for minutes although her service ran.
    await ping(fresh: true);
    expect(pongs(), 2);
    expect(air.sentSignals.last.payload['state'], 'background');
  });

  testWidgets('R5-#15: the first pings of a start ask for an answer at once', (
    WidgetTester tester,
  ) async {
    final MemorySignalTransport transport = MemorySignalTransport();
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

    final List<Map<String, dynamic>> pings = <Map<String, dynamic>>[
      for (final e in transport.sentSignals)
        if (e.remoteAddress == _ada && e.payload['type'] == 'ping') e.payload,
    ];
    expect(pings, isNotEmpty);
    expect(pings.first[kPresenceFreshKey], isTrue);
  });
}
