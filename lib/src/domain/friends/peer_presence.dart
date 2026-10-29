import 'package:flutter/foundation.dart';

/// What a friend's Zen is doing, as far as they let this person see it.
///
/// [online]: Zen is open on their screen. [background]: Zen is off the
/// screen (the app hidden, the phone locked) but still receives — Android's
/// background service, a computer's tray, an iPhone with the keep-alive.
/// [offline]: no sign of life lately, or a device that stops receiving off
/// the screen (an iPhone iOS suspends). [hidden]: the friend does not show
/// it to this person (a weak acquaintance there sees no statuses).
/// [unknown]: not checked lately ("status nieznany": the last state known
/// was confirmed longer than [kPresenceRememberedFor] ago and nothing new
/// came yet, see [PresenceDoubt.unchecked]); kept for a friend only when
/// their Zen is too old to tell it ([kPresenceSinceVersion]).
/// [noConnection]: this device has no connection to the network, so
/// nothing can be known of anyone ("brak połączenia", see
/// [PresenceDoubt.noNetwork]); only shown, never kept.
/// Neither of the last two is ever sent. New values go last, so the stored
/// indexes of the others stay.
enum PeerPresence { hidden, offline, background, online, unknown, noConnection }

/// Why a friend's presence is not shown as it was last known, which is
/// kept underneath: [unchecked], confirmed longer than
/// [kPresenceRememberedFor] ago and not since (after a start, or coming
/// back to the screen or to the network after a while), shown as
/// [PeerPresence.unknown]; [noNetwork], this device has had no connection
/// to the network for a while, so nothing from friends can come, shown as
/// [PeerPresence.noConnection].
enum PresenceDoubt { unchecked, noNetwork }

/// A friend's last presence confirmed at most this long ago is shown as it
/// stands now ([presenceAt]: "online" from 3 min ago is still online, from
/// 8 min ago offline) until they say more; confirmed longer ago, it is
/// [PeerPresence.unknown] until they answer or the answers had time to
/// come.
const Duration kPresenceRememberedFor = Duration(minutes: 30);

/// A friend "w tle" with no sign of life for this long counts as offline
/// (and no longer reachable directly). A phone in the background never
/// pings; it only answers this phone's pings, which go out only while Zen
/// is on this screen, every kPresencePingInterval (2 min), and a locked
/// phone answers one contact at most every kLockedPongEvery (3.5 min): the
/// first ping after a quiet while at once, then every other one, so an
/// answer comes every 4 min. Twice that and a bit, so one lost answer is
/// not "offline".
const Duration kPresenceOfflineAfter = Duration(minutes: 10);

/// A friend "online" with no new sign for this long counts as offline. A
/// friend on the screen pings every kPresencePingInterval and answers this
/// phone's pings at once, and tells "away" when Zen leaves their screen (an
/// "away" lost: the next answer says "w tle"). Silence for two rounds and a
/// bit means Zen was closed or the phone lost the network.
const Duration kPresenceForegroundFor = Duration(minutes: 5);

const String kPresenceSinceVersion = '1.13.0';

/// The key of the presence state in `ping`, `pong` and `away`.
const String kPresenceStateKey = 'state';

/// The key of "Zen was last open this many seconds ago" (0: open now).
const String kPresenceOpenedKey = 'lo';

/// The values of [kPresenceStateKey]: open on the screen, off the screen
/// but receiving, off the screen and about to stop receiving. Any of them
/// may come in a `ping`, a `pong` or an `away` (despite its name, also
/// "back on the screen" and "closing").
const String kPresenceForeground = 'foreground';
const String kPresenceBackground = 'background';
const String kPresenceAsleep = 'asleep';

/// The longest "last open" a frame may name (anything longer is a year).
const Duration kPresenceOpenedMax = Duration(days: 365);

/// The key of "the state as of" in `ping`, `pong` and `away`: the sender's
/// clock (ms) when it told it. Frames can come late (held while a session
/// with the friend is made, sent again after the friend's app started
/// again), and the app and the locked service of one device answer in
/// turn: a state older than one already heard from that device is not
/// taken ([PresenceDevices]). A Zen before 1.14.1 sends none.
const String kPresenceSentKey = 'sq';

/// The key of "this Zen just started" in a `ping`: a locked phone answers
/// it at once, however lately it answered this friend (it did before the
/// start, and that answer is gone with the app that asked), see
/// kLockedFreshPongEvery. Older Zens ignore it.
const String kPresenceFreshKey = 'fs';

/// A state told earlier than the last one taken from the same device by
/// at most this much came late and is not taken. Further back it is a
/// clock set back, and it is taken (nothing would be for that long).
const Duration kPresenceReorderWindow = Duration(minutes: 1);

