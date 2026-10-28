import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/app/app.dart';
import 'package:zen/src/app/peer_version.dart';
import 'package:zen/src/app/theme/zen_ui.dart';
import 'package:zen/src/core/storage/binary_store.dart';
import 'package:zen/src/domain/friends/friend_profile.dart';
import 'package:zen/src/domain/friends/peer_presence.dart';
import 'package:zen/src/domain/signals/signal_queue_store.dart';
import 'package:zen/src/features/chat/message_timeline_store.dart';
import 'package:zen/src/features/chat/presentation/conversation_screen.dart';
import 'package:zen/src/features/chat/presentation/presence_label.dart';
import 'package:zen/src/features/ledger/audience_keys.dart';
import 'package:zen/src/features/ledger/friend_level_lookup.dart';
import 'package:zen/src/features/runtime/locked_presence.dart';
import 'package:zen/src/features/runtime/runtime_signal_module.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';
import 'package:zen/src/features/settings/app_settings.dart';
import 'package:zen/src/features/settings/app_settings_controller.dart';
import 'package:zen/src/features/settings/app_settings_store.dart';
import 'package:zen/src/features/social/social_hub_controller.dart';
import 'package:zen/src/features/social/social_hub_state.dart';
import 'package:zen/src/features/social/social_snapshot_store.dart';

const String _ada = '200:1111:2222:3333:4444:5555:6666:7777';
const String _bob = '200:1111:2222:3333:4444:5555:6666:8888';

const int _minute = 60 * 1000;
const int _hour = 60 * _minute;
const int _day = 24 * _hour;

