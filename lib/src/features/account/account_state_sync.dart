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
  });

  final int clock;
  final String writer;
  final String hash;
  final bool deleted;

  /// Sent by another device, but this build's domain does not keep it (a
  /// field a newer build added): kept aside with its value
  /// ([AccountStateSync]'s held values), never taken for a deletion, and
  /// written into the domain first once an update makes it understood.
  final bool held;

  List<Object> toJson() => <Object>[
    clock,
    writer,
    hash,
    if (deleted) 1 else if (held) 2,
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
  }) : _domains = <String, AccountSyncDomain>{
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

  static const String _stateKey = 'account/sync/state';

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
          known[u.key] = _Unit(c, channel.device, '', deleted: true);
          delta[u.key] = <String, Object?>{'c': c, 'w': channel.device, 'x': 1};
        }
      }
      if (delta.isEmpty) {
        continue;
      }
      dirty = true;
      if (!channel.hasOtherDevices ||
          !await channel.publish(<String, dynamic>{'d': d.id, 'u': delta})) {
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
      final Map<String, Object?> units = flattenAccountState(
        state,
        whole: d.wholeKeys,
      );
      final Map<String, Object?> all = <String, Object?>{
        for (final MapEntry<String, _Unit> u in known.entries)
          if (u.value.deleted)
            u.key: <String, Object?>{
              'c': u.value.clock,
              'w': u.value.writer,
              'x': 1,
            }
          else if (u.value.held && _heldOf(d.id).containsKey(u.key))
            u.key: <String, Object?>{
              'c': u.value.clock,
              'w': u.value.writer,
              'v': _heldOf(d.id)[u.key],
            }
          else if (units.containsKey(u.key))
            u.key: <String, Object?>{
              'c': u.value.clock,
              'w': u.value.writer,
              'v': units[u.key],
            },
      };
      if (await channel.publish(<String, dynamic>{'d': d.id, 'u': all})) {
        published++;
        _unsent.remove(d.id);
      }
    }
    await _save();
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
      _deferred.add(body);
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
      if (r['x'] == 1) {
        units.remove(key);
        known[key] = _Unit(c, w, '', deleted: true);
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
        } else if (got.deleted) {
          known[key] = _Unit(got.clock, got.writer, '', deleted: true);
          _heldOf(d.id).remove(key);
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
