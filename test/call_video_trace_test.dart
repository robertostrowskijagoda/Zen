import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' show StatsReport;
import 'package:zen/src/domain/signals/zen_signal.dart';
import 'package:zen/src/features/calls/call_media_session.dart';
import 'package:zen/src/features/calls/call_video_trace.dart';
import 'package:zen/src/features/runtime/runtime_signal_codec.dart';
import 'package:zen/src/features/runtime/runtime_signal_parser.dart';

/// A video offer as WebRTC on Android (m150, hardware H.264 and the
/// software codecs) writes it: audio with its extensions, then video with
/// VP8, VP9 (two profiles), H.264 (four profiles), AV1, each with its RTX,
/// RED and ULPFEC, the feedback lines and the sender's SSRCs.
String _androidVideoOffer({
  String videoDirection = 'sendrecv',
  bool videoSends = true,
}) {
  final StringBuffer sdp = StringBuffer()
    ..writeln('v=0')
    ..writeln('o=- 4611731400430051336 2 IN IP4 127.0.0.1')
    ..writeln('s=-')
    ..writeln('t=0 0')
    ..writeln('a=group:BUNDLE 0 1')
    ..writeln('a=extmap-allow-mixed')
    ..writeln('a=msid-semantic: WMS 6f1c2a9e-0d55-4b0c-9a51-1f0e7bb0d9a2')
    ..writeln('m=audio 9 UDP/TLS/RTP/SAVPF 111 63 9 102 0 8 13 110 126')
    ..writeln('c=IN IP4 0.0.0.0')
    ..writeln('a=rtcp:9 IN IP4 0.0.0.0')
    ..writeln('a=ice-ufrag:Xq3v')
    ..writeln('a=ice-pwd:0e4wBq7mJ6m3s2v1f0g9h8k7l6p5o4i3')
    ..writeln('a=ice-options:trickle renomination')
    ..writeln(
      'a=fingerprint:sha-256 ${List<String>.filled(32, 'AB').join(':')}',
    )
    ..writeln('a=setup:actpass')
    ..writeln('a=mid:0');
  const List<String> audioExtensions = <String>[
    'urn:ietf:params:rtp-hdrext:ssrc-audio-level',
    'http://www.webrtc.org/experiments/rtp-hdrext/abs-send-time',
    'http://www.ietf.org/id/draft-holmer-rmcat-transport-wide-cc-extensions-01',
    'urn:ietf:params:rtp-hdrext:sdes:mid',
  ];
  for (int i = 0; i < audioExtensions.length; i++) {
    sdp.writeln('a=extmap:${i + 1} ${audioExtensions[i]}');
  }
  sdp
    ..writeln('a=sendrecv')
    ..writeln('a=msid:6f1c2a9e-0d55-4b0c-9a51-1f0e7bb0d9a2 audio-track-1')
    ..writeln('a=rtcp-mux')
    ..writeln('a=rtcp-rsize')
    ..writeln('a=rtpmap:111 opus/48000/2')
    ..writeln('a=rtcp-fb:111 transport-cc')
    ..writeln('a=fmtp:111 minptime=10;useinbandfec=1')
    ..writeln('a=rtpmap:63 red/48000/2')
    ..writeln('a=fmtp:63 111/111')
    ..writeln('a=rtpmap:9 G722/8000')
    ..writeln('a=rtpmap:102 ILBC/8000')
    ..writeln('a=rtpmap:0 PCMU/8000')
    ..writeln('a=rtpmap:8 PCMA/8000')
    ..writeln('a=rtpmap:13 CN/8000')
    ..writeln('a=rtpmap:110 telephone-event/48000')
    ..writeln('a=rtpmap:126 telephone-event/8000')
    ..writeln('a=ssrc:3570614608 cname:4TOk42mSjXCkVIa6')
    ..writeln(
      'a=ssrc:3570614608 msid:6f1c2a9e-0d55-4b0c-9a51-1f0e7bb0d9a2 '
      'audio-track-1',
    );
  // Video: codec, its RTX, in the order Android offers them.
  final List<(int, String, String?)> video = <(int, String, String?)>[
    (96, 'VP8', null),
    (98, 'VP9', 'profile-id=0'),
    (100, 'VP9', 'profile-id=2'),
    (
      102,
      'H264',
      'level-asymmetry-allowed=1;packetization-mode=1;profile-level-id=640c29',
    ),
    (
      104,
      'H264',
      'level-asymmetry-allowed=1;packetization-mode=0;profile-level-id=640c29',
    ),
    (
      106,
      'H264',
      'level-asymmetry-allowed=1;packetization-mode=1;profile-level-id=42e029',
    ),
    (
      108,
      'H264',
      'level-asymmetry-allowed=1;packetization-mode=0;profile-level-id=42e029',
    ),
    (
      110,
      'H264',
      'level-asymmetry-allowed=1;packetization-mode=1;profile-level-id=42001f',
    ),
    (
      112,
      'H264',
      'level-asymmetry-allowed=1;packetization-mode=0;profile-level-id=42001f',
    ),
    (45, 'AV1', 'level-idx=5;profile=0;tier=0'),
    (35, 'H265', 'level-id=180;profile-id=1;tier-flag=0;tx-mode=SRST'),
    (37, 'H265', 'level-id=180;profile-id=2;tier-flag=0;tx-mode=SRST'),
  ];
  final List<int> payloads = <int>[
    for (final (int pt, String _, String? _) in video) ...<int>[pt, pt + 1],
    116,
    117,
    118,
  ];
  sdp
    ..writeln('m=video 9 UDP/TLS/RTP/SAVPF ${payloads.join(' ')}')
    ..writeln('c=IN IP4 0.0.0.0')
    ..writeln('a=rtcp:9 IN IP4 0.0.0.0')
    ..writeln('a=ice-ufrag:Xq3v')
    ..writeln('a=ice-pwd:0e4wBq7mJ6m3s2v1f0g9h8k7l6p5o4i3')
    ..writeln('a=ice-options:trickle renomination')
    ..writeln(
      'a=fingerprint:sha-256 ${List<String>.filled(32, 'AB').join(':')}',
    )
    ..writeln('a=setup:actpass')
    ..writeln('a=mid:1');
  const List<String> videoExtensions = <String>[
    'urn:ietf:params:rtp-hdrext:toffset',
    'http://www.webrtc.org/experiments/rtp-hdrext/abs-send-time',
    'urn:3gpp:video-orientation',
    'http://www.ietf.org/id/draft-holmer-rmcat-transport-wide-cc-extensions-01',
    'http://www.webrtc.org/experiments/rtp-hdrext/playout-delay',
    'http://www.webrtc.org/experiments/rtp-hdrext/video-content-type',
    'http://www.webrtc.org/experiments/rtp-hdrext/video-timing',
    'http://www.webrtc.org/experiments/rtp-hdrext/color-space',
    'urn:ietf:params:rtp-hdrext:sdes:mid',
    'urn:ietf:params:rtp-hdrext:sdes:rtp-stream-id',
    'urn:ietf:params:rtp-hdrext:sdes:repaired-rtp-stream-id',
  ];
  for (int i = 0; i < videoExtensions.length; i++) {
    sdp.writeln('a=extmap:${i + 2} ${videoExtensions[i]}');
  }
  sdp.writeln('a=$videoDirection');
  if (videoSends) {
    sdp.writeln('a=msid:6f1c2a9e-0d55-4b0c-9a51-1f0e7bb0d9a2 video-track-1');
  }
  sdp
    ..writeln('a=rtcp-mux')
    ..writeln('a=rtcp-rsize');
  for (final (int pt, String name, String? fmtp) in video) {
    sdp
      ..writeln('a=rtpmap:$pt $name/90000')
      ..writeln('a=rtcp-fb:$pt goog-remb')
      ..writeln('a=rtcp-fb:$pt transport-cc')
      ..writeln('a=rtcp-fb:$pt ccm fir')
      ..writeln('a=rtcp-fb:$pt nack')
      ..writeln('a=rtcp-fb:$pt nack pli');
    if (fmtp != null) {
      sdp.writeln('a=fmtp:$pt $fmtp');
    }
    sdp
      ..writeln('a=rtpmap:${pt + 1} rtx/90000')
      ..writeln('a=fmtp:${pt + 1} apt=$pt');
  }
  sdp
    ..writeln('a=rtpmap:116 red/90000')
    ..writeln('a=rtpmap:117 rtx/90000')
    ..writeln('a=fmtp:117 apt=116')
    ..writeln('a=rtpmap:118 ulpfec/90000');
  if (videoSends) {
    sdp
      ..writeln('a=ssrc-group:FID 2231627014 632943048')
      ..writeln('a=ssrc:2231627014 cname:4TOk42mSjXCkVIa6')
      ..writeln(
        'a=ssrc:2231627014 msid:6f1c2a9e-0d55-4b0c-9a51-1f0e7bb0d9a2 '
        'video-track-1',
      )
      ..writeln('a=ssrc:632943048 cname:4TOk42mSjXCkVIa6')
      ..writeln(
        'a=ssrc:632943048 msid:6f1c2a9e-0d55-4b0c-9a51-1f0e7bb0d9a2 '
        'video-track-1',
      );
  }
  return sdp.toString().replaceAll('\n', '\r\n');
}

