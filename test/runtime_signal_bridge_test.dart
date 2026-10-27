import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/app/app.dart';
import 'package:zen/src/domain/friends/friend_profile.dart';
import 'package:zen/src/domain/friends/peer_presence.dart';
import 'package:zen/src/domain/groups/group_profile.dart';
import 'package:zen/src/features/runtime/runtime_signal_module.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';
import 'package:zen/src/features/security/app_security_service.dart';
import 'package:zen/src/features/settings/app_settings.dart';
import 'package:zen/src/features/settings/app_settings_controller.dart';
import 'package:zen/src/features/settings/app_settings_store.dart';
import 'package:zen/src/features/shell/presentation/app_shell_screen.dart';
import 'package:zen/src/features/social/social_hub_controller.dart';
import 'package:zen/src/features/social/social_hub_state.dart';
import 'package:zen/src/features/social/social_snapshot_store.dart';

void main() {
  testWidgets('runtime signal bridge pings accepted friends on startup', (
    WidgetTester tester,
  ) async {
    final MemorySignalTransport transport = MemorySignalTransport();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          signalTransportProvider.overrideWithValue(transport),
          socialHubSeedProvider.overrideWithValue(_seedState()),
        ],
        child: const ZenRewriteApp(),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      transport.sentSignals.where((entry) => entry.payload['type'] == 'ping'),
      hasLength(1),
    );
    expect(
      transport.sentSignals
          .singleWhere((entry) => entry.payload['type'] == 'ping')
          .remoteAddress,
      _adaAddress,
    );
  });

  test('presence pings go to friends and unconfirmed invitees only', () {
    final SocialHubState state = _seedState().copyWith(
      groups: <String, GroupProfile>{
        'g1': const GroupProfile(
          id: 'g1',
          name: 'Klub',
          createdById: 'self',
          createdAtMillis: 1,
          memberAddresses: <String>[_adaAddress, _memberAddress, _invitee],
          pendingInviteAddresses: <String>[_invitee],
        ),
      },
    );
    expect(
      presencePingTargets(state),
      unorderedEquals(<String>[_adaAddress, _invitee]),
    );
    // Rarely: every ping wakes the radio of the phone it goes to.
    expect(
      const RuntimePresenceConfig().pingInterval,
      greaterThanOrEqualTo(const Duration(minutes: 2)),
    );
    expect(
      const RuntimePresenceConfig().offlineAfter,
      greaterThan(const RuntimePresenceConfig().pingInterval * 2),
    );
    // "w tle" outlasts two answers of a locked phone (one every other
    // ping): one lost answer is not "offline".
    expect(
      const RuntimePresenceConfig().offlineAfter,
      greaterThan(kPresencePingInterval * 4),
    );
    // "Online" expires sooner, but not before two pings went unanswered.
    expect(
      const RuntimePresenceConfig().foregroundFor,
      lessThan(const RuntimePresenceConfig().offlineAfter),
    );
    expect(
      const RuntimePresenceConfig().foregroundFor,
      greaterThan(kPresencePingInterval * 2),
    );
  });

  testWidgets('presence pings stop off the screen; friends hear "away" and '
      '"I am here"', (WidgetTester tester) async {
    final MemorySignalTransport transport = MemorySignalTransport();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          signalTransportProvider.overrideWithValue(transport),
          socialHubSeedProvider.overrideWithValue(_seedState()),
        ],
        child: const ZenRewriteApp(),
      ),
    );
    await tester.pumpAndSettle();
    int sent(String type) => transport.sentSignals
        .where((entry) => entry.payload['type'] == type)
        .length;
    expect(sent('ping'), 1);

    for (final AppLifecycleState state in <AppLifecycleState>[
      AppLifecycleState.inactive,
      AppLifecycleState.hidden,
      AppLifecycleState.paused,
    ]) {
      tester.binding.handleAppLifecycleStateChanged(state);
    }
    await tester.pump();
    await tester.pump();
    expect(sent('away'), 1);
    expect(
      transport.sentSignals
          .lastWhere((entry) => entry.payload['type'] == 'away')
          .remoteAddress,
      _adaAddress,
    );
    // Off the screen nobody is pinged, however long it stays there.
    await tester.pump(const Duration(minutes: 20));
    expect(sent('ping'), 1);

    for (final AppLifecycleState state in <AppLifecycleState>[
      AppLifecycleState.hidden,
      AppLifecycleState.inactive,
      AppLifecycleState.resumed,
    ]) {
      tester.binding.handleAppLifecycleStateChanged(state);
    }
    await tester.pump();
    await tester.pump();
    expect(sent('ping'), 2, reason: '"I am here" on coming back');
    await tester.pump(kPresencePingInterval);
    expect(sent('ping'), 3);
  });

  testWidgets('a glance at another app pings no one again, and leaving '
      'again sends no second "away"', (WidgetTester tester) async {
    final MemorySignalTransport transport = MemorySignalTransport();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          signalTransportProvider.overrideWithValue(transport),
          socialHubSeedProvider.overrideWithValue(_seedState()),
        ],
        child: const ZenRewriteApp(),
      ),
    );
    await tester.pumpAndSettle();
    int sent(String type) => transport.sentSignals
        .where((entry) => entry.payload['type'] == type)
        .length;
    void leave() {
      for (final AppLifecycleState state in <AppLifecycleState>[
        AppLifecycleState.inactive,
        AppLifecycleState.hidden,
        AppLifecycleState.paused,
      ]) {
        tester.binding.handleAppLifecycleStateChanged(state);
      }
    }

    void comeBack() {
      for (final AppLifecycleState state in <AppLifecycleState>[
        AppLifecycleState.hidden,
        AppLifecycleState.inactive,
        AppLifecycleState.resumed,
      ]) {
        tester.binding.handleAppLifecycleStateChanged(state);
      }
    }

    expect(sent('ping'), 1);
    leave();
    await tester.pump();
    await tester.pump();
    expect(sent('away'), 1);

    await tester.pump(const Duration(seconds: 20));
    comeBack();
    await tester.pump();
    await tester.pump();
    expect(sent('ping'), 1, reason: 'pinged lately: the next round on time');

    leave();
    await tester.pump();
    await tester.pump();
    expect(sent('away'), 1, reason: 'friends already saw "away"');

    comeBack();
    await tester.pump();
    // The round comes a ping interval after the last one.
    await tester.pump(kPresencePingInterval);
    expect(sent('ping'), 2);
    leave();
    await tester.pump();
    await tester.pump();
    // Owed again after the round, but an "away" went out lately: this one
    // goes when kPresenceAwayEvery is over.
    expect(sent('away'), 1);
    await tester.pump(kPresenceAwayEvery);
    expect(sent('away'), 2);
  });

  testWidgets('a friend\'s ping and "away" show at once', (
    WidgetTester tester,
  ) async {
    final MemorySignalTransport transport = MemorySignalTransport();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          signalTransportProvider.overrideWithValue(transport),
          socialHubSeedProvider.overrideWithValue(_seedState()),
        ],
        child: const ZenRewriteApp(),
      ),
    );
    await tester.pump();
    final ProviderContainer container = ProviderScope.containerOf(
      tester.element(find.byType(AppShellScreen)),
    );
    await transport.injectIncoming(
      from: _adaAddress,
      payload: const <String, dynamic>{
        'type': 'ping',
        'state': 'foreground',
        'lo': 0,
      },
    );
    await tester.pumpAndSettle();
    FriendProfile ada() =>
        container.read(socialHubControllerProvider).friends[_adaAddress]!;
    expect(ada().isOnline, isTrue);
    expect(ada().presence, PeerPresence.online);
    expect(ada().lastOpenedAtMillis, greaterThan(0));
    // Presence never takes over the chat list's time of the last message.
    expect(ada().lastActivityLabel, isEmpty);

    await transport.injectIncoming(
      from: _adaAddress,
      payload: const <String, dynamic>{
        'type': 'away',
        'state': 'background',
        'lo': 0,
      },
    );
    await tester.pumpAndSettle();
    expect(ada().isOnline, isTrue, reason: 'still reachable in the background');
    expect(ada().presence, PeerPresence.background);

    // An iPhone leaving the screen stops receiving: offline at once, with
    // when it was last open.
    await transport.injectIncoming(
      from: _adaAddress,
      payload: const <String, dynamic>{
        'type': 'away',
        'state': 'asleep',
        'lo': 0,
      },
    );
    await tester.pumpAndSettle();
    expect(ada().isOnline, isFalse);
    expect(ada().presence, PeerPresence.offline);
    expect(ada().lastOpenedAtMillis, greaterThan(0));

    // A ping without a state: they do not show presence to this person.
    await transport.injectIncoming(
      from: _adaAddress,
      payload: const <String, dynamic>{'type': 'ping'},
    );
    await tester.pumpAndSettle();
    expect(ada().isOnline, isTrue);
    expect(ada().presence, PeerPresence.hidden);
    expect(ada().lastOpenedAtMillis, 0);
  });

  testWidgets('runtime signal bridge answers ping and applies pong presence', (
    WidgetTester tester,
  ) async {
    final MemorySignalTransport transport = MemorySignalTransport();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          signalTransportProvider.overrideWithValue(transport),
          socialHubSeedProvider.overrideWithValue(_seedState()),
        ],
        child: const ZenRewriteApp(),
      ),
    );
    await tester.pump();

    await transport.injectIncoming(
      from: _adaAddress,
      payload: const <String, dynamic>{'type': 'ping'},
    );
    await tester.pumpAndSettle();

    // The answer is a pong (a `census` frame may go along with it).
    final pong = transport.sentSignals.lastWhere(
      (entry) => entry.payload['type'] == 'pong',
    );
    expect(pong.remoteAddress, _adaAddress);
    // The pong also carries the hello digests (see MeetService.helloFor).
    expect(pong.payload, containsPair('state', 'foreground'));
    expect(pong.payload, contains('ms'));

    await transport.injectIncoming(
      from: _adaAddress,
      payload: const <String, dynamic>{'type': 'pong', 'state': 'foreground'},
    );
    await tester.pumpAndSettle();

    final ProviderContainer container = ProviderScope.containerOf(
      tester.element(find.byType(AppShellScreen)),
    );
    final FriendProfile friend = container
        .read(socialHubControllerProvider)
        .friends[_adaAddress]!;
    expect(friend.isOnline, isTrue);
    expect(friend.lastPresenceAtMillis, greaterThan(0));
    expect(friend.presence, PeerPresence.online);
    // No "lo": they keep their last opening to themselves.
    expect(friend.lastOpenedAtMillis, 0);
  });

  testWidgets(
    'runtime signal bridge routes transport messages into social state',
    (WidgetTester tester) async {
      final MemorySignalTransport transport = MemorySignalTransport();

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            signalTransportProvider.overrideWithValue(transport),
            socialHubSeedProvider.overrideWithValue(_seedState()),
          ],
          child: const ZenRewriteApp(),
        ),
      );
      await tester.pump();

      await transport.injectIncoming(
        from: _adaAddress,
        payload: const <String, dynamic>{
          'type': 'message',
          'msgId': 'm-1',
          'text': 'Wpadnij na czat.',
        },
      );
      await tester.pumpAndSettle();

      final ProviderContainer container = ProviderScope.containerOf(
        tester.element(find.byType(AppShellScreen)),
      );
      final FriendProfile friend = container
          .read(socialHubControllerProvider)
          .friends[_adaAddress]!;
      expect(friend.lastMessagePreview, 'Wpadnij na czat.');
      expect(friend.unreadCount, 1);
      expect(
        transport.sentSignals.any(
          (entry) =>
              entry.remoteAddress == _adaAddress &&
              entry.payload['type'] == 'message_ack' &&
              entry.payload['msgId'] == 'm-1',
        ),
        isTrue,
      );
    },
  );

  testWidgets(
    'runtime signal bridge stays background while the app is locked',
    (WidgetTester tester) async {
      final MemorySignalTransport transport = MemorySignalTransport();
      final MemoryAppSettingsStore settingsStore = MemoryAppSettingsStore(
        const AppSettings(),
      );
      final MemoryAppSecurityService security = MemoryAppSecurityService(
        settings: const AppSettings(),
        hasPassword: true,
        locked: true,
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            signalTransportProvider.overrideWithValue(transport),
            socialHubSeedProvider.overrideWithValue(_seedState()),
            appSettingsStoreProvider.overrideWithValue(settingsStore),
            appSecurityServiceProvider.overrideWithValue(security),
          ],
          child: const ZenRewriteApp(),
        ),
      );
      await tester.pump();

      expect(
        transport.sentSignals.where((entry) => entry.payload['type'] == 'ping'),
        isEmpty,
      );

      await transport.injectIncoming(
        from: _adaAddress,
        payload: const <String, dynamic>{'type': 'ping'},
      );
      await tester.pumpAndSettle();

      expect(transport.sentSignals, isEmpty);
    },
  );

  testWidgets('runtime signal bridge ignores presence traffic from strangers', (
    WidgetTester tester,
  ) async {
    final MemorySignalTransport transport = MemorySignalTransport();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          signalTransportProvider.overrideWithValue(transport),
          socialHubSeedProvider.overrideWithValue(_seedState()),
        ],
        child: const ZenRewriteApp(),
      ),
    );
    await tester.pump();

    const String strangerAddress = '200:9999::1';
    await transport.injectIncoming(
      from: strangerAddress,
      payload: const <String, dynamic>{'type': 'ping'},
    );
    await transport.injectIncoming(
      from: strangerAddress,
      payload: const <String, dynamic>{'type': 'pong', 'state': 'foreground'},
    );
    await tester.pumpAndSettle();

    // Nothing at all goes back to a stranger (a reply would confirm the
    // device is online), and their presence is not recorded.
    expect(
      transport.sentSignals.where(
        (entry) => entry.remoteAddress == strangerAddress,
      ),
      isEmpty,
    );
    final ProviderContainer container = ProviderScope.containerOf(
      tester.element(find.byType(AppShellScreen)),
    );
    expect(
      container
          .read(socialHubControllerProvider)
          .friends
          .containsKey(strangerAddress),
      isFalse,
    );
  });

  testWidgets(
    'runtime signal bridge stays silent while the snapshot is unreadable',
    (WidgetTester tester) async {
      final MemorySignalTransport transport = MemorySignalTransport();

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            signalTransportProvider.overrideWithValue(transport),
            socialSnapshotStoreProvider.overrideWithValue(
              _UnreadableSnapshotStore(),
            ),
          ],
          child: const ZenRewriteApp(),
        ),
      );
      await tester.pumpAndSettle();
      final ProviderContainer container = ProviderScope.containerOf(
        tester.element(find.byType(AppShellScreen)),
      );
      expect(
        container.read(socialHubControllerProvider).snapshotUnreadable,
        isTrue,
      );
      expect(
        find.byKey(const Key('social-data-unreadable-notice')),
        findsOneWidget,
      );

      // A friend whose entry could not be read pings as usual.
      await transport.injectIncoming(
        from: _adaAddress,
        payload: const <String, dynamic>{'type': 'ping'},
      );
      await transport.injectIncoming(
        from: _adaAddress,
        payload: const <String, dynamic>{'type': 'message', 'msgId': 'm-1'},
      );
      await tester.pumpAndSettle();

      expect(
        transport.sentSignals.where(
          (entry) => entry.remoteAddress == _adaAddress,
        ),
        isEmpty,
      );
    },
  );

  testWidgets('runtime signal bridge subscribes to frames before starting', (
    WidgetTester tester,
  ) async {
    final _OrderRecordingTransport transport = _OrderRecordingTransport();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          signalTransportProvider.overrideWithValue(transport),
          socialHubSeedProvider.overrideWithValue(_seedState()),
        ],
        child: const ZenRewriteApp(),
      ),
    );
    await tester.pump();

    // `frames` is a broadcast stream: a frame emitted between start() and
    // listen() is lost, so the subscription must come first.
    expect(transport.events.first, 'listen');
    expect(transport.events, contains('start'));
    expect(
      transport.events.indexOf('listen'),
      lessThan(transport.events.indexOf('start')),
    );
  });
}

