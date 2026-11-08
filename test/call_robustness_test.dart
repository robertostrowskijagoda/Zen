import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:zen/src/domain/calls/call_invite_kind.dart';
import 'package:zen/src/domain/calls/call_session.dart';
import 'package:zen/src/domain/friends/friend_profile.dart';
import 'package:zen/src/domain/runtime/lifecycle_snapshot.dart';
import 'package:zen/src/domain/signals/signal_queue_store.dart';
import 'package:zen/src/domain/signals/zen_signal.dart';
import 'package:zen/src/features/calls/call_media_session.dart';
import 'package:zen/src/features/chat/message_timeline_store.dart';
import 'package:zen/src/features/runtime/runtime_signal_parser.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';
import 'package:zen/src/features/social/friendship_book.dart';
import 'package:zen/src/features/social/social_hub_controller.dart';
import 'package:zen/src/features/social/social_hub_state.dart';
import 'package:zen/src/features/social/social_snapshot_store.dart';

// Two phones in a call, wired to each other, with media that connect the
// way real ones do: the one "connected" event may be lost, a "connecting"
// may come late, a camera may be turned on before this side's media have
// connected, the mesh may deliver an offer twice, the app may read its
// snapshot in the middle. In every combination the call must end up the
// way the person sees it: active on both sides (every button, the time,
// "Łączenie…" gone), each camera reaching the other side exactly once, no
// incoming-call screen in the middle of the call. It is the reported
// "only 'Rozłącz'", "'Łączenie…' in the floating window with no video"
// and "I see them, they do not see me".

const String _a = '200:1111:2222:3333:4444:5555:6666:1';
const String _b = '200:1111:2222:3333:4444:5555:6666:2';

/// How one side's media connect.
enum _Connect {
  /// "connected" reaches the controller.
  told,

  /// The event is lost: the media are connected and say so only when asked.
  lost,

  /// "connected", then a "connecting" that was on its way before it.
  lateConnecting,
}

/// When the caller turns its camera on.
enum _Camera {
  never,

  /// After the answer, before the callee's media connected.
  beforeCalleeConnected,

  /// Once both are connected.
  afterBoth,
}

void main() {
  for (final CallInviteKind kind in CallInviteKind.values) {
    for (final _Connect callee in _Connect.values) {
      for (final _Connect caller in _Connect.values) {
        for (final _Camera camera in _Camera.values) {
          for (final bool duplicateOffer in <bool>[false, true]) {
            test(
              '${kind.name} call, callee ${callee.name}, caller ${caller.name}, '
              'camera ${camera.name}${duplicateOffer ? ', offer twice' : ''}: '
              'active on both sides, every camera seen once',
              () => _scenario(
                kind: kind,
                callee: callee,
                caller: caller,
                camera: camera,
                duplicateOffer: duplicateOffer,
              ),
            );
          }
        }
      }
    }
  }

  test('the first call loses its "connected", the second does not: both are '
      'active, each with all it needs', () async {
    final _Pair p = _Pair();
    addTearDown(p.dispose);
    for (final _Connect how in <_Connect>[_Connect.lost, _Connect.told]) {
      await p.call(CallInviteKind.video);
      await p.callee.media.connect(how);
      await p.caller.media.connect(how);
      await _settle();
      p.expectBothActive();
      await p.caller.controller.endActiveCall(peerAddress: _b);
      await _settle();
      expect(p.caller.state.activeCall, isNull);
      expect(p.callee.state.activeCall, isNull);
    }
  });

  test(
    'the snapshot read in the middle of a talking call leaves it active',
    () async {
      final _Pair p = _Pair();
      addTearDown(p.dispose);
      await p.call(CallInviteKind.audio);
      await p.callee.media.connect(_Connect.lost);
      await p.caller.media.connect(_Connect.lost);
      await _settle();
      await p.callee.controller.hydrateFromStore();
      await p.caller.controller.hydrateFromStore();
      await _settle();
      p.expectBothActive();
    },
  );

  test('a network blip (disconnected, then connected again with the event '
      'lost) ends active again, not on "Łączenie…"', () async {
    final _Pair p = _Pair();
    addTearDown(p.dispose);
    await p.call(CallInviteKind.video);
    await p.callee.media.connect(_Connect.told);
    await p.caller.media.connect(_Connect.told);
    await _settle();
    p.callee.media.blip();
    await _settle();
    expect(p.callee.state.activeCall!.status, CallSessionStatus.connecting);
    await p.callee.media.connect(_Connect.lost);
    await _settle();
    p.expectBothActive();
  });

  test('both cameras on and off again, many times, in any order: each change '
      'reaches the other side once and the call stays active', () async {
    final _Pair p = _Pair();
    addTearDown(p.dispose);
    await p.call(CallInviteKind.audio);
    await p.callee.media.connect(_Connect.lost);
    await p.caller.media.connect(_Connect.told);
    await _settle();
    for (int i = 0; i < 6; i++) {
      final _Side who = i.isEven ? p.caller : p.callee;
      await who.controller.toggleActiveCallCamera();
      await _settle();
      p.expectBothActive();
    }
    expect(p.callee.media.appliedOffers, hasLength(3));
    expect(p.caller.media.appliedOffers, hasLength(3));
    expect(p.callee.media.appliedOffers.toSet(), hasLength(3));
  });
}

