import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/core/logging/zen_log.dart';
import 'package:zen/src/core/storage/format_version.dart';
import 'package:zen/src/features/ledger/ledger_providers.dart';
import 'package:zen/src/features/meet/location.dart';
import 'package:zen/src/features/meet/nearby_crypto.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';

// "Mijani": who this person passed in the street or on a tram.
//
// Built only from what the "W pobliżu" radio already hears while it scans
// (the screen, the background look around, an alarm's look around): no
// scanning of its own. A friend is known by the per-friend keys; a
// friend of a friend has no key of this person's phone and cannot be told
// apart from a stranger, so both are only counted. Strangers' tokens stay
// in memory for one token slot (they change every 10 minutes for
// everyone at once), and only the largest count per hour is kept: nobody
// can be followed from slot to slot. Bluetooth addresses are never kept.
// Everything stays on this phone and goes after 30 days.

/// Where the log is kept (the encrypted store; the name says nothing).
const String kEncountersKey = 'meet/encounters';

/// How long encounters are kept.
const Duration kEncountersKeep = Duration(days: 30);

/// Sightings of one friend closer than this in time are one encounter
/// (the background look around runs every 5 minutes).
const Duration kEncounterGap = Duration(minutes: 15);

/// The time window people who cannot be told apart are counted in.
const Duration kEncounterCrowdWindow = Duration(hours: 1);

/// What was heard is written at most this long after (one write per scan
/// window in the background, one every half a minute on the screen).
const Duration kEncounterFlushAfter = Duration(seconds: 30);

/// A last known position older than this is not taken as the place.
const Duration kEncounterPlaceFresh = Duration(minutes: 30);

/// What the locked Android service saw on its looks around: friends passed
/// (`e`, [Encounter.toJson]) and the crowd counts (`c`, `[window, count]`).
/// Left in the sealed inbox from this device's own address; the app merges
/// it after unlock ([EncounterLog.takeKept]).
const String kKeptEncountersType = 'encounters_own';

/// An approximate place (rounded to about 100 m).
@immutable
final class EncounterPlace {
  const EncounterPlace._(this.lat, this.lon);

  /// [lat], [lon] rounded to three decimal places.
  factory EncounterPlace.approximate(double lat, double lon) =>
      EncounterPlace._(_round(lat), _round(lon));

  final double lat;
  final double lon;

  static double _round(double v) => (v * 1000).roundToDouble() / 1000;

  static EncounterPlace? fromJson(Object? lat, Object? lon) {
    if (lat is! num || lon is! num) {
      return null;
    }
    final double a = lat.toDouble();
    final double o = lon.toDouble();
    if (!a.isFinite || !o.isFinite || a.abs() > 90 || o.abs() > 180) {
      return null;
    }
    return EncounterPlace.approximate(a, o);
  }

  @override
  bool operator ==(Object other) =>
      other is EncounterPlace && other.lat == lat && other.lon == lon;

  @override
  int get hashCode => Object.hash(lat, lon);
}

/// How long after passing a friend "Spotkani?" may still be confirmed from
/// "Mijani" (later it is a memory, not a meeting).
const Duration kEncounterMetWindow = Duration(days: 7);

/// Whether "Spotkani?" may still be confirmed for [e] at [now].
bool encounterMayConfirm(Encounter e, int now) =>
    now - e.end <= kEncounterMetWindow.inMilliseconds;

/// A friend was near from [start] to [end] (milliseconds).
@immutable
final class Encounter {
  const Encounter({
    required this.friend,
    required this.start,
    required this.end,
    this.place,
  });

  /// The friend's address (normalised).
  final String friend;
  final int start;
  final int end;
  final EncounterPlace? place;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'f': friend,
    's': start,
    'e': end,
    if (place case final EncounterPlace p) ...<String, dynamic>{
      'la': p.lat,
      'lo': p.lon,
    },
  };

  static Encounter? fromJson(Object? json) {
    if (json is! Map) {
      return null;
    }
    final Object? f = json['f'];
    final Object? s = json['s'];
    final Object? e = json['e'];
    if (f is! String ||
        f.isEmpty ||
        f.length > 200 ||
        s is! int ||
        e is! int ||
        e < s) {
      return null;
    }
    return Encounter(
      friend: f,
      start: s,
      end: e,
      place: EncounterPlace.fromJson(json['la'], json['lo']),
    );
  }
}

