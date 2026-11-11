import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:zen/src/core/logging/zen_log.dart';

// Which video codecs a call uses: VP8 first, H.264 only behind it, nothing
// else.
//
// Every frame of a call is sealed end to end by WebRTC's frame transformer
// (call_media_e2ee.dart). The packetizer works on the sealed frame, so the
// transformer must leave in the clear whatever of the frame the packetizer
// reads: it does that for VP8 (10 bytes of a key frame, 3 of the others)
// and, by parsing NAL units, for H.264. The H.265 and AV1 packetizers
// read the frame's own units (NAL units, OBUs) too, and the transformer is
// not known to leave them alone; VP9 is not known to be handled either.
// Sealed wrongly, a frame is garbage to the other side's depacketizer and
// decoder: nothing is ever decoded and nothing reports it, the picture
// stays black while the sound is fine. WebRTC on Android lists the
// phone's hardware codecs first (H.264, H.265, VP9, AV1 on a recent
// phone), so two phones agree on one of them, while a call with a computer
// agrees on VP8. VP8 is in every WebRTC build (in software where the phone
// has no encoder for it), so preferring it costs no compatibility: an
// older Zen answers in the order offered, and its own offer is answered
// with VP8 first.
//
// The preferences are set on every video transceiver (the camera and the
// shared screen) right before each offer and answer. Where the platform
// refuses them, the local description is reordered instead
// ([setCallLocalDescription]).

/// Codec names that repair or protect the codecs kept (retransmission,
/// redundancy, forward error correction): kept with them.
const Set<String> _repairCodecs = <String>{
  'rtx',
  'red',
  'ulpfec',
  'flexfec-03',
};

/// The video codecs a call keeps, in order of preference.
const List<String> kCallVideoCodecOrder = <String>['VP8', 'H264'];

String _codecName(String mimeType) {
  final int slash = mimeType.indexOf('/');
  return slash < 0 ? mimeType : mimeType.substring(slash + 1);
}

/// [capabilities] (what this device's WebRTC can receive) reduced to the
/// codecs the frame encryption handles, VP8 first, then H.264 (its
/// profiles in the platform's order), then the repair formats. Empty when
/// neither VP8 nor H.264 is there (the defaults then stay).
List<RTCRtpCodecCapability> callVideoCodecPreferences(
  List<RTCRtpCodecCapability> capabilities,
) {
  final List<RTCRtpCodecCapability> preferred = <RTCRtpCodecCapability>[];
  for (final String wanted in kCallVideoCodecOrder) {
    for (final RTCRtpCodecCapability codec in capabilities) {
      if (_codecName(codec.mimeType).toUpperCase() == wanted) {
        preferred.add(codec);
      }
    }
  }
  if (preferred.isEmpty) {
    return const <RTCRtpCodecCapability>[];
  }
  for (final RTCRtpCodecCapability codec in capabilities) {
    if (_repairCodecs.contains(_codecName(codec.mimeType).toLowerCase())) {
      preferred.add(codec);
    }
  }
  return preferred;
}

/// What this device's WebRTC can receive for video (the list codec
/// preferences must come from), or what it can send when that is empty.
Future<List<RTCRtpCodecCapability>> platformVideoCodecCapabilities() async {
  final List<RTCRtpCodecCapability> receive =
      (await getRtpReceiverCapabilities('video')).codecs ??
      const <RTCRtpCodecCapability>[];
  if (receive.isNotEmpty) {
    return receive;
  }
  return (await getRtpSenderCapabilities('video')).codecs ??
      const <RTCRtpCodecCapability>[];
}

/// Where [preferCallVideoCodecs] reads the capabilities (replaced in
/// tests).
typedef VideoCodecCapabilities = Future<List<RTCRtpCodecCapability>> Function();

bool _isVideoTransceiver(RTCRtpTransceiver transceiver) {
  final String? kind =
      transceiver.receiver.track?.kind ?? transceiver.sender.track?.kind;
  return kind == 'video';
}

