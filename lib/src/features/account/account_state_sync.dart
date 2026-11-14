import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/core/ledger/ledger_codec.dart';
import 'package:zen/src/core/logging/zen_log.dart';

/// The account's states kept the same on all its devices, continuously:
/// settings, the dating profile, meetings and circles, the profile with
/// its photos, and copies kept for recovery (the household, chats with
/// strangers).
///
/// Every state is cut into units (a field, an item of a list by its `id`,
/// an element of a set, an entry of a map). A unit changed here gets the
/// next Lamport clock of this device and goes to the other devices
/// (sealed, in the account's `own` space); one that came from there is
/// taken when its clock is higher (or equal, from a device whose id sorts
/// higher), so every device ends with the same value whatever the order
/// of arrival. A removed unit leaves a tombstone. What a device writes
/// after taking a change is read back and remembered with the clock that
/// came, so taking a change never sends it back (no loops).

/// Kind of the sealed entries in the account's `own` space.
const String kAccountStateKind = 'acct_state';

/// One synced state of the account.
abstract interface class AccountSyncDomain {
  /// Stable name (`settings`, `dating`, `meet/plans`…).
  String get id;

  /// Keys whose values are kept whole (an ordered list, a photo).
  Set<String> get wholeKeys;

  /// The state now, or null when it cannot be read yet (still loading,
  /// locked): nothing is sent or removed then.
  Future<Map<String, Object?>?> read();

  /// Takes [state] (the whole state, merged).
  Future<void> write(Map<String, Object?> state);

  /// Fires when the state may have changed here.
  Stream<void> get changes;
}

/// How the devices reach each other (the ledger in the app).
abstract interface class AccountSyncChannel {
  /// This device's id.
  String get device;

  /// Whether the account has other devices to send to.
  bool get hasOtherDevices;

  /// Everything the other devices sent so far.
  Iterable<Map<String, dynamic>> existing();

  /// What they send from now on.
  Stream<Map<String, dynamic>> get incoming;

  /// A device was linked or cut off.
  Stream<void> get devicesChanged;

  Future<bool> publish(Map<String, dynamic> body);
}

/// A channel whose log of this device's changes can start over
/// ([AccountStateSync] prunes it with this, see [kAccountSyncRebaseEvery]).
abstract interface class AccountSyncLog {
  /// Starts this device's log of changes over (a checkpoint); returns
  /// where it starts, or null when nothing can be written now.
  Future<Object?> startOver();

  /// Drops what this device holds of its log before [start] (what
  /// [startOver] returned); returns how many changes went.
  Future<int> dropBefore(Object start);

  /// Zen is locked: every change opened so far is forgotten (no plain copy
  /// of one stays in memory) and none is opened until [reopen].
  void close();

  /// Zen is unlocked: the changes are opened again, and those of the other
  /// devices come once more through [AccountSyncChannel.incoming].
  Future<void> reopen();
}

/// A domain that drops units on purpose when it takes a state (the
/// passwords drop the versions a deletion saw): a unit missing after a
/// write is then a deletion here, never a newer build's field to keep
/// aside with its value.
abstract interface class AccountSyncPruning {}

/// A domain whose state keeps no deletion markers of its own (as the
/// passwords and the notes do): its deletions are written again into the
/// log at every start over, also after [kAccountSyncTombstoneLife], the
/// newest first up to [kAccountSyncMarkerBytes]. A device away for longer
/// than that life otherwise came back with what was deleted, kept it, and
/// sent it on to a device linked later.
abstract interface class AccountSyncMarkedDeletions {}

/// Most bytes of the deletions older than [kAccountSyncTombstoneLife] a
/// [AccountSyncMarkedDeletions] domain writes again at a start over (as
/// JSON units, before sealing): as much as the removed friends and groups
/// carried over a start of the private log, some 200 deletions, so a
/// flood of them never makes a start over grow without end. Older
/// deletions past it go (deleted longest ago: every device has had the
/// longest time to take them).
const int kAccountSyncMarkerBytes = 24 * 1024;

