import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/domain/calls/call_invite_kind.dart';
import 'package:zen/src/features/calls/call_media_e2ee.dart';
import 'package:zen/src/features/calls/call_media_session.dart';
import 'package:zen/src/features/calls/call_recorder.dart';
import 'package:zen/src/features/calls/call_video_codecs.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';

// The call's media against flutter_webrtc's Android side as it behaves
// (PeerConnectionObserver, MethodCallHandlerImpl, FlutterRTCVideoRenderer
// of flutter_webrtc 1.6.3), down to the order in which the platform
// registers the other side's tracks and stream and tells Dart about them:
//
// - For each track: the plan-B `onAddTrack` event goes to Dart first, then
//   the track is registered (`remoteTracks`), then `onTrack` goes to Dart.
// - Only after every track: the stream is registered (`remoteStreams`) and
//   `onAddStream` goes to Dart.
// - A renderer bound by stream (`srcObject = stream`) looks the stream up in
//   `remoteStreams` and draws its first video track; a stream not there yet
//   gives it nothing to draw, without an error. Bound by track
//   (`setSrcObject(trackId:)`) it takes the registered track; a track not
//   registered yet comes from the transceiver listing, whose next call
//   disposes it with every renderer on it.
//
// On the phone that native thread runs beside Dart: whether it registers
// the stream before Dart binds the renderer is a race. Here it is made to
// lose ([_AndroidWebRtc.nativeLagsBehind]), as it did in the calls whose
// frames were decoded and never shown.

const String _peer = '200:1111:2222:3333:4444:5555:6666:7777';

/// No frame encryption here: DTLS-SRTP only.
final class _NoFrameCrypto implements MediaFrameCryptoBackend {
  const _NoFrameCrypto();

  @override
  Future<MediaKeyRing?> openKeyRing() async => null;
}