/// The hybrid public key block of an offer (ML-KEM-768 + X25519).
Map<String, dynamic> _e2eeBlock() => <String, dynamic>{
  'v': 1,
  'pk': base64Url.encode(
    List<int>.generate(1184 + 32, (int i) => (i * 37 + 11) & 0xFF),
  ),
};

Uint8List _zstdFrame(int declaredBytes) {
  final int block = declaredBytes < 128 * 1024 ? declaredBytes : 128 * 1024;
  final int blockHeader = 1 | (1 << 1) | (block << 3);
  return Uint8List.fromList(<int>[
    0x28, 0xB5, 0x2F, 0xFD, // magic
    0xA0, // 4-byte content size, single segment
    declaredBytes & 0xFF,
    (declaredBytes >> 8) & 0xFF,
    (declaredBytes >> 16) & 0xFF,
    (declaredBytes >> 24) & 0xFF,
    blockHeader & 0xFF,
    (blockHeader >> 8) & 0xFF,
    (blockHeader >> 16) & 0xFF,
    0x61,
  ]);
}

/// Stands in for zstd: a well-formed frame declaring the input's size,
/// and the input back on decompression.
final class _PassThroughCompressor implements SignalPayloadCompressor {
  Uint8List? _last;
  int compressed = 0;

  @override
  Future<Uint8List?> compress(Uint8List input, int level) async {
    _last = Uint8List.fromList(input);
    compressed += 1;
    return _zstdFrame(input.length);
  }