/// How often, at most, a device starts its log of changes over: a
/// checkpoint, every unit as it is now (and the deletions of the last
/// [kAccountSyncTombstoneLife]) written again after it, and everything
/// before it dropped, here and (when they get the checkpoint) on the
/// account's other devices. Only when something was overwritten or deleted
/// since the last time. So an overwritten or deleted value (an old
/// password, a deleted note) leaves this device's log within this time of
/// the next look at the states (at most [kAccountSyncScanEvery]).
const Duration kAccountSyncRebaseEvery = Duration(hours: 6);

/// How long a deletion is written again into the log when it starts over.
/// A device away for less than this gets the deletion itself; one away
/// longer gets the state as it is now: a password's or a note's deletion
/// is also a marker inside the state, which stays (up to the markers each
/// keeps), and the deletions of the dating profile, the profile and the
/// meetings are written again for longer ([AccountSyncMarkedDeletions]),
/// so nothing deleted comes back; and every device keeps its own
/// record of each deletion (no value in it) for good, so a returning
/// device's old units are never taken over newer deletions.
const Duration kAccountSyncTombstoneLife = Duration(days: 30);

// ---- units ----

const String _sep = '\u001f';

String _unit(String kind, String key, [String? sub]) =>
    sub == null ? '$kind$_sep$key' : '$kind$_sep$key$_sep$sub';

bool _scalar(Object? v) => v is String || v is num || v is bool;

/// [state] cut into units (see [AccountStateSync]).
Map<String, Object?> flattenAccountState(
  Map<String, Object?> state, {
  Set<String> whole = const <String>{},
}) {
  final Map<String, Object?> out = <String, Object?>{};
  for (final MapEntry<String, Object?> e in state.entries) {
    final String k = e.key;
    final Object? v = e.value;
    if (k.contains(_sep) || whole.contains(k)) {
      out[_unit('v', k)] = v;
      continue;
    }
    if (v is List &&
        v.isNotEmpty &&
        v.every((Object? x) => x is Map && x['id'] is String) &&
        v.map((Object? x) => (x! as Map)['id']).toSet().length == v.length) {
      for (final Object? item in v) {
        out[_unit('i', k, (item! as Map)['id'] as String)] = item;
      }
    } else if (v is List && v.isNotEmpty && v.every(_scalar)) {
      for (final Object? x in v) {
        out[_unit('s', k, jsonEncode(x))] = x;
      }
    } else if (v is Map &&
        v.isNotEmpty &&
        v.keys.every((Object? s) => s is String)) {
      for (final MapEntry<Object?, Object?> m in v.entries) {
        out[_unit('m', k, m.key! as String)] = m.value;
      }
    } else {
      out[_unit('v', k)] = v;
    }
  }
  return out;
}

/// The state made of [units], in the order of [base] where it has one.
Map<String, Object?> unflattenAccountState(
  Map<String, Object?> units,
  Map<String, Object?> base,
) {
  final Map<String, Map<String, Object?>> items =
      <String, Map<String, Object?>>{};
  final Map<String, Map<String, Object?>> sets =
      <String, Map<String, Object?>>{};
  final Map<String, Map<String, Object?>> maps =
      <String, Map<String, Object?>>{};
  final Map<String, Object?> wholes = <String, Object?>{};
  final List<String> order = <String>[...base.keys];
  for (final MapEntry<String, Object?> u in units.entries) {
    final List<String> parts = u.key.split(_sep);
    if (parts.length < 2) {
      continue;
    }
    final String kind = parts[0];
    final String key = parts[1];
    final String sub = parts.length > 2 ? parts.sublist(2).join(_sep) : '';
    if (!order.contains(key)) {
      order.add(key);
    }
    switch (kind) {
      case 'i':
        (items[key] ??= <String, Object?>{})[sub] = u.value;
      case 's':
        (sets[key] ??= <String, Object?>{})[sub] = u.value;
      case 'm':
        (maps[key] ??= <String, Object?>{})[sub] = u.value;
      default:
        wholes[key] = u.value;
    }
  }
  List<String> inOrder(Iterable<String> have, List<String> before) => <String>[
    for (final String b in before)
      if (have.contains(b)) b,
    ...(have.where((String h) => !before.contains(h)).toList()..sort()),
  ];
  final Map<String, Object?> out = <String, Object?>{};
  for (final String k in order) {
    final Object? old = base[k];
    if (items[k]?.isNotEmpty ?? false) {
      final List<String> before = <String>[
        if (old is List)
          for (final Object? x in old)
            if (x is Map && x['id'] is String) x['id'] as String,
      ];
      out[k] = <Object?>[
        for (final String id in inOrder(items[k]!.keys, before)) items[k]![id],
      ];
    } else if (sets[k]?.isNotEmpty ?? false) {
      final List<String> before = <String>[
        if (old is List)
          for (final Object? x in old) jsonEncode(x),
      ];
      out[k] = <Object?>[
        for (final String s in inOrder(sets[k]!.keys, before)) sets[k]![s],
      ];
    } else if (maps[k]?.isNotEmpty ?? false) {
      final List<String> before = <String>[
        if (old is Map)
          for (final Object? s in old.keys)
            if (s is String) s,
      ];
      out[k] = <String, Object?>{
        for (final String s in inOrder(maps[k]!.keys, before)) s: maps[k]![s],
      };
    } else if (wholes.containsKey(k)) {
      out[k] = wholes[k];
    }
  }
  return out;
}

