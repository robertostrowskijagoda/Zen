import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zen/src/app/desktop_window_bridge.dart';
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
/// the radio of each friend's phone, which answers, so not often; the
/// moments that matter are told at once: "I am here" (a ping) when Zen
/// comes on the screen, again once the node reaches the mesh if it did not
/// yet, to a friend as soon as they are added, and each change of this
/// device's state to the friends who have Zen open ([kPresenceNoticeEvery]).
const Duration kPresencePingInterval = Duration(minutes: 2);

/// After a round of pings that could arrive, how long the answers may take
/// before friends who did not answer count as offline. A friend whose
/// presence was not checked lately ("status nieznany", confirmed longer
/// than [kPresenceRememberedFor] ago) is settled so only after the second
/// such round (about 2 min after the node reached the network).
const Duration kPresenceSettleAfterResume = Duration(seconds: 20);

/// After a start, the friends who did not answer the first round of pings
/// that could arrive are pinged again this long after it (once at each),
/// and until then every ping to a friend not heard from yet says this Zen
/// just started (kPresenceFreshKey): the first ping may wait for a session
/// with them or go before the links carry it, and a locked phone that
/// answered before the start answers such a ping at once (no further apart
/// than kLockedFreshPongEvery). Nobody waits for the next round, 2 min on.
const List<Duration> kPresenceStartRetries = <Duration>[
  Duration(seconds: 25),
  Duration(seconds: 50),
];

/// Each change of this device's state (on the screen, off it, closing) is
/// told at once in an `away` frame, but only to the friends who have Zen
/// open now (their last word, within [kPresenceForegroundFor], was
/// "foreground"): their screen is on anyway, and nobody else looks. A
/// locked phone says "w tle", so it never gets one. At most one per state
/// per friend this often; one held back goes when the time is over, unless
/// the state is back to what they were told.
const Duration kPresenceNoticeEvery = Duration(seconds: 30);

/// Changes within this long are told as one: a glance at another app tells
/// nothing.
const Duration kPresenceNoticeDelay = Duration(seconds: 2);

/// An iPhone that stops receiving off the screen tells it to every friend
/// who may see presence, as their mail should go to the mailboxes now: to
/// a friend without Zen open at most this often (each one wakes their
/// phone).
const Duration kPresenceAwayEvery = Duration(minutes: 4);

/// Without the network this long, every friend shows "brak połączenia"
/// ([PresenceDoubt.noNetwork]): nothing from them can come, so what they
/// showed does not expire into "offline" either.
const Duration kPresenceNoNetworkAfter = Duration(seconds: 30);

/// Whether the node reaches the mesh: running, with a peer up.
bool meshReachable(RuntimeTransportSnapshot snapshot) =>
    snapshot.health == RuntimeTransportHealth.active && snapshot.peers > 0;

