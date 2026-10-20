import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zen/src/app/peer_version.dart';
import 'package:zen/src/core/logging/zen_log.dart';
import 'package:zen/src/domain/friends/friend_profile.dart';
import 'package:zen/src/domain/groups/group_profile.dart';
import 'package:zen/src/domain/signals/zen_signal.dart';
import 'package:zen/src/features/account/recovery_providers.dart';
import 'package:zen/src/features/dating/dating_providers.dart';
import 'package:zen/src/features/ledger/ledger_providers.dart';
import 'package:zen/src/features/meet/intro/intro_providers.dart';
import 'package:zen/src/features/meet/meet_providers.dart';
import 'package:zen/src/features/meet/plan/plan_providers.dart';
import 'package:zen/src/features/neighbors/neighbors_providers.dart';
import 'package:zen/src/features/pyramid/pyramid_providers.dart';
import 'package:zen/src/features/runtime/runtime_native_signal_transport.dart';
import 'package:zen/src/features/runtime/runtime_signal_parser.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';
import 'package:zen/src/features/security/app_security_service.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';
import 'package:zen/src/features/social/social_hub_controller.dart';
import 'package:zen/src/features/social/social_hub_state.dart';
import 'package:zen/src/features/update/update_service.dart';

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

class RuntimeSignalBridge extends ConsumerStatefulWidget {
  const RuntimeSignalBridge({required this.child, super.key});

  final Widget child;

  @override
  ConsumerState<RuntimeSignalBridge> createState() =>
      _RuntimeSignalBridgeState();
}

final class _RuntimeSignalBridgeState
    extends ConsumerState<RuntimeSignalBridge> {
  StreamSubscription<SignalTransportFrame>? _subscription;
  SignalTransport? _transport;
  bool? _lastInteractive;
  Timer? _presenceTimer;

  @override
  void initState() {
    super.initState();
    _transport = ref.read(signalTransportProvider);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      unawaitedLogged(() async {
        // Subscribe before starting. `frames` is a broadcast stream, so
        // anything emitted between start() and listen() is gone for good.
        _subscription = _transport!.frames.listen(
          _handleFrame,
          onError: (Object error, StackTrace stackTrace) {
            logZenError('Runtime signal frame stream error', error, stackTrace);
          },
        );
        try {
          await _transport!.start();
        } catch (error, stackTrace) {
          logZenError(
            'Runtime signal transport start failed',
            error,
            stackTrace,
          );
        }
        if (mounted) {
          // Starts the ledger (posts, profiles) once the transport is up.
          ref.read(ledgerNodeProvider);
          ref.read(recoveryServiceProvider);
          // A computer offers itself as a mesh bridge (§5.1).
          ref.read(bridgeHostProvider);
          // New versions of the app from friends (§14.2).
          ref.read(updateServiceProvider);
          // Friends' statuses and alarms; this phone shown nearby (§15–16).
          ref.read(meetServiceProvider);
          ref.read(nearbyServiceProvider);
          ref.read(eventServiceProvider);
          ref.read(askServiceProvider);
          ref.read(tableServiceProvider);
          ref.read(circleServiceProvider);
          // Introductions and letters through friends (§24.1).
          ref.read(introServiceProvider);
          // Flats and neighbours (§18).
          ref.read(neighborsServiceProvider);
          // Dating packages pass through every phone (§19).
          ref.read(datingServiceProvider);
          // The pyramid, its money and crisis mode (§20–24, §28).
          ref.read(pyramidServiceProvider);
          // Plan na weekend (§17.6).
          ref.read(planServiceProvider);
        }
      }(), context: 'Runtime signal bridge startup failed');
    });
  }

  @override
  void dispose() {
    _presenceTimer?.cancel();
    unawaitedLogged(
      _subscription?.cancel(),
      context: 'Runtime signal subscription cancellation failed',
    );
    unawaitedLogged(
      _transport?.stop(),
      context: 'Runtime signal transport stop failed',
    );
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final AppSecurityService security = ref.watch(appSecurityServiceProvider);
    final bool lifecycleInteractive = ref.watch(
      socialHubControllerProvider.select(
        (SocialHubState state) => state.lifecycle.isInteractive,
      ),
    );
    return ListenableBuilder(
      listenable: security,
      child: widget.child,
      builder: (BuildContext context, Widget? child) {
        final bool isInteractive =
            lifecycleInteractive && !_isSecurityBlockingUi(security);
        if (_lastInteractive != isInteractive) {
          _lastInteractive = isInteractive;
          if (isInteractive) {
            _restartPresenceLoop();
            WidgetsBinding.instance.addPostFrameCallback((_) {
              // The node cannot read its sealed config while the app is
              // locked, so the first start after launch can fail. Retry as
              // soon as the UI becomes usable instead of waiting out the
              // runtime's own backoff.
              unawaitedLogged(
                _transport?.start(),
                context: 'Runtime transport restart after resume failed',
              );
              unawaitedLogged(
                _tickPresenceLoop(),
                context: 'Runtime presence tick failed after resume',
              );
            });
          } else {
            _presenceTimer?.cancel();
          }
        }
        return child!;
      },
    );
  }

  Future<void> _handleFrame(SignalTransportFrame frame) async {
    final String from = PeerShareCodec.normalizeAddress(frame.from);
    final String type = frame.payload['type'] as String? ?? '';
    final SignalTransport? transport = _transport;
    final SocialHubController hub = ref.read(
      socialHubControllerProvider.notifier,
    );
    if ((type == 'ping' || type == 'pong') &&
        (!hub.isHydrated ||
            ref.read(socialHubControllerProvider).snapshotUnreadable)) {
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
    return ref
            .read(socialHubControllerProvider)
            .friendByAddress(address)
            ?.status ==
        FriendRelationshipStatus.accepted;
  }

  bool _isAcceptedFriendOrGroupMember(String address) {
    if (_isAcceptedFriendAddress(address)) {
      return true;
    }
    final SocialHubState hubState = ref.read(socialHubControllerProvider);
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
    final SocialHubState hubState = ref.read(socialHubControllerProvider);
    final String localAddr = ref.read(runtimeNodeSnapshotProvider).localAddress;
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
      return ref.read(meetServiceProvider).helloFor(friend);
    } on Object {
      return const <String, dynamic>{};
    }
  }

  void _restartPresenceLoop() {
    _presenceTimer?.cancel();
    final Duration interval = ref
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
    if (!mounted || !_isUiInteractive()) {
      return;
    }
    await ref.read(socialHubControllerProvider.notifier).whenHydrated;
    if (!mounted || !_isUiInteractive()) {
      return;
    }
    final RuntimePresenceConfig config = ref.read(
      runtimePresenceConfigProvider,
    );
    await _sendPresencePings();
    if (!mounted) {
      return;
    }
    await ref
        .read(socialHubControllerProvider.notifier)
        .decayPresence(offlineAfter: config.offlineAfter);
  }

  String _presenceStateLabel() {
    return _isUiInteractive() ? 'foreground' : 'background';
  }

  bool _isUiInteractive() {
    final AppSecurityService security = ref.read(appSecurityServiceProvider);
    return ref.read(socialHubControllerProvider).lifecycle.isInteractive &&
        !_isSecurityBlockingUi(security);
  }

  bool _isSecurityBlockingUi(AppSecurityService security) {
    if (!security.isReady) {
      return true;
    }
    return security.encryptionEnabled &&
        security.hasPassword &&
        security.isLocked;
  }
}