void main() {
  group('what a frame says', () {
    test('the three states, and nothing when the state is missing', () {
      expect(
        PresenceReport.fromPayload(<String, dynamic>{
          'state': 'foreground',
        }).presence,
        PeerPresence.online,
      );
      expect(
        PresenceReport.fromPayload(<String, dynamic>{
          'state': 'background',
        }).presence,
        PeerPresence.background,
      );
      final PresenceReport asleep = PresenceReport.fromPayload(
        <String, dynamic>{'state': 'asleep'},
      );
      expect(asleep.presence, PeerPresence.offline);
      expect(asleep.reachable, isFalse);
      for (final Map<String, dynamic> payload in <Map<String, dynamic>>[
        <String, dynamic>{'type': 'ping'},
        <String, dynamic>{'state': 'dancing', 'lo': 5},
        <String, dynamic>{'state': 3},
      ]) {
        final PresenceReport report = PresenceReport.fromPayload(payload);
        expect(report.presence, PeerPresence.hidden);
        expect(report.openedAgo, isNull);
        expect(report.reachable, isTrue, reason: 'a bare pong still answers');
      }
    });

    test('"last open" is read in seconds, never negative or endless', () {
      PresenceReport read(Object? lo) => PresenceReport.fromPayload(
        <String, dynamic>{'state': 'background', 'lo': lo},
      );
      expect(read(90).openedAgo, const Duration(seconds: 90));
      expect(read(90).lastOpenedAt(100000), 10000);
      expect(read(-1).openedAgo, isNull);
      expect(read('90').openedAgo, isNull);
      expect(read(null).lastOpenedAt(100000), 0);
      expect(read(1 << 40).openedAgo, kPresenceOpenedMax);
      // Longer ago than the clock goes back: not before 1970.
      expect(read(500).lastOpenedAt(1000), 0);
    });

    test('the fields this device sends', () {
      expect(
        presenceFields(own: PeerPresence.online, openedAgo: Duration.zero),
        <String, dynamic>{'state': 'foreground', 'lo': 0},
      );
      expect(
        presenceFields(
          own: PeerPresence.background,
          openedAgo: const Duration(minutes: 3),
        ),
        <String, dynamic>{'state': 'background', 'lo': 180},
      );
      expect(presenceFields(own: PeerPresence.offline), <String, dynamic>{
        'state': 'asleep',
      });
      expect(presenceFields(own: PeerPresence.hidden), isEmpty);
      // Read back the same.
      final PresenceReport back = PresenceReport.fromPayload(
        presenceFields(
          own: PeerPresence.background,
          openedAgo: const Duration(minutes: 3),
        ),
      );
      expect(back.presence, PeerPresence.background);
      expect(back.openedAgo, const Duration(minutes: 3));
    });
  });

  group('expiry', () {
    PeerPresence at(PeerPresence presence, int age) => presenceAt(
      presence: presence,
      presenceAtMillis: 1000,
      nowMillis: 1000 + age,
      foregroundFor: kPresenceForegroundFor,
      backgroundFor: kPresenceOfflineAfter,
    );

    test('"online" expires quickly, "w tle" lasts longer', () {
      final int fg = kPresenceForegroundFor.inMilliseconds;
      final int bg = kPresenceOfflineAfter.inMilliseconds;
      expect(at(PeerPresence.online, fg - 1), PeerPresence.online);
      expect(at(PeerPresence.online, fg), PeerPresence.offline);
      expect(at(PeerPresence.background, fg), PeerPresence.background);
      expect(at(PeerPresence.background, bg - 1), PeerPresence.background);
      expect(at(PeerPresence.background, bg), PeerPresence.offline);
      expect(at(PeerPresence.hidden, 100 * bg), PeerPresence.hidden);
      expect(at(PeerPresence.offline, 0), PeerPresence.offline);
    });

    test('a locked friend answering every other ping stays "w tle"', () {
      // A locked phone answers one contact at most every 4 min; pings go
      // every 2.5 min, so an answer comes every 5 min — even with one of
      // them lost, the next one comes in time.
      final int everyOther = (kPresencePingInterval * 2).inMilliseconds;
      expect(
        at(PeerPresence.background, 2 * everyOther + _minute),
        PeerPresence.background,
      );
    });
  });

  group('the social state', () {
    ProviderContainer hub({
      required FriendProfile ada,
      MemorySocialSnapshotStore? store,
    }) {
      final ProviderContainer container = ProviderContainer(
        overrides: [
          signalQueueStoreProvider.overrideWithValue(MemorySignalQueueStore()),
          socialSnapshotStoreProvider.overrideWithValue(
            store ?? MemorySocialSnapshotStore(),
          ),
          messageTimelineStoreProvider.overrideWithValue(
            MemoryMessageTimelineStore(),
          ),
          socialHubSeedProvider.overrideWithValue(
            SocialHubState.empty().copyWith(
              friends: <String, FriendProfile>{_ada: ada},
            ),
          ),
        ],
      );
      addTearDown(container.dispose);
      return container;
    }

    const FriendProfile ada = FriendProfile(
      address: _ada,
      displayName: 'Ada',
      status: FriendRelationshipStatus.accepted,
    );

    test(
      '"w tle" outlives the time "online" lasts, then goes offline',
      () async {
        final ProviderContainer container = hub(ada: ada);
        final SocialHubController controller = container.read(
          socialHubControllerProvider.notifier,
        );
        FriendProfile read() =>
            container.read(socialHubControllerProvider).friends[_ada]!;
        await controller.updatePeerPresence(
          peerAddress: _ada,
          report: const PresenceReport(
            presence: PeerPresence.background,
            openedAgo: Duration(minutes: 30),
          ),
          observedAtMillis: _day,
        );
        expect(read().presence, PeerPresence.background);
        expect(read().isOnline, isTrue);
        expect(read().lastOpenedAtMillis, _day - 30 * _minute);

        Future<void> decayAt(int now) => controller.decayPresence(
          offlineAfter: kPresenceOfflineAfter,
          foregroundFor: kPresenceForegroundFor,
          nowMillis: now,
        );
        await decayAt(_day + kPresenceForegroundFor.inMilliseconds + 1);
        expect(read().presence, PeerPresence.background);
        await decayAt(_day + kPresenceOfflineAfter.inMilliseconds);
        expect(read().presence, PeerPresence.offline);
        expect(read().isOnline, isFalse);
        expect(read().lastOpenedAtMillis, _day - 30 * _minute);
      },
    );

    test('an online friend gone quiet is offline, last open at the last '
        'sign; answers in between need not touch the state', () async {
      final ProviderContainer container = hub(ada: ada);
      final SocialHubController controller = container.read(
        socialHubControllerProvider.notifier,
      );
      FriendProfile read() =>
          container.read(socialHubControllerProvider).friends[_ada]!;
      const PresenceReport here = PresenceReport(
        presence: PeerPresence.online,
        openedAgo: Duration.zero,
      );
      await controller.updatePeerPresence(
        peerAddress: _ada,
        report: here,
        observedAtMillis: _day,
      );
      expect(read().presence, PeerPresence.online);
      final SocialHubState before = container.read(socialHubControllerProvider);
      // Another ping a round later: nothing visible changes.
      final int later = _day + kPresencePingInterval.inMilliseconds;
      await controller.updatePeerPresence(
        peerAddress: _ada,
        report: here,
        observedAtMillis: later,
      );
      expect(
        identical(container.read(socialHubControllerProvider), before),
        isTrue,
      );
      // That ping still counts: not offline one "online" span after the
      // first one.
      await controller.decayPresence(
        offlineAfter: kPresenceOfflineAfter,
        foregroundFor: kPresenceForegroundFor,
        nowMillis: _day + kPresenceForegroundFor.inMilliseconds,
      );
      expect(read().presence, PeerPresence.online);
      await controller.decayPresence(
        offlineAfter: kPresenceOfflineAfter,
        foregroundFor: kPresenceForegroundFor,
        nowMillis: later + kPresenceForegroundFor.inMilliseconds,
      );
      expect(read().presence, PeerPresence.offline);
      expect(read().lastOpenedAtMillis, later);
    });

    test('a friend who stops showing presence shows nothing', () async {
      final ProviderContainer container = hub(
        ada: ada.copyWith(
          presence: PeerPresence.background,
          presenceAtMillis: _day,
          lastOpenedAtMillis: _day - _hour,
        ),
      );
      await container
          .read(socialHubControllerProvider.notifier)
          .updatePeerPresence(
            peerAddress: _ada,
            report: PresenceReport.fromPayload(<String, dynamic>{
              'type': 'pong',
            }),
            observedAtMillis: _day + _minute,
          );
      final FriendProfile read = container
          .read(socialHubControllerProvider)
          .friends[_ada]!;
      expect(read.presence, PeerPresence.hidden);
      expect(read.lastOpenedAtMillis, 0);
      expect(read.isOnline, isTrue);
      expect(friendPresenceLine(read, _day + _minute), isNull);
    });

    test('presence is kept with the friends', () async {
      final Directory dir = await Directory.systemTemp.createTemp(
        'zen-presence-store-test-',
      );
      addTearDown(() => dir.delete(recursive: true));
      final FileSocialSnapshotStore store = FileSocialSnapshotStore(
        store: FileBinaryStore(
          dir,
          codec: BinaryCodec(compressor: const _PassThroughCompressor()),
        ),
      );
      await store.save(
        SocialHubState.empty().copyWith(
          friends: <String, FriendProfile>{
            _ada: ada.copyWith(
              presence: PeerPresence.background,
              presenceAtMillis: 123,
              lastOpenedAtMillis: 45,
            ),
            _bob: const FriendProfile(
              address: _bob,
              status: FriendRelationshipStatus.accepted,
            ),
          },
        ),
      );
      final SocialHubState back = (await store.load())!;
      expect(back.friends[_ada]!.presence, PeerPresence.background);
      expect(back.friends[_ada]!.presenceAtMillis, 123);
      expect(back.friends[_ada]!.lastOpenedAtMillis, 45);
      expect(back.friends[_bob]!.presence, PeerPresence.offline);
    });
  });

  group('announcements', () {
    Future<MemorySignalTransport> pumpApp(
      WidgetTester tester, {
      AppSettings settings = const AppSettings(),
      FriendLevel? Function(String address)? levelOf,
      bool asleepOffScreen = false,
      ValueListenable<bool>? reachable,
      Map<String, FriendProfile> friends = const <String, FriendProfile>{
        _ada: FriendProfile(
          address: _ada,
          displayName: 'Ada',
          status: FriendRelationshipStatus.accepted,
        ),
      },
    }) async {
      final MemorySignalTransport transport = MemorySignalTransport();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            signalTransportProvider.overrideWithValue(transport),
            appSettingsStoreProvider.overrideWithValue(
              MemoryAppSettingsStore(settings),
            ),
            presenceAsleepOffScreenProvider.overrideWithValue(asleepOffScreen),
            if (reachable != null)
              meshReachableProvider.overrideWithValue(reachable),
            if (levelOf != null)
              friendLevelLookupProvider.overrideWithValue(
                FriendLevelLookup()..levelOf = levelOf,
              ),
            socialHubSeedProvider.overrideWithValue(
              SocialHubState.empty().copyWith(friends: friends),
            ),
          ],
          child: const ZenRewriteApp(),
        ),
      );
      await tester.pumpAndSettle();
      return transport;
    }

    void leave(WidgetTester tester) {
      for (final AppLifecycleState state in <AppLifecycleState>[
        AppLifecycleState.inactive,
        AppLifecycleState.hidden,
        AppLifecycleState.paused,
      ]) {
        tester.binding.handleAppLifecycleStateChanged(state);
      }
    }

    Map<String, dynamic> last(MemorySignalTransport transport, String type) =>
        transport.sentSignals
            .lastWhere((entry) => entry.payload['type'] == type)
            .payload;

    testWidgets('on the screen "online", off it "w tle", each with the last '
        'opening', (WidgetTester tester) async {
      final MemorySignalTransport transport = await pumpApp(tester);
      expect(last(transport, 'ping'), containsPair('state', 'foreground'));
      expect(last(transport, 'ping'), containsPair('lo', 0));

      // A friend's ping on the screen: the pong says "online" too.
      await transport.injectIncoming(
        from: _ada,
        payload: const <String, dynamic>{'type': 'ping'},
      );
      await tester.pumpAndSettle();
      expect(last(transport, 'pong'), containsPair('state', 'foreground'));

      leave(tester);
      await tester.pump();
      await tester.pump();
      final Map<String, dynamic> away = last(transport, 'away');
      expect(away['state'], 'background');
      expect(away['lo'], 0, reason: 'Zen was open until just now');

      // Off the screen, a friend's ping gets "w tle" and when Zen was
      // last open.
      await tester.pump(const Duration(minutes: 3));
      await transport.injectIncoming(
        from: _ada,
        payload: const <String, dynamic>{'type': 'ping'},
      );
      await tester.pump();
      await tester.pump();
      final Map<String, dynamic> pong = last(transport, 'pong');
      expect(pong['state'], 'background');
      expect(pong['lo'], isA<int>());
      // Nothing new is sent just for presence: no ping off the screen.
      expect(
        transport.sentSignals.where((e) => e.payload['type'] == 'ping'),
        hasLength(1),
      );
    });

    testWidgets('an iPhone that stops receiving says so when it leaves', (
      WidgetTester tester,
    ) async {
      final MemorySignalTransport transport = await pumpApp(
        tester,
        asleepOffScreen: true,
      );
      expect(last(transport, 'ping'), containsPair('state', 'foreground'));
      leave(tester);
      await tester.pump();
      await tester.pump();
      expect(last(transport, 'away'), containsPair('state', 'asleep'));
    });

    testWidgets('"last opened" off: the state goes, the time does not', (
      WidgetTester tester,
    ) async {
      final MemorySignalTransport transport = await pumpApp(
        tester,
        settings: const AppSettings(showLastOpened: false),
      );
      final Map<String, dynamic> ping = last(transport, 'ping');
      expect(ping['state'], 'foreground');
      expect(ping.containsKey('lo'), isFalse);
      leave(tester);
      await tester.pump();
      await tester.pump();
      expect(last(transport, 'away').containsKey('lo'), isFalse);
    });

    testWidgets('a weak acquaintance hears nothing of presence', (
      WidgetTester tester,
    ) async {
      final MemorySignalTransport transport = await pumpApp(
        tester,
        levelOf: (String address) => FriendLevel.weak,
      );
      // Not pinged at all while Zen is open: a ping is "I am here".
      expect(
        transport.sentSignals.where((e) => e.payload['type'] == 'ping'),
        isEmpty,
      );
      await transport.injectIncoming(
        from: _ada,
        payload: const <String, dynamic>{'type': 'ping'},
      );
      await tester.pumpAndSettle();
      // Exactly what a locked phone answers: nothing tells them Zen is open.
      expect(last(transport, 'pong').keys.toSet(), <String>{
        'type',
        ...versionHello().keys,
      });
      // And as rarely: a second ping soon after gets no answer.
      await transport.injectIncoming(
        from: _ada,
        payload: const <String, dynamic>{'type': 'ping'},
      );
      await tester.pumpAndSettle();
      expect(
        transport.sentSignals.where((e) => e.payload['type'] == 'pong'),
        hasLength(1),
      );
      leave(tester);
      await tester.pump();
      await tester.pump();
      expect(
        transport.sentSignals.where((e) => e.payload['type'] == 'away'),
        isEmpty,
      );
    });

    testWidgets('only friends who may see presence are pinged; a weak '
        "acquaintance's own presence is not shown", (
      WidgetTester tester,
    ) async {
      final MemorySignalTransport transport = await pumpApp(
        tester,
        levelOf: (String address) => address == _ada ? FriendLevel.weak : null,
        friends: <String, FriendProfile>{
          _ada: const FriendProfile(
            address: _ada,
            displayName: 'Ada',
            status: FriendRelationshipStatus.accepted,
          ).copyWith(presence: PeerPresence.online, lastOpenedAtMillis: _day),
          _bob: const FriendProfile(
            address: _bob,
            displayName: 'Bob',
            status: FriendRelationshipStatus.accepted,
          ),
        },
      );
      Set<String> pinged() => <String>{
        for (final e in transport.sentSignals)
          if (e.payload['type'] == 'ping') e.remoteAddress,
      };
      expect(pinged(), <String>{_bob});
      // A round later: still only Bob.
      await tester.pump(kPresencePingInterval);
      await tester.pump();
      expect(pinged(), <String>{_bob});

      final ProviderContainer container = ProviderScope.containerOf(
        tester.element(find.byType(ZenRewriteApp)),
      );
      FriendProfile friend(String address) =>
          container.read(socialHubControllerProvider).friends[address]!;
      // What Ada showed before she was a weak acquaintance is gone.
      expect(friend(_ada).presence, PeerPresence.hidden);
      expect(friend(_ada).lastOpenedAtMillis, 0);

      // Her ping still says she can be reached, nothing of her state.
      await transport.injectIncoming(
        from: _ada,
        payload: const <String, dynamic>{'type': 'ping', 'state': 'foreground'},
      );
      await tester.pumpAndSettle();
      expect(friend(_ada).presence, PeerPresence.hidden);
      expect(friend(_ada).isOnline, isTrue);
      await transport.injectIncoming(
        from: _bob,
        payload: const <String, dynamic>{'type': 'ping', 'state': 'foreground'},
      );
      await tester.pumpAndSettle();
      expect(friend(_bob).presence, PeerPresence.online);
    });

    testWidgets('switching apps often sends "away" at most every few '
        'minutes; one held back is dropped when Zen comes back first', (
      WidgetTester tester,
    ) async {
      final MemorySignalTransport transport = await pumpApp(tester);
      int aways() => transport.sentSignals
          .where((e) => e.payload['type'] == 'away')
          .length;
      void comeBack() {
        for (final AppLifecycleState state in <AppLifecycleState>[
          AppLifecycleState.hidden,
          AppLifecycleState.inactive,
          AppLifecycleState.resumed,
        ]) {
          tester.binding.handleAppLifecycleStateChanged(state);
        }
      }

      leave(tester);
      await tester.pump();
      await tester.pump();
      expect(aways(), 1);

      // Back after a ping interval (friends are pinged), and off again: the
      // next "away" waits for the rest of kPresenceAwayEvery.
      await tester.pump(const Duration(minutes: 3));
      comeBack();
      await tester.pump();
      await tester.pump();
      leave(tester);
      await tester.pump();
      await tester.pump();
      expect(aways(), 1);
      await tester.pump(kPresenceAwayEvery);
      expect(aways(), 2);
      expect(last(transport, 'away')['state'], 'background');

      // Held back again, but Zen is back before it goes: none goes, and
      // the next time Zen leaves one is owed again.
      await tester.pump(const Duration(minutes: 3));
      comeBack();
      await tester.pump();
      await tester.pump();
      leave(tester);
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(minutes: 1));
      comeBack();
      await tester.pump();
      await tester.pump();
      await tester.pump(kPresenceAwayEvery);
      expect(aways(), 2);
      leave(tester);
      await tester.pump();
      await tester.pump();
      await tester.pump(kPresenceAwayEvery);
      expect(aways(), 3);
    });

    testWidgets('pings that went out before the node reached the mesh go out '
        'again once it does', (WidgetTester tester) async {
      final ValueNotifier<bool> reachable = ValueNotifier<bool>(false);
      addTearDown(reachable.dispose);
      final MemorySignalTransport transport = await pumpApp(
        tester,
        reachable: reachable,
      );
      int pings() => transport.sentSignals
          .where((e) => e.payload['type'] == 'ping')
          .length;
      expect(pings(), 1, reason: '"I am here" as Zen came on the screen');

      reachable.value = true;
      await tester.pump();
      await tester.pump();
      expect(pings(), 2, reason: 'again, now that it can arrive');
      expect(last(transport, 'ping'), containsPair('state', 'foreground'));

      // A short loss of the network after a round that did arrive: nothing
      // new, the next round comes on time.
      reachable.value = false;
      await tester.pump();
      reachable.value = true;
      await tester.pump();
      await tester.pump();
      expect(pings(), 2);
      await tester.pump(kPresencePingInterval);
      await tester.pump();
      expect(pings(), 3);
    });

    testWidgets('a friend just added is pinged at once, the others are not '
        'pinged again', (WidgetTester tester) async {
      final MemorySignalTransport transport = await pumpApp(
        tester,
        friends: const <String, FriendProfile>{
          _ada: FriendProfile(
            address: _ada,
            displayName: 'Ada',
            status: FriendRelationshipStatus.accepted,
          ),
          _bob: FriendProfile(
            address: _bob,
            displayName: 'Bob',
            status: FriendRelationshipStatus.pendingIncoming,
          ),
        },
      );
      List<String> pinged() => <String>[
        for (final e in transport.sentSignals)
          if (e.payload['type'] == 'ping') e.remoteAddress,
      ];
      expect(pinged(), <String>[_ada]);

      final ProviderContainer container = ProviderScope.containerOf(
        tester.element(find.byType(ZenRewriteApp)),
      );
      await container
          .read(socialHubControllerProvider.notifier)
          .acceptFriendRequest(peerAddress: _bob);
      await tester.pump();
      await tester.pump();
      expect(pinged(), <String>[_ada, _bob]);
      expect(last(transport, 'ping'), containsPair('state', 'foreground'));
    });
  });

  group('the locked service', () {
    test('its kit names friends who may see presence, not weak ones', () {
      final SocialHubState state = SocialHubState.empty().copyWith(
        friends: const <String, FriendProfile>{
          _ada: FriendProfile(
            address: _ada,
            status: FriendRelationshipStatus.accepted,
          ),
          _bob: FriendProfile(
            address: _bob,
            status: FriendRelationshipStatus.accepted,
          ),
          'carol.ygg': FriendProfile(
            address: 'carol.ygg',
            status: FriendRelationshipStatus.pendingIncoming,
          ),
        },
      );
      final DateTime left = DateTime.fromMillisecondsSinceEpoch(_day);
      final LockedPresenceKit kit = lockedPresenceKitOf(
        state,
        levelOf: (String a) => a == _bob ? FriendLevel.weak : null,
        showLastOpened: true,
        lastOpenedAt: left,
      );
      expect(kit.shownTo, <String>{_ada});
      expect(kit.lastOpenedAtMillis, _day);
      expect(kit.pongFields(_ada, _day + 2 * _minute), <String, dynamic>{
        'state': 'background',
        'lo': 120,
      });
      expect(kit.pongFields(_bob, _day), isEmpty);
      expect(
        lockedPresenceKitOf(
          state,
          levelOf: (String a) => null,
          showLastOpened: false,
          lastOpenedAt: left,
        ).pongFields(_ada, _day),
        <String, dynamic>{'state': 'background'},
      );
    });
  });

  group('labels', () {
    test('when a friend last had Zen open', () {
      const int now = 100 * _day;
      expect(lastOpenedLabel(0, now), isNull);
      expect(
        lastOpenedLabel(now - 20 * 1000, now),
        'ostatnio otwierał(a) przed chwilą',
      );
      expect(
        lastOpenedLabel(now - 5 * _minute, now),
        'ostatnio otwierał(a) 5 min temu',
      );
      expect(
        lastOpenedLabel(now - 3 * _hour, now),
        'ostatnio otwierał(a) 3 godz. temu',
      );
      expect(
        lastOpenedLabel(now - _day, now),
        'ostatnio otwierał(a) 1 dzień temu',
      );
      expect(
        lastOpenedLabel(now - 3 * _day, now),
        'ostatnio otwierał(a) 3 dni temu',
      );
      expect(
        lastOpenedLabel(now - 40 * _day, now),
        'ostatnio otwierał(a) ponad miesiąc temu',
      );
      // A clock a little ahead of this one: "just now", not negative.
      expect(
        lastOpenedLabel(now + _minute, now),
        'ostatnio otwierał(a) przed chwilą',
      );
    });

    test('the presence line of a chat', () {
      const int now = 100 * _day;
      FriendProfile friend(PeerPresence presence, {int opened = 0}) =>
          FriendProfile(
            address: _ada,
            status: FriendRelationshipStatus.accepted,
            presence: presence,
            lastOpenedAtMillis: opened,
          );
      expect(friendPresenceLine(friend(PeerPresence.online), now), 'w sieci');
      expect(
        friendPresenceLine(
          friend(PeerPresence.online, opened: now - _hour),
          now,
        ),
        'w sieci',
      );
      expect(
        friendPresenceLine(
          friend(PeerPresence.background, opened: now - 5 * _minute),
          now,
        ),
        'w tle · ostatnio otwierał(a) 5 min temu',
      );
      expect(friendPresenceLine(friend(PeerPresence.background), now), 'w tle');
      expect(
        friendPresenceLine(
          friend(PeerPresence.offline, opened: now - 2 * _hour),
          now,
        ),
        'ostatnio otwierał(a) 2 godz. temu',
      );
      expect(
        friendPresenceLine(friend(PeerPresence.offline), now),
        'poza siecią',
      );
      expect(
        friendPresenceLine(
          friend(PeerPresence.hidden, opened: now - _hour),
          now,
        ),
        isNull,
      );
    });
  });

  group('on screen', () {
    Future<void> pumpConversation(WidgetTester tester, FriendProfile ada) {
      return tester.pumpWidget(
        ProviderScope(
          // A new scope each time: the seed is read once per scope.
          key: UniqueKey(),
          overrides: [
            messageTimelineStoreProvider.overrideWithValue(
              MemoryMessageTimelineStore(),
            ),
            socialHubSeedProvider.overrideWithValue(
              SocialHubState.empty().copyWith(
                friends: <String, FriendProfile>{_ada: ada},
              ),
            ),
          ],
          child: const MaterialApp(
            home: ConversationScreen(peerAddress: _ada, title: 'Ada'),
          ),
        ),
      );
    }

    String subtitle(WidgetTester tester) => tester
        .widget<Text>(find.byKey(const Key('conversation-subtitle')))
        .data!;

    ZenStatusDot headerDot(WidgetTester tester) => tester.widget<ZenStatusDot>(
      find
          .descendant(
            of: find.byType(AppBar),
            matching: find.byType(ZenStatusDot),
          )
          .last,
    );

    testWidgets('the chat header shows the three states', (
      WidgetTester tester,
    ) async {
      final int now = DateTime.now().millisecondsSinceEpoch;
      const FriendProfile base = FriendProfile(
        address: _ada,
        displayName: 'Ada',
        status: FriendRelationshipStatus.accepted,
      );

      await pumpConversation(
        tester,
        base.copyWith(presence: PeerPresence.online, presenceAtMillis: now),
      );
      await tester.pumpAndSettle();
      expect(subtitle(tester), 'w sieci');
      expect(headerDot(tester).on, isTrue);

      await pumpConversation(
        tester,
        base.copyWith(
          presence: PeerPresence.background,
          presenceAtMillis: now,
          lastOpenedAtMillis: now - 5 * _minute,
        ),
      );
      await tester.pumpAndSettle();
      expect(subtitle(tester), 'w tle · ostatnio otwierał(a) 5 min temu');
      expect(headerDot(tester).on, isFalse);
      expect(headerDot(tester).away, isTrue);

      await pumpConversation(
        tester,
        base.copyWith(
          presence: PeerPresence.offline,
          lastOpenedAtMillis: now - 3 * _hour,
        ),
      );
      await tester.pumpAndSettle();
      expect(subtitle(tester), 'ostatnio otwierał(a) 3 godz. temu');
      expect(headerDot(tester).on, isFalse);
      expect(headerDot(tester).away, isFalse);

      await pumpConversation(
        tester,
        base.copyWith(
          presence: PeerPresence.hidden,
          nickname: 'Ada z chóru',
          lastPresenceAtMillis: now - 10 * _day,
        ),
      );
      await tester.pumpAndSettle();
      // Nothing about presence for a friend who does not show it.
      expect(subtitle(tester), 'Ada z chóru');
      expect(
        find.descendant(
          of: find.byType(AppBar),
          matching: find.byType(ZenStatusDot),
        ),
        findsNothing,
      );
    });

    testWidgets('the chat list draws each friend\'s state on the avatar', (
      WidgetTester tester,
    ) async {
      final int now = DateTime.now().millisecondsSinceEpoch;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            signalTransportProvider.overrideWithValue(MemorySignalTransport()),
            socialHubSeedProvider.overrideWithValue(
              SocialHubState.empty().copyWith(
                friends: <String, FriendProfile>{
                  _ada: FriendProfile(
                    address: _ada,
                    displayName: 'Ada',
                    status: FriendRelationshipStatus.accepted,
                    presence: PeerPresence.background,
                    presenceAtMillis: now,
                    lastOpenedAtMillis: now - 5 * _minute,
                  ),
                  _bob: FriendProfile(
                    address: _bob,
                    displayName: 'Bob',
                    status: FriendRelationshipStatus.accepted,
                    presence: PeerPresence.hidden,
                    presenceAtMillis: now,
                  ),
                },
              ),
            ),
          ],
          child: const ZenRewriteApp(),
        ),
      );
      await tester.pumpAndSettle();
      ZenBlobAvatar avatarOf(String name) => tester.widget<ZenBlobAvatar>(
        find.byWidgetPredicate(
          (Widget w) => w is ZenBlobAvatar && w.name == name,
        ),
      );
      expect(avatarOf('Ada').online, isFalse);
      expect(avatarOf('Ada').away, isTrue);
      expect(avatarOf('Ada').showStatus, isTrue);
      // Bob does not show presence to this person: no dot at all.
      expect(avatarOf('Bob').showStatus, isFalse);
      // The dot says it in words, too.
      expect(
        find.bySemanticsLabel(
          RegExp(r'^w tle · ostatnio otwierał\(a\) 5 min temu'),
        ),
        findsWidgets,
      );
    });

    testWidgets('the dot has three looks', (WidgetTester tester) async {
      Future<void> pumpDot(bool on, bool away) => tester.pumpWidget(
        MaterialApp(
          home: Center(
            child: ZenStatusDot(on: on, away: away),
          ),
        ),
      );
      Iterable<BoxDecoration> boxes() => tester
          .widgetList<DecoratedBox>(
            find.descendant(
              of: find.byType(ZenStatusDot),
              matching: find.byType(DecoratedBox),
            ),
          )
          .map((DecoratedBox box) => box.decoration)
          .whereType<BoxDecoration>();

      // Online: a filled green dot, no ring.
      await pumpDot(true, false);
      expect(
        boxes().where((BoxDecoration b) => b.border != null),
        isEmpty,
        reason: 'online is filled',
      );
      final Color? onColor = boxes().first.color;
      expect(onColor, isNotNull);

      // "w tle": a ring with a dot in it, in a colour of its own.
      await pumpDot(false, true);
      final List<BoxDecoration> away = boxes().toList();
      expect(away, hasLength(2));
      expect(away.where((BoxDecoration b) => b.border != null), hasLength(1));
      final BoxDecoration awayDot = away.singleWhere(
        (BoxDecoration b) => b.color != null,
      );
      expect(awayDot.color, isNot(onColor), reason: 'not the green of online');

      // Offline: an empty grey ring.
      await pumpDot(false, false);
      final BoxDecoration off = boxes().single;
      expect(off.color, isNull, reason: 'offline is an empty ring');
      expect(off.border, isNotNull);

      // Online wins over "w tle".
      await pumpDot(true, true);
      expect(boxes().where((BoxDecoration b) => b.border != null), isEmpty);
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
