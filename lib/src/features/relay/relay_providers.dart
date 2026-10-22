import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zen/src/domain/friends/friend_profile.dart';
import 'package:zen/src/domain/groups/group_profile.dart';
import 'package:zen/src/features/account/account_routing_transport.dart';
import 'package:zen/src/features/ledger/audience_keys.dart';
import 'package:zen/src/features/ledger/friend_level_lookup.dart';
import 'package:zen/src/features/relay/relay_engine.dart';
import 'package:zen/src/features/relay/relay_models.dart';
import 'package:zen/src/features/relay/relay_state_store.dart';
import 'package:zen/src/features/relay/reliable_signal_transport.dart';
import 'package:zen/src/features/runtime/runtime_native_signal_transport.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';
import 'package:zen/src/features/social/social_hub_controller.dart';
import 'package:zen/src/features/social/social_hub_state.dart';

/// The relay engine of this isolate; `null` wherever store-and-forward is not
/// wired up (tests, previews).
final Provider<RelayEngine?> relayEngineProvider = Provider<RelayEngine?>((
  Ref ref,
) {
  return null;
});

/// Where outgoing chat messages are on their way (see
/// `RelayEngine.progress`), for the bubbles' delivery status. Not ready
/// wherever store-and-forward is not wired up.
final Provider<RelayProgressSnapshot> relayDeliveryProgressProvider =
    Provider<RelayProgressSnapshot>((Ref ref) {
      final RelayEngine? engine = ref.watch(relayEngineProvider);
      if (engine == null) {
        return const RelayProgressSnapshot();
      }
      void changed() => ref.invalidateSelf();
      engine.progress.addListener(changed);
      ref.onDispose(() => engine.progress.removeListener(changed));
      return engine.progress.value;
    });

/// Whether this device is online most of the time and so makes a good
/// mailbox for friends: a computer (Zen in the tray). Not a phone: an
/// iPhone receives only while Zen is open, and an Android phone, locked or
/// a few minutes in the background, only receives for itself (its
/// background service holds no mail for friends, and every deposit, poll
/// and sync sent to it would wake it for nothing).
bool get zenDeviceStaysOnline => zenPlatformStaysOnline(defaultTargetPlatform);

/// [zenDeviceStaysOnline] for [platform].
bool zenPlatformStaysOnline(TargetPlatform platform) =>
    !kIsWeb &&
    (platform == TargetPlatform.linux ||
        platform == TargetPlatform.macOS ||
        platform == TargetPlatform.windows);

/// Overrides that put [ReliableSignalTransport] between the app and
/// [runtime]. Used by both the UI isolate and the Android background service.
List buildRelayTransportProviderOverrides({
  required RuntimeNodeRuntime runtime,
  required RelayStateStore relayStateStore,
}) {
  return [
    relayEngineProvider.overrideWith((Ref ref) {
      return RelayEngine(
        store: relayStateStore,
        peers: _SocialRelayPeerSource(ref),
        send: (String to, Map<String, dynamic> payload) =>
            runtime.send(remoteAddress: to, payload: payload),
        // Attachments through mailboxes, where the store can keep chunks.
        blobStore: switch (relayStateStore) {
          final RelayBlobStore blobs => blobs,
          _ => null,
        },
        staysOnline: zenDeviceStaysOnline,
      );
    }),
    signalTransportProvider.overrideWith((Ref ref) {
      final _RuntimeRunningListenable nodeRunning = _RuntimeRunningListenable(
        runtime,
      );
      final ReliableSignalTransport transport = ReliableSignalTransport(
        delegate: runtime,
        engine: ref.watch(relayEngineProvider)!,
        nodeRunning: nodeRunning,
      );
      ref.onDispose(() async {
        await transport.dispose();
        nodeRunning.dispose();
      });
      // Friends with several devices look like one person.
      return withAccountRouting(ref, transport);
    }),
  ];
}

final class _SocialRelayPeerSource implements RelayPeerSource {
  _SocialRelayPeerSource(this._ref) {
    // Not right here: this runs while the transport is being built, and the
    // social hub needs the transport — reading it now is a provider cycle
    // (the background service would fail to start).
    scheduleMicrotask(() {
      unawaited(
        _ref
            .read(socialHubControllerProvider.notifier)
            .whenHydrated
            .then((_) => _ready = true),
      );
    });
  }

  final Ref _ref;
  bool _ready = false;

  @override
  bool get isReady => _ready;

  @override
  String get localAddress =>
      _ref.read(runtimeNodeSnapshotProvider).localAddress;

  @override
  List<RelayFriend> acceptedFriends() {
    final FriendLevelLookup levels = _ref.read(friendLevelLookupProvider);
    return _ref
        .read(socialHubControllerProvider)
        .acceptedFriends
        .map(
          (FriendProfile friend) => RelayFriend(
            address: friend.address,
            lastSeenAtMillis: friend.lastPresenceAtMillis,
            closeness: (levels.of(friend.address) ?? FriendLevel.friend).index,
          ),
        )
        .toList(growable: false);
  }

  @override
  List<RelayFriend> groupContacts() {
    final SocialHubState state = _ref.read(socialHubControllerProvider);
    final String self = PeerShareCodec.normalizeAddress(localAddress);
    final Set<String> seen = <String>{};
    final List<RelayFriend> contacts = <RelayFriend>[];
    for (final GroupProfile group in state.groups.values) {
      if (group.isInvitePending) {
        // Not joined: its members are strangers until the user says yes.
        continue;
      }
      for (final String member in group.memberAddresses) {
        final String address = PeerShareCodec.normalizeAddress(member);
        if (address.isEmpty || address == self || !seen.add(address)) {
          continue;
        }
        final FriendProfile? profile = state.friendByAddress(address);
        // Friends are covered already; blocked people get nothing.
        if (profile != null &&
            (profile.status == FriendRelationshipStatus.accepted ||
                profile.status == FriendRelationshipStatus.blocked)) {
          continue;
        }
        contacts.add(RelayFriend(address: address));
      }
    }
    return contacts;
  }
}

/// `true` while [runtime] has a live node.
final class _RuntimeRunningListenable extends ChangeNotifier
    implements ValueListenable<bool> {
  _RuntimeRunningListenable(this._runtime) {
    _value = _runtime.snapshot.serviceRunning;
    _runtime.addListener(_update);
  }

  final RuntimeNodeRuntime _runtime;
  late bool _value;

  @override
  bool get value => _value;

  void _update() {
    final bool next = _runtime.snapshot.serviceRunning;
    if (next != _value) {
      _value = next;
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _runtime.removeListener(_update);
    super.dispose();
  }
}
