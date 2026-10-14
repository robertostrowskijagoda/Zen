import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:zen/src/core/logging/zen_log.dart';
import 'package:zen/src/domain/calls/call_invite_kind.dart';
import 'package:zen/src/features/calls/call_media_devices.dart';
import 'package:zen/src/features/calls/call_recorder.dart';
import 'package:zen/src/features/calls/call_recordings.dart';
import 'package:zen/src/features/calls/call_screen_share.dart';
import 'package:zen/src/features/calls/group_call_media.dart';
import 'package:zen/src/features/ledger/ledger_providers.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';

part 'group_call_media_webrtc.dart';

enum CallMediaSessionLifecycle { connecting, active, ended }

enum CallMediaDeviceKind { camera, microphone, speaker }

@immutable
final class CallMediaDevice {
  const CallMediaDevice({
    required this.id,
    required this.label,
    required this.kind,
  });

  final String id;
  final String label;
  final CallMediaDeviceKind kind;
}

typedef CallMediaStatusListener =
    void Function(String callId, CallMediaSessionLifecycle status);
typedef CallMediaErrorListener = void Function(String? callId, Object error);

abstract class CallMediaSessionController extends ChangeNotifier {
  RTCVideoRenderer? get localRenderer;
  RTCVideoRenderer? get remoteRenderer;
  String? get activeCallId;
  String? get remoteAddress;
  CallInviteKind? get activeKind;
  bool get hasLocalStream;
  bool get hasRemoteStream;
  bool get hasLocalVideo;
  bool get hasRemoteVideo;

  CallMediaStatusListener? get onStatusChanged;
  set onStatusChanged(CallMediaStatusListener? value);

  CallMediaErrorListener? get onError;
  set onError(CallMediaErrorListener? value);

  Future<void> startOutgoing({
    required String callId,
    required String remoteAddress,
    required CallInviteKind kind,
  });

  Future<void> acceptIncoming({
    required String callId,
    required String remoteAddress,
    required CallInviteKind kind,
    required Map<String, dynamic> remoteDescription,
  });

  Future<void> handleRemoteOffer({
    required CallInviteKind kind,
    required Map<String, dynamic> remoteDescription,
  });

  Future<void> applyRemoteAnswer(Map<String, dynamic> description);

  /// Re-sends the last locally produced offer for [callId]. Used when the
  /// callee accepted the invite but never received the SDP offer (e.g. the
  /// payload was dropped during a transport restart) and asks for it again.
  /// Returns false when no matching offer is available.
  Future<bool> resendLocalOffer(String callId);

  /// Sends the last local answer again.
  ///
  /// The answer is a single unacknowledged datagram; when it is lost the
  /// caller sits on a call nobody seems to pick up while this side already
  /// answered. Returns false when there is nothing to re-send.
  Future<bool> resendLocalAnswer(String callId);

  Future<void> setMuted(bool muted);
  Future<void> setSpeakerOn(bool enabled);
  Future<void> setCameraEnabled(bool enabled);

  Future<List<CallMediaDevice>> listMediaDevices() async =>
      const <CallMediaDevice>[];

  Future<void> selectMediaDevice(CallMediaDevice device) async {}

  Future<void> switchCamera() async {}

  /// This side shares its screen (or one app/window) instead of the camera.
  bool get isScreenSharing => false;

  /// The other side shares its screen.
  bool get remoteScreenSharing => false;

  /// Screens and windows to pick from (desktop); empty on phones, where the
  /// system asks (whole screen or one app, Android 14+).
  Future<List<ScreenShareSource>> listScreenSources() async =>
      const <ScreenShareSource>[];

  Future<void> startScreenShare({String? sourceId}) async {
    throw UnsupportedError('Udostępnianie ekranu nie jest tu dostępne.');
  }

  Future<void> stopScreenShare() async {}

  /// Whether this device can record calls (§13.2).
  bool get canRecord => false;

  /// This side is recording; the other side always knows (signal + banner).
  bool get isRecording => false;

  /// The other side is recording this call.
  bool get remoteRecording => false;

  /// File type of recordings on this device ("mp4", "wav").
  String get recordingExtension => 'mp4';

  /// Starts recording the call into [path] and tells the other side.
  /// [label] names the recording (who the call is with).
  Future<void> startRecording(String path, {String label = ''}) async {
    throw UnsupportedError('Nagrywanie nie jest tu dostępne.');
  }

  /// Stops recording; returns the file path, or null when nothing ran.
  Future<String?> stopRecording() async => null;

  /// Gets every finished recording — stopped by hand or by the end of the
  /// call — to be kept (encrypted) in the app.
  CallRecordingFinished? onRecordingFinished;

  Future<Map<String, dynamic>> dumpDiagnostics() async =>
      const <String, dynamic>{};

  Future<void> close();
}

/// A recording that just ended: the file, its type and who it was with.
typedef CallRecordingFinished =
    void Function(String path, String mime, String label);

final Provider<CallMediaSessionController> callMediaSessionControllerProvider =
    Provider<CallMediaSessionController>((Ref ref) {
      final WebRtcCallMediaSessionController controller =
          WebRtcCallMediaSessionController(
            transport: ref.read(signalTransportProvider),
          );
      controller.onRecordingFinished =
          (String path, String mime, String label) => unawaitedLogged(
            keepCallRecording(
              ref.read(ledgerDiskProvider),
              path: path,
              mime: mime,
              label: label,
            ),
            context: 'Saving the call recording failed',
          );
      // `dispose` closes the session first and only then releases the
      // renderers, so a separate `close()` here would just race it.
      ref.onDispose(controller.dispose);
      return controller;
    });

List buildCallMediaSessionProviderOverrides({
  required CallMediaSessionController controller,
}) {
  return [callMediaSessionControllerProvider.overrideWithValue(controller)];
}

