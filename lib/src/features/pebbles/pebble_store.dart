import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/core/logging/zen_log.dart';
import 'package:zen/src/features/pebbles/pebble_card.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';

/// What a pebble is to this device: one this account made, one it
/// collected, one it keeps for its author (a keeper). One pebble can be
/// several of these.
enum PebbleRole { created, collected, kept }

/// The longest note a finder writes about where they found a pebble.
const int kPebbleFindNoteMaxChars = 140;

/// At most this many pebbles are collected; this many are kept for others.
const int kPebbleMaxCollected = 500;
const int kPebbleMaxKept = 200;

/// At most this many requests to keep a pebble wait for an answer.
const int kPebbleMaxKeepRequests = 20;

/// One pebble on this device.
@immutable
final class PebbleEntry {
  const PebbleEntry({
    required this.card,
    required this.roles,
    required this.addedAtMillis,
    this.foundAtMillis,
    this.findNote = '',
    this.hasDesign = false,
    this.keepers,
    this.foundSent = false,
    this.keptFrom,
    this.madeHere = false,
    this.hinted = const <String>[],
  });

  final PebbleCard card;
  final Set<PebbleRole> roles;

  /// When it came to this device (made, collected, accepted to keep).
  final int addedAtMillis;

  /// When it was found (collected ones).
  final int? foundAtMillis;

  /// The finder's own note about where they found it (collected ones).
  final String findNote;

  /// Whether the full design is here (otherwise the card's preview look).
  final bool hasDesign;

  /// The newest keeper list of the author known here.
  final PebbleKeeperList? keepers;

  /// Whether the "znaleziono" note reached the author.
  final bool foundSent;

  /// The author's device that asked this one to keep the pebble.
  final String? keptFrom;

  /// Made on this device (not one of the account's others): this one asks
  /// the keepers and signs their list.
  final bool madeHere;

  /// The keepers the QR code it was collected from named (pebble_link.dart):
  /// asked for the design right after the author's devices.
  final List<String> hinted;

  PebbleId get id => card.id;

  bool get created => roles.contains(PebbleRole.created);
  bool get collected => roles.contains(PebbleRole.collected);
  bool get kept => roles.contains(PebbleRole.kept);

  /// Whether the author took it back (keepers stop offering it).
  bool get retired => keepers?.retired ?? false;

  PebbleEntry copyWith({
    PebbleCard? card,
    Set<PebbleRole>? roles,
    int? foundAtMillis,
    String? findNote,
    bool? hasDesign,
    PebbleKeeperList? keepers,
    bool? foundSent,
    String? keptFrom,
    List<String>? hinted,
  }) => PebbleEntry(
    card: card ?? this.card,
    roles: roles ?? this.roles,
    addedAtMillis: addedAtMillis,
    foundAtMillis: foundAtMillis ?? this.foundAtMillis,
    findNote: findNote ?? this.findNote,
    hasDesign: hasDesign ?? this.hasDesign,
    keepers: keepers ?? this.keepers,
    foundSent: foundSent ?? this.foundSent,
    keptFrom: keptFrom ?? this.keptFrom,
    madeHere: madeHere,
    hinted: hinted ?? this.hinted,
  );

  Map<String, dynamic> toJson() => <String, dynamic>{
    'c': card.text,
    'r': <String>[for (final PebbleRole r in roles) r.name],
    'at': addedAtMillis,
    'f': ?foundAtMillis,
    if (findNote.isNotEmpty) 'n': findNote,
    if (hasDesign) 'd': true,
    if (keepers != null) 'k': keepers!.toJson(),
    if (foundSent) 'fs': true,
    'o': ?keptFrom,
    if (madeHere) 'm': true,
    if (hinted.isNotEmpty) 'h': hinted,
  };

