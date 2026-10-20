part of 'call_media_session.dart';

/// One peer connection of a group call.
final class _GroupLeg {
  _GroupLeg({required this.peer, required this.relayId});

  final String peer;
  final String relayId;
  RTCPeerConnection? connection;
  int relayPort = 0;
  RTCVideoRenderer? renderer;
  MediaStream? remoteStream;

  /// The remote video, in a stream of its own: a video slot negotiated
  /// without a camera carries no stream id, so it cannot ride on the audio
  /// stream the renderer would otherwise get.
  MediaStream? videoStream;

  /// The remote shared screen: the leg's second video slot, on a renderer
  /// of its own so the camera keeps showing next to it.
  RTCVideoRenderer? screenRenderer;
  MediaStream? screenStream;

  /// Identifies one offer/answer exchange (offering side's clock): stale
  /// copies of older exchanges are recognised and ignored.
  int exchange = 0;
  GroupCallLegState state = GroupCallLegState.connecting;
  bool awaitingAnswer = false;
  Map<String, dynamic>? lastOffer;
  Map<String, dynamic>? lastAnswer;
  String? lastRemoteOfferSdp;
  bool remoteDescriptionSet = false;

  /// Hosts a relay candidate was already added for (see
  /// `_ensureRelayCandidate`).
  final Set<String> relayHosts = <String>{};
  final List<({String mid, int mLineIndex, String kind})> mids =
      <({String mid, int mLineIndex, String kind})>[];
  String? localCandidateIp;
  Timer? disconnectTimer;
  bool closed = false;
}

/// [GroupCallMedia] over flutter_webrtc: one [RTCPeerConnection] per remote
/// participant, each pinned to its own Yggdrasil UDP relay (see
/// [pinWebRtcSdpToLocalRelay]), all sharing one local stream.
final class WebRtcGroupCallMedia extends GroupCallMedia {
  WebRtcGroupCallMedia({required this.transport, CallRecorder? recorder})
    : _recorder = recorder ?? platformCallRecorder() {
    _frames = transport.frames.listen(_onFrame);
  }

  final CallRecorder _recorder;
  String? _recordingPath;
  String _recordingLabel = '';
  final Set<String> _recordingPeers = <String>{};

  @override
  bool get canRecord => _recorder.available;

  @override
  bool get isRecording => _recordingPath != null;

  @override
  Set<String> get recordingPeers => Set<String>.unmodifiable(_recordingPeers);

  @override
  String get recordingExtension => _recorder.extension;