final class WebRtcCallMediaSessionController
    extends CallMediaSessionController {
  WebRtcCallMediaSessionController({
    required this.transport,
    CallRecorder? recorder,
  }) : _recorder = recorder ?? platformCallRecorder() {
    _callFrames = transport.frames.listen(_onCallFrame);
  }

  StreamSubscription<SignalTransportFrame>? _callFrames;
  MediaStream? _screenStream;
  bool _remoteScreenSharing = false;
  final CallRecorder _recorder;
  String? _recordingPath;
  String _recordingLabel = '';
  bool _remoteRecording = false;

  @override
  bool get canRecord => _recorder.available;

  @override
  String get recordingExtension => _recorder.extension;

  @override
  bool get isRecording => _recordingPath != null;

  @override
  bool get remoteRecording => _remoteRecording;

  @override
  Future<void> startRecording(String path, {String label = ''}) async {
    if (!canRecord) {
      throw UnsupportedError(
        'Nagrywanie rozmów nie jest jeszcze dostępne na tym urządzeniu.',
      );
    }
    if (_peerConnection == null || _recordingPath != null) {
      return;
    }
    final List<MediaStreamTrack> video =
        _remoteStream?.getVideoTracks() ?? const <MediaStreamTrack>[];
    // Announced first: nobody is recorded without knowing (§13.2).
    _sendCallSignal(kCallRecordingSignal, true);
    try {
      await _recorder.start(path, video: video.isEmpty ? null : video.first);
    } on Object {
      _sendCallSignal(kCallRecordingSignal, false);
      rethrow;
    }
    _recordingPath = path;
    _recordingLabel = label;
    _notify();
  }

  @override
  Future<String?> stopRecording() async {
    final String? path = _recordingPath;
    if (path == null) {
      return null;
    }
    await _finishRecording(tell: true);
    _notify();
    return path;
  }

  /// Stops the recorder and hands the file over to be kept.
  Future<void> _finishRecording({required bool tell}) async {
    final String? path = _recordingPath;
    if (path == null) {
      return;
    }
    _recordingPath = null;
    try {
      await _recorder.stop();
    } catch (error, stackTrace) {
      logZenError('Stopping the call recording failed', error, stackTrace);
    }
    if (tell) {
      _sendCallSignal(kCallRecordingSignal, false);
    }
    onRecordingFinished?.call(path, _recorder.mime, _recordingLabel);
  }

  @override
  bool get isScreenSharing => _screenStream != null;

  @override
  bool get remoteScreenSharing => _remoteScreenSharing;

  void _onCallFrame(SignalTransportFrame frame) {
    final Object? type = frame.payload['type'];
    if (type != kCallScreenSignal && type != kCallRecordingSignal) {
      return;
    }
    final String? remote = _remoteAddress;
    if (remote == null ||
        frame.payload['callId'] != _activeCallId ||
        frame.from.trim().toLowerCase() != remote.trim().toLowerCase()) {
      return;
    }
    if (type == kCallScreenSignal) {
      _remoteScreenSharing = frame.payload['on'] == true;
    } else {
      _remoteRecording = frame.payload['on'] == true;
    }
    _notify();
  }

  void _sendScreenSignal(bool on) => _sendCallSignal(kCallScreenSignal, on);

  void _sendCallSignal(String type, bool on) {
    final String? remote = _remoteAddress;
    final String? callId = _activeCallId;
    if (remote == null || callId == null) {
      return;
    }
    unawaited(
      transport
          .send(
            remoteAddress: remote,
            payload: <String, dynamic>{
              'type': type,
              'callId': callId,
              'on': on,
            },
          )
          .catchError((Object error) {
            logZenWarning('Sending the call notice ($type) failed: $error');
          }),
    );
  }

  static bool get _isDesktop =>
      Platform.isWindows || Platform.isLinux || Platform.isMacOS;

  @override
  Future<List<ScreenShareSource>> listScreenSources() async {
    if (!_isDesktop) {
      return const <ScreenShareSource>[];
    }
    try {
      final List<DesktopCapturerSource> sources = await desktopCapturer
          .getSources(
            types: <SourceType>[SourceType.Screen, SourceType.Window],
            thumbnailSize: ThumbnailSize(320, 180),
          );
      return <ScreenShareSource>[
        for (final DesktopCapturerSource s in sources)
          ScreenShareSource(
            id: s.id,
            name: s.name,
            isWindow: s.type == SourceType.Window,
            thumbnail: s.thumbnail,
          ),
      ];
    } catch (error, stackTrace) {
      logZenError('Listing screens to share failed', error, stackTrace);
      return const <ScreenShareSource>[];
    }
  }

  Future<RTCRtpSender?> _videoSender(RTCPeerConnection connection) async {
    final List<RTCRtpTransceiver> transceivers = await connection
        .getTransceivers();
    for (int i = 0; i < transceivers.length; i++) {
      if (_isVideoTransceiver(transceivers[i], i)) {
        try {
          await transceivers[i].setDirection(TransceiverDirection.SendRecv);
        } catch (error) {
          logZenWarning('Setting video transceiver direction failed: $error');
        }
        return transceivers[i].sender;
      }
    }
    for (final RTCRtpSender sender in await connection.getSenders()) {
      if (sender.track?.kind == 'video') {
        return sender;
      }
    }
    return null;
  }

  @override
  Future<void> startScreenShare({String? sourceId}) async {
    final RTCPeerConnection? connection = _peerConnection;
    final MediaStream? localStream = _localStream;
    if (connection == null || localStream == null) {
      throw StateError('Brak aktywnej rozmowy do udostępnienia ekranu.');
    }
    if (_screenStream != null) {
      return;
    }
    if (Platform.isAndroid) {
      // The system dialog lets the user pick the whole screen or one app
      // (Android 14+). The service must carry the mediaProjection type
      // before capture starts.
      final bool allowed = await Helper.requestCapturePermission();
      if (!allowed) {
        throw StateError('Nie zezwolono na udostępnienie ekranu.');
      }
      androidScreenCaptureActive.value = true;
      await androidPrepareScreenCapture?.call();
    }
    final Map<String, dynamic> constraints = _isDesktop
        ? <String, dynamic>{
            'audio': false,
            'video': <String, dynamic>{
              if (sourceId != null)
                'deviceId': <String, dynamic>{'exact': sourceId},
              'mandatory': <String, dynamic>{'frameRate': 15.0},
            },
          }
        : <String, dynamic>{'audio': false, 'video': true};
    final MediaStream screen;
    try {
      screen = await navigator.mediaDevices.getDisplayMedia(constraints);
    } catch (error) {
      androidScreenCaptureActive.value = false;
      rethrow;
    }
    final List<MediaStreamTrack> tracks = screen.getVideoTracks();
    if (tracks.isEmpty) {
      await _disposeStream(screen);
      androidScreenCaptureActive.value = false;
      throw StateError('Nie udało się przechwycić ekranu.');
    }
    final MediaStreamTrack track = tracks.first;
    // Stopped from the system UI ("Zatrzymaj udostępnianie").
    track.onEnded = () => unawaited(stopScreenShare());
    _screenStream = screen;
    await _ensureRenderers();
    final RTCRtpSender? sender = await _videoSender(connection);
    if (sender != null) {
      try {
        await sender.setStreams(<MediaStream>[localStream]);
      } catch (_) {}
      await sender.replaceTrack(track);
    } else {
      await connection.addTrack(track, localStream);
    }
    _activeKind = CallInviteKind.video;
    await _pinLocalVideoDirection(sending: true);
    _safeSetRendererSrcObject(_localRenderer, screen);
    _sendScreenSignal(true);
    _notify();
    await _renegotiateWhenStable(CallInviteKind.video);
  }

  @override
  Future<void> stopScreenShare() async {
    final MediaStream? screen = _screenStream;
    if (screen == null) {
      return;
    }
    _screenStream = null;
    androidScreenCaptureActive.value = false;
    final RTCPeerConnection? connection = _peerConnection;
    final MediaStream? localStream = _localStream;
    if (connection != null) {
      try {
        final RTCRtpSender? sender = await _videoSender(connection);
        final List<MediaStreamTrack> camera =
            localStream?.getVideoTracks() ?? const <MediaStreamTrack>[];
        if (sender != null) {
          await sender.replaceTrack(
            _localCameraWanted && camera.isNotEmpty ? camera.first : null,
          );
        }
        if (!_localCameraWanted) {
          await _pinLocalVideoDirection(sending: false);
        }
      } catch (error, stackTrace) {
        logZenError(
          'Restoring the camera after sharing failed',
          error,
          stackTrace,
        );
      }
    }
    await _disposeStream(screen);
    _safeSetRendererSrcObject(_localRenderer, localStream);
    _sendScreenSignal(false);
    _notify();
    if (connection != null) {
      await _renegotiateWhenStable(_activeKind ?? CallInviteKind.audio);
    }
  }

  final SignalTransport transport;
  final RTCVideoRenderer _localRenderer = RTCVideoRenderer();
  final RTCVideoRenderer _remoteRenderer = RTCVideoRenderer();

  CallMediaStatusListener? _onStatusChanged;
  CallMediaErrorListener? _onError;

  RTCPeerConnection? _peerConnection;
  MediaStream? _localStream;
  MediaStream? _remoteStream;
  String? _activeCallId;
  String? _remoteAddress;
  CallInviteKind? _activeKind;
  bool _renderersInitialized = false;
  bool _remoteDescriptionSet = false;
  bool _relayCandidateAdded = false;
  final List<({String mid, int mLineIndex})> _relayMids =
      <({String mid, int mLineIndex})>[];
  String? _relaySdpMid;
  String? _localCandidateIp;
  int? _relayPort;
  Completer<void>? _relayMetadataReady;
  Timer? _disconnectGraceTimer;
  RTCPeerConnectionState? _lastConnectionState;
  Map<String, dynamic>? _lastSentOfferDescription;
  Map<String, dynamic>? _lastSentAnswerDescription;

  /// True between sending a local offer and applying the answer to it.
  ///
  /// The callee re-sends its answer until the call connects, and applying a
  /// second one throws — which the error path turns into a hang-up. Tracked
  /// here rather than read off `signalingState`, which the plugin only fills
  /// in once the platform event for it has come back.
  bool _awaitingRemoteAnswer = false;
  bool _disposed = false;
  Future<void>? _closeInFlight;

  /// Whether *this* user asked for a local camera. Remote offers must never
  /// flip this — otherwise the other side could start our camera.
  bool _localCameraWanted = false;
  String? _selectedCameraId;
  String? _selectedMicrophoneId;

  /// Offer we still need to send once the outstanding answer lands.
  ///
  /// `createOffer` while `_awaitingRemoteAnswer` is true throws, and that
  /// used to abort turning the camera on.
  CallInviteKind? _pendingRenegotiationKind;
  String? _lastBoundRemoteVideoTrackId;

  /// Synchronizes [_remoteRenderer] with the remote stream that contains active video.
  ///
  /// In flutter_webrtc, RTCVideoRenderer binds to video tracks at the native
  /// texture level only when srcObject is assigned. Adding a video track to an
  /// existing MediaStream without resetting srcObject will not attach the native
  /// video sink, leaving the remote video invisible. Rebinding srcObject forces
  /// the platform renderer to register the new video track.
  void _safeSetRendererSrcObject(
    RTCVideoRenderer renderer,
    MediaStream? stream,
  ) {
    if (_disposed || !_renderersInitialized) {
      return;
    }
    if (renderer.textureId == null) {
      return;
    }
    try {
      if (stream != null && stream.getVideoTracks().isEmpty) {
        if (renderer.srcObject != null) {
          renderer.srcObject = null;
        }
        return;
      }
      renderer.srcObject = stream;
    } catch (error) {
      logZenWarning('Setting renderer srcObject failed: $error');
    }
  }

  /// Synchronizes [_remoteRenderer] with the remote stream that contains active video.
  ///
  /// In flutter_webrtc, RTCVideoRenderer binds to video tracks at the native
  /// texture level only when srcObject is assigned. Adding a video track to an
  /// existing MediaStream without resetting srcObject will not attach the native
  /// video sink, leaving the remote video invisible. Rebinding srcObject forces
  /// the platform renderer to register the new video track.
  void _syncRemoteRenderer() {
    if (_disposed ||
        !_renderersInitialized ||
        _remoteRenderer.textureId == null) {
      return;
    }
    MediaStream? target = _remoteStream;
    final List<MediaStream?>? streams = _peerConnection?.getRemoteStreams();
    if (streams != null && streams.isNotEmpty) {
      for (final MediaStream? s in streams) {
        if (s != null && s.getVideoTracks().isNotEmpty) {
          target = s;
          _remoteStream = s;
          break;
        }
      }
    }
    if (target != null &&
        target.getVideoTracks().isEmpty &&
        _remoteStream != null &&
        _remoteStream!.getVideoTracks().isNotEmpty) {
      target = _remoteStream;
    }
    final String? currentVideoTrackId =
        target != null && target.getVideoTracks().isNotEmpty
        ? target.getVideoTracks().first.id
        : null;

    if (currentVideoTrackId != null &&
        (!identical(_remoteRenderer.srcObject, target) ||
            currentVideoTrackId != _lastBoundRemoteVideoTrackId)) {
      _lastBoundRemoteVideoTrackId = currentVideoTrackId;
      _safeSetRendererSrcObject(_remoteRenderer, target);
      _notify();
    } else if (currentVideoTrackId == null &&
        _remoteRenderer.srcObject != null) {
      _lastBoundRemoteVideoTrackId = null;
      _safeSetRendererSrcObject(_remoteRenderer, null);
      _notify();
    }
  }

  /// [notifyListeners] after [dispose] throws, and teardown is asynchronous:
  /// the last few notifications of a closing session can easily land after the
  /// controller is gone.
  void _notify() {
    if (_disposed) {
      return;
    }
    notifyListeners();
  }

  @override
  RTCVideoRenderer? get localRenderer =>
      _renderersInitialized && _localRenderer.textureId != null
      ? _localRenderer
      : null;

  @override
  RTCVideoRenderer? get remoteRenderer =>
      _renderersInitialized && _remoteRenderer.textureId != null
      ? _remoteRenderer
      : null;

  @override
  String? get activeCallId => _activeCallId;

  @override
  String? get remoteAddress => _remoteAddress;

  @override
  CallInviteKind? get activeKind => _activeKind;

  @override
  bool get hasLocalStream => _localStream != null;

  @override
  bool get hasRemoteStream => _remoteStream != null;

  @override
  bool get hasLocalVideo =>
      _localStream?.getVideoTracks().any(
        (MediaStreamTrack track) => track.enabled,
      ) ??
      false;

  @override
  bool get hasRemoteVideo {
    if (_remoteStream?.getVideoTracks().any(_isLiveVideoTrack) ?? false) {
      return true;
    }
    final List<MediaStream?>? remoteStreams = _peerConnection
        ?.getRemoteStreams();
    if (remoteStreams != null) {
      for (final MediaStream? stream in remoteStreams) {
        if (stream != null && stream.getVideoTracks().any(_isLiveVideoTrack)) {
          return true;
        }
      }
    }
    if (_remoteRenderer.srcObject?.getVideoTracks().any(_isLiveVideoTrack) ??
        false) {
      return true;
    }
    return false;
  }

  static bool _isLiveVideoTrack(MediaStreamTrack track) {
    return (track.kind == null || track.kind == 'video') && track.enabled;
  }

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
    try {
      _localCameraWanted = kind == CallInviteKind.video;
      await _preparePeerConnection(
        callId: callId,
        remoteAddress: remoteAddress,
        kind: kind,
        captureVideo: _localCameraWanted,
        isIncoming: false,
      );
      await _pinLocalVideoDirection(sending: _localCameraWanted);
      final RTCSessionDescription offer = await _requireConnection()
          .createOffer(_offerConstraints());
      final RTCSessionDescription pinned = await _commitLocalDescription(offer);
      _lastSentOfferDescription = _descriptionToMap(pinned);
      _awaitingRemoteAnswer = true;
      await _sendPayload(
        type: 'offer',
        payload: <String, dynamic>{
          'kind': kind.name,
          'description': _lastSentOfferDescription,
        },
      );
    } catch (error) {
      _emitError(error);
      await close();
      rethrow;
    }
  }

  @override
  Future<void> acceptIncoming({
    required String callId,
    required String remoteAddress,
    required CallInviteKind kind,
    required Map<String, dynamic> remoteDescription,
  }) async {
    try {
      _localCameraWanted = kind == CallInviteKind.video;
      await _preparePeerConnection(
        callId: callId,
        remoteAddress: remoteAddress,
        kind: kind,
        captureVideo: _localCameraWanted,
        isIncoming: true,
      );
      await _setRemoteDescriptionPinned(remoteDescription);
      await _bindLocalTracksToAnswerTransceivers();
      await _pinLocalVideoDirection(sending: _localCameraWanted);
      final RTCSessionDescription answer = await _requireConnection()
          .createAnswer(_offerConstraints());
      final RTCSessionDescription pinned = await _commitLocalDescription(
        answer,
      );
      _lastSentAnswerDescription = _descriptionToMap(pinned);
      await _sendPayload(
        type: 'answer',
        payload: <String, dynamic>{
          'kind': kind.name,
          'description': _lastSentAnswerDescription,
        },
      );
      _syncRemoteRenderer();
      _notify();
    } catch (error) {
      _emitError(error);
      await close();
      rethrow;
    }
  }

  @override
  Future<void> handleRemoteOffer({
    required CallInviteKind kind,
    required Map<String, dynamic> remoteDescription,
  }) async {
    final RTCPeerConnection? connection = _peerConnection;
    if (connection == null) {
      throw StateError('Brak aktywnej sesji do renegocjacji rozmowy.');
    }
    try {
      await _setRemoteDescriptionPinned(remoteDescription);
      await _bindLocalTracksToAnswerTransceivers();
      await _pinLocalVideoDirection(sending: _localCameraWanted);
      final RTCSessionDescription answer = await connection.createAnswer(
        _offerConstraints(),
      );
      final RTCSessionDescription pinned = await _commitLocalDescription(
        answer,
      );
      _activeKind = kind;
      _lastSentAnswerDescription = _descriptionToMap(pinned);
      await _sendPayload(
        type: 'answer',
        payload: <String, dynamic>{
          'kind': kind.name,
          'description': _lastSentAnswerDescription,
        },
      );
      _syncRemoteRenderer();
      _notify();
    } catch (error) {
      _emitError(error);
      rethrow;
    }
  }

  @override
  Future<void> applyRemoteAnswer(Map<String, dynamic> description) async {
    final RTCPeerConnection? connection = _peerConnection;
    if (connection == null) {
      return;
    }
    // The callee re-sends its answer until the call connects, so repeats are
    // expected. An answer only applies to an outstanding local offer; setting
    // a second one throws, and the error path hangs the call up.
    if (!_awaitingRemoteAnswer) {
      return;
    }
    try {
      await _setRemoteDescriptionPinned(description);
      _awaitingRemoteAnswer = false;
      _syncRemoteRenderer();
      _notify();
      final CallInviteKind? pending = _pendingRenegotiationKind;
      _pendingRenegotiationKind = null;
      if (pending != null) {
        await _sendRenegotiationOffer(pending);
      }
    } catch (error) {
      _emitError(error);
      rethrow;
    }
  }

  @override
  Future<void> setMuted(bool muted) async {
    for (final MediaStreamTrack track
        in _localStream?.getAudioTracks() ?? const <MediaStreamTrack>[]) {
      track.enabled = !muted;
    }
    _notify();
  }

  @override
  Future<void> setSpeakerOn(bool enabled) async {
    if (!Platform.isAndroid && !Platform.isIOS) {
      return;
    }
    try {
      await Helper.setSpeakerphoneOn(enabled);
    } catch (error, stackTrace) {
      logZenError('Updating speakerphone state failed', error, stackTrace);
    }
  }

  @override
  Future<void> setCameraEnabled(bool enabled) async {
    final RTCPeerConnection? connection = _peerConnection;
    final MediaStream? localStream = _localStream;
    if (connection == null || localStream == null) {
      throw StateError('Brak aktywnej rozmowy do sterowania kamera.');
    }
    _localCameraWanted = enabled;
    if (!enabled) {
      await _detachLocalVideoTracks();
      await _pinLocalVideoDirection(sending: false);
      _notify();
      await _renegotiateWhenStable(_activeKind ?? CallInviteKind.audio);
      return;
    }
    await _ensureRenderers();
    await _attachLocalVideoTrack(connection, localStream);
    _activeKind = CallInviteKind.video;
    await _pinLocalVideoDirection(sending: true);
    _safeSetRendererSrcObject(_localRenderer, localStream);
    _notify();
    await _renegotiateWhenStable(CallInviteKind.video);
  }

  @override
  Future<List<CallMediaDevice>> listMediaDevices() async {
    try {
      final List<MediaDeviceInfo> raw = await navigator.mediaDevices
          .enumerateDevices();
      final bool isMobile = Platform.isAndroid || Platform.isIOS;
      return catalogCallMediaDevices(
        raw: raw.map(
          (MediaDeviceInfo info) => RawCallMediaDevice(
            id: info.deviceId,
            label: info.label,
            kind: info.kind ?? '',
          ),
        ),
        includeMobileAudioOutputs: isMobile,
        filterMobileCameras: isMobile,
      );
    } catch (error, stackTrace) {
      logZenError('Listing call media devices failed', error, stackTrace);
      if (Platform.isAndroid || Platform.isIOS) {
        return catalogCallMediaDevices(
          raw: const <RawCallMediaDevice>[],
          includeMobileAudioOutputs: true,
          filterMobileCameras: true,
        );
      }
      return const <CallMediaDevice>[];
    }
  }

  @override
  Future<void> selectMediaDevice(CallMediaDevice device) async {
    switch (device.kind) {
      case CallMediaDeviceKind.camera:
        final bool sameCamera =
            _selectedCameraId != null &&
            _selectedCameraId == (device.id.isEmpty ? null : device.id);
        _selectedCameraId = device.id.isEmpty ? null : device.id;
        if (_localStream != null && _localCameraWanted) {
          final List<MediaStreamTrack> tracks =
              _localStream?.getVideoTracks() ?? const <MediaStreamTrack>[];
          if (sameCamera && tracks.isNotEmpty) {
            return;
          }
          try {
            await _detachLocalVideoTracks();
            if (Platform.isAndroid || Platform.isIOS) {
              await Future<void>.delayed(const Duration(milliseconds: 150));
            }
            final RTCPeerConnection? connection = _peerConnection;
            final MediaStream? localStream = _localStream;
            if (connection != null && localStream != null) {
              await _attachLocalVideoTrack(connection, localStream);
              _localRenderer.srcObject = localStream;
              _notify();
            }
          } catch (error, stackTrace) {
            logZenError('Switching camera device failed', error, stackTrace);
          }
        }
        return;
      case CallMediaDeviceKind.microphone:
        _selectedMicrophoneId = device.id.isEmpty ? null : device.id;
        await _replaceAudioInput(_selectedMicrophoneId);
        return;
      case CallMediaDeviceKind.speaker:
        final String label = device.label.toLowerCase();
        final bool speaker =
            device.id == 'speakerphone' ||
            label.contains('speaker') ||
            label.contains('głośnik') ||
            label.contains('glosnik');
        await setSpeakerOn(speaker);
        try {
          await Helper.selectAudioOutput(device.id);
        } catch (error, stackTrace) {
          logZenError('Selecting audio output failed', error, stackTrace);
        }
        return;
    }
  }

  @override
  Future<void> switchCamera() async {
    final List<MediaStreamTrack> tracks =
        _localStream?.getVideoTracks() ?? const <MediaStreamTrack>[];
    if (tracks.isEmpty || !_localCameraWanted) {
      return;
    }
    // Deterministically flip between front ('1') and back ('0')
    if (_selectedCameraId == '0') {
      _selectedCameraId = '1';
    } else {
      _selectedCameraId = '0';
    }
    try {
      await _detachLocalVideoTracks();
      if (Platform.isAndroid || Platform.isIOS) {
        await Future<void>.delayed(const Duration(milliseconds: 150));
      }
      final RTCPeerConnection? connection = _peerConnection;
      final MediaStream? localStream = _localStream;
      if (connection != null && localStream != null) {
        await _attachLocalVideoTrack(connection, localStream);
        _localRenderer.srcObject = localStream;
        _notify();
      }
    } catch (error, stackTrace) {
      logZenError('Switching camera failed', error, stackTrace);
    }
  }

  Future<void> _replaceAudioInput(String? deviceId) async {
    final RTCPeerConnection? connection = _peerConnection;
    final MediaStream? localStream = _localStream;
    if (connection == null || localStream == null) {
      return;
    }
    final MediaStream next = await navigator.mediaDevices
        .getUserMedia(<String, dynamic>{
          'audio': _buildAudioConstraints(
            deviceId: deviceId != null && deviceId.isNotEmpty ? deviceId : null,
          ),
          'video': false,
        });
    final List<MediaStreamTrack> fresh = next.getAudioTracks();
    if (fresh.isEmpty) {
      await _disposeStream(next);
      return;
    }
    for (final MediaStreamTrack old in List<MediaStreamTrack>.from(
      localStream.getAudioTracks(),
    )) {
      await localStream.removeTrack(old);
      await old.stop();
      try {
        final List<RTCRtpSender> senders = await connection.getSenders();
        for (final RTCRtpSender sender in senders) {
          if (sender.track?.kind == 'audio') {
            await sender.replaceTrack(fresh.first);
          }
        }
      } catch (error, stackTrace) {
        logZenError('Replacing the audio sender failed', error, stackTrace);
      }
    }
    await localStream.addTrack(fresh.first);
    _notify();
  }

  bool _isVideoTransceiver(RTCRtpTransceiver transceiver, [int? index]) {
    if (transceiver.sender.track?.kind == 'video' ||
        transceiver.receiver.track?.kind == 'video') {
      return true;
    }
    if (transceiver.mid == '1') {
      return true;
    }
    if (index != null && index == 1) {
      return true;
    }
    return false;
  }

  Future<void> _attachLocalVideoTrack(
    RTCPeerConnection connection,
    MediaStream localStream,
  ) async {
    final List<MediaStreamTrack> existing = localStream.getVideoTracks();
    if (existing.isNotEmpty) {
      for (final MediaStreamTrack track in existing) {
        track.enabled = true;
      }
      return;
    }
    MediaStream? cameraStream;
    try {
      cameraStream = await navigator.mediaDevices
          .getUserMedia(<String, dynamic>{
            'audio': false,
            'video': _buildVideoConstraints(deviceId: _selectedCameraId),
          });
    } catch (error) {
      logZenWarning(
        'Primary camera constraints failed ($error), trying unconstrained video',
      );
      try {
        cameraStream = await navigator.mediaDevices.getUserMedia(
          <String, dynamic>{'audio': false, 'video': true},
        );
      } catch (fallbackError, fallbackStackTrace) {
        logZenError(
          'Unconstrained camera capture failed',
          fallbackError,
          fallbackStackTrace,
        );
        _localCameraWanted = false;
        return;
      }
    }
    final List<MediaStreamTrack> freshTracks = cameraStream.getVideoTracks();
    if (freshTracks.isEmpty) {
      _localCameraWanted = false;
      await _disposeStream(cameraStream);
      return;
    }
    final MediaStreamTrack fresh = freshTracks.first;
    await localStream.addTrack(fresh);
    RTCRtpSender? videoSender;
    try {
      final List<RTCRtpTransceiver> transceivers = await connection
          .getTransceivers();
      for (int i = 0; i < transceivers.length; i++) {
        final RTCRtpTransceiver transceiver = transceivers[i];
        if (_isVideoTransceiver(transceiver, i)) {
          videoSender = transceiver.sender;
          try {
            await transceiver.setDirection(TransceiverDirection.SendRecv);
          } catch (error) {
            logZenWarning('Setting video transceiver direction failed: $error');
          }
          break;
        }
      }
      if (videoSender == null) {
        final List<RTCRtpSender> senders = await connection.getSenders();
        for (final RTCRtpSender sender in senders) {
          if (sender.track?.kind == 'video') {
            videoSender = sender;
            break;
          }
        }
      }
    } catch (error, stackTrace) {
      logZenError('Reading RTP senders failed', error, stackTrace);
    }
    if (videoSender != null) {
      try {
        await videoSender.setStreams(<MediaStream>[localStream]);
      } catch (_) {}
      try {
        await videoSender.replaceTrack(fresh);
      } catch (error, stackTrace) {
        logZenError('Replacing the video sender failed', error, stackTrace);
        await connection.addTrack(fresh, localStream);
      }
    } else {
      await connection.addTrack(fresh, localStream);
    }
    _safeSetRendererSrcObject(_localRenderer, localStream);
    _notify();
  }

  Future<void> _detachLocalVideoTracks() async {
    final RTCPeerConnection? connection = _peerConnection;
    final MediaStream? localStream = _localStream;
    if (localStream == null) {
      return;
    }
    final List<MediaStreamTrack> videoTracks = List<MediaStreamTrack>.from(
      localStream.getVideoTracks(),
    );
    for (final MediaStreamTrack track in videoTracks) {
      track.enabled = false;
      try {
        await localStream.removeTrack(track);
        await track.stop();
      } catch (error, stackTrace) {
        logZenError('Stopping a local video track failed', error, stackTrace);
      }
    }
    if (connection != null) {
      try {
        final List<RTCRtpSender> senders = await connection.getSenders();
        for (final RTCRtpSender sender in senders) {
          if (sender.track?.kind == 'video') {
            try {
              await sender.replaceTrack(null);
            } catch (error, stackTrace) {
              logZenError(
                'Clearing the video sender failed',
                error,
                stackTrace,
              );
            }
          }
        }
      } catch (error, stackTrace) {
        logZenError('Reading RTP senders failed', error, stackTrace);
      }
    }
    _safeSetRendererSrcObject(_localRenderer, localStream);
    _notify();
  }

  Future<void> _pinLocalVideoDirection({required bool sending}) async {
    final RTCPeerConnection? connection = _peerConnection;
    if (connection == null) {
      return;
    }
    try {
      final List<RTCRtpTransceiver> transceivers = await connection
          .getTransceivers();
      for (int i = 0; i < transceivers.length; i++) {
        final RTCRtpTransceiver transceiver = transceivers[i];
        if (!_isVideoTransceiver(transceiver, i)) {
          continue;
        }
        await transceiver.setDirection(
          sending
              ? TransceiverDirection.SendRecv
              : TransceiverDirection.RecvOnly,
        );
      }
    } catch (error, stackTrace) {
      logZenError('Pinning local video direction failed', error, stackTrace);
    }
  }

  Future<void> _bindLocalTracksToAnswerTransceivers() async {
    final RTCPeerConnection? connection = _peerConnection;
    final MediaStream? localStream = _localStream;
    if (connection == null || localStream == null) {
      return;
    }
    final List<MediaStreamTrack> audioTracks = localStream.getAudioTracks();
    final List<MediaStreamTrack> videoTracks = localStream.getVideoTracks();

    bool audioBound = false;
    bool videoBound = false;

    try {
      final List<RTCRtpTransceiver> transceivers = await connection
          .getTransceivers();
      for (int i = 0; i < transceivers.length; i++) {
        final RTCRtpTransceiver transceiver = transceivers[i];
        if (_isVideoTransceiver(transceiver, i)) {
          if (_localCameraWanted && videoTracks.isNotEmpty) {
            try {
              await transceiver.sender.setStreams(<MediaStream>[localStream]);
            } catch (error) {
              logZenWarning('Setting video sender stream failed: $error');
            }
            try {
              await transceiver.sender.replaceTrack(videoTracks.first);
              videoBound = true;
            } catch (error) {
              logZenWarning(
                'Binding video track to answer transceiver failed: $error',
              );
            }
            try {
              await transceiver.setDirection(TransceiverDirection.SendRecv);
            } catch (error) {
              logZenWarning(
                'Setting video transceiver direction to SendRecv failed: $error',
              );
            }
          } else {
            try {
              await transceiver.setDirection(TransceiverDirection.RecvOnly);
            } catch (error) {
              logZenWarning(
                'Setting video transceiver direction to RecvOnly failed: $error',
              );
            }
          }
        } else {
          // Audio transceiver
          if (audioTracks.isNotEmpty) {
            try {
              await transceiver.sender.setStreams(<MediaStream>[localStream]);
            } catch (error) {
              logZenWarning('Setting audio sender stream failed: $error');
            }
            try {
              await transceiver.sender.replaceTrack(audioTracks.first);
              audioBound = true;
            } catch (error) {
              logZenWarning(
                'Binding audio track to answer transceiver failed: $error',
              );
            }
            try {
              await transceiver.setDirection(TransceiverDirection.SendRecv);
            } catch (error) {
              logZenWarning(
                'Setting audio transceiver direction to SendRecv failed: $error',
              );
            }
          }
        }
      }
    } catch (error, stackTrace) {
      logZenError('Binding transceivers on answer failed', error, stackTrace);
    }

    if (!audioBound && audioTracks.isNotEmpty) {
      try {
        await connection.addTrack(audioTracks.first, localStream);
      } catch (error) {
        logZenWarning('Fallback addTrack for audio failed: $error');
      }
    }
    if (!videoBound && _localCameraWanted && videoTracks.isNotEmpty) {
      try {
        await connection.addTrack(videoTracks.first, localStream);
      } catch (error) {
        logZenWarning('Fallback addTrack for video failed: $error');
      }
    }
  }

  Future<void> _renegotiateWhenStable(CallInviteKind kind) async {
    if (_awaitingRemoteAnswer) {
      _pendingRenegotiationKind = kind;
      return;
    }
    await _sendRenegotiationOffer(kind);
  }

  RTCPeerConnection _requireConnection() {
    final RTCPeerConnection? connection = _peerConnection;
    if (connection == null) {
      throw StateError('Rozmowa została zamknięta w trakcie zestawiania.');
    }
    return connection;
  }

  Future<void> _preparePeerConnection({
    required String callId,
    required String remoteAddress,
    required CallInviteKind kind,
    required bool captureVideo,
    bool isIncoming = false,
  }) async {
    await close();
    if (_disposed) {
      throw StateError('Kontroler rozmowy został już zamknięty.');
    }
    _activeCallId = callId;
    _remoteAddress = remoteAddress;
    _activeKind = kind;
    _localCameraWanted = captureVideo;
    _remoteDescriptionSet = false;
    _awaitingRemoteAnswer = false;
    _relayCandidateAdded = false;
    _relayMids.clear();
    _relaySdpMid = null;
    _localCandidateIp = null;
    _lastConnectionState = null;
    if (captureVideo || kind == CallInviteKind.video) {
      await _ensureRenderers();
    }

    _relayPort = await transport.openRelay(
      callId: callId,
      remoteAddress: remoteAddress,
    );
    if ((_relayPort ?? 0) <= 0) {
      throw StateError('Nie udało się uruchomić lokalnego relay dla rozmowy.');
    }

    final RTCPeerConnection connection = await createPeerConnection(
      _configuration,
      _peerConstraints,
    );
    if (_disposed) {
      // Torn down while the platform was building the connection.
      try {
        await connection.close();
        await connection.dispose();
      } catch (error, stackTrace) {
        logZenError(
          'Closing an orphaned peer connection failed',
          error,
          stackTrace,
        );
      }
      throw StateError('Kontroler rozmowy został już zamknięty.');
    }
    _peerConnection = connection;
    _relayMetadataReady = Completer<void>();
    connection.onIceCandidate = (RTCIceCandidate candidate) {
      final String? candidateValue = candidate.candidate;
      if (candidateValue == null || candidateValue.isEmpty) {
        return;
      }
      _relaySdpMid ??= candidate.sdpMid;
      if (_localCandidateIp == null) {
        final RegExpMatch? match = _hostCandidatePattern.firstMatch(
          candidateValue,
        );
        if (match != null) {
          _localCandidateIp = match.group(1);
        }
      }
      _completeRelayMetadataIfReady();
      if (_remoteDescriptionSet) {
        unawaited(_ensureRelayCandidate());
      }
    };
    connection.onAddTrack = (MediaStream stream, MediaStreamTrack track) async {
      if (_disposed || _peerConnection != connection) {
        return;
      }
      if (track.kind == 'video') {
        await _ensureRenderers();
      }
      track.onMute = () {
        _syncRemoteRenderer();
        _notify();
      };
      track.onUnMute = () {
        _syncRemoteRenderer();
        _notify();
      };
      track.onEnded = () {
        _syncRemoteRenderer();
        _notify();
      };
      if (track.kind == 'video' &&
          !stream.getVideoTracks().any(
            (MediaStreamTrack t) => t.id == track.id,
          )) {
        try {
          await stream.addTrack(track, addToNative: true);
        } catch (_) {
          await stream.addTrack(track, addToNative: false);
        }
      } else if (track.kind == 'audio' &&
          !stream.getAudioTracks().any(
            (MediaStreamTrack t) => t.id == track.id,
          )) {
        try {
          await stream.addTrack(track, addToNative: true);
        } catch (_) {
          await stream.addTrack(track, addToNative: false);
        }
      }
      if (track.kind == 'video' || _remoteStream == null) {
        _remoteStream = stream;
      }
      _syncRemoteRenderer();
      _notify();
    };
    connection.onTrack = (RTCTrackEvent event) async {
      if (_disposed || _peerConnection != connection) {
        return;
      }
      final MediaStreamTrack track = event.track;
      if (track.kind == 'video') {
        await _ensureRenderers();
      }
      track.onMute = () {
        _syncRemoteRenderer();
        _notify();
      };
      track.onUnMute = () {
        _syncRemoteRenderer();
        _notify();
      };
      track.onEnded = () {
        _syncRemoteRenderer();
        _notify();
      };

      MediaStream? stream = event.streams.isNotEmpty
          ? event.streams.first
          : null;
      if (stream == null) {
        final List<MediaStream?> remoteStreams = connection.getRemoteStreams();
        for (final MediaStream? s in remoteStreams) {
          if (s == null) {
            continue;
          }
          if (track.kind == 'video' && s.getVideoTracks().isNotEmpty) {
            stream = s;
            break;
          } else if (track.kind == 'audio' && s.getAudioTracks().isNotEmpty) {
            stream = s;
            break;
          }
        }
        if (stream == null) {
          for (final MediaStream? s in remoteStreams) {
            if (s != null) {
              stream = s;
              break;
            }
          }
        }
        if (stream == null && _remoteStream != null) {
          stream = _remoteStream;
        }
      }

      if (stream == null) {
        try {
          stream = await createLocalMediaStream('remote_stream_${track.id}');
        } catch (e) {
          logZenWarning('Failed to create fallback remote MediaStream: $e');
        }
      }

      if (stream != null) {
        if (track.kind == 'video' &&
            !stream.getVideoTracks().any(
              (MediaStreamTrack t) => t.id == track.id,
            )) {
          try {
            await stream.addTrack(track, addToNative: true);
          } catch (_) {
            await stream.addTrack(track, addToNative: false);
          }
        } else if (track.kind == 'audio' &&
            !stream.getAudioTracks().any(
              (MediaStreamTrack t) => t.id == track.id,
            )) {
          try {
            await stream.addTrack(track, addToNative: true);
          } catch (_) {
            await stream.addTrack(track, addToNative: false);
          }
        }
        if (track.kind == 'video' || _remoteStream == null) {
          _remoteStream = stream;
        }
      }

      _syncRemoteRenderer();
      _notify();
    };
    connection.onAddStream = (MediaStream stream) {
      if (_disposed) {
        return;
      }
      if (stream.getVideoTracks().isNotEmpty || _remoteStream == null) {
        _remoteStream = stream;
      }
      _syncRemoteRenderer();
      _notify();
    };
    connection.onRemoveStream = (MediaStream stream) {
      if (_disposed) {
        return;
      }
      if (_remoteStream == stream) {
        _remoteStream = null;
      }
      _syncRemoteRenderer();
      _notify();
    };

    connection.onConnectionState = (RTCPeerConnectionState state) {
      if (_disposed) {
        return;
      }
      _lastConnectionState = state;
      final String? activeCallId = _activeCallId;
      if (activeCallId == null) {
        return;
      }
      switch (state) {
        case RTCPeerConnectionState.RTCPeerConnectionStateConnected:
          _disconnectGraceTimer?.cancel();
          _disconnectGraceTimer = null;
          _onStatusChanged?.call(
            activeCallId,
            CallMediaSessionLifecycle.active,
          );
          return;
        case RTCPeerConnectionState.RTCPeerConnectionStateDisconnected:
          _disconnectGraceTimer?.cancel();
          _disconnectGraceTimer = Timer(const Duration(seconds: 3), () {
            if (_activeCallId != activeCallId) {
              return;
            }
            if (_lastConnectionState ==
                    RTCPeerConnectionState.RTCPeerConnectionStateDisconnected ||
                _lastConnectionState ==
                    RTCPeerConnectionState.RTCPeerConnectionStateFailed ||
                _lastConnectionState ==
                    RTCPeerConnectionState.RTCPeerConnectionStateClosed) {
              _onStatusChanged?.call(
                activeCallId,
                CallMediaSessionLifecycle.ended,
              );
            }
          });
          _onStatusChanged?.call(
            activeCallId,
            CallMediaSessionLifecycle.connecting,
          );
          return;
        case RTCPeerConnectionState.RTCPeerConnectionStateFailed:
        case RTCPeerConnectionState.RTCPeerConnectionStateClosed:
          _disconnectGraceTimer?.cancel();
          _disconnectGraceTimer = null;
          _onStatusChanged?.call(activeCallId, CallMediaSessionLifecycle.ended);
          return;
        case RTCPeerConnectionState.RTCPeerConnectionStateConnecting:
        case RTCPeerConnectionState.RTCPeerConnectionStateNew:
          _disconnectGraceTimer?.cancel();
          _disconnectGraceTimer = null;
          _onStatusChanged?.call(
            activeCallId,
            CallMediaSessionLifecycle.connecting,
          );
          return;
      }
    };

    final MediaStream localStream = await _getLocalStream(
      captureVideo: captureVideo,
      audioDeviceId: _selectedMicrophoneId,
      videoDeviceId: _selectedCameraId,
    );
    if (_disposed || _peerConnection == null) {
      // The call was torn down while the capture prompt was up; releasing the
      // camera/microphone here is the only chance we get.
      await _disposeStream(localStream);
      throw StateError('Rozmowa została zamknięta w trakcie zestawiania.');
    }
    _localStream = localStream;
    _safeSetRendererSrcObject(_localRenderer, localStream);
    _notify();
    if (!isIncoming) {
      for (final MediaStreamTrack track in localStream.getAudioTracks()) {
        try {
          await connection.addTrack(track, localStream);
        } catch (error) {
          logZenWarning('Adding audio track failed: $error');
        }
      }
      final List<MediaStreamTrack> videoTracks = localStream.getVideoTracks();
      if (videoTracks.isNotEmpty) {
        for (final MediaStreamTrack track in videoTracks) {
          try {
            await connection.addTrack(track, localStream);
          } catch (error) {
            logZenWarning('Adding video track failed: $error');
          }
        }
      } else {
        try {
          await connection.addTransceiver(
            kind: RTCRtpMediaType.RTCRtpMediaTypeVideo,
            init: RTCRtpTransceiverInit(
              direction: TransceiverDirection.RecvOnly,
            ),
          );
        } catch (error) {
          logZenWarning('Pre-provisioning video transceiver failed: $error');
        }
      }
    }
    if (Platform.isAndroid || Platform.isIOS) {
      await setSpeakerOn(kind == CallInviteKind.video);
    }
  }

  Future<MediaStream> _getLocalStream({
    required bool captureVideo,
    String? audioDeviceId,
    String? videoDeviceId,
  }) async {
    final Map<String, dynamic> mediaConstraints = <String, dynamic>{
      'audio': _buildAudioConstraints(deviceId: audioDeviceId),
      'video': captureVideo
          ? _buildVideoConstraints(deviceId: videoDeviceId)
          : false,
    };
    try {
      return await navigator.mediaDevices.getUserMedia(mediaConstraints);
    } catch (error, stackTrace) {
      logZenError('Opening local media stream failed', error, stackTrace);
      try {
        logZenWarning(
          'Retrying getUserMedia with basic unconstrained settings',
        );
        return await navigator.mediaDevices.getUserMedia(<String, dynamic>{
          'audio': true,
          'video': captureVideo,
        });
      } catch (fallbackError) {
        logZenWarning('Basic unconstrained capture failed: $fallbackError');
      }
      if (!captureVideo) {
        rethrow;
      }
      try {
        return await navigator.mediaDevices.getUserMedia(<String, dynamic>{
          'audio': _buildAudioConstraints(deviceId: audioDeviceId),
          'video': true,
        });
      } catch (fallbackError) {
        logZenWarning(
          'Fallback video capture failed: $fallbackError; falling back to audio only',
        );
        _localCameraWanted = false;
        try {
          return await navigator.mediaDevices.getUserMedia(<String, dynamic>{
            'audio': _buildAudioConstraints(deviceId: audioDeviceId),
            'video': false,
          });
        } catch (audioOnlyError) {
          logZenWarning(
            'Fallback audio-only constrained capture failed: $audioOnlyError, trying plain audio',
          );
          return navigator.mediaDevices.getUserMedia(<String, dynamic>{
            'audio': true,
            'video': false,
          });
        }
      }
    }
  }

  Future<void> _ensureRenderers() async {
    if (_renderersInitialized || _disposed) {
      return;
    }
    try {
      await _localRenderer.initialize();
      await _remoteRenderer.initialize();
      _renderersInitialized = true;
      _syncRemoteRenderer();
    } catch (error, stackTrace) {
      logZenError('Initializing renderers failed', error, stackTrace);
    }
  }

  /// Stops and releases [stream], never throwing: teardown runs on paths that
  /// are already handling a failure.
  Future<void> _disposeStream(MediaStream? stream) async {
    if (stream == null) {
      return;
    }
    for (final MediaStreamTrack track in List<MediaStreamTrack>.from(
      stream.getTracks(),
    )) {
      try {
        await track.stop();
      } catch (_) {
        // Ignored: track may have already stopped.
      }
    }
    try {
      await stream.dispose();
    } catch (_) {
      // Ignored: native stream may have already been cleaned up by peer connection teardown.
    }
  }

  void _completeRelayMetadataIfReady() {
    final Completer<void>? metadataReady = _relayMetadataReady;
    if (_relaySdpMid != null &&
        _relaySdpMid!.isNotEmpty &&
        metadataReady != null &&
        !metadataReady.isCompleted) {
      metadataReady.complete();
    }
  }

  void _captureRelayMetadata(String? sdp) {
    if (sdp == null || sdp.isEmpty) {
      return;
    }
    int mediaIndex = -1;
    for (final String rawLine in sdp.split(RegExp(r'\r?\n'))) {
      final String line = rawLine.trim();
      if (line.startsWith('m=')) {
        mediaIndex += 1;
        continue;
      }
      if (mediaIndex >= 0 && line.startsWith('a=mid:')) {
        final String mid = line.substring('a=mid:'.length).trim();
        if (mid.isNotEmpty &&
            !_relayMids.any(
              (({int mLineIndex, String mid}) m) => m.mid == mid,
            )) {
          _relayMids.add((mid: mid, mLineIndex: mediaIndex));
        }
      }
    }
    if (_relayMids.isNotEmpty) {
      _relaySdpMid = _relayMids.first.mid;
      _completeRelayMetadataIfReady();
    }
  }

  Future<void> _waitForRelayMetadata() async {
    final Completer<void>? metadataReady = _relayMetadataReady;
    if (metadataReady == null ||
        metadataReady.isCompleted ||
        (_relaySdpMid?.isNotEmpty ?? false)) {
      return;
    }
    try {
      await metadataReady.future.timeout(
        Platform.isWindows
            ? const Duration(milliseconds: 300)
            : const Duration(milliseconds: 600),
      );
    } on TimeoutException {
      return;
    }
  }

  Future<void> _ensureRelayCandidate() async {
    final RTCPeerConnection? connection = _peerConnection;
    if (connection == null ||
        !_remoteDescriptionSet ||
        _relayCandidateAdded ||
        _relayPort == null ||
        _relayMids.isEmpty) {
      return;
    }
    final Set<String> hosts = <String>{
      '127.0.0.1',
      if (_localCandidateIp != null && _localCandidateIp!.isNotEmpty)
        _localCandidateIp!,
    };
    for (final ({int mLineIndex, String mid}) entry in _relayMids) {
      for (final String host in hosts) {
        // Hanging up mid-negotiation drops the connection between two awaits.
        if (!identical(_peerConnection, connection)) {
          return;
        }
        try {
          await connection.addCandidate(
            RTCIceCandidate(
              'candidate:relay 1 udp 2130706431 $host $_relayPort typ host generation 0',
              entry.mid,
              entry.mLineIndex,
            ),
          );
        } catch (error, stackTrace) {
          logZenError(
            'Adding relay ICE candidate for mid ${entry.mid} failed',
            error,
            stackTrace,
          );
        }
      }
    }
    _relayCandidateAdded = true;
  }

  Future<void> _sendRenegotiationOffer(CallInviteKind kind) async {
    final RTCPeerConnection? connection = _peerConnection;
    if (connection == null) {
      throw StateError('Brak aktywnej rozmowy do renegocjacji.');
    }
    await _pinLocalVideoDirection(sending: _localCameraWanted);
    final RTCSessionDescription offer = await connection.createOffer(
      _offerConstraints(),
    );
    final RTCSessionDescription pinned = await _commitLocalDescription(offer);
    _lastSentOfferDescription = _descriptionToMap(pinned);
    _awaitingRemoteAnswer = true;
    await _sendPayload(
      type: 'offer',
      payload: <String, dynamic>{
        'kind': kind.name,
        'description': _lastSentOfferDescription,
      },
    );
  }

  @override
  Future<bool> resendLocalOffer(String callId) async {
    final Map<String, dynamic>? description = _lastSentOfferDescription;
    final CallInviteKind? kind = _activeKind;
    if (_activeCallId != callId || description == null || kind == null) {
      return false;
    }
    await _sendPayload(
      type: 'offer',
      payload: <String, dynamic>{'kind': kind.name, 'description': description},
    );
    return true;
  }

  @override
  Future<bool> resendLocalAnswer(String callId) async {
    final Map<String, dynamic>? description = _lastSentAnswerDescription;
    final CallInviteKind? kind = _activeKind;
    if (_activeCallId != callId || description == null || kind == null) {
      return false;
    }
    await _sendPayload(
      type: 'answer',
      payload: <String, dynamic>{'kind': kind.name, 'description': description},
    );
    return true;
  }

  Future<void> _sendPayload({
    required String type,
    required Map<String, dynamic> payload,
  }) async {
    final String? remoteAddress = _remoteAddress;
    final String? callId = _activeCallId;
    if (remoteAddress == null || callId == null) {
      throw StateError('Brak aktywnej sesji do wysłania sygnału rozmowy.');
    }
    await transport.send(
      remoteAddress: remoteAddress,
      payload: <String, dynamic>{'type': type, 'callId': callId, ...payload},
    );
  }

  Future<RTCSessionDescription> _commitLocalDescription(
    RTCSessionDescription original,
  ) async {
    final RTCPeerConnection? connection = _peerConnection;
    if (connection == null) {
      return original;
    }
    RTCSessionDescription desc = original;
    if (_localCameraWanted) {
      desc = _ensureVideoSendRecv(desc);
    }
    await connection.setLocalDescription(desc);
    _captureRelayMetadata(desc.sdp);
    return desc;
  }

  RTCSessionDescription _ensureVideoSendRecv(
    RTCSessionDescription description,
  ) {
    final String sdp = description.sdp ?? '';
    if (sdp.isEmpty) {
      return description;
    }
    final String separator = sdp.contains('\r\n') ? '\r\n' : '\n';
    final List<String> lines = sdp.split(RegExp(r'\r?\n'));
    final List<String> result = <String>[];
    bool inVideo = false;
    bool foundDirection = false;

    for (int i = 0; i < lines.length; i++) {
      final String raw = lines[i];
      final String line = raw.trim();
      if (line.startsWith('m=')) {
        if (inVideo && !foundDirection) {
          result.add('a=sendrecv');
        }
        inVideo = line.startsWith('m=video');
        foundDirection = false;
        result.add(raw);
        continue;
      }
      if (inVideo) {
        if (line == 'a=recvonly' ||
            line == 'a=sendonly' ||
            line == 'a=inactive' ||
            line == 'a=sendrecv') {
          result.add('a=sendrecv');
          foundDirection = true;
          continue;
        }
      }
      result.add(raw);
    }
    if (inVideo && !foundDirection) {
      result.add('a=sendrecv');
    }
    return RTCSessionDescription(result.join(separator), description.type);
  }

  Future<void> _setRemoteDescriptionPinned(
    Map<String, dynamic> description,
  ) async {
    final RTCPeerConnection? connection = _peerConnection;
    if (connection == null) {
      throw StateError('Brak aktywnej sesji WebRTC.');
    }
    final RTCSessionDescription original = _descriptionFromMap(description);
    final RTCSessionDescription pinned = _pinDescription(original);
    try {
      await connection.setRemoteDescription(pinned);
    } catch (error, stackTrace) {
      logZenError(
        'Pinned remote description rejected, falling back',
        error,
        stackTrace,
      );
      await connection.setRemoteDescription(original);
    }
    _remoteDescriptionSet = true;
    await _waitForRelayMetadata();
    await _ensureRelayCandidate();
  }

  RTCSessionDescription _pinDescription(RTCSessionDescription description) {
    final int port = _relayPort ?? 0;
    final String sdp = description.sdp ?? '';
    if (port <= 0 || sdp.isEmpty) {
      return description;
    }
    return RTCSessionDescription(
      pinWebRtcSdpToLocalRelay(sdp, port),
      description.type,
    );
  }

  Map<String, dynamic> _descriptionToMap(RTCSessionDescription description) {
    return <String, dynamic>{'sdp': description.sdp, 'type': description.type};
  }

  RTCSessionDescription _descriptionFromMap(Map<String, dynamic> description) {
    return RTCSessionDescription(
      description['sdp'] as String? ?? '',
      description['type'] as String? ?? 'offer',
    );
  }

  void _emitError(Object error) {
    _onError?.call(_activeCallId, error);
  }

  /// Serialised so two teardowns cannot race.
  ///
  /// Both peers of a failing call hang up at once (the error handler, the
  /// rollback in `sendCallInvite`, the peer's own `hangup`), and each entered
  /// this unguarded — the second one then stopped and disposed streams the
  /// first had already released, which crashes in the platform code.
  @override
  Future<void> close() async {
    final Future<void>? inFlight = _closeInFlight;
    if (inFlight != null) {
      await inFlight;
      return;
    }
    final Completer<void> completer = Completer<void>();
    _closeInFlight = completer.future;
    try {
      await _closeInternal();
    } finally {
      _closeInFlight = null;
      completer.complete();
    }
  }

  Future<void> _closeInternal() async {
    // The call ends: a recording still running is finished and kept.
    await _finishRecording(tell: false);
    _remoteRecording = false;
    final MediaStream? screen = _screenStream;
    _screenStream = null;
    _remoteScreenSharing = false;
    androidScreenCaptureActive.value = false;
    await _disposeStream(screen);
    _disconnectGraceTimer?.cancel();
    _disconnectGraceTimer = null;
    final RTCPeerConnection? connection = _peerConnection;
    final String? callId = _activeCallId;
    _peerConnection = null;
    _activeCallId = null;
    _remoteAddress = null;
    _remoteDescriptionSet = false;
    _relayCandidateAdded = false;
    _relayMids.clear();
    _relaySdpMid = null;
    _localCandidateIp = null;
    _relayMetadataReady = null;
    _relayPort = null;
    _lastConnectionState = null;
    _lastSentOfferDescription = null;
    _lastSentAnswerDescription = null;
    _awaitingRemoteAnswer = false;
    _activeKind = null;
    _localCameraWanted = false;
    _pendingRenegotiationKind = null;
    _lastBoundRemoteVideoTrackId = null;
    try {
      connection?.onIceCandidate = null;
      connection?.onTrack = null;
      connection?.onAddTrack = null;
      connection?.onAddStream = null;
      connection?.onRemoveStream = null;
      connection?.onConnectionState = null;
    } catch (error, stackTrace) {
      logZenError(
        'Detaching peer connection callbacks failed',
        error,
        stackTrace,
      );
    }
    // Detach before releasing, so nothing can reach a half-torn-down stream.
    final MediaStream? localStream = _localStream;
    final MediaStream? remoteStream = _remoteStream;
    _localStream = null;
    _remoteStream = null;
    if (_renderersInitialized) {
      _safeSetRendererSrcObject(_localRenderer, null);
      _safeSetRendererSrcObject(_remoteRenderer, null);
    }
    await _disposeStream(localStream);
    await _disposeStream(remoteStream);
    _notify();
    try {
      await connection?.close();
      await connection?.dispose();
    } catch (error, stackTrace) {
      logZenError('Closing peer connection failed', error, stackTrace);
    }
    if (callId != null) {
      try {
        await transport.closeRelay(callId);
      } catch (error, stackTrace) {
        logZenError('Closing call relay failed', error, stackTrace);
      }
    }
  }

  @override
  Future<Map<String, dynamic>> dumpDiagnostics() async {
    final RTCPeerConnection? pc = _peerConnection;
    final List<Map<String, dynamic>> sendersInfo = <Map<String, dynamic>>[];
    final List<Map<String, dynamic>> receiversInfo = <Map<String, dynamic>>[];
    final List<Map<String, dynamic>> transceiversInfo =
        <Map<String, dynamic>>[];
    if (pc != null) {
      try {
        final List<RTCRtpSender> senders = await pc.getSenders();
        for (final RTCRtpSender s in senders) {
          sendersInfo.add(<String, dynamic>{
            'trackId': s.track?.id,
            'trackKind': s.track?.kind,
            'trackEnabled': s.track?.enabled,
          });
        }
      } catch (e) {
        sendersInfo.add(<String, dynamic>{'error': '$e'});
      }
      try {
        final List<RTCRtpReceiver> receivers = await pc.getReceivers();
        for (final RTCRtpReceiver r in receivers) {
          receiversInfo.add(<String, dynamic>{
            'trackId': r.track?.id,
            'trackKind': r.track?.kind,
            'trackEnabled': r.track?.enabled,
          });
        }
      } catch (e) {
        receiversInfo.add(<String, dynamic>{'error': '$e'});
      }
      try {
        final List<RTCRtpTransceiver> transceivers = await pc.getTransceivers();
        for (final RTCRtpTransceiver t in transceivers) {
          String? dirName;
          try {
            final TransceiverDirection dir = await t.getDirection();
            dirName = dir.name;
          } catch (_) {}
          String? curDirName;
          try {
            final TransceiverDirection? curDir = await t.getCurrentDirection();
            curDirName = curDir?.name;
          } catch (_) {}
          transceiversInfo.add(<String, dynamic>{
            'direction': dirName,
            'currentDirection': curDirName,
            'senderTrack': t.sender.track?.kind,
            'receiverTrack': t.receiver.track?.kind,
            'mid': t.mid,
          });
        }
      } catch (e) {
        transceiversInfo.add(<String, dynamic>{'error': '$e'});
      }
    }
    return <String, dynamic>{
      'localStreamTracks': _localStream
          ?.getTracks()
          .map(
            (MediaStreamTrack t) => <String, dynamic>{
              'id': t.id,
              'kind': t.kind,
              'enabled': t.enabled,
            },
          )
          .toList(),
      'remoteStreamTracks': _remoteStream
          ?.getTracks()
          .map(
            (MediaStreamTrack t) => <String, dynamic>{
              'id': t.id,
              'kind': t.kind,
              'enabled': t.enabled,
            },
          )
          .toList(),
      'remoteRendererSrcObjectTracks': _remoteRenderer.srcObject
          ?.getTracks()
          .map(
            (MediaStreamTrack t) => <String, dynamic>{
              'id': t.id,
              'kind': t.kind,
              'enabled': t.enabled,
            },
          )
          .toList(),
      'remoteRendererTextureId': _remoteRenderer.textureId,
      'senders': sendersInfo,
      'receivers': receiversInfo,
      'transceivers': transceiversInfo,
      'relayMids': _relayMids
          .map(
            (({int mLineIndex, String mid}) m) => <String, dynamic>{
              'mid': m.mid,
              'mLineIndex': m.mLineIndex,
            },
          )
          .toList(),
      'lastSentOffer': _lastSentOfferDescription?['sdp'],
      'lastSentAnswer': _lastSentAnswerDescription?['sdp'],
    };
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(_callFrames?.cancel());
    unawaitedLogged(
      _shutdown(),
      context: 'Call media session dispose-close failed',
    );
    super.dispose();
  }

  /// Releases the renderers only once the session is fully closed.
  ///
  /// Disposing them alongside an in-flight `close()` let the teardown write
  /// `srcObject` on an already-freed native renderer.
  Future<void> _shutdown() async {
    await close();
    if (!_renderersInitialized) {
      return;
    }
    _renderersInitialized = false;
    try {
      await _localRenderer.dispose();
    } catch (error, stackTrace) {
      logZenError('Disposing local video renderer failed', error, stackTrace);
    }
    try {
      await _remoteRenderer.dispose();
    } catch (error, stackTrace) {
      logZenError('Disposing remote video renderer failed', error, stackTrace);
    }
  }
}

