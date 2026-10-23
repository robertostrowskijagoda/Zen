import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/app/app.dart';
import 'package:zen/src/app/app_version.dart';
import 'package:zen/src/app/peer_version.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/core/storage/binary_store.dart';
import 'package:zen/src/domain/friends/friend_profile.dart';
import 'package:zen/src/features/runtime/runtime_system_notifications.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';
import 'package:zen/src/features/shell/presentation/app_shell_screen.dart';
import 'package:zen/src/features/social/social_hub_controller.dart';
import 'package:zen/src/features/social/social_hub_state.dart';
import 'package:zen/src/features/social/social_snapshot_store.dart';
import 'package:zen/src/features/update/presentation/friends_version_banner.dart';

const String _ada = '200:1111:2222:3333:4444:5555:6666:7777';
const String _bob = '200:aaaa:bbbb:cccc:dddd:eeee:ffff:1111';

/// Versions newer than this build's, whatever it is.
final List<int> _own = kAppVersion.split('.').map(int.parse).toList();
final String _next = '${_own[0]}.${_own[1] + 1}.0';
final String _after = '${_own[0]}.${_own[1] + 2}.0';

SocialHubState _seed() => SocialHubState.empty().copyWith(
  friends: <String, FriendProfile>{
    _ada: const FriendProfile(
      address: _ada,
      displayName: 'Ada',
      status: FriendRelationshipStatus.accepted,
    ),
    _bob: const FriendProfile(
      address: _bob,
      displayName: 'Bob',
      status: FriendRelationshipStatus.pendingOutgoing,
    ),
  },
);

ProviderContainer _container() => ProviderContainer(
  overrides: [
    socialHubAutoHydrateProvider.overrideWithValue(false),
    socialHubSeedProvider.overrideWithValue(_seed()),
    signalTransportProvider.overrideWithValue(MemorySignalTransport()),
    runtimeSystemNotificationServiceProvider.overrideWithValue(
      MemoryRuntimeSystemNotificationService(),
    ),
  ],
);

