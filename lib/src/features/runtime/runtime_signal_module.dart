import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zen/src/app/peer_version.dart';
import 'package:zen/src/app/zen_core.dart';
import 'package:zen/src/core/logging/zen_log.dart';
import 'package:zen/src/domain/friends/friend_profile.dart';
import 'package:zen/src/domain/groups/group_profile.dart';
import 'package:zen/src/domain/signals/zen_signal.dart';
import 'package:zen/src/features/meet/meet_providers.dart';
import 'package:zen/src/features/runtime/runtime_native_signal_transport.dart';
import 'package:zen/src/features/runtime/runtime_signal_parser.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';
import 'package:zen/src/features/security/app_security_service.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';
import 'package:zen/src/features/social/social_hub_controller.dart';
import 'package:zen/src/features/social/social_hub_state.dart';

final Provider<RuntimePresenceConfig> runtimePresenceConfigProvider =
    Provider<RuntimePresenceConfig>((Ref ref) {
      return const RuntimePresenceConfig();
    });

final class RuntimePresenceConfig {
  const RuntimePresenceConfig({
    this.pingInterval = const Duration(seconds: 45),
    this.offlineAfter = const Duration(minutes: 2),
  });

  final Duration pingInterval;
  final Duration offlineAfter;
}

/// Whether the security gate hides the app (not ready, or locked).
bool isSecurityBlockingUi(AppSecurityService security) {
  if (!security.isReady) {
    return true;
  }
  return security.encryptionEnabled &&
      security.hasPassword &&
      security.isLocked;
}

/// The core's first module: the signal transport, frames into the social
/// state, and friends' presence (ping/pong) while the app is in use.
final class RuntimeSignalModule extends ZenModule {
  RuntimeSignalModule(this._ref);

  final Ref _ref;
  StreamSubscription<SignalTransportFrame>? _subscription;
  SignalTransport? _transport;
  Timer? _presenceTimer;
  bool _running = false;

  @override
  String get id => 'signal';

  @override
  Future<void> start() async {
    final SignalTransport transport = _ref.read(signalTransportProvider);
    _transport = transport;
    _running = true;
    // Subscribe before starting. `frames` is a broadcast stream, so anything
    // emitted between start() and listen() is gone for good.
    _subscription = transport.frames.listen(
      _handleFrame,
      onError: (Object error, StackTrace stackTrace) {
        logZenError('Runtime signal frame stream error', error, stackTrace);
      },
    );
    try {
      await transport.start();
    } catch (error, stackTrace) {
      // The node may not read its sealed config while the app is locked;
      // it starts again once the app is in use (see onInteractiveChanged).
      logZenError('Runtime signal transport start failed', error, stackTrace);
    }
  }

  @override
  FutureOr<void> stop() {
    _running = false;
    _presenceTimer?.cancel();
    _presenceTimer = null;
    final StreamSubscription<SignalTransportFrame>? subscription =
        _subscription;
    _subscription = null;
    unawaitedLogged(
      subscription?.cancel(),
      context: 'Runtime signal subscription cancellation failed',
    );
    final SignalTransport? transport = _transport;
    _transport = null;
    unawaitedLogged(
      transport?.stop(),
      context: 'Runtime signal transport stop failed',
    );
  }

  @override
  void onInteractiveChanged(bool interactive) {
    if (!interactive) {
      _presenceTimer?.cancel();
      return;
    }
    _restartPresenceLoop();
    // After the current frame: this comes from a widget's build.
    scheduleMicrotask(() {
      if (!_running) {
        return;
      }
      // The node cannot read its sealed config while the app is locked, so
      // the first start after launch can fail. Retry as soon as the UI
      // becomes usable instead of waiting out the runtime's own backoff.
      unawaitedLogged(
        _transport?.start(),
        context: 'Runtime transport restart after resume failed',
      );
      unawaitedLogged(
        _tickPresenceLoop(),
        context: 'Runtime presence tick failed after resume',
      );
    });
  }

  Future<void> _handleFrame(SignalTransportFrame frame) async {
    if (!_running) {
      return;
    }
    final String from = PeerShareCodec.normalizeAddress(frame.from);
    final String type = frame.payload['type'] as String? ?? '';
    final SignalTransport? transport = _transport;
    final SocialHubController hub = _ref.read(
      socialHubControllerProvider.notifier,
    );
    if ((type == 'ping' || type == 'pong') &&
        (!hub.isHydrated ||
            _ref.read(socialHubControllerProvider).snapshotUnreadable)) {
      // The friends are not known: not read yet (locked app), or the stored
      // list could not be read at all. Every friend would look like a
      // stranger here, so presence waits - no answer, nothing recorded.
      return;
    }
    // Presence traffic is friend-gated: never reveal our state to, or accept
    // state from, peers we have not accepted.
    final bool isAcceptedFriend = _isAcceptedFriendAddress(from);
    final bool isGroupMember =
        !isAcceptedFriend && _isAcceptedFriendOrGroupMember(from);
    if (type == 'ping') {
      if (transport == null) {
        return;
      }
      if (!isAcceptedFriend && !isGroupMember) {
        // No answer at all to a peer we do not know: any reply would confirm
        // that this device is online at this address. (An automatic
        // `friend_remove` used to go back, which also ended real friendships
        // whenever this side had only lost its friend list.)
        return;
      }
      await transport.send(
        remoteAddress: from,
        payload: <String, dynamic>{
          'type': 'pong',
          'state': _presenceStateLabel(),
          if (isAcceptedFriend) ...versionHello(),
          if (isAcceptedFriend) ..._hello(from),
        },
      );
      if (isAcceptedFriend) {
        await _notePeerVersion(hub, from, frame.payload);
      }
      return;
    }
    if (type == 'pong') {
      if (!isAcceptedFriend && !isGroupMember) {
        // Not taken, and not answered either (see the ping above).
        return;
      }
      await hub.updatePeerPresence(
        peerAddress: from,
        isForeground: (frame.payload['state'] as String? ?? '') == 'foreground',
        observedAtMillis: frame.receivedAtMillis,
      );
      if (isAcceptedFriend) {
        await _notePeerVersion(hub, from, frame.payload);
      }
      return;
    }
    if (isUnconfirmedFriendRemovePayload(frame.payload)) {
      // An older peer's automatic reply, not a person's decision: it must
      // not end the friendship here.
      await hub.receiveUnconfirmedFriendRemove(
        from,
        receivedAtMillis: frame.receivedAtMillis,
      );
      return;
    }
    final ZenSignal? signal = zenSignalFromTransportPayload(
      sender: from,
      payload: frame.payload,
    );
    if (signal == null) {
      return;
    }
    await hub.receiveSignal(signal, receivedAtMillis: frame.receivedAtMillis);
  }