/// A snapshot whose file and backup both fail to read (app unlocked).
final class _UnreadableSnapshotStore implements SocialSnapshotStore {
  @override
  Future<SocialHubState?> load() async {
    throw const FormatException('unreadable');
  }

  @override
  Future<void> save(SocialHubState state) async {
    fail('an unreadable snapshot must never be saved over');
  }
}

/// Records whether `frames` was listened to before `start()` ran.
final class _OrderRecordingTransport implements SignalTransport {
  final List<String> events = <String>[];
  late final StreamController<SignalTransportFrame> _frames =
      StreamController<SignalTransportFrame>.broadcast(
        onListen: () => events.add('listen'),
      );

  @override
  Stream<SignalTransportFrame> get frames => _frames.stream;

  @override
  Future<void> start() async {
    events.add('start');
  }

  @override
  Future<void> stop() async {}

  @override
  Future<void> send({
    required String remoteAddress,
    required Map<String, dynamic> payload,
  }) async {}

  @override
  Future<int> openRelay({
    required String callId,
    required String remoteAddress,
  }) async => 0;

  @override
  Future<void> closeRelay(String callId) async {}
}

const String _adaAddress = '200:1111:2222:3333:4444:5555:6666:7777';
const String _memberAddress = '200:1111:2222:3333:4444:5555:6666:8888';
const String _invitee = '200:1111:2222:3333:4444:5555:6666:9999';

SocialHubState _seedState() {
  return SocialHubState.empty().copyWith(
    friends: <String, FriendProfile>{
      _adaAddress: const FriendProfile(
        address: _adaAddress,
        displayName: 'Ada',
        status: FriendRelationshipStatus.accepted,
      ),
    },
  );
}
