import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zen/src/app/peer_version.dart';
import 'package:zen/src/app/zen_core.dart';
import 'package:zen/src/app/zen_host.dart';
import 'package:zen/src/core/logging/zen_log.dart';
import 'package:zen/src/domain/friends/friend_profile.dart';
import 'package:zen/src/domain/friends/peer_presence.dart';
import 'package:zen/src/domain/groups/group_profile.dart';
import 'package:zen/src/domain/signals/zen_signal.dart';
import 'package:zen/src/features/ledger/audience_keys.dart';
import 'package:zen/src/features/ledger/friend_level_lookup.dart';
import 'package:zen/src/features/meet/meet_providers.dart';
import 'package:zen/src/features/runtime/locked_presence.dart';
import 'package:zen/src/features/runtime/locked_receiver.dart';
import 'package:zen/src/features/runtime/runtime_native_signal_transport.dart';
import 'package:zen/src/features/runtime/runtime_signal_parser.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';
import 'package:zen/src/features/runtime/zen_wake.dart';
import 'package:zen/src/features/security/app_security_service.dart';
import 'package:zen/src/features/settings/app_settings.dart';
import 'package:zen/src/features/settings/app_settings_controller.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';
import 'package:zen/src/features/social/social_hub_controller.dart';
import 'package:zen/src/features/social/social_hub_state.dart';
import 'package:zen/src/features/update/version_gate.dart';

final Provider<RuntimePresenceConfig> runtimePresenceConfigProvider =
    Provider<RuntimePresenceConfig>((Ref ref) {
      return const RuntimePresenceConfig();
    });

/// How often friends are pinged while Zen is on the screen. Every ping wakes
/// the radio of each friend's phone, which answers, so rarely; the moments
/// that matter are told at once: "I am here" (a ping) when Zen comes on the
/// screen and "away" when it leaves it.
const Duration kPresencePingInterval = Duration(minutes: 2, seconds: 30);

/// A friend "w tle" with no sign of life for this long counts as offline
/// (and no longer reachable directly). A phone in the background never
/// pings; it only answers this phone's pings, which go out only while Zen
/// is on this screen, every [kPresencePingInterval], and a locked phone
/// answers one contact at most every kLockedPongEvery (4 min): an answer
/// comes about every 5 min, up to 6.5 min after coming back on the screen
/// between two rounds. Twice that, so one lost answer is not "offline".
const Duration kPresenceOfflineAfter = Duration(minutes: 12);

/// A friend "online" with no new sign for this long counts as offline. A
/// friend on the screen pings every [kPresencePingInterval] and answers
/// this phone's pings at once, and tells "away" when Zen leaves their
/// screen (an "away" lost: the next answer says "w tle"). Silence for two
/// rounds and a bit means Zen was closed or the phone lost the network.
const Duration kPresenceForegroundFor = Duration(minutes: 6);

/// After coming back on the screen, how long the answers to the first pings
/// may take before friends who did not answer count as offline.
const Duration kPresenceSettleAfterResume = Duration(seconds: 20);

/// "Away" goes to friends at most this often: each one wakes every friend's
/// phone, and switching between apps would send one every few minutes. One
/// held back goes out when the time is over, unless Zen is back on the
/// screen by then (friends then rightly still see it "online"). Shorter
/// than [kPresenceForegroundFor], so a friend never sees this phone
/// offline meanwhile.
const Duration kPresenceAwayEvery = Duration(minutes: 5);

final class RuntimePresenceConfig {
  const RuntimePresenceConfig({
    this.pingInterval = kPresencePingInterval,
    this.offlineAfter = kPresenceOfflineAfter,
    this.foregroundFor = kPresenceForegroundFor,
  });

  final Duration pingInterval;
  final Duration offlineAfter;
  final Duration foregroundFor;
}

/// Whether this device stops receiving once Zen leaves the screen: an
/// iPhone, which iOS suspends, unless the keep-alive runs
/// (docs/IOS_BACKGROUND.md). Friends then see it offline, not "w tle".
final Provider<bool> presenceAsleepOffScreenProvider = Provider<bool>((
  Ref ref,
) {
  if (kIsWeb || defaultTargetPlatform != TargetPlatform.iOS) {
    return false;
  }
  return !ref.watch(
    appSettingsControllerProvider.select(
      (AppSettings settings) => settings.keepReceivingInBackground,
    ),
  );
});

