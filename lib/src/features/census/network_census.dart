import 'dart:convert';
import 'dart:math' as math;

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/foundation.dart';
import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/core/logging/zen_log.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';

// How many people use Zen, estimated without anyone learning who.
//
// Every account puts one anonymous identifier per month into a
// HyperLogLog sketch: HMAC-SHA256 of the month with a secret only the
// account's own devices hold (the ledger's self key), so the account's
// devices count once, nobody can recognise it, and next month it is
// another, unlinkable one. Friends exchange their sketches (a `census`
// frame, at most once an hour per friend and only when it changed) and
// merge them register by register (the maximum), so after a while every
// phone holds about the same sketch of the whole network: 2048 registers,
// ~2.3% standard error, 1.5 KB per month on the wire.
//
// Months: the current month's sketch and the previous one are kept; the
// number shown is the larger estimate, so it follows growth at once and
// forgets those who left within two months.
//
// A friend could send a forged sketch to make the number huge. Each
// friend's sketch is therefore kept apart, and with three or more sources
// (this account and friends) every register takes the second-largest value
// any source has: one source alone cannot raise it, neither in what this
// phone shows nor in what it passes on. With fewer sources the plain
// maximum is used (a phone with one friend has to believe that friend).
// Two colluding friends, or a friend with a single other friend, can still
// inflate it: the number is a rough guide, never a basis for decisions.

/// Registers: 2^11.
const int kCensusPrecision = 11;
const int kCensusRegisters = 1 << kCensusPrecision;

/// Largest register value kept (about 2^40 people).
const int kCensusMaxRank = 40;

/// The frame friends exchange: `{type, e: month, c: sketch, p: previous}`.
const String kCensusType = 'census';

/// A friend gets the sketch at most this often (and only when it changed).
const Duration kCensusSendInterval = Duration(hours: 1);

/// A friend's sketch is taken at most this often.
const Duration kCensusAcceptInterval = Duration(minutes: 30);

/// Friends' sketches kept per month at most (the most recent ones).
const int kCensusMaxSources = 300;

/// The month number of [utc] (months since January 2024).
int censusEpoch(DateTime utc) => (utc.year - 2024) * 12 + utc.month - 1;

/// A HyperLogLog sketch with [kCensusRegisters] registers.
final class CensusSketch {
  CensusSketch() : registers = Uint8List(kCensusRegisters);

  CensusSketch._(this.registers);

  final Uint8List registers;

  bool get isEmpty => registers.every((int r) => r == 0);

  /// Puts [id] in: the first 64 bits of SHA-256(id) give the register (top
  /// [kCensusPrecision] bits) and the rank (leading zeros of the rest + 1).
  void add(List<int> id) {
    final List<int> digest = crypto.sha256.convert(id).bytes;
    int index = (digest[0] << 3) | (digest[1] >> 5);
    index &= kCensusRegisters - 1;
    // The 53 bits after the index, most significant first.
    int rank = 1;
    bool found = false;
    for (int bit = kCensusPrecision; bit < 64 && !found; bit++) {
      if ((digest[bit >> 3] >> (7 - (bit & 7))) & 1 == 1) {
        found = true;
      } else {
        rank++;
      }
    }
    _raise(index, math.min(rank, kCensusMaxRank));
  }

  bool _raise(int index, int value) {
    if (value <= registers[index]) {
      return false;
    }
    registers[index] = value;
    return true;
  }

  /// Takes the larger value of every register; whether anything changed.
  bool merge(CensusSketch other) {
    bool changed = false;
    for (int i = 0; i < kCensusRegisters; i++) {
      changed = _raise(i, other.registers[i]) || changed;
    }
    return changed;
  }

  /// The estimated number of distinct identifiers put in.
  double estimate() {
    const int m = kCensusRegisters;
    final double alpha = 0.7213 / (1 + 1.079 / m);
    double sum = 0;
    int zeros = 0;
    for (final int r in registers) {
      sum += math.pow(2, -r);
      if (r == 0) {
        zeros++;
      }
    }
    final double raw = alpha * m * m / sum;
    if (raw <= 2.5 * m && zeros > 0) {
      return m * math.log(m / zeros);
    }
    return raw;
  }

  /// The registers packed in 6 bits each, base64url (2048 characters).
  String encode() {
    final Uint8List packed = Uint8List(kCensusRegisters * 6 ~/ 8);
    int bitPos = 0;
    for (final int r in registers) {
      for (int b = 5; b >= 0; b--) {
        if ((r >> b) & 1 == 1) {
          packed[bitPos >> 3] |= 1 << (7 - (bitPos & 7));
        }
        bitPos++;
      }
    }
    return base64Url.encode(packed);
  }

