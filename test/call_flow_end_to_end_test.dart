import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:zen/src/domain/calls/call_invite_kind.dart';
import 'package:zen/src/domain/calls/call_session.dart';
import 'package:zen/src/domain/friends/friend_profile.dart';
import 'package:zen/src/domain/messages/chat_message.dart';
import 'package:zen/src/domain/runtime/lifecycle_snapshot.dart';
import 'package:zen/src/domain/signals/signal_queue_store.dart';
import 'package:zen/src/domain/signals/zen_signal.dart';
import 'package:zen/src/features/calls/call_media_session.dart';
import 'package:zen/src/features/chat/message_timeline_store.dart';
import 'package:zen/src/features/runtime/runtime_signal_parser.dart';
import 'package:zen/src/features/runtime/runtime_system_notifications.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';
import 'package:zen/src/features/social/social_hub_controller.dart';
import 'package:zen/src/features/social/social_hub_state.dart';
import 'package:zen/src/features/social/social_snapshot_store.dart';

const String _callerAddress = '200:1111:2222:3333:4444:5555:6666:1';
const String _calleeAddress = '200:1111:2222:3333:4444:5555:6666:2';

/// End-to-end call flow across two wired-up peers.
///
/// The unit tests around the controller feed it one signal at a time, which is
/// exactly how the re-ring bugs slipped through: they only show up once the
/// caller's 1 Hz invite loop keeps running against a callee that has already
/// answered.
void main() {
  test('an answered call stops ringing on both sides', () async {
    final _Peer caller = _Peer(
      address: _callerAddress,
      peerAddress: _calleeAddress,
      peerName: 'Ada',
    );
    final _Peer callee = _Peer(
      address: _calleeAddress,
      peerAddress: _callerAddress,
      peerName: 'Bob',
      // Off screen, so a missed-call shade entry would be raised if nobody
      // answered. Ringing itself uses the popup, not a notification.
      visibility: AppVisibilityState.background,
    );
    _link(caller, callee);
    addTearDown(caller.dispose);
    addTearDown(callee.dispose);

    await caller.controller.sendCallInvite(
      peerAddress: _calleeAddress,
      kind: CallInviteKind.audio,
    );
    await _settle();

    expect(callee.state.activeCall, isNotNull);
    expect(callee.state.activeCall!.isIncoming, isTrue);
    expect(
      callee.notifications.activeNotifications,
      isEmpty,
      reason: 'ringing uses the popup, not a shade notification',
    );

    await callee.controller.acceptIncomingCall(peerAddress: _callerAddress);
    await _settle();

    // Both media sessions report the connection; that is what turns the
    // ringing sessions into active ones.
    caller.media.markActive();
    callee.media.markActive();
    await _settle();

    final int notificationsAfterAccept =
        callee.notifications.activeNotifications.length;

    // Let the caller's invite loop run well past the answer.
    await Future<void>.delayed(const Duration(milliseconds: 200));
    await _settle();

    expect(
      callee.state.activeCall!.status,
      CallSessionStatus.active,
      reason: 'a re-ringed invite must not undo the answer',
    );
    expect(callee.state.activeCall!.isIncoming, isFalse);
    expect(caller.state.activeCall!.status, CallSessionStatus.active);
    expect(
      callee.notifications.activeNotifications,
      hasLength(notificationsAfterAccept),
      reason: 'an answered call must stop raising call notifications',
    );
    expect(
      callee.notifications.ringingAttempts,
      0,
      reason: 'ringing uses the popup, not a shade notification',
    );
    expect(
      caller.notifications.showAttempts,
      isEmpty,
      reason: 'the caller never notifies itself about its own call',
    );
    expect(
      await callee.timelineEntries('Przyszło zaproszenie'),
      1,
      reason: 'the repeats must not spam the conversation',
    );
  });

  test('an answered call raises nothing while the app is on screen', () async {
    final _Peer caller = _Peer(
      address: _callerAddress,
      peerAddress: _calleeAddress,
      peerName: 'Ada',
    );
    final _Peer callee = _Peer(
      address: _calleeAddress,
      peerAddress: _callerAddress,
      peerName: 'Bob',
    );
    _link(caller, callee);
    addTearDown(caller.dispose);
    addTearDown(callee.dispose);

    await caller.controller.sendCallInvite(
      peerAddress: _calleeAddress,
      kind: CallInviteKind.audio,
    );
    await _settle();
    await callee.controller.acceptIncomingCall(peerAddress: _callerAddress);
    await _settle();

    // The media never reports the connection, so the caller keeps inviting for
    // the whole ringing window — the worst case for the callee.
    await Future<void>.delayed(const Duration(milliseconds: 300));
    await _settle();

    expect(
      callee.notifications.ringingAttempts,
      0,
      reason:
          'incoming calls do not spam system notifications while the app is open',
    );
    expect(caller.notifications.showAttempts, isEmpty);
    expect(callee.state.activeCall!.isIncoming, isFalse);
    expect(
      await callee.timelineEntries('Przyszło zaproszenie'),
      1,
      reason: 'one invite line per call, not one per second',
    );
  });

  test('answering without the offer recovers it from the caller', () async {
    final _Peer caller = _Peer(
      address: _callerAddress,
      peerAddress: _calleeAddress,
      peerName: 'Ada',
    );
    final _Peer callee = _Peer(
      address: _calleeAddress,
      peerAddress: _callerAddress,
      peerName: 'Bob',
    );
    _link(caller, callee);
    addTearDown(caller.dispose);
    addTearDown(callee.dispose);

    // Exactly what a handoff from the foreground service looks like: the
    // ringing session survived, the SDP offer did not.
    caller.transport.dropTypes.add('offer');
    await caller.controller.sendCallInvite(
      peerAddress: _calleeAddress,
      kind: CallInviteKind.audio,
    );
    await _settle();
    expect(callee.state.activeCall, isNotNull);

    caller.transport.dropTypes.remove('offer');
    await callee.controller.acceptIncomingCall(peerAddress: _callerAddress);
    await _settle();
    await Future<void>.delayed(const Duration(milliseconds: 40));
    await _settle();

    expect(
      callee.media.activeCallId,
      isNotNull,
      reason: 'the re-requested offer has to complete the answer',
    );
    expect(caller.media.appliedAnswers, hasLength(1));
  });

  test('declining clears the call on both sides', () async {
    final _Peer caller = _Peer(
      address: _callerAddress,
      peerAddress: _calleeAddress,
      peerName: 'Ada',
    );
    final _Peer callee = _Peer(
      address: _calleeAddress,
      peerAddress: _callerAddress,
      peerName: 'Bob',
    );
    _link(caller, callee);
    addTearDown(caller.dispose);
    addTearDown(callee.dispose);

    await caller.controller.sendCallInvite(
      peerAddress: _calleeAddress,
      kind: CallInviteKind.audio,
    );
    await _settle();

    await callee.controller.declineIncomingCall(peerAddress: _callerAddress);
    await _settle();
    await Future<void>.delayed(const Duration(milliseconds: 1600));
    await _settle();

    expect(callee.state.activeCall, isNull);
    expect(caller.state.activeCall, isNull);
    expect(await caller.timelineEntries('odrzucił'), 1);
  });

  test('a cancelled ring leaves one missed-call notification', () async {
    final _Peer caller = _Peer(
      address: _callerAddress,
      peerAddress: _calleeAddress,
      peerName: 'Ada',
    );
    final _Peer callee = _Peer(
      address: _calleeAddress,
      peerAddress: _callerAddress,
      peerName: 'Bob',
      visibility: AppVisibilityState.background,
    );
    _link(caller, callee);
    addTearDown(caller.dispose);
    addTearDown(callee.dispose);

    await caller.controller.sendCallInvite(
      peerAddress: _calleeAddress,
      kind: CallInviteKind.audio,
    );
    await _settle();
    expect(
      callee.notifications.ringingAttempts,
      0,
      reason: 'ringing uses the popup, not a shade notification',
    );

    await caller.controller.endActiveCall(peerAddress: _calleeAddress);
    await _settle();
    await Future<void>.delayed(const Duration(milliseconds: 1600));
    await _settle();

    expect(callee.state.activeCall, isNull);
    expect(
      callee.notifications.activeNotifications.single.title,
      contains('Nieodebrane'),
    );
    expect(
      callee.notifications.showAttempts
          .where((RuntimeSystemNotification e) => !e.isRingingCall)
          .length,
      1,
      reason: 'the re-sent hangup must not stack missed-call notes',
    );
  });

  test('a burst of invites for one call rings once', () async {
    final _Peer callee = _Peer(
      address: _calleeAddress,
      peerAddress: _callerAddress,
      peerName: 'Bob',
      visibility: AppVisibilityState.background,
    );
    addTearDown(callee.dispose);

    // Delivered without waiting for each other, the way the transport hands
    // frames over: the invite, its offer and every re-ring land on top of one
    // another. Each one used to start from the state it read on entry, decide
    // the call was new, and ring again.
    final List<Future<void>> deliveries = <Future<void>>[
      callee.receiveFrame(_callerAddress, <String, dynamic>{
        'type': 'call_invite',
        'callId': 'burst-call',
        'kind': 'audio',
      }),
      callee.receiveFrame(_callerAddress, <String, dynamic>{
        'type': 'offer',
        'callId': 'burst-call',
        'kind': 'audio',
        'description': <String, dynamic>{'type': 'offer', 'sdp': 'v=0'},
      }),
      for (int index = 0; index < 20; index += 1)
        callee.receiveFrame(_callerAddress, <String, dynamic>{
          'type': 'call_invite',
          'callId': 'burst-call',
          'kind': 'audio',
        }),
    ];
    await Future.wait(deliveries);
    await _settle();

    expect(
      callee.notifications.ringingAttempts,
      0,
      reason: 'ringing uses the popup, not a shade notification',
    );
    expect(callee.state.activeCall!.id, 'burst-call');
    expect(await callee.timelineEntries('Przyszło zaproszenie'), 1);
  });

  test('hanging up clears the call on both sides', () async {
    final _Peer caller = _Peer(
      address: _callerAddress,
      peerAddress: _calleeAddress,
      peerName: 'Ada',
    );
    final _Peer callee = _Peer(
      address: _calleeAddress,
      peerAddress: _callerAddress,
      peerName: 'Bob',
    );
    _link(caller, callee);
    addTearDown(caller.dispose);
    addTearDown(callee.dispose);

    await caller.controller.sendCallInvite(
      peerAddress: _calleeAddress,
      kind: CallInviteKind.audio,
    );
    await _settle();
    await callee.controller.acceptIncomingCall(peerAddress: _callerAddress);
    await _settle();
    caller.media.markActive();
    callee.media.markActive();
    await _settle();

    await callee.controller.endActiveCall(peerAddress: _callerAddress);
    await _settle();
    // Let the teardown re-sends land as well.
    await Future<void>.delayed(const Duration(milliseconds: 1600));
    await _settle();

    expect(callee.state.activeCall, isNull);
    expect(
      caller.state.activeCall,
      isNull,
      reason: 'the hangup has to reach the other side',
    );
    expect(
      await caller.timelineEntries('zakończył'),
      1,
      reason: 'the re-sent teardown must be applied once',
    );
  });

  test('a lost answer is recovered by the caller own re-ring', () async {
    final _Peer caller = _Peer(
      address: _callerAddress,
      peerAddress: _calleeAddress,
      peerName: 'Ada',
    );
    final _Peer callee = _Peer(
      address: _calleeAddress,
      peerAddress: _callerAddress,
      peerName: 'Bob',
    );
    _link(caller, callee);
    addTearDown(caller.dispose);
    addTearDown(callee.dispose);

    await caller.controller.sendCallInvite(
      peerAddress: _calleeAddress,
      kind: CallInviteKind.audio,
    );
    await _settle();

    // The answer this accept sends never makes it across.
    callee.transport.dropTypes.add('answer');
    await callee.controller.acceptIncomingCall(peerAddress: _callerAddress);
    await _settle();
    expect(caller.media.appliedAnswers, isEmpty);

    // The caller keeps inviting; the callee takes the repeat as its cue to
    // send the answer again.
    callee.transport.dropTypes.remove('answer');
    await Future<void>.delayed(const Duration(milliseconds: 120));
    await _settle();

    expect(
      caller.media.appliedAnswers,
      hasLength(1),
      reason: 'the re-sent answer has to reach the caller exactly once',
    );
  });
}

