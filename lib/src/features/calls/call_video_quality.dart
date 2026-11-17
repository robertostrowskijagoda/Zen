import 'package:flutter_webrtc/flutter_webrtc.dart';

// What a call asks of the camera and of the camera's encoder, so the
// picture stays steady and sharp when it moves and when the light is poor.
//
// The technical log of a call on two Android phones (13 November 2026,
// evening light) showed the picture going out at 5-6 frames a second with
// no limit named by WebRTC ("limit none") while the path's estimate was
// 3.5 Mbit/s: the camera itself delivered 5-6 frames ("captured at 5
// fps"). Three things added up:
//
// - The camera was never asked for what Zen meant. flutter_webrtc on
//   Android reads a constraint only as a plain number (a map such as
//   `{'ideal': 24}` is skipped, a bug of the plugin), so every call opened
//   the camera at the plugin's default, 1280 x 720 at 30 frames.
// - WebRTC's Android camera then picks the frame-rate range with the
//   lowest floor it can find (7-30 on most phones: "to allow the framerate
//   to fluctuate based on lighting conditions"). In poor light the
//   camera's auto-exposure goes down to that floor: long exposures, a few
//   frames a second, each smeared by any movement.
// - The encoder started at WebRTC's 300 kbit/s and climbed for seconds;
//   1280 x 720 in VP8 from that start is blocks, worst while it moves.
//
// So the camera is asked for 1280 x 720 at 24 frames in plain numbers
// ([callCameraConstraints]); on Android its auto-exposure range is pinned,
// once the camera runs, to the steadiest range it offers
// ([chooseCameraFrameRateRange], applied by ZenCallCamera.kt); the encoder
// starts at [kCallVideoStartBitrate] ([withCallVideoStartBitrate]) and
// keeps up to [kCallVideoMaxBitrate] at up to [kCallVideoFrameRate]
// frames ([tuneCallCameraParameters]).
//
// It stays adaptive: on a path that carries less than the start, WebRTC's
// estimate comes down within a second or two, and on a path that carries
// little the frames keep coming at a lower resolution
// ([RTCDegradationPreference.MAINTAIN_FRAMERATE]) rather than the picture
// stopping. A frozen picture is worse than a soft one.
//
// The voice comes first (since 1.17.6). 1.17.5 encoded the camera at
// 1280 x 720 and 24 frames whatever the light, up to 2.5 Mbit/s from a
// start of 1 Mbit/s and never below 150 kbit/s, with WebRTC's watch on the
// processor switched off (`googCpuOveruseDetection: false` since 1.10.0).
// The camera is VP8 in software on most phones (call_video_codecs.dart),
// each frame is sealed (call_media_e2ee.dart), the other side's picture is
// decoded in software too, and every packet goes through Yggdrasil's own
// encryption in the same app: in poor light 1.17.1 encoded 5 frames a
// second, 1.17.5 encoded 24 at full size, and calls stuttered, the voice
// too. Over Yggdrasil's TCP links whatever the path cannot carry waits in
// a queue, and the voice waits behind it. So:
//
// - WebRTC watches the processor again ([kCallPeerConstraints]): an
//   encoder that cannot keep up lowers the resolution before the voice
//   starves;
// - the camera is encoded at most at [kCallVideoSendWidth] x
//   [kCallVideoSendHeight] ([kCallVideoScaleDownBy]), about half the work
//   of 1280 x 720 for VP8 in software, here and on the other's decoder;
// - the ceiling is [kCallVideoMaxBitrate], the start
//   [kCallVideoStartBitrateKbps], and there is no floor of Zen's own: on a
//   path that carries little the picture gives way down to WebRTC's own
//   minimum instead of keeping 150 kbit/s queued ahead of the voice.
//
// The camera's frame rate in poor light stays as 1.17.5 fixed it: asked
// for 24 frames and pinned to its steadiest range.

/// The frames a second a call's camera is asked for and its encoder sends
/// at most.
const int kCallVideoFrameRate = 24;

/// The lowest frame rate the camera's auto-exposure may go down to, where
/// the camera offers such a range: below it a moving picture judders and
/// smears.
const int kCallCameraMinFrameRate = 15;

/// The size a call's camera is asked for: one every phone camera has in
/// 16:9 (a smaller size asked of a camera may come back 4:3).
const int kCallCameraWidth = 1280;
const int kCallCameraHeight = 720;

/// The largest picture the camera's encoder sends: sharp on a phone's
/// screen, about half the processor's work of 1280 x 720 in VP8 in
/// software, on this phone's encoder and on the other's decoder.
const int kCallVideoSendWidth = 960;
const int kCallVideoSendHeight = 540;

/// How much the encoder scales the camera's picture down
/// ([kCallCameraWidth] to [kCallVideoSendWidth]). A camera that gives less
/// than it was asked is scaled by as much.
const double kCallVideoScaleDownBy = kCallCameraWidth / kCallVideoSendWidth;

