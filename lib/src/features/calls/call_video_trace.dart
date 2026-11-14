import 'package:flutter_webrtc/flutter_webrtc.dart' show StatsReport;

// What the technical log says about a call's media, so that one test call
// tells where a picture that never shows is lost: never encoded or never
// sent (the sender), lost on the way (sent on one phone, not received on
// the other), received but never opened (the frame keys), or decoded but
// never on the screen (the renderer).
//
// Nothing here writes an address, a key, a fingerprint, an ICE credential
// or SDP text: only kinds, directions, codec names, counts, sizes and
// states. The lines are short; a call writes a handful of them.

/// Payload names that are not a codec of their own (retransmissions,
/// redundancy, comfort noise, DTMF).
const Set<String> _notCodecs = <String>{
  'rtx',
  'red',
  'ulpfec',
  'flexfec-03',
  'cn',
  'telephone-event',
};

/// One line about an SDP: each m-section's kind, mid, direction, whether
/// this side sends on it (it names an SSRC), its codecs in the order
/// offered (at most five), the feedback the first video codec asks for
/// (nack, pli, fir, transport-cc, remb), and the size in bytes.
///
/// `audio#0 sendrecv sends opus; video#1 sendrecv sends VP8 VP9 H264 fb
/// nack,pli,fir,tcc; 5321 B`
String describeCallSdp(String sdp) {
  if (sdp.isEmpty) {
    return 'empty';
  }
  final List<_SdpSection> sections = <_SdpSection>[];
  _SdpSection? current;
  for (final String raw in sdp.split(RegExp(r'\r?\n'))) {
    final String line = raw.trim();
    if (line.startsWith('m=')) {
      final List<String> parts = line.substring(2).split(' ');
      current = _SdpSection(
        parts.isEmpty ? '?' : parts.first,
        parts.length > 3 ? parts.sublist(3) : const <String>[],
      );
      sections.add(current);
      continue;
    }
    final _SdpSection? section = current;
    if (section == null) {
      continue;
    }
    if (line.startsWith('a=mid:')) {
      section.mid = line.substring('a=mid:'.length).trim();
    } else if (line == 'a=sendrecv' ||
        line == 'a=sendonly' ||
        line == 'a=recvonly' ||
        line == 'a=inactive') {
      section.direction = line.substring(2);
    } else if (line.startsWith('a=ssrc:')) {
      section.sends = true;
    } else if (line.startsWith('a=rtpmap:')) {
      final String rest = line.substring('a=rtpmap:'.length);
      final int space = rest.indexOf(' ');
      if (space > 0) {
        final String name = rest.substring(space + 1).split('/').first;
        section.names[rest.substring(0, space)] = name;
      }
    } else if (line.startsWith('a=rtcp-fb:')) {
      final String rest = line.substring('a=rtcp-fb:'.length);
      final int space = rest.indexOf(' ');
      if (space > 0) {
        (section.feedback[rest.substring(0, space)] ??= <String>{}).add(
          rest.substring(space + 1).trim(),
        );
      }
    }
  }
  final List<String> parts = <String>[
    for (final _SdpSection section in sections) section.describe(),
  ];
  return '${parts.join('; ')}; ${sdp.length} B';
}

final class _SdpSection {
  _SdpSection(this.kind, this.payloads);

  final String kind;
  final List<String> payloads;
  final Map<String, String> names = <String, String>{};
  final Map<String, Set<String>> feedback = <String, Set<String>>{};
  String? mid;
  String direction = 'sendrecv';
  bool sends = false;

  String describe() {
    final List<String> codecs = <String>[];
    String? firstPayload;
    for (final String payload in payloads) {
      final String? name = names[payload];
      if (name == null || _notCodecs.contains(name.toLowerCase())) {
        continue;
      }
      firstPayload ??= payload;
      if (!codecs.contains(name) && codecs.length < 5) {
        codecs.add(name);
      }
    }
    final StringBuffer out = StringBuffer('$kind#${mid ?? '?'} $direction');
    if (sends) {
      out.write(' sends');
    }
    if (codecs.isNotEmpty) {
      out.write(' ${codecs.join(' ')}');
    }
    if (kind == 'video' && firstPayload != null) {
      final Set<String> fb = <String>{
        ...?feedback['*'],
        ...?feedback[firstPayload],
      };
      final List<String> named = <String>[
        if (fb.contains('nack')) 'nack',
        if (fb.contains('nack pli')) 'pli',
        if (fb.contains('ccm fir')) 'fir',
        if (fb.contains('transport-cc')) 'tcc',
        if (fb.contains('goog-remb')) 'remb',
      ];
      out.write(' fb ${named.isEmpty ? 'none' : named.join(',')}');
    }
    return out.toString();
  }
}