/// Sets [callVideoCodecPreferences] on every video transceiver of
/// [connection] (the camera's and the shared screen's). Never throws: a
/// platform that refuses keeps its defaults, and the technical log says so.
/// Returns how many transceivers took the preferences.
Future<int> preferCallVideoCodecs(
  RTCPeerConnection connection, {
  VideoCodecCapabilities capabilities = platformVideoCodecCapabilities,
}) async {
  final List<RTCRtpCodecCapability> preferred;
  try {
    preferred = callVideoCodecPreferences(await capabilities());
  } on Object catch (error) {
    logZenWarning('Call video codecs: no capabilities ($error), defaults kept');
    return 0;
  }
  if (preferred.isEmpty) {
    logZenWarning(
      'Call video codecs: neither VP8 nor H264 here, defaults kept',
    );
    return 0;
  }
  final List<RTCRtpTransceiver> transceivers;
  try {
    transceivers = await connection.getTransceivers();
  } on Object catch (error) {
    logZenWarning('Call video codecs: transceivers unreadable ($error)');
    return 0;
  }
  // No other call on the connection in between: flutter_webrtc on Android
  // finds a transceiver that has no mid yet only until the next listing.
  int set = 0;
  int refused = 0;
  for (final RTCRtpTransceiver transceiver in transceivers) {
    if (!_isVideoTransceiver(transceiver)) {
      continue;
    }
    try {
      await transceiver.setCodecPreferences(preferred);
      set += 1;
    } on Object catch (error) {
      refused += 1;
      logZenWarning('Call video codecs: preferences refused ($error)');
    }
  }
  if (set > 0 || refused > 0) {
    final List<String> names = <String>[];
    for (final RTCRtpCodecCapability codec in preferred) {
      final String name = _codecName(codec.mimeType);
      if (!names.contains(name)) {
        names.add(name);
      }
    }
    logZenMessage(
      'Call video codecs preferred: ${names.join(' ')} on $set video '
      'slot(s)${refused > 0 ? ', refused on $refused' : ''}',
    );
  }
  return set;
}

/// An offer or answer of [connection] made after the video codecs were
/// preferred ([preferCallVideoCodecs]); the platform's error in making it
/// goes to the caller as before.
Future<RTCSessionDescription> createCallDescription(
  RTCPeerConnection connection, {
  required bool offer,
  Map<String, dynamic> constraints = const <String, dynamic>{},
  VideoCodecCapabilities capabilities = platformVideoCodecCapabilities,
}) async {
  await preferCallVideoCodecs(connection, capabilities: capabilities);
  return offer
      ? connection.createOffer(constraints)
      : connection.createAnswer(constraints);
}

/// The m-sections of [sdp] as lists of lines (the session part first).
List<List<String>> _sections(List<String> lines) {
  final List<List<String>> sections = <List<String>>[<String>[]];
  for (final String line in lines) {
    if (line.startsWith('m=')) {
      sections.add(<String>[]);
    }
    sections.last.add(line);
  }
  return sections;
}

/// Payload type -> codec name, and RTX payload -> the payload it repairs,
/// of one m-section.
(Map<String, String>, Map<String, String>) _payloads(List<String> section) {
  final Map<String, String> names = <String, String>{};
  final Map<String, String> repairs = <String, String>{};
  for (final String raw in section) {
    final String line = raw.trim();
    if (line.startsWith('a=rtpmap:')) {
      final String rest = line.substring('a=rtpmap:'.length);
      final int space = rest.indexOf(' ');
      if (space > 0) {
        names[rest.substring(0, space)] = rest
            .substring(space + 1)
            .split('/')
            .first;
      }
    } else if (line.startsWith('a=fmtp:')) {
      final String rest = line.substring('a=fmtp:'.length);
      final int space = rest.indexOf(' ');
      if (space > 0) {
        final RegExpMatch? apt = RegExp(
          r'(?:^|;)\s*apt=(\d+)',
        ).firstMatch(rest.substring(space + 1));
        if (apt != null) {
          repairs[rest.substring(0, space)] = apt.group(1)!;
        }
      }
    }
  }
  return (names, repairs);
}

