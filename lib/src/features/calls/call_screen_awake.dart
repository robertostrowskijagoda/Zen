import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:zen/src/core/logging/zen_log.dart';
import 'package:zen/src/domain/calls/call_invite_kind.dart';
import 'package:zen/src/domain/calls/call_session.dart';
import 'package:zen/src/features/calls/call_platform_channel.dart';

// What the screen does during a call: stays on, or goes dark at the ear.
//
// Up to 1.17.1 only a ringing incoming call kept it on (the window flag of
// the ringing overlay): an outgoing call, a call once answered and every
// video call went dark after the phone's screen timeout whenever nobody
// touched it. On the owner's phone, plugged in with "stay awake" on, it
// never did. Worse, the end of the ringing cleared the flag on the very
// window the call went on in. And a voice call held to the ear had no
// proximity sensor: the screen stayed lit against the cheek and took its
// touches until the timeout.
//
// Now the call itself decides ([callScreenModeFor]), from the moment an
// outgoing call starts ringing to the end of the call, whatever the path
// into it (dialled, answered in the app, from the lock screen or the
// notification, a group call), and whatever is on the screen (the call
// screen, the rest of the app with the call bar, picture-in-picture): it
// is decided above all of them ([CallScreenAwake.update], from
// CallCompactLayer). The Android side keeps the window flag apart from
// the ringing's and puts it back on every new window of the app
// (CallScreenKeepOn.kt), and holds the proximity wake lock
// (ZenCallProximity.kt).

/// What the screen does during a call.
enum CallScreenMode {
  /// As the phone does without a call.
  normal,

  /// Stays on: a video call, or a call heard out loud.
  keepOn,

  /// Goes dark and ignores touches while something is close to the
  /// proximity sensor (the phone at the ear), lights up when it moves away.
  proximity,
}

/// What the screen does during [session], and why: a video call (the
/// call's kind, or this side's camera on) and a call heard out loud (the
/// loudspeaker, or a headset, which shows as "Głośnik" on) keep it on; a
/// voice call on the earpiece goes dark at the ear; both from the first
/// ring of an outgoing call (and from the answer of an incoming one) to
/// the end. An incoming call that still rings keeps the screen on through
/// its own ringing window, and no call leaves the screen to the phone.
({CallScreenMode mode, String reason}) callScreenModeFor(CallSession? session) {
  if (session == null) {
    return (mode: CallScreenMode.normal, reason: 'no call');
  }
  final bool running =
      session.status == CallSessionStatus.active ||
      session.status == CallSessionStatus.connecting ||
      (session.status == CallSessionStatus.ringing && !session.isIncoming);
  if (!running) {
    return (mode: CallScreenMode.normal, reason: 'ringing in');
  }
  if (session.kind == CallInviteKind.video || session.isCameraEnabled) {
    return (mode: CallScreenMode.keepOn, reason: 'video call');
  }
  if (session.isSpeakerOn) {
    return (mode: CallScreenMode.keepOn, reason: 'loudspeaker or headset');
  }
  return (mode: CallScreenMode.proximity, reason: 'voice call at the ear');
}

/// Why the screen stays on during [session], or null when it does not
/// ([callScreenModeFor]).
String? callScreenAwakeReason(CallSession? session) {
  final ({CallScreenMode mode, String reason}) decided = callScreenModeFor(
    session,
  );
  return decided.mode == CallScreenMode.keepOn ? decided.reason : null;
}

/// Puts the screen in the mode the current call wants
/// ([callScreenModeFor]) and back when the call ends, with a line in the
/// technical log each time the keep-on or the proximity sensor is taken or
/// released.
final class CallScreenAwake {
  CallScreenAwake({
    @visibleForTesting Future<bool?> Function(CallScreenMode mode)? setter,
  }) : _setter =
           setter ?? ((CallScreenMode mode) => setCallScreenMode(mode.name));

  static final CallScreenAwake instance = CallScreenAwake();

  final Future<bool?> Function(CallScreenMode mode) _setter;

  /// What was last asked of the platform; null before the first ask, so
  /// the first one always goes (a new engine of the app may find what a
  /// call of the previous one left).
  CallScreenMode? _mode;

  /// The mode asked last.
  CallScreenMode get mode => _mode ?? CallScreenMode.normal;

  /// Whether the screen is kept on now (as last asked).
  bool get keptOn => mode == CallScreenMode.keepOn;

  /// The current call (null without one): asks the platform when what it
  /// wants changed.
  void update(CallSession? session) {
    final ({CallScreenMode mode, String reason}) decided = callScreenModeFor(
      session,
    );
    final CallScreenMode? before = _mode;
    if (before == decided.mode) {
      return;
    }
    _mode = decided.mode;
    unawaited(_apply(before, decided.mode, decided.reason));
  }

  Future<void> _apply(
    CallScreenMode? before,
    CallScreenMode mode,
    String reason,
  ) async {
    final bool? taken = await _setter(mode);
    if (before == null && mode == CallScreenMode.normal) {
      return;
    }
    final String where = switch (taken) {
      null => 'not on this platform',
      false when mode == CallScreenMode.proximity =>
        'this phone has no proximity sensor for it',
      false => 'no app window now; set when it shows',
      true =>
        mode == CallScreenMode.proximity
            ? 'the proximity sensor is held'
            : 'the app window has the flag',
    };
    final List<String> lines = <String>[
      if (before == CallScreenMode.keepOn) 'Call screen keep-on released',
      if (before == CallScreenMode.proximity) 'Call screen proximity released',
      if (mode == CallScreenMode.keepOn) 'Call screen kept on ($reason)',
      if (mode == CallScreenMode.proximity)
        'Call screen dark at the ear ($reason)',
    ];
    logZenMessage('${lines.join('; ')}: $where');
  }
}
