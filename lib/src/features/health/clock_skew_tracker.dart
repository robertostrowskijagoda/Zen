import 'package:flutter/foundation.dart';

/// Compares this phone's clock with the timestamps friends put on their
/// messages. Each subsystem silently drops what lies outside its
/// own tolerance, so a clock that is off by minutes looks like "nothing
/// arrives" — this makes it visible.
///
/// A message always takes some time to arrive, so `peer time − arrival
/// time` is the peer's clock offset **minus the delay**. Per friend the
/// largest recent difference is therefore the best estimate (the freshest
/// message had the shortest delay); the estimate is the median over
/// friends, so one friend with a wrong clock does not decide.
class ClockSkewTracker extends ChangeNotifier {
  ClockSkewTracker({this.minPeers = 2});

  /// The process-wide tracker, fed by the message handler.
  static final ClockSkewTracker instance = ClockSkewTracker();

  /// Beyond this the phone's clock is called wrong.
  static const Duration warnThreshold = Duration(minutes: 2);

  /// Samples older than this are replaced even by a smaller difference
  /// (the clock may have been corrected since).
  static const Duration sampleLifetime = Duration(hours: 6);

  /// At most so many friends are remembered.
  static const int maxPeers = 64;

  /// How many different friends must agree before a verdict.
  final int minPeers;

  final Map<String, _Sample> _byPeer = <String, _Sample>{};

  /// A friend's message that says it was written at [peerMillis], seen
  /// here at [receivedAtMillis] (this phone's clock).
  void observe(String peer, int peerMillis, int receivedAtMillis) {
    if (peer.isEmpty || peerMillis <= 0) {
      return;
    }
    final int diff = peerMillis - receivedAtMillis;
    final _Sample? old = _byPeer[peer];
    final bool expired =
        old != null &&
        receivedAtMillis - old.at > sampleLifetime.inMilliseconds;
    final Duration before = estimate ?? Duration.zero;
    if (old == null || expired) {
      if (old == null && _byPeer.length >= maxPeers) {
        _byPeer.remove(_byPeer.keys.first);
      }
      _byPeer[peer] = _Sample(diff, receivedAtMillis, 1);
    } else {
      _byPeer[peer] = _Sample(
        diff > old.diff ? diff : old.diff,
        diff > old.diff ? receivedAtMillis : old.at,
        old.count + 1,
      );
    }
    if ((estimate ?? Duration.zero) != before) {
      notifyListeners();
    }
  }

  void clear() {
    _byPeer.clear();
    notifyListeners();
  }

  /// How many friends contributed.
  int get peerCount => _usable().length;

  List<int> _usable() {
    // A negative difference may be only a late delivery: it counts when the
    // friend sent at least two messages (one of them was surely live). A
    // positive one cannot come from a delay.
    final List<int> out = <int>[
      for (final _Sample s in _byPeer.values)
        if (s.diff > 0 || s.count >= 2) s.diff,
    ]..sort();
    return out;
  }

  /// Friends whose differences must lie this close to the median for it to
  /// count: a flush of late relayed mail gives every friend a different
  /// delay, a wrong clock gives all of them the same offset.
  static const int agreeMillis = 90 * 1000;

  /// The friends' clock minus this phone's: positive = this phone is
  /// behind. `null` while there is not enough (agreeing) data.
  Duration? get estimate {
    final List<int> d = _usable();
    if (d.length < minPeers || d.isEmpty) {
      return null;
    }
    final int mid = d.length ~/ 2;
    final int median = d.length.isOdd ? d[mid] : (d[mid - 1] + d[mid]) ~/ 2;
    final int agreeing = d
        .where((int x) => (x - median).abs() <= agreeMillis)
        .length;
    if (agreeing < minPeers) {
      return null;
    }
    return Duration(milliseconds: median);
  }

  /// This phone's clock is off by more than [warnThreshold].
  bool get skewed {
    final Duration? e = estimate;
    return e != null && e.abs() > warnThreshold;
  }

  /// This phone runs ahead of its friends (a fast clock).
  bool get phoneAhead => (estimate ?? Duration.zero).isNegative;
}

@immutable
class _Sample {
  const _Sample(this.diff, this.at, this.count);

  final int diff;
  final int at;
  final int count;
}
