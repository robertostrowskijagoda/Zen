import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:zen/src/domain/calls/call_invite_kind.dart';
import 'package:zen/src/domain/calls/call_session.dart';
import 'package:zen/src/domain/friends/friend_profile.dart';
import 'package:zen/src/domain/runtime/lifecycle_snapshot.dart';
import 'package:zen/src/domain/signals/signal_queue_store.dart';
import 'package:zen/src/features/calls/call_media_session.dart';
import 'package:zen/src/features/calls/presentation/call_floating_overlay.dart';
import 'package:zen/src/features/calls/presentation/call_surface_screen.dart';
import 'package:zen/src/features/chat/message_timeline_store.dart';
import 'package:zen/src/features/runtime/runtime_signal_parser.dart';
import 'package:zen/src/features/runtime/runtime_system_notifications.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';
import 'package:zen/src/features/social/friendship_book.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';
import 'package:zen/src/features/social/social_hub_controller.dart';
import 'package:zen/src/features/social/social_hub_state.dart';
import 'package:zen/src/features/social/social_snapshot_store.dart';

// The controls of a call from the first ring on: microphone, loudspeaker,
// camera and the camera switch work while a call rings out and while it
// connects, not only once the other side answered; what is chosen then
// holds when the call connects. An incoming call that rings has only
// "Odbierz" and "Odrzuć".

final String _cyd = PeerShareCodec.normalizeAddress('200::c0d');

/// The call's media: records what the controls asked of it, and is set up
/// (its offer sent) only when [ready] says so.
final class _Media extends CallMediaSessionController {
  bool ready = true;
  bool camera = true;
  final List<String> calls = <String>[];
  String? _id;
  String? _remote;
  CallInviteKind? _kind;
  CallMediaStatusListener? _onStatus;
  CallMediaErrorListener? _onError;

  void connect() => _onStatus?.call(_id!, CallMediaSessionLifecycle.active);

  @override
  bool get controlsReady => ready && _id != null;
  @override
  RTCVideoRenderer? get localRenderer => null;
  @override
  RTCVideoRenderer? get remoteRenderer => null;
  @override
  String? get activeCallId => _id;
  @override
  String? get remoteAddress => _remote;
  @override
  CallInviteKind? get activeKind => _kind;
  @override
  bool get hasLocalStream => _id != null;
  @override
  bool get hasRemoteStream => false;
  @override
  bool get hasLocalVideo => _id != null && camera;
  @override
  bool get hasRemoteVideo => false;
  @override
  CallMediaStatusListener? get onStatusChanged => _onStatus;
  @override
  set onStatusChanged(CallMediaStatusListener? v) => _onStatus = v;
  @override
  CallMediaErrorListener? get onError => _onError;
  @override
  set onError(CallMediaErrorListener? v) => _onError = v;

  @override
  Future<void> startOutgoing({
    required String callId,
    required String remoteAddress,
    required CallInviteKind kind,
  }) async {
    _id = callId;
    _remote = remoteAddress;
    _kind = kind;
    camera = kind == CallInviteKind.video;
    notifyListeners();
  }

  @override
  Future<void> acceptIncoming({
    required String callId,
    required String remoteAddress,
    required CallInviteKind kind,
    required Map<String, dynamic> remoteDescription,
  }) async {
    _id = callId;
    _remote = remoteAddress;
    _kind = kind;
    camera = kind == CallInviteKind.video;
    notifyListeners();
  }

  @override
  Future<void> handleRemoteOffer({
    required CallInviteKind kind,
    required Map<String, dynamic> remoteDescription,
  }) async {}
  @override
  Future<void> applyRemoteAnswer(Map<String, dynamic> description) async {}
  @override
  Future<bool> resendLocalOffer(String callId) async => false;
  @override
  Future<bool> resendLocalAnswer(String callId) async => false;

  @override
  Future<void> setMuted(bool muted) async {
    calls.add('microphone ${muted ? 'off' : 'on'}');
    notifyListeners();
  }

  @override
  Future<void> setSpeakerOn(bool enabled) async {
    calls.add('loudspeaker ${enabled ? 'on' : 'off'}');
    notifyListeners();
  }

  @override
  Future<void> setCameraEnabled(bool enabled) async {
    calls.add('camera ${enabled ? 'on' : 'off'}');
    camera = enabled;
    notifyListeners();
  }

  @override
  Future<void> switchCamera() async {
    calls.add('switch camera');
  }