Object? _canonical(Object? v) {
  if (v is Map) {
    final List<String> keys = <String>[for (final Object? k in v.keys) '$k']
      ..sort();
    return <String, Object?>{for (final String k in keys) k: _canonical(v[k])};
  }
  if (v is List) {
    return <Object?>[for (final Object? x in v) _canonical(x)];
  }
  return v;
}

/// A short hash of [value] (the same for equal JSON, whatever key order).
String accountStateHash(Object? value) =>
    sha256Hex(utf8.encode(jsonEncode(_canonical(value)))).substring(0, 32);

final class _Unit {
  const _Unit(
    this.clock,
    this.writer,
    this.hash, {
    this.deleted = false,
    this.held = false,
    this.at = 0,
  });

  final int clock;
  final String writer;
  final String hash;
  final bool deleted;

  /// For a deletion: when this device learnt of it (wall clock), so it is
  /// written again into the log only for [kAccountSyncTombstoneLife].
  final int at;

  /// Sent by another device, but this build's domain does not keep it (a
  /// field a newer build added): kept aside with its value
  /// ([AccountStateSync]'s held values), never taken for a deletion, and
  /// written into the domain first once an update makes it understood.
  final bool held;

  List<Object> toJson() => <Object>[
    clock,
    writer,
    hash,
    if (deleted) ...<Object>[1, at] else if (held) 2,
  ];

  static _Unit? fromJson(Object? json) {
    if (json is! List ||
        json.length < 3 ||
        json[0] is! int ||
        json[1] is! String ||
        json[2] is! String) {
      return null;
    }
    return _Unit(
      json[0] as int,
      json[1] as String,
      json[2] as String,
      deleted: json.length > 3 && json[3] == 1,
      held: json.length > 3 && json[3] == 2,
      at: json.length > 4 && json[4] is int ? json[4] as int : 0,
    );
  }

  /// Whether ([clock], [writer]) wins over this.
  bool loses(int clock, String writer) =>
      clock > this.clock ||
      (clock == this.clock && writer.compareTo(this.writer) > 0);
}

/// How often [AccountStateSync] reads and hashes every state anyway. Each
/// scan decrypts about ten stores, so not often: changes do not wait for
/// it.
const Duration kAccountSyncScanEvery = Duration(minutes: 15);

/// Most bytes of units (plain JSON) in one change sent to the other
/// devices: sealed (base64, a third more), signed (several KiB) and framed,
/// it stays under the 64 KiB an entry of the account's log may have.
const int kAccountSyncPartBytes = 24 * 1024;

/// Keeps [domains] the same on the account's devices through [channel];
/// its own bookkeeping lives on [disk].
final class AccountStateSync {
  AccountStateSync({
    required this.channel,
    required this.disk,
    required List<AccountSyncDomain> domains,
    this.delay = const Duration(seconds: 2),
    this.scanEvery = kAccountSyncScanEvery,
    this.mayRead,
    this.rebaseEvery = kAccountSyncRebaseEvery,
    this.tombstoneLife = kAccountSyncTombstoneLife,
    int Function()? now,
  }) : _now = now ?? (() => DateTime.now().millisecondsSinceEpoch),
       _domains = <String, AccountSyncDomain>{
         for (final AccountSyncDomain d in domains) d.id: d,
       };