const Map<String, dynamic> _configuration = <String, dynamic>{
  'iceServers': <Map<String, dynamic>>[],
  'sdpSemantics': 'unified-plan',
  'bundlePolicy': 'max-bundle',
  'iceCandidatePoolSize': 0,
};

const Map<String, dynamic> _peerConstraints = <String, dynamic>{
  'mandatory': <String, dynamic>{},
  'optional': <Map<String, dynamic>>[
    <String, dynamic>{'googDscp': true},
    <String, dynamic>{'googCpuOveruseDetection': false},
    <String, dynamic>{'googSuspendBelowMinBitrate': false},
  ],
};

final RegExp _hostCandidatePattern = RegExp(
  r'candidate:\S+ \d+ udp \d+ (\S+) \d+ typ host',
);

/// Rewrites a WebRTC SDP so RTP/RTCP targets the local Yggdrasil UDP relay.
/// Both peers pin independently to `127.0.0.1:<their relay port>`; the Go
/// bridge then forwards datagrams across the mesh.
String pinWebRtcSdpToLocalRelay(String sdp, int port) {
  if (sdp.isEmpty || port <= 0) {
    return sdp;
  }
  final String separator = sdp.contains('\r\n') ? '\r\n' : '\n';
  final List<String> lines = sdp.split(RegExp(r'\r?\n'));
  final List<String> rewritten = <String>[];
  for (final String raw in lines) {
    final String line = raw.trimRight();
    if (line.startsWith('b=AS:') || line.startsWith('b=TIAS:')) {
      continue;
    }
    if (line.startsWith('o=')) {
      final List<String> parts = line.split(' ');
      if (parts.length >= 6) {
        parts[4] = 'IP4';
        parts[5] = '127.0.0.1';
        rewritten.add(parts.join(' '));
      } else {
        rewritten.add(line);
      }
      continue;
    }
    if (line.startsWith('c=')) {
      rewritten.add('c=IN IP4 127.0.0.1');
      continue;
    }
    if (line.startsWith('m=')) {
      final List<String> parts = line.split(' ');
      if (parts.length >= 2) {
        parts[1] = '$port';
        rewritten.add(parts.join(' '));
      } else {
        rewritten.add(line);
      }
      continue;
    }
    if (line.startsWith('a=rtcp:') && !line.startsWith('a=rtcp-mux')) {
      rewritten.add('a=rtcp:$port IN IP4 127.0.0.1');
      continue;
    }
    if (line.startsWith('a=candidate:') ||
        line.startsWith('a=end-of-candidates')) {
      continue;
    }
    rewritten.add(line);
    if (line.startsWith('a=ice-pwd:')) {
      rewritten.add(
        'a=candidate:1 1 udp 2122260223 127.0.0.1 $port typ host generation 0',
      );
      rewritten.add('a=end-of-candidates');
    }
  }
  return rewritten.join(separator);
}

