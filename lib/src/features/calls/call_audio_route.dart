import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:zen/src/core/logging/zen_log.dart';

/// The ids flutter_webrtc gives a phone's audio outputs that sit on the
/// person (AudioDeviceKind on Android), best first.
const List<String> kCallHeadsetOutputs = <String>['bluetooth', 'wired-headset'];

/// The phone's own earpiece, as flutter_webrtc names it on Android.
const String kCallEarpieceOutput = 'earpiece';

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

/// Where a call's sound goes.
enum CallAudioOutput {
  /// A headset: a car's Bluetooth, earphones ([CallAudioChoice.id]).
  headset,

  /// The phone's loudspeaker.
  loudspeaker,

  /// The phone's earpiece: the phone at the ear.
  earpiece,
}

/// Where the sound goes and, for a headset, which one.
typedef CallAudioChoice = ({CallAudioOutput output, String? id});

/// Where a call's sound goes on Android, from the "Głośnik" switch
/// ([speaker]) and the outputs there are ([outputs], flutter_webrtc's ids).
///
/// "Głośnik" on is the sound out loud, hands free: a connected headset
/// (a car's Bluetooth, earphones) when there is one, the loudspeaker
/// otherwise. Off is the phone at the ear: the earpiece. So in a car the
/// call starts in the car, "Głośnik" off moves it to the phone and on
/// brings it back to the car; it went to the phone's loudspeaker, with
/// the car's speakers right there. A phone without an earpiece (a tablet)
/// keeps a headset when "Głośnik" is off. The loudspeaker with a headset
/// connected is still there in the list of outputs (selectMediaDevice).
CallAudioChoice callAudioChoice({
  required bool speaker,
  required Iterable<String> outputs,
}) {
  final Set<String> ids = outputs.toSet();
  final String? headset = callHeadsetOutput(ids);
  if (speaker) {
    return headset != null
        ? (output: CallAudioOutput.headset, id: headset)
        : (output: CallAudioOutput.loudspeaker, id: null);
  }
  if (ids.contains(kCallEarpieceOutput) || headset == null) {
    return (output: CallAudioOutput.earpiece, id: null);
  }
  return (output: CallAudioOutput.headset, id: headset);
}

/// What [routeCallAudio] does with the phone's sound: flutter_webrtc on a
/// phone, a recorder in tests.
abstract interface class CallAudioDevice {
  bool get android;
  bool get ios;

  /// The audio outputs' ids (Android).
  Future<List<String>> outputs();
  Future<void> setSpeakerphoneOn(bool on);
  Future<void> selectAudioOutput(String id);
}

final class _WebRtcAudioDevice implements CallAudioDevice {
  const _WebRtcAudioDevice();

  @override
  bool get android => Platform.isAndroid;

  @override
  bool get ios => Platform.isIOS;

  @override
  Future<List<String>> outputs() async => <String>[
    for (final MediaDeviceInfo d
        in await navigator.mediaDevices.enumerateDevices())
      if (d.kind == 'audiooutput') d.deviceId,
  ];

  @override
  Future<void> setSpeakerphoneOn(bool on) => Helper.setSpeakerphoneOn(on);

  @override
  Future<void> selectAudioOutput(String id) => Helper.selectAudioOutput(id);
}

/// The device [routeCallAudio] routes on.
@visibleForTesting
CallAudioDevice callAudioDevice = const _WebRtcAudioDevice();

/// Routes a call's sound by [callAudioChoice] and says where it went
/// (`null`: not on a phone, or the routing failed). At the start of a call
/// ([preferHeadset]) a connected headset takes it whatever [speaker] says.
///
/// flutter_webrtc's own "speaker off" takes the first of Bluetooth, wired
/// headset and earpiece in the order Android lists them, so the outputs
/// are chosen here by name.
Future<CallAudioOutput?> routeCallAudio({
  required bool speaker,
  bool preferHeadset = false,
}) async {
  final CallAudioDevice device = callAudioDevice;
  if (!device.android && !device.ios) {
    return null;
  }
  try {
    if (!device.android) {
      // iOS sends the sound to a connected headset by itself unless the
      // loudspeaker is asked for.
      await device.setSpeakerphoneOn(speaker);
      return speaker ? CallAudioOutput.loudspeaker : CallAudioOutput.earpiece;
    }
    final List<String> outputs = await device.outputs();
    final CallAudioChoice choice = callAudioChoice(
      speaker: speaker || (preferHeadset && callHeadsetOutput(outputs) != null),
      outputs: outputs,
    );
    switch (choice.output) {
      case CallAudioOutput.headset:
        await device.setSpeakerphoneOn(false);
        await device.selectAudioOutput(choice.id!);
      case CallAudioOutput.loudspeaker:
        await device.setSpeakerphoneOn(true);
      case CallAudioOutput.earpiece:
        await device.setSpeakerphoneOn(false);
        if (outputs.contains(kCallEarpieceOutput)) {
          await device.selectAudioOutput(kCallEarpieceOutput);
        }
    }
    return choice.output;
  } catch (error, stackTrace) {
    logZenError('Routing the call audio failed', error, stackTrace);
    return null;
  }
}
