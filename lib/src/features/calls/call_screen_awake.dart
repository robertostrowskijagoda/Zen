import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:zen/src/core/logging/zen_log.dart';
import 'package:zen/src/domain/calls/call_invite_kind.dart';
import 'package:zen/src/domain/calls/call_session.dart';
import 'package:zen/src/features/calls/call_platform_channel.dart';

// Whether the screen stays on during a call.
//
// Up to 1.17.1 only a ringing incoming call kept it on (the window flag of
// the ringing overlay): an outgoing call, a call once answered and every
// video call went dark after the phone's screen timeout whenever nobody
// touched it. On the owner's phone, plugged in with "stay awake" on, it
// never did. Worse, the end of the ringing cleared the flag on the very
// window the call went on in.
//
// Now the call itself decides ([callScreenAwakeReason]), from the moment
// an outgoing call starts ringing to the end of the call, whatever the
// path into it (dialled, answered in the app, from the lock screen or the
// notification, a group call), and whatever is on the screen (the call
// screen, the rest of the app with the call bar, picture-in-picture): it
// is decided above all of them ([CallScreenAwake.update], from
// CallCompactLayer), and the Android side keeps the flag apart from the
// ringing's and puts it back on every new window of the app
// (CallScreenKeepOn.kt).

/// Why the screen stays on during [session], or null when it may go dark
/// as usual: a video call (the call's kind, or this side's camera on)
/// and a call heard out loud (the loudspeaker, or a headset, which shows
/// as "Głośnik" on), from the first ring of an outgoing call to its end.
/// A voice call at the ear is left to the phone (the screen against a
/// cheek must not take touches); an incoming call that still rings keeps
/// the screen on through its own ringing window.
String? callScreenAwakeReason(CallSession? session) {
  if (session == null) {
    return null;
  }
  final bool running =
      session.status == CallSessionStatus.active ||
      session.status == CallSessionStatus.connecting ||
      (session.status == CallSessionStatus.ringing && !session.isIncoming);
  if (!running) {
    return null;
  }
  if (session.kind == CallInviteKind.video || session.isCameraEnabled) {
    return 'video call';
  }
  if (session.isSpeakerOn) {
    return 'loudspeaker or headset';
  }
  return null;
}

/// Keeps the screen on while the current call wants it
/// ([callScreenAwakeReason]) and lets it go when the call ends, with a line
/// in the technical log each time it is taken or released.
final class CallScreenAwake {
  CallScreenAwake({@visibleForTesting Future<bool?> Function(bool on)? setter})
    : _setter = setter ?? setCallKeepScreenOn;

  static final CallScreenAwake instance = CallScreenAwake();

  final Future<bool?> Function(bool on) _setter;

  /// What was last asked of the platform; null before the first ask, so
  /// the first one always goes (a new engine of the app may find the flag
  /// a call of the previous one left).
  bool? _on;

  /// Whether the screen is kept on now (as last asked).
  bool get keptOn => _on ?? false;

  /// The current call (null without one): asks the platform when what it
  /// wants changed.
  void update(CallSession? session) {
    final String? reason = callScreenAwakeReason(session);
    final bool on = reason != null;
    if (_on == on) {
      return;
    }
    final bool first = _on == null;
    _on = on;
    unawaited(_apply(on, reason, quietly: first && !on));
  }

  Future<void> _apply(bool on, String? reason, {required bool quietly}) async {
    final bool? taken = await _setter(on);
    if (quietly) {
      return;
    }
    final String where = switch (taken) {
      true => 'the app window has the flag',
      false => 'no app window now; set when it shows',
      null => 'not on this platform',
    };
    logZenMessage(
      on
          ? 'Call screen kept on ($reason): $where'
          : 'Call screen keep-on released: $where',
    );
  }
}
