import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:zen/src/features/calls/call_platform_channel.dart';
import 'package:zen/src/features/calls/call_video_quality.dart';
import 'package:zen/src/features/calls/call_video_trace.dart';

/// What a call asks of the camera and its encoder so that the picture
/// stays steady and sharp in motion and in poor light
/// (call_video_quality.dart). 1.17.1 opened the camera at whatever the
/// plugin chose, let its auto-exposure fall to 5 frames, capped the
/// encoder at 1.8 Mbit/s with no floor and started it at 300 kbit/s.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('the camera asked of a phone', () {
    test('is asked in plain numbers, the only form Android reads', () {
      final Map<String, dynamic> front = callCameraConstraints(mobile: true);
      expect(front['width'], 1280);
      expect(front['height'], 720);
      expect(front['frameRate'], 24);
      expect(front['facingMode'], 'user');
      // A map ({'ideal': 960}) was skipped and the camera opened at the
      // plugin's default.
      for (final String key in <String>['width', 'height', 'frameRate']) {
        expect(front[key], isA<int>(), reason: key);
      }
    });

    test('a chosen camera is named as a plain string', () {
      final Map<String, dynamic> back = callCameraConstraints(
        deviceId: '0',
        mobile: true,
      );
      expect(back['deviceId'], '0');
      expect(back.containsKey('facingMode'), isFalse);
      expect(
        callCameraConstraints(deviceId: '', mobile: true)['facingMode'],
        'user',
      );
    });

    test('a computer gets the same size and rate', () {
      final Map<String, dynamic> desktop = callCameraConstraints(
        deviceId: 'cam-1',
        mobile: false,
      );
      expect(desktop['width'], 1280);
      expect(desktop['height'], 720);
      expect(desktop['frameRate'], kCallVideoFrameRate);
      expect(desktop['deviceId'], 'cam-1');
      expect(desktop['optional'], <Map<String, dynamic>>[
        <String, dynamic>{'sourceId': 'cam-1'},
      ]);
      expect(
        callCameraConstraints(mobile: false).containsKey('deviceId'),
        isFalse,
      );
    });
  });

  group('the camera encoder', () {
    test('keeps under the ceiling, with no floor, at up to 24 frames and '
        '960 x 540', () {
      final RTCRtpParameters parameters = RTCRtpParameters(
        encodings: <RTCRtpEncoding>[
          RTCRtpEncoding(
            maxBitrate: 1800000,
            minBitrate: 150000,
            scaleResolutionDownBy: 2.0,
          ),
        ],
      );
      expect(tuneCallCameraParameters(parameters), isTrue);
      final RTCRtpEncoding encoding = parameters.encodings!.single;
      // 1.17.5 allowed 2.5 Mbit/s: over Yggdrasil's links it queued ahead
      // of the voice.
      expect(encoding.maxBitrate, 1200000);
      // 1.17.5 kept 150 kbit/s whatever the path carried.
      expect(encoding.minBitrate, isNull);
      expect(encoding.toMap().containsKey('minBitrate'), isFalse);
      expect(encoding.maxFramerate, 24);
      // 1.17.5 encoded the camera's full 1280 x 720 in software.
      expect(encoding.scaleResolutionDownBy, closeTo(4 / 3, 1e-9));
      expect((1280 / encoding.scaleResolutionDownBy!).round(), 960);
      expect((720 / encoding.scaleResolutionDownBy!).round(), 540);
      // Frames before resolution: a soft picture rather than a frozen one.
      expect(
        parameters.degradationPreference,
        RTCDegradationPreference.MAINTAIN_FRAMERATE,
      );
    });

    test('the camera is asked for more than is sent, never less', () {
      expect(kCallCameraWidth / kCallVideoScaleDownBy, kCallVideoSendWidth);
      expect(kCallCameraHeight / kCallVideoScaleDownBy, kCallVideoSendHeight);
      expect(kCallVideoScaleDownBy, greaterThan(1.0));
      final Map<String, dynamic> front = callCameraConstraints(mobile: true);
      expect(front['width'], kCallCameraWidth);
      expect(front['height'], kCallCameraHeight);
    });

    test('WebRTC watches the processor, so the voice does not starve', () {
      final List<Map<String, dynamic>> optional =
          (kCallPeerConstraints['optional'] as List<Map<String, dynamic>>);
      bool? named(String key) => optional
          .where((Map<String, dynamic> o) => o.containsKey(key))
          .map((Map<String, dynamic> o) => o[key] as bool)
          .single;
      // Off from 1.10.0 to 1.17.5.
      expect(named('googCpuOveruseDetection'), isTrue);
      expect(named('googSuspendBelowMinBitrate'), isFalse);
      expect(named('googDscp'), isTrue);
    });

    test('every encoding is set; none is nothing to set', () {
      final RTCRtpParameters two = RTCRtpParameters(
        encodings: <RTCRtpEncoding>[RTCRtpEncoding(), RTCRtpEncoding()],
      );
      expect(tuneCallCameraParameters(two), isTrue);
      expect(two.encodings!.map((RTCRtpEncoding e) => e.maxBitrate), <int>[
        kCallVideoMaxBitrate,
        kCallVideoMaxBitrate,
      ]);
      final RTCRtpParameters none = RTCRtpParameters(
        encodings: <RTCRtpEncoding>[],
      );
      expect(tuneCallCameraParameters(none), isFalse);
      expect(none.degradationPreference, isNull);
    });

    test('the start is modest, between WebRTC\'s own and the ceiling', () {
      // 1.17.5 started at 1 Mbit/s, which a relayed path may not carry.
      expect(kCallVideoStartBitrateKbps, 500);
      expect(kCallVideoStartBitrate, 500000);
      expect(kCallVideoStartBitrate, greaterThan(300000));
      expect(kCallVideoStartBitrate, lessThan(kCallVideoMaxBitrate));
    });
  });

  group('the auto-exposure range', () {
    CameraFrameRateRange r(int min, int max) => (min: min, max: max);

    test('a steady 24 where the camera has it', () {
      expect(
        chooseCameraFrameRateRange(<CameraFrameRateRange>[
          r(7, 30),
          r(15, 15),
          r(15, 30),
          r(24, 24),
          r(30, 30),
        ]),
        r(24, 24),
      );
      // The camera's own pick was the lowest floor: 7-30, down to 5-7
      // frames in poor light.
    });

    test('else the highest floor of at least 15', () {
      expect(
        chooseCameraFrameRateRange(<CameraFrameRateRange>[
          r(8, 30),
          r(10, 30),
          r(15, 30),
          r(30, 30),
        ]),
        r(15, 30),
      );
      expect(
        chooseCameraFrameRateRange(<CameraFrameRateRange>[
          r(15, 15),
          r(15, 30),
          r(20, 30),
        ]),
        r(20, 30),
      );
    });

    test('a top nearest 24 between equal floors', () {
      expect(
        chooseCameraFrameRateRange(<CameraFrameRateRange>[
          r(15, 30),
          r(15, 15),
          r(15, 24),
        ]),
        r(15, 24),
      );
      expect(
        chooseCameraFrameRateRange(<CameraFrameRateRange>[
          r(24, 30),
          r(24, 24),
        ]),
        r(24, 24),
      );
    });

    test('a floor above 24 only when nothing lower is steady', () {
      expect(
        chooseCameraFrameRateRange(<CameraFrameRateRange>[
          r(7, 30),
          r(60, 60),
          r(30, 30),
        ]),
        r(30, 30),
      );
    });

    test('nothing steady, nothing offered or no range: the camera chooses', () {
      expect(
        chooseCameraFrameRateRange(<CameraFrameRateRange>[r(7, 30), r(8, 24)]),
        isNull,
      );
      expect(chooseCameraFrameRateRange(<CameraFrameRateRange>[]), isNull);
      expect(
        chooseCameraFrameRateRange(<CameraFrameRateRange>[r(20, 10)]),
        isNull,
      );
    });

    test('ranges are read from what Android sends, the rest skipped', () {
      expect(
        cameraFrameRateRanges(<Object?>[
          <Object?>[7, 30],
          <Object?>[24, 24],
          <Object?>[24],
          <Object?>['24', 24],
          null,
        ]),
        <CameraFrameRateRange>[r(7, 30), r(24, 24)],
      );
      expect(cameraFrameRateRanges(null), isEmpty);
      expect(cameraFrameRateRanges('7-30'), isEmpty);
      expect(describeCameraFrameRateRange(r(7, 30)), '7-30');
    });
  });

  group('pinning the camera through the Android side', () {
    const MethodChannel channel = MethodChannel('zen/calls-test');
    final List<MethodCall> calls = <MethodCall>[];

    void answer(Object? Function(MethodCall call) reply) {
      calls.clear();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (MethodCall call) async {
            calls.add(call);
            return reply(call);
          });
    }

    tearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );

    test('the chosen range is pinned and the line says what changed', () async {
      answer(
        (MethodCall call) => call.method == 'callCameraFrameRates'
            ? <String, Object?>{
                'ranges': <Object?>[
                  <Object?>[7, 30],
                  <Object?>[24, 24],
                ],
                'current': <Object?>[7, 30],
              }
            : 'pinned',
      );
      final String line = await steadyCallCameraFrameRate(
        'track-1',
        channel: channel,
      );
      expect(line, 'pinned to 24-24 fps, was 7-30 (offers 7-30 24-24)');
      expect(calls.map((MethodCall c) => c.method), <String>[
        'callCameraFrameRates',
        'pinCallCameraFrameRate',
      ]);
      expect(calls.last.arguments, <String, Object?>{
        'trackId': 'track-1',
        'min': 24,
        'max': 24,
      });
    });

    test('a camera already there is left alone', () async {
      answer(
        (MethodCall call) => <String, Object?>{
          'ranges': <Object?>[
            <Object?>[24, 24],
          ],
          'current': <Object?>[24, 24],
        },
      );
      expect(
        await steadyCallCameraFrameRate('t', channel: channel),
        'already at 24-24 fps (offers 24-24)',
      );
      expect(calls, hasLength(1));
    });

    test('no steady range, a refusal or no Android side: said, never '
        'thrown', () async {
      answer(
        (MethodCall call) => <String, Object?>{
          'ranges': <Object?>[
            <Object?>[7, 30],
          ],
          'current': <Object?>[7, 30],
        },
      );
      expect(
        await steadyCallCameraFrameRate('t', channel: channel),
        'kept at 7-30 fps: no steady range among 7-30',
      );
      answer(
        (MethodCall call) => call.method == 'callCameraFrameRates'
            ? <String, Object?>{
                'ranges': <Object?>[
                  <Object?>[30, 30],
                ],
                'current': <Object?>[],
              }
            : 'refused: CameraAccessException',
      );
      expect(
        await steadyCallCameraFrameRate('t', channel: channel),
        'not pinned (refused: CameraAccessException) to 30-30 fps, was ? '
        '(offers 30-30)',
      );
      answer(
        (MethodCall call) => <String, Object?>{
          'error': 'not a Camera2 capturer',
        },
      );
      expect(
        await steadyCallCameraFrameRate('t', channel: channel),
        'not read (not a Camera2 capturer)',
      );
      answer((MethodCall call) => throw PlatformException(code: 'x'));
      expect(
        await steadyCallCameraFrameRate('t', channel: channel),
        startsWith('not pinned: '),
      );
    });
  });

  group('the start of the path estimate', () {
    const String offer =
        'v=0\r\n'
        'm=audio 9 UDP/TLS/RTP/SAVPF 111\r\n'
        'a=rtpmap:111 opus/48000/2\r\n'
        'a=fmtp:111 minptime=10;useinbandfec=1\r\n'
        'm=video 9 UDP/TLS/RTP/SAVPF 96 97 102\r\n'
        'a=mid:1\r\n'
        'a=rtpmap:96 VP8/90000\r\n'
        'a=rtpmap:97 rtx/90000\r\n'
        'a=fmtp:97 apt=96\r\n'
        'a=rtpmap:102 H264/90000\r\n'
        'a=fmtp:102 level-asymmetry-allowed=1;packetization-mode=1\r\n'
        'm=video 9 UDP/TLS/RTP/SAVPF 96\r\n'
        'a=mid:2\r\n'
        'a=rtpmap:96 VP8/90000\r\n';

    test('goes on the camera section\'s VP8 and H.264 only', () {
      final String hinted = withCallVideoStartBitrate(offer);
      final List<String> sections = hinted.split('m=');
      expect(
        sections[2],
        contains(
          'a=rtpmap:96 VP8/90000\r\na=fmtp:96 x-google-start-bitrate=500\r\n',
        ),
      );
      expect(
        sections[2],
        contains(
          'a=fmtp:102 level-asymmetry-allowed=1;packetization-mode=1;'
          'x-google-start-bitrate=500\r\n',
        ),
      );
      // Not the retransmissions, the audio or the screen slot.
      expect(sections[2], contains('a=fmtp:97 apt=96\r\n'));
      expect(sections[1], isNot(contains('x-google')));
      expect(sections[3], isNot(contains('x-google')));
      expect(hinted.split('x-google-start-bitrate').length - 1, 2);
    });

    test('is put once, whatever comes again', () {
      final String once = withCallVideoStartBitrate(offer);
      expect(withCallVideoStartBitrate(once), once);
      expect(withCallVideoStartBitrate(''), '');
      const String audioOnly =
          'v=0\nm=audio 9 UDP/TLS/RTP/SAVPF 111\na=rtpmap:111 opus/48000/2\n';
      expect(withCallVideoStartBitrate(audioOnly), audioOnly);
    });

    test('keeps the line ends of the description', () {
      final String lf = withCallVideoStartBitrate(
        offer.replaceAll('\r\n', '\n'),
      );
      expect(lf, isNot(contains('\r')));
      expect(lf, contains('a=fmtp:96 x-google-start-bitrate=500\n'));
    });
  });

  group('the statistics lines judge the picture', () {
    StatsReport report(String id, String type, Map<String, dynamic> values) =>
        StatsReport(id, type, 0, <String, dynamic>{
          'id': id,
          'type': type,
          ...values,
        });

    test('the camera going out: target, quantizer, changes, time held '
        'back; coming in: rate and freezes', () {
      final List<String> lines = describeCallStats(<StatsReport>[
        report('C1', 'codec', <String, dynamic>{'mimeType': 'video/VP8'}),
        report('O1', 'outbound-rtp', <String, dynamic>{
          'kind': 'video',
          'codecId': 'C1',
          'framesEncoded': 100,
          'frameWidth': 1280,
          'frameHeight': 720,
          'framesPerSecond': 24.0,
          'qualityLimitationReason': 'none',
          'encoderImplementation': 'libvpx',
          'targetBitrate': 1480000.0,
          'qpSum': 3600,
          'qualityLimitationResolutionChanges': 2,
          'qualityLimitationDurations': <String, dynamic>{
            'none': 50.2,
            'cpu': 0.1,
            'bandwidth': 6.6,
            'other': 0.0,
          },
        }),
        report('I1', 'inbound-rtp', <String, dynamic>{
          'kind': 'video',
          'codecId': 'C1',
          'frameWidth': 1280,
          'frameHeight': 720,
          'framesPerSecond': 23.0,
          'freezeCount': 3,
          'totalFreezesDuration': 1.6,
        }),
      ]);
      expect(
        lines[0],
        endsWith(
          ', limit none, encoder libvpx, target 1480 kbit/s, qp 36, '
          'resolution changed 2 times, held back bandwidth 7 s',
        ),
      );
      expect(lines[1], startsWith('video in VP8 1280x720 23 fps, '));
      expect(lines[1], endsWith(', 3 freezes (2 s)'));
    });

    test('what the processor and the voice went through: encode and decode '
        'time, camera frames not encoded, concealed voice, jitter buffer, '
        'and the round trip of the media', () {
      final List<String> lines = describeCallStats(<StatsReport>[
        report('C1', 'codec', <String, dynamic>{'mimeType': 'video/VP8'}),
        report('C2', 'codec', <String, dynamic>{'mimeType': 'audio/opus'}),
        report('S1', 'media-source', <String, dynamic>{
          'kind': 'video',
          'frames': 1440,
          'width': 1280,
          'height': 720,
          'framesPerSecond': 24.0,
        }),
        report('O1', 'outbound-rtp', <String, dynamic>{
          'kind': 'video',
          'codecId': 'C1',
          'mediaSourceId': 'S1',
          'framesEncoded': 1200,
          'frameWidth': 960,
          'frameHeight': 540,
          'framesPerSecond': 20.0,
          'qualityLimitationReason': 'cpu',
          'totalEncodeTime': 42.6,
        }),
        report('I1', 'inbound-rtp', <String, dynamic>{
          'kind': 'video',
          'codecId': 'C1',
          'framesDecoded': 1000,
          'totalDecodeTime': 9.0,
        }),
        report('I2', 'inbound-rtp', <String, dynamic>{
          'kind': 'audio',
          'codecId': 'C2',
          'packetsReceived': 3000,
          'bytesReceived': 120 * 1024,
          'packetsLost': 12,
          'totalSamplesReceived': 2880000,
          'concealedSamples': 72000,
          'concealmentEvents': 31,
          'jitterBufferDelay': 360000.0,
          'jitterBufferEmittedCount': 2880000,
          'jitter': 0.0214,
        }),
        report('R1', 'remote-inbound-rtp', <String, dynamic>{
          'kind': 'audio',
          'roundTripTime': 0.4127,
          'packetsLost': 5,
        }),
      ]);
      expect(lines[0], startsWith('camera 1280x720, 1440 frames captured'));
      expect(lines[1], startsWith('video out VP8 960x540 20 fps, '));
      expect(
        lines[1],
        endsWith(
          ', limit cpu, encode 35.5 ms/frame, 240 camera frames not encoded',
        ),
      );
      expect(lines[2], endsWith(', decode 9.0 ms/frame'));
      expect(
        lines[3],
        'audio in opus, 3000 packets, 120 KB, lost 12, concealed 2.5% '
        '(31 times), jitter buffer 125 ms, jitter 21 ms',
      );
      expect(lines[4], 'audio out reached the other side, rtt 413 ms, lost 5');
    });
  });
}