Future<void> _settle() async {
  for (int index = 0; index < 12; index += 1) {
    await Future<void>.delayed(Duration.zero);
  }
}

void _link(_Peer left, _Peer right) {
  left.transport.deliver = right.receiveFrame;
  right.transport.deliver = left.receiveFrame;
}

final class _Peer {
  _Peer({
    required this.address,
    required String peerAddress,
    required String peerName,
    AppVisibilityState visibility = AppVisibilityState.foregroundFocused,
  }) : transport = _LinkedTransport(address) {
    this.peerAddress = peerAddress;
    media = _ScriptedCallMedia(transport);
    container = ProviderContainer(
      overrides: [
        signalQueueStoreProvider.overrideWithValue(MemorySignalQueueStore()),
        socialSnapshotStoreProvider.overrideWithValue(
          MemorySocialSnapshotStore(),
        ),
        messageTimelineStoreProvider.overrideWithValue(timelineStore),
        signalTransportProvider.overrideWithValue(transport),
        callMediaSessionControllerProvider.overrideWithValue(media),
        runtimeSystemNotificationServiceProvider.overrideWithValue(
          notifications,
        ),
        // Fast enough to exercise the loop inside a test.
        callReRingIntervalProvider.overrideWithValue(
          const Duration(milliseconds: 20),
        ),
        socialHubSeedProvider.overrideWithValue(
          SocialHubState.empty(
            lifecycle: LifecycleSnapshot(
              visibility: visibility,
              generation: 1,
              capturedAtMillis: 0,
            ),
          ).copyWith(
            friends: <String, FriendProfile>{
              peerAddress: FriendProfile(
                address: peerAddress,
                displayName: peerName,
                status: FriendRelationshipStatus.accepted,
              ),
            },
          ),
        ),
      ],
    );
    controller = container.read(socialHubControllerProvider.notifier);
  }