/// The most a call's camera sends, in bits per second: 960 x 540 at 24
/// frames in VP8 is sharp at it. It is a ceiling, not a rate: WebRTC sends
/// what the path carries. 1.17.5's 2.5 Mbit/s filled Yggdrasil's links
/// ahead of the voice.
const int kCallVideoMaxBitrate = 1200000;

/// Where WebRTC's estimate of the path starts, in kbit/s (the SDP
/// `x-google-start-bitrate`): above WebRTC's own 300 kbit/s, so the first
/// seconds are not soft, and half of 1.17.5's 1 Mbit/s, which a relayed
/// path may not carry. WebRTC probes upwards from it in the first seconds.
const int kCallVideoStartBitrateKbps = 500;

/// [kCallVideoStartBitrateKbps] in bits per second.
const int kCallVideoStartBitrate = kCallVideoStartBitrateKbps * 1000;

/// What every peer connection of a call is made with
/// (`createPeerConnection`'s constraints). `googCpuOveruseDetection` lets
/// WebRTC lower the camera's resolution when the encoder cannot keep up:
/// it was off from 1.10.0 to 1.17.5, and a phone that could not keep up
/// starved the voice instead. `googSuspendBelowMinBitrate` off keeps a
/// small picture coming on a tight path rather than none.
const Map<String, dynamic> kCallPeerConstraints = <String, dynamic>{
  'mandatory': <String, dynamic>{},
  'optional': <Map<String, dynamic>>[
    <String, dynamic>{'googDscp': true},
    <String, dynamic>{'googCpuOveruseDetection': true},
    <String, dynamic>{'googSuspendBelowMinBitrate': false},
  ],
};

/// The camera of a call, as getUserMedia takes it: on a phone ([mobile])
/// plain numbers only (flutter_webrtc on Android skips a map such as
/// `{'ideal': 960}` and opened the camera at its own default), the front
/// camera unless a [deviceId] is chosen; on a computer the same size and
/// rate with the device as both `deviceId` and the older `sourceId`.
Map<String, dynamic> callCameraConstraints({
  String? deviceId,
  required bool mobile,
}) {
  final bool chosen = deviceId != null && deviceId.isNotEmpty;
  if (mobile) {
    return <String, dynamic>{
      if (chosen) 'deviceId': deviceId else 'facingMode': 'user',
      'width': kCallCameraWidth,
      'height': kCallCameraHeight,
      'frameRate': kCallVideoFrameRate,
    };
  }
  return <String, dynamic>{
    if (chosen) 'deviceId': deviceId,
    if (chosen)
      'optional': <Map<String, dynamic>>[
        <String, dynamic>{'sourceId': deviceId},
      ],
    'width': kCallCameraWidth,
    'height': kCallCameraHeight,
    'frameRate': kCallVideoFrameRate,
  };
}

/// Sets what a camera sender of a call keeps to ([parameters] of its
/// sender): every encoding up to [kCallVideoMaxBitrate] with no floor of
/// Zen's own, at up to [kCallVideoFrameRate] frames and at most
/// [kCallVideoSendWidth] x [kCallVideoSendHeight] ([kCallVideoScaleDownBy]),
/// and frames kept before resolution when the path or the processor is
/// tight. False when there is no encoding to set.
bool tuneCallCameraParameters(RTCRtpParameters parameters) {
  final List<RTCRtpEncoding> encodings =
      parameters.encodings ?? const <RTCRtpEncoding>[];
  if (encodings.isEmpty) {
    return false;
  }
  for (final RTCRtpEncoding encoding in encodings) {
    encoding.maxBitrate = kCallVideoMaxBitrate;
    encoding.minBitrate = null;
    encoding.maxFramerate = kCallVideoFrameRate;
    encoding.scaleResolutionDownBy = kCallVideoScaleDownBy;
  }
  parameters.degradationPreference =
      RTCDegradationPreference.MAINTAIN_FRAMERATE;
  return true;
}

/// A frame-rate range a camera offers for its auto-exposure, in frames a
/// second.
typedef CameraFrameRateRange = ({int min, int max});