  @override
  Future<void> close() async {
    _id = null;
    _remote = null;
    _kind = null;
  }
}

final class _Phone {
  _Phone() {
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
        runtimeSystemNotificationServiceProvider.overrideWithValue(
          MemoryRuntimeSystemNotificationService(),
        ),
        callReRingIntervalProvider.overrideWithValue(Duration.zero),
        callRingingWaitTimeoutProvider.overrideWithValue(Duration.zero),
        deviceLockedProbeProvider.overrideWithValue(() async => false),
        socialHubAutoHydrateProvider.overrideWithValue(false),
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
                _cyd: FriendProfile(
                  address: _cyd,
                  displayName: 'Cyd',
                  status: FriendRelationshipStatus.accepted,
                ),
              },
            ),
          ),
        ),
      ],
    );
    hub = container.read(socialHubControllerProvider.notifier);
  }

  final _Media media = _Media();
  final MemorySignalTransport transport = MemorySignalTransport();
  late final ProviderContainer container;
  late final SocialHubController hub;

  CallSession? get call =>
      container.read(socialHubControllerProvider).activeCall;

  /// Cyd calls this phone: her invite and her offer.
  Future<void> rungBy(String callId) async {
    for (final Map<String, dynamic> payload in <Map<String, dynamic>>[
      <String, dynamic>{
        'type': 'call_invite',
        'callId': callId,
        'kind': 'video',
      },
      <String, dynamic>{
        'type': 'offer',
        'callId': callId,
        'kind': 'video',
        'description': <String, dynamic>{'type': 'offer', 'sdp': 'v=0'},
      },
    ]) {
      await hub.receiveSignal(
        zenSignalFromTransportPayload(sender: _cyd, payload: payload)!,
        receivedAtMillis: 1000,
      );
    }
  }
}

Widget _app(_Phone phone, Widget home) => UncontrolledProviderScope(
  container: phone.container,
  child: MaterialApp(home: home),
);

IconButton _button(WidgetTester tester, String key) =>
    tester.widget<IconButton>(find.byKey(Key(key)));