  final String address;
  late final String peerAddress;
  final _LinkedTransport transport;
  final MemoryMessageTimelineStore timelineStore = MemoryMessageTimelineStore();
  final _CountingNotificationService notifications =
      _CountingNotificationService();
  late final _ScriptedCallMedia media;
  late final ProviderContainer container;
  late final SocialHubController controller;

  Future<void> receiveFrame(String from, Map<String, dynamic> payload) async {
    final ZenSignal? signal = zenSignalFromTransportPayload(
      sender: from,
      payload: payload,
    );
    if (signal == null) {
      return;
    }
    await controller.receiveSignal(signal);
  }

  SocialHubState get state => container.read(socialHubControllerProvider);

  Future<int> timelineEntries(String needle) async {
    final List<ChatMessage> thread = await timelineStore.load(peerAddress);
    return thread
        .where((ChatMessage message) => message.text.contains(needle))
        .length;
  }

  void dispose() {
    container.dispose();
  }
}

/// Counts what the pipeline *tries* to post, not just what is left on screen.
///
/// A repeat that replaces the entry in its slot keeps `activeNotifications` at
/// one while re-firing the ringtone on a real phone, so the attempts are the
/// number that matters.
final class _CountingNotificationService
    implements RuntimeSystemNotificationService {
  final MemoryRuntimeSystemNotificationService _inner =
      MemoryRuntimeSystemNotificationService();
  final List<RuntimeSystemNotification> showAttempts =
      <RuntimeSystemNotification>[];

  List<RuntimeSystemNotification> get activeNotifications =>
      _inner.activeNotifications;

  int get ringingAttempts => showAttempts
      .where((RuntimeSystemNotification e) => e.isRingingCall)
      .length;

  @override
  Future<void> initialize({
    required Future<void> Function(String routeKey) onOpenRoute,
    NotificationActionCallback? onAction,
  }) {
    return _inner.initialize(onOpenRoute: onOpenRoute, onAction: onAction);
  }

  @override
  Future<bool> show(RuntimeSystemNotification notification) {
    showAttempts.add(notification);
    return _inner.show(notification);
  }

  @override
  Future<void> dismiss(String id) => _inner.dismiss(id);

  @override
  Future<void> dismissSlot(String slotKey) => _inner.dismissSlot(slotKey);

  @override
  Future<void> clear() => _inner.clear();
}