Future<void> _settle() async {
  for (int i = 0; i < 60; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

final class _Track {
  _Track(this.id, this.kind, {this.remote = false});

  final String id;
  final String kind;
  final bool remote;

  Map<String, Object?> map() => <String, Object?>{
    'id': id,
    'label': kind,
    'kind': kind,
    'enabled': true,
    'readyState': 'live',
    'remote': remote,
  };
}

final class _Slot {
  _Slot(this.id, this.kind, this.receiver);

  final String id;
  final String kind;
  final _Track receiver;
  String? mid;
  String direction = 'sendrecv';
  _Track? sender;

  static Map<String, Object?> parameters(String kind) => <String, Object?>{
    'transactionId': 't',
    'rtcp': <String, Object?>{'cname': 'c', 'reducedSize': true},
    'headerExtensions': <Object?>[],
    'encodings': <Object?>[
      <String, Object?>{
        'active': true,
        'priority': 'low',
        'networkPriority': 'low',
      },
    ],
    'codecs': <Object?>[],
    'degradationPreference': 'balanced',
  };

  Map<String, Object?> senderMap() => <String, Object?>{
    'senderId': 'sender-$id',
    'ownsTrack': true,
    'rtpParameters': parameters(kind),
    'track': sender?.map() ?? <String, Object?>{},
  };

  Map<String, Object?> receiverMap() => <String, Object?>{
    'receiverId': 'receiver-$id',
    'track': receiver.map(),
    'rtpParameters': parameters(kind),
  };

  Map<String, Object?> map() => <String, Object?>{
    'transceiverId': id,
    'mid': mid ?? '',
    'direction': direction,
    'sender': senderMap(),
    'receiver': receiverMap(),
  };
}

final class _AndroidWebRtc {
  _AndroidWebRtc({this.nativeLagsBehind = true});

  /// Dart handles each event before the native thread goes on (registers
  /// the track, the stream): the order the black calls had.
  final bool nativeLagsBehind;

  /// This many of the next bindings of a renderer to the other side's
  /// camera draw nothing, as if their sink were lost.
  int loseRemoteBinds = 0;

  static const MethodChannel _method = MethodChannel('FlutterWebRTC.Method');
  static const String _stream = 'their-stream';

  TestDefaultBinaryMessenger get _messenger =>
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  final Map<String, MockStreamHandlerEventSink> _sinks =
      <String, MockStreamHandlerEventSink>{};
  final List<String> _eventChannels = <String>[];
  int _nextTexture = 1;
  int _nextId = 1;
  String? _pc;

  final Map<String, List<_Track>> _localStreams = <String, List<_Track>>{};
  final Map<String, _Track> _localTracks = <String, _Track>{};
  final Map<String, List<_Track>> _remoteStreams = <String, List<_Track>>{};
  final Map<String, _Track> _remoteTracks = <String, _Track>{};
  final List<_Slot> _slots = <_Slot>[];
  final _Track _theirAudio = _Track('their-audio', 'audio', remote: true);
  final _Track _theirVideo = _Track('their-video', 'video', remote: true);

  /// What each renderer (by texture) draws: the id of its track, or null.
  final Map<int, String?> drawn = <int, String?>{};
  final Set<int> _drawnFromListing = <int>{};

  /// How many times each renderer was bound.
  final Map<int, int> binds = <int, int>{};

  /// Every remote description applied, as given to the platform.
  final List<String> appliedRemote = <String>[];
  bool _connected = false;
  int _framesDecoded = 0;

  void install() {
    _messenger.setMockMethodCallHandler(_method, _handle);
    _listen('FlutterWebRTC.Event');
  }

  void uninstall() {
    _messenger.setMockMethodCallHandler(_method, null);
    for (final String name in _eventChannels) {
      _messenger.setMockStreamHandler(EventChannel(name), null);
    }
  }

  void _listen(String name) {
    _eventChannels.add(name);
    _messenger.setMockStreamHandler(
      EventChannel(name),
      MockStreamHandler.inline(
        onListen: (Object? arguments, MockStreamHandlerEventSink events) {
          _sinks[name] = events;
        },
        onCancel: (Object? arguments) {
          _sinks.remove(name);
        },
      ),
    );
  }

  void _emit(String channel, Map<String, Object?> event) {
    _sinks[channel]?.success(event);
  }

  String get _pcChannel => 'FlutterWebRTC/peerConnectionEvent$_pc';

  /// The media connect: the other side's frames start coming in.
  Future<void> connect() async {
    _connected = true;
    _emit(_pcChannel, <String, Object?>{
      'event': 'peerConnectionState',
      'state': 'connected',
    });
    for (final MapEntry<int, String?> entry in drawn.entries) {
      if (entry.value == _theirVideo.id) {
        _firstFrame(entry.key);
      }
    }
    await _settle();
  }

  void _firstFrame(int texture) {
    _emit('FlutterWebRTC/Texture$texture', <String, Object?>{
      'event': 'didFirstFrameRendered',
      'id': texture,
    });
  }

  _Slot _slotFor(String kind) {
    for (final _Slot slot in _slots) {
      if (slot.kind == kind && slot.sender == null) {
        return slot;
      }
    }
    final _Slot slot = _Slot(
      'tr${_nextId++}',
      kind,
      kind == 'audio' ? _theirAudio : _theirVideo,
    );
    _slots.add(slot);
    return slot;
  }

  _Slot? _slot(Object? id) {
    for (final _Slot slot in _slots) {
      if (slot.id == id || (slot.mid != null && slot.mid == id)) {
        return slot;
      }
    }
    return null;
  }

  /// The SDP this side makes: VP8 and H.264, the camera's direction.
  String _ownSdp() {
    String direction = 'sendrecv';
    for (final _Slot slot in _slots) {
      if (slot.kind == 'video') {
        direction = slot.direction;
      }
    }
    return <String>[
      'v=0',
      'o=- 1 2 IN IP4 127.0.0.1',
      's=-',
      't=0 0',
      'a=group:BUNDLE 0 1',
      'm=audio 9 UDP/TLS/RTP/SAVPF 111',
      'c=IN IP4 0.0.0.0',
      'a=ice-ufrag:abcd',
      'a=ice-pwd:efghijklmnopqrstuvwxyz12',
      'a=mid:0',
      'a=sendrecv',
      'a=rtpmap:111 opus/48000/2',
      'm=video 9 UDP/TLS/RTP/SAVPF 96 97 102 103',
      'c=IN IP4 0.0.0.0',
      'a=ice-ufrag:abcd',
      'a=ice-pwd:efghijklmnopqrstuvwxyz12',
      'a=mid:1',
      'a=$direction',
      'a=rtpmap:96 VP8/90000',
      'a=rtpmap:97 rtx/90000',
      'a=fmtp:97 apt=96',
      'a=rtpmap:102 H264/90000',
      'a=fmtp:102 level-asymmetry-allowed=1;packetization-mode=1;'
          'profile-level-id=42e01f',
      'a=rtpmap:103 rtx/90000',
      'a=fmtp:103 apt=102',
      '',
    ].join('\r\n');
  }

  /// The other side's tracks as the platform reports them while their
  /// description is applied.
  Future<void> _announceTheirTracks() async {
    final Map<String, Object?> stream = <String, Object?>{
      'streamId': _stream,
      'ownerTag': _pc,
      'audioTracks': <Object?>[_theirAudio.map()],
      'videoTracks': <Object?>[_theirVideo.map()],
    };
    if (!nativeLagsBehind) {
      _remoteTracks[_theirAudio.id] = _theirAudio;
      _remoteTracks[_theirVideo.id] = _theirVideo;
      _remoteStreams[_stream] = <_Track>[_theirAudio, _theirVideo];
    }
    for (final _Slot slot in List<_Slot>.from(_slots)) {
      final _Track track = slot.receiver;
      _emit(_pcChannel, <String, Object?>{
        'event': 'onAddTrack',
        'streamId': _stream,
        'ownerTag': _pc,
        'trackId': track.id,
        'track': track.map(),
      });
      if (nativeLagsBehind) {
        await _settle();
      }
      _remoteTracks[track.id] = track;
      _emit(_pcChannel, <String, Object?>{
        'event': 'onTrack',
        'streams': <Object?>[stream],
        'track': track.map(),
        'receiver': slot.receiverMap(),
        'transceiver': slot.map(),
      });
      if (nativeLagsBehind) {
        await _settle();
      }
    }
    _remoteStreams[_stream] = <_Track>[_theirAudio, _theirVideo];
    _emit(_pcChannel, <String, Object?>{
      'event': 'onAddStream',
      'streamId': _stream,
      'ownerTag': _pc,
      'audioTracks': <Object?>[_theirAudio.map()],
      'videoTracks': <Object?>[_theirVideo.map()],
    });
    await _settle();
  }

  void _bindRenderer(
    int texture,
    String streamId,
    String ownerTag,
    String? trackId,
  ) {
    binds[texture] = (binds[texture] ?? 0) + 1;
    final List<_Track>? stream = ownerTag == 'local'
        ? _localStreams[streamId]
        : _remoteStreams[streamId] ?? _localStreams[streamId];
    _Track? track;
    bool fromListing = false;
    _Track? firstVideo(List<_Track>? tracks) {
      for (final _Track t in tracks ?? const <_Track>[]) {
        if (t.kind == 'video') {
          return t;
        }
      }
      return null;
    }

    if (trackId != null && trackId != '0') {
      track = _localTracks[trackId] ?? _remoteTracks[trackId];
      if (track == null) {
        for (final _Slot slot in _slots) {
          if (slot.receiver.id == trackId) {
            track = slot.receiver;
            fromListing = true;
          }
        }
      }
      if (track == null || track.kind != 'video') {
        fromListing = false;
        track = firstVideo(stream);
      }
    } else {
      track = firstVideo(stream);
    }
    if (loseRemoteBinds > 0 && track != null && track.remote) {
      loseRemoteBinds -= 1;
      track = null;
    }
    drawn[texture] = track?.id;
    if (fromListing) {
      _drawnFromListing.add(texture);
    } else {
      _drawnFromListing.remove(texture);
    }
    if (track != null && (!track.remote || _connected)) {
      _firstFrame(texture);
    }
  }

  List<Object?> _stats() {
    if (_connected) {
      _framesDecoded += 30;
    }
    return <Object?>[
      <String, Object?>{
        'id': 'C1',
        'type': 'codec',
        'timestamp': 0,
        'values': <String, Object?>{'mimeType': 'video/VP8'},
      },
      <String, Object?>{
        'id': 'O1',
        'type': 'outbound-rtp',
        'timestamp': 0,
        'values': <String, Object?>{
          'kind': 'video',
          'codecId': 'C1',
          'framesEncoded': 40,
          'encoderImplementation': 'libvpx',
        },
      },
      if (_connected)
        <String, Object?>{
          'id': 'I1',
          'type': 'inbound-rtp',
          'timestamp': 0,
          'values': <String, Object?>{
            'kind': 'video',
            'codecId': 'C1',
            'trackIdentifier': _theirVideo.id,
            'framesDecoded': _framesDecoded,
            'decoderImplementation': 'libvpx',
          },
        },
    ];
  }

  Future<Object?> _handle(MethodCall call) async {
    final Map<dynamic, dynamic> a =
        (call.arguments as Map<dynamic, dynamic>?) ??
        const <dynamic, dynamic>{};
    switch (call.method) {
      case 'createVideoRenderer':
        final int texture = _nextTexture++;
        _listen('FlutterWebRTC/Texture$texture');
        drawn[texture] = null;
        return <String, Object?>{'textureId': texture};
      case 'videoRendererSetSrcObject':
        _bindRenderer(
          a['textureId'] as int,
          a['streamId'] as String? ?? '',
          a['ownerTag'] as String? ?? '',
          a['trackId'] as String?,
        );
        return null;
      case 'createPeerConnection':
        _pc = 'pc${_nextId++}';
        _listen(_pcChannel);
        return <String, Object?>{'peerConnectionId': _pc};
      case 'getUserMedia':
        final Map<dynamic, dynamic> constraints =
            a['constraints'] as Map<dynamic, dynamic>;
        final String id = 'mine-${_nextId++}';
        final List<_Track> tracks = <_Track>[
          _Track('mic-${_nextId++}', 'audio'),
          if (constraints['video'] != false)
            _Track('cam-${_nextId++}', 'video'),
        ];
        _localStreams[id] = tracks;
        for (final _Track track in tracks) {
          _localTracks[track.id] = track;
        }
        return <String, Object?>{
          'streamId': id,
          'audioTracks': <Object?>[
            for (final _Track t in tracks)
              if (t.kind == 'audio') t.map(),
          ],
          'videoTracks': <Object?>[
            for (final _Track t in tracks)
              if (t.kind == 'video') t.map(),
          ],
        };
      case 'createLocalMediaStream':
        final String id = 'mine-${_nextId++}';
        _localStreams[id] = <_Track>[];
        return <String, Object?>{'streamId': id};
      case 'mediaStreamAddTrack':
        final List<_Track>? stream = _localStreams[a['streamId']];
        final _Track? track =
            _localTracks[a['trackId']] ?? _remoteTracks[a['trackId']];
        if (stream == null || track == null) {
          throw PlatformException(code: 'mediaStreamAddTrack');
        }
        stream.add(track);
        return null;
      case 'mediaStreamRemoveTrack':
        _localStreams[a['streamId']]?.removeWhere(
          (_Track t) => t.id == a['trackId'],
        );
        return null;
      case 'addTrack':
        final _Track track = _localTracks[a['trackId']]!;
        final _Slot slot = _slotFor(track.kind)..sender = track;
        return slot.senderMap();
      case 'addTransceiver':
        final String kind = a['mediaType'] as String? ?? 'video';
        final _Slot slot = _slotFor(kind);
        final Map<dynamic, dynamic>? init =
            a['transceiverInit'] as Map<dynamic, dynamic>?;
        slot.direction = init?['direction'] as String? ?? 'sendrecv';
        final Object? trackId = a['trackId'];
        if (trackId != null) {
          slot.sender = _localTracks[trackId];
        }
        return slot.map();
      case 'getTransceivers':
        // A new listing disposes the receivers of the one before, and the
        // renderers on their tracks lose their picture.
        for (final int texture in _drawnFromListing) {
          drawn[texture] = null;
        }
        _drawnFromListing.clear();
        return <String, Object?>{
          'transceivers': <Object?>[for (final _Slot s in _slots) s.map()],
        };
      case 'getSenders':
        return <String, Object?>{
          'senders': <Object?>[for (final _Slot s in _slots) s.senderMap()],
        };
      case 'getReceivers':
        return <String, Object?>{
          'receivers': <Object?>[for (final _Slot s in _slots) s.receiverMap()],
        };
      case 'rtpTransceiverSetDirection':
        _slot(a['transceiverId'])?.direction = a['direction'] as String;
        return null;
      case 'rtpTransceiverGetDirection':
      case 'rtpTransceiverGetCurrentDirection':
        return <String, Object?>{
          'result': _slot(a['transceiverId'])?.direction ?? 'sendrecv',
        };
      case 'rtpSenderReplaceTrack':
        final String senderId = a['rtpSenderId'] as String? ?? '';
        for (final _Slot slot in _slots) {
          if ('sender-${slot.id}' == senderId) {
            slot.sender = _localTracks[a['trackId']];
          }
        }
        return null;
      case 'rtpSenderSetParameters':
        return <String, Object?>{'result': true};
      case 'getRtpReceiverCapabilities':
      case 'getRtpSenderCapabilities':
        return <String, Object?>{
          'codecs': <Object?>[
            <String, Object?>{'mimeType': 'video/H264', 'clockRate': 90000},
            <String, Object?>{'mimeType': 'video/VP8', 'clockRate': 90000},
            <String, Object?>{'mimeType': 'video/rtx', 'clockRate': 90000},
          ],
          'headerExtensions': <Object?>[],
          'fecMechanisms': <Object?>[],
        };
      case 'createOffer':
        return <String, Object?>{'sdp': _ownSdp(), 'type': 'offer'};
      case 'createAnswer':
        return <String, Object?>{'sdp': _ownSdp(), 'type': 'answer'};
      case 'setLocalDescription':
        for (final _Slot slot in _slots) {
          slot.mid ??= slot.kind == 'audio' ? '0' : '1';
        }
        return null;
      case 'setRemoteDescription':
        final Map<dynamic, dynamic> description =
            a['description'] as Map<dynamic, dynamic>;
        appliedRemote.add(description['sdp'] as String);
        final bool offer = description['type'] == 'offer';
        if (_slots.isEmpty) {
          // The answering side: the offer makes the transceivers.
          _slotFor('audio')
            ..mid = '0'
            ..direction = 'recvonly';
          _slotFor('video')
            ..mid = '1'
            ..direction = 'recvonly';
        }
        if (offer || appliedRemote.length == 1) {
          await _announceTheirTracks();
        }
        return null;
      case 'getStats':
        return <String, Object?>{'stats': _stats()};
      default:
        return null;
    }
  }
}

/// The other side's description: its camera sends; [h264First] lists its
/// codecs as the offer of a phone whose preferences did not take did
/// (`H264 H265 VP8 AV1 VP9`).
String _theirSdp(String type, {bool h264First = false}) => <String>[
  'v=0',
  'o=- 9 2 IN IP4 127.0.0.1',
  's=-',
  't=0 0',
  'a=group:BUNDLE 0 1',
  'a=msid-semantic: WMS their-stream',
  'm=audio 9 UDP/TLS/RTP/SAVPF 111',
  'c=IN IP4 0.0.0.0',
  'a=ice-ufrag:wxyz',
  'a=ice-pwd:abcdefghijklmnopqrstuvwx',
  'a=mid:0',
  'a=sendrecv',
  'a=msid:their-stream their-audio',
  'a=rtpmap:111 opus/48000/2',
  'a=ssrc:1001 cname:them',
  h264First
      ? 'm=video 9 UDP/TLS/RTP/SAVPF 102 103 39 96 97 45 98 99'
      : 'm=video 9 UDP/TLS/RTP/SAVPF 96 97 102 103',
  'c=IN IP4 0.0.0.0',
  'a=ice-ufrag:wxyz',
  'a=ice-pwd:abcdefghijklmnopqrstuvwx',
  'a=mid:1',
  'a=sendrecv',
  'a=msid:their-stream their-video',
  'a=rtpmap:102 H264/90000',
  'a=fmtp:102 level-asymmetry-allowed=1;packetization-mode=1;'
      'profile-level-id=42e01f',
  'a=rtpmap:103 rtx/90000',
  'a=fmtp:103 apt=102',
  if (h264First) 'a=rtpmap:39 H265/90000',
  'a=rtpmap:96 VP8/90000',
  'a=rtpmap:97 rtx/90000',
  'a=fmtp:97 apt=96',
  if (h264First) ...<String>[
    'a=rtpmap:45 AV1/90000',
    'a=rtpmap:98 VP9/90000',
    'a=rtpmap:99 rtx/90000',
    'a=fmtp:99 apt=98',
  ],
  'a=ssrc:2002 cname:them',
  '',
].join('\r\n');

WebRtcCallMediaSessionController _media(MemorySignalTransport transport) =>
    WebRtcCallMediaSessionController(
      transport: transport,
      recorder: const UnavailableCallRecorder(),
      frameCrypto: const _NoFrameCrypto(),
    );

int _offersSent(MemorySignalTransport transport) => transport.sentSignals
    .where(
      (({String remoteAddress, Map<String, dynamic> payload}) s) =>
          s.payload['type'] == 'offer',
    )
    .length;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _AndroidWebRtc platform;
  late MemorySignalTransport transport;
  late WebRtcCallMediaSessionController media;

  Future<void> start({bool nativeLagsBehind = true}) async {
    platform = _AndroidWebRtc(nativeLagsBehind: nativeLagsBehind)..install();
    transport = MemorySignalTransport()..relayPortResult = 40000;
    media = _media(transport);
  }

  tearDown(() async {
    await media.close();
    media.dispose();
    await _settle();
    platform.uninstall();
  });

  group('the other side\'s camera reaches the screen', () {
    for (final bool lags in <bool>[true, false]) {
      test(
        'calling: the renderer draws their camera '
        '(${lags ? 'Dart answers before the platform registered their '
                  'stream' : 'the platform registered everything first'})',
        () async {
          await start(nativeLagsBehind: lags);
          await media.startOutgoing(
            callId: 'call-1',
            remoteAddress: _peer,
            kind: CallInviteKind.video,
          );
          await media.applyRemoteAnswer(<String, dynamic>{
            'type': 'answer',
            'sdp': _theirSdp('answer'),
          });
          await platform.connect();
          final int texture = media.remoteRenderer!.textureId!;
          expect(platform.drawn[texture], 'their-video');
          expect(media.remoteRenderer!.srcObject, isNotNull);
        },
      );
    }

    test('answering: the renderer draws their camera, and keeps drawing it '
        'when the transceivers are listed again', () async {
      await start();
      await media.acceptIncoming(
        callId: 'call-2',
        remoteAddress: _peer,
        kind: CallInviteKind.video,
        remoteDescription: <String, dynamic>{
          'type': 'offer',
          'sdp': _theirSdp('offer'),
        },
      );
      await platform.connect();
      final int texture = media.remoteRenderer!.textureId!;
      expect(platform.drawn[texture], 'their-video');
      // A listing of the transceivers (codec preferences, statistics) must
      // not take the picture away.
      await media.dumpDiagnostics();
      expect(platform.drawn[texture], 'their-video');
    });

    test('frames decoded and none on the screen: the renderer is bound to '
        'their track again', () async {
      await start(nativeLagsBehind: false);
      // Every binding while their description is applied comes to
      // nothing: only the watch is left to bring the picture.
      platform.loseRemoteBinds = 2;
      await media.startOutgoing(
        callId: 'call-3',
        remoteAddress: _peer,
        kind: CallInviteKind.video,
      );
      await media.applyRemoteAnswer(<String, dynamic>{
        'type': 'answer',
        'sdp': _theirSdp('answer'),
      });
      final int texture = media.remoteRenderer!.textureId!;
      expect(platform.drawn[texture], isNot('their-video'));
      await platform.connect();
      expect(platform.drawn[texture], isNot('their-video'));
      final int bindsBefore = platform.binds[texture] ?? 0;
      await Future<void>.delayed(
        kRemotePictureLookInterval + const Duration(milliseconds: 600),
      );
      await _settle();
      expect(platform.drawn[texture], 'their-video');
      expect(platform.binds[texture], greaterThan(bindsBefore));
    });
  });

  group('their codec order does not decide what this side sends', () {
    test('an offer that lists H.264 first is applied with VP8 first', () async {
      await start();
      await media.acceptIncoming(
        callId: 'call-4',
        remoteAddress: _peer,
        kind: CallInviteKind.video,
        remoteDescription: <String, dynamic>{
          'type': 'offer',
          'sdp': _theirSdp('offer', h264First: true),
        },
      );
      expect(platform.appliedRemote, hasLength(1));
      expect(firstVideoCodecInSdp(platform.appliedRemote.single), 'VP8');
      // Nothing else of their description changes but the order.
      expect(
        videoCodecsInSdp(platform.appliedRemote.single).toSet(),
        videoCodecsInSdp(_theirSdp('offer', h264First: true)).toSet(),
      );
      final String answer =
          (transport.sentSignals.last.payload['description']
                  as Map<String, dynamic>)['sdp']
              as String;
      final ({String? offererSends, String? answererSends}) codecs =
          negotiatedVideoCodecs(
            offer: platform.appliedRemote.single,
            answer: answer,
          );
      expect(codecs.answererSends, 'VP8');
      expect(codecs.offererSends, 'VP8');
    });

    test(
      'an answer that lists H.264 first is applied with VP8 first',
      () async {
        await start();
        await media.startOutgoing(
          callId: 'call-5',
          remoteAddress: _peer,
          kind: CallInviteKind.video,
        );
        await media.applyRemoteAnswer(<String, dynamic>{
          'type': 'answer',
          'sdp': _theirSdp('answer', h264First: true),
        });
        expect(firstVideoCodecInSdp(platform.appliedRemote.single), 'VP8');
      },
    );
  });

  group('the controls before the answer', () {
    test('ready once the offer went out, while it still rings', () async {
      await start();
      expect(media.controlsReady, isFalse);
      await media.startOutgoing(
        callId: 'call-6',
        remoteAddress: _peer,
        kind: CallInviteKind.video,
      );
      expect(media.controlsReady, isTrue);
      expect(media.isConnected, isFalse);
    });

    test('the camera switched off while it rings stays off when the call '
        'connects, and the other side is told once it has answered', () async {
      await start();
      await media.startOutgoing(
        callId: 'call-7',
        remoteAddress: _peer,
        kind: CallInviteKind.video,
      );
      await media.setCameraEnabled(false);
      expect(media.hasLocalVideo, isFalse);
      expect(_offersSent(transport), 1);
      await media.applyRemoteAnswer(<String, dynamic>{
        'type': 'answer',
        'sdp': _theirSdp('answer'),
      });
      expect(_offersSent(transport), 1);
      await platform.connect();
      await _settle();
      expect(_offersSent(transport), 2);
      final String offer =
          (transport.sentSignals.last.payload['description']
                  as Map<String, dynamic>)['sdp']
              as String;
      final String video = offer.substring(offer.indexOf('m=video'));
      expect(video, contains('a=recvonly'));
      expect(media.hasLocalVideo, isFalse);
    });

    test('the camera switched off right after accepting: no offer goes to a '
        'caller that may not have the answer yet, one goes once the call '
        'connects', () async {
      await start();
      await media.acceptIncoming(
        callId: 'call-8',
        remoteAddress: _peer,
        kind: CallInviteKind.video,
        remoteDescription: <String, dynamic>{
          'type': 'offer',
          'sdp': _theirSdp('offer'),
        },
      );
      expect(media.controlsReady, isTrue);
      await media.setCameraEnabled(false);
      expect(_offersSent(transport), 0);
      await platform.connect();
      await _settle();
      expect(_offersSent(transport), 1);
      expect(media.hasLocalVideo, isFalse);
    });
  });
}
