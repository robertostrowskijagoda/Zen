import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/domain/calls/call_session.dart';
import 'package:zen/src/features/calls/call_tones.dart';
import 'package:zen/src/features/sound/zen_sound_effects.dart';

/// The tones of a call heard by this side only play on the call's audio
/// whatever the ringer (call_tones.dart); the ringing of an incoming call
/// and the message sounds still follow silent mode. Up to 1.17.1 there was
/// no ringback or busy tone, and the chimes were skipped on a silent phone.
void main() {
  CallToneState call(
    CallSessionStatus? status, {
    String? id = 'c1',
    bool incoming = false,
    bool group = false,
  }) => (
    id: status == null ? null : id,
    status: status,
    incoming: incoming,
    group: group,
  );
  final CallToneState none = call(null);

  List<CallTone?> tones(List<CallToneStep> steps) =>
      steps.map((CallToneStep s) => s.tone).toList();

  group('which tone a call asks for', () {
    test('a call made here: ringback while it rings, the chime when it '
        'connects, a signal when it drops, the chime when it ends', () {
      final CallToneDirector d = CallToneDirector();
      expect(tones(d.onCall(call(CallSessionStatus.ringing))), <CallTone?>[
        CallTone.ringback,
      ]);
      // A repeat of the same state starts nothing again.
      expect(d.onCall(call(CallSessionStatus.ringing)), isEmpty);
      expect(tones(d.onCall(call(CallSessionStatus.connecting))), <CallTone?>[
        null,
      ]);
      expect(tones(d.onCall(call(CallSessionStatus.active))), <CallTone?>[
        CallTone.connected,
      ]);
      expect(tones(d.onCall(call(CallSessionStatus.connecting))), <CallTone?>[
        CallTone.reconnecting,
      ]);
      expect(tones(d.onCall(call(CallSessionStatus.active))), <CallTone?>[
        CallTone.connected,
      ]);
      expect(tones(d.onCall(none)), <CallTone?>[CallTone.ended]);
      expect(d.onCall(none), isEmpty);
    });

    test('a call that drops while it reconnects still ends with its chime', () {
      final CallToneDirector d = CallToneDirector();
      d.onCall(call(CallSessionStatus.active));
      d.onCall(call(CallSessionStatus.connecting));
      expect(tones(d.onCall(none)), <CallTone?>[CallTone.ended]);
    });

    test('declined, busy or unanswered: the ringback stops, the busy tone '
        'plays; cancelled here: only silence', () {
      final CallToneDirector d = CallToneDirector();
      d.onCall(call(CallSessionStatus.ringing));
      // The other side's answer clears the call, then says why.
      expect(tones(d.onCall(none)), <CallTone?>[null]);
      expect(tones(d.busy()), <CallTone?>[CallTone.busy]);

      final CallToneDirector mine = CallToneDirector();
      mine.onCall(call(CallSessionStatus.ringing));
      expect(tones(mine.onCall(none)), <CallTone?>[null]);
    });

    test('an incoming call and a group call have no ringback; an incoming '
        'call has its chimes once answered', () {
      final CallToneDirector d = CallToneDirector();
      expect(
        d.onCall(call(CallSessionStatus.ringing, incoming: true)),
        isEmpty,
      );
      expect(
        tones(d.onCall(call(CallSessionStatus.active, incoming: true))),
        <CallTone?>[CallTone.connected],
      );
      expect(tones(d.onCall(none)), <CallTone?>[CallTone.ended]);
      expect(d.onCall(call(CallSessionStatus.ringing, group: true)), isEmpty);
    });

    test('a new call right after another ends the first with its chime', () {
      final CallToneDirector d = CallToneDirector();
      d.onCall(call(CallSessionStatus.active));
      expect(
        tones(d.onCall(call(CallSessionStatus.active, id: 'c2'))),
        <CallTone?>[CallTone.ended, CallTone.connected],
      );
    });
  });

  group('which stream and which ringer', () {
    test('every call tone goes to the call audio and plays in every ringer '
        'mode', () {
      for (final CallTone tone in CallTone.values) {
        expect(callToneStream(tone), SoundStream.voiceCall);
        for (final RingerMode ringer in RingerMode.values) {
          expect(
            callTonePlays(tone, ringer: ringer, inAppSoundsOn: true),
            isTrue,
            reason: '$tone $ringer',
          );
        }
      }
    });

    test('"Dźwięki w aplikacji" off silences only the chimes', () {
      expect(
        <CallTone>[
          for (final CallTone tone in CallTone.values)
            if (callTonePlays(
              tone,
              ringer: RingerMode.normal,
              inAppSoundsOn: false,
            ))
              tone,
        ],
        <CallTone>[CallTone.ringback, CallTone.busy, CallTone.reconnecting],
      );
    });

    test('on a silent phone the call chimes play, a message and the '
        'ringtone of the notification do not', () async {
      final List<String> played = <String>[];
      final ZenSoundEffects sounds = ZenSoundEffects(
        output: _Recorder(played),
        inAppSoundsOn: () => true,
        deviceKeepsQuiet: () async => true,
        platform: TargetPlatform.android,
      );
      expect(await sounds.play(ZenSound.callConnected), isTrue);
      expect(await sounds.play(ZenSound.callEnded), isTrue);
      expect(await sounds.play(ZenSound.messageReceived), isFalse);
      expect(ZenSound.ringtone.isCallSound, isFalse);
      expect(ZenSound.message.isCallSound, isFalse);
    });
  });

  test('the service plays in order, skips chimes with the setting off and '
      'stops the ringback', () async {
    final List<String> asked = <String>[];
    bool inApp = false;
    final CallTones calls = CallTones(
      player: _Player(asked),
      inAppSoundsOn: () => inApp,
    );
    calls.onCall(call(CallSessionStatus.ringing));
    calls.onCall(call(CallSessionStatus.active));
    calls.onCall(none);
    await Future<void>.delayed(Duration.zero);
    inApp = true;
    calls.onCall(call(CallSessionStatus.ringing, id: 'c2'));
    calls.onCall(call(null));
    calls.busy();
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    expect(asked, <String>['ringback', 'stop', 'ringback', 'stop', 'busy']);
  });
}

final class _Player implements CallTonePlayer {
  _Player(this.asked);

  final List<String> asked;

  @override
  Future<bool> start(CallTone tone) async {
    asked.add(tone.name);
    return true;
  }

  @override
  Future<void> stop() async => asked.add('stop');
}

final class _Recorder implements ZenSoundOutput {
  _Recorder(this.played);

  final List<String> played;

  @override
  Future<ZenSoundHandle?> play(String asset, {required bool loop}) async {
    played.add(asset);
    return _Handle();
  }
}

final class _Handle implements ZenSoundHandle {
  @override
  Future<void> stop() async {}
}