/// Short lines about a call's statistics (`RTCPeerConnection.getStats`):
/// for audio and video, what went out and what came in, and the path's
/// totals. A side whose camera sends shows `video out` with frames encoded
/// and packets sent; the other side shows `video in` with packets
/// received, frames received (put together from the packets) and frames
/// decoded (after their keys opened them). PLI and FIR count the requests
/// for a key frame. No address, id or SSRC is written.
List<String> describeCallStats(List<StatsReport> reports) {
  final Map<String, String> codecs = _codecNames(reports);
  String codecOf(Map<dynamic, dynamic> values) {
    final Object? id = values['codecId'];
    return id is String ? codecs[id] ?? '?' : '?';
  }

  final List<String> lines = <String>[];
  for (final StatsReport report in reports) {
    final Map<dynamic, dynamic> v = report.values;
    final Object? kind = v['kind'] ?? v['mediaType'];
    if (report.type == 'outbound-rtp' && kind == 'video') {
      lines.add(
        'video out ${codecOf(v)} ${_size(v)}'
        '${_has(v, 'framesPerSecond') ? ' ${_int(v['framesPerSecond'])} fps' : ''}, '
        '${_int(v['framesEncoded'])} frames '
        '(${_int(v['keyFramesEncoded'])} key), '
        '${_int(v['packetsSent'])} packets, ${_kb(v['bytesSent'])}, '
        'nack ${_int(v['nackCount'])} pli ${_int(v['pliCount'])} '
        'fir ${_int(v['firCount'])}'
        '${v['active'] == false ? ', INACTIVE' : ''}'
        '${_text(v, 'qualityLimitationReason', 'limit')}'
        '${_text(v, 'encoderImplementation', 'encoder')}'
        '${_videoOutQuality(v)}',
      );
    } else if (report.type == 'inbound-rtp' && kind == 'video') {
      lines.add(
        'video in ${codecOf(v)} ${_size(v)}'
        '${_has(v, 'framesPerSecond') ? ' ${_int(v['framesPerSecond'])} fps' : ''}, '
        '${_int(v['packetsReceived'])} packets, ${_kb(v['bytesReceived'])}, '
        'lost ${_int(v['packetsLost'])}, '
        'received ${_int(v['framesReceived'])} frames, '
        'decoded ${_int(v['framesDecoded'])} '
        '(${_int(v['keyFramesDecoded'])} key), '
        'dropped ${_int(v['framesDropped'])}, '
        'nack ${_int(v['nackCount'])} pli ${_int(v['pliCount'])} '
        'fir ${_int(v['firCount'])}'
        '${_text(v, 'decoderImplementation', 'decoder')}'
        '${_int(v['freezeCount']) > 0 ? ', ${_int(v['freezeCount'])} freezes '
                  '(${_seconds(v['totalFreezesDuration'])})' : ''}',
      );
    } else if (report.type == 'outbound-rtp' && kind == 'audio') {
      lines.add(
        'audio out ${codecOf(v)}, ${_int(v['packetsSent'])} packets, '
        '${_kb(v['bytesSent'])}',
      );
    } else if (report.type == 'inbound-rtp' && kind == 'audio') {
      lines.add(
        'audio in ${codecOf(v)}, ${_int(v['packetsReceived'])} packets, '
        '${_kb(v['bytesReceived'])}, lost ${_int(v['packetsLost'])}',
      );
    } else if (report.type == 'media-source' && kind == 'video') {
      lines.add(
        'camera ${_size(v)}, ${_int(v['frames'])} frames captured'
        '${_has(v, 'framesPerSecond') ? ' at ${_int(v['framesPerSecond'])} fps' : ''}',
      );
    } else if (report.type == 'candidate-pair' &&
        v['state'] == 'succeeded' &&
        v['nominated'] == true) {
      final Object? rtt = v['currentRoundTripTime'];
      final Object? rate = v['availableOutgoingBitrate'];
      lines.add(
        'path ${_kb(v['bytesSent'])} out, ${_kb(v['bytesReceived'])} in'
        '${rtt is num ? ', rtt ${(rtt * 1000).round()} ms' : ''}'
        '${rate is num ? ', estimate ${(rate / 1000).round()} kbit/s' : ''}',
      );
    }
  }
  if (!lines.any((String l) => l.startsWith('video '))) {
    lines.add('no video stream either way');
  }
  return lines;
}