/// [count] people who could not be told apart (strangers, friends of
/// friends) were near at once within the hour from [windowStart].
@immutable
final class EncounterCrowd {
  const EncounterCrowd({required this.windowStart, required this.count});

  final int windowStart;
  final int count;

  int get windowEnd => windowStart + kEncounterCrowdWindow.inMilliseconds;
}

/// The window of [kEncounterCrowdWindow] that [at] falls in.
int encounterWindowOf(int at) => at - at % kEncounterCrowdWindow.inMilliseconds;

/// [list] (newest first) with [add] in it: joined with every encounter of
/// the same friend that overlaps it or is less than [gap] away.
List<Encounter> mergeEncounter(
  List<Encounter> list,
  Encounter add, {
  Duration gap = kEncounterGap,
}) {
  final int g = gap.inMilliseconds;
  Encounter merged = add;
  final List<Encounter> rest = <Encounter>[];
  for (final Encounter e in list) {
    if (e.friend == merged.friend &&
        merged.start <= e.end + g &&
        merged.end >= e.start - g) {
      merged = Encounter(
        friend: e.friend,
        start: math.min(e.start, merged.start),
        end: math.max(e.end, merged.end),
        // The place where the encounter began stays.
        place: e.start <= merged.start
            ? e.place ?? merged.place
            : merged.place ?? e.place,
      );
    } else {
      rest.add(e);
    }
  }
  // A longer encounter may now reach one it did not before.
  if (rest.any(
    (Encounter e) =>
        e.friend == merged.friend &&
        merged.start <= e.end + g &&
        merged.end >= e.start - g,
  )) {
    return mergeEncounter(rest, merged, gap: gap);
  }
  return <Encounter>[...rest, merged]
    ..sort((Encounter a, Encounter b) => b.end.compareTo(a.end));
}

/// What is kept on disk.
final class _Saved {
  bool on = true;

  /// When the log was last cleared: nothing older comes back (the other
  /// engine may still hold sightings from before).
  int clearedAt = 0;
  List<Encounter> encounters = <Encounter>[];
  Map<int, int> crowds = <int, int>{};

  Map<String, dynamic> toJson() => <String, dynamic>{
    'v': 1,
    'on': on,
    if (clearedAt > 0) 'cl': clearedAt,
    'e': <Map<String, dynamic>>[
      for (final Encounter e in encounters) e.toJson(),
    ],
    'c': <List<int>>[
      for (final MapEntry<int, int> c in crowds.entries) <int>[c.key, c.value],
    ],
  };

  static _Saved fromJson(Object? json) {
    final _Saved s = _Saved();
    if (json is! Map || !isReadableFormat(json, current: 1)) {
      return s;
    }
    s
      ..on = json['on'] != false
      ..clearedAt = json['cl'] is int ? json['cl'] as int : 0;
    final Object? e = json['e'];
    if (e is List) {
      for (final Object? x in e.take(EncounterLog.maxEncounters)) {
        final Encounter? enc = Encounter.fromJson(x);
        if (enc != null) {
          s.encounters.add(enc);
        }
      }
    }
    final Object? c = json['c'];
    if (c is List) {
      for (final Object? x in c.take(EncounterLog.maxCrowds)) {
        if (x is List &&
            x.length == 2 &&
            x[0] is int &&
            x[1] is int &&
            (x[1] as int) > 0) {
          s.crowds[x[0] as int] = math.min(
            x[1] as int,
            EncounterLog.maxStrangersPerSlot,
          );
        }
      }
    }
    return s;
  }
}

/// "Mijani": a log, kept only on this phone, of friends who were
/// near (who, from–to, an approximate place when location is allowed) and
/// of how many others were, without telling who.
///
/// [saw] takes what the radio heard; it is written within
/// [kEncounterFlushAfter] (or at [flush], e.g. when a scan ends). Both the
/// app and the Android background service keep one; each write reads the
/// log first, so neither drops what the other wrote.
final class EncounterLog extends ChangeNotifier {
  EncounterLog({
    required this.disk,
    int Function()? now,
    Future<EncounterPlace?> Function()? place,
    this.flushAfter = kEncounterFlushAfter,
  }) : _now = now ?? (() => DateTime.now().millisecondsSinceEpoch),
       _place = place ?? (() async => null);

