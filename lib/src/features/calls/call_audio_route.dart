import 'dart:io';

import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:zen/src/core/logging/zen_log.dart';

/// The ids flutter_webrtc gives a phone's audio outputs that sit on the
/// person (AudioDeviceKind on Android), best first.
const List<String> kCallHeadsetOutputs = <String>['bluetooth', 'wired-headset'];

/// The headset [outputs] (audio output ids) offer, best first, or `null`.
String? callHeadsetOutput(Iterable<String> outputs) {
  final Set<String> ids = outputs.toSet();
  for (final String id in kCallHeadsetOutputs) {
    if (ids.contains(id)) {
      return id;
    }
  }
  return null;
}

/// Routes a call's sound: to the loudspeaker ([speaker]) or, without it,
/// to a headset when one is connected (a car's Bluetooth, earphones), else
/// the earpiece. With [preferHeadset] (the start of a call) a connected
/// headset wins over the loudspeaker too.
///
/// flutter_webrtc's own "speaker off" takes the first of Bluetooth, wired
/// headset and earpiece in the order Android lists them, often the
/// earpiece while a car's Bluetooth is connected: the call stayed in the
/// phone. The headset is chosen here by name.
Future<void> routeCallAudio({
  required bool speaker,
  bool preferHeadset = false,
}) async {
  if (!Platform.isAndroid && !Platform.isIOS) {
    return;
  }
  try {
    final String? headset = Platform.isAndroid && (!speaker || preferHeadset)
        ? callHeadsetOutput(<String>[
            for (final MediaDeviceInfo d
                in await navigator.mediaDevices.enumerateDevices())
              if (d.kind == 'audiooutput') d.deviceId,
          ])
        : null;
    if (headset != null) {
      await Helper.setSpeakerphoneOn(false);
      await Helper.selectAudioOutput(headset);
      return;
    }
    await Helper.setSpeakerphoneOn(speaker);
  } catch (error, stackTrace) {
    logZenError('Routing the call audio failed', error, stackTrace);
  }
}