final class _LinkedTransport implements SignalTransport {
  _LinkedTransport(this.address);

  final String address;
  final StreamController<SignalTransportFrame> _frames =
      StreamController<SignalTransportFrame>.broadcast();

  /// Payload types that silently go missing, to model a lost datagram.
  final Set<String> dropTypes = <String>{};
  Future<void> Function(String from, Map<String, dynamic> payload)? deliver;

  @override
  Stream<SignalTransportFrame> get frames => _frames.stream;

  @override
  Future<void> start() async {}

  @override
  Future<void> stop() async {}

  @override
  Future<void> send({
    required String remoteAddress,
    required Map<String, dynamic> payload,
  }) async {
    final String type = payload['type'] as String? ?? '';
    if (dropTypes.contains(type)) {
      return;
    }
    final Future<void> Function(String, Map<String, dynamic>)? sink = deliver;
    if (sink == null) {
      return;
    }
    // Delivered out of band, like a real datagram: sending must never run the
    // peer's handling inside the sender's own call stack.
    unawaited(
      Future<void>.microtask(
        () => sink(address, Map<String, dynamic>.from(payload)),
      ),
    );
  }

  @override
  Future<int> openRelay({
    required String callId,
    required String remoteAddress,
  }) async => 0;

  @override
  Future<void> closeRelay(String callId) async {}
}