Map<String, dynamic> _offerConstraints() {
  return <String, dynamic>{};
}

Map<String, dynamic> _buildAudioConstraints({String? deviceId}) {
  final bool isMobile = Platform.isAndroid || Platform.isIOS;
  if (!isMobile) {
    return <String, dynamic>{
      if (deviceId != null && deviceId.isNotEmpty) 'deviceId': deviceId,
      'echoCancellation': true,
      'autoGainControl': true,
      'noiseSuppression': true,
      if (deviceId != null && deviceId.isNotEmpty)
        'optional': <Map<String, dynamic>>[
          <String, dynamic>{'sourceId': deviceId},
        ],
    };
  }
  final bool useStandardAgc = !Platform.isAndroid;
  return <String, dynamic>{
    if (deviceId != null && deviceId.isNotEmpty) 'deviceId': deviceId,
    'echoCancellation': true,
    'noiseSuppression': false,
    'autoGainControl': useStandardAgc,
    'latency': <String, dynamic>{'ideal': 0.01},
    'sampleRate': <String, dynamic>{'ideal': 48000},
    'channelCount': <String, dynamic>{'ideal': 1},
    'googEchoCancellation': true,
    'googEchoCancellation2': true,
    'googNoiseSuppression': false,
    'googNoiseSuppression2': false,
    'googAutoGainControl': false,
    'googAutoGainControl2': false,
    'googHighpassFilter': false,
    'googTypingNoiseDetection': false,
  };
}