  final AccountSyncChannel channel;
  final LedgerDisk disk;
  final Map<String, AccountSyncDomain> _domains;

  /// Quiet time after a change before it is sent.
  final Duration delay;

  /// How often every state is looked at anyway (a safety net: every
  /// domain tells its changes, which are sent [delay] after they come).
  final Duration scanEvery;

  /// Whether the states can be read now (`null`: always). A locked app's
  /// stores do not open without its key, so the periodic scan is skipped
  /// then instead of failing every [scanEvery]; changes after the unlock
  /// are sent as they come, and the next scan looks at everything again.
  final Future<bool> Function()? mayRead;

  /// [kAccountSyncRebaseEvery].
  final Duration rebaseEvery;

  /// [kAccountSyncTombstoneLife].
  final Duration tombstoneLife;
  final int Function() _now;

  static const String _stateKey = 'account/sync/state';

  /// When this device's log last started over.
  int _rebasedAt = 0;

  /// Something was overwritten or deleted since (the log holds values no
  /// longer current).
  bool _superseded = false;

  /// Zen is locked: nothing opened is kept ([lock]).
  bool _locked = false;

  /// Changes that came while locked were let go: taken again at [unlock].
  bool _retake = false;

  /// How many times the log started over (tests).
  int rebased = 0;

  int _lamport = 0;
  final Map<String, Map<String, _Unit>> _units = <String, Map<String, _Unit>>{};

  /// Domain → the values of its held units ([_Unit.held]).
  final Map<String, Map<String, Object?>> _held =
      <String, Map<String, Object?>>{};

  Map<String, Object?> _heldOf(String domain) =>
      _held[domain] ??= <String, Object?>{};

  /// Changes from other devices that could not be taken yet.
  final List<Map<String, dynamic>> _deferred = <Map<String, dynamic>>[];

  /// States changed while there was nobody to send them to.
  final Set<String> _unsent = <String>{};

  final List<StreamSubscription<Object?>> _subs =
      <StreamSubscription<Object?>>[];
  Timer? _timer;
  Timer? _periodic;
  Future<void> _queue = Future<void>.value();
  bool _stopped = false;

  /// How many changes this device sent (tests).
  int published = 0;

  Future<void> start() async {
    await _load();
    if (_rebasedAt == 0) {
      // The bound counts from the first start.
      _rebasedAt = _now();
    }
    for (final Map<String, dynamic> body in channel.existing()) {
      _enqueue(() => _take(body));
    }
    _subs
      ..add(
        channel.incoming.listen((Map<String, dynamic> b) {
          _enqueue(() => _take(b));
        }),
      )
      ..add(channel.devicesChanged.listen((_) => _enqueue(_sendAll)));
    for (final AccountSyncDomain d in _domains.values) {
      _subs.add(d.changes.listen((_) => _schedule()));
    }
    _periodic = Timer.periodic(scanEvery, (_) => _enqueue(_periodicScan));
    _enqueue(_scan);
  }

  /// The periodic safety net: a scan unless the states cannot be read now.
  Future<void> _periodicScan() async {
    final Future<bool> Function()? mayRead = this.mayRead;
    if (mayRead != null && !await mayRead()) {
      return;
    }
    await _scan();
  }

  Future<void> stop() async {
    _stopped = true;
    _timer?.cancel();
    _periodic?.cancel();
    for (final StreamSubscription<Object?> s in _subs) {
      await s.cancel();
    }
    _subs.clear();
  }

  /// Waits until everything queued so far is done.
  Future<void> get idle => _queue;

  /// Looks at every state now and sends what changed (tests; normally
  /// after [delay]).
  Future<void> flush() {
    _timer?.cancel();
    _timer = null;
    _enqueue(_scan);
    return _queue;
  }

  void _schedule() {
    if (_stopped) {
      return;
    }
    _timer?.cancel();
    _timer = Timer(delay, () {
      _timer = null;
      _enqueue(_scan);
    });
  }

  void _enqueue(Future<void> Function() work) {
    _queue = _queue.then((_) async {
      if (_stopped) {
        return;
      }
      try {
        await work();
      } on Object catch (error, stack) {
        logZenError('Account state on devices', error, stack);
      }
    });
  }