  static PebbleEntry? fromJson(Object? json) {
    if (json is! Map) {
      return null;
    }
    final Object? c = json['c'];
    final PebbleCard? card = c is String ? PebbleCard.fromText(c) : null;
    final Object? r = json['r'];
    final Object? at = json['at'];
    if (card == null || r is! List || at is! int) {
      return null;
    }
    final Set<PebbleRole> roles = <PebbleRole>{
      for (final PebbleRole role in PebbleRole.values)
        if (r.contains(role.name)) role,
    };
    if (roles.isEmpty) {
      return null;
    }
    final Object? n = json['n'];
    final PebbleKeeperList? keepers = PebbleKeeperList.fromJson(json['k']);
    return PebbleEntry(
      card: card,
      roles: roles,
      addedAtMillis: at,
      foundAtMillis: json['f'] is int ? json['f'] as int : null,
      findNote: n is String ? clipFindNote(n) : '',
      hasDesign: json['d'] == true,
      keepers: keepers != null && keepers.id == card.id ? keepers : null,
      foundSent: json['fs'] == true,
      keptFrom: json['o'] is String ? json['o'] as String : null,
      madeHere: json['m'] == true,
      hinted: json['h'] is List
          ? <String>[
              for (final Object? a in json['h'] as List)
                if (a is String) a,
            ].take(kPebbleQrKeepersHinted).toList()
          : const <String>[],
    );
  }
}

/// The most keepers a collected pebble keeps from its QR code.
const int kPebbleQrKeepersHinted = 3;

/// [note] trimmed to [kPebbleFindNoteMaxChars] characters.
String clipFindNote(String note) {
  final List<int> runes = note.trim().runes.toList();
  return runes.length <= kPebbleFindNoteMaxChars
      ? note.trim()
      : String.fromCharCodes(runes.take(kPebbleFindNoteMaxChars));
}

/// Where one keeper the author asked stands.
enum PebbleKeeperState {
  /// Asked, no answer yet.
  asked,

  /// Agreed: keeps and serves the pebble.
  accepted,

  /// Said no.
  declined,

  /// Kept it, then gave the role up.
  resigned,

  /// Never answered in time.
  silent,
}

/// One keeper of one of this account's pebbles, as the author sees it.
@immutable
final class PebbleKeeperStatus {
  const PebbleKeeperStatus({
    required this.address,
    required this.state,
    required this.atMillis,
  });

  final String address;
  final PebbleKeeperState state;

  /// When it was asked or answered last.
  final int atMillis;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'a': address,
    's': state.name,
    'at': atMillis,
  };

  static PebbleKeeperStatus? fromJson(Object? json) {
    if (json is! Map || json['a'] is! String || json['at'] is! int) {
      return null;
    }
    for (final PebbleKeeperState s in PebbleKeeperState.values) {
      if (s.name == json['s']) {
        return PebbleKeeperStatus(
          address: json['a'] as String,
          state: s,
          atMillis: json['at'] as int,
        );
      }
    }
    return null;
  }
}

/// A friend asks this device to keep one of their pebbles.
@immutable
final class PebbleKeepRequest {
  const PebbleKeepRequest({
    required this.card,
    required this.from,
    required this.sizeBytes,
    required this.askedAtMillis,
  });

  final PebbleCard card;

  /// The author's device that asked.
  final String from;

  /// How large the full design is.
  final int sizeBytes;
  final int askedAtMillis;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'c': card.text,
    'from': from,
    'n': sizeBytes,
    'at': askedAtMillis,
  };

  static PebbleKeepRequest? fromJson(Object? json) {
    if (json is! Map) {
      return null;
    }
    final Object? c = json['c'];
    final PebbleCard? card = c is String ? PebbleCard.fromText(c) : null;
    if (card == null ||
        json['from'] is! String ||
        json['n'] is! int ||
        json['at'] is! int) {
      return null;
    }
    return PebbleKeepRequest(
      card: card,
      from: json['from'] as String,
      sizeBytes: json['n'] as int,
      askedAtMillis: json['at'] as int,
    );
  }
}

