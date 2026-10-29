import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/app/app.dart';
import 'package:zen/src/app/peer_version.dart';
import 'package:zen/src/app/theme/zen_ui.dart';
import 'package:zen/src/app/zen_app_modules.dart';
import 'package:zen/src/app/zen_core.dart';
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
import 'package:zen/src/features/social/social_snapshot_store.dart';

const String _ada = '200:1111:2222:3333:4444:5555:6666:7777';
const String _bob = '200:1111:2222:3333:4444:5555:6666:8888';
const String _carol = '200:1111:2222:3333:4444:5555:6666:9999';

/// This phone, as its friends' phones see it.
const String _me = '200:1111:2222:3333:4444:5555:6666:1234';

const int _minute = 60 * 1000;
const int _hour = 60 * _minute;
const int _day = 24 * _hour;

/// Ada's locked phone: its Android service answering pings, with this
/// phone ([_me]) among the friends who may see "w tle".
LockedReceiver _lockedFriendPhone(
  MemorySignalTransport air, {
  required int Function() now,
}) => LockedReceiver(
  transport: air,
  capability: BackgroundCapability.fromDraft(
    BackgroundCapabilityDraft(
      inboxPublicKey: Uint8List(32),
      friends: const <String>{_me},
    ),
    backgroundKey: Uint8List.fromList(List<int>.filled(32, 7)),
  ),
  inbox: SealedInboxWriter(
    file: File('${Directory.systemTemp.path}/zen-presence-unused.inbox'),
    recipientPublicKey: Uint8List(32),
  ),
  notices: MemoryRuntimeSystemNotificationService(),
  presence: const LockedPresenceKit(shownTo: <String>{_me}),
  mailboxPollInterval: Duration.zero,
  now: now,
);

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
      expect(back.sentAtMillis, isNull, reason: 'a 1.14.0 frame');
      // When the sender told it: the order of what one device tells.
      final Map<String, dynamic> told = presenceFields(
        own: PeerPresence.online,
        sentAtMillis: _day,
      );
      expect(told, <String, dynamic>{'state': 'foreground', 'sq': _day});
      expect(PresenceReport.fromPayload(told).sentAtMillis, _day);
      expect(
        PresenceReport.fromPayload(<String, dynamic>{
          'state': 'background',
          'sq': 'soon',
        }).sentAtMillis,
        isNull,
      );
    });
  });

  group('one friend, several frames, several devices', () {
    PresenceReport said(PeerPresence presence, [int? sentAt]) =>
        PresenceReport(presence: presence, sentAtMillis: sentAt);

    ({PresenceReport report, int at})? note(
      PresenceDevices devices,
      PresenceReport report, {
      String device = _ada,
      required int at,
    }) => devices.note(
      friend: _ada,
      device: device,
      report: report,
      atMillis: at,
      foregroundFor: kPresenceForegroundFor,
      backgroundFor: kPresenceOfflineAfter,
    );

    test('a stale "online" that comes after the "w tle" told later is not '
        'taken', () {
      final PresenceDevices devices = PresenceDevices();
      // The friend left the screen: "away" says "w tle" ...
      expect(
        note(
          devices,
          said(PeerPresence.background, _day + 5000),
          at: _day + 6000,
        )!.report.presence,
        PeerPresence.background,
      );
      // ... and the pong they sent just before, held on the way, comes
      // after it.
      expect(
        note(devices, said(PeerPresence.online, _day + 1000), at: _day + 7000),
        isNull,
      );
      // What they tell next is taken.
      expect(
        note(
          devices,
          said(PeerPresence.online, _day + 9000),
          at: _day + 9500,
        )!.report.presence,
        PeerPresence.online,
      );
      // A Zen that does not tell the order: each frame as it comes.
      expect(
        note(
          devices,
          said(PeerPresence.background),
          at: _day + 9600,
        )!.report.presence,
        PeerPresence.background,
      );
    });

    test('a clock set back by more than a minute is not stuck', () {
      final PresenceDevices devices = PresenceDevices();
      note(devices, said(PeerPresence.online, _day), at: _day);
      expect(
        note(
          devices,
          said(
            PeerPresence.background,
            _day - kPresenceReorderWindow.inMilliseconds - 1,
          ),
          at: _day + 1000,
        )!.report.presence,
        PeerPresence.background,
      );
    });

    test('a friend\'s devices together: Zen open on one of them is online, '
        'whatever order their answers come in', () {
      const String laptop = '200:1111:2222:3333:4444:5555:6666:aaaa';
      final PresenceDevices devices = PresenceDevices();
      // The computer has Zen on its screen ...
      note(devices, said(PeerPresence.online, _day), device: laptop, at: _day);
      // ... the phone answers from the pocket: still online.
      final ({PresenceReport report, int at}) both = note(
        devices,
        said(PeerPresence.background, _day + _minute),
        at: _day + _minute,
      )!;
      expect(both.report.presence, PeerPresence.online);
      expect(both.at, _day, reason: 'as old as the computer\'s word');
      // Once the computer's "online" is older than "online" lasts, the
      // phone's "w tle" is what shows.
      expect(
        note(
          devices,
          said(PeerPresence.background, _day + 6 * _minute),
          at: _day + 6 * _minute,
        )!.report.presence,
        PeerPresence.background,
      );
      // The computer leaves the screen: "w tle" from both.
      expect(
        note(
          devices,
          said(PeerPresence.background, _day + 7 * _minute),
          device: laptop,
          at: _day + 7 * _minute,
        )!.report.presence,
        PeerPresence.background,
      );
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

    test('a state is remembered for 30 min after its last confirmation', () {
      expect(kPresenceRememberedFor, const Duration(minutes: 30));
      final int window = kPresenceRememberedFor.inMilliseconds;
      bool remembered(int age) =>
          presenceRemembered(confirmedAtMillis: _day, nowMillis: _day + age);
      expect(remembered(0), isTrue);
      expect(remembered(window), isTrue);
      expect(remembered(window + 1), isFalse);
      expect(remembered(-_minute), isFalse, reason: 'the clock went back');
      expect(
        presenceRemembered(confirmedAtMillis: 0, nowMillis: _day),
        isFalse,
        reason: 'never confirmed',
      );
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
              book: FriendshipBook.restore(
                profiles: <String, FriendProfile>{_ada: ada},
              ),
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

    test('without the network every friend shows "brak połączenia" and '
        'nothing expires; back on it, a state confirmed lately shows what '
        'it is worth by now', () async {
      final ProviderContainer container = hub(
        ada: ada.copyWith(
          presence: PeerPresence.online,
          presenceAtMillis: _day,
        ),
      );
      final SocialHubController controller = container.read(
        socialHubControllerProvider.notifier,
      );
      FriendProfile read() =>
          container.read(socialHubControllerProvider).friends[_ada]!;

      await controller.notePresenceNetwork(reachable: false);
      expect(read().presenceDoubt, PresenceDoubt.noNetwork);
      expect(read().shownPresence, PeerPresence.noConnection);
      expect(
        friendPresenceLine(read(), _day + _minute),
        'Nie masz połączenia z siecią',
      );
      await controller.decayPresence(
        offlineAfter: kPresenceOfflineAfter,
        foregroundFor: kPresenceForegroundFor,
        settleUnchecked: true,
        nowMillis: _day + _hour,
      );
      expect(
        read().presence,
        PeerPresence.online,
        reason: 'nothing could come',
      );
      expect(read().shownPresence, PeerPresence.noConnection);

      // Back 3 min after the last word: still online.
      await controller.notePresenceNetwork(
        reachable: true,
        nowMillis: _day + 3 * _minute,
      );
      expect(read().presenceDoubt, isNull);
      expect(read().shownPresence, PeerPresence.online);

      // Lost again, back 8 min after the last word: "online" has expired.
      await controller.notePresenceNetwork(reachable: false);
      await controller.notePresenceNetwork(
        reachable: true,
        nowMillis: _day + 8 * _minute,
      );
      expect(read().presenceDoubt, isNull);
      expect(read().shownPresence, PeerPresence.offline);
    });

    test('back on the network after long, "status nieznany" until the '
        'answers had time to come', () async {
      final ProviderContainer container = hub(
        ada: ada.copyWith(
          presence: PeerPresence.background,
          presenceAtMillis: _day,
        ),
      );
      final SocialHubController controller = container.read(
        socialHubControllerProvider.notifier,
      );
      FriendProfile read() =>
          container.read(socialHubControllerProvider).friends[_ada]!;
      Future<void> decayAt(int now, {bool settle = false}) =>
          controller.decayPresence(
            offlineAfter: kPresenceOfflineAfter,
            foregroundFor: kPresenceForegroundFor,
            settleUnchecked: settle,
            nowMillis: now,
          );

      await controller.notePresenceNetwork(reachable: false);
      final int back = _day + kPresenceRememberedFor.inMilliseconds + _minute;
      await controller.notePresenceNetwork(reachable: true, nowMillis: back);
      expect(read().presenceDoubt, PresenceDoubt.unchecked);
      expect(read().shownPresence, PeerPresence.unknown);
      expect(
        friendPresenceLine(read(), back),
        'status nieznany · ostatnio w tle 31 min temu',
      );
      await decayAt(back);
      expect(read().shownPresence, PeerPresence.unknown);
      expect(read().presence, PeerPresence.background);
      await decayAt(back, settle: true);
      expect(read().presenceDoubt, isNull);
      expect(read().shownPresence, PeerPresence.offline);
    });

    test('back on the screen, a presence that would have expired shows what '
        'it is worth by now, or "status nieznany" when it is long ago; an '
        'answer ends the doubt', () async {
      final ProviderContainer container = hub(
        ada: ada.copyWith(
          presence: PeerPresence.online,
          presenceAtMillis: _day,
        ),
      );
      final SocialHubController controller = container.read(
        socialHubControllerProvider.notifier,
      );
      FriendProfile read() =>
          container.read(socialHubControllerProvider).friends[_ada]!;
      Future<void> backAt(int now) => controller.recheckStalePresence(
        offlineAfter: kPresenceOfflineAfter,
        foregroundFor: kPresenceForegroundFor,
        nowMillis: now,
      );

      await backAt(_day + _minute);
      expect(read().presenceDoubt, isNull);
      expect(read().shownPresence, PeerPresence.online);
      await backAt(_day + kPresenceForegroundFor.inMilliseconds);
      expect(read().presenceDoubt, isNull);
      expect(read().shownPresence, PeerPresence.offline);

      final int heard = _day + 6 * _minute;
      await controller.updatePeerPresence(
        peerAddress: _ada,
        report: const PresenceReport(presence: PeerPresence.background),
        observedAtMillis: heard,
      );
      expect(read().shownPresence, PeerPresence.background);
      final int later = heard + 40 * _minute;
      await backAt(later);
      expect(read().presenceDoubt, PresenceDoubt.unchecked);
      expect(read().presence, PeerPresence.background);
      expect(
        friendPresenceLine(read(), later),
        'status nieznany · ostatnio w tle 40 min temu',
      );

      await controller.updatePeerPresence(
        peerAddress: _ada,
        report: const PresenceReport(presence: PeerPresence.online),
        observedAtMillis: later + _minute,
      );
      expect(read().presenceDoubt, isNull);
      expect(read().shownPresence, PeerPresence.online);
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
          book: FriendshipBook.restore(
            profiles: <String, FriendProfile>{
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
      SocialSnapshotStore? store,
      Map<String, FriendProfile> friends = const <String, FriendProfile>{
        _ada: FriendProfile(
          address: _ada,
          displayName: 'Ada',
          status: FriendRelationshipStatus.accepted,
        ),
      },
    }) async {
      final MemorySignalTransport transport = MemorySignalTransport();
      // The node reaches the network unless a test says otherwise.
      final ValueNotifier<bool> online = ValueNotifier<bool>(true);
      addTearDown(online.dispose);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            signalTransportProvider.overrideWithValue(transport),
            appSettingsStoreProvider.overrideWithValue(
              MemoryAppSettingsStore(settings),
            ),
            presenceAsleepOffScreenProvider.overrideWithValue(asleepOffScreen),
            meshReachableProvider.overrideWithValue(reachable ?? online),
            if (levelOf != null)
              friendLevelLookupProvider.overrideWithValue(
                FriendLevelLookup()..levelOf = levelOf,
              ),
            if (store != null)
              socialSnapshotStoreProvider.overrideWithValue(store),
            socialHubSeedProvider.overrideWithValue(
              SocialHubState.empty().copyWith(
                book: FriendshipBook.restore(profiles: friends),
              ),
            ),
          ],
          child: const ZenRewriteApp(),
        ),
      );
      await tester.pumpAndSettle();
      return transport;
    }

    /// [from]'s ping from a Zen on their screen: they have Zen open.
    Future<void> openOn(
      WidgetTester tester,
      MemorySignalTransport transport,
      String from,
    ) async {
      await transport.injectIncoming(
        from: from,
        payload: const <String, dynamic>{'type': 'ping', 'state': 'foreground'},
      );
      await tester.pumpAndSettle();
    }

    int sent(MemorySignalTransport transport, String type, [String? to]) =>
        transport.sentSignals
            .where(
              (e) =>
                  e.payload['type'] == type &&
                  (to == null || e.remoteAddress == to),
            )
            .length;

    FriendProfile friendIn(WidgetTester tester, String address) =>
        ProviderScope.containerOf(
          tester.element(find.byType(ZenRewriteApp)),
        ).read(socialHubControllerProvider).friends[address]!;

    void comeBack(WidgetTester tester) {
      for (final AppLifecycleState state in <AppLifecycleState>[
        AppLifecycleState.hidden,
        AppLifecycleState.inactive,
        AppLifecycleState.resumed,
      ]) {
        tester.binding.handleAppLifecycleStateChanged(state);
      }
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
      await openOn(tester, transport, _ada);
      expect(last(transport, 'pong'), containsPair('state', 'foreground'));

      leave(tester);
      await tester.pump();
      await tester.pump(kPresenceNoticeDelay);
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
      // At once (iOS gives it seconds), and also to a friend without Zen
      // open: their mail should go to the mailboxes now.
      await tester.pump();
      await tester.pump();
      await tester.pump();
      expect(last(transport, 'away'), containsPair('state', 'asleep'));
      expect(sent(transport, 'away', _ada), 1);
      // Back and off again soon: Ada (without Zen open) heard no "I am
      // here", so she needs no second "asleep" either; each one would wake
      // her phone.
      comeBack(tester);
      await tester.pump();
      await tester.pump(kPresenceNoticeDelay);
      leave(tester);
      await tester.pump();
      await tester.pump();
      await tester.pump();
      expect(sent(transport, 'away', _ada), 1);
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
      await openOn(tester, transport, _ada);
      leave(tester);
      await tester.pump();
      await tester.pump(kPresenceNoticeDelay);
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
      await tester.pump(kPresenceNoticeDelay);
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

    const Map<String, FriendProfile> adaAndBob = <String, FriendProfile>{
      _ada: FriendProfile(
        address: _ada,
        displayName: 'Ada',
        status: FriendRelationshipStatus.accepted,
      ),
      _bob: FriendProfile(
        address: _bob,
        displayName: 'Bob',
        status: FriendRelationshipStatus.accepted,
      ),
    };

    testWidgets('each change goes at once to the friends who have Zen open '
        'and to nobody else; quick switches are told as one, each state at '
        'most every 30 s', (WidgetTester tester) async {
      final MemorySignalTransport transport = await pumpApp(
        tester,
        friends: adaAndBob,
      );
      await openOn(tester, transport, _ada);
      // Bob's phone is locked: it answers "w tle".
      await transport.injectIncoming(
        from: _bob,
        payload: const <String, dynamic>{'type': 'pong', 'state': 'background'},
      );
      await tester.pumpAndSettle();

      leave(tester);
      await tester.pump();
      expect(sent(transport, 'away'), 0, reason: 'changes are gathered first');
      await tester.pump(kPresenceNoticeDelay);
      expect(sent(transport, 'away', _ada), 1);
      expect(last(transport, 'away')['state'], 'background');
      expect(sent(transport, 'away', _bob), 0, reason: 'a locked phone sleeps');

      // Back before the next round: Ada hears "I am here" at once, and
      // nobody is pinged for it.
      final int pings = sent(transport, 'ping');
      comeBack(tester);
      await tester.pump();
      await tester.pump(kPresenceNoticeDelay);
      expect(sent(transport, 'away', _ada), 2);
      expect(last(transport, 'away')['state'], 'foreground');
      expect(last(transport, 'away')['lo'], 0);
      expect(sent(transport, 'ping'), pings);
      expect(sent(transport, 'away', _bob), 0);

      // A glance at another app, back within the delay: nothing.
      leave(tester);
      await tester.pump(const Duration(seconds: 1));
      comeBack(tester);
      await tester.pump();
      await tester.pump(kPresenceNoticeDelay);
      expect(sent(transport, 'away', _ada), 2);

      // Off again: "w tle" went to Ada less than 30 s ago, so this one
      // waits for the rest of that time.
      leave(tester);
      await tester.pump();
      await tester.pump(kPresenceNoticeDelay);
      expect(sent(transport, 'away', _ada), 2);
      await tester.pump(kPresenceNoticeEvery);
      expect(sent(transport, 'away', _ada), 3);
      expect(last(transport, 'away')['state'], 'background');

      // Held back, but Zen is back on the screen before it may go: the
      // state is what Ada was told last, so nothing goes at all.
      comeBack(tester);
      await tester.pump();
      await tester.pump(kPresenceNoticeDelay);
      final int told = sent(transport, 'away', _ada);
      leave(tester);
      await tester.pump(kPresenceNoticeDelay);
      comeBack(tester);
      await tester.pump();
      await tester.pump(kPresenceNoticeEvery);
      expect(sent(transport, 'away', _ada), told);
      expect(sent(transport, 'away', _bob), 0);
    });

    testWidgets('an announcement keeps the shape a 1.13 Zen reads: an `away` '
        'with `state` and `lo`, and the order it ignores', (
      WidgetTester tester,
    ) async {
      final MemorySignalTransport transport = await pumpApp(tester);
      await openOn(tester, transport, _ada);
      leave(tester);
      await tester.pump();
      await tester.pump(kPresenceNoticeDelay);
      comeBack(tester);
      await tester.pump();
      await tester.pump(kPresenceNoticeDelay);
      final List<Map<String, dynamic>> aways = <Map<String, dynamic>>[
        for (final e in transport.sentSignals)
          if (e.payload['type'] == 'away') e.payload,
      ];
      expect(aways, hasLength(2));
      for (final Map<String, dynamic> away in aways) {
        // No new type, and only a field an older Zen does not read (it
        // reads fields by name): it takes it as it took "away", whatever
        // state it names.
        expect(away.keys.toSet(), <String>{'type', 'state', 'lo', 'sq'});
      }
      expect(
        PresenceReport.fromPayload(aways.first).presence,
        PeerPresence.background,
      );
      expect(
        PresenceReport.fromPayload(aways.last).presence,
        PeerPresence.online,
      );
    });

    testWidgets('a friend whose Zen is too old to tell presence shows '
        '"status nieznany", not nothing', (WidgetTester tester) async {
      final MemorySignalTransport transport = await pumpApp(tester);
      await transport.injectIncoming(
        from: _ada,
        payload: const <String, dynamic>{
          'type': 'pong',
          'ver': '1.12.1',
          'build': 99,
        },
      );
      await tester.pumpAndSettle();
      final FriendProfile ada = friendIn(tester, _ada);
      expect(ada.presence, PeerPresence.unknown);
      expect(ada.shownPresence, PeerPresence.unknown);
      expect(ada.isOnline, isTrue, reason: 'it still answers');
      expect(
        friendPresenceLine(ada, DateTime.now().millisecondsSinceEpoch),
        'Starsza wersja Zen — status nieznany',
      );
      // A 1.13 Zen without a state hides it from this person: nothing.
      await transport.injectIncoming(
        from: _ada,
        payload: const <String, dynamic>{'type': 'pong', 'ver': '1.13.1'},
      );
      await tester.pumpAndSettle();
      expect(friendIn(tester, _ada).shownPresence, PeerPresence.hidden);
    });

    testWidgets('without the network for a while every friend shows "brak '
        'połączenia", neither offline nor "status nieznany"; back on it, '
        'what they showed lately at once, and the friends who have Zen open '
        'are pinged', (WidgetTester tester) async {
      final ValueNotifier<bool> reachable = ValueNotifier<bool>(true);
      addTearDown(reachable.dispose);
      final MemorySignalTransport transport = await pumpApp(
        tester,
        reachable: reachable,
        friends: adaAndBob,
      );
      await openOn(tester, transport, _ada);
      await transport.injectIncoming(
        from: _bob,
        payload: const <String, dynamic>{'type': 'pong', 'state': 'background'},
      );
      await tester.pumpAndSettle();

      reachable.value = false;
      await tester.pump(const Duration(seconds: 5));
      expect(friendIn(tester, _ada).presenceDoubt, isNull, reason: 'a blip');
      await tester.pump(kPresenceNoNetworkAfter);
      await tester.pump();
      for (final String friend in <String>[_ada, _bob]) {
        expect(
          friendIn(tester, friend).shownPresence,
          PeerPresence.noConnection,
        );
        expect(
          friendPresenceLine(
            friendIn(tester, friend),
            DateTime.now().millisecondsSinceEpoch,
          ),
          'Nie masz połączenia z siecią',
        );
      }
      // What they showed last is kept underneath.
      expect(friendIn(tester, _ada).presence, PeerPresence.online);
      expect(friendIn(tester, _bob).presence, PeerPresence.background);

      final int adaPings = sent(transport, 'ping', _ada);
      final int bobPings = sent(transport, 'ping', _bob);
      reachable.value = true;
      await tester.pump();
      await tester.pump();
      expect(sent(transport, 'ping', _ada), adaPings + 1);
      expect(sent(transport, 'ping', _bob), bobPings, reason: 'not woken');
      // Confirmed moments ago: shown as it was, not "status nieznany".
      expect(friendIn(tester, _ada).presenceDoubt, isNull);
      expect(friendIn(tester, _ada).shownPresence, PeerPresence.online);
      expect(friendIn(tester, _bob).presenceDoubt, isNull);
      expect(friendIn(tester, _bob).shownPresence, PeerPresence.background);

      // Ada answers: what she says now.
      await transport.injectIncoming(
        from: _ada,
        payload: const <String, dynamic>{'type': 'pong', 'state': 'background'},
      );
      await tester.pumpAndSettle();
      expect(friendIn(tester, _ada).shownPresence, PeerPresence.background);
    });

    testWidgets('what friends showed is remembered over a restart: confirmed '
        'within 30 min it shows as it stands now until they answer; older, '
        '"status nieznany" until they answer, or until the second round\'s '
        'answers had time to come', (WidgetTester tester) async {
      final int now = DateTime.now().millisecondsSinceEpoch;
      final MemorySocialSnapshotStore store = MemorySocialSnapshotStore(
        SocialHubState.empty().copyWith(
          book: FriendshipBook.restore(
            profiles: <String, FriendProfile>{
              _ada: adaAndBob[_ada]!.copyWith(
                presence: PeerPresence.online,
                presenceAtMillis: now - 3 * _minute,
              ),
              _bob: adaAndBob[_bob]!.copyWith(
                presence: PeerPresence.background,
                presenceAtMillis: now - _hour,
              ),
              _carol:
                  const FriendProfile(
                    address: _carol,
                    displayName: 'Carol',
                    status: FriendRelationshipStatus.accepted,
                  ).copyWith(
                    presence: PeerPresence.online,
                    presenceAtMillis: now - 12 * _minute,
                    lastOpenedAtMillis: now - 12 * _minute,
                  ),
            },
          ),
        ),
      );
      final MemorySignalTransport transport = await pumpApp(
        tester,
        store: store,
      );
      // Ada, online 3 min ago: online.
      expect(friendIn(tester, _ada).presenceDoubt, isNull);
      expect(friendIn(tester, _ada).shownPresence, PeerPresence.online);
      // Carol, online 12 min ago: "online" has expired, so offline.
      expect(friendIn(tester, _carol).presenceDoubt, isNull);
      expect(friendIn(tester, _carol).shownPresence, PeerPresence.offline);
      expect(
        friendPresenceLine(friendIn(tester, _carol), now),
        'ostatnio otwierał(a) 12 min temu',
      );
      // Bob, an hour ago: not known.
      expect(friendIn(tester, _bob).presenceDoubt, PresenceDoubt.unchecked);
      expect(friendIn(tester, _bob).shownPresence, PeerPresence.unknown);
      expect(
        friendPresenceLine(friendIn(tester, _bob), now),
        'status nieznany · ostatnio w tle 1 godz. temu',
      );
      // Not offline after the first round's settle either.
      await tester.pump(kPresenceSettleAfterResume);
      await tester.pump();
      expect(friendIn(tester, _bob).shownPresence, PeerPresence.unknown);

      // Ada's first word replaces what was remembered.
      await transport.injectIncoming(
        from: _ada,
        payload: const <String, dynamic>{'type': 'pong', 'state': 'background'},
      );
      await tester.pumpAndSettle();
      expect(friendIn(tester, _ada).shownPresence, PeerPresence.background);

      // Bob never answers: after the second round, what his last state is
      // worth by now (an hour old "w tle" is offline).
      await tester.pump(kPresencePingInterval);
      await tester.pump(kPresenceSettleAfterResume);
      await tester.pump();
      expect(friendIn(tester, _bob).presenceDoubt, isNull);
      expect(friendIn(tester, _bob).shownPresence, PeerPresence.offline);
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
      // Ada answers it (so she is not pinged again in the first minute).
      await transport.injectIncoming(
        from: _ada,
        payload: const <String, dynamic>{'type': 'pong', 'state': 'background'},
      );
      await tester.pump();

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

    testWidgets('after a start, a locked friend who answered just before it '
        'shows "w tle" within seconds, not "status nieznany" for minutes', (
      WidgetTester tester,
    ) async {
      final int start = DateTime.now().millisecondsSinceEpoch;
      // Ada's phone is locked; its clock runs with this test's.
      int clock = start - _minute;
      final MemorySignalTransport adaAir = MemorySignalTransport();
      final LockedReceiver adaPhone = _lockedFriendPhone(
        adaAir,
        now: () => clock,
      );
      await adaPhone.start();
      addTearDown(adaPhone.stop);
      // A minute ago this phone's Zen (gone since) pinged her, and she
      // answered: that answer never reached anything shown here.
      await adaPhone.handleFrame(
        SignalTransportFrame(
          from: _me,
          payload: const <String, dynamic>{'type': 'ping'},
          receivedAtMillis: clock,
        ),
      );
      clock = start;
      final MemorySignalTransport transport = await pumpApp(
        tester,
        store: MemorySocialSnapshotStore(
          SocialHubState.empty().copyWith(
            book: FriendshipBook.restore(
              profiles: <String, FriendProfile>{
                _ada:
                    const FriendProfile(
                      address: _ada,
                      displayName: 'Ada',
                      status: FriendRelationshipStatus.accepted,
                    ).copyWith(
                      presence: PeerPresence.background,
                      presenceAtMillis: start - _hour,
                    ),
              },
            ),
          ),
        ),
      );
      expect(friendIn(tester, _ada).shownPresence, PeerPresence.unknown);

      // This phone's pings reach Ada's phone; her answers come back (not
      // the one from before the start: it went to the app that is gone).
      int carried = 0;
      int answered = adaAir.sentSignals.length;
      expect(answered, 1);
      Future<void> carry() async {
        final List<Map<String, dynamic>> toAda = <Map<String, dynamic>>[
          for (final e in transport.sentSignals)
            if (e.remoteAddress == _ada && e.payload['type'] == 'ping')
              e.payload,
        ];
        for (final Map<String, dynamic> payload in toAda.skip(carried)) {
          await adaPhone.handleFrame(
            SignalTransportFrame(
              from: _me,
              payload: payload,
              receivedAtMillis: clock,
            ),
          );
        }
        carried = toAda.length;
        final List<Map<String, dynamic>> back = <Map<String, dynamic>>[
          for (final e in adaAir.sentSignals)
            if (e.remoteAddress == _me) e.payload,
        ];
        for (final Map<String, dynamic> payload in back.skip(answered)) {
          await transport.injectIncoming(from: _ada, payload: payload);
        }
        answered = back.length;
        await tester.pumpAndSettle();
      }

      await carry();
      expect(last(transport, 'ping'), containsPair(kPresenceFreshKey, true));
      expect(friendIn(tester, _ada).presenceDoubt, isNull);
      expect(friendIn(tester, _ada).shownPresence, PeerPresence.background);
    });

    testWidgets('after a start, friends who did not answer are pinged again '
        'within the first minute, and only they', (WidgetTester tester) async {
      final MemorySignalTransport transport = await pumpApp(
        tester,
        friends: adaAndBob,
      );
      List<Map<String, dynamic>> pingsTo(String friend) =>
          <Map<String, dynamic>>[
            for (final e in transport.sentSignals)
              if (e.remoteAddress == friend && e.payload['type'] == 'ping')
                e.payload,
          ];
      expect(pingsTo(_ada).single, containsPair(kPresenceFreshKey, true));
      // Bob answers; Ada's answer (or her ping) got lost on the way.
      await transport.injectIncoming(
        from: _bob,
        payload: const <String, dynamic>{'type': 'pong', 'state': 'background'},
      );
      await tester.pumpAndSettle();
      await tester.pump(kPresenceStartRetries.first);
      await tester.pump();
      expect(pingsTo(_ada), hasLength(2));
      expect(pingsTo(_ada).last, containsPair(kPresenceFreshKey, true));
      expect(pingsTo(_bob), hasLength(1));
      // Ada answers this one: nothing more for her either.
      await transport.injectIncoming(
        from: _ada,
        payload: const <String, dynamic>{'type': 'pong', 'state': 'background'},
      );
      await tester.pumpAndSettle();
      await tester.pump(
        kPresenceStartRetries.last - kPresenceStartRetries.first,
      );
      await tester.pump();
      expect(pingsTo(_ada), hasLength(2));
      // The rounds that follow are the usual ones, not marked.
      await tester.pump(kPresencePingInterval - kPresenceStartRetries.last);
      await tester.pump();
      expect(pingsTo(_ada), hasLength(3));
      expect(pingsTo(_ada).last.containsKey(kPresenceFreshKey), isFalse);
      expect(pingsTo(_bob).last.containsKey(kPresenceFreshKey), isFalse);
    });

    testWidgets('a stale "online" that comes after "w tle" does not show '
        'online; what each frame tells is in order of telling', (
      WidgetTester tester,
    ) async {
      final MemorySignalTransport transport = await pumpApp(tester);
      final int now = DateTime.now().millisecondsSinceEpoch;
      Future<void> hear(String type, String state, int sentAt) async {
        await transport.injectIncoming(
          from: _ada,
          payload: <String, dynamic>{
            'type': type,
            'state': state,
            kPresenceSentKey: sentAt,
          },
        );
        await tester.pumpAndSettle();
      }

      // Ada leaves the screen; the pong she sent just before comes later.
      await hear(kPresenceAwayType, 'background', now - 2000);
      await hear('pong', 'foreground', now - 5000);
      expect(friendIn(tester, _ada).shownPresence, PeerPresence.background);
      // Back on her screen.
      await hear('ping', 'foreground', now - 1000);
      expect(friendIn(tester, _ada).shownPresence, PeerPresence.online);
      // Her outgoing pings carry the order too.
      expect(last(transport, 'pong')[kPresenceSentKey], isA<int>());
    });

    testWidgets('the core started again (the node back from the Android '
        'service) is a start of its own: "status nieznany" is not settled '
        'after its first round', (WidgetTester tester) async {
      final int now = DateTime.now().millisecondsSinceEpoch;
      await pumpApp(
        tester,
        store: MemorySocialSnapshotStore(
          SocialHubState.empty().copyWith(
            book: FriendshipBook.restore(
              profiles: <String, FriendProfile>{
                _ada:
                    const FriendProfile(
                      address: _ada,
                      displayName: 'Ada',
                      status: FriendRelationshipStatus.accepted,
                    ).copyWith(
                      presence: PeerPresence.background,
                      presenceAtMillis: now - _hour,
                    ),
              },
            ),
          ),
        ),
      );
      expect(friendIn(tester, _ada).shownPresence, PeerPresence.unknown);
      final ZenCore core = ProviderScope.containerOf(
        tester.element(find.byType(ZenRewriteApp)),
      ).read(zenCoreProvider);
      await core.stop();
      await core.start();
      await tester.pump();
      await tester.pump();
      await tester.pump(kPresenceSettleAfterResume);
      await tester.pump();
      expect(friendIn(tester, _ada).shownPresence, PeerPresence.unknown);
      // The second round of this run settles it.
      await tester.pump(kPresencePingInterval);
      await tester.pump(kPresenceSettleAfterResume);
      await tester.pump();
      expect(friendIn(tester, _ada).shownPresence, PeerPresence.offline);
    });

    testWidgets('leaving the screen right before the core stops (a phone '
        'that locks hands its node over at once): the friends who have Zen '
        'open hear "w tle" first', (WidgetTester tester) async {
      final MemorySignalTransport transport = await pumpApp(tester);
      await openOn(tester, transport, _ada);
      expect(sent(transport, kPresenceAwayType), 0);
      leave(tester);
      await tester.pump();
      // Within the moment a glance is given, the core stops.
      await ProviderScope.containerOf(
        tester.element(find.byType(ZenRewriteApp)),
      ).read(zenCoreProvider).stop();
      await tester.pump();
      expect(sent(transport, kPresenceAwayType, _ada), 1);
      expect(last(transport, kPresenceAwayType)['state'], 'background');
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
        book: FriendshipBook.restore(
          profiles: const <String, FriendProfile>{
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
        ),
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
        'sq': _day + 2 * _minute,
      });
      expect(kit.pongFields(_bob, _day), isEmpty);
      expect(
        lockedPresenceKitOf(
          state,
          levelOf: (String a) => null,
          showLastOpened: false,
          lastOpenedAt: left,
        ).pongFields(_ada, _day),
        <String, dynamic>{'state': 'background', 'sq': _day},
      );
    });

    test('a ping from a Zen that just started is answered at once, even '
        'right after an answer, but at most every 20 s', () async {
      int clock = _day;
      final MemorySignalTransport air = MemorySignalTransport();
      final LockedReceiver phone = _lockedFriendPhone(air, now: () => clock);
      await phone.start();
      addTearDown(phone.stop);
      int pongs() =>
          air.sentSignals.where((e) => e.payload['type'] == 'pong').length;
      Future<void> ping({bool fresh = false}) => phone.handleFrame(
        SignalTransportFrame(
          from: _me,
          payload: <String, dynamic>{
            'type': 'ping',
            if (fresh) kPresenceFreshKey: true,
          },
          receivedAtMillis: clock,
        ),
      );
      await ping();
      expect(pongs(), 1);
      // A minute later Zen starts again there: the answer went to the app
      // that is gone. An ordinary ping waits for its turn ...
      clock += _minute;
      await ping();
      expect(pongs(), 1);
      // ... the first ones of the new start do not.
      await ping(fresh: true);
      expect(pongs(), 2);
      expect(air.sentSignals.last.payload['state'], 'background');
      expect(air.sentSignals.last.payload['sq'], clock);
      // Marked or not, no more than one answer every 20 s for them ...
      clock += 10 * 1000;
      await ping(fresh: true);
      expect(pongs(), 2);
      clock += kLockedFreshPongEvery.inMilliseconds;
      await ping(fresh: true);
      expect(pongs(), 3);
      // ... and the ordinary pings keep the pace of a locked phone.
      clock += _minute;
      await ping();
      expect(pongs(), 3);
      clock += kLockedPongEvery.inMilliseconds;
      await ping();
      expect(pongs(), 4);
      // A clock set back answers at once rather than never.
      clock -= _hour;
      await ping();
      expect(pongs(), 5);
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

    test('the line of a presence not shown as it is says why', () {
      const int now = 100 * _day;
      const FriendProfile base = FriendProfile(
        address: _ada,
        status: FriendRelationshipStatus.accepted,
      );
      FriendProfile unchecked(PeerPresence presence, {int at = 0}) =>
          base.copyWith(
            presence: presence,
            presenceAtMillis: at,
            presenceDoubt: PresenceDoubt.unchecked,
          );
      expect(presenceStateLabel(PeerPresence.unknown), 'status nieznany');
      expect(presenceStateLabel(PeerPresence.noConnection), 'brak połączenia');
      expect(
        friendPresenceLine(
          unchecked(PeerPresence.online, at: now - 12 * _minute),
          now,
        ),
        'status nieznany · ostatnio w sieci 12 min temu',
      );
      expect(
        friendPresenceLine(
          unchecked(PeerPresence.background, at: now - 3 * _hour),
          now,
        ),
        'status nieznany · ostatnio w tle 3 godz. temu',
      );
      expect(
        friendPresenceLine(
          unchecked(
            PeerPresence.offline,
          ).copyWith(lastOpenedAtMillis: now - 2 * _hour),
          now,
        ),
        'status nieznany · ostatnio otwierał(a) 2 godz. temu',
      );
      expect(
        friendPresenceLine(unchecked(PeerPresence.offline), now),
        'status nieznany',
      );
      expect(
        friendPresenceLine(
          unchecked(
            PeerPresence.online,
          ).copyWith(presenceDoubt: PresenceDoubt.noNetwork),
          now,
        ),
        'Nie masz połączenia z siecią',
      );
      expect(
        base
            .copyWith(
              presence: PeerPresence.offline,
              presenceDoubt: PresenceDoubt.noNetwork,
            )
            .shownPresence,
        PeerPresence.noConnection,
        reason: 'about this device, so the same for every friend',
      );
      expect(
        friendPresenceLine(base.copyWith(presence: PeerPresence.unknown), now),
        'Starsza wersja Zen — status nieznany',
      );
      // A friend who does not show it shows nothing, in doubt or not.
      expect(friendPresenceLine(unchecked(PeerPresence.hidden), now), isNull);
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
                book: FriendshipBook.restore(
                  profiles: <String, FriendProfile>{_ada: ada},
                ),
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

    testWidgets('the chat header shows each state', (
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

      // Not known now: the dot says so, the words say why.
      await pumpConversation(
        tester,
        base.copyWith(
          presence: PeerPresence.background,
          presenceAtMillis: now - 12 * _minute,
          presenceDoubt: PresenceDoubt.unchecked,
        ),
      );
      await tester.pumpAndSettle();
      expect(subtitle(tester), 'status nieznany · ostatnio w tle 12 min temu');
      expect(headerDot(tester).unknown, isTrue);
      expect(headerDot(tester).away, isFalse);

      // This device has no network: its own look, and the words say whose
      // connection it is.
      await pumpConversation(
        tester,
        base.copyWith(
          presence: PeerPresence.online,
          presenceAtMillis: now,
          presenceDoubt: PresenceDoubt.noNetwork,
        ),
      );
      await tester.pumpAndSettle();
      expect(subtitle(tester), 'Nie masz połączenia z siecią');
      expect(headerDot(tester).noConnection, isTrue);
      expect(headerDot(tester).on, isFalse);
      expect(headerDot(tester).unknown, isFalse);

      await pumpConversation(
        tester,
        base.copyWith(
          presence: PeerPresence.hidden,
          presenceDoubt: PresenceDoubt.noNetwork,
        ),
      );
      await tester.pumpAndSettle();
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
                book: FriendshipBook.restore(
                  profiles: <String, FriendProfile>{
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
                    _carol: FriendProfile(
                      address: _carol,
                      displayName: 'Carol',
                      status: FriendRelationshipStatus.accepted,
                      presence: PeerPresence.online,
                      presenceAtMillis: now,
                      presenceDoubt: PresenceDoubt.noNetwork,
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
      // Carol's cannot be known (this device has no network): its own
      // look, neither online, offline nor "status nieznany".
      expect(avatarOf('Carol').noConnection, isTrue);
      expect(avatarOf('Carol').unknown, isFalse);
      expect(avatarOf('Carol').online, isFalse);
      expect(avatarOf('Carol').showStatus, isTrue);
      // The dot says it in words, too.
      expect(
        find.bySemanticsLabel(
          RegExp(r'^w tle · ostatnio otwierał\(a\) 5 min temu'),
        ),
        findsWidgets,
      );
      expect(
        find.bySemanticsLabel(RegExp(r'^Nie masz połączenia z siecią')),
        findsWidgets,
      );
    });

    testWidgets('the dot has five looks', (WidgetTester tester) async {
      Future<void> pumpDot(
        bool on,
        bool away, {
        bool unknown = false,
        bool noConnection = false,
      }) => tester.pumpWidget(
        MaterialApp(
          home: Center(
            child: ZenStatusDot(
              on: on,
              away: away,
              unknown: unknown,
              noConnection: noConnection,
            ),
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

      // Not known: a filled grey dot with a question mark, unlike the
      // empty ring of offline.
      await pumpDot(false, false, unknown: true);
      final BoxDecoration unknown = boxes().single;
      expect(unknown.color, isNotNull, reason: 'filled, offline is empty');
      expect(unknown.border, isNull);
      expect(unknown.color, isNot(onColor));
      expect(
        find.descendant(
          of: find.byType(ZenStatusDot),
          matching: find.byIcon(Icons.question_mark_rounded),
        ),
        findsOneWidget,
      );

      // No network here: a crossed-out cloud, neither a ring nor a dot.
      await pumpDot(false, false, noConnection: true);
      expect(boxes(), isEmpty);
      expect(
        find.descendant(
          of: find.byType(ZenStatusDot),
          matching: find.byIcon(Icons.cloud_off_rounded),
        ),
        findsOneWidget,
      );
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