  final LedgerDisk disk;
  final int Function() _now;
  final Future<EncounterPlace?> Function() _place;
  final Duration flushAfter;

  /// Encounters and crowd windows kept at most.
  static const int maxEncounters = 3000;
  static const int maxCrowds = 24 * 31;

  /// Unknown people counted at most in one slot.
  static const int maxStrangersPerSlot = 300;

  _Saved _saved = _Saved();

  /// Heard but not written yet (memory only).
  List<Encounter> _pending = <Encounter>[];
  Map<int, int> _pendingCrowds = <int, int>{};

  /// The unknown tokens of the current slot only (memory only).
  int _slot = -1;
  final Set<String> _strangers = <String>{};

  Timer? _flushTimer;
  Future<void> _queue = Future<void>.value();
  bool _disposed = false;

  /// Whether passing people is written down ("Zapisuj, kogo mijam").
  bool get recording => _saved.on;

  int get _oldest => _now() - kEncountersKeep.inMilliseconds;

  /// Friends passed, newest first (what is still to be written included).
  List<Encounter> get encounters {
    List<Encounter> all = <Encounter>[
      for (final Encounter e in _saved.encounters)
        if (e.end >= _oldest) e,
    ];
    for (final Encounter e in _pending) {
      all = mergeEncounter(all, e);
    }
    return all;
  }

  /// Hours with people who could not be told apart, newest first.
  List<EncounterCrowd> get crowds {
    final Map<int, int> all = Map<int, int>.of(_saved.crowds);
    _pendingCrowds.forEach((int w, int n) {
      all[w] = math.max(all[w] ?? 0, n);
    });
    final int oldest = _oldest;
    return <EncounterCrowd>[
      for (final MapEntry<int, int> c in all.entries)
        if (c.key + kEncounterCrowdWindow.inMilliseconds >= oldest)
          EncounterCrowd(windowStart: c.key, count: c.value),
    ]..sort(
      (EncounterCrowd a, EncounterCrowd b) =>
          b.windowStart.compareTo(a.windowStart),
    );
  }

  bool get isEmpty => encounters.isEmpty && crowds.isEmpty;

  /// The radio saw a Zen phone showing [token] at [at]: [friend]'s, or
  /// someone who cannot be told apart (`null`). Nothing else about the
  /// phone is taken.
  void saw({required String token, required int at, String? friend}) {
    if (!_saved.on || _disposed) {
      return;
    }
    bool changed = false;
    if (friend != null) {
      final String key = PeerShareCodec.normalizeAddress(friend);
      final int before = _pending.length;
      _pending = mergeEncounter(
        _pending,
        Encounter(friend: key, start: at, end: at),
      );
      changed = _pending.length != before;
      if (_pending.length > maxEncounters) {
        _pending.removeLast();
      }
    } else {
      final int slot = nearbySlot(at);
      if (slot != _slot) {
        // Everybody's token changed: the last slot's are forgotten.
        _slot = slot;
        _strangers.clear();
      }
      if (_strangers.length < maxStrangersPerSlot) {
        _strangers.add(token);
      }
      final int window = encounterWindowOf(at);
      final int had = _pendingCrowds[window] ?? 0;
      if (_strangers.length > had) {
        _pendingCrowds[window] = _strangers.length;
        changed = true;
      }
    }
    _flushTimer ??= Timer(flushAfter, () {
      _flushTimer = null;
      unawaitedLogged(flush(), context: 'Mijani: zapis');
    });
    if (changed) {
      _notify();
    }
  }

  void _notify() {
    if (!_disposed) {
      notifyListeners();
    }
  }