/// The pebbles on this device, kept in the app's encrypted store ([disk]):
/// the ones made here, the collected ones (with the finder's note and the
/// date), the ones kept for others; their full designs; what the author
/// knows about each own pebble's keepers and finders; requests to keep a
/// pebble that wait for an answer.
final class PebbleStore extends ChangeNotifier {
  PebbleStore(this.disk, {int Function()? clock})
    : _clock = clock ?? (() => DateTime.now().millisecondsSinceEpoch);

  final LedgerDisk disk;
  final int Function() _clock;

  static const String _indexKey = 'pebbles/index';
  static String _designKey(PebbleId id) => 'pebbles/design/${id.text}';

  final Map<PebbleId, PebbleEntry> _entries = <PebbleId, PebbleEntry>{};
  final Map<PebbleId, Map<String, PebbleKeeperStatus>> _keepers =
      <PebbleId, Map<String, PebbleKeeperStatus>>{};
  final Map<PebbleId, Set<String>> _finders = <PebbleId, Set<String>>{};
  final Map<PebbleId, PebbleKeepRequest> _requests =
      <PebbleId, PebbleKeepRequest>{};

  /// Pebbles removed here (the account's other devices drop them too).
  final Map<PebbleId, int> _removed = <PebbleId, int>{};

  Future<void>? _loaded;
  Future<void> _writing = Future<void>.value();

  int get now => _clock();

  Future<void> load() => _loaded ??= _load();

  Future<void> _load() async {
    final Uint8List? raw = await disk.read(_indexKey);
    if (raw == null) {
      return;
    }
    Object? json;
    try {
      json = jsonDecode(utf8.decode(raw));
    } on FormatException {
      logZenWarning('The pebbles index is damaged; it starts afresh.');
      return;
    }
    if (json is! Map) {
      return;
    }
    for (final Object? e in _list(json['e'])) {
      final PebbleEntry? entry = PebbleEntry.fromJson(e);
      if (entry != null) {
        _entries[entry.id] = entry;
      }
    }
    final Object? keepers = json['kp'];
    if (keepers is Map) {
      for (final MapEntry<Object?, Object?> e in keepers.entries) {
        final PebbleId? id = PebbleId.parse(e.key);
        if (id == null) {
          continue;
        }
        _keepers[id] = <String, PebbleKeeperStatus>{
          for (final Object? s in _list(e.value))
            if (PebbleKeeperStatus.fromJson(s) case final PebbleKeeperStatus k)
              k.address: k,
        };
      }
    }
    final Object? finders = json['fd'];
    if (finders is Map) {
      for (final MapEntry<Object?, Object?> e in finders.entries) {
        final PebbleId? id = PebbleId.parse(e.key);
        if (id != null) {
          _finders[id] = _list(e.value).whereType<String>().toSet();
        }
      }
    }
    for (final Object? r in _list(json['rq'])) {
      final PebbleKeepRequest? request = PebbleKeepRequest.fromJson(r);
      if (request != null) {
        _requests[request.card.id] = request;
      }
    }
    final Object? removed = json['x'];
    if (removed is Map) {
      for (final MapEntry<Object?, Object?> e in removed.entries) {
        final PebbleId? id = PebbleId.parse(e.key);
        if (id != null && e.value is int) {
          _removed[id] = e.value! as int;
        }
      }
    }
  }

  static List<Object?> _list(Object? v) => v is List ? v : const <Object?>[];