  /// A sketch from [encode], or null for anything else.
  static CensusSketch? decode(Object? value) {
    if (value is! String || value.length != kCensusRegisters) {
      return null;
    }
    final Uint8List packed;
    try {
      packed = base64Url.decode(value);
    } on FormatException {
      return null;
    }
    if (packed.length != kCensusRegisters * 6 ~/ 8) {
      return null;
    }
    final Uint8List registers = Uint8List(kCensusRegisters);
    int bitPos = 0;
    for (int i = 0; i < kCensusRegisters; i++) {
      int r = 0;
      for (int b = 0; b < 6; b++) {
        r = (r << 1) | ((packed[bitPos >> 3] >> (7 - (bitPos & 7))) & 1);
        bitPos++;
      }
      registers[i] = math.min(r, kCensusMaxRank);
    }
    return CensusSketch._(registers);
  }

  /// The sketch of several sources (see the top of this file): the
  /// maximum per register with fewer than three, else the second-largest.
  static CensusSketch combine(Iterable<CensusSketch> sources) {
    final List<CensusSketch> all = sources.toList(growable: false);
    final CensusSketch out = CensusSketch();
    if (all.length < 3) {
      for (final CensusSketch s in all) {
        out.merge(s);
      }
      return out;
    }
    for (int i = 0; i < kCensusRegisters; i++) {
      int first = 0;
      int second = 0;
      for (final CensusSketch s in all) {
        final int r = s.registers[i];
        if (r > first) {
          second = first;
          first = r;
        } else if (r > second) {
          second = r;
        }
      }
      out.registers[i] = second;
    }
    return out;
  }
}

/// What the app shows: the estimate, its month, and when it last changed.
@immutable
final class CensusView {
  const CensusView({
    required this.estimate,
    required this.epoch,
    required this.updatedAt,
  });

  final int estimate;
  final int epoch;

  /// Millis since epoch; 0 before anything was counted.
  final int updatedAt;
}

/// The month's sketches: this account's own and each friend's.
final class _Month {
  _Month(this.epoch);

  final int epoch;
  final Map<String, CensusSketch> sources = <String, CensusSketch>{};
  final Map<String, int> seenAt = <String, int>{};

  CensusSketch combined() => CensusSketch.combine(sources.values);

  void put(String source, CensusSketch sketch, int now) {
    sources[source] = sketch;
    seenAt[source] = now;
    while (sources.length > kCensusMaxSources) {
      String? oldest;
      for (final String s in seenAt.keys) {
        if (s != _self && (oldest == null || seenAt[s]! < seenAt[oldest]!)) {
          oldest = s;
        }
      }
      if (oldest == null) {
        break;
      }
      sources.remove(oldest);
      seenAt.remove(oldest);
    }
  }
}

const String _self = 'self';

/// The census of one phone: its sketches, the frames to and from friends.
final class NetworkCensus extends ChangeNotifier {
  NetworkCensus({
    required this.disk,
    required this.send,
    required this.isFriend,
    required this.secret,
    int Function()? now,
  }) : _now = now ?? (() => DateTime.now().millisecondsSinceEpoch);

  final LedgerDisk disk;
  final Future<void> Function(String to, Map<String, dynamic> payload) send;
  final bool Function(String address) isFriend;

  /// The secret of this account's identifiers (null while unknown: the
  /// account does not count yet).
  final Uint8List? Function() secret;
  final int Function() _now;

  static const String storageKey = 'census/state';

  _Month _current = _Month(0);
  _Month? _previous;
  int _updatedAt = 0;
  final Map<String, int> _sentAt = <String, int>{};
  final Map<String, String> _sentDigest = <String, String>{};
  final Map<String, int> _acceptedAt = <String, int>{};
  bool _loaded = false;

  int get _epoch =>
      censusEpoch(DateTime.fromMillisecondsSinceEpoch(_now(), isUtc: true));

  /// The current estimate (the larger of this month's and last month's).
  CensusView get view {
    _roll();
    _addSelf();
    final double current = _current.combined().estimate();
    final double previous = _previous?.combined().estimate() ?? 0;
    return CensusView(
      estimate: math.max(current, previous).round(),
      epoch: _current.epoch,
      updatedAt: _updatedAt,
    );
  }

  Future<void> load() async {
    if (_loaded) {
      return;
    }
    _loaded = true;
    try {
      final Uint8List? raw = await disk.read(storageKey);
      if (raw != null) {
        _read(jsonDecode(utf8.decode(raw)));
      }
    } on Object catch (error) {
      logZenWarning('Licznik sieci jest uszkodzony; zaczynam od zera: $error');
    }
    _roll();
    if (_addSelf()) {
      await _save();
    }
    notifyListeners();
  }