  @override
  Future<Uint8List?> decompress(Uint8List input) async => _last;
}

void main() {
  group('the SDP line of the technical log', () {
    test('a video offer: kinds, directions, who sends, codecs in order '
        'and the feedback the camera asks for', () {
      final String sdp = _androidVideoOffer();
      expect(
        describeCallSdp(sdp),
        'audio#0 sendrecv sends opus G722 ILBC PCMU PCMA; '
        'video#1 sendrecv sends VP8 VP9 H264 AV1 H265 fb nack,pli,fir,tcc,remb; '
        '${sdp.length} B',
      );
    });

    test('a voice call offers a camera slot it only receives on', () {
      final String sdp = _androidVideoOffer(
        videoDirection: 'recvonly',
        videoSends: false,
      );
      expect(
        describeCallSdp(sdp),
        startsWith(
          'audio#0 sendrecv sends opus G722 ILBC PCMU PCMA; '
          'video#1 recvonly VP8',
        ),
      );
    });

    test('writes no address, credential, fingerprint or SSRC', () {
      final String line = describeCallSdp(
        _androidVideoOffer().replaceAll('0.0.0.0', '192.168.1.23'),
      );
      expect(line, isNot(contains('192.168')));
      expect(line, isNot(contains('127.0.0.1')));
      expect(line, isNot(contains('Xq3v')));
      expect(line, isNot(contains('AB:AB')));
      expect(line, isNot(contains('2231627014')));
      expect(line, isNot(contains('6f1c2a9e')));
      expect(describeCallSdp(''), 'empty');
    });

    test('the relay form keeps every media line of the camera: only '
        'addresses and candidates change', () {
      final String sdp = _androidVideoOffer();
      final String pinned = pinWebRtcSdpToLocalRelay(sdp, 40123);
      String media(String s) =>
          describeCallSdp(s).replaceAll(RegExp(r'; \d+ B$'), '');
      expect(media(pinned), media(sdp));
      for (final String kept in <String>[
        'a=rtpmap:96 VP8/90000',
        'a=rtcp-fb:96 nack pli',
        'a=rtcp-fb:96 ccm fir',
        'a=ssrc-group:FID 2231627014 632943048',
        'a=msid:6f1c2a9e-0d55-4b0c-9a51-1f0e7bb0d9a2 video-track-1',
        'a=extmap:5 http://www.ietf.org/id/draft-holmer-rmcat-transport-'
            'wide-cc-extensions-01',
      ]) {
        expect(pinned, contains(kept));
      }
    });
  });

  group('a video SDP on the signalling path', () {
    /// The camera's offer, and the same with a second video section (a
    /// shared screen), which crosses the compression threshold.
    final String camera = _androidVideoOffer();
    final String video = camera.substring(camera.indexOf('m=video'));
    final String withScreen =
        camera +
        video
            .replaceAll('a=mid:1', 'a=mid:2')
            .replaceAll('video-track-1', 'screen-track-1');

    for (final (String label, String sdp) in <(String, String)>[
      ('camera', camera),
      ('camera and screen', withScreen),
    ]) {
      test('an Android offer ($label, ${sdp.length} B) with its key block '
          'arrives whole and is read as a video call offer', () async {
        expect(sdp.length, inInclusiveRange(5 * 1024, 16 * 1024));
        final Map<String, dynamic> payload = <String, dynamic>{
          'type': 'offer',
          'callId': 'call-1731300000000',
          'kind': 'video',
          'description': <String, dynamic>{
            'sdp': sdp,
            'type': 'offer',
            'e2ee': _e2eeBlock(),
          },
        };
        final _PassThroughCompressor compressor = _PassThroughCompressor();
        final String wire = await encodeRuntimeSignalPayload(
          payload,
          compressor,
        );
        final bool overThreshold =
            utf8.encode(jsonEncode(payload)).length >=
            kRuntimeSignalCompressionThresholdBytes;
        expect(compressor.compressed, overThreshold ? 1 : 0);
        final Map<String, dynamic>? decoded = await decodeRuntimeSignalPayload(
          wire,
          compressor,
        );
        final ZenSignal? signal = zenSignalFromTransportPayload(
          sender: '200:1111:2222:3333:4444:5555:6666:7777',
          payload: decoded!,
        );
        expect(signal, isNotNull);
        expect(signal!.type, ZenSignalType.callOffer);
        expect(signal.content, 'video');
        expect(signal.callId, 'call-1731300000000');
        final Map<String, dynamic> description = signal.sessionDescription!;
        expect(description['sdp'], sdp);
        expect(description['type'], 'offer');
        expect(description['e2ee'], _e2eeBlock());
      });
    }

    test('of the two, the one with the screen goes compressed', () {
      int bytes(String sdp) => utf8
          .encode(
            jsonEncode(<String, dynamic>{
              'type': 'offer',
              'callId': 'call-1731300000000',
              'kind': 'video',
              'description': <String, dynamic>{
                'sdp': sdp,
                'type': 'offer',
                'e2ee': _e2eeBlock(),
              },
            }),
          )
          .length;
      expect(
        bytes(withScreen),
        greaterThan(kRuntimeSignalCompressionThresholdBytes),
      );
    });
  });
  group('the statistics lines of the technical log', () {
    StatsReport report(String id, String type, Map<String, dynamic> values) =>
        StatsReport(id, type, 0, <String, dynamic>{
          'id': id,
          'type': type,
          ...values,
        });

    test('the side whose camera sends, and the side that receives packets '
        'but decodes no frame', () {
      final List<String> lines = describeCallStats(<StatsReport>[
        report('C1', 'codec', <String, dynamic>{'mimeType': 'video/VP8'}),
        report('C2', 'codec', <String, dynamic>{'mimeType': 'audio/opus'}),
        report('O1', 'outbound-rtp', <String, dynamic>{
          'kind': 'video',
          'codecId': 'C1',
          'ssrc': 2231627014,
          'packetsSent': 950,
          'bytesSent': 640 * 1024,
          'framesEncoded': 96,
          'keyFramesEncoded': 3,
          'frameWidth': 960,
          'frameHeight': 540,
          'framesPerSecond': 24.0,
          'pliCount': 2,
          'qualityLimitationReason': 'bandwidth',
          'encoderImplementation': 'libvpx',
        }),
        report('I1', 'inbound-rtp', <String, dynamic>{
          'kind': 'video',
          'codecId': 'C1',
          'packetsReceived': 870,
          'bytesReceived': 600 * 1024,
          'packetsLost': 4,
          'framesReceived': 90,
          'framesDecoded': 0,
          'keyFramesDecoded': 0,
          'pliCount': 7,
        }),
        report('O2', 'outbound-rtp', <String, dynamic>{
          'kind': 'audio',
          'codecId': 'C2',
          'packetsSent': 200,
          'bytesSent': 16 * 1024,
        }),
        report('P1', 'candidate-pair', <String, dynamic>{
          'state': 'succeeded',
          'nominated': true,
          'bytesSent': 700 * 1024,
          'bytesReceived': 650 * 1024,
          'currentRoundTripTime': 0.182,
          'availableOutgoingBitrate': 1200000,
        }),
        report('L1', 'local-candidate', <String, dynamic>{
          'address': '192.168.1.23',
          'port': 40123,
        }),
      ]);
      expect(lines, <String>[
        'video out VP8 960x540 24 fps, 96 frames (3 key), 950 packets, '
            '640 KB, nack 0 pli 2 fir 0, limit bandwidth, encoder libvpx',
        'video in VP8 no size, 870 packets, 600 KB, lost 4, received 90 '
            'frames, decoded 0 (0 key), dropped 0, nack 0 pli 7 fir 0',
        'audio out opus, 200 packets, 16 KB',
        'path 700 KB out, 650 KB in, rtt 182 ms, estimate 1200 kbit/s',
      ]);
      expect(lines.join('\n'), isNot(contains('192.168')));
      expect(lines.join('\n'), isNot(contains('2231627014')));
    });

    test('a call with no video stream says so', () {
      expect(describeCallStats(<StatsReport>[]), <String>[
        'no video stream either way',
      ]);
    });
  });

  group('the video path line after "connected"', () {
    StatsReport report(String id, String type, Map<String, dynamic> values) =>
        StatsReport(id, type, 0, <String, dynamic>{'id': id, ...values});

    /// The statistics of the answering phone at 04:58:29 on 12 November:
    /// VP8 in, decoded in software, and H.264 out of the hardware encoder.
    List<StatsReport> answeringPhone() => <StatsReport>[
      report('C1', 'codec', <String, dynamic>{'mimeType': 'video/VP8'}),
      report('C2', 'codec', <String, dynamic>{'mimeType': 'video/H264'}),
      report('I1', 'inbound-rtp', <String, dynamic>{
        'kind': 'video',
        'codecId': 'C1',
        'trackIdentifier': 'their-camera',
        'framesDecoded': 38,
        'decoderImplementation': 'libvpx',
      }),
      report('O1', 'outbound-rtp', <String, dynamic>{
        'kind': 'video',
        'codecId': 'C2',
        'framesEncoded': 56,
        'encoderImplementation': 'c2.qti.avc.encoder',
      }),
    ];

    test('says plainly what goes out and comes in', () {
      expect(
        describeCallVideoPath(callVideoPath(answeringPhone())),
        'sends H264 (encoder c2.qti.avc.encoder), receives VP8 '
        '(decoder libvpx)',
      );
      expect(
        describeCallVideoPath(callVideoPath(<StatsReport>[])),
        'sends no video, receives no video',
      );
    });

    test('with their screen shared too, the camera on the screen is the one '
        'named, and its frames are the ones counted', () {
      final List<StatsReport> reports = <StatsReport>[
        ...answeringPhone(),
        report('I2', 'inbound-rtp', <String, dynamic>{
          'kind': 'video',
          'codecId': 'C2',
          'trackIdentifier': 'their-screen',
          'framesDecoded': 400,
          'decoderImplementation': 'c2.qti.avc.decoder',
        }),
      ];
      expect(
        callVideoPath(reports, receivedTrackId: 'their-camera').receives,
        'VP8',
      );
      expect(remoteVideoFramesDecoded(reports, trackId: 'their-camera'), 38);
      expect(remoteVideoFramesDecoded(reports), 400);
      expect(remoteVideoFramesDecoded(<StatsReport>[]), isNull);
    });
  });

  group('the watch over the remote picture', () {
    test('frames decoded, none on the screen within a look: bound again, at '
        'most three times', () {
      final RemotePictureWatch watch = RemotePictureWatch();
      // At "connected": the count to compare with.
      expect(
        watch.look(shown: false, bound: true, decoded: 0),
        RemotePictureStep.wait,
      );
      for (int i = 1; i <= 3; i++) {
        expect(
          watch.look(shown: false, bound: true, decoded: i * 50),
          RemotePictureStep.rebind,
        );
        expect(watch.rebinds, i);
      }
      expect(
        watch.look(shown: false, bound: true, decoded: 400),
        RemotePictureStep.done,
      );
    });

    test('nothing to do while nothing is decoded, nothing bound, or the '
        'picture is there', () {
      final RemotePictureWatch watch = RemotePictureWatch();
      expect(
        watch.look(shown: false, bound: true, decoded: 10),
        RemotePictureStep.wait,
      );
      // No new frame decoded: the sender may simply send none.
      expect(
        watch.look(shown: false, bound: true, decoded: 10),
        RemotePictureStep.wait,
      );
      // Their camera is off: nothing bound.
      expect(
        watch.look(shown: false, bound: false, decoded: 90),
        RemotePictureStep.wait,
      );
      expect(watch.rebinds, 0);
      expect(
        watch.look(shown: true, bound: true, decoded: 200),
        RemotePictureStep.done,
      );
    });

    test('ends after its looks', () {
      final RemotePictureWatch watch = RemotePictureWatch(maxLooks: 2);
      expect(
        watch.look(shown: false, bound: false, decoded: null),
        RemotePictureStep.wait,
      );
      expect(
        watch.look(shown: false, bound: false, decoded: null),
        RemotePictureStep.wait,
      );
      expect(
        watch.look(shown: false, bound: false, decoded: null),
        RemotePictureStep.done,
      );
    });
  });
}