  Future<void> _save() {
    final Uint8List bytes = Uint8List.fromList(
      utf8.encode(
        jsonEncode(<String, dynamic>{
          'e': <Map<String, dynamic>>[
            for (final PebbleEntry e in _entries.values) e.toJson(),
          ],
          'kp': <String, dynamic>{
            for (final MapEntry<PebbleId, Map<String, PebbleKeeperStatus>> e
                in _keepers.entries)
              e.key.text: <Map<String, dynamic>>[
                for (final PebbleKeeperStatus s in e.value.values) s.toJson(),
              ],
          },
          'fd': <String, dynamic>{
            for (final MapEntry<PebbleId, Set<String>> e in _finders.entries)
              e.key.text: e.value.toList(),
          },
          'rq': <Map<String, dynamic>>[
            for (final PebbleKeepRequest r in _requests.values) r.toJson(),
          ],
          'x': <String, int>{
            for (final MapEntry<PebbleId, int> e in _removed.entries)
              e.key.text: e.value,
          },
        }),
      ),
    );
    notifyListeners();
    return _writing = _writing.then((_) => disk.write(_indexKey, bytes));
  }

  // ---- reading ----

  PebbleEntry? entry(PebbleId id) => _entries[id];

  /// Every pebble here, newest first.
  List<PebbleEntry> get entries =>
      _entries.values.toList()..sort((PebbleEntry a, PebbleEntry b) {
        final int byTime = b.addedAtMillis.compareTo(a.addedAtMillis);
        return byTime != 0 ? byTime : a.id.text.compareTo(b.id.text);
      });

  List<PebbleEntry> get created =>
      entries.where((PebbleEntry e) => e.created).toList();

  List<PebbleEntry> get collected =>
      entries.where((PebbleEntry e) => e.collected).toList();

  List<PebbleEntry> get kept =>
      entries.where((PebbleEntry e) => e.kept).toList();

  /// Pebbles collected or kept here whose full design has not come yet.
  List<PebbleEntry> get lackingDesign =>
      entries.where((PebbleEntry e) => !e.hasDesign).toList();

  Future<Uint8List?> design(PebbleId id) async {
    if (!(_entries[id]?.hasDesign ?? false)) {
      return null;
    }
    final Uint8List? raw = await disk.read(_designKey(id));
    final PebbleEntry? e = _entries[id];
    if (raw == null || e == null || !e.card.matchesDesign(raw)) {
      return null;
    }
    return raw;
  }

  /// The keepers the author asked, for one of this account's pebbles.
  List<PebbleKeeperStatus> keepersOf(PebbleId id) =>
      (_keepers[id]?.values.toList() ?? <PebbleKeeperStatus>[])..sort(
        (PebbleKeeperStatus a, PebbleKeeperStatus b) =>
            a.address.compareTo(b.address),
      );

  PebbleKeeperStatus? keeperStatus(PebbleId id, String address) =>
      _keepers[id]?[PeerShareCodec.normalizeAddress(address)];

  /// How many keepers agreed (one of this account's pebbles).
  int acceptedKeepers(PebbleId id) => keepersOf(id)
      .where((PebbleKeeperStatus k) => k.state == PebbleKeeperState.accepted)
      .length;

  /// How many people told the author they found [id].
  int finderCount(PebbleId id) => _finders[id]?.length ?? 0;

  List<PebbleKeepRequest> get keepRequests => _requests.values.toList()
    ..sort(
      (PebbleKeepRequest a, PebbleKeepRequest b) =>
          a.askedAtMillis.compareTo(b.askedAtMillis),
    );

  PebbleKeepRequest? keepRequest(PebbleId id) => _requests[id];

  /// Pebbles removed here, with when (for the account's other devices).
  Map<PebbleId, int> get removed => Map<PebbleId, int>.unmodifiable(_removed);

  // ---- changing ----

  /// Saves a pebble this account made, with its design.
  Future<PebbleEntry> addCreated(PebbleCard card, Uint8List design) async {
    await load();
    await disk.write(_designKey(card.id), design);
    final PebbleEntry? had = _entries[card.id];
    final PebbleEntry e = PebbleEntry(
      card: card,
      roles: <PebbleRole>{...?had?.roles, PebbleRole.created},
      addedAtMillis: had?.addedAtMillis ?? now,
      foundAtMillis: had?.foundAtMillis,
      findNote: had?.findNote ?? '',
      hasDesign: true,
      keepers: had?.keepers,
      madeHere: true,
    );
    _entries[card.id] = e;
    _removed.remove(card.id);
    await _save();
    return e;
  }