  Future<void> _load() async {
    final Uint8List? raw = await disk.read(_stateKey);
    if (raw == null) {
      return;
    }
    try {
      final Object? json = jsonDecode(utf8.decode(raw));
      if (json is! Map) {
        return;
      }
      _lamport = json['l'] is int ? json['l'] as int : 0;
      _rebasedAt = json['rb'] is int ? json['rb'] as int : 0;
      // A state saved by an earlier build: its log never started over.
      _superseded = json['sp'] == true || !json.containsKey('rb');
      final Object? d = json['d'];
      if (d is Map) {
        for (final MapEntry<Object?, Object?> e in d.entries) {
          final Object? units = e.value;
          if (e.key is! String || units is! Map) {
            continue;
          }
          _units[e.key! as String] = <String, _Unit>{
            for (final MapEntry<Object?, Object?> u in units.entries)
              if (u.key is String && _Unit.fromJson(u.value) != null)
                u.key! as String: _Unit.fromJson(u.value)!,
          };
        }
      }
      final Object? unsent = json['n'];
      if (unsent is List) {
        _unsent.addAll(unsent.whereType<String>());
      }
      final Object? held = json['h'];
      if (held is Map) {
        for (final MapEntry<Object?, Object?> e in held.entries) {
          final Object? values = e.value;
          if (e.key is String && values is Map) {
            _held[e.key! as String] = <String, Object?>{
              for (final MapEntry<Object?, Object?> v in values.entries)
                if (v.key is String) v.key! as String: v.value,
            };
          }
        }
      }
    } on FormatException {
      // Starts over: every unit is sent again once.
    }
  }

  Future<void> _save() => disk.write(
    _stateKey,
    Uint8List.fromList(
      utf8.encode(
        jsonEncode(<String, Object>{
          'l': _lamport,
          'd': <String, Object>{
            for (final MapEntry<String, Map<String, _Unit>> e in _units.entries)
              e.key: <String, Object>{
                for (final MapEntry<String, _Unit> u in e.value.entries)
                  u.key: u.value.toJson(),
              },
          },
          'n': _unsent.toList(),
          'rb': _rebasedAt,
          'sp': _superseded,
          if (_held.values.any((Map<String, Object?> m) => m.isNotEmpty))
            'h': <String, Object>{
              for (final MapEntry<String, Map<String, Object?>> e
                  in _held.entries)
                if (e.value.isNotEmpty) e.key: e.value,
            },
        }),
      ),
    ),
  );

  Future<void> _scan() async {
    // What could not be taken before, first.
    final List<Map<String, dynamic>> waiting = List<Map<String, dynamic>>.of(
      _deferred,
    );
    _deferred.clear();
    for (final Map<String, dynamic> body in waiting) {
      await _take(body);
    }
    bool dirty = false;
    for (final AccountSyncDomain d in _domains.values) {
      final Map<String, Object?>? state = await d.read();
      if (state == null) {
        continue;
      }
      final Map<String, Object?> units = flattenAccountState(
        state,
        whole: d.wholeKeys,
      );
      final Map<String, _Unit> known = _units[d.id] ??= <String, _Unit>{};
      if (await _writeHeld(d, state, units, known)) {
        dirty = true;
      }
      final Map<String, Object?> delta = <String, Object?>{};
      for (final MapEntry<String, Object?> u in units.entries) {
        final String h = accountStateHash(u.value);
        final _Unit? old = known[u.key];
        if (old != null && old.held) {
          // Still not kept here: stays held (never this device's default).
          continue;
        }
        if (old == null || old.deleted || old.hash != h) {
          if (old != null && !old.deleted) {
            _superseded = true;
          }
          final int c = ++_lamport;
          known[u.key] = _Unit(c, channel.device, h);
          delta[u.key] = <String, Object?>{
            'c': c,
            'w': channel.device,
            'v': u.value,
          };
        }
      }
      for (final MapEntry<String, _Unit> u in known.entries.toList()) {
        if (!u.value.deleted && !u.value.held && !units.containsKey(u.key)) {
          final int c = ++_lamport;
          known[u.key] = _Unit(
            c,
            channel.device,
            '',
            deleted: true,
            at: _now(),
          );
          _superseded = true;
          delta[u.key] = <String, Object?>{'c': c, 'w': channel.device, 'x': 1};
        }
      }
      if (delta.isEmpty) {
        continue;
      }
      dirty = true;
      if (!channel.hasOtherDevices || !await _publishUnits(d.id, delta)) {
        _unsent.add(d.id);
      } else {
        published++;
      }
    }
    if (_unsent.isNotEmpty && channel.hasOtherDevices) {
      await _sendAll(only: _unsent.toSet());
      dirty = true;
    }
    if (dirty) {
      await _save();
    }
    await _rebase();
  }