/// Whether the node reaches the mesh now ([meshReachable]), as it changes:
/// pings sent before it did went nowhere, so a round goes out again once it
/// does (a fake in tests).
final Provider<ValueListenable<bool>> meshReachableProvider =
    Provider<ValueListenable<bool>>((Ref ref) {
      final RuntimeNodeRuntime runtime = ref.watch(runtimeNodeRuntimeProvider);
      final ValueNotifier<bool> reachable = ValueNotifier<bool>(
        meshReachable(runtime.snapshot),
      );
      void update() => reachable.value = meshReachable(runtime.snapshot);
      runtime.addListener(update);
      ref.onDispose(() {
        runtime.removeListener(update);
        reachable.dispose();
      });
      return reachable;
    });

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
/// comes on the screen (again once the node reaches the mesh, when the
/// first round went out before it did), a ping to a friend as soon as
/// they are added. Off the screen it pings no one; it still answers
/// friends' pings.
///
/// Each ping, pong and `away` to a friend who may see it says this
/// device's state (on the screen, in the background, or about to stop
/// receiving) and how long ago Zen was last open here ([presenceFields]).
/// A change of that state goes out at once in an `away` only to the
/// friends who have Zen open ([kPresenceNoticeEvery]): leaving the screen,
/// coming back before the next round, closing Zen on a computer, the
/// network back after a loss.
///
/// Friends' presence is in doubt ([PresenceDoubt]) while this device has
/// no network ([kPresenceNoNetworkAfter]: "brak połączenia"), and, when
/// it was confirmed longer than [kPresenceRememberedFor] ago, after a start
/// until they answer or the answers had time to come
/// ([kPresenceSettleAfterResume]: "status nieznany").
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

  /// Zen was on the screen at the last change.
  bool _wasInteractive = false;

  /// The last round of pings (wall time: a sleeping phone's timers stand
  /// still) and a timer that runs out a ping interval after it; while both
  /// say it was lately, coming back on the screen pings no one at once.
  DateTime? _pingedAt;
  Timer? _pingedLately;

  /// When Zen last left the screen in this run (wall time); `null` when it
  /// was not on the screen yet (a computer starting in the tray).
  DateTime? _leftScreenAt;

  /// What each friend was last told of this device's state (a ping, a pong
  /// or an `away` that could arrive) and when (wall time, ms); and, by
  /// friend and state, the last `away` that told it (wall time, ms) with a
  /// timer that runs out when the next one may go (the limit per state).
  final Map<String, ({PeerPresence state, int at})> _told =
      <String, ({PeerPresence state, int at})>{};
  final Map<String, ({int at, Timer lately})> _noticed =
      <String, ({int at, Timer lately})>{};

  /// What each friend last said of their own state in this run, and when
  /// (wall time, ms): who has Zen open now ([_hasZenOpen]).
  final Map<String, ({PeerPresence state, int at})> _heard =
      <String, ({PeerPresence state, int at})>{};

  /// The next look at what friends should be told ([_sendNotices]), and
  /// when it is due.
  Timer? _noticeTimer;
  DateTime? _noticeDue;

  /// Zen is quitting for good (a computer): "closing" is what goes out.
  bool _closing = false;

  /// Rounds of pings that could arrive in this run: the second one settles
  /// the presence remembered from before the start.
  int _reachableRounds = 0;

  /// This run just started: pings to friends not heard from yet say so
  /// until the pings again after the first round that could arrive are
  /// over ([kPresenceStartRetries], [_retryTimer]).
  bool _fresh = true;
  Timer? _retryTimer;

  /// What each device of each friend told of its presence in this run.
  final PresenceDevices _devices = PresenceDevices();

  /// Without the network for [kPresenceNoNetworkAfter] ([_noNetworkTimer]
  /// runs meanwhile): friends' presence is in doubt.
  Timer? _noNetworkTimer;
  bool _noNetwork = false;

  /// When each weak acquaintance last got an answer to a ping (see
  /// [_answersWeak]).
  final Map<String, int> _weakPongedAt = <String, int>{};

  /// Whether the node reaches the mesh ([meshReachableProvider]), and
  /// whether it did not when the last round of pings went out.
  ValueListenable<bool>? _reachable;
  bool _wasReachable = true;
  bool _pingedUnreachable = false;

  /// Who the last round went to (`null`: none yet in this run): someone new
  /// among the targets later is pinged at once ([_onFriendsChanged]).
  Set<String>? _pingTargets;
  ProviderSubscription<SocialHubState>? _friendsSubscription;

  @override
  String get id => 'signal';

  @override
  Future<void> start() async {
    final SignalTransport transport = _ref.read(signalTransportProvider);
    _transport = transport;
    _running = true;
    // A run of its own (the core starts again once the node is back from
    // the Android service): who heard what, and the rounds, start anew.
    _reachableRounds = 0;
    _fresh = true;
    _heard.clear();
    _told.clear();
    // Subscribe before starting. `frames` is a broadcast stream, so anything
    // emitted between start() and listen() is gone for good.
    _subscription = transport.frames.listen(
      _handleFrame,
      onError: (Object error, StackTrace stackTrace) {
        logZenError('Runtime signal frame stream error', error, stackTrace);
      },
    );
    final ValueListenable<bool> reachable = _ref.read(meshReachableProvider);
    _reachable = reachable;
    _wasReachable = reachable.value;
    reachable.addListener(_onReachableChanged);
    if (!_inService) {
      if (!reachable.value) {
        _armNoNetwork();
      }
      if (!kIsWeb &&
          (Platform.isWindows || Platform.isLinux || Platform.isMacOS)) {
        zenBeforeQuit.add(_sayClosing);
      }
    }
    _friendsSubscription = _ref.listen<SocialHubState>(
      socialHubControllerProvider,
      (SocialHubState? previous, SocialHubState next) =>
          _onFriendsChanged(next),
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
    if (_running && !_inService && (_noticeTimer != null || _wasInteractive)) {
      // A change of this device's state still to be told ("leaving the
      // screen" waits a moment for a glance to pass): it goes now, while
      // the node is still up. A phone that locks hands its node to the
      // service at once, and the friends who have Zen open would show it
      // "online" until their next ping got an answer.
      return _tellBeforeStopping().whenComplete(_stopNow);
    }
    _stopNow();
  }

  Future<void> _tellBeforeStopping() async {
    if (!_ref.mounted) {
      // The app itself is going away (its providers with it).
      return;
    }
    try {
      if (_noticeTimer == null && _isUiInteractive()) {
        // Still on the screen: nothing changed.
        return;
      }
      _noticeTimer?.cancel();
      _noticeTimer = null;
      _noticeDue = null;
      await _sendNotices().timeout(const Duration(seconds: 2));
    } on Object catch (error) {
      logZenWarning('The presence change was not told before stopping: $error');
    }
  }

  void _stopNow() {
    _running = false;
    _presenceTimer?.cancel();
    _presenceTimer = null;
    _settleTimer?.cancel();
    _settleTimer = null;
    _retryTimer?.cancel();
    _retryTimer = null;
    _pingedLately?.cancel();
    _pingedLately = null;
    _noticeTimer?.cancel();
    _noticeTimer = null;
    _noticeDue = null;
    _forgetNotices();
    _noNetworkTimer?.cancel();
    _noNetworkTimer = null;
    zenBeforeQuit.remove(_sayClosing);
    _reachable?.removeListener(_onReachableChanged);
    _reachable = null;
    _friendsSubscription?.close();
    _friendsSubscription = null;
    _pingTargets = null;
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
      if (_wasInteractive) {
        // "Leaving the screen": the friends who have Zen open see it at
        // once, without pinging. An iPhone about to stop receiving says so
        // right away (iOS gives it seconds).
        _scheduleNotice(
          _ref.read(presenceAsleepOffScreenProvider)
              ? Duration.zero
              : kPresenceNoticeDelay,
        );
      }
      _wasInteractive = false;
      return;
    }
    final bool cameBack = _leftScreenAt != null;
    _wasInteractive = true;
    // Back before the next round: the friends who have Zen open and heard
    // "away" hear "I am here" (nothing when it never went out).
    _scheduleNotice();
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
      if (cameBack) {
        // What friends showed may have expired off the screen: what it is
        // worth by now, or "status nieznany" when it is long ago, until
        // they answer.
        final RuntimePresenceConfig config = _ref.read(
          runtimePresenceConfigProvider,
        );
        unawaitedLogged(
          _ref
              .read(socialHubControllerProvider.notifier)
              .recheckStalePresence(
                offlineAfter: config.offlineAfter,
                foregroundFor: config.foregroundFor,
              ),
          context: 'Rechecking stale presence failed',
        );
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
      _hereNow(context: 'Runtime presence tick failed after resume');
    });
  }

  /// "I am here": a ping to every friend now. Who did not answer counts as
  /// offline only once the answers had time to come (the settle a round
  /// that could arrive arms, [_sendPresencePings]).
  void _hereNow({required String context}) {
    unawaitedLogged(_tickPresenceLoop(decay: false), context: context);
  }

  /// The node reached the mesh, or lost it. A round of pings that went out
  /// while it did not went nowhere (a cold start: Zen on the screen before
  /// the node has a peer), so "I am here" goes out again now rather than a
  /// whole interval later. Lost for [kPresenceNoNetworkAfter], friends
  /// show "brak połączenia"; back, the friends who had Zen open are pinged
  /// (they hear this device again and answer), and what friends should
  /// have been told meanwhile goes out.
  void _onReachableChanged() {
    final bool reachable = _reachable?.value ?? false;
    if (reachable == _wasReachable) {
      return;
    }
    _wasReachable = reachable;
    if (!_running || _inService) {
      return;
    }
    if (!reachable) {
      _armNoNetwork();
      return;
    }
    _noNetworkTimer?.cancel();
    _noNetworkTimer = null;
    final bool wasWithout = _noNetwork;
    _noNetwork = false;
    final SocialHubController hub = _ref.read(
      socialHubControllerProvider.notifier,
    );
    if (wasWithout) {
      final RuntimePresenceConfig config = _ref.read(
        runtimePresenceConfigProvider,
      );
      unawaitedLogged(
        hub.notePresenceNetwork(
          reachable: true,
          offlineAfter: config.offlineAfter,
          foregroundFor: config.foregroundFor,
        ),
        context: 'Presence back on the network failed',
      );
    }
    if (_presenceRuns()) {
      if (_pingedUnreachable) {
        _pingedUnreachable = false;
        _restartPresenceLoop();
        _hereNow(context: 'Runtime presence tick failed once reachable');
        return;
      }
      if (wasWithout) {
        unawaitedLogged(
          _pingAll(_openZenFriends(), _ref.read(socialHubControllerProvider)),
          context: 'Runtime presence ping once reachable failed',
        );
      }
    }
    _scheduleNotice(Duration.zero);
  }

  /// Starts the wait after which, still without the network, friends'
  /// presence is in doubt.
  void _armNoNetwork() {
    if (_noNetworkTimer != null || _noNetwork) {
      return;
    }
    _noNetworkTimer = Timer(kPresenceNoNetworkAfter, () {
      _noNetworkTimer = null;
      if (!_running || (_reachable?.value ?? true)) {
        return;
      }
      _noNetwork = true;
      final SocialHubController hub = _ref.read(
        socialHubControllerProvider.notifier,
      );
      unawaitedLogged(
        hub.whenHydrated.then((_) async {
          if (_running && _noNetwork) {
            await hub.notePresenceNetwork(reachable: false);
          }
        }),
        context: 'Presence without the network failed',
      );
    });
  }

  /// Someone new among the ping targets (a friend just accepted, a group
  /// invite just sent) is pinged at once while Zen is on the screen, not at
  /// the next round: one ping each, the others are not pinged again.
  void _onFriendsChanged(SocialHubState state) {
    final Set<String>? known = _pingTargets;
    // No round yet in this run: the first one pings everybody. Off the
    // screen nobody is pinged; the next round reaches the new ones.
    if (known == null || !_running || !_presenceRuns()) {
      return;
    }
    final Set<String> targets = presencePingTargets(state);
    final Set<String> added = targets.difference(known);
    _pingTargets = targets;
    if (added.isEmpty) {
      return;
    }
    unawaitedLogged(
      _pingAll(added, state),
      context: 'Runtime presence ping of a new friend failed',
    );
  }

  /// Whether frames are still taken: the module runs and its providers are
  /// there. A frame handled across a stop (the app closing, an account
  /// switch) ends at its next step instead of reading what is gone.
  bool get _live => _running && _ref.mounted;

  Future<void> _handleFrame(SignalTransportFrame frame) async {
    if (!_live) {
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
        final Map<String, dynamic> presence = isAcceptedFriend
            ? _presenceFor(from)
            : const <String, dynamic>{};
        await transport.send(
          remoteAddress: from,
          payload: <String, dynamic>{
            'type': 'pong',
            ...presence,
            if (isAcceptedFriend) ...versionHello(),
            // To a weak acquaintance exactly what a locked phone answers
            // (locked_receiver.dart), so they cannot tell the two apart.
            if (seesPresence) ..._hello(from),
          },
        );
        _noteTold(from, presence);
      }
      if (isAcceptedFriend && _live) {
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

  /// What a ping, pong or `away` from [from] says of their presence.
  /// A weak acquaintance's status is not shown here, as this person's is not
  /// sent to them ([presenceVisibleTo]): only whether they can be reached.
  /// A friend whose Zen is older than [kPresenceSinceVersion] tells none at
  /// all: unknown, not hidden. Taken with what the friend's other devices
  /// told, and not at all when it came after something newer from the same
  /// device ([PresenceDevices]).
  Future<void> _notePresence(
    SocialHubController hub,
    String from,
    SignalTransportFrame frame,
  ) {
    if (!_live) {
      return Future<void>.value();
    }
    PresenceReport report = PresenceReport.fromPayload(frame.payload);
    if (_isWeakFriend(from)) {
      report = const PresenceReport(presence: PeerPresence.hidden);
    } else if (report.presence == PeerPresence.hidden &&
        _tellsNoPresence(frame.payload)) {
      report = const PresenceReport(presence: PeerPresence.unknown);
    }
    final RuntimePresenceConfig config = _ref.read(
      runtimePresenceConfigProvider,
    );
    final ({PresenceReport report, int at})? now = _devices.note(
      friend: from,
      device: PeerShareCodec.normalizeAddress(frame.sender),
      report: report,
      atMillis: frame.receivedAtMillis,
      foregroundFor: config.foregroundFor,
      backgroundFor: config.offlineAfter,
    );
    if (now == null) {
      // Told before what this device heard from there already.
      return Future<void>.value();
    }
    if (_heard.length >= 2000) {
      _heard.clear();
    }
    _heard[from] = (
      state: now.report.presence,
      at:
          DateTime.now().millisecondsSinceEpoch -
          (frame.receivedAtMillis - now.at),
    );
    return hub.updatePeerPresence(
      peerAddress: from,
      report: now.report,
      reachable: now.report.reachable,
      observedAtMillis: now.at,
    );
  }

  /// Whether a frame comes from a Zen too old to tell its presence: it
  /// names a version, older than [kPresenceSinceVersion].
  bool _tellsNoPresence(Map<String, dynamic> payload) {
    final PeerVersion? version = PeerVersion.fromPayload(payload);
    return version != null &&
        compareAppVersions(version.version, kPresenceSinceVersion) < 0;
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
    if (version != null && _live) {
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
    if (_transport == null) {
      return;
    }
    final SocialHubState hubState = _ref.read(socialHubControllerProvider);
    final Set<String> peersToPing = presencePingTargets(hubState);
    _notePingRound();
    _pingTargets = peersToPing;
    final bool reachable = _reachable?.value ?? true;
    _pingedUnreachable = !reachable;
    await _pingAll(peersToPing, hubState);
    if (reachable && _running) {
      _armSettle(settleUnchecked: ++_reachableRounds >= 2);
      if (_reachableRounds == 1) {
        _retryUnanswered(0);
      }
    }
  }

  /// The friends not heard from in this run are pinged again
  /// [kPresenceStartRetries] after the first round that could arrive; once
  /// those are over, pings no longer say this Zen just started.
  void _retryUnanswered(int index) {
    _retryTimer?.cancel();
    _retryTimer = null;
    if (index >= kPresenceStartRetries.length) {
      _fresh = false;
      return;
    }
    final Duration wait =
        kPresenceStartRetries[index] -
        (index == 0 ? Duration.zero : kPresenceStartRetries[index - 1]);
    _retryTimer = Timer(wait, () {
      _retryTimer = null;
      if (!_running) {
        return;
      }
      if (_presenceRuns()) {
        final SocialHubState hubState = _ref.read(socialHubControllerProvider);
        final Set<String> unanswered = <String>{
          for (final FriendProfile friend in hubState.acceptedFriends)
            if (!_heard.containsKey(
              PeerShareCodec.normalizeAddress(friend.address),
            ))
              friend.address,
        };
        if (unanswered.isNotEmpty) {
          unawaitedLogged(
            _pingAll(unanswered, hubState),
            context: 'Runtime presence ping of the unanswered failed',
          );
        }
      }
      _retryUnanswered(index + 1);
    });
  }

  /// Once the answers to a round had time to come, friends who did not
  /// answer show what their last state is worth by now; with
  /// [settleUnchecked] also those not checked lately ("status nieznany").
  void _armSettle({required bool settleUnchecked}) {
    _settleTimer?.cancel();
    _settleTimer = Timer(kPresenceSettleAfterResume, () {
      _settleTimer = null;
      unawaitedLogged(
        _decayPresence(settleUnchecked: settleUnchecked),
        context: 'Runtime presence decay failed after a round',
      );
    });
  }

  /// A ping to each of [targets] who may hear one.
  Future<void> _pingAll(
    Iterable<String> targets,
    SocialHubState hubState,
  ) async {
    final SignalTransport? transport = _transport;
    if (transport == null) {
      return;
    }
    final String localAddr = _ref
        .read(runtimeNodeSnapshotProvider)
        .localAddress;
    final SocialHubController hub = _ref.read(
      socialHubControllerProvider.notifier,
    );
    for (final String address in targets) {
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
      final bool friend =
          hubState.friendByAddress(address)?.status ==
          FriendRelationshipStatus.accepted;
      final Map<String, dynamic> presence = friend
          ? _presenceFor(address)
          : const <String, dynamic>{};
      await transport.send(
        remoteAddress: address,
        payload: <String, dynamic>{
          'type': 'ping',
          if (friend) ...<String, dynamic>{
            ...presence,
            ...versionHello(),
            ..._hello(address),
            // Not heard from since this Zen started: a locked phone
            // answers at once (kPresenceStartRetries).
            if (_fresh &&
                !_heard.containsKey(PeerShareCodec.normalizeAddress(address)))
              kPresenceFreshKey: true,
          },
        },
      );
      _noteTold(address, presence);
    }
  }

  /// [friend] heard [presence] (the fields of a frame just sent), as far as
  /// it could arrive.
  void _noteTold(String friend, Map<String, dynamic> presence) {
    if (presence.isEmpty || !(_reachable?.value ?? true)) {
      return;
    }
    final PresenceReport report = PresenceReport.fromPayload(presence);
    if (_told.length >= 2000) {
      _told.clear();
    }
    _told[PeerShareCodec.normalizeAddress(friend)] = (
      state: report.presence,
      at: DateTime.now().millisecondsSinceEpoch,
    );
  }

  /// Whether [friend] has Zen open now, as far as this device heard: their
  /// last word in this run said "foreground", within the time "online"
  /// lasts (kPresenceForegroundFor).
  bool _hasZenOpen(String friend) {
    final ({PeerPresence state, int at})? last =
        _heard[PeerShareCodec.normalizeAddress(friend)];
    if (last == null || last.state != PeerPresence.online) {
      return false;
    }
    final int age = DateTime.now().millisecondsSinceEpoch - last.at;
    return age >= 0 &&
        age <
            _ref
                .read(runtimePresenceConfigProvider)
                .foregroundFor
                .inMilliseconds;
  }

  /// The accepted friends who have Zen open now ([_hasZenOpen]).
  Set<String> _openZenFriends() => <String>{
    for (final FriendProfile friend
        in _ref.read(socialHubControllerProvider).acceptedFriends)
      if (_hasZenOpen(friend.address)) friend.address,
  };

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

  /// Looks at what friends should be told of this device's state after
  /// [delay] (or earlier, when a look is due sooner already): changes in
  /// between are told as one. [Duration.zero]: right after this.
  void _scheduleNotice([Duration delay = kPresenceNoticeDelay]) {
    if (!_running || _inService) {
      return;
    }
    if (delay <= Duration.zero) {
      _noticeTimer?.cancel();
      _noticeTimer = null;
      _noticeDue = null;
      scheduleMicrotask(() {
        unawaitedLogged(
          _sendNotices(),
          context: 'Runtime presence announcement failed',
        );
      });
      return;
    }
    final DateTime due = DateTime.now().add(delay);
    final DateTime? pending = _noticeDue;
    if (_noticeTimer != null && pending != null && !pending.isAfter(due)) {
      return;
    }
    _noticeTimer?.cancel();
    _noticeDue = due;
    _noticeTimer = Timer(delay, () {
      _noticeTimer = null;
      _noticeDue = null;
      unawaitedLogged(
        _sendNotices(),
        context: 'Runtime presence announcement failed',
      );
    });
  }

  /// Zen is quitting for good (a computer): the friends who have Zen open
  /// hear "closing" (as an iPhone's "about to stop receiving"), as far as
  /// there is time for it.
  Future<void> _sayClosing() async {
    if (!_running) {
      return;
    }
    _closing = true;
    _noticeTimer?.cancel();
    _noticeTimer = null;
    _noticeDue = null;
    await _sendNotices();
    // A moment for the node to put the frames on the wire.
    await Future<void>.delayed(const Duration(milliseconds: 300));
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
      own: _ownPresence(),
      openedAgo: openedAgo,
      sentAtMillis: DateTime.now().millisecondsSinceEpoch,
    );
  }

  /// This device's state as friends should see it now: on the screen,
  /// off it but receiving, or about to stop receiving (an iPhone iOS
  /// suspends, a computer quitting).
  PeerPresence _ownPresence() {
    if (_closing) {
      return PeerPresence.offline;
    }
    if (_isUiInteractive()) {
      return PeerPresence.online;
    }
    return _ref.read(presenceAsleepOffScreenProvider)
        ? PeerPresence.offline
        : PeerPresence.background;
  }

  /// Tells each friend who should hear it this device's state now, in an
  /// `away`: a friend who has Zen open ([_hasZenOpen]) and was told
  /// something else, at most one per state every [kPresenceNoticeEvery].
  /// An iPhone about to stop receiving tells every friend who may see
  /// presence (one without Zen open at most every [kPresenceAwayEvery]).
  /// Nothing while the node does not reach the network: it goes once it
  /// does.
  Future<void> _sendNotices() async {
    final SignalTransport? transport = _transport;
    final SocialHubController hub = _ref.read(
      socialHubControllerProvider.notifier,
    );
    if (!_running ||
        transport == null ||
        !hub.isHydrated ||
        _ref.read(socialHubControllerProvider).snapshotUnreadable ||
        !(_reachable?.value ?? true)) {
      return;
    }
    final PeerPresence own = _ownPresence();
    final bool toEveryone = own == PeerPresence.offline && !_closing;
    final String localAddr = _ref
        .read(runtimeNodeSnapshotProvider)
        .localAddress;
    final int now = DateTime.now().millisecondsSinceEpoch;
    int? retryIn;
    for (final FriendProfile friend
        in _ref.read(socialHubControllerProvider).acceptedFriends) {
      final String address = friend.address;
      final String key = PeerShareCodec.normalizeAddress(address);
      if ((localAddr.isNotEmpty &&
              PeerShareCodec.addressesEqual(address, localAddr)) ||
          !isRoutablePeerAddress(address)) {
        continue;
      }
      final bool open = _hasZenOpen(address);
      if ((!open && !toEveryone) || _told[key]?.state == own) {
        continue;
      }
      final Map<String, dynamic> presence = _presenceFor(address);
      if (presence.isEmpty) {
        // They see nothing of it: nothing to tell.
        continue;
      }
      final Duration every = open ? kPresenceNoticeEvery : kPresenceAwayEvery;
      final String noticeKey = '$key ${own.name}';
      final ({int at, Timer lately})? last = _noticed[noticeKey];
      // Lately while both the wall time and the timer say so (a sleeping
      // phone's timers stand still).
      if (last != null &&
          last.lately.isActive &&
          now >= last.at &&
          now - last.at < every.inMilliseconds) {
        final int wait = every.inMilliseconds - (now - last.at);
        retryIn = retryIn == null || wait < retryIn ? wait : retryIn;
        continue;
      }
      try {
        await transport.send(
          remoteAddress: address,
          payload: <String, dynamic>{'type': kPresenceAwayType, ...presence},
        );
      } on Object catch (error) {
        logZenWarning('A presence announcement was not sent: $error');
        continue;
      }
      if (_noticed.length >= 2000) {
        _forgetNotices();
      }
      last?.lately.cancel();
      _noticed[noticeKey] = (at: now, lately: Timer(every, () {}));
      _noteTold(address, presence);
    }
    if (retryIn != null && !_closing) {
      _scheduleNotice(Duration(milliseconds: retryIn));
    }
  }

  void _forgetNotices() {
    for (final ({int at, Timer lately}) n in _noticed.values) {
      n.lately.cancel();
    }
    _noticed.clear();
  }

  Future<void> _decayPresence({bool settleUnchecked = false}) async {
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
          settleUnchecked: settleUnchecked,
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