/// What one `ping`, `pong` or `away` says about its sender: the state, and
/// how long ago Zen was last open there ([openedAgo], `null` when not told:
/// the friend hides it, or the device does not know), and when the sender
/// told it ([sentAtMillis], its own clock; `null` from an older Zen).
@immutable
final class PresenceReport {
  const PresenceReport({
    required this.presence,
    this.openedAgo,
    this.sentAtMillis,
  });

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
    final Object? sq = payload[kPresenceSentKey];
    return PresenceReport(
      presence: presence,
      openedAgo: openedAgo,
      sentAtMillis: sq is int && sq > 0 ? sq : null,
    );
  }

  final PeerPresence presence;
  final Duration? openedAgo;
  final int? sentAtMillis;

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
/// it to itself; [sentAtMillis] this device's clock now (the order of what
/// it tells, [kPresenceSentKey]). [PeerPresence.hidden] (and
/// [PeerPresence.unknown], [PeerPresence.noConnection]) says nothing at
/// all.
Map<String, dynamic> presenceFields({
  required PeerPresence own,
  Duration? openedAgo,
  int? sentAtMillis,
}) {
  final String? state = switch (own) {
    PeerPresence.online => kPresenceForeground,
    PeerPresence.background => kPresenceBackground,
    PeerPresence.offline => kPresenceAsleep,
    PeerPresence.hidden ||
    PeerPresence.unknown ||
    PeerPresence.noConnection => null,
  };
  if (state == null) {
    return const <String, dynamic>{};
  }
  return <String, dynamic>{
    kPresenceStateKey: state,
    if (openedAgo != null)
      kPresenceOpenedKey: openedAgo.isNegative ? 0 : openedAgo.inSeconds,
    if (sentAtMillis != null && sentAtMillis > 0)
      kPresenceSentKey: sentAtMillis,
  };
}

/// How present [presence] is, for picking among a friend's devices: Zen
/// open on one of them beats one in the background, which beats one
/// about to stop receiving; a device that tells nothing counts least.
int _presenceRank(PeerPresence presence) => switch (presence) {
  PeerPresence.online => 3,
  PeerPresence.background => 2,
  PeerPresence.offline => 1,
  PeerPresence.hidden || PeerPresence.unknown || PeerPresence.noConnection => 0,
};

/// What each device of each friend told last (the account routing hands
/// every device's frames over as the friend's), and so what the friend's
/// presence is: Zen open on any of their devices is "online", else one
/// in the background is "w tle" (a phone in the pocket does not hide the
/// computer with Zen on its screen, nor the other way round). A state
/// told earlier than the last one taken from the same device
/// ([kPresenceSentKey], within [kPresenceReorderWindow]) came late and is
/// not taken: a stale "online" never undoes the "w tle" told after it.
/// A friend with one device, and a Zen that does not tell the order, keep
/// what each frame says as it comes.
final class PresenceDevices {
  PresenceDevices({this.reorderWindow = kPresenceReorderWindow});

  final Duration reorderWindow;

  /// Friend → device → (what it told, when it came here).
  final Map<String, Map<String, ({PresenceReport report, int at})>> _told =
      <String, Map<String, ({PresenceReport report, int at})>>{};

  /// The most friends, and devices of one friend, kept.
  static const int maxFriends = 2000;
  static const int maxDevices = 16;

  /// [report] from [friend]'s [device] came at [atMillis] (this device's
  /// clock): the friend's presence now, all their devices together, with
  /// the time it was told here; `null` when it came late (nothing changes).
  ({PresenceReport report, int at})? note({
    required String friend,
    required String device,
    required PresenceReport report,
    required int atMillis,
    required Duration foregroundFor,
    required Duration backgroundFor,
  }) {
    Map<String, ({PresenceReport report, int at})>? devices = _told[friend];
    if (devices == null) {
      if (_told.length >= maxFriends) {
        _told.clear();
      }
      devices = _told[friend] = <String, ({PresenceReport report, int at})>{};
    }
    final int? sent = report.sentAtMillis;
    final int? last = devices[device]?.report.sentAtMillis;
    if (sent != null &&
        last != null &&
        sent < last &&
        last - sent <= reorderWindow.inMilliseconds) {
      return null;
    }
    devices.remove(device);
    if (devices.length >= maxDevices) {
      devices.remove(devices.keys.first);
    }
    final ({PresenceReport report, int at}) heard = (
      report: report,
      at: atMillis,
    );
    devices[device] = heard;
    ({PresenceReport report, int at}) best = heard;
    int bestRank = _presenceRank(report.presence);
    for (final ({PresenceReport report, int at}) other in devices.values) {
      if (identical(other, heard)) {
        continue;
      }
      final int rank = _presenceRank(
        presenceAt(
          presence: other.report.presence,
          presenceAtMillis: other.at,
          nowMillis: atMillis,
          foregroundFor: foregroundFor,
          backgroundFor: backgroundFor,
        ),
      );
      // Only what is still worth as much as it said: an "online" that
      // has expired is not picked over a fresh word.
      if (rank > bestRank && rank == _presenceRank(other.report.presence)) {
        best = other;
        bestRank = rank;
      }
    }
    return best;
  }
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

/// Whether a presence last confirmed at [confirmedAtMillis] is still worth
/// showing at [nowMillis] ([kPresenceRememberedFor]); a time ahead of the
/// clock (the clock was set back) is not.
bool presenceRemembered({
  required int confirmedAtMillis,
  required int nowMillis,
}) {
  final int age = nowMillis - confirmedAtMillis;
  return confirmedAtMillis > 0 &&
      age >= 0 &&
      age <= kPresenceRememberedFor.inMilliseconds;
}
