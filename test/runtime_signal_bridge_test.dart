import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/app/app.dart';
import 'package:zen/src/domain/friends/friend_profile.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';
import 'package:zen/src/features/security/app_security_service.dart';
import 'package:zen/src/features/settings/app_settings.dart';
import 'package:zen/src/features/settings/app_settings_controller.dart';
import 'package:zen/src/features/settings/app_settings_store.dart';
import 'package:zen/src/features/shell/presentation/app_shell_screen.dart';
import 'package:zen/src/features/social/social_hub_controller.dart';
import 'package:zen/src/features/social/social_hub_state.dart';

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

    expect(transport.sentSignals.last.remoteAddress, _adaAddress);
    // The pong also carries the hello digests (see MeetService.helloFor).
    expect(transport.sentSignals.last.payload, containsPair('type', 'pong'));
    expect(
      transport.sentSignals.last.payload,
      containsPair('state', 'foreground'),
    );
    expect(transport.sentSignals.last.payload, contains('ms'));

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
    expect(friend.lastActivityLabel, 'Teraz');
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
        const AppSettings(encryptionEnabled: true),
      );
      final MemoryAppSecurityService security = MemoryAppSecurityService(
        settings: const AppSettings(encryptionEnabled: true),
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

    // No pong goes back to a stranger, and their presence is not recorded.
    expect(
      transport.sentSignals.where(
        (entry) =>
            entry.remoteAddress == strangerAddress &&
            entry.payload['type'] == 'pong',
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