/// The first codec (not a repair format) of the first video m-section of
/// [sdp]: the one both sides send with once it is an answer. Null without
/// a video section.
String? firstVideoCodecInSdp(String sdp) {
  for (final List<String> section in _sections(sdp.split(RegExp(r'\r?\n')))) {
    final String head = section.first.trim();
    if (!head.startsWith('m=video')) {
      continue;
    }
    final (Map<String, String> names, Map<String, String> _) = _payloads(
      section,
    );
    final List<String> parts = head.split(' ');
    for (final String payload in parts.skip(3)) {
      final String? name = names[payload];
      if (name != null && !_repairCodecs.contains(name.toLowerCase())) {
        return name;
      }
    }
    return null;
  }
  return null;
}

/// [sdp] with each video m-section's payload list reordered: VP8 and its
/// RTX first, then H.264 and theirs, then everything else as it was. Only
/// the order of the `m=` line changes; every other line stays.
String preferVp8InSdp(String sdp) {
  if (sdp.isEmpty) {
    return sdp;
  }
  final String separator = sdp.contains('\r\n') ? '\r\n' : '\n';
  final List<List<String>> sections = _sections(sdp.split(RegExp(r'\r?\n')));
  for (final List<String> section in sections) {
    final String head = section.first;
    if (!head.trim().startsWith('m=video')) {
      continue;
    }
    final (Map<String, String> names, Map<String, String> repairs) = _payloads(
      section,
    );
    final List<String> parts = head.trim().split(' ');
    if (parts.length <= 3) {
      continue;
    }
    final List<String> payloads = parts.sublist(3);
    final List<String> ordered = <String>[];
    for (final String wanted in kCallVideoCodecOrder) {
      for (final String payload in payloads) {
        if (names[payload]?.toUpperCase() == wanted &&
            !ordered.contains(payload)) {
          ordered.add(payload);
          for (final String repair in payloads) {
            if (repairs[repair] == payload && !ordered.contains(repair)) {
              ordered.add(repair);
            }
          }
        }
      }
    }
    for (final String payload in payloads) {
      if (!ordered.contains(payload)) {
        ordered.add(payload);
      }
    }
    section[0] = <String>[...parts.sublist(0, 3), ...ordered].join(' ');
  }
  return <String>[for (final List<String> s in sections) ...s].join(separator);
}

/// Sets [description] as [connection]'s local description. When the codec
/// preferences did not take (its first video codec is not VP8 although
/// VP8 is in the list), the video codecs are reordered first
/// ([preferVp8InSdp]); a platform that refuses the reordered form gets the
/// description as it was made. Returns the description set, which is the
/// one to send.
Future<RTCSessionDescription> setCallLocalDescription(
  RTCPeerConnection connection,
  RTCSessionDescription description,
) async {
  final String sdp = description.sdp ?? '';
  final String? first = firstVideoCodecInSdp(sdp);
  if (first != null && first.toUpperCase() != 'VP8') {
    final String reordered = preferVp8InSdp(sdp);
    final String? now = firstVideoCodecInSdp(reordered);
    if (now != null && now.toUpperCase() == 'VP8') {
      logZenWarning(
        'Call video codecs: $first came first despite the preferences; '
        'VP8 moved to the front of the ${description.type}',
      );
      final RTCSessionDescription moved = RTCSessionDescription(
        reordered,
        description.type,
      );
      try {
        await connection.setLocalDescription(moved);
        return moved;
      } on Object catch (error) {
        logZenWarning(
          'Call video codecs: the reordered ${description.type} was refused '
          '($error); $first stays',
        );
      }
    }
  }
  await connection.setLocalDescription(description);
  return description;
}
