import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zen/src/core/logging/zen_log.dart';
import 'package:zen/src/domain/calls/call_session.dart';
import 'package:zen/src/features/calls/call_platform_channel.dart';
import 'package:zen/src/features/settings/app_settings_controller.dart';
import 'package:zen/src/features/sound/zen_sound_effects.dart';

// The sounds of a call that only the person holding the phone hears: the
// ringback while the other phone rings, the busy tone when nobody answers
// or the call is declined, a short signal when the call drops and Zen
// tries again, and the chimes when it connects and ends.
//
// Up to 1.17.1 there was no ringback and no busy tone at all, and the two
// chimes went to the media stream through the in-app sound effects, which
// skip every sound while the phone is on silent or vibrate ("Sound
// zen_call_connected skipped: the device keeps quiet"). A caller on a
// silent phone heard nothing of the call until a voice. These are part of
// the call, like the tones of the phone's own dialler: they go to the
// call's audio (Android's voice-call stream, at the call's volume, on the
// call's route: earpiece, loudspeaker or headset) and play whatever the
// ringer says ([callTonePlays]). The ringing of an incoming call and the
// message sounds still follow the phone's silent mode and Zen's
// notification settings (zen_sound_effects.dart).

/// A sound of a call heard by this side only.
enum CallTone {
  /// The other phone rings: the dialler's ringing tone, over and over.
  ringback,

  /// Nobody answered, the call was declined or the other side is busy.
  busy,

  /// The media dropped and Zen tries to bring the call back.
  reconnecting,

  /// The call is on (Zen's own two rising notes).
  connected,

  /// The call is over, ended by either side or dropped (the notes falling).
  ended;

  /// Zen's own sound for it; the others are the phone's call tones.
  ZenSound? get chime => switch (this) {
    CallTone.connected => ZenSound.callConnected,
    CallTone.ended => ZenSound.callEnded,
    _ => null,
  };

  /// Whether "Dźwięki w aplikacji" may switch it off: the two chimes, as
  /// before. The ringback, busy and reconnecting tones say what the call
  /// does and always play.
  bool get followsInAppSounds => chime != null;
}

/// Where the phone's ringer stands.
enum RingerMode { normal, vibrate, silent }

/// Which audio a sound goes to.
enum SoundStream {
  /// The call's audio (Android `STREAM_VOICE_CALL`, usage
  /// `VOICE_COMMUNICATION`): the call's volume and route, never muted by the
  /// ringer.
  voiceCall,

  /// The ringer and notification sounds, which silent mode mutes.
  notification,
}

/// Every call tone goes to the call's audio.
SoundStream callToneStream(CallTone tone) => SoundStream.voiceCall;

/// Whether [tone] plays: in every [ringer] mode; the chimes only while
/// "Dźwięki w aplikacji" ([inAppSoundsOn]) is on.
bool callTonePlays(
  CallTone tone, {
  required RingerMode ringer,
  required bool inAppSoundsOn,
}) => !tone.followsInAppSounds || inAppSoundsOn;

/// What the call tones follow: which call, in which state, which way.
typedef CallToneState = ({
  String? id,
  CallSessionStatus? status,
  bool incoming,
  bool group,
});

/// One thing to do: start [tone], or stop the tone that plays ([tone] null).
typedef CallToneStep = ({CallTone? tone});

/// Which tones a call's changes ask for. Kept apart from the platform so
/// that every change can be checked.
final class CallToneDirector {
  CallToneState? _last;
  bool _ringback = false;

  /// The call that connected and has not ended yet.
  String? _connected;

  /// The call is now [next] (an empty state without a call).
  List<CallToneStep> onCall(CallToneState next) {
    final CallToneState? previous = _last;
    _last = next;
    final List<CallToneStep> steps = <CallToneStep>[];
    final bool wantsRingback =
        next.id != null &&
        !next.incoming &&
        !next.group &&
        next.status == CallSessionStatus.ringing;
    if (wantsRingback && !_ringback) {
      _ringback = true;
      steps.add((tone: CallTone.ringback));
    } else if (!wantsRingback && _ringback) {
      _ringback = false;
      steps.add((tone: null));
    }
    final bool sameCall = previous?.id != null && previous!.id == next.id;
    final bool wasOn = sameCall && previous.status == CallSessionStatus.active;
    if (next.status == CallSessionStatus.active) {
      if (_connected != null && _connected != next.id) {
        steps.add((tone: CallTone.ended));
      }
      if (!wasOn) {
        steps.add((tone: CallTone.connected));
      }
      _connected = next.id;
    } else if (wasOn && next.status == CallSessionStatus.connecting) {
      steps.add((tone: CallTone.reconnecting));
    } else if (_connected != null && next.id != _connected) {
      _connected = null;
      steps.add((tone: CallTone.ended));
    }
    return steps;
  }

