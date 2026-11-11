import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:zen/src/features/calls/call_video_codecs.dart';

RTCRtpCodecCapability _codec(String mime, [String? fmtp]) =>
    RTCRtpCodecCapability(mimeType: mime, clockRate: 90000, sdpFmtpLine: fmtp);

/// What WebRTC on a recent Android phone (hardware H.264 and H.265) can
/// receive, in its own order.
List<RTCRtpCodecCapability> _androidCapabilities() => <RTCRtpCodecCapability>[
  _codec(
    'video/H264',
    'level-asymmetry-allowed=1;packetization-mode=1;'
        'profile-level-id=640c29',
  ),
  _codec(
    'video/H264',
    'level-asymmetry-allowed=1;packetization-mode=1;'
        'profile-level-id=42e029',
  ),
  _codec('video/H265', 'level-id=180;profile-id=1;tier-flag=0;tx-mode=SRST'),
  _codec('video/VP8'),
  _codec('video/VP9', 'profile-id=0'),
  _codec('video/VP9', 'profile-id=2'),
  _codec('video/AV1', 'level-idx=5;profile=0;tier=0'),
  _codec('video/rtx'),
  _codec('video/red'),
  _codec('video/ulpfec'),
  _codec('video/flexfec-03', 'repair-window=10000000'),
];

final class _Track implements MediaStreamTrack {
  _Track(this.kind);