  /// Every unit of [d] as it is now, to write again: values (held ones
  /// too) and the deletions of the last [tombstoneLife]; for an
  /// [AccountSyncMarkedDeletions] domain also the older deletions, the
  /// newest first, within [kAccountSyncMarkerBytes].
  Map<String, Object?> _allUnits(
    AccountSyncDomain d,
    Map<String, Object?> state,
  ) {
    final Map<String, _Unit> known = _units[d.id] ?? const <String, _Unit>{};
    final Map<String, Object?> units = flattenAccountState(
      state,
      whole: d.wholeKeys,
    );
    final int now = _now();
    final Map<String, Object?> all = <String, Object?>{};
    final List<MapEntry<String, _Unit>> older = <MapEntry<String, _Unit>>[];
    for (final MapEntry<String, _Unit> u in known.entries) {
      final _Unit unit = u.value;
      if (unit.deleted) {
        if (unit.at == 0 || now - unit.at < tombstoneLife.inMilliseconds) {
          all[u.key] = _marker(unit);
        } else if (d is AccountSyncMarkedDeletions) {
          older.add(u);
        }
      } else if (unit.held && _heldOf(d.id).containsKey(u.key)) {
        all[u.key] = <String, Object?>{
          'c': unit.clock,
          'w': unit.writer,
          'v': _heldOf(d.id)[u.key],
        };
      } else if (units.containsKey(u.key)) {
        all[u.key] = <String, Object?>{
          'c': unit.clock,
          'w': unit.writer,
          'v': units[u.key],
        };
      }
    }
    // Newest first by their clocks, which every device orders the same
    // way (a re-creation after a deletion has a higher one, so it is never
    // undone by this); past the bound the oldest stay out.
    older.sort((MapEntry<String, _Unit> a, MapEntry<String, _Unit> b) {
      if (a.value.clock != b.value.clock) {
        return b.value.clock.compareTo(a.value.clock);
      }
      final int byWriter = b.value.writer.compareTo(a.value.writer);
      return byWriter != 0 ? byWriter : a.key.compareTo(b.key);
    });
    int bytes = 0;
    for (final MapEntry<String, _Unit> u in older) {
      final Map<String, Object?> marker = _marker(u.value);
      bytes += utf8.encode(jsonEncode(<String, Object?>{u.key: marker})).length;
      if (bytes > kAccountSyncMarkerBytes) {
        break;
      }
      all[u.key] = marker;
    }
    return all;
  }

  /// A deletion as it travels.
  static Map<String, Object?> _marker(_Unit unit) => <String, Object?>{
    'c': unit.clock,
    'w': unit.writer,
    'x': 1,
  };

  /// Starts this device's log over ([kAccountSyncRebaseEvery]) when it
  /// holds values no longer current: a checkpoint, every state as it is
  /// now after it, then everything before it dropped. Nothing is dropped
  /// unless all was written again (a device that has not seen a value
  /// finds it after the checkpoint), nor while a state cannot be read.
  Future<void> _rebase() async {
    final AccountSyncChannel channel = this.channel;
    if (channel is! AccountSyncLog ||
        _locked ||
        !_superseded ||
        _now() - _rebasedAt < rebaseEvery.inMilliseconds) {
      return;
    }
    final AccountSyncLog log = channel as AccountSyncLog;
    final Map<String, Map<String, Object?>> states =
        <String, Map<String, Object?>>{};
    for (final AccountSyncDomain d in _domains.values) {
      final Map<String, Object?>? state = await d.read();
      if (state == null) {
        return;
      }
      states[d.id] = state;
    }
    final Object? start = await log.startOver();
    if (start == null) {
      return;
    }
    bool all = true;
    if (channel.hasOtherDevices) {
      for (final AccountSyncDomain d in _domains.values) {
        final Map<String, Object?> units = _allUnits(d, states[d.id]!);
        if (units.isNotEmpty && !await _publishUnits(d.id, units)) {
          all = false;
        }
      }
    }
    if (!all) {
      // Tried again at the next look: the old changes stay meanwhile.
      return;
    }
    await log.dropBefore(start);
    if (channel.hasOtherDevices) {
      _unsent.clear();
    }
    _rebasedAt = _now();
    _superseded = false;
    rebased++;
    await _save();
  }