/// Media controller that performs the SDP handshake over the transport without
/// touching WebRTC.
final class _ScriptedCallMedia extends CallMediaSessionController {
  _ScriptedCallMedia(this.transport);

  final SignalTransport transport;
  final List<Map<String, dynamic>> appliedAnswers = <Map<String, dynamic>>[];

  String? _callId;
  String? _remote;
  CallInviteKind? _kind;
  Map<String, dynamic>? _lastAnswer;
  bool _awaitingAnswer = false;
  CallMediaStatusListener? _onStatusChanged;
  CallMediaErrorListener? _onError;

  void markActive() {
    final String? callId = _callId;
    if (callId != null) {
      _onStatusChanged?.call(callId, CallMediaSessionLifecycle.active);
    }
  }

  @override
  String? get activeCallId => _callId;

  @override
  CallInviteKind? get activeKind => _kind;

  @override
  bool get hasLocalStream => _callId != null;

  @override
  bool get hasLocalVideo => false;

  @override
  bool get hasRemoteStream => _callId != null;

  @override
  bool get hasRemoteVideo => false;

  @override
  RTCVideoRenderer? get localRenderer => null;

  @override
  RTCVideoRenderer? get remoteRenderer => null;

  @override
  String? get remoteAddress => _remote;

  @override
  CallMediaStatusListener? get onStatusChanged => _onStatusChanged;

  @override
  set onStatusChanged(CallMediaStatusListener? value) {
    _onStatusChanged = value;
  }

  @override
  CallMediaErrorListener? get onError => _onError;

  @override
  set onError(CallMediaErrorListener? value) {
    _onError = value;
  }

  @override
  Future<void> startOutgoing({
    required String callId,
    required String remoteAddress,
    required CallInviteKind kind,
  }) async {
    _callId = callId;
    _remote = remoteAddress;
    _kind = kind;
    _awaitingAnswer = true;
    await transport.send(
      remoteAddress: remoteAddress,
      payload: <String, dynamic>{
        'type': 'offer',
        'callId': callId,
        'kind': kind.name,
        'description': <String, dynamic>{'type': 'offer', 'sdp': 'v=0'},
      },
    );
  }

  @override
  Future<void> acceptIncoming({
    required String callId,
    required String remoteAddress,
    required CallInviteKind kind,
    required Map<String, dynamic> remoteDescription,
  }) async {
    _callId = callId;
    _remote = remoteAddress;
    _kind = kind;
    _lastAnswer = <String, dynamic>{'type': 'answer', 'sdp': 'v=0'};
    await transport.send(
      remoteAddress: remoteAddress,
      payload: <String, dynamic>{
        'type': 'answer',
        'callId': callId,
        'kind': kind.name,
        'description': _lastAnswer,
      },
    );
  }

  @override
  Future<void> handleRemoteOffer({
    required CallInviteKind kind,
    required Map<String, dynamic> remoteDescription,
  }) async {}

  @override
  Future<void> applyRemoteAnswer(Map<String, dynamic> description) async {
    if (!_awaitingAnswer) {
      return;
    }
    _awaitingAnswer = false;
    appliedAnswers.add(description);
  }

  @override
  Future<bool> resendLocalOffer(String callId) async {
    if (_callId != callId || _kind == null) {
      return false;
    }
    await transport.send(
      remoteAddress: _remote!,
      payload: <String, dynamic>{
        'type': 'offer',
        'callId': callId,
        'kind': _kind!.name,
        'description': <String, dynamic>{'type': 'offer', 'sdp': 'v=0'},
      },
    );
    return true;
  }

  @override
  Future<bool> resendLocalAnswer(String callId) async {
    final Map<String, dynamic>? answer = _lastAnswer;
    if (_callId != callId || answer == null || _kind == null) {
      return false;
    }
    await transport.send(
      remoteAddress: _remote!,
      payload: <String, dynamic>{
        'type': 'answer',
        'callId': callId,
        'kind': _kind!.name,
        'description': answer,
      },
    );
    return true;
  }

  @override
  Future<void> setMuted(bool muted) async {}

  @override
  Future<void> setSpeakerOn(bool enabled) async {}

  @override
  Future<void> setCameraEnabled(bool enabled) async {}

  @override
  Future<void> close() async {
    final String? callId = _callId;
    _callId = null;
    _remote = null;
    _kind = null;
    _lastAnswer = null;
    _awaitingAnswer = false;
    if (callId != null) {
      _onStatusChanged?.call(callId, CallMediaSessionLifecycle.ended);
    }
  }
}