/// What a call's video does at one look at its statistics: the codec and
/// the encoder of the video going out, the codec and the decoder of the
/// video coming in. Null where nothing goes out or comes in.
typedef CallVideoPath = ({
  String? sends,
  String? encoder,
  String? receives,
  String? decoder,
});

/// The [CallVideoPath] of [reports]. With two videos either way (the
/// camera and a shared screen), the one with the most frames; coming in,
/// the one of [receivedTrackId] (the camera on the screen) when it is
/// named.
CallVideoPath callVideoPath(
  List<StatsReport> reports, {
  String? receivedTrackId,
}) {
  final Map<String, String> codecs = _codecNames(reports);
  Map<dynamic, dynamic>? out;
  Map<dynamic, dynamic>? into;
  for (final StatsReport report in reports) {
    final Map<dynamic, dynamic> v = report.values;
    if ((v['kind'] ?? v['mediaType']) != 'video') {
      continue;
    }
    if (report.type == 'outbound-rtp') {
      if (out == null ||
          _int(v['framesEncoded']) > _int(out['framesEncoded'])) {
        out = v;
      }
    } else if (report.type == 'inbound-rtp') {
      final bool named =
          receivedTrackId != null && v['trackIdentifier'] == receivedTrackId;
      final bool namedBefore =
          receivedTrackId != null &&
          into != null &&
          into['trackIdentifier'] == receivedTrackId;
      if (into == null ||
          (named && !namedBefore) ||
          (!namedBefore &&
              _int(v['framesDecoded']) > _int(into['framesDecoded']))) {
        into = v;
      }
    }
  }
  String? codecOf(Map<dynamic, dynamic>? values) {
    if (values == null) {
      return null;
    }
    final Object? id = values['codecId'];
    return id is String ? codecs[id] ?? '?' : '?';
  }

  String? text(Map<dynamic, dynamic>? values, String key) {
    final Object? value = values?[key];
    if (value is! String || value.isEmpty) {
      return null;
    }
    return value.length > 48 ? value.substring(0, 48) : value;
  }

  return (
    sends: codecOf(out),
    encoder: text(out, 'encoderImplementation'),
    receives: codecOf(into),
    decoder: text(into, 'decoderImplementation'),
  );
}

/// One plain line about [path]: `sends VP8 (encoder libvpx), receives VP8
/// (decoder libvpx)`.
String describeCallVideoPath(CallVideoPath path) {
  final String sends = path.sends == null
      ? 'sends no video'
      : 'sends ${path.sends} (encoder ${path.encoder ?? '?'})';
  final String receives = path.receives == null
      ? 'receives no video'
      : 'receives ${path.receives} (decoder ${path.decoder ?? '?'})';
  return '$sends, $receives';
}

/// How many frames of the other side's video were decoded so far: of the
/// video of [trackId] when the statistics name it, else of the video with
/// the most. Null without any video coming in.
int? remoteVideoFramesDecoded(List<StatsReport> reports, {String? trackId}) {
  int? most;
  for (final StatsReport report in reports) {
    final Map<dynamic, dynamic> v = report.values;
    if (report.type != 'inbound-rtp' ||
        (v['kind'] ?? v['mediaType']) != 'video') {
      continue;
    }
    final int decoded = _int(v['framesDecoded']);
    if (trackId != null && v['trackIdentifier'] == trackId) {
      return decoded;
    }
    if (most == null || decoded > most) {
      most = decoded;
    }
  }
  return most;
}

/// What the call does next about the other side's picture
/// ([RemotePictureWatch]).
enum RemotePictureStep {
  /// Nothing to do yet: look again later.
  wait,

  /// Frames are decoded and none reached the screen: bind the renderer to
  /// the track again.
  rebind,

  /// The picture is on the screen, or the watch gave up.
  done,
}

