import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:zen/src/features/calls/call_audio_route.dart';

/// The phone's sound as the tests see it: what was asked, in order.
final class _Device implements CallAudioDevice {
  _Device(this.listed, {this.android = true, this.ios = false});

  final List<String> listed;
  @override
  final bool android;
  @override
  final bool ios;
  bool fail = false;
  final List<String> calls = <String>[];

  /// Where the sound is now, as the phone would put it.
  String? now;

  @override
  Future<List<String>> outputs() async {
    if (fail) {
      throw StateError('no audio');
    }
    return List<String>.of(listed);
  }

  @override
  Future<void> setSpeakerphoneOn(bool on) async {
    calls.add('speaker:$on');
    if (on) {
      now = 'speaker';
    } else if (now == 'speaker') {
      now = null;
    }
  }

  @override
  Future<void> selectAudioOutput(String id) async {
    calls.add('select:$id');
    now = id;
  }
}

final CallAudioDevice _defaultDevice = callAudioDevice;

void main() {
  group('routing on the phone, step by step', () {
    late _Device phone;

    tearDown(() => callAudioDevice = _defaultDevice);

    void use(_Device d) {
      phone = d;
      callAudioDevice = d;
    }

    test('in a car: the call starts there, off puts it at the ear, on '
        'brings it back to the car, again and again', () async {
      use(_Device(<String>['earpiece', 'speaker', 'bluetooth']));
      expect(
        await routeCallAudio(speaker: false, preferHeadset: true),
        CallAudioOutput.headset,
      );
      expect(phone.now, 'bluetooth');
      for (int i = 0; i < 3; i++) {
        expect(await routeCallAudio(speaker: false), CallAudioOutput.earpiece);
        expect(phone.now, 'earpiece', reason: 'at the ear');
        expect(await routeCallAudio(speaker: true), CallAudioOutput.headset);
        expect(
          phone.now,
          'bluetooth',
          reason: "the car's speakers, not the phone's loudspeaker",
        );
      }
      expect(phone.calls.where((String c) => c == 'speaker:true'), isEmpty);
    });

    test(
      'a video call starts in the car too, not on the loudspeaker',
      () async {
        use(_Device(<String>['speaker', 'earpiece', 'bluetooth']));
        expect(
          await routeCallAudio(speaker: true, preferHeadset: true),
          CallAudioOutput.headset,
        );
        expect(phone.now, 'bluetooth');
      },
    );

    test('no headset: a video call starts on the loudspeaker, an audio call '
        'at the ear, and the switch moves between the two', () async {
      use(_Device(<String>['earpiece', 'speaker']));
      expect(
        await routeCallAudio(speaker: true, preferHeadset: true),
        CallAudioOutput.loudspeaker,
      );
      expect(phone.now, 'speaker');
      expect(
        await routeCallAudio(speaker: false, preferHeadset: true),
        CallAudioOutput.earpiece,
      );
      expect(phone.now, 'earpiece');
      expect(await routeCallAudio(speaker: true), CallAudioOutput.loudspeaker);
      expect(phone.calls.last, 'speaker:true');
    });

    test('wired earphones without an earpiece listed: off keeps them, and no '
        'earpiece is asked for that is not there', () async {
      use(_Device(<String>['wired-headset', 'speaker']));
      expect(await routeCallAudio(speaker: false), CallAudioOutput.headset);
      expect(phone.calls, <String>['speaker:false', 'select:wired-headset']);
      use(_Device(<String>['speaker']));
      expect(await routeCallAudio(speaker: false), CallAudioOutput.earpiece);
      expect(phone.calls, <String>['speaker:false']);
    });

    test('an iPhone: the system routes a headset itself, Zen only says '
        'loudspeaker or not', () async {
      use(_Device(<String>['bluetooth'], android: false, ios: true));
      expect(await routeCallAudio(speaker: true), CallAudioOutput.loudspeaker);
      expect(await routeCallAudio(speaker: false), CallAudioOutput.earpiece);
      expect(phone.calls, <String>['speaker:true', 'speaker:false']);
    });

    test('a computer: nothing is touched', () async {
      use(_Device(<String>['speaker'], android: false));
      expect(await routeCallAudio(speaker: true), isNull);
      expect(phone.calls, isEmpty);
    });

    test('the system failing: nothing claimed, nothing thrown', () async {
      use(_Device(<String>['earpiece'])..fail = true);
      expect(await routeCallAudio(speaker: true), isNull);
      expect(phone.calls, isEmpty);
    });
  });

  test('a connected headset is chosen over the earpiece, whatever the order '
      'Android lists the outputs in', () {
    expect(
      callHeadsetOutput(<String>['earpiece', 'speaker', 'bluetooth']),
      'bluetooth',
    );
    expect(
      callHeadsetOutput(<String>['earpiece', 'wired-headset', 'bluetooth']),
      'bluetooth',
    );
    expect(
      callHeadsetOutput(<String>['wired-headset', 'earpiece']),
      'wired-headset',
    );
    expect(callHeadsetOutput(<String>['earpiece', 'speaker']), isNull);
  });

  test('every set of outputs a phone can list, both ways: on is never the '
      'phone at the ear, never the loudspeaker past a headset; off is the '
      'earpiece whenever there is one; a headset named is always one listed; '
      'and flipping back and forth always lands on the same two', () {
    const List<String> all = <String>[
      'earpiece',
      'speaker',
      'bluetooth',
      'wired-headset',
      'usb-headset',
    ];
    for (int mask = 0; mask < 1 << all.length; mask++) {
      final List<String> outputs = <String>[
        for (int i = 0; i < all.length; i++)
          if (mask & (1 << i) != 0) all[i],
      ];
      final String? headset = callHeadsetOutput(outputs);
      final CallAudioChoice on = callAudioChoice(
        speaker: true,
        outputs: outputs,
      );
      final CallAudioChoice off = callAudioChoice(
        speaker: false,
        outputs: outputs,
      );
      final String why = 'outputs $outputs';
      expect(on.output, isNot(CallAudioOutput.earpiece), reason: why);
      if (headset != null) {
        expect(on, (output: CallAudioOutput.headset, id: headset), reason: why);
      } else {
        expect(on.output, CallAudioOutput.loudspeaker, reason: why);
      }
      if (outputs.contains('earpiece')) {
        expect(off.output, CallAudioOutput.earpiece, reason: why);
      }
      expect(off.output, isNot(CallAudioOutput.loudspeaker), reason: why);
      for (final CallAudioChoice c in <CallAudioChoice>[on, off]) {
        if (c.output == CallAudioOutput.headset) {
          expect(outputs, contains(c.id), reason: why);
        } else {
          expect(c.id, isNull, reason: why);
        }
      }
      // The order Android lists them in changes nothing.
      final List<String> reversed = outputs.reversed.toList();
      expect(callAudioChoice(speaker: true, outputs: reversed), on);
      expect(callAudioChoice(speaker: false, outputs: reversed), off);
      // Ten flips: the same two places, alternating.
      for (int flip = 0; flip < 10; flip++) {
        expect(
          callAudioChoice(speaker: flip.isEven, outputs: outputs),
          flip.isEven ? on : off,
          reason: why,
        );
      }
    }
  });

  group('"Głośnik" and the outputs there are: every case', () {
    const List<String> car = <String>['earpiece', 'speaker', 'bluetooth'];
    const List<String> wired = <String>['wired-headset', 'speaker'];
    const List<String> phone = <String>['earpiece', 'speaker'];
    const List<String> tabletWithCar = <String>['speaker', 'bluetooth'];
    const List<String> tablet = <String>['speaker'];

    CallAudioChoice choice(bool speaker, List<String> outputs) =>
        callAudioChoice(speaker: speaker, outputs: outputs);

    test('in a car: on is the car, off is the phone at the ear, on again '
        'is the car again, never the phone\'s loudspeaker', () {
      expect(choice(true, car), (
        output: CallAudioOutput.headset,
        id: 'bluetooth',
      ));
      expect(choice(false, car), (output: CallAudioOutput.earpiece, id: null));
      // Back and forth any number of times: always the same two.
      for (int i = 0; i < 4; i++) {
        expect(choice(true, car).output, CallAudioOutput.headset);
        expect(choice(false, car).output, CallAudioOutput.earpiece);
      }
    });

    test('Bluetooth wins over wired earphones when both are there', () {
      expect(
        choice(true, <String>['wired-headset', 'earpiece', 'bluetooth']).id,
        'bluetooth',
      );
    });

    test('wired earphones (the phone gives no earpiece with them): on and '
        'off both keep the earphones', () {
      expect(choice(true, wired), (
        output: CallAudioOutput.headset,
        id: 'wired-headset',
      ));
      expect(choice(false, wired), (
        output: CallAudioOutput.headset,
        id: 'wired-headset',
      ));
    });

    test('no headset: on is the loudspeaker, off the earpiece', () {
      expect(choice(true, phone), (
        output: CallAudioOutput.loudspeaker,
        id: null,
      ));
      expect(choice(false, phone), (
        output: CallAudioOutput.earpiece,
        id: null,
      ));
    });

    test('a tablet (no earpiece) in a car keeps the car either way', () {
      expect(choice(true, tabletWithCar).output, CallAudioOutput.headset);
      expect(choice(false, tabletWithCar).output, CallAudioOutput.headset);
    });

    test('a tablet alone: the loudspeaker on, the system\'s choice off', () {
      expect(choice(true, tablet).output, CallAudioOutput.loudspeaker);
      expect(choice(false, tablet).output, CallAudioOutput.earpiece);
    });

    test('nothing listed (the list failed): the loudspeaker or the system\'s '
        'own off', () {
      expect(
        choice(true, const <String>[]).output,
        CallAudioOutput.loudspeaker,
      );
      expect(choice(false, const <String>[]).output, CallAudioOutput.earpiece);
    });

    test('an output listed twice or unknown ones change nothing', () {
      expect(
        choice(true, <String>['bluetooth', 'bluetooth', 'usb-x', 'earpiece']),
        (output: CallAudioOutput.headset, id: 'bluetooth'),
      );
      expect(
        choice(false, <String>['usb-x', 'earpiece', 'earpiece']).output,
        CallAudioOutput.earpiece,
      );
    });
  });

  test('only outputs are taken for outputs: a Bluetooth microphone alone '
      'is no headset', () {
    final List<MediaDeviceInfo> devices = <MediaDeviceInfo>[
      MediaDeviceInfo(kind: 'audioinput', label: 'BT', deviceId: 'bluetooth'),
      MediaDeviceInfo(kind: 'audiooutput', label: 'Ear', deviceId: 'earpiece'),
      MediaDeviceInfo(kind: 'videoinput', label: 'Cam', deviceId: '1'),
      MediaDeviceInfo(label: 'Unknown', deviceId: 'wired-headset'),
      MediaDeviceInfo(kind: 'audiooutput', label: 'Spk', deviceId: 'speaker'),
    ];
    expect(callAudioOutputIds(devices), <String>['earpiece', 'speaker']);
    expect(callHeadsetOutput(callAudioOutputIds(devices)), isNull);
  });
}