/// Whether a friend at [level] may see this person's presence and last
/// opening: not a weak acquaintance ("Słaby znajomy" sees no statuses but
/// "Nie przeszkadzać"); `null` (the ledger is not up) counts as "Znajomy".
bool presenceVisibleTo(FriendLevel? level) => level != FriendLevel.weak;

/// Who gets presence pings: accepted friends, and the members of a group
/// this phone invited who did not confirm the invite yet (a sign of life
/// from them sends it again). Not the other members of groups: each ping
/// wakes the radio of the phone it goes to.
Set<String> presencePingTargets(SocialHubState state) {
  return <String>{
    ...state.acceptedFriends.map((FriendProfile friend) => friend.address),
    for (final GroupProfile group in state.groupList)
      if (!group.isInvitePending) ...group.pendingInviteAddresses,
  };
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
/// state, and friends' presence while Zen is on the screen: a ping to each
/// friend now and then ([kPresencePingInterval]), "I am here" when it
/// comes on the screen and "away" when it leaves it. Off the screen it
/// pings no one; it still answers friends' pings.
///
/// Each ping, pong and "away" to a friend who may see it says this
/// device's state (on the screen, in the background, or about to stop
/// receiving) and how long ago Zen was last open here ([presenceFields]);
/// nothing goes out just for that.
final class RuntimeSignalModule extends ZenModule {
  RuntimeSignalModule(this._ref)
    : _inService = _ref.read(zenHostProvider) == ZenHost.backgroundService;

  final Ref _ref;
  final bool _inService;

  /// Presence keeps going with nobody looking only in a background service
  /// that runs a whole core (none does today; Android's locked service only
  /// answers, locked_receiver.dart).
  bool get _runsUnseen => _inService;
  StreamSubscription<SignalTransportFrame>? _subscription;
  SignalTransport? _transport;
  Timer? _presenceTimer;
  Timer? _settleTimer;
  bool _running = false;

  /// Zen was on the screen at the last change (an "away" goes out only
  /// after it was).
  bool _wasInteractive = false;

  /// Pings went out since the last "away": friends see Zen on the screen,
  /// so leaving it is worth telling. Coming back for a moment and leaving
  /// again sends nothing new.
  bool _awayOwed = false;

  /// The last round of pings (wall time: a sleeping phone's timers stand
  /// still) and a timer that runs out a ping interval after it; while both
  /// say it was lately, coming back on the screen pings no one at once.
  DateTime? _pingedAt;
  Timer? _pingedLately;

  /// When Zen last left the screen in this run (wall time); `null` when it
  /// was not on the screen yet (a computer starting in the tray).
  DateTime? _leftScreenAt;

  /// The last "away" (wall time) and a timer that runs out
  /// [kPresenceAwayEvery] after it; while both say it was lately, the next
  /// one waits ([_awayLater]) for the rest of that time.
  DateTime? _awayAt;
  Timer? _awayLately;
  Timer? _awayLater;

  /// When each weak acquaintance last got an answer to a ping (see
  /// [_answersWeak]).
  final Map<String, int> _weakPongedAt = <String, int>{};

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
    if (_inService && _running) {
      // Nobody looks at the service: friends see this phone and it sees
      // them for as long as it runs.
      _restartPresenceLoop();
      await _tickPresenceLoop();
    }
  }

  @override
  FutureOr<void> stop() {
    _running = false;
    _presenceTimer?.cancel();
    _presenceTimer = null;
    _settleTimer?.cancel();
    _settleTimer = null;
    _pingedLately?.cancel();
    _pingedLately = null;
    _awayLately?.cancel();
    _awayLately = null;
    _awayLater?.cancel();
    _awayLater = null;
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
    if (_inService) {
      return;
    }
    // The node's numbers are read often only while someone may look.
    _ref.read(runtimeNodeRuntimeProvider).setOnScreen(interactive);
    if (!interactive) {
      _presenceTimer?.cancel();
      _presenceTimer = null;
      _settleTimer?.cancel();
      _settleTimer = null;
      if (_wasInteractive) {
        final DateTime left = DateTime.now();
        _leftScreenAt = left;
        // Android: what the locked service may tell friends from now on.
        scheduleMicrotask(() {
          if (_running) {
            unawaitedLogged(
              writeLockedPresenceKit(_ref, lastOpenedAt: left),
              context: 'Writing the presence kit failed',
            );
          }
        });
      }
      if (_wasInteractive && _awayOwed) {
        _wasInteractive = false;
        _awayOwed = false;
        // "Leaving the screen": friends see it at once, without pinging
        // (or a little later after another "away" lately).
        _scheduleAway();
      }
      _wasInteractive = false;
      return;
    }
    _wasInteractive = true;
    if (_awayLater != null) {
      // Back before the "away" held back went out: friends still see Zen
      // on the screen, which it is; leaving again owes them one.
      _awayLater?.cancel();
      _awayLater = null;
      _awayOwed = true;
    }
    // Back within a ping interval of the last round (a glance at another
    // app): friends are not pinged again at once; the next round comes on
    // time. Each ping wakes every friend's phone.
    final Duration? sincePing = _sinceLastPing();
    final Duration interval = _ref
        .read(runtimePresenceConfigProvider)
        .pingInterval;
    final Duration? rest = sincePing != null && sincePing < interval
        ? interval - sincePing
        : null;
    final bool pingNow = rest == null;
    _restartPresenceLoop(firstAfter: rest);
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
      if (!pingNow) {
        return;
      }
      // "I am here": a ping to every friend now. Who did not answer counts
      // as offline only once the answers had time to come.
      unawaitedLogged(
        _tickPresenceLoop(decay: false),
        context: 'Runtime presence tick failed after resume',
      );
      _settleTimer?.cancel();
      _settleTimer = Timer(kPresenceSettleAfterResume, () {
        _settleTimer = null;
        unawaitedLogged(
          _decayPresence(),
          context: 'Runtime presence decay failed after resume',
        );
      });
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
    if ((type == 'ping' || type == 'pong' || type == kPresenceAwayType) &&
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
        // that this device is online at this address.
        return;
      }
      final bool seesPresence =
          isAcceptedFriend &&
          presenceVisibleTo(_ref.read(friendLevelLookupProvider).of(from));
      if (!isAcceptedFriend || seesPresence || _answersWeak(from)) {
        await transport.send(
          remoteAddress: from,
          payload: <String, dynamic>{
            'type': 'pong',
            if (isAcceptedFriend) ..._presenceFor(from),
            if (isAcceptedFriend) ...versionHello(),
            // To a weak acquaintance exactly what a locked phone answers
            // (locked_receiver.dart), so they cannot tell the two apart.
            if (seesPresence) ..._hello(from),
          },
        );
      }
      if (isAcceptedFriend) {
        // A ping is a friend's "I am here": Zen is on their screen (as far
        // as they show it).
        await _notePresence(hub, from, frame);
        await _notePeerVersion(hub, from, frame.payload);
      }
      return;
    }
    if (type == kPresenceAwayType) {
      if (isAcceptedFriend) {
        // Off their screen: still reachable ("w tle") until no answer comes
        // for kPresenceOfflineAfter, or offline at once when their device
        // stops receiving (an iPhone).
        await _notePresence(hub, from, frame);
      }
      return;
    }
    if (type == 'pong') {
      if (!isAcceptedFriend && !isGroupMember) {
        // Not taken, and not answered either (see the ping above).
        return;
      }
      await _notePresence(hub, from, frame);
      if (isAcceptedFriend) {
        await _notePeerVersion(hub, from, frame.payload);
      }
      return;
    }
    final ZenSignal? signal = zenSignalFromTransportPayload(
      sender: from,
      payload: frame.payload,
    );
    if (signal == null) {
      return;
    }
    // The phone may be asleep but for this frame (the app in the
    // background, screen off): awake until it is handled (a message kept,
    // a notice shown, a call ringing), then free to sleep again.
    await ZenWake.holdWhile(
      () => hub.receiveSignal(signal, receivedAtMillis: frame.receivedAtMillis),
      tag: 'signal-work',
      limit: const Duration(seconds: 15),
      linger: const Duration(seconds: 2),
    );
  }

  /// What a ping, pong or way from [from] says of their presence.
  /// A weak acquaintance's status is not shown here, as this person's is not
  /// sent to them ([presenceVisibleTo]): only whether they can be reached.
  Future<void> _notePresence(
    SocialHubController hub,
    String from,
    SignalTransportFrame frame,
  ) {
    final PresenceReport report = PresenceReport.fromPayload(frame.payload);
    return hub.updatePeerPresence(
      peerAddress: from,
      report: _isWeakFriend(from)
          ? const PresenceReport(presence: PeerPresence.hidden)
          : report,
      reachable: report.reachable,
      observedAtMillis: frame.receivedAtMillis,
    );
  }

  /// Whether [address] is an accepted friend kept as a weak acquaintance
  /// ("Słaby znajomy"): no presence either way.
  bool _isWeakFriend(String address) =>
      _isAcceptedFriendAddress(address) &&
      !presenceVisibleTo(_ref.read(friendLevelLookupProvider).of(address));

  /// What app version a friend named: only for the "newer Zen" hint.
  Future<void> _notePeerVersion(
    SocialHubController hub,
    String from,
    Map<String, dynamic> payload,
  ) async {
    final PeerVersion? version = PeerVersion.fromPayload(payload);
    if (version != null) {
      // Kept whole (capabilities, the oldest Zen it still talks to): an
      // older build is told to update instead of quietly missing messages.
      _ref.read(peerHelloBookProvider.notifier).note(from, version);
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
    final SocialHubController hub = _ref.read(
      socialHubControllerProvider.notifier,
    );
    final Set<String> peersToPing = presencePingTargets(hubState);
    _notePingRound();
    for (final String address in peersToPing) {
      if (localAddr.isNotEmpty &&
          PeerShareCodec.addressesEqual(address, localAddr)) {
        continue;
      }
      if (!isRoutablePeerAddress(address)) {
        continue;
      }
      if (_isWeakFriend(address)) {
        // A ping is "I am here": a weak acquaintance hears nothing of it,
        // and what they showed before is not shown any more.
        await hub.hidePeerPresence(address);
        continue;
      }
      await transport.send(
        remoteAddress: address,
        payload: <String, dynamic>{
          'type': 'ping',
          if (hubState.friendByAddress(address)?.status ==
              FriendRelationshipStatus.accepted) ...<String, dynamic>{
            ..._presenceFor(address),
            ...versionHello(),
            ..._hello(address),
          },
        },
      );
    }
  }

  /// Whether a ping of the weak acquaintance [friend] gets an answer now: at
  /// most one every kLockedPongEvery, as from a locked phone, so how often
  /// answers come does not tell them whether Zen is open.
  bool _answersWeak(String friend) {
    final int now = DateTime.now().millisecondsSinceEpoch;
    final int? last = _weakPongedAt[friend];
    if (last != null &&
        now >= last &&
        now - last < kLockedPongEvery.inMilliseconds) {
      return false;
    }
    if (_weakPongedAt.length >= 500) {
      _weakPongedAt.clear();
    }
    _weakPongedAt[friend] = now;
    return true;
  }

  /// Sends "away" now, or once [kPresenceAwayEvery] after the last one.
  void _scheduleAway() {
    _awayLater?.cancel();
    _awayLater = null;
    final DateTime? at = _awayAt;
    Duration since = at == null || _awayLately == null
        ? kPresenceAwayEvery
        : DateTime.now().difference(at);
    if (since.isNegative) {
      since = Duration.zero;
    }
    if (since >= kPresenceAwayEvery) {
      scheduleMicrotask(_awayNow);
      return;
    }
    _awayLater = Timer(kPresenceAwayEvery - since, _awayNow);
  }

  void _awayNow() {
    _awayLater = null;
    if (!_running || _wasInteractive) {
      return;
    }
    _awayAt = DateTime.now();
    _awayLately?.cancel();
    _awayLately = Timer(kPresenceAwayEvery, () => _awayLately = null);
    unawaitedLogged(_sendAway(), context: 'Runtime presence "away" failed');
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

  /// What [friend] (an accepted friend) may hear about this device's
  /// presence: nothing when they may not see it ([presenceVisibleTo]);
  /// otherwise the state and, unless the person keeps it to themselves,
  /// how long ago Zen was last open (unknown before it was on the screen
  /// in this run).
  Map<String, dynamic> _presenceFor(String friend) {
    if (!presenceVisibleTo(_ref.read(friendLevelLookupProvider).of(friend))) {
      return const <String, dynamic>{};
    }
    final bool onScreen = _isUiInteractive();
    final DateTime? left = _leftScreenAt;
    final Duration? openedAgo =
        !_ref.read(appSettingsControllerProvider).showLastOpened
        ? null
        : onScreen
        ? Duration.zero
        : left == null
        ? null
        : DateTime.now().difference(left);
    return presenceFields(
      own: onScreen
          ? PeerPresence.online
          : _ref.read(presenceAsleepOffScreenProvider)
          ? PeerPresence.offline
          : PeerPresence.background,
      openedAgo: openedAgo,
    );
  }

  /// "Away" to every friend who may see it: Zen left the screen.
  Future<void> _sendAway() async {
    final SignalTransport? transport = _transport;
    final SocialHubController hub = _ref.read(
      socialHubControllerProvider.notifier,
    );
    if (transport == null ||
        !hub.isHydrated ||
        _ref.read(socialHubControllerProvider).snapshotUnreadable) {
      return;
    }
    final String localAddr = _ref
        .read(runtimeNodeSnapshotProvider)
        .localAddress;
    for (final FriendProfile friend
        in _ref.read(socialHubControllerProvider).acceptedFriends) {
      final String address = friend.address;
      if ((localAddr.isNotEmpty &&
              PeerShareCodec.addressesEqual(address, localAddr)) ||
          !isRoutablePeerAddress(address)) {
        continue;
      }
      final Map<String, dynamic> presence = _presenceFor(address);
      if (presence.isEmpty) {
        // They see nothing of it: nothing to tell.
        continue;
      }
      try {
        await transport.send(
          remoteAddress: address,
          payload: <String, dynamic>{'type': kPresenceAwayType, ...presence},
        );
      } on Object catch (error) {
        logZenWarning('"Away" to a friend was not sent: $error');
      }
    }
  }

  Future<void> _decayPresence() async {
    if (!_running || !_presenceRuns()) {
      return;
    }
    final RuntimePresenceConfig config = _ref.read(
      runtimePresenceConfigProvider,
    );
    await _ref
        .read(socialHubControllerProvider.notifier)
        .decayPresence(
          offlineAfter: config.offlineAfter,
          foregroundFor: config.foregroundFor,
        );
  }

  /// Since the last round of pings, or `null` when it was not lately.
  Duration? _sinceLastPing() {
    final DateTime? at = _pingedAt;
    if (at == null || _pingedLately == null) {
      return null;
    }
    final Duration since = DateTime.now().difference(at);
    return since.isNegative ? Duration.zero : since;
  }

  void _notePingRound() {
    _awayOwed = true;
    _pingedAt = DateTime.now();
    _pingedLately?.cancel();
    final Duration interval = _ref
        .read(runtimePresenceConfigProvider)
        .pingInterval;
    _pingedLately = interval <= Duration.zero
        ? null
        : Timer(interval, () => _pingedLately = null);
  }

  /// Pings every interval; the first round after [firstAfter] when given
  /// (the rest of an interval that began before).
  void _restartPresenceLoop({Duration? firstAfter}) {
    _presenceTimer?.cancel();
    _presenceTimer = null;
    final Duration interval = _ref
        .read(runtimePresenceConfigProvider)
        .pingInterval;
    if (interval <= Duration.zero) {
      return;
    }
    if (firstAfter != null) {
      _presenceTimer = Timer(firstAfter, () {
        if (!_running) {
          return;
        }
        _restartPresenceLoop();
        unawaitedLogged(
          _tickPresenceLoop(),
          context: 'Runtime presence loop tick failed',
        );
      });
      return;
    }
    _presenceTimer = Timer.periodic(interval, (_) {
      unawaitedLogged(
        _tickPresenceLoop(),
        context: 'Runtime presence loop tick failed',
      );
    });
  }

  Future<void> _tickPresenceLoop({bool decay = true}) async {
    if (!_running || !_presenceRuns()) {
      return;
    }
    await _ref.read(socialHubControllerProvider.notifier).whenHydrated;
    if (!_running || !_presenceRuns()) {
      return;
    }
    await _sendPresencePings();
    if (!_running || !decay) {
      return;
    }
    await _decayPresence();
  }

  /// Presence pings go out only while Zen is on the screen and unlocked.
  bool _presenceRuns() => _runsUnseen || _isUiInteractive();

  bool _isUiInteractive() {
    final AppSecurityService security = _ref.read(appSecurityServiceProvider);
    return _ref.read(socialHubControllerProvider).lifecycle.isInteractive &&
        !isSecurityBlockingUi(security);
  }
}