/// The safety net under the remote picture: frames of the other side's
/// camera are decoded (their count grows from one look to the next) while
/// the renderer, bound to that track, reported no frame on the screen. The
/// renderer is then bound again, at most [maxRebinds] times a call, and the
/// technical log says so.
final class RemotePictureWatch {
  RemotePictureWatch({this.maxRebinds = 3, this.maxLooks = 8});

  final int maxRebinds;

  /// After this many looks the watch ends whatever it saw.
  final int maxLooks;

  int _looks = 0;
  int _rebinds = 0;
  int? _decodedBefore;

  /// How many times the renderer was bound again.
  int get rebinds => _rebinds;

  /// How many looks were taken.
  int get looks => _looks;

  /// One look: [shown] whether a frame of the bound track reached the
  /// screen, [bound] whether the renderer has a remote track, [decoded]
  /// the frames decoded so far ([remoteVideoFramesDecoded]).
  RemotePictureStep look({
    required bool shown,
    required bool bound,
    required int? decoded,
  }) {
    _looks += 1;
    final int? before = _decodedBefore;
    if (decoded != null) {
      _decodedBefore = decoded;
    }
    if (shown || _looks > maxLooks) {
      return RemotePictureStep.done;
    }
    if (!bound || decoded == null || before == null || decoded <= before) {
      return RemotePictureStep.wait;
    }
    if (_rebinds >= maxRebinds) {
      return RemotePictureStep.done;
    }
    _rebinds += 1;
    return RemotePictureStep.rebind;
  }
}

Map<String, String> _codecNames(List<StatsReport> reports) {
  final Map<String, String> codecs = <String, String>{};
  for (final StatsReport report in reports) {
    if (report.type == 'codec') {
      final Object? mime = report.values['mimeType'];
      if (mime is String) {
        codecs[report.id] = mime.contains('/')
            ? mime.substring(mime.indexOf('/') + 1)
            : mime;
      }
    }
  }
  return codecs;
}

bool _has(Map<dynamic, dynamic> values, String key) => values[key] is num;

/// What judges a camera's picture going out, beyond its size and rate:
/// the bitrate the encoder aims at (`target`), its average quantizer
/// (`qp`, higher is blockier: VP8 from 4 to 127, around 30-50 a sharp
/// picture, above 80 blocks), how often it changed the resolution, and
/// for how long it was held back by the processor or the path in all.
/// Each part only when the statistics have it.
String _videoOutQuality(Map<dynamic, dynamic> v) {
  final StringBuffer out = StringBuffer();
  final Object? target = v['targetBitrate'];
  if (target is num && target > 0) {
    out.write(', target ${(target / 1000).round()} kbit/s');
  }
  final Object? qpSum = v['qpSum'];
  final int encoded = _int(v['framesEncoded']);
  if (qpSum is num && encoded > 0) {
    out.write(', qp ${(qpSum / encoded).round()}');
  }
  final int changes = _int(v['qualityLimitationResolutionChanges']);
  if (changes > 0) {
    out.write(', resolution changed $changes times');
  }
  final Object? durations = v['qualityLimitationDurations'];
  if (durations is Map) {
    final List<String> held = <String>[
      for (final String reason in const <String>['cpu', 'bandwidth', 'other'])
        if (durations[reason] is num && (durations[reason] as num) >= 0.5)
          '$reason ${_seconds(durations[reason])}',
    ];
    if (held.isNotEmpty) {
      out.write(', held back ${held.join(' ')}');
    }
  }
  return out.toString();
}

String _seconds(Object? value) =>
    '${value is num && value.isFinite ? value.round() : 0} s';

int _int(Object? value) => value is num && value.isFinite ? value.round() : 0;

String _kb(Object? value) => '${(_int(value) / 1024).round()} KB';

String _size(Map<dynamic, dynamic> values) {
  final int width = _int(values['frameWidth'] ?? values['width']);
  final int height = _int(values['frameHeight'] ?? values['height']);
  return width > 0 && height > 0 ? '${width}x$height' : 'no size';
}

/// `, <label> <value>` for a short text value (an implementation name, a
/// limitation reason), nothing when absent.
String _text(Map<dynamic, dynamic> values, String key, String label) {
  final Object? value = values[key];
  if (value is! String || value.isEmpty) {
    return '';
  }
  final String clipped = value.length > 48 ? value.substring(0, 48) : value;
  return ', $label $clipped';
}
