import 'package:flutter/foundation.dart';
import 'package:zen/src/features/calls/call_media_session.dart';

/// Platform-agnostic device row, so cataloguing can be unit-tested without
/// spinning up WebRTC.
@immutable
final class RawCallMediaDevice {
  const RawCallMediaDevice({
    required this.id,
    required this.label,
    required this.kind,
  });

  final String id;
  final String label;
  final String kind;
}

CallMediaDeviceKind? parseCallMediaDeviceKind(String kind) {
  switch (kind.trim().toLowerCase()) {
    case 'videoinput':
    case 'video':
      return CallMediaDeviceKind.camera;
    case 'audioinput':
    case 'audio':
      return CallMediaDeviceKind.microphone;
    case 'audiooutput':
      return CallMediaDeviceKind.speaker;
    default:
      return null;
  }
}

/// Turns the raw WebRTC device list into a stable, labelled catalogue.
///
/// Empty labels become "Mikrofon 1" / "Kamera 2" instead of collapsing every
/// unnamed input into a single generic row. On phones, speaker/earpiece are
/// always present because Android rarely reports `audiooutput` devices.
List<CallMediaDevice> catalogCallMediaDevices({
  required Iterable<RawCallMediaDevice> raw,
  bool includeMobileAudioOutputs = false,
  bool filterMobileCameras = false,
}) {
  final List<CallMediaDevice> cameras = <CallMediaDevice>[];
  final List<CallMediaDevice> microphones = <CallMediaDevice>[];
  final List<CallMediaDevice> speakers = <CallMediaDevice>[];
  final Set<String> seen = <String>{};

  for (final RawCallMediaDevice device in raw) {
    final CallMediaDeviceKind? kind = parseCallMediaDeviceKind(device.kind);
    if (kind == null) {
      continue;
    }
    final String id = device.id.trim();
    final String dedupeKey = id.isNotEmpty
        ? '${kind.name}:$id'
        : '${kind.name}:${device.label.trim().toLowerCase()}';
    if (!seen.add(dedupeKey)) {
      continue;
    }
    final CallMediaDevice mapped = CallMediaDevice(
      id: id,
      label: device.label.trim(),
      kind: kind,
    );
    switch (kind) {
      case CallMediaDeviceKind.camera:
        cameras.add(mapped);
      case CallMediaDeviceKind.microphone:
        microphones.add(mapped);
      case CallMediaDeviceKind.speaker:
        speakers.add(mapped);
    }
  }

  final List<CallMediaDevice> processedCameras = filterMobileCameras
      ? _filterAndLabelMobileCameras(cameras)
      : _withDistinctLabels(cameras, 'Kamera');
  final List<CallMediaDevice> numberedMics = _withDistinctLabels(
    microphones,
    'Mikrofon',
  );
  List<CallMediaDevice> numberedSpeakers = _withDistinctLabels(
    speakers,
    'Głośnik',
  );

  if (includeMobileAudioOutputs) {
    numberedSpeakers = _ensureMobileAudioOutputs(numberedSpeakers);
  }

  return <CallMediaDevice>[
    ...processedCameras,
    ...numberedMics,
    ...numberedSpeakers,
  ];
}

List<CallMediaDevice> _ensureMobileAudioOutputs(
  List<CallMediaDevice> speakers,
) {
  const CallMediaDevice speakerphone = CallMediaDevice(
    id: 'speakerphone',
    label: 'Głośnik',
    kind: CallMediaDeviceKind.speaker,
  );
  const CallMediaDevice earpiece = CallMediaDevice(
    id: 'earpiece',
    label: 'Słuchawka',
    kind: CallMediaDeviceKind.speaker,
  );
  final bool hasSpeakerphone = speakers.any(
    (CallMediaDevice device) =>
        device.id == 'speakerphone' ||
        device.label.toLowerCase().contains('głośnik') ||
        device.label.toLowerCase().contains('glosnik') ||
        device.label.toLowerCase().contains('speaker'),
  );
  final bool hasEarpiece = speakers.any(
    (CallMediaDevice device) =>
        device.id == 'earpiece' ||
        device.label.toLowerCase().contains('słuchawk') ||
        device.label.toLowerCase().contains('sluchawk') ||
        device.label.toLowerCase().contains('earpiece') ||
        device.label.toLowerCase().contains('headset'),
  );
  return <CallMediaDevice>[
    if (!hasSpeakerphone) speakerphone,
    if (!hasEarpiece) earpiece,
    ...speakers,
  ];
}