Future<void> _scenario({
  required CallInviteKind kind,
  required _Connect callee,
  required _Connect caller,
  required _Camera camera,
  required bool duplicateOffer,
}) async {
  final _Pair p = _Pair();
  addTearDown(p.dispose);
  p.caller.transport.duplicateOffers = duplicateOffer;
  await p.call(kind);
  // The caller's media connect first (it applied the answer); the callee's
  // a moment later.
  await p.caller.media.connect(caller);
  await _settle();
  int offers = 0;
  if (camera == _Camera.beforeCalleeConnected) {
    offers = await p.caller.media.turnCameraOn();
    await _settle();
  }
  await p.callee.media.connect(callee);
  await _settle();
  if (camera == _Camera.afterBoth) {
    offers = await p.caller.media.turnCameraOn();
    await _settle();
  }
  p.expectBothActive();
  if (camera == _Camera.never) {
    expect(p.callee.media.appliedOffers, isEmpty);
  } else {
    final List<String> sent = <String>[
      for (int i = 1; i <= offers; i++) 'v=cam-$i',
    ];
    expect(
      p.callee.media.appliedOffers,
      sent,
      reason: "each change of the caller's camera reached the callee once",
    );
    expect(p.callee.media.remoteVideo, isTrue, reason: 'the callee sees them');
    expect(
      p.caller.media.appliedAnswers,
      hasLength(offers),
      reason: 'each renegotiation was answered',
    );
  }
  expect(
    p.callee.transport.sentAfterAccept('ringing'),
    0,
    reason: 'no "ringing" back in the middle of the call',
  );
}