  /// A pebble the account made on another of its devices (its design
  /// follows from there).
  Future<void> addFromOtherDevice(PebbleCard card) async {
    await load();
    final PebbleEntry? had = _entries[card.id];
    if (had != null && had.created) {
      return;
    }
    _entries[card.id] =
        (had ??
                PebbleEntry(
                  card: card,
                  roles: const <PebbleRole>{},
                  addedAtMillis: now,
                ))
            .copyWith(roles: <PebbleRole>{...?had?.roles, PebbleRole.created});
    await _save();
  }

  /// Saves a collected pebble from its [card] at once (the design comes
  /// later, [putDesign]). Collecting it again keeps the first find.
  /// Returns `null` when the collection is full.
  Future<PebbleEntry?> addCollected(
    PebbleCard card, {
    String findNote = '',
    int? foundAtMillis,
    List<String> hinted = const <String>[],
  }) async {
    await load();
    final PebbleEntry? had = _entries[card.id];
    if (had != null && had.collected) {
      return had;
    }
    if (had == null && collected.length >= kPebbleMaxCollected) {
      return null;
    }
    final PebbleEntry e =
        (had ??
                PebbleEntry(
                  card: card,
                  roles: const <PebbleRole>{},
                  addedAtMillis: now,
                ))
            .copyWith(
              roles: <PebbleRole>{...?had?.roles, PebbleRole.collected},
              foundAtMillis: foundAtMillis ?? now,
              findNote: clipFindNote(findNote),
              hinted: hinted.isEmpty
                  ? null
                  : hinted.take(kPebbleQrKeepersHinted).toList(),
            );
    _entries[card.id] = e;
    _removed.remove(card.id);
    await _save();
    return e;
  }

  /// Takes a pebble to keep for its author ([design] checked by the
  /// caller). Returns false when this device keeps too many already.
  Future<bool> addKept(PebbleCard card, {String? from}) async {
    await load();
    final PebbleEntry? had = _entries[card.id];
    if (had == null && kept.length >= kPebbleMaxKept) {
      return false;
    }
    _entries[card.id] =
        (had ??
                PebbleEntry(
                  card: card,
                  roles: const <PebbleRole>{},
                  addedAtMillis: now,
                ))
            .copyWith(
              roles: <PebbleRole>{...?had?.roles, PebbleRole.kept},
              keptFrom: from == null
                  ? null
                  : PeerShareCodec.normalizeAddress(from),
            );
    await _save();
    return true;
  }

  /// The full card [full] of a pebble collected from its QR card takes
  /// the QR card's place (checked by the caller: the same pebble, the
  /// author's signature); false when the pebble is not here.
  Future<bool> replaceCard(PebbleCard full) async {
    await load();
    final PebbleEntry? e = _entries[full.id];
    if (e == null || !full.isFull || !e.card.isSamePebble(full)) {
      return false;
    }
    _entries[full.id] = e.copyWith(card: full);
    await _save();
    return true;
  }

  /// The full design of a pebble here arrived; false when it is not the
  /// design of that card (or the pebble is not here).
  Future<bool> putDesign(PebbleId id, Uint8List design) async {
    await load();
    final PebbleEntry? e = _entries[id];
    if (e == null || !e.card.matchesDesign(design)) {
      return false;
    }
    if (e.hasDesign) {
      return true;
    }
    await disk.write(_designKey(id), design);
    _entries[id] = e.copyWith(hasDesign: true);
    await _save();
    return true;
  }

  /// A newer checked keeper list for [id]; false when not newer.
  Future<bool> putKeeperList(PebbleKeeperList list) async {
    await load();
    final PebbleEntry? e = _entries[list.id];
    if (e == null || (e.keepers?.version ?? -1) >= list.version) {
      return false;
    }
    _entries[list.id] = e.copyWith(keepers: list);
    await _save();
    return true;
  }