List<CallMediaDevice> _withDistinctLabels(
  List<CallMediaDevice> devices,
  String fallback,
) {
  if (devices.isEmpty) {
    return devices;
  }
  if (devices.length == 1) {
    final CallMediaDevice only = devices.single;
    return <CallMediaDevice>[
      CallMediaDevice(
        id: only.id,
        label: only.label.isEmpty ? fallback : only.label,
        kind: only.kind,
      ),
    ];
  }
  final Map<String, int> seenCounts = <String, int>{};
  final List<CallMediaDevice> labelled = <CallMediaDevice>[];
  for (int index = 0; index < devices.length; index += 1) {
    final CallMediaDevice device = devices[index];
    String label = device.label;
    if (label.isEmpty) {
      label = '$fallback ${index + 1}';
    } else {
      final int count = (seenCounts[label.toLowerCase()] ?? 0) + 1;
      seenCounts[label.toLowerCase()] = count;
      if (count > 1) {
        label = '$label ($count)';
      }
    }
    labelled.add(
      CallMediaDevice(id: device.id, label: label, kind: device.kind),
    );
  }
  return labelled;
}

List<CallMediaDevice> _filterAndLabelMobileCameras(
  List<CallMediaDevice> cameras,
) {
  if (cameras.isEmpty) {
    return cameras;
  }
  if (cameras.length == 1) {
    return <CallMediaDevice>[
      CallMediaDevice(
        id: cameras.first.id,
        label: cameras.first.label.isNotEmpty ? cameras.first.label : 'Kamera',
        kind: CallMediaDeviceKind.camera,
      ),
    ];
  }

  CallMediaDevice? frontCamera;
  CallMediaDevice? backCamera;

  for (final CallMediaDevice cam in cameras) {
    final String label = cam.label.toLowerCase();
    final String id = cam.id.trim();

    final bool isFront =
        label.contains('front') ||
        label.contains('przed') ||
        label.contains('selfie') ||
        label.contains('user') ||
        id == '1';

    final bool isBack =
        label.contains('back') ||
        label.contains('rear') ||
        label.contains('tył') ||
        label.contains('tyl') ||
        label.contains('environment') ||
        id == '0';

    if (isFront && frontCamera == null) {
      frontCamera = cam;
    } else if (isBack && backCamera == null) {
      backCamera = cam;
    }
  }

  // Fallbacks if one or both facings were not explicitly detected:
  if (frontCamera == null && backCamera == null) {
    if (cameras[0].id == '0' && cameras.length > 1) {
      backCamera = cameras[0];
      frontCamera = cameras[1];
    } else {
      frontCamera = cameras[0];
      if (cameras.length > 1) {
        backCamera = cameras[1];
      }
    }
  } else if (frontCamera == null) {
    frontCamera = cameras.firstWhere(
      (c) => c.id != backCamera?.id,
      orElse: () => cameras.first,
    );
  } else {
    backCamera ??= cameras.firstWhere(
      (c) => c.id != frontCamera?.id,
      orElse: () => cameras.last,
    );
  }

  final List<CallMediaDevice> result = <CallMediaDevice>[
    CallMediaDevice(
      id: frontCamera.id,
      label: 'Kamera przednia',
      kind: CallMediaDeviceKind.camera,
    ),
  ];
  if (backCamera != null && backCamera.id != frontCamera.id) {
    result.add(
      CallMediaDevice(
        id: backCamera.id,
        label: 'Kamera tylna',
        kind: CallMediaDeviceKind.camera,
      ),
    );
  }
  return result;
}
