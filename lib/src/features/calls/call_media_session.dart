import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/core/logging/zen_log.dart';
import 'package:zen/src/domain/calls/call_invite_kind.dart';
import 'package:zen/src/features/calls/call_media_devices.dart';
import 'package:zen/src/features/calls/call_media_e2ee.dart';
import 'package:zen/src/features/calls/call_recorder.dart';
import 'package:zen/src/features/calls/call_recordings.dart';
import 'package:zen/src/features/calls/call_safety_cues.dart';
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

  /// This side shares its screen (or one app/window) on a second video track;
  /// the camera keeps going on its own.
  bool get isScreenSharing => false;

  /// The other side shares its screen.
  bool get remoteScreenSharing => false;

  /// The other side's shared screen, while it shares and the picture is
  /// there; [remoteRenderer] keeps showing its camera.
  RTCVideoRenderer? get remoteScreenRenderer => null;

  /// Screens and windows to pick from (desktop); empty on phones, where the
  /// system asks (whole screen or one app, Android 14+).
  Future<List<ScreenShareSource>> listScreenSources() async =>
      const <ScreenShareSource>[];

  Future<void> startScreenShare({String? sourceId}) async {
    throw UnsupportedError(t('Udostępnianie ekranu nie jest tu dostępne.'));
  }

  Future<void> stopScreenShare() async {}

  /// Whether this device can record calls.
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
    throw UnsupportedError(t('Nagrywanie nie jest tu dostępne.'));
  }

  /// Stops recording; returns the file path, or null when nothing ran.
  Future<String?> stopRecording() async => null;

  /// Gets every finished recording — stopped by hand or by the end of the
  /// call — to be kept (encrypted) in the app.
  CallRecordingFinished? onRecordingFinished;

  Future<Map<String, dynamic>> dumpDiagnostics() async =>
      const <String, dynamic>{};

  /// How the media of the active call is protected (see
  /// call_media_e2ee.dart).
  CallMediaSecurity get mediaSecurity => CallMediaSecurity.standard;

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
    MediaFrameCryptoBackend frameCrypto = const WebRtcFrameCryptoBackend(),
  }) : _recorder = recorder ?? platformCallRecorder(),
       _frameCrypto = frameCrypto {
    _callFrames = transport.frames.listen(_onCallFrame);
  }

  final MediaFrameCryptoBackend _frameCrypto;

  /// Frame encryption of the call; null where this device has none or the
  /// other side does not offer it (DTLS-SRTP only).
  MediaE2eeChannel? _e2ee;
  CallMediaSecurity _mediaSecurity = CallMediaSecurity.negotiating;

  /// The block this side answered the first offer with, repeated in every
  /// answer (the first one may be lost).
  Map<String, dynamic>? _e2eeAnswer;

  @override
  CallMediaSecurity get mediaSecurity => _mediaSecurity;

  /// Opens frame encryption for a new connection, as the offering side
  /// unless [isIncoming].
  Future<void> _openE2ee(String callId, {required bool isIncoming}) async {
    _e2eeAnswer = null;
    _mediaSecurity = CallMediaSecurity.negotiating;
    late final MediaE2eeChannel? channel;
    channel = await MediaE2eeChannel.open(
      backend: _frameCrypto,
      callId: callId,
      localId: isIncoming ? kMediaAnswererId : kMediaOffererId,
      remoteId: isIncoming ? kMediaOffererId : kMediaAnswererId,
      onRotated: _sendMediaKeyNotice,
      onChanged: () {
        final MediaE2eeChannel? current = _e2ee;
        if (current != null && identical(current, channel)) {
          _mediaSecurity = current.security;
          _notify();
        }
      },
    );
    if (_disposed || _activeCallId != callId) {
      await channel?.dispose();
      return;
    }
    _e2ee = channel;
    if (channel == null) {
      _mediaSecurity = CallMediaSecurity.standard;
    }
  }

  /// Drops frame encryption: DTLS-SRTP only from here on.
  Future<void> _dropE2ee() async {
    final MediaE2eeChannel? channel = _e2ee;
    _e2ee = null;
    _mediaSecurity = CallMediaSecurity.standard;
    _notify();
    if (channel != null) {
      await channel.fallBack();
      await channel.dispose();
    }
  }

  /// The offering side's key-exchange block, or null without encryption.
  Future<Map<String, dynamic>?> _offerE2eeBlock() async {
    final MediaE2eeChannel? channel = _e2ee;
    if (channel == null) {
      return null;
    }
    try {
      return await channel.offerBlock();
    } on Object catch (error, stackTrace) {
      logZenError('Media key offer failed', error, stackTrace);
      await _dropE2ee();
      return null;
    }
  }

  /// The answering side: keys from the offer's block, and the block for the
  /// answer; null (DTLS-SRTP only) when the offer has none.
  Future<void> _answerE2ee(Object? offerBlock) async {
    final MediaE2eeChannel? channel = _e2ee;
    if (channel == null) {
      return;
    }
    try {
      final Map<String, dynamic>? answer = await channel.answerOffer(
        offerBlock,
        offererId: kMediaOffererId,
        answererId: kMediaAnswererId,
      );
      if (answer == null) {
        await _dropE2ee();
        return;
      }
      _e2eeAnswer = answer;
      _mediaSecurity = channel.security;
    } on Object catch (error, stackTrace) {
      logZenError('Media key answer failed', error, stackTrace);
      await _dropE2ee();
    }
  }

  /// The offering side, before the first answer is applied.
  Future<void> _acceptE2eeAnswer(Object? answerBlock) async {
    final MediaE2eeChannel? channel = _e2ee;
    if (channel == null || _mediaSecurity != CallMediaSecurity.negotiating) {
      return;
    }
    try {
      await channel.acceptAnswer(
        answerBlock,
        offererId: kMediaOffererId,
        answererId: kMediaAnswererId,
      );
      _mediaSecurity = channel.security;
      if (channel.negotiated == CallMediaSecurity.standard) {
        await _dropE2ee();
      }
    } on Object catch (error, stackTrace) {
      logZenError('Media key agreement failed', error, stackTrace);
      await _dropE2ee();
    }
    _notify();
  }

  Map<String, dynamic> _withE2ee(
    Map<String, dynamic> description,
    Map<String, dynamic>? block,
  ) => <String, dynamic>{...description, kMediaE2eeField: ?block};

  void _sendMediaKeyNotice(int epoch) {
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
              'type': kCallMediaKeySignal,
              'callId': callId,
              'epoch': epoch,
            },
          )
          .catchError((Object error) {
            logZenWarning('Sending the media key notice failed: $error');
          }),
    );
  }

  StreamSubscription<SignalTransportFrame>? _callFrames;
  MediaStream? _screenStream;
  MediaStreamTrack? _screenTrack;
  bool _remoteScreenSharing = false;

  /// The mid of the screen slot: the second `m=video` section (see
  /// [screenShareSlotInSdp]), the same on both sides once an SDP carrying
  /// it has been seen.
  String? _screenMid;

  /// The msid stream id the other side sends its screen under, read from
  /// its SDP before it is applied: that stream must never be taken for the
  /// camera.
  String? _remoteScreenStreamId;
  String? _remoteScreenTrackId;
  MediaStream? _remoteScreenStream;
  final RTCVideoRenderer _remoteScreenRenderer = RTCVideoRenderer();
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
        t('Nagrywanie rozmów nie jest jeszcze dostępne na tym urządzeniu.'),
      );
    }
    if (_peerConnection == null || _recordingPath != null) {
      return;
    }
    final List<MediaStreamTrack> video =
        _remoteStream?.getVideoTracks() ?? const <MediaStreamTrack>[];
    // Announced first: nobody is recorded without knowing.
    _sendCallSignal(kCallRecordingSignal, true);
    try {
      await _recorder.start(path, video: video.isEmpty ? null : video.first);
    } on Object {
      _sendCallSignal(kCallRecordingSignal, false);
      rethrow;
    }
    _recordingPath = path;
    _recordingLabel = label;
    announceRecordingStartedWithTone();
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

  @override
  RTCVideoRenderer? get remoteScreenRenderer =>
      _remoteScreenSharing &&
          _renderersInitialized &&
          _remoteScreenRenderer.textureId != null &&
          _remoteScreenStream != null
      ? _remoteScreenRenderer
      : null;

  /// The transceiver of the screen slot, by mid once negotiated, else by
  /// the screen track it already carries.
  bool _isScreenTransceiver(RTCRtpTransceiver transceiver) {
    final String? mid = _screenMid;
    if (mid != null && mid.isNotEmpty && transceiver.mid == mid) {
      return true;
    }
    final String? screenTrackId = _screenTrack?.id;
    return screenTrackId != null &&
        transceiver.sender.track?.id == screenTrackId;
  }

  Future<RTCRtpTransceiver?> _screenTransceiver(
    RTCPeerConnection connection,
  ) async {
    for (final RTCRtpTransceiver transceiver
        in await connection.getTransceivers()) {
      if (_isScreenTransceiver(transceiver)) {
        return transceiver;
      }
    }
    return null;
  }

  /// A remote stream that carries the other side's screen, not its camera.
  bool _isRemoteScreenStream(MediaStream? stream) {
    if (stream == null) {
      return false;
    }
    if (identical(stream, _remoteScreenStream)) {
      return true;
    }
    final String? streamId = _remoteScreenStreamId;
    if (streamId != null && stream.id == streamId) {
      return true;
    }
    final String? trackId = _remoteScreenTrackId;
    return trackId != null &&
        stream.getVideoTracks().any((MediaStreamTrack t) => t.id == trackId);
  }

  bool _isRemoteScreenTrack(RTCTrackEvent event) {
    final String? mid = _screenMid;
    final String? eventMid = event.transceiver?.mid;
    if (mid != null && mid.isNotEmpty && eventMid == mid) {
      return true;
    }
    final String? trackId = _remoteScreenTrackId;
    final String? streamId = _remoteScreenStreamId;
    return (trackId != null && event.track.id == trackId) ||
        (streamId != null &&
            event.streams.any((MediaStream s) => s.id == streamId));
  }

  /// Puts the other side's screen track into a stream of its own, bound to
  /// [_remoteScreenRenderer].
  Future<void> _bindRemoteScreen(MediaStreamTrack track) async {
    MediaStream? stream = _remoteScreenStream;
    if (stream == null) {
      try {
        stream = await createLocalMediaStream('remote_screen_${track.id}');
      } catch (error) {
        logZenWarning('Creating the remote screen stream failed: $error');
        return;
      }
    }
    for (final MediaStreamTrack old in List<MediaStreamTrack>.from(
      stream.getVideoTracks(),
    )) {
      if (old.id != track.id) {
        try {
          await stream.removeTrack(old);
        } catch (_) {
          // Gone with its receiver already.
        }
      }
    }
    if (!stream.getVideoTracks().any(
      (MediaStreamTrack t) => t.id == track.id,
    )) {
      try {
        await stream.addTrack(track, addToNative: true);
      } catch (_) {
        await stream.addTrack(track, addToNative: false);
      }
    }
    if (_disposed || _peerConnection == null) {
      return;
    }
    _remoteScreenStream = stream;
    _remoteScreenTrackId = track.id;
    _safeSetRendererSrcObject(_remoteScreenRenderer, stream);
    _notify();
  }

  void _onCallFrame(SignalTransportFrame frame) {
    final Object? type = frame.payload['type'];
    if (type != kCallScreenSignal &&
        type != kCallRecordingSignal &&
        type != kCallMediaKeySignal) {
      return;
    }
    final String? remote = _remoteAddress;
    if (remote == null ||
        frame.payload['callId'] != _activeCallId ||
        frame.from.trim().toLowerCase() != remote.trim().toLowerCase()) {
      return;
    }
    if (type == kCallMediaKeySignal) {
      unawaitedLogged(
        _e2ee?.remoteAdvanced(frame.payload['epoch']),
        context: 'Following the media key failed',
      );
      return;
    }
    if (type == kCallScreenSignal) {
      _remoteScreenSharing = frame.payload['on'] == true;
    } else {
      final bool on = frame.payload['on'] == true;
      if (on && !_remoteRecording) {
        // Everyone hears that a recording began.
        announceRecordingStartedWithTone();
      }
      _remoteRecording = on;
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

  @override
  Future<void> startScreenShare({String? sourceId}) async {
    final RTCPeerConnection? connection = _peerConnection;
    final MediaStream? localStream = _localStream;
    if (connection == null || localStream == null) {
      throw StateError(t('Brak aktywnej rozmowy do udostępnienia ekranu.'));
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
        throw StateError(t('Nie zezwolono na udostępnienie ekranu.'));
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
      throw StateError(t('Nie udało się przechwycić ekranu.'));
    }
    final MediaStreamTrack track = tracks.first;
    // Stopped from the system UI ("Zatrzymaj udostępnianie").
    track.onEnded = () => unawaited(stopScreenShare());
    _screenStream = screen;
    _screenTrack = track;
    screenShareHidesNotifications.value = true;
    try {
      await _attachScreenTrack(connection, screen, track);
    } catch (error) {
      _screenStream = null;
      _screenTrack = null;
      androidScreenCaptureActive.value = false;
      screenShareHidesNotifications.value = false;
      await _disposeStream(screen);
      rethrow;
    }
    _activeKind = CallInviteKind.video;
    _sendScreenSignal(true);
    _notify();
    await _renegotiateWhenStable(CallInviteKind.video);
  }

  /// The screen goes out on its own video slot, next to the camera: the
  /// slot already negotiated for screens when there is one (either side may
  /// have opened it), else a new transceiver. Sends and receives, so both
  /// sides can share at once; negotiated against a side that does not
  /// share, it ends up send-only.
  Future<void> _attachScreenTrack(
    RTCPeerConnection connection,
    MediaStream screen,
    MediaStreamTrack track,
  ) async {
    final RTCRtpTransceiver? slot = await _screenTransceiver(connection);
    if (slot == null) {
      await connection.addTransceiver(
        track: track,
        kind: RTCRtpMediaType.RTCRtpMediaTypeVideo,
        init: RTCRtpTransceiverInit(
          direction: TransceiverDirection.SendRecv,
          streams: <MediaStream>[screen],
        ),
      );
      return;
    }
    try {
      // The msid tells the other side which stream is the screen.
      await slot.sender.setStreams(<MediaStream>[screen]);
    } catch (error) {
      logZenWarning('Setting the screen sender stream failed: $error');
    }
    await slot.sender.replaceTrack(track);
    await slot.setDirection(TransceiverDirection.SendRecv);
  }

  @override
  Future<void> stopScreenShare() async {
    final MediaStream? screen = _screenStream;
    if (screen == null) {
      return;
    }
    _screenStream = null;
    androidScreenCaptureActive.value = false;
    screenShareHidesNotifications.value = false;
    final RTCPeerConnection? connection = _peerConnection;
    if (connection != null) {
      try {
        // Found while [_screenTrack] still names it; the camera slot is
        // never touched.
        final RTCRtpTransceiver? slot = await _screenTransceiver(connection);
        if (slot != null) {
          await slot.sender.replaceTrack(null);
          await slot.setDirection(TransceiverDirection.RecvOnly);
        }
      } catch (error, stackTrace) {
        logZenError('Clearing the screen slot failed', error, stackTrace);
      }
    }
    _screenTrack = null;
    await _disposeStream(screen);
    _sendScreenSignal(false);
    _notify();
    if (connection != null && identical(connection, _peerConnection)) {
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
        if (s != null &&
            !_isRemoteScreenStream(s) &&
            s.getVideoTracks().isNotEmpty) {
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
        if (stream != null &&
            !_isRemoteScreenStream(stream) &&
            stream.getVideoTracks().any(_isLiveVideoTrack)) {
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
      final Map<String, dynamic>? e2ee = await _offerE2eeBlock();
      final RTCSessionDescription offer = await _requireConnection()
          .createOffer(_offerConstraints());
      final RTCSessionDescription pinned = await _commitLocalDescription(offer);
      _lastSentOfferDescription = _withE2ee(_descriptionToMap(pinned), e2ee);
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
      // Keys first: the transformers attached with the remote description
      // then have them before anything arrives.
      await _answerE2ee(remoteDescription[kMediaE2eeField]);
      await _setRemoteDescriptionPinned(remoteDescription);
      await _bindLocalTracksToAnswerTransceivers();
      await _pinLocalVideoDirection(sending: _localCameraWanted);
      final RTCSessionDescription answer = await _requireConnection()
          .createAnswer(_offerConstraints());
      final RTCSessionDescription pinned = await _commitLocalDescription(
        answer,
      );
      _lastSentAnswerDescription = _withE2ee(
        _descriptionToMap(pinned),
        _e2eeAnswer,
      );
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
      throw StateError(t('Brak aktywnej sesji do renegocjacji rozmowy.'));
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
      _lastSentAnswerDescription = _withE2ee(
        _descriptionToMap(pinned),
        _e2eeAnswer,
      );
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
      // Keys before the answer lands, so no frame comes in without them.
      await _acceptE2eeAnswer(description[kMediaE2eeField]);
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
      throw StateError(t('Brak aktywnej rozmowy do sterowania kamera.'));
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

  /// The camera's video transceiver. The screen slot is a video
  /// transceiver too, but never this one.
  bool _isVideoTransceiver(RTCRtpTransceiver transceiver, [int? index]) {
    if (_isScreenTransceiver(transceiver)) {
      return false;
    }
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
          if (sender.track?.kind == 'video' &&
              sender.track?.id != _screenTrack?.id) {
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
          // The shared screen keeps going without the camera.
          if (sender.track?.kind == 'video' &&
              sender.track?.id != _screenTrack?.id) {
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
        if (_isScreenTransceiver(transceiver)) {
          final MediaStream? screen = _screenStream;
          final MediaStreamTrack? screenTrack = _screenTrack;
          if (screen != null && screenTrack != null) {
            try {
              await _attachScreenTrack(connection, screen, screenTrack);
            } catch (error) {
              logZenWarning('Binding the screen to its slot failed: $error');
            }
          }
          // Not sharing: the slot stays receive-only.
          continue;
        }
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
      throw StateError(t('Rozmowa została zamknięta w trakcie zestawiania.'));
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
      throw StateError(t('Kontroler rozmowy został już zamknięty.'));
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
      throw StateError(
        t('Nie udało się uruchomić lokalnego relay dla rozmowy.'),
      );
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
      throw StateError(t('Kontroler rozmowy został już zamknięty.'));
    }
    _peerConnection = connection;
    _relayMetadataReady = Completer<void>();
    await _openE2ee(callId, isIncoming: isIncoming);
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
        if (_isRemoteScreenStream(stream) ||
            (_remoteScreenTrackId != null &&
                track.id == _remoteScreenTrackId)) {
          // The other side's screen, never its camera.
          track.onMute = _notify;
          track.onUnMute = _notify;
          await _bindRemoteScreen(track);
          return;
        }
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
        if (_isRemoteScreenTrack(event)) {
          // The second video slot: the other side's screen, shown on its
          // own renderer while the camera stays on [_remoteRenderer].
          track.onMute = _notify;
          track.onUnMute = _notify;
          await _bindRemoteScreen(track);
          return;
        }
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
          if (s == null || _isRemoteScreenStream(s)) {
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
            if (s != null && !_isRemoteScreenStream(s)) {
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
      if (_isRemoteScreenStream(stream)) {
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
      throw StateError(t('Rozmowa została zamknięta w trakcie zestawiania.'));
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
      await _remoteScreenRenderer.initialize();
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
      throw StateError(t('Brak aktywnej rozmowy do renegocjacji.'));
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
      throw StateError(t('Brak aktywnej sesji do wysłania sygnału rozmowy.'));
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
      desc = RTCSessionDescription(
        forceCameraSectionSendRecv(desc.sdp ?? ''),
        desc.type,
      );
    }
    // Every sender and receiver gets its transformer before the
    // description that lets media flow on it.
    await _e2ee?.attachAll(connection);
    await connection.setLocalDescription(desc);
    _captureRelayMetadata(desc.sdp);
    _screenMid ??= screenShareSlotInSdp(desc.sdp ?? '')?.mid;
    return desc;
  }

  Future<void> _setRemoteDescriptionPinned(
    Map<String, dynamic> description,
  ) async {
    final RTCPeerConnection? connection = _peerConnection;
    if (connection == null) {
      throw StateError(t('Brak aktywnej sesji WebRTC.'));
    }
    final RTCSessionDescription original = _descriptionFromMap(description);
    // Known before the description lands: its tracks arrive while it is
    // being applied, and the screen must not be taken for the camera.
    final ({String mid, String? streamId})? screenSlot = screenShareSlotInSdp(
      original.sdp ?? '',
    );
    if (screenSlot != null) {
      _screenMid ??= screenSlot.mid;
      _remoteScreenStreamId = screenSlot.streamId ?? _remoteScreenStreamId;
    }
    // Never the peer's original SDP: its candidates carry LAN/public
    // addresses, and ICE could then route the media around the mesh.
    await applyRemoteSdpViaLocalRelay(
      sdp: original.sdp ?? '',
      type: original.type ?? 'offer',
      relayPort: _relayPort ?? 0,
      apply: (String value, String kind) =>
          connection.setRemoteDescription(RTCSessionDescription(value, kind)),
    );
    await _e2ee?.attachAll(connection);
    _remoteDescriptionSet = true;
    await _waitForRelayMetadata();
    await _ensureRelayCandidate();
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
    _screenTrack = null;
    _remoteScreenSharing = false;
    _screenMid = null;
    _remoteScreenStreamId = null;
    _remoteScreenTrackId = null;
    final MediaStream? remoteScreen = _remoteScreenStream;
    _remoteScreenStream = null;
    if (_renderersInitialized) {
      _safeSetRendererSrcObject(_remoteScreenRenderer, null);
    }
    if (remoteScreen != null) {
      try {
        await remoteScreen.dispose();
      } catch (_) {
        // Released with the connection already.
      }
    }
    androidScreenCaptureActive.value = false;
    screenShareHidesNotifications.value = false;
    await _disposeStream(screen);
    _disconnectGraceTimer?.cancel();
    _disconnectGraceTimer = null;
    final MediaE2eeChannel? e2ee = _e2ee;
    _e2ee = null;
    _e2eeAnswer = null;
    _mediaSecurity = CallMediaSecurity.negotiating;
    if (e2ee != null) {
      // Transformers go before the connection they sit on.
      await e2ee.dispose();
    }
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
      'mediaSecurity': _mediaSecurity.name,
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
    try {
      await _remoteScreenRenderer.dispose();
    } catch (error, stackTrace) {
      logZenError('Disposing remote screen renderer failed', error, stackTrace);
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

/// The screen-share slot of a 1:1 call SDP: the second `m=video` section
/// (the first one is always the camera's). Returns its mid and the stream
/// id of its `a=msid` line (null while nothing is sent on it), or null when
/// the SDP has no second video section.
({String mid, String? streamId})? screenShareSlotInSdp(String sdp) {
  if (sdp.isEmpty) {
    return null;
  }
  int videoSections = 0;
  bool inSlot = false;
  String? mid;
  String? streamId;
  for (final String raw in sdp.split(RegExp(r'\r?\n'))) {
    final String line = raw.trim();
    if (line.startsWith('m=')) {
      if (inSlot) {
        break;
      }
      if (line.startsWith('m=video')) {
        videoSections += 1;
        inSlot = videoSections == 2;
      }
      continue;
    }
    if (!inSlot) {
      continue;
    }
    if (line.startsWith('a=mid:')) {
      mid = line.substring('a=mid:'.length).trim();
    } else if (line.startsWith('a=msid:')) {
      final String id = line.substring('a=msid:'.length).trim().split(' ')[0];
      if (id.isNotEmpty && id != '-') {
        streamId = id;
      }
    }
  }
  if (mid == null || mid.isEmpty) {
    return null;
  }
  return (mid: mid, streamId: streamId);
}

/// Forces the camera's video section (the first `m=video`) to `sendrecv`,
/// leaving every other section — the screen slot among them — as WebRTC
/// produced it.
String forceCameraSectionSendRecv(String sdp) {
  if (sdp.isEmpty) {
    return sdp;
  }
  final String separator = sdp.contains('\r\n') ? '\r\n' : '\n';
  final List<String> lines = sdp.split(RegExp(r'\r?\n'));
  final List<String> result = <String>[];
  bool seenVideo = false;
  bool inCamera = false;
  bool foundDirection = false;
  for (final String raw in lines) {
    final String line = raw.trim();
    if (line.startsWith('m=')) {
      if (inCamera && !foundDirection) {
        result.add('a=sendrecv');
      }
      inCamera = !seenVideo && line.startsWith('m=video');
      seenVideo = seenVideo || line.startsWith('m=video');
      foundDirection = false;
      result.add(raw);
      continue;
    }
    if (inCamera &&
        (line == 'a=recvonly' ||
            line == 'a=sendonly' ||
            line == 'a=inactive' ||
            line == 'a=sendrecv')) {
      result.add('a=sendrecv');
      foundDirection = true;
      continue;
    }
    result.add(raw);
  }
  if (inCamera && !foundDirection) {
    result.add('a=sendrecv');
  }
  return result.join(separator);
}

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

/// Removes every ICE candidate from a peer's SDP and blanks its connection
/// addresses (`c=`, `a=rtcp:`), keeping ports, codecs, ICE credentials and
/// fingerprints as they are — the shape WebRTC itself produces before it has
/// gathered any candidate.
///
/// The fallback when the platform refuses the [pinWebRtcSdpToLocalRelay]
/// form: the connection then knows no address of the peer at all, only the
/// local relay candidates added afterwards, so media cannot leave the
/// Yggdrasil mesh.
String stripWebRtcSdpCandidates(String sdp) {
  if (sdp.isEmpty) {
    return sdp;
  }
  final String separator = sdp.contains('\r\n') ? '\r\n' : '\n';
  final List<String> lines = sdp.split(RegExp(r'\r?\n'));
  final List<String> stripped = <String>[];
  for (final String raw in lines) {
    final String line = raw.trimRight();
    if (line.startsWith('a=candidate:') ||
        line.startsWith('a=end-of-candidates') ||
        line.startsWith('a=remote-candidates:')) {
      continue;
    }
    if (line.startsWith('c=')) {
      stripped.add('c=IN IP4 0.0.0.0');
      continue;
    }
    if (line.startsWith('a=rtcp:')) {
      final String port = line.substring('a=rtcp:'.length).split(' ').first;
      stripped.add('a=rtcp:$port IN IP4 0.0.0.0');
      continue;
    }
    stripped.add(line);
  }
  return stripped.join(separator);
}

/// Applies a peer's [sdp] so its media can only reach the local Yggdrasil
/// relay on [relayPort].
///
/// First in the [pinWebRtcSdpToLocalRelay] form; when [apply] (the
/// connection's `setRemoteDescription`) rejects that, once more with every
/// peer candidate stripped ([stripWebRtcSdpCandidates]). The peer's original
/// SDP — whose candidates carry its LAN/public addresses, so ICE could pair
/// them and route the call around the mesh — is never applied: when the
/// stripped form is refused too, this throws and the caller ends the call.
Future<void> applyRemoteSdpViaLocalRelay({
  required String sdp,
  required String type,
  required int relayPort,
  required Future<void> Function(String sdp, String type) apply,
  String label = 'call',
}) async {
  if (relayPort <= 0) {
    // Pinning to port 0 would hand the original SDP through unchanged.
    throw StateError(t('Nie udało się uruchomić lokalnego relay dla rozmowy.'));
  }
  try {
    await apply(pinWebRtcSdpToLocalRelay(sdp, relayPort), type);
    return;
  } catch (error, stackTrace) {
    logZenError(
      'Pinned remote $label SDP ($type) rejected; retrying with the peer '
      'candidates stripped, never with the original',
      error,
      stackTrace,
    );
  }
  try {
    await apply(stripWebRtcSdpCandidates(sdp), type);
    logZenWarning(
      'Remote $label SDP ($type) applied without peer candidates; only the '
      'local relay candidates remain',
    );
  } catch (error, stackTrace) {
    logZenError(
      'Remote $label SDP ($type) rejected even without peer candidates; '
      'ending instead of applying the original',
      error,
      stackTrace,
    );
    throw StateError(t('Nie udało się zestawić rozmowy przez lokalny relay.'));
  }
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