void main() {
  group('versions', () {
    test('compare numerically, not as text', () {
      expect(compareAppVersions('1.10.0', '1.9.3'), greaterThan(0));
      expect(compareAppVersions('1.10.0', '1.10.0'), 0);
      expect(compareAppVersions('1.10.0', '1.10.1'), lessThan(0));
      expect(compareAppVersions('2.0.0', '1.99.99'), greaterThan(0));
      expect(compareAppVersions('bad', '0.0.1'), lessThan(0));
    });

    test('the newest one above ours, if any', () {
      expect(
        newestVersionAbove(<String>['1.9.0', '1.10.0'], ours: '1.10.0'),
        isNull,
      );
      expect(
        newestVersionAbove(<String>[
          '1.11.0',
          '1.12.1',
          'x.y.z',
          '99999.0.0',
        ], ours: '1.10.0'),
        '1.12.1',
      );
    });

    test('garbage from a peer is not taken', () {
      for (final Object? ver in <Object?>[
        null,
        11,
        '',
        '1.11',
        '1.11.0-beta',
        '1.11.0\n',
        '${'1' * 40}.0.0',
      ]) {
        expect(
          PeerVersion.fromPayload(<String, dynamic>{'ver': ver}),
          isNull,
          reason: '$ver',
        );
      }
      final PeerVersion v = PeerVersion.fromPayload(<String, dynamic>{
        'ver': '1.11.0',
        'build': -4,
        'caps': <Object?>[
          'ok_1',
          'Not Ok',
          7,
          'x' * 33,
          for (int i = 0; i < 100; i++) 'c$i',
        ],
      })!;
      expect(v.build, isNull);
      expect(v.caps.first, 'ok_1');
      expect(v.caps, hasLength(kMaxPeerCaps));
      expect(v.caps, isNot(contains('Not Ok')));
    });
  });

  group('the hub remembers what friends run', () {
    test('accepted friends only, and only valid versions', () async {
      final ProviderContainer container = _container();
      addTearDown(container.dispose);
      final SocialHubController hub = container.read(
        socialHubControllerProvider.notifier,
      );
      await hub.notePeerAppVersion(peerAddress: _ada, version: _next);
      await hub.notePeerAppVersion(peerAddress: _bob, version: _after);
      await hub.notePeerAppVersion(peerAddress: _ada, version: 'nonsense');
      await hub.notePeerAppVersion(peerAddress: '200::1', version: '9.0.0');
      final SocialHubState state = container.read(socialHubControllerProvider);
      expect(state.peerAppVersions, <String, String>{_ada: _next});
      expect(newestFriendVersion(state), _next);
      expect(container.read(friendsNewerVersionProvider), _next);
    });

    test('an older or equal version gives no hint', () {
      final SocialHubState state = _seed().copyWith(
        peerAppVersions: <String, String>{_ada: kAppVersion, _bob: '99.0.0'},
      );
      // Bob is not an accepted friend: his claim does not count.
      expect(newestFriendVersion(state), isNull);
    });

    test('the snapshot keeps it; one without it still loads', () async {
      final Directory dir = await Directory.systemTemp.createTemp(
        'zen-peer-versions-',
      );
      addTearDown(() => dir.delete(recursive: true));
      final FileSocialSnapshotStore store = FileSocialSnapshotStore(
        store: FileBinaryStore(
          dir,
          codec: BinaryCodec(compressor: const _PassThroughCompressor()),
        ),
      );
      await store.save(_seed());
      expect((await store.load())!.peerAppVersions, isEmpty);
      await store.save(
        _seed().copyWith(
          peerAppVersions: <String, String>{
            _ada: '1.11.0',
            // Someone no longer a friend is not kept.
            '200::dead': _next,
          },
        ),
      );
      final SocialHubState loaded = (await store.load())!;
      expect(loaded.peerAppVersions, <String, String>{_ada: '1.11.0'});
      expect(loaded.friends[_ada]!.displayName, 'Ada');
    });
  });

  testWidgets('ping and pong carry the version both ways', (
    WidgetTester tester,
  ) async {
    final MemorySignalTransport transport = MemorySignalTransport();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          signalTransportProvider.overrideWithValue(transport),
          socialHubSeedProvider.overrideWithValue(_seed()),
        ],
        child: const ZenRewriteApp(),
      ),
    );
    await tester.pumpAndSettle();

    // Our ping to Ada names this build.
    final Map<String, dynamic> ping = transport.sentSignals
        .firstWhere((e) => e.payload['type'] == 'ping')
        .payload;
    expect(ping['ver'], kAppVersion);
    expect(ping['build'], kAppBuild);
    expect(ping['caps'], kZenCaps);

    // A 1.10.0 ping (no version) is still answered, with our version.
    await transport.injectIncoming(
      from: _ada,
      payload: const <String, dynamic>{'type': 'ping'},
    );
    await tester.pumpAndSettle();
    // The answer is a pong (a `census` frame may go along with it).
    final Map<String, dynamic> pong = transport.sentSignals
        .lastWhere((e) => e.payload['type'] == 'pong')
        .payload;
    expect(pong['ver'], kAppVersion);

    await transport.injectIncoming(
      from: _ada,
      payload: const <String, dynamic>{
        'type': 'pong',
        'state': 'foreground',
        'ver': '99.1.0',
        'caps': <String>['ledger1'],
      },
    );
    await tester.pumpAndSettle();
    final ProviderContainer container = ProviderScope.containerOf(
      tester.element(find.byType(AppShellScreen)),
    );
    final SocialHubState state = container.read(socialHubControllerProvider);
    expect(state.peerAppVersions[_ada], '99.1.0');
    expect(state.friends[_ada]!.isOnline, isTrue);
  });

  testWidgets('the banner shows only while a friend is ahead', (
    WidgetTester tester,
  ) async {
    Future<void> pump(String? version, {String? signed}) => tester.pumpWidget(
      ProviderScope(
        overrides: [
          friendsNewerVersionProvider.overrideWithValue(version),
          signedNewerVersionProvider.overrideWithValue(signed),
        ],
        child: MaterialApp(
          theme: ZenTheme.dark(),
          home: const Scaffold(body: FriendsNewerVersionBanner()),
        ),
      ),
    );

    await pump(null);
    expect(find.byKey(const Key('friends-newer-version-banner')), findsNothing);

    await pump(_next);
    expect(
      find.byKey(const Key('friends-newer-version-banner')),
      findsOneWidget,
    );
    expect(find.textContaining(_next), findsOneWidget);
    expect(find.textContaining('podpisana'), findsNothing);

    // A signature that verified here says so; a friend's claim does not.
    await pump(_next, signed: _after);
    expect(find.textContaining(_after), findsOneWidget);
    expect(find.textContaining('podpisana'), findsOneWidget);
    expect(find.textContaining(_next), findsNothing);
  });
}

final class _PassThroughCompressor implements BinaryCompressor {
  const _PassThroughCompressor();

  @override
  Future<Uint8List?> compress(Uint8List input, int level) async => input;

  @override
  Future<Uint8List?> decompress(Uint8List input) async => input;
}