Map<String, dynamic> _buildVideoConstraints({String? deviceId}) {
  final bool isMobile = Platform.isAndroid || Platform.isIOS;
  if (isMobile) {
    return <String, dynamic>{
      if (deviceId != null && deviceId.isNotEmpty)
        'deviceId': deviceId
      else
        'facingMode': 'user',
      'width': <String, dynamic>{'ideal': 1280, 'max': 1280},
      'height': <String, dynamic>{'ideal': 720, 'max': 720},
      'frameRate': <String, dynamic>{'ideal': 30, 'max': 30},
    };
  }
  return <String, dynamic>{
    if (deviceId != null && deviceId.isNotEmpty) 'deviceId': deviceId,
    if (deviceId != null && deviceId.isNotEmpty)
      'optional': <Map<String, dynamic>>[
        <String, dynamic>{'sourceId': deviceId},
      ],
    'width': 1280,
    'height': 720,
    'frameRate': 30,
  };
}

@visibleForTesting
Map<String, dynamic> buildAudioConstraintsForTesting({String? deviceId}) =>
    _buildAudioConstraints(deviceId: deviceId);

@visibleForTesting
Map<String, dynamic> buildVideoConstraintsForTesting({String? deviceId}) =>
    _buildVideoConstraints(deviceId: deviceId);