  @override
  Future<void> startRecording(String path, {String label = ''}) async {
    if (!canRecord) {
      throw UnsupportedError(
        t('Nagrywanie rozmów nie jest jeszcze dostępne na tym urządzeniu.'),
      );
    }
    if (_callId == null || _recordingPath != null) {
      return;
    }
    // Everyone is told first: nobody is recorded without knowing (§13.2).
    await _announceRecording(true);
    try {
      // What this device hears: everyone else, mixed.
      await _recorder.start(path);
    } on Object {
      await _announceRecording(false);
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

  Future<void> _finishRecording({required bool tell}) async {
    final String? path = _recordingPath;
    if (path == null) {
      return;
    }
    _recordingPath = null;
    try {
      await _recorder.stop();
    } catch (error, stackTrace) {
      logZenError(
        'Stopping the group call recording failed',
        error,
        stackTrace,
      );
    }
    if (tell) {
      await _announceRecording(false);
    }
    onRecordingFinished?.call(path, _recorder.mime, _recordingLabel);
  }

  Future<void> _announceRecording(bool on, {String? only}) async {
    final String? callId = _callId;
    if (callId == null) {
      return;
    }
    for (final String peer
        in only == null ? _legs.keys.toList() : <String>[only]) {
      try {
        await transport.send(
          remoteAddress: peer,
          payload: <String, dynamic>{
            'type': kGroupRecordingSignal,
            'callId': callId,
            'on': on,
          },
        );
      } catch (error) {
        logZenWarning('Telling $peer about the recording failed: $error');
      }
    }
  }

  StreamSubscription<SignalTransportFrame>? _frames;
  MediaStream? _screenStream;
  MediaStreamTrack? _screenTrack;
  final Set<String> _remoteScreens = <String>{};

  /// What goes out on video slot [slot]: the camera on the first, the
  /// shared screen on the second.
  MediaStreamTrack? _outgoingVideo(int slot) =>
      slot == _screenSlot ? _screenTrack : _cameraTrack;

  /// Video slots of every leg: the camera's, then the screen's. Both are
  /// negotiated when the leg is built, so sharing is a track swap like the
  /// camera and never renegotiates.
  static const int _cameraSlot = 0;
  static const int _screenSlot = 1;

  @override
  bool get isScreenSharing => _screenTrack != null;

  void _onFrame(SignalTransportFrame frame) {
    final Object? type = frame.payload['type'];
    if ((type != kGroupScreenSignal && type != kGroupRecordingSignal) ||
        frame.payload['callId'] != _callId) {
      return;
    }
    final String? peer = _legs.keys
        .where((String p) => p.toLowerCase() == frame.from.toLowerCase())
        .firstOrNull;
    if (peer == null) {
      return;
    }
    if (type == kGroupRecordingSignal) {
      if (frame.payload['on'] == true) {
        if (_recordingPeers.add(peer)) {
          // Everyone hears that a recording began (§13.2).
          announceRecordingStartedWithTone();
        }
      } else {
        _recordingPeers.remove(peer);
      }
      _notify();
      return;
    }
    if (frame.payload['on'] == true) {
      _remoteScreens.add(peer);
    } else {
      _remoteScreens.remove(peer);
    }
    _notify();
  }

  Future<void> _announceScreen(bool on, {String? only}) async {
    final String? callId = _callId;
    if (callId == null) {
      return;
    }
    for (final String peer
        in only == null ? _legs.keys.toList() : <String>[only]) {
      try {
        await transport.send(
          remoteAddress: peer,
          payload: <String, dynamic>{
            'type': kGroupScreenSignal,
            'callId': callId,
            'on': on,
          },
        );
      } catch (error) {
        logZenWarning('Telling $peer about screen sharing failed: $error');
      }
    }
  }

  @override
  Future<List<ScreenShareSource>> listScreenSources() async {
    if (!(Platform.isWindows || Platform.isLinux || Platform.isMacOS)) {
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
    } catch (error) {
      logZenWarning('Listing screens to share failed: $error');
      return const <ScreenShareSource>[];
    }
  }

  @override
  Future<void> startScreenShare({String? sourceId}) async {
    final MediaStream? local = _localStream;
    if (local == null) {
      throw StateError(t('Brak aktywnego połączenia grupowego.'));
    }
    if (_screenTrack != null) {
      return;
    }
    final bool desktop =
        Platform.isWindows || Platform.isLinux || Platform.isMacOS;
    if (Platform.isAndroid) {
      if (!await Helper.requestCapturePermission()) {
        throw StateError(t('Nie zezwolono na udostępnienie ekranu.'));
      }
      androidScreenCaptureActive.value = true;
      await androidPrepareScreenCapture?.call();
    }
    final MediaStream screen;
    try {
      screen = await navigator.mediaDevices.getDisplayMedia(
        desktop
            ? <String, dynamic>{
                'audio': false,
                'video': <String, dynamic>{
                  if (sourceId != null)
                    'deviceId': <String, dynamic>{'exact': sourceId},
                  'mandatory': <String, dynamic>{'frameRate': 15.0},
                },
              }
            : <String, dynamic>{'audio': false, 'video': true},
      );
    } catch (error) {
      androidScreenCaptureActive.value = false;
      rethrow;
    }
    final List<MediaStreamTrack> tracks = screen.getVideoTracks();
    if (tracks.isEmpty) {
      await _stopStream(screen);
      androidScreenCaptureActive.value = false;
      throw StateError(t('Nie udało się przechwycić ekranu.'));
    }
    final MediaStreamTrack track = tracks.first;
    _screenStream = screen;
    _screenTrack = track;
    screenShareHidesNotifications.value = true;
    track.onEnded = () => unawaited(stopScreenShare());
    for (final _GroupLeg leg in _legs.values.toList()) {
      await _replaceVideo(leg, track, screen, slot: _screenSlot);
    }
    await _announceScreen(true);
    _notify();
  }

  @override
  Future<void> stopScreenShare() async {
    final MediaStream? screen = _screenStream;
    if (screen == null) {
      return;
    }
    _screenStream = null;
    _screenTrack = null;
    androidScreenCaptureActive.value = false;
    screenShareHidesNotifications.value = false;
    for (final _GroupLeg leg in _legs.values.toList()) {
      await _replaceVideo(leg, null, screen, slot: _screenSlot);
    }
    await _stopStream(screen);
    await _announceScreen(false);
    _notify();
  }

  final SignalTransport transport;

  String? _callId;
  String? _groupId;
  String _localAddress = '';
  CallInviteKind _kind = CallInviteKind.audio;
  MediaStream? _localStream;
  MediaStreamTrack? _cameraTrack;
  RTCVideoRenderer? _localRenderer;
  bool _localRendererReady = false;
  bool _muted = false;
  bool _disposed = false;
  final Map<String, _GroupLeg> _legs = <String, _GroupLeg>{};
  final Map<String, bool> _remoteCamera = <String, bool>{};
  final Map<String, Future<void>> _peerOps = <String, Future<void>>{};

  /// Bumped by every start/close: work queued for an earlier call must not
  /// run against the next one.
  int _generation = 0;

  @override
  String? get activeCallId => _callId;

  @override
  RTCVideoRenderer? get localRenderer =>
      _localRendererReady && _cameraTrack != null ? _localRenderer : null;

  @override
  bool get hasLocalVideo => _cameraTrack != null;

  @override
  Map<String, GroupCallPeerView> get peers => <String, GroupCallPeerView>{
    for (final _GroupLeg leg in _legs.values)
      leg.peer: GroupCallPeerView(
        address: leg.peer,
        state: leg.state,
        renderer: leg.renderer,
        hasVideo:
            (_remoteCamera[leg.peer] ?? false) &&
            leg.renderer != null &&
            leg.videoStream != null,
        sharingScreen: _remoteScreens.contains(leg.peer),
        screenRenderer:
            _remoteScreens.contains(leg.peer) && leg.screenStream != null
            ? leg.screenRenderer
            : null,
      ),
  };

  void _notify() {
    if (!_disposed) {
      notifyListeners();
    }
  }

  /// Runs [operation] after everything already queued for [peer]: an offer,
  /// its repeat and a drop must never interleave on one connection.
  Future<void> _serial(String peer, Future<void> Function() operation) {
    final int generation = _generation;
    final Future<void> previous = _peerOps[peer] ?? Future<void>.value();
    final Future<void> next = previous
        .then((_) {
          if (generation != _generation) {
            return null;
          }
          return operation();
        })
        .catchError((Object error, StackTrace stackTrace) {
          logZenError('Group call leg $peer failed', error, stackTrace);
          final _GroupLeg? leg = _legs[peer];
          if (generation == _generation && leg != null && !leg.closed) {
            _setLegState(leg, GroupCallLegState.failed);
          }
        });
    _peerOps[peer] = next;
    return next;
  }

  @override
  Future<void> start({
    required String callId,
    required String groupId,
    required String localAddress,
    required CallInviteKind kind,
    required bool cameraOn,
  }) async {
    await close();
    if (_disposed) {
      throw StateError(t('Połączenie zostało już zamknięte.'));
    }
    _generation += 1;
    _callId = callId;
    _groupId = groupId;
    _localAddress = localAddress;
    _kind = kind;
    _muted = false;
    final MediaStream stream = await _openLocalStream(cameraOn: cameraOn);
    if (_disposed || _callId != callId) {
      await _stopStream(stream);
      throw StateError(
        t('Połączenie zostało zamknięte w trakcie zestawiania.'),
      );
    }
    _localStream = stream;
    final List<MediaStreamTrack> video = stream.getVideoTracks();
    _cameraTrack = video.isEmpty ? null : video.first;
    if (_cameraTrack != null) {
      await _ensureLocalRenderer();
      _localRenderer?.srcObject = stream;
    }
    if (Platform.isAndroid || Platform.isIOS) {
      await setSpeakerOn(kind == CallInviteKind.video);
    }
    _notify();
  }

  Future<MediaStream> _openLocalStream({required bool cameraOn}) async {
    try {
      return await navigator.mediaDevices.getUserMedia(<String, dynamic>{
        'audio': _buildAudioConstraints(),
        'video': cameraOn ? _buildVideoConstraints() : false,
      });
    } catch (error) {
      logZenWarning('Group call capture failed ($error), retrying plainly');
    }
    if (cameraOn) {
      try {
        return await navigator.mediaDevices.getUserMedia(<String, dynamic>{
          'audio': true,
          'video': true,
        });
      } catch (error) {
        logZenWarning('Group call camera unavailable ($error), audio only');
      }
    }
    return navigator.mediaDevices.getUserMedia(<String, dynamic>{
      'audio': true,
      'video': false,
    });
  }

  Future<void> _ensureLocalRenderer() async {
    if (_localRendererReady || _disposed) {
      return;
    }
    final RTCVideoRenderer renderer = _localRenderer ?? RTCVideoRenderer();
    _localRenderer = renderer;
    await renderer.initialize();
    _localRendererReady = true;
  }

  Future<_GroupLeg> _createLeg(String peer) async {
    final String? callId = _callId;
    final MediaStream? local = _localStream;
    if (callId == null || local == null) {
      throw StateError(t('Brak aktywnego połączenia grupowego.'));
    }
    final _GroupLeg leg = _GroupLeg(
      peer: peer,
      relayId: groupCallLegId(callId, _localAddress, peer),
    );
    _legs[peer] = leg;
    _notify();
    onLegState?.call(callId, peer, GroupCallLegState.connecting);
    leg.relayPort = await transport.openRelay(
      callId: leg.relayId,
      remoteAddress: peer,
    );
    if (leg.relayPort <= 0) {
      throw StateError(
        t('Nie udało się uruchomić relay dla {peer}.', {'peer': peer}),
      );
    }
    final RTCPeerConnection connection = await createPeerConnection(
      _configuration,
      _peerConstraints,
    );
    if (leg.closed || _callId != callId) {
      await connection.close();
      await connection.dispose();
      throw StateError(
        t('Połączenie z {peer} zamknięte w trakcie zestawiania.', {
          'peer': peer,
        }),
      );
    }
    leg.connection = connection;
    connection.onIceCandidate = (RTCIceCandidate candidate) {
      final String value = candidate.candidate ?? '';
      if (leg.localCandidateIp == null) {
        final RegExpMatch? match = _hostCandidatePattern.firstMatch(value);
        if (match != null) {
          leg.localCandidateIp = match.group(1);
        }
      }
      if (leg.remoteDescriptionSet) {
        unawaited(_ensureRelayCandidate(leg));
      }
    };
    connection.onTrack = (RTCTrackEvent event) {
      unawaited(_handleRemoteTrack(leg, event));
    };
    connection.onConnectionState = (RTCPeerConnectionState state) {
      if (leg.closed) {
        return;
      }
      switch (state) {
        case RTCPeerConnectionState.RTCPeerConnectionStateConnected:
          leg.disconnectTimer?.cancel();
          leg.disconnectTimer = null;
          final bool joined = leg.state != GroupCallLegState.connected;
          _setLegState(leg, GroupCallLegState.connected);
          // Whoever joins while this side records learns it at once.
          if (joined && _recordingPath != null) {
            unawaited(_announceRecording(true, only: leg.peer));
          }
          // Same for a screen being shared: its slot is live already.
          if (joined && _screenTrack != null) {
            unawaited(_announceScreen(true, only: leg.peer));
          }
        case RTCPeerConnectionState.RTCPeerConnectionStateDisconnected:
          // Often just a hiccup on the mesh; give it a moment.
          leg.disconnectTimer?.cancel();
          leg.disconnectTimer = Timer(const Duration(seconds: 5), () {
            if (!leg.closed && leg.state != GroupCallLegState.connected) {
              _setLegState(leg, GroupCallLegState.failed);
            }
          });
          if (leg.state == GroupCallLegState.connected) {
            _setLegState(leg, GroupCallLegState.connecting);
          }
        case RTCPeerConnectionState.RTCPeerConnectionStateFailed:
        case RTCPeerConnectionState.RTCPeerConnectionStateClosed:
          leg.disconnectTimer?.cancel();
          leg.disconnectTimer = null;
          _setLegState(leg, GroupCallLegState.failed);
        case RTCPeerConnectionState.RTCPeerConnectionStateNew:
        case RTCPeerConnectionState.RTCPeerConnectionStateConnecting:
          break;
      }
    };
    return leg;
  }

  void _setLegState(_GroupLeg leg, GroupCallLegState state) {
    if (leg.state == state) {
      return;
    }
    leg.state = state;
    _notify();
    final String? callId = _callId;
    if (callId != null && !leg.closed) {
      onLegState?.call(callId, leg.peer, state);
    }
  }

  Future<void> _handleRemoteTrack(_GroupLeg leg, RTCTrackEvent event) async {
    if (leg.closed) {
      return;
    }
    final MediaStreamTrack track = event.track;
    if (track.kind != 'video') {
      // Remote audio plays by itself; keep the stream only for bookkeeping.
      leg.remoteStream ??= event.streams.isNotEmpty
          ? event.streams.first
          : null;
      return;
    }
    final String? mid = event.transceiver?.mid;
    final bool screen = mid != null && _videoSlotOfMid(leg, mid) == _screenSlot;
    MediaStream? stream = screen ? leg.screenStream : leg.videoStream;
    if (stream == null) {
      try {
        stream = await createLocalMediaStream(
          '${screen ? 'group_screen' : 'group_video'}_${leg.relayId}',
        );
      } catch (error) {
        logZenWarning('Creating a video stream for ${leg.peer} failed: $error');
        return;
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
    if (leg.closed) {
      return;
    }
    if (screen) {
      leg.screenStream = stream;
    } else {
      leg.videoStream = stream;
    }
    RTCVideoRenderer? renderer = screen ? leg.screenRenderer : leg.renderer;
    if (renderer == null) {
      final RTCVideoRenderer created = RTCVideoRenderer();
      await created.initialize();
      if (leg.closed) {
        await created.dispose();
        return;
      }
      renderer = created;
      if (screen) {
        leg.screenRenderer = created;
      } else {
        leg.renderer = created;
      }
    }
    renderer.srcObject = stream;
    _notify();
  }

  @override
  Future<void> connectTo(String peer) {
    return _serial(peer, () async {
      if (_callId == null) {
        return;
      }
      final _GroupLeg? existing = _legs[peer];
      if (existing != null) {
        if (existing.state != GroupCallLegState.failed) {
          return;
        }
        await _closeLeg(existing);
      }
      final _GroupLeg leg = await _createLeg(peer);
      final RTCPeerConnection connection = leg.connection!;
      final MediaStream local = _localStream!;
      for (final MediaStreamTrack track in local.getAudioTracks()) {
        await connection.addTrack(track, local);
      }
      final MediaStreamTrack? camera = _cameraTrack;
      if (camera != null) {
        await connection.addTrack(camera, local);
      } else {
        // A video slot from the start: turning the camera on later is then a
        // track swap, never a renegotiation.
        await connection.addTransceiver(
          kind: RTCRtpMediaType.RTCRtpMediaTypeVideo,
          init: RTCRtpTransceiverInit(
            direction: TransceiverDirection.SendRecv,
            streams: <MediaStream>[local],
          ),
        );
      }
      // The screen slot, the second video section: carries the shared
      // screen whenever this side shares, on top of the camera.
      final MediaStream? screen = _screenStream;
      final MediaStreamTrack? screenTrack = _screenTrack;
      final RTCRtpTransceiverInit screenInit = RTCRtpTransceiverInit(
        direction: TransceiverDirection.SendRecv,
        streams: screen == null ? <MediaStream>[] : <MediaStream>[screen],
      );
      if (screenTrack == null) {
        await connection.addTransceiver(
          kind: RTCRtpMediaType.RTCRtpMediaTypeVideo,
          init: screenInit,
        );
      } else {
        await connection.addTransceiver(
          track: screenTrack,
          kind: RTCRtpMediaType.RTCRtpMediaTypeVideo,
          init: screenInit,
        );
      }
      final RTCSessionDescription offer = _forceVideoSendRecv(
        await connection.createOffer(_offerConstraints()),
      );
      await connection.setLocalDescription(offer);
      _captureMids(leg, offer.sdp);
      leg.exchange = DateTime.now().microsecondsSinceEpoch;
      leg.lastOffer = <String, dynamic>{
        'sdp': offer.sdp,
        'type': offer.type,
        'exchange': leg.exchange,
      };
      leg.awaitingAnswer = true;
      await _send(peer, 'gc_offer', leg.lastOffer!);
    });
  }

  @override
  Future<void> resendOffer(String peer) {
    return _serial(peer, () async {
      final _GroupLeg? leg = _legs[peer];
      if (leg == null || !leg.awaitingAnswer || leg.lastOffer == null) {
        return;
      }
      await _send(peer, 'gc_offer', leg.lastOffer!);
    });
  }

  @override
  Future<void> handleOffer(String peer, Map<String, dynamic> description) {
    return _serial(peer, () async {
      if (_callId == null) {
        return;
      }
      final String sdp = description['sdp'] as String? ?? '';
      final int exchange = (description['exchange'] as num?)?.toInt() ?? 0;
      final _GroupLeg? existing = _legs[peer];
      if (existing != null &&
          existing.lastRemoteOfferSdp == sdp &&
          existing.lastAnswer != null) {
        // A repeat: our answer got lost on the way.
        await _send(peer, 'gc_answer', existing.lastAnswer!);
        return;
      }
      if (existing != null && exchange != 0 && exchange < existing.exchange) {
        // A late copy of an offer this leg already moved past.
        return;
      }
      if (existing != null) {
        // A new offer means a new session from their side.
        await _closeLeg(existing);
      }
      final _GroupLeg leg = await _createLeg(peer);
      leg.exchange = exchange;
      final RTCPeerConnection connection = leg.connection!;
      await _setRemote(leg, description);
      leg.lastRemoteOfferSdp = sdp;
      await _bindLocalTracks(leg);
      final RTCSessionDescription answer = _forceVideoSendRecv(
        await connection.createAnswer(_offerConstraints()),
      );
      await connection.setLocalDescription(answer);
      _captureMids(leg, answer.sdp);
      await _ensureRelayCandidate(leg);
      leg.lastAnswer = <String, dynamic>{
        'sdp': answer.sdp,
        'type': answer.type,
        'exchange': exchange,
      };
      await _send(peer, 'gc_answer', leg.lastAnswer!);
    });
  }

  @override
  Future<void> handleAnswer(String peer, Map<String, dynamic> description) {
    return _serial(peer, () async {
      final _GroupLeg? leg = _legs[peer];
      if (leg == null || !leg.awaitingAnswer || leg.connection == null) {
        return;
      }
      final int exchange = (description['exchange'] as num?)?.toInt() ?? 0;
      if (exchange != 0 && exchange != leg.exchange) {
        // The answer to an offer from a leg that has since been rebuilt.
        return;
      }
      await _setRemote(leg, description);
      leg.awaitingAnswer = false;
      await _ensureRelayCandidate(leg);
    });
  }

  Future<void> _setRemote(
    _GroupLeg leg,
    Map<String, dynamic> description,
  ) async {
    final RTCPeerConnection connection = leg.connection!;
    final String sdp = description['sdp'] as String? ?? '';
    final String type = description['type'] as String? ?? 'offer';
    _captureMids(leg, sdp);
    // Never the peer's original SDP (see applyRemoteSdpViaLocalRelay): when
    // even the stripped form is refused this throws, and `_serial` marks the
    // leg failed.
    await applyRemoteSdpViaLocalRelay(
      sdp: sdp,
      type: type,
      relayPort: leg.relayPort,
      apply: (String value, String kind) =>
          connection.setRemoteDescription(RTCSessionDescription(value, kind)),
      label: 'group call',
    );
    leg.remoteDescriptionSet = true;
  }

  /// Puts the microphone (and camera, when on) on the answering side's
  /// transceivers, all of them send-and-receive.
  Future<void> _bindLocalTracks(_GroupLeg leg) async {
    final RTCPeerConnection connection = leg.connection!;
    final MediaStream local = _localStream!;
    final List<MediaStreamTrack> audio = local.getAudioTracks();
    bool audioBound = false;
    for (final RTCRtpTransceiver transceiver
        in await connection.getTransceivers()) {
      final int slot = _videoSlot(leg, transceiver);
      final bool isVideo = slot >= 0;
      final MediaStream? screen = _screenStream;
      try {
        await transceiver.setDirection(TransceiverDirection.SendRecv);
      } catch (error) {
        logZenWarning('Setting a group transceiver direction failed: $error');
      }
      if (slot != _screenSlot || screen != null) {
        try {
          await transceiver.sender.setStreams(<MediaStream>[
            if (slot == _screenSlot) screen! else local,
          ]);
        } catch (_) {
          // Older platforms: the stream id only matters for grouping.
        }
      }
      final MediaStreamTrack? track = isVideo
          ? _outgoingVideo(slot)
          : (audio.isEmpty ? null : audio.first);
      if (track == null) {
        continue;
      }
      await transceiver.sender.replaceTrack(track);
      if (!isVideo) {
        audioBound = true;
      }
    }
    if (!audioBound && audio.isNotEmpty) {
      await connection.addTrack(audio.first, local);
    }
  }

  /// Which video slot [transceiver] is ([_cameraSlot], [_screenSlot]), or
  /// -1 for audio. By the order of the video sections in the negotiated
  /// SDP; a mid not seen there yet counts as the camera's.
  int _videoSlot(_GroupLeg leg, RTCRtpTransceiver transceiver) {
    final int slot = _videoSlotOfMid(leg, transceiver.mid);
    if (slot != -2) {
      return slot;
    }
    return transceiver.sender.track?.kind == 'video' ||
            transceiver.receiver.track?.kind == 'video'
        ? _cameraSlot
        : -1;
  }

  /// The video slot of [mid] (-1 for audio), or -2 when the leg's SDP does
  /// not name it.
  int _videoSlotOfMid(_GroupLeg leg, String mid) {
    final List<({String mid, int mLineIndex, String kind})> sections =
        List<({String mid, int mLineIndex, String kind})>.from(leg.mids)..sort(
          (
            ({String mid, int mLineIndex, String kind}) a,
            ({String mid, int mLineIndex, String kind}) b,
          ) => a.mLineIndex.compareTo(b.mLineIndex),
        );
    int videoIndex = 0;
    for (final ({String mid, int mLineIndex, String kind}) entry in sections) {
      if (entry.mid == mid) {
        return entry.kind == 'video' ? videoIndex : -1;
      }
      if (entry.kind == 'video') {
        videoIndex += 1;
      }
    }
    return -2;
  }

  void _captureMids(_GroupLeg leg, String? sdp) {
    if (sdp == null || sdp.isEmpty) {
      return;
    }
    int index = -1;
    String kind = '';
    for (final String raw in sdp.split(RegExp(r'\r?\n'))) {
      final String line = raw.trim();
      if (line.startsWith('m=')) {
        index += 1;
        kind = line.substring(2).split(' ').first;
        continue;
      }
      if (index >= 0 && line.startsWith('a=mid:')) {
        final String mid = line.substring('a=mid:'.length).trim();
        if (mid.isNotEmpty &&
            !leg.mids.any(
              (({String mid, int mLineIndex, String kind}) m) => m.mid == mid,
            )) {
          leg.mids.add((mid: mid, mLineIndex: index, kind: kind));
        }
      }
    }
  }

  /// Points every media section at the local relay port: on loopback, and
  /// on the host address WebRTC gathered (some platforms skip loopback). The
  /// host address shows up with the first ICE candidates, so this runs again
  /// from `onIceCandidate` and only adds what is new.
  Future<void> _ensureRelayCandidate(_GroupLeg leg) async {
    final RTCPeerConnection? connection = leg.connection;
    if (connection == null ||
        leg.closed ||
        !leg.remoteDescriptionSet ||
        leg.relayPort <= 0 ||
        leg.mids.isEmpty) {
      return;
    }
    final List<String> hosts = <String>[
      '127.0.0.1',
      if (leg.localCandidateIp?.isNotEmpty ?? false) leg.localCandidateIp!,
    ].where((String host) => !leg.relayHosts.contains(host)).toList();
    leg.relayHosts.addAll(hosts);
    for (final String host in hosts) {
      for (final ({String mid, int mLineIndex, String kind}) entry
          in leg.mids) {
        if (leg.closed) {
          return;
        }
        try {
          await connection.addCandidate(
            RTCIceCandidate(
              'candidate:relay 1 udp 2130706431 $host ${leg.relayPort} typ host generation 0',
              entry.mid,
              entry.mLineIndex,
            ),
          );
        } catch (error) {
          logZenWarning('Adding a group relay candidate failed: $error');
        }
      }
    }
  }

  Future<void> _send(
    String peer,
    String type,
    Map<String, dynamic> description,
  ) async {
    final GroupCallSignalSender? sender = sendSignal;
    if (sender == null || _callId == null) {
      return;
    }
    await sender(peer, <String, dynamic>{
      'type': type,
      'callId': _callId,
      'groupId': _groupId,
      'kind': _kind.name,
      'description': description,
    });
  }

  @override
  Future<void> dropPeer(String peer) {
    return _serial(peer, () async {
      final _GroupLeg? leg = _legs[peer];
      if (leg != null) {
        await _closeLeg(leg);
      }
      _remoteCamera.remove(peer);
      _notify();
    });
  }

  Future<void> _closeLeg(_GroupLeg leg) async {
    leg.closed = true;
    leg.disconnectTimer?.cancel();
    leg.disconnectTimer = null;
    if (identical(_legs[leg.peer], leg)) {
      _legs.remove(leg.peer);
      _recordingPeers.remove(leg.peer);
    }
    final RTCPeerConnection? connection = leg.connection;
    leg.connection = null;
    try {
      connection?.onIceCandidate = null;
      connection?.onTrack = null;
      connection?.onConnectionState = null;
      await connection?.close();
      await connection?.dispose();
    } catch (error, stackTrace) {
      logZenError('Closing a group call leg failed', error, stackTrace);
    }
    final RTCVideoRenderer? renderer = leg.renderer;
    leg.renderer = null;
    if (renderer != null) {
      try {
        renderer.srcObject = null;
        await renderer.dispose();
      } catch (_) {
        // Already gone with the connection.
      }
    }
    final RTCVideoRenderer? screenRenderer = leg.screenRenderer;
    leg.screenRenderer = null;
    if (screenRenderer != null) {
      try {
        screenRenderer.srcObject = null;
        await screenRenderer.dispose();
      } catch (_) {
        // Already gone with the connection.
      }
    }
    leg.remoteStream = null;
    for (final MediaStream? video in <MediaStream?>[
      leg.videoStream,
      leg.screenStream,
    ]) {
      if (video == null) {
        continue;
      }
      try {
        await video.dispose();
      } catch (_) {
        // Released with the connection already.
      }
    }
    leg.videoStream = null;
    leg.screenStream = null;
    try {
      await transport.closeRelay(leg.relayId);
    } catch (error, stackTrace) {
      logZenError('Closing a group call relay failed', error, stackTrace);
    }
  }

  @override
  void setRemoteCamera(String peer, bool on) {
    if (_remoteCamera[peer] == on) {
      return;
    }
    _remoteCamera[peer] = on;
    _notify();
  }

  @override
  Future<void> setMuted(bool muted) async {
    _muted = muted;
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
      logZenError('Switching the group call speaker failed', error, stackTrace);
    }
  }

  @override
  Future<void> setCameraEnabled(bool enabled) async {
    final MediaStream? local = _localStream;
    if (local == null) {
      throw StateError(t('Brak aktywnego połączenia grupowego.'));
    }
    if (enabled) {
      if (_cameraTrack != null) {
        return;
      }
      MediaStream camera;
      try {
        camera = await navigator.mediaDevices.getUserMedia(<String, dynamic>{
          'audio': false,
          'video': _buildVideoConstraints(),
        });
      } catch (_) {
        camera = await navigator.mediaDevices.getUserMedia(<String, dynamic>{
          'audio': false,
          'video': true,
        });
      }
      final List<MediaStreamTrack> tracks = camera.getVideoTracks();
      if (tracks.isEmpty) {
        await _stopStream(camera);
        throw StateError(t('Kamera jest niedostępna.'));
      }
      final MediaStreamTrack track = tracks.first;
      await local.addTrack(track);
      _cameraTrack = track;
      await _ensureLocalRenderer();
      _localRenderer?.srcObject = local;
      for (final _GroupLeg leg in _legs.values.toList()) {
        await _replaceVideo(leg, track, local, slot: _cameraSlot);
      }
    } else {
      final MediaStreamTrack? track = _cameraTrack;
      _cameraTrack = null;
      for (final _GroupLeg leg in _legs.values.toList()) {
        await _replaceVideo(leg, null, local, slot: _cameraSlot);
      }
      if (track != null) {
        try {
          await local.removeTrack(track);
          await track.stop();
        } catch (error) {
          logZenWarning('Stopping the group call camera failed: $error');
        }
      }
      _localRenderer?.srcObject = null;
    }
    _notify();
  }

  /// Puts [track] (null: nothing) on video slot [slot] of [leg], grouped
  /// under [stream].
  Future<void> _replaceVideo(
    _GroupLeg leg,
    MediaStreamTrack? track,
    MediaStream stream, {
    required int slot,
  }) async {
    final RTCPeerConnection? connection = leg.connection;
    if (connection == null || leg.closed) {
      return;
    }
    try {
      for (final RTCRtpTransceiver transceiver
          in await connection.getTransceivers()) {
        if (_videoSlot(leg, transceiver) != slot) {
          continue;
        }
        if (track != null) {
          try {
            await transceiver.sender.setStreams(<MediaStream>[stream]);
          } catch (_) {
            // Grouping only.
          }
        }
        await transceiver.sender.replaceTrack(track);
        return;
      }
    } catch (error, stackTrace) {
      logZenError('Swapping the group call camera failed', error, stackTrace);
    }
  }

  @override
  Future<void> switchCamera() async {
    final MediaStreamTrack? track = _cameraTrack;
    if (track == null) {
      return;
    }
    try {
      await Helper.switchCamera(track);
    } catch (error) {
      logZenWarning('Switching the group call camera failed: $error');
    }
  }

  Future<void> _stopStream(MediaStream? stream) async {
    if (stream == null) {
      return;
    }
    for (final MediaStreamTrack track in List<MediaStreamTrack>.from(
      stream.getTracks(),
    )) {
      try {
        await track.stop();
      } catch (_) {
        // Already stopped.
      }
    }
    try {
      await stream.dispose();
    } catch (_) {
      // Already released.
    }
  }

  @override
  Future<void> close() async {
    // The call ends: a recording still running is finished and kept.
    await _finishRecording(tell: false);
    _recordingPeers.clear();
    final MediaStream? screen = _screenStream;
    _screenStream = null;
    _screenTrack = null;
    _remoteScreens.clear();
    if (screen != null) {
      androidScreenCaptureActive.value = false;
      screenShareHidesNotifications.value = false;
      await _stopStream(screen);
    }
    _generation += 1;
    _callId = null;
    final List<_GroupLeg> legs = _legs.values.toList();
    _legs.clear();
    _remoteCamera.clear();
    _peerOps.clear();
    for (final _GroupLeg leg in legs) {
      await _closeLeg(leg);
    }
    final MediaStream? local = _localStream;
    _localStream = null;
    _cameraTrack = null;
    if (_localRendererReady) {
      try {
        _localRenderer?.srcObject = null;
      } catch (_) {
        // Renderer already released.
      }
    }
    await _stopStream(local);
    if (_muted) {
      _muted = false;
    }
    _notify();
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(_frames?.cancel());
    unawaitedLogged(_shutdown(), context: 'Group call media dispose failed');
    super.dispose();
  }

  Future<void> _shutdown() async {
    await close();
    final RTCVideoRenderer? renderer = _localRenderer;
    _localRenderer = null;
    if (renderer != null && _localRendererReady) {
      _localRendererReady = false;
      try {
        await renderer.dispose();
      } catch (_) {
        // Already released.
      }
    }
  }
}

RTCSessionDescription _forceVideoSendRecv(RTCSessionDescription description) {
  final String sdp = description.sdp ?? '';
  if (sdp.isEmpty) {
    return description;
  }
  final String separator = sdp.contains('\r\n') ? '\r\n' : '\n';
  final List<String> result = <String>[];
  bool inVideo = false;
  bool directionSeen = false;
  for (final String raw in sdp.split(RegExp(r'\r?\n'))) {
    final String line = raw.trim();
    if (line.startsWith('m=')) {
      if (inVideo && !directionSeen) {
        result.add('a=sendrecv');
      }
      inVideo = line.startsWith('m=video');
      directionSeen = false;
      result.add(raw);
      continue;
    }
    if (inVideo &&
        (line == 'a=recvonly' ||
            line == 'a=sendonly' ||
            line == 'a=inactive' ||
            line == 'a=sendrecv')) {
      result.add('a=sendrecv');
      directionSeen = true;
      continue;
    }
    result.add(raw);
  }
  if (inVideo && !directionSeen) {
    result.add('a=sendrecv');
  }
  // A trailing empty line is part of the SDP grammar; keep the original end.
  return RTCSessionDescription(result.join(separator), description.type);
}
