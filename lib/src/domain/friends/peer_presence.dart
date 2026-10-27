import 'package:flutter/foundation.dart';

/// What a friend's Zen is doing, as far as they let this person see it.
///
/// [online]: Zen is open on their screen. [background]: Zen is off the
/// screen (the app hidden, the phone locked) but still receives — Android's
/// background service, a computer's tray, an iPhone with the keep-alive.
/// [offline]: no sign of life lately, or a device that stops receiving off
/// the screen (an iPhone iOS suspends). [hidden]: the friend does not show
/// it to this person (a weak acquaintance there sees no statuses).
enum PeerPresence { hidden, offline, background, online }

/// The key of the presence state in `ping`, `pong` and `away`.
const String kPresenceStateKey = 'state';

/// The key of "Zen was last open this many seconds ago" (0: open now).
const String kPresenceOpenedKey = 'lo';

/// The values of [kPresenceStateKey]: open on the screen, off the screen
/// but receiving, off the screen and about to stop receiving.
const String kPresenceForeground = 'foreground';
const String kPresenceBackground = 'background';
const String kPresenceAsleep = 'asleep';

/// The longest "last open" a frame may name (anything longer is a year).
const Duration kPresenceOpenedMax = Duration(days: 365);

/// What one `ping`, `pong` or `away` says about its sender: the state, and
/// how long ago Zen was last open there ([openedAgo], `null` when not told:
/// the friend hides it, or the device does not know).
@immutable
final class PresenceReport {
  const PresenceReport({required this.presence, this.openedAgo});

  /// A frame that says nothing about presence: [PeerPresence.hidden].
  factory PresenceReport.fromPayload(Map<String, dynamic> payload) {
    final PeerPresence presence = switch (payload[kPresenceStateKey]) {
      kPresenceForeground => PeerPresence.online,
      kPresenceBackground => PeerPresence.background,
      kPresenceAsleep => PeerPresence.offline,
      _ => PeerPresence.hidden,
    };
    if (presence == PeerPresence.hidden) {
      return const PresenceReport(presence: PeerPresence.hidden);
    }
    final Object? lo = payload[kPresenceOpenedKey];
    final Duration? openedAgo = lo is int && lo >= 0
        ? Duration(seconds: lo) > kPresenceOpenedMax
              ? kPresenceOpenedMax
              : Duration(seconds: lo)
        : null;
    return PresenceReport(presence: presence, openedAgo: openedAgo);
  }

  final PeerPresence presence;
  final Duration? openedAgo;

  /// Whether the sender can be reached directly now and for a while: not
  /// a device that is about to stop receiving.
  bool get reachable => presence != PeerPresence.offline;

  /// When Zen was last open, given the frame came at [receivedAtMillis];
  /// 0 when not told.
  int lastOpenedAt(int receivedAtMillis) {
    final Duration? ago = openedAgo;
    if (ago == null) {
      return 0;
    }
    final int at = receivedAtMillis - ago.inMilliseconds;
    return at > 0 ? at : 0;
  }
}

/// The presence fields of a frame about this device: [own] is
/// [PeerPresence.online] (on the screen), [PeerPresence.background] (off
/// it, still receiving) or [PeerPresence.offline] (off it and about to stop
/// receiving); [openedAgo] how long ago Zen was last open, `null` to keep
/// it to itself. [PeerPresence.hidden] says nothing at all.
Map<String, dynamic> presenceFields({
  required PeerPresence own,
  Duration? openedAgo,
}) {
  final String? state = switch (own) {
    PeerPresence.online => kPresenceForeground,
    PeerPresence.background => kPresenceBackground,
    PeerPresence.offline => kPresenceAsleep,
    PeerPresence.hidden => null,
  };
  if (state == null) {
    return const <String, dynamic>{};
  }
  return <String, dynamic>{
    kPresenceStateKey: state,
    if (openedAgo != null)
      kPresenceOpenedKey: openedAgo.isNegative ? 0 : openedAgo.inSeconds,
  };
}

/// [presence] as it stands at [nowMillis], [presenceAtMillis] being its last
/// confirmation: "online" lasts [foregroundFor] without a new sign, "w tle"
/// [backgroundFor]; after that the friend is offline.
PeerPresence presenceAt({
  required PeerPresence presence,
  required int presenceAtMillis,
  required int nowMillis,
  required Duration foregroundFor,
  required Duration backgroundFor,
}) {
  final int age = nowMillis - presenceAtMillis;
  return switch (presence) {
    PeerPresence.online when age >= foregroundFor.inMilliseconds =>
      PeerPresence.offline,
    PeerPresence.background when age >= backgroundFor.inMilliseconds =>
      PeerPresence.offline,
    _ => presence,
  };
}