  void _read(Object? json) {
    if (json is! Map || json['v'] != 1) {
      return;
    }
    _updatedAt = json['u'] is int ? json['u'] as int : 0;
    _Month? month(Object? m) {
      if (m is! Map || m['e'] is! int || m['s'] is! Map) {
        return null;
      }
      final _Month out = _Month(m['e'] as int);
      (m['s'] as Map<Object?, Object?>).forEach((Object? k, Object? v) {
        final CensusSketch? sketch = CensusSketch.decode(v);
        if (k is String && sketch != null) {
          out.put(k, sketch, 0);
        }
      });
      return out;
    }

    _current = month(json['c']) ?? _Month(_epoch);
    _previous = month(json['p']);
  }

  Map<String, Object?> _write() {
    Map<String, Object?> month(_Month m) => <String, Object?>{
      'e': m.epoch,
      's': <String, String>{
        for (final MapEntry<String, CensusSketch> e in m.sources.entries)
          e.key: e.value.encode(),
      },
    };
    return <String, Object?>{
      'v': 1,
      'u': _updatedAt,
      'c': month(_current),
      if (_previous != null) 'p': month(_previous!),
    };
  }

  Future<void> _save() => disk.write(
    storageKey,
    Uint8List.fromList(utf8.encode(jsonEncode(_write()))),
  );

  /// Moves to a new month when the calendar did.
  void _roll() {
    final int epoch = _epoch;
    if (epoch <= _current.epoch) {
      // The same month (or a clock that went back: nothing is undone).
      return;
    }
    _previous = epoch == _current.epoch + 1 ? _current : null;
    _current = _Month(epoch);
  }

  /// Puts this account's identifier of the month in (once the secret is
  /// known); whether that changed anything.
  bool _addSelf() {
    final Uint8List? key = secret();
    if (key == null || key.isEmpty) {
      return false;
    }
    final List<int> id = crypto.Hmac(
      crypto.sha256,
      key,
    ).convert(utf8.encode('zen.census.v1|${_current.epoch}')).bytes;
    final CensusSketch own = CensusSketch()..add(id);
    final CensusSketch? had = _current.sources[_self];
    if (had != null && !had.merge(own)) {
      // In already.
      return false;
    }
    _current.put(_self, had ?? own, _now());
    _updatedAt = _now();
    return true;
  }

  /// A frame from the transport: a friend's sketch, or a sign of a friend
  /// being there (a good moment to send ours).
  Future<void> onFrame(SignalTransportFrame frame) async {
    final Object? type = frame.payload['type'];
    final String from = PeerShareCodec.normalizeAddress(frame.from);
    if (from.isEmpty || frame.door || !isFriend(from)) {
      return;
    }
    if (type == kCensusType) {
      await _receive(from, frame.payload);
    } else if (type == 'ping' || type == 'pong' || type == 'lg_hello') {
      await maybeSend(from);
    }
  }

  Future<void> _receive(String from, Map<String, dynamic> payload) async {
    await load();
    final int now = _now();
    final int? last = _acceptedAt[from];
    if (last != null && now - last < kCensusAcceptInterval.inMilliseconds) {
      return;
    }
    final Object? e = payload['e'];
    final CensusSketch? current = CensusSketch.decode(payload['c']);
    if (e is! int || current == null) {
      return;
    }
    _acceptedAt[from] = now;
    _roll();
    final CensusSketch? previous = CensusSketch.decode(payload['p']);
    bool take(_Month? month, CensusSketch? sketch) {
      if (month == null || sketch == null) {
        return false;
      }
      final Uint8List before = month.combined().registers;
      month.put(from, sketch, now);
      return !listEquals(before, month.combined().registers);
    }

    bool changed = false;
    if (e == _current.epoch) {
      changed = take(_current, current) | take(_previous, previous);
    } else if (e == _current.epoch - 1) {
      changed = take(_previous, current);
    }
    if (changed) {
      _updatedAt = now;
      notifyListeners();
    }
    await _save();
  }

  /// Sends this phone's sketches to [friend] when an hour has passed since
  /// the last time and they changed since.
  Future<void> maybeSend(String friend) async {
    await load();
    final String to = PeerShareCodec.normalizeAddress(friend);
    final int now = _now();
    final int? last = _sentAt[to];
    if (last != null && now - last < kCensusSendInterval.inMilliseconds) {
      return;
    }
    _roll();
    _addSelf();
    final String c = _current.combined().encode();
    final _Month? previousMonth = _previous;
    final String? p = previousMonth == null || previousMonth.sources.isEmpty
        ? null
        : previousMonth.combined().encode();
    final String digest = crypto.sha256
        .convert(utf8.encode('$c|${p ?? ''}'))
        .toString();
    if (_sentDigest[to] == digest) {
      return;
    }
    _sentAt[to] = now;
    _sentDigest[to] = digest;
    await send(to, <String, dynamic>{
      'type': kCensusType,
      'e': _current.epoch,
      'c': c,
      'p': ?p,
    });
  }
}
