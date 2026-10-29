import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/app/app.dart';
import 'package:zen/src/domain/friends/friend_profile.dart';
import 'package:zen/src/domain/signals/signal_queue_store.dart';
import 'package:zen/src/features/relay/mailbox_quiet_notice.dart';
import 'package:zen/src/features/relay/relay_engine.dart';
import 'package:zen/src/features/relay/relay_models.dart';
import 'package:zen/src/features/relay/relay_providers.dart';
import 'package:zen/src/features/relay/relay_state_store.dart';
import 'package:zen/src/features/runtime/runtime_lifecycle_bridge.dart';
import 'package:zen/src/features/social/friendship_book.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';
import 'package:zen/src/features/social/social_hub_controller.dart';
import 'package:zen/src/features/social/social_hub_state.dart';

const int _day = 24 * 60 * 60 * 1000;

final String _ada = PeerShareCodec.normalizeAddress('200::ada');
final String _ewa = PeerShareCodec.normalizeAddress('200::ewa');

final class _Peers implements RelayPeerSource {
  @override
  bool get isReady => true;

  @override
  String get localAddress => PeerShareCodec.normalizeAddress('200::1');

  @override
  List<RelayFriend> acceptedFriends() => <RelayFriend>[
    RelayFriend(address: _ada),
    RelayFriend(address: _ewa),
  ];

  @override
  List<RelayFriend> groupContacts() => const <RelayFriend>[];
}

/// An engine whose hand-picked mailbox, Ada's phone, has not answered for
/// four days; Ewa has an iPhone.
Future<RelayEngine> _engineWithQuietMailbox(int now) async {
  final MemoryRelayStateStore store = MemoryRelayStateStore();
  await store.save(
    RelayState(
      manualRelays: <String>[_ada],
      currentRelays: <String>[_ada],
      peers: <String, RelayPeerInfo>{
        _ada: RelayPeerInfo(
          address: _ada,
          deviceClass: RelayDeviceClass.android,
        ),
        _ewa: RelayPeerInfo(
          address: _ewa,
          deviceClass: RelayDeviceClass.iphone,
        ),
      },
      reach: <String, RelayReach>{
        _ada: RelayReach(
          answered: 10,
          hours: 40,
          sampledAtMillis: now,
          heardAtMillis: now - 4 * _day,
          askedAtMillis: now - 60000,
          failingSinceMillis: now - 4 * _day + 60000,
        ),
      },
    ),
  );
  final RelayEngine engine = RelayEngine(
    store: store,
    peers: _Peers(),
    send: (String to, Map<String, dynamic> payload) async {},
    clock: () => now,
  );
  await engine.activate();
  return engine;
}

void main() {
  testWidgets('a mailbox that stopped answering shows on the chats list, '
      'leads to the picker, and the picker warns about an iPhone', (
    WidgetTester tester,
  ) async {
    final int now = DateTime.now().millisecondsSinceEpoch;
    final RelayEngine engine = (await tester.runAsync(
      () => _engineWithQuietMailbox(now),
    ))!;
    expect(engine.overview.value.quiet, hasLength(1));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          signalQueueStoreProvider.overrideWithValue(MemorySignalQueueStore()),
          runtimeLifecycleBindingEnabledProvider.overrideWithValue(false),
          relayEngineProvider.overrideWithValue(engine),
          socialHubSeedProvider.overrideWithValue(
            SocialHubState.empty().copyWith(
              book: FriendshipBook.restore(
                profiles: <String, FriendProfile>{
                  _ada: FriendProfile(
                    address: _ada,
                    displayName: 'Ada',
                    status: FriendRelationshipStatus.accepted,
                  ),
                  _ewa: FriendProfile(
                    address: _ewa,
                    displayName: 'Ewa',
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

    expect(find.byKey(const Key('relay-quiet-card')), findsOneWidget);
    expect(
      find.text(quietMailboxTitle('Ada', now - 4 * _day, now)),
      findsOneWidget,
    );
    expect(
      find.text('Skrzynka Ada nie odpowiada od 4 dni — wybierz inną'),
      findsOneWidget,
    );

    await tester.ensureVisible(find.byKey(const Key('relay-quiet-card-pick')));
    await tester.tap(find.byKey(const Key('relay-quiet-card-pick')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('relay-settings-screen')), findsOneWidget);
    expect(find.byKey(Key('relay-quiet-$_ada')), findsOneWidget);
    // Ewa's iPhone is marked as a weak mailbox; Ada's phone shows how often
    // it was there.
    expect(find.byKey(Key('relay-friend-weak-$_ewa')), findsOneWidget);
    expect(find.byKey(Key('relay-friend-weak-$_ada')), findsNothing);
    expect(find.text('Android · dostępna przez 25% czasu'), findsOneWidget);
    expect(find.text('Nie odpowiada od 4 dni'), findsOneWidget);
  });
}