void main() {
  group('the controller', () {
    test('ringing out: microphone, loudspeaker and camera act on the media '
        'and the call, and hold when the call connects', () async {
      final _Phone p = _Phone();
      addTearDown(p.container.dispose);
      await p.hub.sendCallInvite(peerAddress: _cyd, kind: CallInviteKind.video);
      expect(p.call!.status, CallSessionStatus.ringing);
      expect(p.call!.isSpeakerOn, isTrue);
      expect(p.call!.isCameraEnabled, isTrue);

      await p.hub.toggleActiveCallMute();
      await p.hub.toggleActiveCallSpeaker();
      await p.hub.toggleActiveCallCamera();
      expect(p.media.calls, <String>[
        'microphone off',
        'loudspeaker off',
        'camera off',
      ]);
      expect(p.call!.status, CallSessionStatus.ringing);
      expect(p.call!.isMuted, isTrue);
      expect(p.call!.isSpeakerOn, isFalse);
      expect(p.call!.isCameraEnabled, isFalse);

      p.media.connect();
      await Future<void>.delayed(Duration.zero);
      final CallSession talking = p.call!;
      expect(talking.status, CallSessionStatus.active);
      expect(talking.isMuted, isTrue);
      expect(talking.isCameraEnabled, isFalse);
      expect(talking.isSpeakerOn, isFalse);
      // The earpiece chosen while it rang is routed once more as the
      // call's sound starts.
      expect(p.media.calls.last, 'loudspeaker off');
    });

    test('the media still being set up: the controls wait', () async {
      final _Phone p = _Phone();
      addTearDown(p.container.dispose);
      p.media.ready = false;
      await p.hub.sendCallInvite(peerAddress: _cyd, kind: CallInviteKind.video);
      await p.hub.toggleActiveCallMute();
      await p.hub.toggleActiveCallCamera();
      expect(p.media.calls, isEmpty);
      expect(p.call!.isMuted, isFalse);
      expect(p.call!.isCameraEnabled, isTrue);
    });

    test('an incoming call that rings: nothing to switch before answering; '
        'once accepted, while it connects, everything', () async {
      final _Phone p = _Phone();
      addTearDown(p.container.dispose);
      await p.rungBy('call-cyd-1');
      expect(p.call!.isIncoming, isTrue);
      expect(p.call!.ownControlsShown, isFalse);
      await p.hub.toggleActiveCallMute();
      expect(p.media.calls, isEmpty);

      await p.hub.acceptIncomingCall(peerAddress: _cyd);
      expect(p.call!.status, CallSessionStatus.connecting);
      expect(p.call!.ownControlsShown, isTrue);
      await p.hub.toggleActiveCallCamera();
      await p.hub.toggleActiveCallMute();
      expect(p.media.calls, <String>['camera off', 'microphone off']);
      p.media.connect();
      await Future<void>.delayed(Duration.zero);
      expect(p.call!.status, CallSessionStatus.active);
      expect(p.call!.isCameraEnabled, isFalse);
      expect(p.call!.isMuted, isTrue);
    });
  });

  group('the call screen', () {
    testWidgets('ringing out: the same controls as in the call, working', (
      WidgetTester tester,
    ) async {
      final _Phone p = _Phone();
      addTearDown(p.container.dispose);
      await tester.runAsync(
        () =>
            p.hub.sendCallInvite(peerAddress: _cyd, kind: CallInviteKind.video),
      );
      await tester.pumpWidget(
        _app(p, CallSurfaceScreen(peerAddress: _cyd, title: 'Cyd')),
      );
      await tester.pumpAndSettle();

      for (final String key in <String>[
        'call-mute-button',
        'call-speaker-button',
        'call-camera-button',
        'call-flip-camera-button',
        'call-devices-button',
        'call-end-button',
      ]) {
        expect(find.byKey(Key(key)), findsOneWidget, reason: key);
      }
      expect(find.text('Anuluj'), findsOneWidget);
      expect(_button(tester, 'call-mute-button').onPressed, isNotNull);

      await tester.tap(find.byKey(const Key('call-flip-camera-button')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('call-camera-button')));
      await tester.pumpAndSettle();
      expect(p.media.calls, <String>['switch camera', 'camera off']);
      expect(p.call!.isCameraEnabled, isFalse);
      expect(p.call!.status, CallSessionStatus.ringing);
      // The camera is off: nothing to switch.
      expect(find.byKey(const Key('call-flip-camera-button')), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('ringing out while the media are still being set up: the '
        'controls show, not yet working', (WidgetTester tester) async {
      final _Phone p = _Phone();
      addTearDown(p.container.dispose);
      p.media.ready = false;
      await tester.runAsync(
        () =>
            p.hub.sendCallInvite(peerAddress: _cyd, kind: CallInviteKind.video),
      );
      await tester.pumpWidget(
        _app(p, CallSurfaceScreen(peerAddress: _cyd, title: 'Cyd')),
      );
      await tester.pumpAndSettle();
      expect(_button(tester, 'call-mute-button').onPressed, isNull);
      expect(_button(tester, 'call-camera-button').onPressed, isNull);
      expect(_button(tester, 'call-end-button').onPressed, isNotNull);

      p.media.ready = true;
      p.media.notifyListeners();
      await tester.pumpAndSettle();
      expect(_button(tester, 'call-mute-button').onPressed, isNotNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('rung: answer or decline, nothing else', (
      WidgetTester tester,
    ) async {
      final _Phone p = _Phone();
      addTearDown(p.container.dispose);
      await tester.runAsync(() => p.rungBy('call-cyd-2'));
      await tester.pumpWidget(
        _app(p, CallSurfaceScreen(peerAddress: _cyd, title: 'Cyd')),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('call-accept-button')), findsOneWidget);
      expect(find.byKey(const Key('call-decline-button')), findsOneWidget);
      expect(find.byKey(const Key('call-mute-button')), findsNothing);
      expect(find.byKey(const Key('call-camera-button')), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets(
      'the floating chip of a call ringing out has the controls too',
      (WidgetTester tester) async {
        final _Phone p = _Phone();
        addTearDown(p.container.dispose);
        await tester.runAsync(
          () => p.hub.sendCallInvite(
            peerAddress: _cyd,
            kind: CallInviteKind.video,
          ),
        );
        await tester.pumpWidget(
          _app(p, const CallFloatingOverlay(child: SizedBox.expand())),
        );
        await tester.pump(const Duration(milliseconds: 500));
        expect(
          find.byKey(const Key('global-call-mute-button')),
          findsOneWidget,
        );
        expect(
          find.byKey(const Key('global-call-camera-button')),
          findsOneWidget,
        );
        await tester.tap(find.byKey(const Key('global-call-mute-button')));
        await tester.pump(const Duration(milliseconds: 100));
        expect(p.media.calls, <String>['microphone off']);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  });
}