  /// The call this side made was declined, found the other side busy or
  /// was not answered.
  List<CallToneStep> busy() {
    final List<CallToneStep> steps = <CallToneStep>[];
    if (_ringback) {
      _ringback = false;
      steps.add((tone: null));
    }
    steps.add((tone: CallTone.busy));
    return steps;
  }
}

/// Plays the call tones on this platform.
abstract interface class CallTonePlayer {
  /// Whether it started.
  Future<bool> start(CallTone tone);

  Future<void> stop();
}

/// Android: the call's audio (ZenCallTones.kt).
final class AndroidCallTonePlayer implements CallTonePlayer {
  const AndroidCallTonePlayer();

  @override
  Future<bool> start(CallTone tone) =>
      playCallTone(tone.name, asset: tone.chime?.asset);

  @override
  Future<void> stop() => stopCallTone();
}

/// Computers: the chimes as before (no ringer to follow there); the
/// dialler tones are not played.
final class DesktopCallTonePlayer implements CallTonePlayer {
  const DesktopCallTonePlayer(this._effects);

  final ZenSoundEffects _effects;

  @override
  Future<bool> start(CallTone tone) async {
    final ZenSound? chime = tone.chime;
    return chime != null && await _effects.play(chime);
  }

  @override
  Future<void> stop() async {}
}

/// Plays nothing (iOS, the web, tests).
final class SilentCallTonePlayer implements CallTonePlayer {
  const SilentCallTonePlayer();

  @override
  Future<bool> start(CallTone tone) async => false;

  @override
  Future<void> stop() async {}
}

/// The call tones of this device: [onCall] with every change of the call,
/// [busy] when a call made here ends unanswered. Each tone played or
/// skipped leaves a line in the technical log.
final class CallTones {
  CallTones({
    required CallTonePlayer player,
    required bool Function() inAppSoundsOn,
  }) : _player = player,
       _inAppSoundsOn = inAppSoundsOn;

  final CallTonePlayer _player;
  final bool Function() _inAppSoundsOn;
  final CallToneDirector _director = CallToneDirector();

  /// Steps run one after another, in the order asked.
  Future<void> _queue = Future<void>.value();

  void onCall(CallToneState next) => _run(_director.onCall(next));

  void busy() => _run(_director.busy());

  void _run(List<CallToneStep> steps) {
    if (steps.isEmpty) {
      return;
    }
    _queue = _queue.then((_) => _apply(steps)).catchError((Object error) {
      logZenWarning('Call tone failed: $error');
    });
  }

  Future<void> _apply(List<CallToneStep> steps) async {
    for (final CallToneStep step in steps) {
      final CallTone? tone = step.tone;
      if (tone == null) {
        await _player.stop();
        continue;
      }
      bool inApp = true;
      try {
        inApp = _inAppSoundsOn();
      } on Object {
        // Settings not readable (yet): the default, on.
      }
      // The ringer is not asked: it never silences a call tone.
      if (!callTonePlays(
        tone,
        ringer: RingerMode.silent,
        inAppSoundsOn: inApp,
      )) {
        logZenMessage(
          'Call tone ${tone.name} skipped: "Dźwięki w aplikacji" off',
        );
        continue;
      }
      final bool started = await _player.start(tone);
      logZenMessage(
        'Call tone ${tone.name}: '
        '${started ? 'on the call audio, whatever the ringer' : 'not played here'}',
      );
    }
  }
}

final Provider<CallTones> callTonesProvider = Provider<CallTones>((Ref ref) {
  final bool underTest = Platform.environment.containsKey('FLUTTER_TEST');
  final CallTonePlayer player = underTest || kIsWeb
      ? const SilentCallTonePlayer()
      : Platform.isAndroid
      ? const AndroidCallTonePlayer()
      : (Platform.isWindows || Platform.isLinux || Platform.isMacOS)
      ? DesktopCallTonePlayer(ref.read(zenSoundEffectsProvider))
      : const SilentCallTonePlayer();
  return CallTones(
    player: player,
    inAppSoundsOn: () => ref.read(appSettingsControllerProvider).inAppSounds,
  );
});