  Future<void> setFindNote(PebbleId id, String note) async {
    await load();
    final PebbleEntry? e = _entries[id];
    if (e == null) {
      return;
    }
    _entries[id] = e.copyWith(findNote: clipFindNote(note));
    await _save();
  }

  Future<void> markFoundSent(PebbleId id) async {
    final PebbleEntry? e = _entries[id];
    if (e == null || e.foundSent) {
      return;
    }
    _entries[id] = e.copyWith(foundSent: true);
    await _save();
  }

  /// Drops [role] from a pebble; the pebble goes when nothing is left (its
  /// design too). Removing a collected or made one is remembered for the
  /// account's other devices.
  Future<void> drop(PebbleId id, PebbleRole role) async {
    await load();
    final PebbleEntry? e = _entries[id];
    if (e == null || !e.roles.contains(role)) {
      return;
    }
    final Set<PebbleRole> left = <PebbleRole>{...e.roles}..remove(role);
    if (role != PebbleRole.kept) {
      _removed[id] = now;
      while (_removed.length > 200) {
        _removed.remove(_removed.keys.first);
      }
    }
    if (left.isEmpty) {
      _entries.remove(id);
      _keepers.remove(id);
      _finders.remove(id);
      await disk.delete(_designKey(id));
    } else {
      _entries[id] = e.copyWith(roles: left);
    }
    await _save();
  }

  /// Sets where keeper [address] stands for one of this account's pebbles.
  Future<void> setKeeper(
    PebbleId id,
    String address,
    PebbleKeeperState state,
  ) async {
    await load();
    final String a = PeerShareCodec.normalizeAddress(address);
    (_keepers[id] ??= <String, PebbleKeeperStatus>{})[a] = PebbleKeeperStatus(
      address: a,
      state: state,
      atMillis: now,
    );
    await _save();
  }

  /// A finder's account told the author they found [id]; false when known.
  Future<bool> addFinder(PebbleId id, String account) async {
    await load();
    final Set<String> set = _finders[id] ??= <String>{};
    if (set.length >= 100000 || !set.add(account)) {
      return false;
    }
    await _save();
    return true;
  }

  /// A friend's request to keep a pebble; false when there are too many.
  Future<bool> addKeepRequest(PebbleKeepRequest request) async {
    await load();
    if (!_requests.containsKey(request.card.id) &&
        _requests.length >= kPebbleMaxKeepRequests) {
      return false;
    }
    _requests[request.card.id] = request;
    await _save();
    return true;
  }

  Future<void> removeKeepRequest(PebbleId id) async {
    await load();
    if (_requests.remove(id) != null) {
      await _save();
    }
  }

  /// The pebbles removed on another device of the account: dropped here
  /// too (made and collected; kept ones stay).
  Future<void> applyRemovals(Map<PebbleId, int> removed) async {
    await load();
    bool changed = false;
    for (final MapEntry<PebbleId, int> r in removed.entries) {
      final PebbleEntry? e = _entries[r.key];
      if (e != null && e.addedAtMillis <= r.value) {
        final Set<PebbleRole> left = <PebbleRole>{...e.roles}
          ..remove(PebbleRole.created)
          ..remove(PebbleRole.collected);
        if (left.isEmpty) {
          _entries.remove(r.key);
          await disk.delete(_designKey(r.key));
        } else {
          _entries[r.key] = e.copyWith(roles: left);
        }
        changed = true;
      }
      if ((_removed[r.key] ?? 0) < r.value) {
        _removed[r.key] = r.value;
        changed = true;
      }
    }
    if (changed) {
      await _save();
    }
  }

  /// Waits for the writes so far (tests).
  Future<void> get idle => _writing;

  /// A short text of the store for logs.
  @override
  String toString() =>
      'PebbleStore(${_entries.length} pebbles, ${_requests.length} requests)';
}