  /// Zen is locked: the changes not taken yet (they wait for the states to
  /// open) and every change the channel opened are let go, so no plain copy
  /// of one (a password) stays in memory; they are taken again at [unlock].
  void lock() {
    _locked = true;
    if (_deferred.isNotEmpty) {
      _deferred.clear();
      _retake = true;
    }
    final AccountSyncChannel channel = this.channel;
    if (channel is AccountSyncLog) {
      (channel as AccountSyncLog).close();
    }
  }

  /// Zen is unlocked: what was let go at [lock] is opened and taken again.
  void unlock() {
    if (!_locked) {
      return;
    }
    _locked = false;
    _enqueue(() async {
      final AccountSyncChannel channel = this.channel;
      if (channel is AccountSyncLog) {
        // The changes of the other devices come again through incoming.
        await (channel as AccountSyncLog).reopen();
      } else if (_retake) {
        for (final Map<String, dynamic> body in channel.existing()) {
          await _take(body);
        }
      }
      _retake = false;
      await _scan();
    });
  }

  /// Sends every unit of the states (a device was linked): the others take
  /// only what is newer than theirs.
  Future<void> _sendAll({Set<String>? only}) async {
    if (!channel.hasOtherDevices) {
      return;
    }
    for (final AccountSyncDomain d in _domains.values) {
      if (only != null && !only.contains(d.id)) {
        continue;
      }
      final Map<String, Object?>? state = await d.read();
      final Map<String, _Unit>? known = _units[d.id];
      if (state == null || known == null || known.isEmpty) {
        continue;
      }
      final Map<String, Object?> all = _allUnits(d, state);
      if (await _publishUnits(d.id, all)) {
        published++;
        _unsent.remove(d.id);
      }
    }
    await _save();
  }

  /// Sends [units] of the state [domain], in as many changes as it takes
  /// for each to stay well under the largest entry the account's log
  /// carries (`kMaxEntryBytes`, with sealing and signatures on top): a
  /// large state (every password of the vault, sent to a newly linked
  /// device) would otherwise be one entry the other devices refuse, sent
  /// again and refused for ever. Each part is a change on its own: a
  /// device takes it as it comes, an older build too. False when a part
  /// did not go out (it is all sent again later).
  Future<bool> _publishUnits(String domain, Map<String, Object?> units) async {
    final List<Map<String, Object?>> parts = <Map<String, Object?>>[];
    Map<String, Object?> part = <String, Object?>{};
    int size = 0;
    for (final MapEntry<String, Object?> u in units.entries) {
      final int bytes = utf8
          .encode(jsonEncode(<String, Object?>{u.key: u.value}))
          .length;
      if (part.isNotEmpty && size + bytes > kAccountSyncPartBytes) {
        parts.add(part);
        part = <String, Object?>{};
        size = 0;
      }
      part[u.key] = u.value;
      size += bytes;
    }
    if (part.isNotEmpty || parts.isEmpty) {
      parts.add(part);
    }
    bool all = true;
    for (final Map<String, Object?> p in parts) {
      try {
        if (!await channel.publish(<String, dynamic>{'d': domain, 'u': p})) {
          all = false;
        }
      } on Object catch (error) {
        // One part refused does not stop the others, nor the other states.
        logZenWarning('Account state $domain not sent: ${error.runtimeType}');
        all = false;
      }
    }
    return all;
  }

