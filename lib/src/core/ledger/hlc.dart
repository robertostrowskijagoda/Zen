import 'package:flutter/foundation.dart';

/// Hybrid logical clock timestamp: wall time in milliseconds plus a counter
/// for events inside the same millisecond. Orders events across devices
/// without trusting any one clock, and never goes backwards on one device.
@immutable
final class Hlc implements Comparable<Hlc> {
  const Hlc(this.millis, this.counter);

  /// Encoded as one integer (`millis * 65536 + counter`) so it signs and
  /// sorts as a plain number.
  factory Hlc.fromInt(int value) => Hlc(value >> 16, value & 0xFFFF);

  static const Hlc zero = Hlc(0, 0);

  final int millis;
  final int counter;

  int toInt() => (millis << 16) | (counter & 0xFFFF);

  @override
  int compareTo(Hlc other) => millis != other.millis
      ? millis.compareTo(other.millis)
      : counter.compareTo(other.counter);

  bool operator >(Hlc other) => compareTo(other) > 0;
  bool operator <(Hlc other) => compareTo(other) < 0;

  @override
  bool operator ==(Object other) =>
      other is Hlc && other.millis == millis && other.counter == counter;

  @override
  int get hashCode => Object.hash(millis, counter);

  @override
  String toString() => 'Hlc($millis:$counter)';
}

/// How far ahead of the local clock a received timestamp may be. Anything
/// later is refused: otherwise a post dated 2099 would stay on top forever.
const Duration kMaxClockSkew = Duration(minutes: 10);

final class HlcClock {
  HlcClock({int Function()? wallClock})
    : _wall = wallClock ?? (() => DateTime.now().millisecondsSinceEpoch);

  final int Function() _wall;
  Hlc _last = Hlc.zero;

  Hlc get last => _last;

  int wallMillis() => _wall();

  /// A timestamp for a local event, later than everything seen so far.
  Hlc now() {
    final int wall = _wall();
    if (wall > _last.millis) {
      _last = Hlc(wall, 0);
    } else if (_last.counter < 0xFFFF) {
      _last = Hlc(_last.millis, _last.counter + 1);
    } else {
      _last = Hlc(_last.millis + 1, 0);
    }
    return _last;
  }

  /// Folds in a timestamp from elsewhere. Returns false (and ignores it) when
  /// it lies too far in the future.
  bool observe(Hlc remote) {
    if (!isAcceptable(remote)) {
      return false;
    }
    if (remote > _last) {
      _last = remote;
    }
    return true;
  }

  bool isAcceptable(Hlc remote) =>
      remote.millis <= _wall() + kMaxClockSkew.inMilliseconds;
}