  /// What app version a friend named (A17): only for the "newer Zen" hint.
  Future<void> _notePeerVersion(
    SocialHubController hub,
    String from,
    Map<String, dynamic> payload,
  ) async {
    final PeerVersion? version = PeerVersion.fromPayload(payload);
    if (version != null) {
      await hub.notePeerAppVersion(peerAddress: from, version: version.version);
    }
  }

  bool _isAcceptedFriendAddress(String address) {
    return _ref
            .read(socialHubControllerProvider)
            .friendByAddress(address)
            ?.status ==
        FriendRelationshipStatus.accepted;
  }

  bool _isAcceptedFriendOrGroupMember(String address) {
    if (_isAcceptedFriendAddress(address)) {
      return true;
    }
    final SocialHubState hubState = _ref.read(socialHubControllerProvider);
    // Only groups the user joined: anyone can create an invitation naming
    // themselves its creator, and that must not open presence to them.
    return hubState.groups.values.any(
      (GroupProfile g) =>
          !g.isInvitePending &&
          (g.hasMember(address) ||
              PeerShareCodec.addressesEqual(g.createdById, address)),
    );
  }

  Future<void> _sendPresencePings() async {
    final SignalTransport? transport = _transport;
    if (transport == null) {
      return;
    }
    final SocialHubState hubState = _ref.read(socialHubControllerProvider);
    final String localAddr = _ref
        .read(runtimeNodeSnapshotProvider)
        .localAddress;
    final Set<String> peersToPing = <String>{
      ...hubState.acceptedFriends.map((FriendProfile friend) => friend.address),
      // Not the members of a group the user has not joined yet.
      for (final GroupProfile group in hubState.groupList)
        ...group.memberAddresses,
    };
    for (final String address in peersToPing) {
      if (localAddr.isNotEmpty &&
          PeerShareCodec.addressesEqual(address, localAddr)) {
        continue;
      }
      if (!isRoutablePeerAddress(address)) {
        continue;
      }
      await transport.send(
        remoteAddress: address,
        payload: <String, dynamic>{
          'type': 'ping',
          if (hubState.friendByAddress(address)?.status ==
              FriendRelationshipStatus.accepted) ...<String, dynamic>{
            ...versionHello(),
            ..._hello(address),
          },
        },
      );
    }
  }

  /// What this phone gave [friend] (friend list, nearby key, status), as
  /// short digests: the friend asks again for whatever got lost (B1/B2).
  Map<String, dynamic> _hello(String friend) {
    try {
      return _ref.read(meetServiceProvider).helloFor(friend);
    } on Object {
      return const <String, dynamic>{};
    }
  }

  void _restartPresenceLoop() {
    _presenceTimer?.cancel();
    final Duration interval = _ref
        .read(runtimePresenceConfigProvider)
        .pingInterval;
    if (interval <= Duration.zero) {
      return;
    }
    _presenceTimer = Timer.periodic(interval, (_) {
      unawaitedLogged(
        _tickPresenceLoop(),
        context: 'Runtime presence loop tick failed',
      );
    });
  }

  Future<void> _tickPresenceLoop() async {
    if (!_running || !_isUiInteractive()) {
      return;
    }
    await _ref.read(socialHubControllerProvider.notifier).whenHydrated;
    if (!_running || !_isUiInteractive()) {
      return;
    }
    final RuntimePresenceConfig config = _ref.read(
      runtimePresenceConfigProvider,
    );
    await _sendPresencePings();
    if (!_running) {
      return;
    }
    await _ref
        .read(socialHubControllerProvider.notifier)
        .decayPresence(offlineAfter: config.offlineAfter);
  }

  String _presenceStateLabel() {
    return _isUiInteractive() ? 'foreground' : 'background';
  }

  bool _isUiInteractive() {
    final AppSecurityService security = _ref.read(appSecurityServiceProvider);
    return _ref.read(socialHubControllerProvider).lifecycle.isInteractive &&
        !isSecurityBlockingUi(security);
  }
}