  /// Runs [work] after whatever is being written now. A failure (e.g. the
  /// store still locked) is logged; the log stays as it was.
  Future<void> _inTurn(String what, Future<void> Function() work) {
    final Completer<void> done = Completer<void>();
    _queue = _queue.then((_) async {
      try {
        await work();
      } on Object catch (error, stack) {
        logZenError('Mijani: $what', error, stack);
      }
      done.complete();
    });
    return done.future;
  }

  Future<_Saved> _read() async {
    final Uint8List? raw = await disk.read(kEncountersKey);
    if (raw == null) {
      return _Saved();
    }
    final Object? json = jsonDecode(utf8.decode(raw));
    // A newer build's file stays as it is (saves are skipped).
    heldAsNewerOn(disk, kEncountersKey, json, current: 1);
    return _Saved.fromJson(json);
  }

  /// Drops what is older than [kEncountersKeep]; whether anything went.
  bool _prune(_Saved s) {
    final int oldest = _oldest;
    final int hadEncounters = s.encounters.length;
    final int hadCrowds = s.crowds.length;
    s.encounters.removeWhere((Encounter e) => e.end < oldest);
    s.crowds.removeWhere(
      (int w, int _) => w + kEncounterCrowdWindow.inMilliseconds < oldest,
    );
    if (s.encounters.length > maxEncounters) {
      s.encounters.sort((Encounter a, Encounter b) => b.end.compareTo(a.end));
      s.encounters.removeRange(maxEncounters, s.encounters.length);
    }
    if (s.crowds.length > maxCrowds) {
      final List<int> keep = s.crowds.keys.toList()
        ..sort((int a, int b) => b.compareTo(a));
      for (final int w in keep.skip(maxCrowds)) {
        s.crowds.remove(w);
      }
    }
    return s.encounters.length != hadEncounters || s.crowds.length != hadCrowds;
  }

  Future<void> _write(_Saved s) => disk.write(
    kEncountersKey,
    Uint8List.fromList(utf8.encode(jsonEncode(s.toJson()))),
  );

  /// Reads the log (the other engine may have written it); what is older
  /// than [kEncountersKeep] is deleted for good.
  Future<void> load() => _inTurn('odczyt', () async {
    final _Saved s = await _read();
    if (_prune(s)) {
      await _write(s);
    }
    _saved = s;
    _notify();
  });

  /// What the locked service saw while the app was locked
  /// ([kKeptEncountersType]): merged with the log and written (not when
  /// recording is off, nor what is older than the last "Wyczyść").
  Future<void> takeKept(Map<String, dynamic> payload) {
    if (!_saved.on || _disposed) {
      return Future<void>.value();
    }
    final Object? e = payload['e'];
    if (e is List) {
      for (final Object? item in e.take(maxEncounters)) {
        final Encounter? encounter = Encounter.fromJson(item);
        if (encounter != null) {
          _pending = mergeEncounter(
            _pending,
            Encounter(
              friend: PeerShareCodec.normalizeAddress(encounter.friend),
              start: encounter.start,
              end: encounter.end,
              place: encounter.place,
            ),
          );
        }
      }
      while (_pending.length > maxEncounters) {
        _pending.removeLast();
      }
    }
    final Object? c = payload['c'];
    if (c is List) {
      for (final Object? x in c.take(maxCrowds)) {
        if (x is List && x.length == 2 && x[0] is int && x[1] is int) {
          final int window = encounterWindowOf(x[0] as int);
          final int count = math.min(x[1] as int, maxStrangersPerSlot);
          if (count > 0) {
            _pendingCrowds[window] = math.max(
              _pendingCrowds[window] ?? 0,
              count,
            );
          }
        }
      }
    }
    _notify();
    return flush();
  }

  /// Writes what was heard so far.
  Future<void> flush() {
    _flushTimer?.cancel();
    _flushTimer = null;
    return _inTurn('zapis', _flushNow);
  }