Future<void> _settle() async {
  for (int i = 0; i < 30; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

final class _Pair {
  _Pair() {
    caller.transport.deliver = callee.receive;
    callee.transport.deliver = caller.receive;
  }

  final _Side caller = _Side(_a, _b, 'Bob');
  final _Side callee = _Side(_b, _a, 'Ada');

  /// [caller] calls, [callee] answers.
  Future<void> call(CallInviteKind kind) async {
    await caller.controller.sendCallInvite(peerAddress: _b, kind: kind);
    await _settle();
    expect(callee.state.activeCall?.isIncoming, isTrue);
    await callee.controller.acceptIncomingCall(peerAddress: _a);
    callee.transport.accepted = true;
    await _settle();
  }

  void expectBothActive() {
    for (final _Side s in <_Side>[caller, callee]) {
      final CallSession? call = s.state.activeCall;
      expect(call, isNotNull, reason: '${s.name}: the call is there');
      expect(
        call!.status,
        CallSessionStatus.active,
        reason: '${s.name}: talking, so active (not "Łączenie…")',
      );
      expect(call.isIncoming, isFalse, reason: '${s.name}: not ringing');
    }
    expect(caller.state.activeCall!.id, callee.state.activeCall!.id);
  }

  void dispose() {
    caller.dispose();
    callee.dispose();
  }
}

final class _Side {
  _Side(this.address, this.peer, String peerName) : transport = _Wire(address) {
    media = _Media(transport);
    container = ProviderContainer(
      overrides: [
        signalQueueStoreProvider.overrideWithValue(MemorySignalQueueStore()),
        socialSnapshotStoreProvider.overrideWithValue(
          MemorySocialSnapshotStore(),
        ),
        messageTimelineStoreProvider.overrideWithValue(
          MemoryMessageTimelineStore(),
        ),
        signalTransportProvider.overrideWithValue(transport),
        callMediaSessionControllerProvider.overrideWithValue(media),
        callReRingIntervalProvider.overrideWithValue(
          const Duration(milliseconds: 20),
        ),
        socialHubSeedProvider.overrideWithValue(
          SocialHubState.empty(
            lifecycle: const LifecycleSnapshot(
              visibility: AppVisibilityState.foregroundFocused,
              generation: 1,
              capturedAtMillis: 0,
            ),
          ).copyWith(
            book: FriendshipBook.restore(
              profiles: <String, FriendProfile>{
                peer: FriendProfile(
                  address: peer,
                  displayName: peerName,
                  status: FriendRelationshipStatus.accepted,
                ),
              },
            ),
          ),
        ),
      ],
    );
    controller = container.read(socialHubControllerProvider.notifier);
  }

  final String address;
  final String peer;
  final _Wire transport;
  late final _Media media;
  late final ProviderContainer container;
  late final SocialHubController controller;

  String get name => address == _a ? 'caller' : 'callee';

  SocialHubState get state => container.read(socialHubControllerProvider);

  Future<void> receive(String from, Map<String, dynamic> payload) async {
    final ZenSignal? signal = zenSignalFromTransportPayload(
      sender: from,
      payload: payload,
    );
    if (signal != null) {
      await controller.receiveSignal(signal);
    }
  }

  void dispose() => container.dispose();
}

final class _Wire implements SignalTransport {
  _Wire(this.address);

  final String address;
  Future<void> Function(String from, Map<String, dynamic> payload)? deliver;

  /// Every renegotiation offer goes twice (the mesh repeats a datagram).
  bool duplicateOffers = false;

  /// The callee answered: what it sends from here on is counted.
  bool accepted = false;
  final Map<String, int> _afterAccept = <String, int>{};

  int sentAfterAccept(String type) => _afterAccept[type] ?? 0;

  @override
  Stream<SignalTransportFrame> get frames =>
      const Stream<SignalTransportFrame>.empty();

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
    if (accepted) {
      _afterAccept[type] = (_afterAccept[type] ?? 0) + 1;
    }
    final Future<void> Function(String, Map<String, dynamic>)? sink = deliver;
    if (sink == null) {
      return;
    }
    final bool twice =
        duplicateOffers &&
        type == 'offer' &&
        (payload['description'] as Map?)?['sdp'] != 'v=0';
    for (int i = 0; i < (twice ? 2 : 1); i++) {
      unawaited(
        Future<void>.microtask(
          () => sink(address, Map<String, dynamic>.from(payload)),
        ),
      );
    }
  }

  @override
  Future<int> openRelay({
    required String callId,
    required String remoteAddress,
  }) async => 0;

  @override
  Future<void> closeRelay(String callId) async {}
}

/// Media that do the handshake over the wire and connect when told to,
/// telling the controller as real ones may (or may not).
final class _Media extends CallMediaSessionController {
  _Media(this.wire);

  final _Wire wire;
  String? _callId;
  String? _remote;
  CallInviteKind? _kind;
  bool _connected = false;

  /// Offers of this side not answered yet.
  int _awaitingAnswers = 0;
  bool _camera = false;
  int _cameraOffers = 0;
  String? _lastOfferSdp;
  Map<String, dynamic>? _lastAnswer;
  CallMediaStatusListener? _onStatusChanged;
  CallMediaErrorListener? _onError;

  /// Offers from the other side applied (renegotiations), by SDP.
  final List<String> appliedOffers = <String>[];

  /// Answers to this side's renegotiations applied.
  final List<Map<String, dynamic>> appliedAnswers = <Map<String, dynamic>>[];

  /// The other side's camera shows here.
  bool remoteVideo = false;

  /// The media connect, and tell the controller [how].
  Future<void> connect(_Connect how) async {
    final String? callId = _callId;
    if (callId == null) {
      return;
    }
    _connected = true;
    notifyListeners();
    if (how != _Connect.lost) {
      _onStatusChanged?.call(callId, CallMediaSessionLifecycle.active);
    }
    if (how == _Connect.lateConnecting) {
      await Future<void>.delayed(Duration.zero);
      _onStatusChanged?.call(callId, CallMediaSessionLifecycle.connecting);
    }
  }

  /// The path drops for a moment.
  void blip() {
    final String? callId = _callId;
    if (callId == null) {
      return;
    }
    _connected = false;
    notifyListeners();
    _onStatusChanged?.call(callId, CallMediaSessionLifecycle.connecting);
  }

  /// The camera on: for a video call (on already) off and on again, so
  /// there is a change to send either way. Returns the offers it made.
  Future<int> turnCameraOn() async {
    final int before = _cameraOffers;
    if (_camera) {
      await setCameraEnabled(false);
    }
    await setCameraEnabled(true);
    return _cameraOffers - before;
  }

  @override
  bool get isConnected => _connected && _callId != null;

  @override
  String? get activeCallId => _callId;

  @override
  CallInviteKind? get activeKind => _kind;

  @override
  bool get hasLocalStream => _callId != null;

  @override
  bool get hasLocalVideo => _camera;

  @override
  bool get hasRemoteStream => _callId != null;

  @override
  bool get hasRemoteVideo => remoteVideo;

  @override
  RTCVideoRenderer? get localRenderer => null;

  @override
  RTCVideoRenderer? get remoteRenderer => null;

  @override
  String? get remoteAddress => _remote;

  @override
  CallMediaStatusListener? get onStatusChanged => _onStatusChanged;

  @override
  set onStatusChanged(CallMediaStatusListener? value) =>
      _onStatusChanged = value;

  @override
  CallMediaErrorListener? get onError => _onError;

  @override
  set onError(CallMediaErrorListener? value) => _onError = value;

  /// [kind]: what the description says this side sends; its camera by
  /// default.
  Future<void> _send(
    String type,
    Map<String, dynamic> description, {
    CallInviteKind? kind,
  }) => wire.send(
    remoteAddress: _remote!,
    payload: <String, dynamic>{
      'type': type,
      'callId': _callId,
      'kind': (kind ?? (_camera ? CallInviteKind.video : CallInviteKind.audio))
          .name,
      'description': description,
    },
  );

  @override
  Future<void> startOutgoing({
    required String callId,
    required String remoteAddress,
    required CallInviteKind kind,
  }) async {
    _callId = callId;
    _remote = remoteAddress;
    _kind = kind;
    _camera = kind == CallInviteKind.video;
    _awaitingAnswers = 1;
    await _send('offer', <String, dynamic>{'type': 'offer', 'sdp': 'v=0'});
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
    _lastOfferSdp = remoteDescription['sdp'] as String?;
    remoteVideo = kind == CallInviteKind.video;
    _lastAnswer = <String, dynamic>{'type': 'answer', 'sdp': 'a=0'};
    await _send('answer', _lastAnswer!, kind: kind);
  }

  @override
  Future<void> handleRemoteOffer({
    required CallInviteKind kind,
    required Map<String, dynamic> remoteDescription,
  }) async {
    final String sdp = remoteDescription['sdp'] as String;
    if (sdp == _lastOfferSdp) {
      // The same offer again: applied once (as the real media do).
      return;
    }
    _lastOfferSdp = sdp;
    appliedOffers.add(sdp);
    remoteVideo = kind == CallInviteKind.video;
    _lastAnswer = <String, dynamic>{'type': 'answer', 'sdp': 'a-$sdp'};
    await _send('answer', _lastAnswer!);
    notifyListeners();
  }

  @override
  Future<void> applyRemoteAnswer(Map<String, dynamic> description) async {
    if (_awaitingAnswers == 0) {
      return;
    }
    _awaitingAnswers -= 1;
    if (description['sdp'] != 'a=0') {
      appliedAnswers.add(description);
    }
  }

  @override
  Future<bool> resendLocalOffer(String callId) async => false;

  @override
  Future<bool> resendLocalAnswer(String callId) async => false;

  @override
  Future<void> setMuted(bool muted) async {}

  @override
  Future<void> setSpeakerOn(bool enabled) async {}

  @override
  Future<void> setCameraEnabled(bool enabled) async {
    if (_callId == null || enabled == _camera) {
      return;
    }
    _camera = enabled;
    _cameraOffers += 1;
    _awaitingAnswers += 1;
    notifyListeners();
    await _send('offer', <String, dynamic>{
      'type': 'offer',
      'sdp': 'v=cam-$_cameraOffers',
    });
  }

  @override
  Future<void> close() async {
    final String? callId = _callId;
    _callId = null;
    _connected = false;
    _camera = false;
    _cameraOffers = 0;
    _lastOfferSdp = null;
    remoteVideo = false;
    if (callId != null) {
      _onStatusChanged?.call(callId, CallMediaSessionLifecycle.ended);
    }
  }
}