  @override
  final String? kind;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _Receiver implements RTCRtpReceiver {
  _Receiver(this.kind);

  final String kind;

  @override
  MediaStreamTrack? get track => _Track(kind);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _Sender implements RTCRtpSender {
  @override
  MediaStreamTrack? get track => null;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _Transceiver implements RTCRtpTransceiver {
  _Transceiver(this.name, String kind, this.calls, {this.refuses = false})
    : receiver = _Receiver(kind);

  final String name;
  final List<String> calls;
  final bool refuses;
  List<RTCRtpCodecCapability>? preferred;

  @override
  final RTCRtpReceiver receiver;

  @override
  RTCRtpSender get sender => _Sender();

  @override
  Future<void> setCodecPreferences(List<RTCRtpCodecCapability> codecs) async {
    calls.add('prefer $name');
    if (refuses) {
      throw 'Unable to RTCRtpTransceiver::setCodecPreferences: refused';
    }
    preferred = codecs;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _Connection implements RTCPeerConnection {
  _Connection({bool refuses = false, this.refusesSdp}) {
    slots = <_Transceiver>[
      _Transceiver('microphone', 'audio', calls, refuses: refuses),
      _Transceiver('camera', 'video', calls, refuses: refuses),
      _Transceiver('screen', 'video', calls, refuses: refuses),
    ];
  }

  final List<String> calls = <String>[];
  late final List<_Transceiver> slots;

  /// The local description is refused when this says so.
  final bool Function(String sdp)? refusesSdp;
  String? local;

  @override
  Future<List<RTCRtpTransceiver>> getTransceivers() async {
    calls.add('transceivers');
    return slots;
  }

  @override
  Future<RTCSessionDescription> createOffer([
    Map<String, dynamic>? constraints,
  ]) async {
    calls.add('createOffer');
    return RTCSessionDescription('v=0', 'offer');
  }

  @override
  Future<RTCSessionDescription> createAnswer([
    Map<String, dynamic>? constraints,
  ]) async {
    calls.add('createAnswer');
    return RTCSessionDescription('v=0', 'answer');
  }

  @override
  Future<void> setLocalDescription(RTCSessionDescription description) async {
    final String sdp = description.sdp ?? '';
    if (refusesSdp?.call(sdp) ?? false) {
      throw 'Failed to set local description';
    }
    local = sdp;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// The video section of an answer from a phone whose preferences did not
/// take: H.264 first, VP8 behind it, each with its RTX.
const String _h264FirstSdp =
    'v=0\r\n'
    'a=group:BUNDLE 0 1\r\n'
    'm=audio 9 UDP/TLS/RTP/SAVPF 111\r\n'
    'a=mid:0\r\n'
    'a=rtpmap:111 opus/48000/2\r\n'
    'm=video 9 UDP/TLS/RTP/SAVPF 102 103 39 96 97 98 99\r\n'
    'a=mid:1\r\n'
    'a=sendrecv\r\n'
    'a=rtpmap:102 H264/90000\r\n'
    'a=fmtp:102 level-asymmetry-allowed=1;packetization-mode=1;'
    'profile-level-id=42e01f\r\n'
    'a=rtpmap:103 rtx/90000\r\n'
    'a=fmtp:103 apt=102\r\n'
    'a=rtpmap:39 H265/90000\r\n'
    'a=rtpmap:96 VP8/90000\r\n'
    'a=rtpmap:97 rtx/90000\r\n'
    'a=fmtp:97 apt=96\r\n'
    'a=rtpmap:98 VP9/90000\r\n'
    'a=rtpmap:99 rtx/90000\r\n'
    'a=fmtp:99 apt=98\r\n';

void main() {
  group('the codecs a call prefers', () {
    test('VP8 first, H.264 behind it, the repair formats, and no H.265, '
        'VP9 or AV1', () {
      final List<String> preferred = <String>[
        for (final RTCRtpCodecCapability codec in callVideoCodecPreferences(
          _androidCapabilities(),
        ))
          '${codec.mimeType} ${codec.sdpFmtpLine ?? ''}'.trim(),
      ];
      expect(preferred, <String>[
        'video/VP8',
        'video/H264 level-asymmetry-allowed=1;packetization-mode=1;'
            'profile-level-id=640c29',
        'video/H264 level-asymmetry-allowed=1;packetization-mode=1;'
            'profile-level-id=42e029',
        'video/rtx',
        'video/red',
        'video/ulpfec',
        'video/flexfec-03 repair-window=10000000',
      ]);
    });

    test('nothing to prefer without VP8 and H.264: the defaults stay', () {
      expect(
        callVideoCodecPreferences(<RTCRtpCodecCapability>[
          _codec('video/AV1'),
          _codec('video/rtx'),
        ]),
        isEmpty,
      );
    });

    for (final bool offer in <bool>[true, false]) {
      final String made = offer ? 'createOffer' : 'createAnswer';
      test(
        'before the ${offer ? 'offer' : 'answer'}: the camera and the '
        'shared screen get the preferences, the microphone does not',
        () async {
          final _Connection connection = _Connection();
          final RTCSessionDescription description = await createCallDescription(
            connection,
            offer: offer,
            capabilities: () async => _androidCapabilities(),
          );
          expect(description.type, offer ? 'offer' : 'answer');
          expect(connection.calls, <String>[
            'transceivers',
            'prefer camera',
            'prefer screen',
            made,
          ]);
          for (final _Transceiver video in connection.slots.skip(1)) {
            final List<String> mimes = <String>[
              for (final RTCRtpCodecCapability c in video.preferred!)
                c.mimeType,
            ];
            expect(mimes.first, 'video/VP8');
            expect(mimes, isNot(contains('video/H265')));
            expect(mimes, isNot(contains('video/VP9')));
            expect(mimes, isNot(contains('video/AV1')));
          }
          expect(connection.slots.first.preferred, isNull);
        },
      );
    }

    test('a platform that refuses the preferences, or has no list of '
        'codecs, still gets its offer and answer made', () async {
      final _Connection refusing = _Connection(refuses: true);
      final RTCSessionDescription offer = await createCallDescription(
        refusing,
        offer: true,
        capabilities: () async => _androidCapabilities(),
      );
      expect(offer.type, 'offer');
      expect(refusing.calls.last, 'createOffer');

      final _Connection blind = _Connection();
      final RTCSessionDescription answer = await createCallDescription(
        blind,
        offer: false,
        capabilities: () async => throw StateError('no capabilities'),
      );
      expect(answer.type, 'answer');
      expect(blind.calls, <String>['createAnswer']);
    });
  });

  group('the local description', () {
    test('the first video codec of a description', () {
      expect(firstVideoCodecInSdp(_h264FirstSdp), 'H264');
      expect(firstVideoCodecInSdp(preferVp8InSdp(_h264FirstSdp)), 'VP8');
      expect(firstVideoCodecInSdp('v=0\r\nm=audio 9 RTP 111\r\n'), isNull);
    });

    test('VP8 and its RTX move to the front, H.264 and its RTX next; only '
        'the m-line changes', () {
      final String reordered = preferVp8InSdp(_h264FirstSdp);
      expect(
        reordered,
        contains('m=video 9 UDP/TLS/RTP/SAVPF 96 97 102 103 39 98 99\r\n'),
      );
      final List<String> before = _h264FirstSdp.split('\r\n');
      final List<String> after = reordered.split('\r\n');
      expect(after.length, before.length);
      for (int i = 0; i < before.length; i++) {
        if (!before[i].startsWith('m=video')) {
          expect(after[i], before[i]);
        }
      }
    });

    test('preferences that did not take: VP8 is moved to the front of '
        'what is set and sent', () async {
      final _Connection connection = _Connection();
      final RTCSessionDescription set = await setCallLocalDescription(
        connection,
        RTCSessionDescription(_h264FirstSdp, 'answer'),
      );
      expect(firstVideoCodecInSdp(set.sdp!), 'VP8');
      expect(connection.local, set.sdp);
    });

    test('a platform that refuses the reordered form gets the description '
        'as it was made', () async {
      final _Connection connection = _Connection(
        refusesSdp: (String sdp) => firstVideoCodecInSdp(sdp) == 'VP8',
      );
      final RTCSessionDescription set = await setCallLocalDescription(
        connection,
        RTCSessionDescription(_h264FirstSdp, 'offer'),
      );
      expect(set.sdp, _h264FirstSdp);
      expect(connection.local, _h264FirstSdp);
    });

    test('a description with VP8 first is set as it is', () async {
      final _Connection connection = _Connection();
      final String vp8First = preferVp8InSdp(_h264FirstSdp);
      final RTCSessionDescription set = await setCallLocalDescription(
        connection,
        RTCSessionDescription(vp8First, 'offer'),
      );
      expect(identical(set.sdp, vp8First), isTrue);
      expect(connection.local, vp8First);
    });
  });
}