  Future<void> _flushNow() async {
    if (nearbySlot(_now()) != _slot) {
      // The slot is over: its tokens are not kept any longer.
      _strangers.clear();
    }
    if (_pending.isEmpty && _pendingCrowds.isEmpty) {
      return;
    }
    final List<Encounter> pending = _pending;
    final Map<int, int> pendingCrowds = _pendingCrowds;
    _pending = <Encounter>[];
    _pendingCrowds = <int, int>{};
    final _Saved s;
    try {
      s = await _read();
    } on Object {
      // Not readable now (e.g. still locked): kept for the next write.
      for (final Encounter e in pending) {
        _pending = mergeEncounter(_pending, e);
      }
      pendingCrowds.forEach((int w, int n) {
        _pendingCrowds[w] = math.max(_pendingCrowds[w] ?? 0, n);
      });
      rethrow;
    }
    if (!s.on) {
      // Switched off meanwhile (in the other engine).
      _strangers.clear();
      _saved = s;
      _notify();
      return;
    }
    // The place is looked up once per write, only for new encounters.
    final EncounterPlace? place = pending.any((Encounter e) => e.place == null)
        ? await _safePlace()
        : null;
    for (final Encounter e in pending) {
      if (e.end < s.clearedAt) {
        continue;
      }
      s.encounters = mergeEncounter(
        s.encounters,
        Encounter(
          friend: e.friend,
          start: math.max(e.start, s.clearedAt),
          end: e.end,
          place: e.place ?? place,
        ),
      );
    }
    pendingCrowds.forEach((int w, int n) {
      if (w + kEncounterCrowdWindow.inMilliseconds > s.clearedAt) {
        s.crowds[w] = math.max(s.crowds[w] ?? 0, n);
      }
    });
    _prune(s);
    await _write(s);
    _saved = s;
    _notify();
  }

  Future<EncounterPlace?> _safePlace() async {
    try {
      return await _place();
    } on Object catch (error) {
      logZenWarning('Mijani: położenie: $error');
      return null;
    }
  }

  /// "Zapisuj, kogo mijam": off drops what was not written yet; what was
  /// written stays until [clear] or 30 days.
  Future<void> setRecording(bool on) {
    // Right away (the switch, and nothing more is taken), then on disk.
    _saved.on = on;
    _notify();
    if (!on) {
      _pending = <Encounter>[];
      _pendingCrowds = <int, int>{};
      _strangers.clear();
    }
    return _inTurn('wyłączanie', () async {
      final _Saved s = await _read();
      s.on = on;
      await _write(s);
      _saved = s;
      _notify();
    });
  }

  /// "Wyczyść": everything goes, also what is still to be written.
  Future<void> clear() {
    _flushTimer?.cancel();
    _flushTimer = null;
    _pending = <Encounter>[];
    _pendingCrowds = <int, int>{};
    _strangers.clear();
    return _inTurn('czyszczenie', () async {
      final _Saved s = await _read();
      s
        ..clearedAt = _now()
        ..encounters = <Encounter>[]
        ..crowds = <int, int>{};
      await _write(s);
      _saved = s;
      _notify();
    });
  }

  @override
  void dispose() {
    _disposed = true;
    _flushTimer?.cancel();
    _flushTimer = null;
    super.dispose();
  }
}

/// The approximate place for an encounter: only with the location
/// permission already given (the one the alarm uses; never asked for
/// here), and only the last known position — the GPS is not switched on
/// for it.
Future<EncounterPlace?> lastKnownEncounterPlace() async {
  if (kIsWeb || !Platform.isAndroid) {
    return null;
  }
  try {
    final GeoFix? fix = await lastKnownFix();
    final DateTime? at = fix?.at;
    if (fix == null ||
        at == null ||
        DateTime.now().difference(at) > kEncounterPlaceFresh) {
      return null;
    }
    return EncounterPlace.approximate(fix.lat, fix.lon);
  } on Object catch (error) {
    logZenWarning('Mijani: położenie: $error');
    return null;
  }
}

/// "Mijani" of this engine (the app, or the Android background service).
final Provider<EncounterLog> encounterLogProvider = Provider<EncounterLog>((
  Ref ref,
) {
  final EncounterLog log = EncounterLog(
    disk: ref.read(ledgerDiskProvider),
    place: lastKnownEncounterPlace,
  );
  unawaitedLogged(log.load(), context: 'Mijani: odczyt');
  ref.onDispose(() {
    unawaitedLogged(log.flush(), context: 'Mijani: zapis');
    log.dispose();
  });
  return log;
});