  /// Takes a change another device sent.
  Future<void> _take(Map<String, dynamic> body) async {
    final Object? id = body['d'];
    final Object? u = body['u'];
    final AccountSyncDomain? d = id is String ? _domains[id] : null;
    if (d == null || u is! Map) {
      return;
    }
    final Map<String, Object?>? current = await d.read();
    if (current == null) {
      if (_locked) {
        // Not kept in memory while locked: taken again at the unlock.
        _retake = true;
      } else {
        _deferred.add(body);
      }
      return;
    }
    final Map<String, Object?> units = flattenAccountState(
      current,
      whole: d.wholeKeys,
    );
    final Map<String, _Unit> known = _units[d.id] ??= <String, _Unit>{};
    final Map<String, _Unit> before = Map<String, _Unit>.of(known);
    final Set<String> taken = <String>{};
    for (final MapEntry<Object?, Object?> e in u.entries) {
      final Object? key = e.key;
      final Object? r = e.value;
      if (key is! String || r is! Map) {
        continue;
      }
      final Object? c = r['c'];
      final Object? w = r['w'];
      if (c is! int || w is! String) {
        continue;
      }
      if (c > _lamport) {
        _lamport = c;
      }
      final _Unit? old = known[key];
      if (old != null && !old.loses(c, w)) {
        continue;
      }
      if (old != null && !old.deleted) {
        _superseded = true;
      }
      if (r['x'] == 1) {
        units.remove(key);
        known[key] = _Unit(c, w, '', deleted: true, at: _now());
      } else {
        units[key] = r['v'];
        known[key] = _Unit(c, w, accountStateHash(r['v']));
      }
      taken.add(key);
    }
    if (taken.isEmpty) {
      await _save();
      return;
    }
    try {
      await d.write(unflattenAccountState(units, current));
    } on Object catch (error) {
      // Not now (the file of a photo has not come yet…): again later.
      logZenWarning('Account state ${d.id}: $error');
      _units[d.id] = before;
      _deferred.add(body);
      return;
    }
    // Remembered as written here, so it is not taken for a change of ours.
    final Map<String, Object?>? after = await d.read();
    if (after != null) {
      final Map<String, Object?> now = flattenAccountState(
        after,
        whole: d.wholeKeys,
      );
      for (final String key in taken) {
        final _Unit got = known[key]!;
        if (now.containsKey(key)) {
          known[key] = _Unit(got.clock, got.writer, accountStateHash(now[key]));
          _heldOf(d.id).remove(key);
        } else if (got.deleted || d is AccountSyncPruning) {
          // Deleted, or dropped by the domain on purpose (a password
          // version a deletion saw): a deletion here.
          known[key] = _Unit(
            got.clock,
            got.writer,
            '',
            deleted: true,
            at: got.deleted ? got.at : _now(),
          );
          _heldOf(d.id).remove(key);
          if (!got.deleted) {
            _superseded = true;
          }
        } else {
          // Not kept by this build (a newer build's field): held with its
          // value, not deleted — after an update it is written in first
          // instead of this device's default going out as a change.
          known[key] = _Unit(got.clock, got.writer, got.hash, held: true);
          _heldOf(d.id)[key] = units[key];
        }
      }
    }
    await _save();
  }

  /// Writes the held units [d] now keeps (this build was updated and
  /// understands them) into it, with their values, before anything of
  /// this device is sent. Returns whether any unit changed.
  Future<bool> _writeHeld(
    AccountSyncDomain d,
    Map<String, Object?> state,
    Map<String, Object?> units,
    Map<String, _Unit> known,
  ) async {
    final Map<String, Object?> held = _heldOf(d.id);
    final List<String> ready = <String>[
      for (final String key in held.keys)
        if (units.containsKey(key) && (known[key]?.held ?? false)) key,
    ];
    if (ready.isEmpty) {
      return false;
    }
    final Map<String, Object?> merged = Map<String, Object?>.of(units);
    for (final String key in ready) {
      merged[key] = held[key];
    }
    try {
      await d.write(unflattenAccountState(merged, state));
    } on Object catch (error) {
      logZenWarning('Account state ${d.id}: $error');
      return false;
    }
    final Map<String, Object?>? after = await d.read();
    if (after == null) {
      return false;
    }
    final Map<String, Object?> now = flattenAccountState(
      after,
      whole: d.wholeKeys,
    );
    for (final String key in ready) {
      final _Unit got = known[key]!;
      if (now.containsKey(key)) {
        known[key] = _Unit(got.clock, got.writer, accountStateHash(now[key]));
        held.remove(key);
      }
    }
    units
      ..clear()
      ..addAll(now);
    return true;
  }
}