/// The range of [offered] the camera's auto-exposure is pinned to: the
/// highest floor up to [kCallVideoFrameRate] that is at least
/// [kCallCameraMinFrameRate] (24-24 where the camera has it, else 15-30
/// and the like), its top as close to [kCallVideoFrameRate] as offered;
/// without such a floor the lowest floor above it (30-30, darker in poor
/// light but never slower). Null when every range may go below
/// [kCallCameraMinFrameRate] (the camera's own choice then stays) or
/// nothing is offered. A range whose top is below its floor is no range.
CameraFrameRateRange? chooseCameraFrameRateRange(
  Iterable<CameraFrameRateRange> offered,
) {
  final List<CameraFrameRateRange> steady = <CameraFrameRateRange>[
    for (final CameraFrameRateRange r in offered)
      if (r.min >= kCallCameraMinFrameRate && r.max >= r.min) r,
  ];
  if (steady.isEmpty) {
    return null;
  }
  int topDistance(CameraFrameRateRange r) =>
      (r.max - kCallVideoFrameRate).abs();
  final List<CameraFrameRateRange> within = <CameraFrameRateRange>[
    for (final CameraFrameRateRange r in steady)
      if (r.min <= kCallVideoFrameRate) r,
  ];
  if (within.isNotEmpty) {
    within.sort((CameraFrameRateRange a, CameraFrameRateRange b) {
      final int byFloor = b.min.compareTo(a.min);
      if (byFloor != 0) {
        return byFloor;
      }
      final int byTop = topDistance(a).compareTo(topDistance(b));
      return byTop != 0 ? byTop : b.max.compareTo(a.max);
    });
    return within.first;
  }
  steady.sort((CameraFrameRateRange a, CameraFrameRateRange b) {
    final int byFloor = a.min.compareTo(b.min);
    return byFloor != 0 ? byFloor : a.max.compareTo(b.max);
  });
  return steady.first;
}

/// The ranges in [raw] as the Android side sends them (a list of
/// `[min, max]` lists of numbers); anything else in it is skipped.
List<CameraFrameRateRange> cameraFrameRateRanges(Object? raw) {
  if (raw is! List) {
    return const <CameraFrameRateRange>[];
  }
  return <CameraFrameRateRange>[
    for (final Object? pair in raw)
      if (pair is List && pair.length == 2 && pair[0] is int && pair[1] is int)
        (min: pair[0] as int, max: pair[1] as int),
  ];
}

/// `min-max` of [range], as the technical log writes it.
String describeCameraFrameRateRange(CameraFrameRateRange range) =>
    '${range.min}-${range.max}';

/// The other side's [sdp] with `x-google-start-bitrate` (in kbit/s,
/// [kCallVideoStartBitrateKbps]) on the VP8 and H.264 formats of the
/// camera's video section (the first `m=video`). WebRTC takes the codec
/// parameters this side sends with from the other side's description, so
/// that is where the start goes; the screen slot and audio stay as they
/// were, and a format that already names a start keeps it.
String withCallVideoStartBitrate(String sdp) {
  if (sdp.isEmpty) {
    return sdp;
  }
  final String separator = sdp.contains('\r\n') ? '\r\n' : '\n';
  final List<String> lines = sdp.split(RegExp(r'\r?\n'));
  // The camera section's VP8 and H.264 payload types, and which of them
  // have an fmtp line.
  final Set<String> payloads = <String>{};
  final Set<String> withFmtp = <String>{};
  bool seenVideo = false;
  bool inCamera = false;
  for (final String raw in lines) {
    final String line = raw.trim();
    if (line.startsWith('m=')) {
      inCamera = !seenVideo && line.startsWith('m=video');
      seenVideo = seenVideo || line.startsWith('m=video');
      continue;
    }
    if (!inCamera) {
      continue;
    }
    final RegExpMatch? rtpmap = RegExp(
      r'^a=rtpmap:(\d+) ([A-Za-z0-9-]+)/',
    ).firstMatch(line);
    if (rtpmap != null) {
      final String name = rtpmap.group(2)!.toUpperCase();
      if (name == 'VP8' || name == 'H264') {
        payloads.add(rtpmap.group(1)!);
      }
      continue;
    }
    final RegExpMatch? fmtp = RegExp(r'^a=fmtp:(\d+) ').firstMatch(line);
    if (fmtp != null) {
      withFmtp.add(fmtp.group(1)!);
    }
  }
  if (payloads.isEmpty) {
    return sdp;
  }
  const String key = 'x-google-start-bitrate';
  final String value = '$key=$kCallVideoStartBitrateKbps';
  final List<String> result = <String>[];
  seenVideo = false;
  inCamera = false;
  for (final String raw in lines) {
    final String line = raw.trim();
    if (line.startsWith('m=')) {
      inCamera = !seenVideo && line.startsWith('m=video');
      seenVideo = seenVideo || line.startsWith('m=video');
      result.add(raw);
      continue;
    }
    if (inCamera) {
      final RegExpMatch? fmtp = RegExp(r'^a=fmtp:(\d+) ').firstMatch(line);
      if (fmtp != null &&
          payloads.contains(fmtp.group(1)) &&
          !line.contains(key)) {
        result.add('$line;$value');
        continue;
      }
      final RegExpMatch? rtpmap = RegExp(r'^a=rtpmap:(\d+) ').firstMatch(line);
      result.add(raw);
      if (rtpmap != null &&
          payloads.contains(rtpmap.group(1)) &&
          !withFmtp.contains(rtpmap.group(1))) {
        result.add('a=fmtp:${rtpmap.group(1)} $value');
      }
      continue;
    }
    result.add(raw);
  }
  return result.join(separator);
}
