import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:zen/src/app/i18n/zen_format.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/core/ledger/ledger_codec.dart';
import 'package:zen/src/core/ledger/ledger_identity.dart';
import 'package:zen/src/core/logging/zen_log.dart';
import 'package:zen/src/features/meet/events/event_service.dart';
import 'package:zen/src/features/neighbors/flat_model.dart';
import 'package:zen/src/features/runtime/runtime_system_notifications.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';

abstract final class FlatTypes {
  /// "We scanned your door": our profile + the door secret.
  static const String hello = 'flat_hello';

  /// The door secret is no longer valid.
  static const String nope = 'flat_nope';

  /// A flat's current profile.
  static const String profile = 'flat_profile';

  /// "Send me your current profile" (a neighbour).
  static const String get = 'flat_get';
  static const String message = 'flat_msg';
  static const String signup = 'flat_signup';
  static const String signupAck = 'flat_signup_ok';

  /// Between housemates: the whole shared state of the flat.
  static const String house = 'flat_house';

  /// A new resident (holding the flat key) asks to be added.
  static const String join = 'flat_join';
  static const String leave = 'flat_leave';

  /// "We moved out of here": neighbours drop us; the flat is free for the
  /// new tenants' own profile.
  static const String moved = 'flat_moved';

  /// Between housemates: a vote to remove one phone that will not leave
  /// by itself (§18.1).
  static const String kick = 'flat_kick';

  /// Between housemates: the household's new key, without the removed
  /// phone (signed with the old key).
  static const String rekey = 'flat_rekey';

  /// To neighbours: "we have a new key" (signed with the old one).
  static const String newKey = 'flat_newkey';

  /// To a neighbour flat: one resident shows their own account ("Pokaż mój
  /// profil").
  static const String reveal = 'flat_reveal';

  static const Set<String> all = <String>{
    hello,
    nope,
    profile,
    get,
    message,
    signup,
    signupAck,
    house,
    join,
    leave,
    moved,
    kick,
    rekey,
    newKey,
    reveal,
  };
}

/// Wave payload version of a flat's invitation passed over Bluetooth.
const int kFlatWaveVersion = 2;

/// How long an invitation heard nearby is kept.
const Duration kNearbyInviteLife = Duration(days: 3);

/// What happened to a scanned door code.
enum FlatScan { sent, own, noFlat, alreadyNeighbor }

/// A resident key a neighbour has known at least this long counts when a
/// household announces a new key (§18.1). A key that showed up just before
/// could have been slipped in by the phone being removed.
const Duration kResidentKeyTrust = Duration(days: 1);

/// The warning when a neighbour household announced two different new keys.
String get kFlatKeyConflict =>
    t('Dwa różne nowe klucze mieszkania — zapytaj sąsiadów osobiście');

/// "Sekcja sąsiedzka" (§18): this phone's flat (shared by its residents,
/// who all hold the flat's key), the door QR, "Moi sąsiedzi", messages
/// between flats and sign-ups for invitations. Everything is signed with
/// the flats' keys; the residents' accounts never show.
final class NeighborsService extends ChangeNotifier {
  NeighborsService({
    required this.host,
    required this.disk,
    int Function()? now,
    Random? random,
    this.doorInbox,
  }) : _now = now ?? (() => DateTime.now().millisecondsSinceEpoch),
       _random = random ?? Random.secure();

  final EventHost host;
  final LedgerDisk disk;

  /// The address of the flat's door while it runs: a node of its own that
  /// this phone runs with [doorKey] (door_node.go in the bridge). The door
  /// QR carries it and never a resident's address (§18.2); without it there
  /// is no door QR.
  final String? Function()? doorInbox;
  final int Function() _now;
  final Random _random;
  static const String _key = 'neighbors/state';

  String? _seed;
  LedgerKeyPair? _pair;
  FlatProfile? _profile;
  String _door = '';
  int _doorAt = 0;

  /// This phone's door key (a 32-byte ed25519 seed, hex) and the door token
  /// it was made for: a new token ("Nowy kod", here or at a housemate's) is
  /// a new key, so an old sticker's address stops answering. Kept on this
  /// phone only: two phones never run one key on the mesh.
  String? _doorKey;
  String _doorKeyFor = '';
  bool shareWithScanners = false;
  int _shareAt = 0;

  /// Waiting for the housemate to answer our "flat_join".
  bool joining = false;

  final Map<String, NeighborFlat> _neighbors = <String, NeighborFlat>{};

  /// Neighbours removed (key → when), so housemates do not bring them back.
  final Map<String, int> _removed = <String, int>{};
  final Map<String, FlatMessage> _messages = <String, FlatMessage>{};
  final Map<String, int> _lastRead = <String, int>{};

  /// Our invitations' sign-ups: item id → flat key → sign-up.
  final Map<String, Map<String, FlatSignup>> _signups =
      <String, Map<String, FlatSignup>>{};

  /// Our sign-ups at neighbours ("flatKey|itemId" → count, 0 = refused or
  /// cancelled).
  final Map<String, FlatSignup> _mine = <String, FlatSignup>{};

  /// Doors scanned, waiting for the flat's answer (key → code).
  final Map<String, FlatDoorCode> pending = <String, FlatDoorCode>{};

  /// Doors that turned out stale (key → name).
  final Map<String, String> staleDoors = <String, String>{};
  final List<NearbyFlatInvite> _nearby = <NearbyFlatInvite>[];

  /// Residents' first names (phone address → name), shared between
  /// housemates only.
  final Map<String, String> _names = <String, String>{};

  /// Votes to remove a phone: target → the phones that voted.
  final Map<String, Set<String>> _kickVotes = <String, Set<String>>{};

  /// A new key that came before enough votes did (target → sender, body).
  final Map<String, (String, Map<String, dynamic>)> _pendingRekeys =
      <String, (String, Map<String, dynamic>)>{};

  /// Our household's key before the last change (a housemate who made a
  /// new key at the same time is reconciled through it).
  String? _oldKey;

  /// This phone's own key as a resident (Ed25519; not the flat's key, which
  /// every resident holds): votes to remove a phone and the "new key"
  /// notice for neighbours are signed with it, so a removed phone cannot
  /// speak for the others (§18.1).
  String? _residentSeed;
  LedgerKeyPair? _resident;

  /// The residents' own public keys (phone address → key), known to all
  /// housemates and sent to neighbours with the profile.
  final Map<String, String> _residentKeys = <String, String>{};

  /// Signed votes to remove a phone: target → voter → signature.
  final Map<String, Map<String, String>> _voteSigs =
      <String, Map<String, String>>{};

  /// Neighbour households that moved to a new key (old key → the switch).
  final Map<String, FlatKeySwitch> _switches = <String, FlatKeySwitch>{};

  /// Residents of neighbour flats who showed us their own account:
  /// flat key → reveals.
  final Map<String, List<FlatReveal>> _reveals = <String, List<FlatReveal>>{};

  /// Neighbour flats this phone showed its own account to.
  final Set<String> _revealedTo = <String>{};
  Future<void> _queue = Future<void>.value();

  String _n(String a) => PeerShareCodec.normalizeAddress(a);

  FlatProfile? get profile => _profile;
  bool get hasFlat => _profile != null && _pair != null;
  String get door => _door;

  /// The door QR, once the door runs ([doorInbox]); `null` before.
  FlatDoorCode? get doorCode {
    final FlatProfile? p = _profile;
    final String? inbox = doorInbox?.call();
    if (p == null || inbox == null || !isRoutablePeerAddress(inbox)) {
      return null;
    }
    return FlatDoorCode(
      key: p.key,
      door: _door,
      inbox: _n(inbox),
      name: p.label,
    );
  }

  /// The key this phone runs the flat's door with ([doorInbox]); `null`
  /// without a flat.
  String? get doorKey =>
      hasFlat && _door.isNotEmpty && _doorKeyFor == _door ? _doorKey : null;

  /// The door came up, went down or moved ([doorInbox]): the door QR
  /// changes with it.
  void doorInboxChanged() => notifyListeners();

  /// Makes [_doorKey] match the door token; true when it changed.
  bool _syncDoorKey() {
    if (_door.isEmpty || !hasFlat) {
      final bool had = _doorKey != null;
      _doorKey = null;
      _doorKeyFor = '';
      return had;
    }
    if (_doorKey != null && _doorKeyFor == _door) {
      return false;
    }
    _doorKey = List<String>.generate(
      32,
      (_) => _random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    _doorKeyFor = _door;
    return true;
  }

  /// What a housemate scans to join (inside the flat only).
  FlatHomeCode? get homeCode {
    final String? seed = _seed;
    return seed == null || !hasFlat
        ? null
        : FlatHomeCode(seed: seed, address: _n(host.ownAddress()));
  }

  List<NeighborFlat> get neighbors => _neighbors.values.toList()
    ..sort(
      (NeighborFlat a, NeighborFlat b) => a.profile.label
          .toLowerCase()
          .compareTo(b.profile.label.toLowerCase()),
    );

  NeighborFlat? neighbor(String key) => _neighbors[key];

  List<FlatMessage> messagesWith(String key) =>
      _messages.values.where((FlatMessage m) => m.flat == key).toList()
        ..sort((FlatMessage a, FlatMessage b) => a.at.compareTo(b.at));

  /// The small chat about one invitation ([itemId]) with the flat [key].
  List<FlatMessage> threadAbout(String key, String itemId) =>
      messagesWith(key).where((FlatMessage m) => m.item == itemId).toList();

  int unread(String key) {
    final int since = _lastRead[key] ?? 0;
    return _messages.values
        .where((FlatMessage m) => m.flat == key && !m.mine && m.at > since)
        .length;
  }

  Future<void> markRead(String key) async {
    _lastRead[key] = _now();
    await _save();
  }

  List<FlatSignup> signupsFor(String itemId) =>
      (_signups[itemId]?.values ?? const Iterable<FlatSignup>.empty())
          .where((FlatSignup s) => s.count > 0)
          .toList()
        ..sort((FlatSignup a, FlatSignup b) => a.at.compareTo(b.at));

  /// How many places we hold for [itemId] at [flat] (0 = none).
  int mySignup(String flat, String itemId) =>
      _mine['$flat|$itemId']?.count ?? 0;

  /// A resident's name, as housemates told it ('' when unknown).
  String residentName(String address) => _names[_n(address)] ?? '';

  /// Phones that voted to remove [target].
  Set<String> votesFor(String target) {
    final Set<String> members = (_profile?.members ?? const <String>[]).toSet();
    return <String>{
      for (final String v in _kickVotes[_n(target)] ?? const <String>{})
        if (members.contains(v) && v != _n(target)) v,
    };
  }

  /// Votes needed to remove [target]: a majority of the other residents.
  int votesNeeded(String target) {
    final int others = (_profile?.members.length ?? 1) - 1;
    return others ~/ 2 + 1;
  }

  bool _enoughVotes(String target) =>
      votesFor(target).length >= votesNeeded(target);

  /// Residents of [key] who showed us their own account.
  List<FlatReveal> revealsFrom(String key) =>
      List<FlatReveal>.of(_reveals[key] ?? const <FlatReveal>[]);

  /// Whether this phone already showed its account to [key].
  bool revealedTo(String key) => _revealedTo.contains(key);

  /// The other new key of [key]'s household when two different ones came
  /// ([kFlatKeyConflict]); `null` normally. Scanning the household's new
  /// door code ([scanDoor]) or [keepCurrentKey] settles it.
  FlatProfile? keyRival(String key) {
    for (final FlatKeySwitch s in _switches.values) {
      if (s.newKey == key && s.rival != null) {
        return s.rival;
      }
    }
    return null;
  }

  /// Keeps the key [key]'s household has now and drops the other one.
  Future<void> keepCurrentKey(String key) async {
    bool changed = false;
    for (final FlatKeySwitch s in _switches.values.toList()) {
      if (s.newKey == key && s.rival != null) {
        s
          ..rival = null
          ..rivalRemoved = <String>{}
          ..rivalBy = '';
        changed = true;
      }
    }
    if (changed) {
      await _save();
    }
  }

  /// This phone's resident key (public), once there is one.
  String? get residentKey => _resident?.id;

  /// Signs [message] with this phone's resident key (tests play a removed
  /// phone that cheats with its own key).
  @visibleForTesting
  Future<String?> residentSign(List<int> message) async {
    final LedgerKeyPair? r = _resident;
    return r == null ? null : b64(await r.sign(message));
  }

  List<NearbyFlatInvite> get nearbyInvites {
    final int t = _now();
    return _nearby
        .where(
          (NearbyFlatInvite i) => t - i.at < kNearbyInviteLife.inMilliseconds,
        )
        .toList()
      ..sort((NearbyFlatInvite a, NearbyFlatInvite b) => b.at.compareTo(a.at));
  }

  String _newId([int length = 12]) => List<String>.generate(
    length,
    (_) => _random.nextInt(36).toRadixString(36),
  ).join();

  String _newDoor() => b64(
    List<int>.generate(12, (_) => _random.nextInt(256)),
  ).replaceAll('=', '');

  // ---- storage ----

  /// The stored state could not be read (e.g. the app was still locked):
  /// nothing is written until a read succeeds, so empty memory never
  /// replaces the real data.
  bool _diskUnreadable = false;

  Future<void> load() async {
    try {
      _diskUnreadable = true;
      final List<int>? raw = await disk.read(_key);
      _diskUnreadable = false;
      final Object? json = raw == null ? null : jsonDecode(utf8.decode(raw));
      if (json is Map) {
        await _fromJson(json);
      }
      if (_syncDoorKey()) {
        await _save();
      }
      notifyListeners();
    } on Object catch (error, stack) {
      logZenError('Odczyt sąsiadów', error, stack);
    }
  }

  Future<void> _fromJson(Map<dynamic, dynamic> json) async {
    final Object? seed = json['seed'];
    _seed = seed is String ? seed : null;
    _pair = null;
    final Uint8List? seedBytes = unb64(_seed, length: 32);
    if (seedBytes != null) {
      _pair = await LedgerKeyPair.fromSeed(seedBytes);
    }
    _profile = FlatProfile.fromJson(json['p']);
    _door = json['door'] is String ? json['door'] as String : '';
    _doorAt = json['doorAt'] is int ? json['doorAt'] as int : 0;
    _doorKey = json['dk'] is String ? json['dk'] as String : null;
    _doorKeyFor = json['dkFor'] is String ? json['dkFor'] as String : '';
    shareWithScanners = json['share'] == true;
    _shareAt = json['shareAt'] is int ? json['shareAt'] as int : 0;
    joining = json['joining'] == true;
    _neighbors.clear();
    final Object? nb = json['nb'];
    if (nb is List) {
      for (final Object? item in nb) {
        final NeighborFlat? f = NeighborFlat.fromJson(item);
        if (f != null) {
          _neighbors[f.key] = f;
        }
      }
    }
    _removed
      ..clear()
      ..addAll(_intMap(json['rm']));
    _messages.clear();
    final Object? msgs = json['msgs'];
    if (msgs is List) {
      for (final Object? item in msgs) {
        final FlatMessage? m = FlatMessage.fromJson(item);
        if (m != null) {
          _messages[m.id] = m;
        }
      }
    }
    _lastRead
      ..clear()
      ..addAll(_intMap(json['read']));
    _signups
      ..clear()
      ..addAll(_signupsFromJson(json['sign']));
    _mine
      ..clear()
      ..addAll(_flatSignupMap(json['my']));
    _nearby.clear();
    final Object? near = json['near'];
    if (near is List) {
      for (final Object? item in near) {
        final NearbyFlatInvite? i = NearbyFlatInvite.fromJson(item);
        if (i != null) {
          _nearby.add(i);
        }
      }
    }
    _names
      ..clear()
      ..addAll(_stringMap(json['names']));
    _kickVotes.clear();
    final Object? kick = json['kick'];
    if (kick is Map) {
      for (final MapEntry<dynamic, dynamic> e in kick.entries) {
        if (e.key is String && e.value is List) {
          _kickVotes[e.key as String] = (e.value as List)
              .whereType<String>()
              .toSet();
        }
      }
    }
    _oldKey = json['oldKey'] is String ? json['oldKey'] as String : null;
    _reveals.clear();
    final Object? rv = json['rv'];
    if (rv is Map) {
      for (final MapEntry<dynamic, dynamic> e in rv.entries) {
        if (e.key is String && e.value is List) {
          _reveals[e.key as String] = <FlatReveal>[
            for (final Object? r in (e.value as List).take(20))
              if (FlatReveal.fromJson(r) != null) FlatReveal.fromJson(r)!,
          ];
        }
      }
    }
    _revealedTo
      ..clear()
      ..addAll(
        ((json['rvTo'] as List?) ?? const <Object?>[]).whereType<String>(),
      );
    final Uint8List? residentSeed = unb64(json['rseed'], length: 32);
    _residentSeed = residentSeed == null ? null : json['rseed'] as String;
    _resident = residentSeed == null
        ? null
        : await LedgerKeyPair.fromSeed(residentSeed);
    _residentKeys
      ..clear()
      ..addAll(_keyMap(json['rks']));
    _voteSigs.clear();
    final Object? kickSig = json['kickSig'];
    if (kickSig is Map) {
      for (final MapEntry<dynamic, dynamic> e in kickSig.entries) {
        if (e.key is String && e.value is Map) {
          _voteSigs[e.key as String] = <String, String>{
            for (final MapEntry<dynamic, dynamic> v in (e.value as Map).entries)
              if (v.key is String && v.value is String)
                v.key as String: v.value as String,
          };
        }
      }
    }
    _switches.clear();
    final Object? sw = json['sw'];
    if (sw is List) {
      for (final Object? item in sw) {
        final FlatKeySwitch? s = FlatKeySwitch.fromJson(item);
        if (s != null) {
          _switches[s.oldKey] = s;
        }
      }
    }
  }

  /// Public keys by phone address, from JSON (anything else dropped).
  Map<String, String> _keyMap(Object? json) => <String, String>{
    if (json is Map)
      for (final MapEntry<dynamic, dynamic> e in json.entries)
        if (e.key is String && unb64(e.value, length: 32) != null)
          _n(e.key as String): e.value as String,
  };

  static Map<String, String> _stringMap(Object? json) => <String, String>{
    if (json is Map)
      for (final MapEntry<dynamic, dynamic> e in json.entries)
        if (e.key is String && e.value is String)
          e.key as String: (e.value as String).length > 40
              ? (e.value as String).substring(0, 40)
              : e.value as String,
  };

  static Map<String, int> _intMap(Object? json) => <String, int>{
    if (json is Map)
      for (final MapEntry<dynamic, dynamic> e in json.entries)
        if (e.key is String && e.value is int) e.key as String: e.value as int,
  };

  static Map<String, FlatSignup> _flatSignupMap(Object? json) =>
      <String, FlatSignup>{
        if (json is Map)
          for (final MapEntry<dynamic, dynamic> e in json.entries)
            if (e.key is String && FlatSignup.fromJson(e.value) != null)
              e.key as String: FlatSignup.fromJson(e.value)!,
      };

  static Map<String, Map<String, FlatSignup>> _signupsFromJson(Object? json) =>
      <String, Map<String, FlatSignup>>{
        if (json is Map)
          for (final MapEntry<dynamic, dynamic> e in json.entries)
            if (e.key is String) e.key as String: _flatSignupMap(e.value),
      };

  Map<String, dynamic> _signupsJson() => <String, dynamic>{
    for (final MapEntry<String, Map<String, FlatSignup>> e in _signups.entries)
      e.key: <String, dynamic>{
        for (final MapEntry<String, FlatSignup> s in e.value.entries)
          s.key: s.value.toJson(),
      },
  };

  Map<String, dynamic> _mineJson() => <String, dynamic>{
    for (final MapEntry<String, FlatSignup> e in _mine.entries)
      e.key: e.value.toJson(),
  };

  Future<void> _save() async {
    if (_diskUnreadable) {
      return;
    }
    final int t = _now();
    _syncDoorKey();
    _nearby.removeWhere(
      (NearbyFlatInvite i) => t - i.at >= kNearbyInviteLife.inMilliseconds,
    );
    // Keep the newest 300 messages per neighbour.
    final Map<String, List<FlatMessage>> byFlat = <String, List<FlatMessage>>{};
    for (final FlatMessage m in _messages.values) {
      (byFlat[m.flat] ??= <FlatMessage>[]).add(m);
    }
    for (final List<FlatMessage> list in byFlat.values) {
      if (list.length > 300) {
        list.sort((FlatMessage a, FlatMessage b) => b.at.compareTo(a.at));
        for (final FlatMessage m in list.skip(300)) {
          _messages.remove(m.id);
        }
      }
    }
    // Key switches of neighbours are kept a month (an unsettled one, three).
    const int month = 30 * 24 * 3600 * 1000;
    _switches.removeWhere(
      (String _, FlatKeySwitch s) =>
          t - s.at > (s.rival == null ? month : 3 * month) ||
          !_neighbors.containsKey(s.newKey),
    );
    await disk.write(
      _key,
      utf8.encode(
        jsonEncode(<String, dynamic>{
          if (_seed != null) 'seed': _seed,
          if (_profile != null) 'p': _profile!.toJson(),
          'door': _door,
          'doorAt': _doorAt,
          'dk': ?_doorKey,
          'dkFor': _doorKeyFor,
          if (shareWithScanners) 'share': true,
          'shareAt': _shareAt,
          if (joining) 'joining': true,
          'nb': <Map<String, dynamic>>[
            for (final NeighborFlat f in _neighbors.values) f.toJson(),
          ],
          'rm': _removed,
          'msgs': <Map<String, dynamic>>[
            for (final FlatMessage m in _messages.values) m.toJson(),
          ],
          'read': _lastRead,
          'sign': _signupsJson(),
          'my': _mineJson(),
          'near': <Map<String, dynamic>>[
            for (final NearbyFlatInvite i in _nearby) i.toJson(),
          ],
          'names': _names,
          'kick': <String, dynamic>{
            for (final MapEntry<String, Set<String>> e in _kickVotes.entries)
              e.key: e.value.toList(),
          },
          'oldKey': ?_oldKey,
          'rv': <String, dynamic>{
            for (final MapEntry<String, List<FlatReveal>> e in _reveals.entries)
              if (_neighbors.containsKey(e.key))
                e.key: <Map<String, dynamic>>[
                  for (final FlatReveal r in e.value) r.toJson(),
                ],
          },
          'rvTo': <String>[
            for (final String k in _revealedTo)
              if (_neighbors.containsKey(k)) k,
          ],
          'rseed': ?_residentSeed,
          'rks': _residentKeys,
          'kickSig': _voteSigs,
          'sw': <Map<String, dynamic>>[
            for (final FlatKeySwitch s in _switches.values) s.toJson(),
          ],
        }),
      ),
    );
    notifyListeners();
  }

  // ---- sending ----

  /// A message signed by our flat, addressed to the flat [to].
  Future<Map<String, dynamic>> _envelope(
    String type,
    String to,
    Map<String, dynamic> body,
  ) => _envelopeWith(_pair!, type, to, body);

  Future<Map<String, dynamic>> _envelopeWith(
    LedgerKeyPair pair,
    String type,
    String to,
    Map<String, dynamic> body,
  ) async {
    final Map<String, dynamic> signed = <String, dynamic>{
      'type': type,
      'f': pair.id,
      'to': to,
      'b': body,
    };
    final Uint8List sig = await pair.sign(canonicalJsonBytes(signed));
    return <String, dynamic>{...signed, 's': b64(sig)};
  }

  Future<void> _sendToFlat(
    List<String> members,
    String type,
    String to,
    Map<String, dynamic> body,
  ) async {
    if (_pair == null) {
      return;
    }
    final Map<String, dynamic> payload = await _envelope(type, to, body);
    final String own = _n(host.ownAddress());
    for (final String m in members.toSet()) {
      if (_n(m) != own) {
        await _send(m, payload);
      }
    }
  }

  Future<void> _send(String to, Map<String, dynamic> payload) async {
    try {
      await host.send(to, payload);
    } on Object catch (error) {
      logZenWarning('Sąsiedzi: ${payload['type']} do $to: $error');
    }
  }

  /// Housemates' phones (all residents but this phone).
  List<String> get _housemates {
    final String own = _n(host.ownAddress());
    return <String>[
      for (final String m in _profile?.members ?? const <String>[])
        if (m != own) m,
    ];
  }

  /// Neighbours who get our profile (and so our invitations) pushed.
  List<NeighborFlat> get audience => <NeighborFlat>[
    for (final NeighborFlat f in _neighbors.values)
      if (f.weScanned || (f.scannedUs && shareWithScanners)) f,
  ];

  Future<void> _pushProfile({Iterable<NeighborFlat>? to}) async {
    final FlatProfile? p = _profile;
    if (p == null) {
      return;
    }
    for (final NeighborFlat f in to ?? audience) {
      await _sendToFlat(
        f.profile.members,
        FlatTypes.profile,
        f.key,
        <String, dynamic>{'p': p.toJson(), 'rk': _roster(p.members)},
      );
    }
  }

  /// The residents' own keys of [members], sent beside the signed profile.
  Map<String, String> _roster(List<String> members) => <String, String>{
    for (final String m in members)
      if (_residentKeys[m] != null) m: _residentKeys[m]!,
  };

  /// Makes sure this phone has its resident key, and that it is on the
  /// housemates' list.
  Future<LedgerKeyPair> _ensureResident() async {
    LedgerKeyPair? pair = _resident;
    if (pair == null) {
      pair = await LedgerKeyPair.generate();
      _resident = pair;
      _residentSeed = b64(pair.seed);
    }
    final String own = _n(host.ownAddress());
    if (own.isNotEmpty) {
      _residentKeys[own] = pair.id;
    }
    return pair;
  }

  /// Pins the residents' keys a neighbour flat sent along with its own
  /// profile: the first key for an address stays for good.
  bool _pinResidents(NeighborFlat f, List<String> members, Object? json) {
    bool changed = false;
    _keyMap(json).forEach((String a, String k) {
      if (members.contains(a) && !f.residents.containsKey(a)) {
        f.residents[a] = FlatPin(key: k, since: _now());
        changed = true;
      }
    });
    return changed;
  }

  /// Sends the whole shared state to the housemates.
  Future<void> _syncHouse({List<String>? to}) async {
    final FlatProfile? p = _profile;
    if (p == null) {
      return;
    }
    final List<FlatMessage> recent = _messages.values.toList()
      ..sort((FlatMessage a, FlatMessage b) => b.at.compareTo(a.at));
    await _sendToFlat(
      to ?? _housemates,
      FlatTypes.house,
      p.key,
      <String, dynamic>{
        'p': p.toJson(),
        'door': _door,
        'doorAt': _doorAt,
        'share': shareWithScanners,
        'shareAt': _shareAt,
        'nb': <Map<String, dynamic>>[
          for (final NeighborFlat f in _neighbors.values)
            <String, dynamic>{
              'p': f.profile.toJson(),
              'at': f.addedAt,
              if (f.weScanned) 'ws': true,
              if (f.scannedUs) 'su': true,
              if (f.residents.isNotEmpty) 'rk': flatPinsToJson(f.residents),
            },
        ],
        'rm': _removed,
        'msgs': <Map<String, dynamic>>[
          for (final FlatMessage m in recent.take(200)) m.toJson(),
        ],
        'sign': _signupsJson(),
        'my': _mineJson(),
        'names': _names,
        'rks': _roster(p.members),
      },
    );
  }

  // ---- this flat ----

  /// Creates this phone's flat ("Nowakowie, m. 12").
  Future<FlatProfile?> createFlat(
    String name, {
    String place = '',
    String about = '',
  }) async {
    final String own = _n(host.ownAddress());
    if (name.trim().isEmpty || own.isEmpty || hasFlat) {
      return null;
    }
    final LedgerKeyPair pair = await LedgerKeyPair.generate();
    _seed = b64(pair.seed);
    _pair = pair;
    _residentKeys.clear();
    await _ensureResident();
    _door = _newDoor();
    _doorAt = _now();
    _profile = await FlatProfile(
      key: pair.id,
      name: _clip(name, 60),
      place: _clip(place, 80),
      about: _clip(about, 1000),
      members: <String>[own],
      rev: 1,
    ).signedWith(pair);
    _names[own] = _clip(host.ownName(), 40);
    joining = false;
    await _save();
    return _profile;
  }

  static String _clip(String s, int max) {
    final String t = s.trim();
    return t.length > max ? t.substring(0, max) : t;
  }

  /// Joins a housemate's flat from their "home" QR (§18.1).
  Future<bool> joinFlat(FlatHomeCode code) async {
    final String own = _n(host.ownAddress());
    final Uint8List? seed = unb64(code.seed, length: 32);
    if (seed == null || own.isEmpty || hasFlat) {
      return false;
    }
    _pair = await LedgerKeyPair.fromSeed(seed);
    _seed = code.seed;
    joining = true;
    _residentKeys.clear();
    final LedgerKeyPair me = await _ensureResident();
    await _save();
    await _send(
      code.address,
      await _envelope(FlatTypes.join, _pair!.id, <String, dynamic>{
        'a': own,
        'n': _clip(host.ownName(), 40),
        // This phone's own key, for votes and neighbours (§18.1).
        'rk': me.id,
      }),
    );
    return true;
  }

  Future<void> _changeProfile(
    FlatProfile Function(FlatProfile p) change,
  ) async {
    final FlatProfile? p = _profile;
    final LedgerKeyPair? pair = _pair;
    if (p == null || pair == null) {
      return;
    }
    final FlatProfile next = change(p);
    _profile = await next.copyWith(rev: p.rev + 1).signedWith(pair);
    await _save();
    await _syncHouse();
    await _pushProfile();
  }

  Future<void> editProfile({String? name, String? place, String? about}) =>
      _changeProfile(
        (FlatProfile p) => p.copyWith(
          name: name == null || name.trim().isEmpty ? null : _clip(name, 60),
          place: place == null ? null : _clip(place, 80),
          about: about == null ? null : _clip(about, 1000),
        ),
      );

  /// Sets (or with `null` removes) the household's photo: a JPEG already
  /// made small with `compressFlatPhoto`.
  Future<bool> setPhoto(Uint8List? jpeg) async {
    if (!hasFlat) {
      return false;
    }
    final String photo = jpeg == null ? '' : b64(jpeg);
    if (photo.length > FlatProfile.maxPhotoChars) {
      return false;
    }
    await _changeProfile((FlatProfile p) => p.copyWith(photo: photo));
    return true;
  }

  /// Adds an invitation, offer or need. Returns its id.
  Future<String?> addItem(
    FlatItemKind kind,
    String text, {
    int? at,
    int seats = 0,
  }) async {
    if (!hasFlat || text.trim().isEmpty || _profile!.items.length >= 60) {
      return null;
    }
    final String id = _newId();
    await _changeProfile(
      (FlatProfile p) => p.copyWith(
        items: <FlatItem>[
          ...p.items,
          FlatItem(
            id: id,
            kind: kind,
            text: _clip(text, 300),
            at: kind == FlatItemKind.invite ? at : null,
            seats: kind == FlatItemKind.invite ? seats.clamp(0, 999) : 0,
          ),
        ],
      ),
    );
    return id;
  }

  Future<void> removeItem(String id) async {
    _signups.remove(id);
    await _changeProfile(
      (FlatProfile p) =>
          p.copyWith(items: p.items.where((FlatItem i) => i.id != id).toList()),
    );
  }

  /// A new door QR: the old one stops working (moving out, a leaked code).
  Future<void> newDoor() async {
    if (!hasFlat) {
      return;
    }
    _door = _newDoor();
    _doorAt = _now();
    await _save();
    await _syncHouse();
  }

  /// A flat that scanned our door code becomes a full neighbour: it gets
  /// our profile and invitations (as if we had scanned theirs).
  Future<void> confirmNeighbor(String key) async {
    final NeighborFlat? f = _neighbors[key];
    if (f == null || f.weScanned) {
      return;
    }
    f.weScanned = true;
    await _save();
    notifyListeners();
    await _syncHouse();
    await _pushProfile(to: <NeighborFlat>[f]);
  }

  Future<void> setShareWithScanners(bool on) async {
    shareWithScanners = on;
    _shareAt = _now();
    await _save();
    await _syncHouse();
    if (on) {
      await _pushProfile(
        to: _neighbors.values.where(
          (NeighborFlat f) => f.scannedUs && !f.weScanned,
        ),
      );
    }
  }

  /// This phone leaves the flat (the others keep it). Neighbours keep
  /// reaching the remaining residents.
  Future<void> leaveFlat() async {
    final FlatProfile? p = _profile;
    final String own = _n(host.ownAddress());
    if (p != null && _pair != null) {
      final List<String> others = _housemates;
      if (others.isNotEmpty) {
        await _sendToFlat(others, FlatTypes.leave, p.key, <String, dynamic>{
          'a': own,
        });
      }
    }
    _seed = null;
    _pair = null;
    _profile = null;
    _door = '';
    joining = false;
    shareWithScanners = false;
    _shareAt = 0;
    _neighbors.clear();
    _removed.clear();
    _messages.clear();
    _signups.clear();
    _mine.clear();
    pending.clear();
    _names.clear();
    _kickVotes.clear();
    _pendingRekeys.clear();
    _oldKey = null;
    _reveals.clear();
    _revealedTo.clear();
    _residentKeys.clear();
    _voteSigs.clear();
    _switches.clear();
    await _save();
  }

  /// The household moves out (§18.1): the door code stops working,
  /// neighbours are told and dropped, invitations and offers go — the
  /// household itself (name, residents, "O nas") stays and starts again at
  /// [newPlace]. The new tenants make their own profile from scratch.
  Future<void> moveOut({String newPlace = ''}) async {
    final FlatProfile? p = _profile;
    if (p == null || _pair == null) {
      return;
    }
    for (final NeighborFlat f in _neighbors.values.toList()) {
      await _sendToFlat(
        f.profile.members,
        FlatTypes.moved,
        f.key,
        <String, dynamic>{'pl': p.place},
      );
    }
    final int t = _now();
    for (final String key in _neighbors.keys) {
      _removed[key] = t;
    }
    _neighbors.clear();
    _messages.clear();
    _signups.clear();
    _mine.clear();
    _nearby.clear();
    pending.clear();
    staleDoors.clear();
    _reveals.clear();
    _revealedTo.clear();
    _switches.clear();
    _door = _newDoor();
    _doorAt = t;
    await _changeProfile(
      (FlatProfile p) =>
          p.copyWith(place: _clip(newPlace, 80), items: const <FlatItem>[]),
    );
  }

  // ---- neighbours ----

  /// A door QR was scanned (or an invitation nearby accepted).
  Future<FlatScan> scanDoor(FlatDoorCode code) async {
    final FlatProfile? p = _profile;
    if (p == null || _pair == null) {
      return FlatScan.noFlat;
    }
    if (code.key == p.key) {
      return FlatScan.own;
    }
    staleDoors.remove(code.key);
    // Asked in person, scanned their new door: that key stays.
    await _settleByDoor(code.key);
    final NeighborFlat? had = _neighbors[code.key];
    if (had != null && had.weScanned) {
      await _sendToFlat(
        had.profile.members,
        FlatTypes.get,
        code.key,
        const <String, dynamic>{},
      );
      return FlatScan.alreadyNeighbor;
    }
    pending[code.key] = code;
    notifyListeners();
    await _sendToFlat(
      <String>[code.inbox],
      FlatTypes.hello,
      code.key,
      <String, dynamic>{
        'door': code.door,
        'p': p.toJson(),
        'rk': _roster(p.members),
      },
    );
    return FlatScan.sent;
  }

  /// A neighbour household with two different new keys ([keyRival]): the
  /// one whose door code was scanned ([key]) stays, the other goes.
  Future<void> _settleByDoor(String key) async {
    for (final FlatKeySwitch s in _switches.values.toList()) {
      final FlatProfile? rival = s.rival;
      if (rival == null) {
        continue;
      }
      if (s.newKey == key) {
        await keepCurrentKey(key);
        return;
      }
      final NeighborFlat? current = _neighbors[s.newKey];
      if (rival.key != key || current == null || _neighbors.containsKey(key)) {
        continue;
      }
      _moveNeighbor(current, rival);
      s
        ..newKey = rival.key
        ..removed = s.rivalRemoved
        ..by = s.rivalBy
        ..rival = null
        ..rivalRemoved = <String>{}
        ..rivalBy = '';
      await _save();
      await _syncHouse();
      return;
    }
  }

  Future<void> removeNeighbor(String key) async {
    _neighbors.remove(key);
    _removed[key] = _now();
    _switches.removeWhere((String _, FlatKeySwitch s) => s.newKey == key);
    await _save();
    await _syncHouse();
  }

  Future<void> setFollowing(String key, bool on) async {
    final NeighborFlat? f = _neighbors[key];
    if (f == null) {
      return;
    }
    f.following = on;
    await _save();
  }

  /// Asks a neighbour for their current profile.
  Future<void> refresh(String key) async {
    final NeighborFlat? f = _neighbors[key];
    if (f != null) {
      await _sendToFlat(
        f.profile.members,
        FlatTypes.get,
        key,
        const <String, dynamic>{},
      );
    }
  }

  /// Writes to the flat [key]. With [itemId] the message belongs to the
  /// small chat of that invitation (§18.3).
  Future<bool> sendMessage(String key, String text, {String? itemId}) async {
    final NeighborFlat? f = _neighbors[key];
    if (f == null || text.trim().isEmpty || !hasFlat) {
      return false;
    }
    final String about =
        itemId != null &&
            (f.profile.item(itemId) != null || _profile?.item(itemId) != null)
        ? itemId
        : '';
    final FlatMessage m = FlatMessage(
      id: _newId(16),
      flat: key,
      mine: true,
      text: _clip(text, 2000),
      at: _now(),
      by: host.ownName(),
      item: about,
    );
    _messages[m.id] = m;
    _lastRead[key] = m.at;
    await _save();
    await _sendToFlat(
      f.profile.members,
      FlatTypes.message,
      key,
      <String, dynamic>{
        'id': m.id,
        't': m.text,
        'at': m.at,
        'by': m.by,
        if (about.isNotEmpty) 'it': about,
      },
    );
    await _syncHouse();
    return true;
  }

  /// Signs up for a neighbour's invitation ([count] places, 0 = cancel).
  Future<bool> signUp(String key, String itemId, int count) async {
    final NeighborFlat? f = _neighbors[key];
    final FlatItem? item = f?.profile.item(itemId);
    if (f == null ||
        item == null ||
        item.kind != FlatItemKind.invite ||
        !hasFlat) {
      return false;
    }
    _mine['$key|$itemId'] = FlatSignup(
      flat: key,
      name: _profile!.name,
      count: count.clamp(0, 20),
      at: _now(),
    );
    await _save();
    await _sendToFlat(
      f.profile.members,
      FlatTypes.signup,
      key,
      <String, dynamic>{'i': itemId, 'c': count.clamp(0, 20)},
    );
    await _syncHouse();
    return true;
  }

  // ---- nearby (Bluetooth) ----

  /// The Bluetooth "wave" that carries one of our invitations to people
  /// around (§18.3). `null` when there is nothing to send.
  Map<String, dynamic>? nearbyWave(String itemId) {
    final FlatDoorCode? code = doorCode;
    final FlatItem? item = _profile?.item(itemId);
    if (code == null || item == null) {
      return null;
    }
    final String when = item.at == null ? '' : ' (${_shortDate(item.at!)})';
    return <String, dynamic>{
      'v': kFlatWaveVersion,
      'q': code.toQr(),
      'm': _clip('${code.name}: ${item.text}$when', 180),
    };
  }

  static String _shortDate(int millis) =>
      ZenFormat.dayMonthTime(DateTime.fromMillisecondsSinceEpoch(millis));

  /// Someone nearby passed us an invitation.
  Future<void> onNearbyWave(Map<dynamic, dynamic> json) async {
    if (json['v'] != kFlatWaveVersion ||
        json['q'] is! String ||
        json['m'] is! String) {
      return;
    }
    final FlatDoorCode? code = FlatDoorCode.parse(json['q'] as String);
    if (code == null || code.key == _profile?.key) {
      return;
    }
    final String text = _clip(json['m'] as String, 200);
    if (_nearby.any(
      (NearbyFlatInvite i) => i.door.key == code.key && i.text == text,
    )) {
      return;
    }
    _nearby.add(NearbyFlatInvite(door: code, text: text, at: _now()));
    await _save();
    await host.notify(
      RuntimeSystemNotification(
        id: 'flat-near-${code.key.hashCode}-${text.hashCode}',
        title: t('Zaproszenie w pobliżu'),
        body: text,
        createdAtMillis: _now(),
        category: RuntimeSystemNotificationCategory.social,
        slotKey: 'flat-near',
      ),
    );
  }

  Future<void> dismissNearby(NearbyFlatInvite invite) async {
    _nearby.remove(invite);
    await _save();
  }

  // ---- receiving ----

  Future<bool> handle(SignalTransportFrame frame) {
    final Object? type = frame.payload['type'];
    if (type is! String || !FlatTypes.all.contains(type)) {
      return Future<bool>.value(false);
    }
    if (frame.door && type != FlatTypes.hello) {
      // The door takes knocks only (the bridge lets nothing else in).
      return Future<bool>.value(false);
    }
    final Completer<bool> done = Completer<bool>();
    _queue = _queue.then((_) async {
      try {
        await _handle(type, frame);
      } on Object catch (error, stack) {
        logZenError('Sąsiedzi', error, stack);
      }
      done.complete(true);
    });
    return done.future;
  }

  Future<void> _handle(String type, SignalTransportFrame frame) async {
    final Map<String, dynamic> p = frame.payload;
    final Object? from = p['f'];
    final Object? to = p['to'];
    final Object? body = p['b'];
    final Object? sig = p['s'];
    if (from is! String || to is! String || body is! Map || sig is! String) {
      return;
    }
    final bool ok = await verifyLedgerSignature(
      publicKey: from,
      message: canonicalJsonBytes(<String, dynamic>{
        'type': type,
        'f': from,
        'to': to,
        'b': body,
      }),
      signature: sig,
    );
    if (!ok) {
      return;
    }
    final String sender = _n(frame.from);
    final Map<String, dynamic> b = Map<String, dynamic>.from(body);
    final String? ownKey = _pair?.id;
    if (type == FlatTypes.rekey &&
        ownKey != null &&
        from == to &&
        to == _oldKey &&
        to != ownKey) {
      // A housemate made a new key at the same moment as this phone.
      await _onRekeyRace(sender, b);
      return;
    }
    if (ownKey == null || to != ownKey) {
      return;
    }
    if (from == ownKey) {
      switch (type) {
        case FlatTypes.house:
          await _onHouse(b);
        case FlatTypes.join:
          await _onJoin(sender, b);
        case FlatTypes.leave:
          await _onLeave(sender, b);
        case FlatTypes.kick:
          await _onKick(sender, b);
        case FlatTypes.rekey:
          await _onRekey(sender, b);
      }
      return;
    }
    if (_profile == null) {
      return;
    }
    switch (type) {
      case FlatTypes.hello:
        await _onHello(from, sender, b, atDoor: frame.door);
      case FlatTypes.nope:
        final FlatDoorCode? code = pending.remove(from);
        if (code != null) {
          staleDoors[from] = code.name;
          notifyListeners();
        }
      case FlatTypes.profile:
        await _onProfile(from, b);
      case FlatTypes.get:
        final NeighborFlat? f = _neighbors[from];
        if (f != null) {
          await _pushProfile(to: <NeighborFlat>[f]);
        }
      case FlatTypes.message:
        await _onMessage(from, b);
      case FlatTypes.signup:
        await _onSignup(from, b);
      case FlatTypes.signupAck:
        await _onSignupAck(from, b);
      case FlatTypes.moved:
        await _onMoved(from);
      case FlatTypes.newKey:
        await _onNewKey(from, sender, b);
      case FlatTypes.reveal:
        await _onReveal(from, sender, b);
    }
  }

  Future<void> _onMoved(String from) async {
    final NeighborFlat? f = _neighbors.remove(from);
    if (f == null) {
      return;
    }
    _removed[from] = _now();
    _messages.removeWhere((String _, FlatMessage m) => m.flat == from);
    await _save();
    await _syncHouse();
    await host.notify(
      RuntimeSystemNotification(
        id: 'flat-moved-${from.hashCode}',
        title: t('{name} wyprowadzili się', {'name': f.profile.name}),
        body: f.profile.place.isEmpty
            ? t('Znikają z listy sąsiadów.')
            : t('Z {place}. Nowi lokatorzy założą własny profil.', {
                'place': f.profile.place,
              }),
        createdAtMillis: _now(),
        category: RuntimeSystemNotificationCategory.social,
        slotKey: 'flat-moved',
      ),
    );
  }

  Future<FlatProfile?> _verifiedProfile(String key, Object? json) async {
    final FlatProfile? p = FlatProfile.fromJson(json);
    if (p == null || p.key != key || !await p.verify()) {
      return null;
    }
    return p;
  }

  Future<void> _onHello(
    String from,
    String sender,
    Map<String, dynamic> b, {
    bool atDoor = false,
  }) async {
    final FlatProfile? theirs = await _verifiedProfile(from, b['p']);
    if (theirs == null) {
      return;
    }
    if (b['door'] != _door) {
      if (atDoor) {
        // Anyone can knock at the door address; an answer from this phone
        // would tell them whose door it is. (An old sticker's door has a
        // key that no longer runs, so its knocks reach nobody anyway.)
        return;
      }
      await _sendToFlat(
        <String>{sender, ...theirs.members}.toList(),
        FlatTypes.nope,
        from,
        const <String, dynamic>{},
      );
      return;
    }
    final NeighborFlat f = _addNeighbor(theirs)..scannedUs = true;
    _pinResidents(f, theirs.members, b['rk']);
    await _save();
    await _pushProfile(to: <NeighborFlat>[f]);
    await _syncHouse();
    await host.notify(
      RuntimeSystemNotification(
        id: 'flat-hello-${from.hashCode}-${_now()}',
        title: t('Nowi sąsiedzi'),
        body: t('{name} zeskanowali Wasz kod z drzwi.', {'name': theirs.name}),
        createdAtMillis: _now(),
        category: RuntimeSystemNotificationCategory.social,
        slotKey: 'flat-hello',
      ),
    );
  }

  NeighborFlat _addNeighbor(FlatProfile p) {
    _removed.remove(p.key);
    final NeighborFlat? had = _neighbors[p.key];
    if (had != null) {
      if (p.newerThan(had.profile)) {
        had.profile = p;
      }
      return had;
    }
    return _neighbors[p.key] = NeighborFlat(
      profile: p,
      addedAt: _now(),
      seenItems: p.items.map((FlatItem i) => i.id).toSet(),
    );
  }

  Future<void> _onProfile(String from, Map<String, dynamic> b) async {
    final FlatProfile? theirs = await _verifiedProfile(from, b['p']);
    if (theirs == null) {
      return;
    }
    final bool wasPending = pending.remove(from) != null;
    NeighborFlat? f = _neighbors[from];
    if (f == null && !wasPending) {
      return;
    }
    if (f == null) {
      f = _addNeighbor(theirs)..weScanned = true;
      _pinResidents(f, theirs.members, b['rk']);
      await _save();
      await _syncHouse();
      return;
    }
    if (wasPending && !f.weScanned) {
      f.weScanned = true;
    }
    final bool pinned = _pinResidents(f, theirs.members, b['rk']);
    if (!theirs.newerThan(f.profile)) {
      if (wasPending || pinned) {
        await _save();
      }
      return;
    }
    f.profile = theirs;
    final List<FlatItem> news = <FlatItem>[
      for (final FlatItem i in theirs.items)
        if (!f.seenItems.contains(i.id)) i,
    ];
    f.seenItems.addAll(theirs.items.map((FlatItem i) => i.id));
    await _save();
    if (f.following) {
      for (final FlatItem i in news) {
        await host.notify(
          RuntimeSystemNotification(
            id: 'flat-item-${i.id}',
            title: switch (i.kind) {
              FlatItemKind.invite => t('{name} zapraszają', {
                'name': theirs.name,
              }),
              FlatItemKind.offer => t('{name} oferują', {'name': theirs.name}),
              FlatItemKind.need => t('{name} szukają pomocy', {
                'name': theirs.name,
              }),
            },
            body: i.at == null ? i.text : '${i.text} — ${_shortDate(i.at!)}',
            createdAtMillis: _now(),
            category: RuntimeSystemNotificationCategory.social,
            slotKey: 'flat-item:$from',
          ),
        );
      }
    }
  }

  Future<void> _onMessage(String from, Map<String, dynamic> b) async {
    final NeighborFlat? f = _neighbors[from];
    final Object? id = b['id'];
    final Object? text = b['t'];
    if (f == null ||
        id is! String ||
        id.length > 40 ||
        text is! String ||
        _messages.containsKey(id)) {
      return;
    }
    final Object? by = b['by'];
    final FlatMessage m = FlatMessage(
      id: id,
      flat: from,
      mine: false,
      text: text.length > 2000 ? text.substring(0, 2000) : text,
      at: _now(),
      by: by is String ? _clip(by, 40) : '',
      item: b['it'] is String && (b['it'] as String).length <= 40
          ? b['it'] as String
          : '',
    );
    _messages[id] = m;
    await _save();
    await host.notify(
      RuntimeSystemNotification(
        id: 'flat-msg-$id',
        title: f.profile.name,
        body: m.by.isEmpty ? m.text : '${m.by}: ${m.text}',
        createdAtMillis: _now(),
        category: RuntimeSystemNotificationCategory.social,
        slotKey: 'flat-msg:$from',
      ),
    );
  }

  Future<void> _onSignup(String from, Map<String, dynamic> b) async {
    final NeighborFlat? f = _neighbors[from];
    final Object? itemId = b['i'];
    final Object? c = b['c'];
    final FlatItem? item = itemId is String ? _profile!.item(itemId) : null;
    if (f == null ||
        item == null ||
        item.kind != FlatItemKind.invite ||
        c is! int) {
      return;
    }
    final int count = c.clamp(0, 20);
    final Map<String, FlatSignup> list = _signups[item.id] ??=
        <String, FlatSignup>{};
    final int before = list[from]?.count ?? 0;
    final int othersTaken = item.taken - before;
    final bool accepted =
        count == 0 || item.seats == 0 || othersTaken + count <= item.seats;
    if (accepted) {
      list[from] = FlatSignup(
        flat: from,
        name: f.profile.name,
        count: count,
        at: _now(),
      );
    }
    await _sendToFlat(
      f.profile.members,
      FlatTypes.signupAck,
      from,
      <String, dynamic>{
        'i': item.id,
        'c': accepted ? count : before,
        'ok': accepted,
      },
    );
    if (!accepted) {
      return;
    }
    await _changeProfile(
      (FlatProfile p) => p.copyWith(
        items: <FlatItem>[
          for (final FlatItem i in p.items)
            i.id == item.id ? i.copyWith(taken: othersTaken + count) : i,
        ],
      ),
    );
    // The one who signed up gets the new count even when not in audience.
    if (!audience.contains(f)) {
      await _pushProfile(to: <NeighborFlat>[f]);
    }
    if (count > before) {
      await host.notify(
        RuntimeSystemNotification(
          id: 'flat-signup-${item.id}-${from.hashCode}-$count',
          title: t('{name} przyjdą', {'name': f.profile.name}),
          body: tn(
            count,
            one: '{text}: {n} osoba',
            few: '{text}: {n} osoby',
            many: '{text}: {n} osób',
            args: <String, Object?>{'text': item.text},
          ),
          createdAtMillis: _now(),
          category: RuntimeSystemNotificationCategory.social,
          slotKey: 'flat-signup:${item.id}',
        ),
      );
    }
  }

  Future<void> _onSignupAck(String from, Map<String, dynamic> b) async {
    final Object? itemId = b['i'];
    final Object? c = b['c'];
    final NeighborFlat? f = _neighbors[from];
    if (f == null || itemId is! String || c is! int) {
      return;
    }
    _mine['$from|$itemId'] = FlatSignup(
      flat: from,
      name: _profile!.name,
      count: c,
      at: _now(),
    );
    await _save();
    await _syncHouse();
    if (b['ok'] != true) {
      await host.notify(
        RuntimeSystemNotification(
          id: 'flat-full-$itemId',
          title: t('Brak miejsc'),
          body:
              '${f.profile.name}: '
              '${f.profile.item(itemId)?.text ?? t('zaproszenie')}',
          createdAtMillis: _now(),
          category: RuntimeSystemNotificationCategory.social,
          slotKey: 'flat-full:$itemId',
        ),
      );
    }
  }

  // ---- housemates ----

  Future<void> _onJoin(String sender, Map<String, dynamic> b) async {
    final Object? a = b['a'];
    final FlatProfile? p = _profile;
    if (p == null || a is! String || _n(a) != sender) {
      return;
    }
    final Object? name = b['n'];
    if (name is String && name.trim().isNotEmpty) {
      _names[sender] = _clip(name, 40);
    }
    // The new resident's own key (its first one stays).
    final Object? rk = b['rk'];
    if (unb64(rk, length: 32) != null && _residentKeys[sender] == null) {
      _residentKeys[sender] = rk as String;
    }
    if (!p.members.contains(sender)) {
      await _changeProfile(
        (FlatProfile p) => p.copyWith(members: <String>[...p.members, sender]),
      );
    } else {
      await _save();
      await _syncHouse(to: <String>[sender]);
    }
    await host.notify(
      RuntimeSystemNotification(
        id: 'flat-join-${sender.hashCode}',
        title: t('Nowy domownik'),
        body: t('Kolejny telefon dołączył do „{name}”.', {'name': p.name}),
        createdAtMillis: _now(),
        category: RuntimeSystemNotificationCategory.social,
        slotKey: 'flat-join',
      ),
    );
  }

  Future<void> _onLeave(String sender, Map<String, dynamic> b) async {
    final Object? a = b['a'];
    final FlatProfile? p = _profile;
    if (p == null ||
        a is! String ||
        _n(a) != sender ||
        !p.members.contains(sender)) {
      return;
    }
    _names.remove(sender);
    _kickVotes.remove(sender);
    _voteSigs.remove(sender);
    _residentKeys.remove(sender);
    await _changeProfile(
      (FlatProfile p) => p.copyWith(
        members: p.members.where((String m) => m != sender).toList(),
      ),
    );
  }

  Future<void> _onHouse(Map<String, dynamic> b) async {
    final FlatProfile? p = await _verifiedProfile(_pair!.id, b['p']);
    if (p == null) {
      return;
    }
    final bool wasJoining = joining;
    if (p.newerThan(_profile)) {
      _profile = p;
    }
    joining = false;
    final Object? door = b['door'];
    final Object? doorAt = b['doorAt'];
    if (door is String && doorAt is int && doorAt > _doorAt) {
      _door = door;
      _doorAt = doorAt;
    }
    final Object? shareAt = b['shareAt'];
    if (shareAt is int && shareAt > _shareAt) {
      shareWithScanners = b['share'] == true;
      _shareAt = shareAt;
    }
    _intMap(b['rm']).forEach((String key, int at) {
      if (at > (_removed[key] ?? 0)) {
        _removed[key] = at;
      }
    });
    final Object? nb = b['nb'];
    if (nb is List) {
      for (final Object? item in nb) {
        if (item is! Map || item['at'] is! int) {
          continue;
        }
        final FlatProfile? fp = FlatProfile.fromJson(item['p']);
        if (fp == null || fp.key == p.key || !await fp.verify()) {
          continue;
        }
        final int addedAt = item['at'] as int;
        if ((_removed[fp.key] ?? 0) >= addedAt) {
          continue;
        }
        final NeighborFlat? had = _neighbors[fp.key];
        // Residents' keys a housemate pinned (ours stay where we have one).
        final Map<String, FlatPin> pins = flatPinsFromJson(item['rk']);
        if (had == null) {
          _neighbors[fp.key] = NeighborFlat(
            profile: fp,
            addedAt: addedAt,
            weScanned: item['ws'] == true,
            scannedUs: item['su'] == true,
            seenItems: fp.items.map((FlatItem i) => i.id).toSet(),
            residents: pins,
          );
        } else {
          if (fp.newerThan(had.profile)) {
            had.profile = fp;
          }
          had
            ..weScanned = had.weScanned || item['ws'] == true
            ..scannedUs = had.scannedUs || item['su'] == true;
          pins.forEach((String a, FlatPin pin) {
            had.residents.putIfAbsent(a, () => pin);
          });
        }
      }
    }
    _neighbors.removeWhere(
      (String key, NeighborFlat f) => (_removed[key] ?? 0) >= f.addedAt,
    );
    _messages.removeWhere(
      (String _, FlatMessage m) => !_neighbors.containsKey(m.flat),
    );
    final Object? msgs = b['msgs'];
    if (msgs is List) {
      for (final Object? item in msgs) {
        final FlatMessage? m = FlatMessage.fromJson(item);
        if (m != null &&
            !_messages.containsKey(m.id) &&
            _neighbors.containsKey(m.flat)) {
          _messages[m.id] = m;
        }
      }
    }
    _signupsFromJson(b['sign']).forEach((
      String item,
      Map<String, FlatSignup> list,
    ) {
      final Map<String, FlatSignup> mine = _signups[item] ??=
          <String, FlatSignup>{};
      list.forEach((String flat, FlatSignup s) {
        if (s.at > (mine[flat]?.at ?? -1)) {
          mine[flat] = s;
        }
      });
    });
    _flatSignupMap(b['my']).forEach((String key, FlatSignup s) {
      if (s.at > (_mine[key]?.at ?? -1)) {
        _mine[key] = s;
      }
    });
    final Set<String> residents = (_profile?.members ?? const <String>[])
        .toSet();
    _stringMap(b['names']).forEach((String a, String n) {
      if (residents.contains(a) && n.trim().isNotEmpty) {
        _names[a] = n;
      }
    });
    // Housemates' own keys: the first one known for a phone stays, and
    // this phone's own is never taken from elsewhere.
    final String own = _n(host.ownAddress());
    _keyMap(b['rks']).forEach((String a, String k) {
      if (residents.contains(a) && a != own) {
        _residentKeys.putIfAbsent(a, () => k);
      }
    });
    await _save();
    if (wasJoining && hasFlat) {
      await host.notify(
        RuntimeSystemNotification(
          id: 'flat-joined-${p.key.hashCode}',
          title: t('Jesteś domownikiem'),
          body: t('Dołączyłeś(-aś) do „{name}”.', {'name': p.name}),
          createdAtMillis: _now(),
          category: RuntimeSystemNotificationCategory.social,
          slotKey: 'flat-join',
        ),
      );
    }
  }

  // ---- removing a housemate who will not leave (§18.1) ----

  /// Votes to remove the phone [target] from the household. Once a
  /// majority of the other residents agree, the household gets a new key
  /// and a new door code without it, and neighbours are told. Returns
  /// whether the vote counted.
  Future<bool> voteRemove(String target) async {
    final FlatProfile? p = _profile;
    final String own = _n(host.ownAddress());
    final String t = _n(target);
    if (p == null || _pair == null || t == own || !p.members.contains(t)) {
      return false;
    }
    // Signed with this phone's own key: neighbours check the votes when
    // the household announces its new key.
    final LedgerKeyPair me = await _ensureResident();
    final String vote = b64(await me.sign(flatKickBytes(p.key, t)));
    (_kickVotes[t] ??= <String>{}).add(own);
    (_voteSigs[t] ??= <String, String>{})[own] = vote;
    await _save();
    await _sendToFlat(
      <String>[
        for (final String m in _housemates)
          if (m != t) m,
      ],
      FlatTypes.kick,
      p.key,
      <String, dynamic>{'a': t, 'v': vote},
    );
    await _maybeRekey(t);
    return true;
  }

  /// Takes back this phone's vote.
  Future<void> withdrawVote(String target) async {
    final FlatProfile? p = _profile;
    final String own = _n(host.ownAddress());
    final String t = _n(target);
    if (p == null || !(_kickVotes[t]?.remove(own) ?? false)) {
      return;
    }
    _voteSigs[t]?.remove(own);
    await _save();
    await _sendToFlat(
      <String>[
        for (final String m in _housemates)
          if (m != t) m,
      ],
      FlatTypes.kick,
      p.key,
      <String, dynamic>{'a': t, 'no': true},
    );
  }

  Future<void> _onKick(String sender, Map<String, dynamic> b) async {
    final FlatProfile? p = _profile;
    final Object? a = b['a'];
    final String own = _n(host.ownAddress());
    if (p == null || a is! String) {
      return;
    }
    final String target = _n(a);
    if (target == own ||
        target == sender ||
        !p.members.contains(target) ||
        !p.members.contains(sender)) {
      return;
    }
    if (b['no'] == true) {
      _kickVotes[target]?.remove(sender);
      _voteSigs[target]?.remove(sender);
      await _save();
      return;
    }
    // The vote signed with the voter's own key.
    final Object? vote = b['v'];
    if (vote is! String) {
      return;
    }
    final String? rk = _residentKeys[sender];
    if (rk != null &&
        !await verifyLedgerSignature(
          publicKey: rk,
          message: flatKickBytes(p.key, target),
          signature: vote,
        )) {
      return;
    }
    (_voteSigs[target] ??= <String, String>{})[sender] = vote;
    final bool added = (_kickVotes[target] ??= <String>{}).add(sender);
    await _save();
    if (added && !(_kickVotes[target]?.contains(own) ?? false)) {
      final String name = residentName(target);
      await host.notify(
        RuntimeSystemNotification(
          id: 'flat-kick-${target.hashCode}-${sender.hashCode}',
          title: t('Domownicy chcą odłączyć telefon'),
          body: t(
            '{name}: głosów {votes} z {needed}. Zajrzyj do „Domownicy”.',
            <String, Object?>{
              'name': name.isEmpty ? t('Jeden z telefonów') : name,
              'votes': votesFor(target).length,
              'needed': votesNeeded(target),
            },
          ),
          createdAtMillis: _now(),
          category: RuntimeSystemNotificationCategory.social,
          slotKey: 'flat-kick',
        ),
      );
    }
    final (String, Map<String, dynamic>)? waiting = _pendingRekeys[target];
    if (waiting != null && _enoughVotes(target)) {
      _pendingRekeys.remove(target);
      await _applyRekey(target, waiting.$2);
      return;
    }
    await _maybeRekey(target);
  }

  /// With a majority, the voter with the lowest address makes the new key
  /// (so two phones do not do it at once).
  Future<void> _maybeRekey(String target) async {
    final String own = _n(host.ownAddress());
    final Set<String> votes = votesFor(target);
    if (!_enoughVotes(target) || !votes.contains(own)) {
      return;
    }
    final List<String> sorted = votes.toList()..sort();
    if (sorted.first == own) {
      await _rekey(target);
    }
  }

  Future<void> _rekey(String target) async {
    final FlatProfile? p = _profile;
    final LedgerKeyPair? old = _pair;
    final String own = _n(host.ownAddress());
    if (p == null || old == null) {
      return;
    }
    final LedgerKeyPair pair = await LedgerKeyPair.generate();
    final int t = _now();
    final String door = _newDoor();
    final FlatProfile next = await p
        .copyWith(
          key: pair.id,
          members: p.members.where((String m) => m != target).toList(),
          rev: 1,
        )
        .signedWith(pair);
    // Signed with the old key (the one housemates and neighbours trust),
    // before switching to the new one.
    final Map<String, dynamic> toHouse =
        await _envelopeWith(old, FlatTypes.rekey, old.id, <String, dynamic>{
          'a': target,
          'seed': b64(pair.seed),
          'p': next.toJson(),
          'door': door,
          'doorAt': t,
        });
    // For neighbours the old key is not enough (the removed phone has it
    // too): the notice carries this phone's own signature and the
    // others' signed votes, checked with the residents' keys the neighbours
    // pinned while everyone was still in.
    final LedgerKeyPair me = await _ensureResident();
    final String bySig = b64(
      await me.sign(flatNewKeyBytes(old.id, pair.id, target)),
    );
    final Map<String, String> votes = <String, String>{
      for (final String v in votesFor(target))
        if (_voteSigs[target]?[v] != null) v: _voteSigs[target]![v]!,
    };
    final Map<String, dynamic> notice = <String, dynamic>{
      'p': next.toJson(),
      'a': target,
      'by': own,
      'bs': bySig,
      'v': votes,
    };
    final List<(Set<String>, Map<String, dynamic>)> toNeighbors =
        <(Set<String>, Map<String, dynamic>)>[
          for (final NeighborFlat f in _neighbors.values)
            (
              f.profile.members.toSet(),
              await _envelopeWith(old, FlatTypes.newKey, f.key, notice),
            ),
        ];
    _oldKey = old.id;
    _seed = b64(pair.seed);
    _pair = pair;
    _profile = next;
    _door = door;
    _doorAt = t;
    _kickVotes.clear();
    _voteSigs.clear();
    _pendingRekeys.clear();
    _names.remove(target);
    _residentKeys.remove(target);
    await _save();
    for (final String m in next.members) {
      if (m != own) {
        await _send(m, toHouse);
      }
    }
    for (final (Set<String> members, Map<String, dynamic> payload)
        in toNeighbors) {
      for (final String m in members) {
        if (m != own) {
          await _send(m, payload);
        }
      }
    }
    await _notifyRekeyed(next);
  }

  Future<void> _notifyRekeyed(FlatProfile next) => host.notify(
    RuntimeSystemNotification(
      id: 'flat-rekey-${next.key.hashCode}',
      title: t('Telefon odłączony od „{name}”', {'name': next.name}),
      body: t(
        'Macie nowy klucz mieszkania i nowy kod na drzwi — wydrukujcie '
        'nową naklejkę. Sąsiedzi dostali informację.',
      ),
      createdAtMillis: _now(),
      category: RuntimeSystemNotificationCategory.social,
      slotKey: 'flat-kick',
    ),
  );

  Future<void> _onRekey(String sender, Map<String, dynamic> b) async {
    final FlatProfile? p = _profile;
    final Object? a = b['a'];
    final String own = _n(host.ownAddress());
    if (p == null || a is! String) {
      return;
    }
    final String target = _n(a);
    if (target == own ||
        sender == target ||
        !p.members.contains(sender) ||
        !p.members.contains(target)) {
      return; // the removed phone gets nothing; nobody removes us by mail
    }
    if (!_enoughVotes(target)) {
      // The votes may still be on their way.
      _pendingRekeys[target] = (sender, b);
      return;
    }
    await _applyRekey(target, b);
  }

  /// Checks a new key from a housemate and switches to it.
  Future<bool> _applyRekey(String target, Map<String, dynamic> b) async {
    final String own = _n(host.ownAddress());
    final Object? seed = b['seed'];
    final Uint8List? seedBytes = unb64(seed, length: 32);
    if (seed is! String || seedBytes == null) {
      return false;
    }
    final LedgerKeyPair pair = await LedgerKeyPair.fromSeed(seedBytes);
    final FlatProfile? next = await _verifiedProfile(pair.id, b['p']);
    if (next == null ||
        !next.members.contains(own) ||
        next.members.contains(target)) {
      return false;
    }
    final Object? door = b['door'];
    final Object? doorAt = b['doorAt'];
    _oldKey = _pair?.id;
    _seed = seed;
    _pair = pair;
    _profile = next;
    if (door is String && doorAt is int) {
      _door = door;
      _doorAt = doorAt;
    } else {
      _door = _newDoor();
      _doorAt = _now();
    }
    _kickVotes.clear();
    _voteSigs.clear();
    _pendingRekeys.clear();
    _names.remove(target);
    _residentKeys.remove(target);
    await _save();
    await _notifyRekeyed(next);
    return true;
  }

  /// Two housemates made a new key at once: everyone keeps the one with
  /// the lower key, and the phone that switches tells neighbours (with the
  /// key they now know) where the household went.
  Future<void> _onRekeyRace(String sender, Map<String, dynamic> b) async {
    final FlatProfile? p = _profile;
    final LedgerKeyPair? mine = _pair;
    final Object? a = b['a'];
    final Uint8List? seedBytes = unb64(b['seed'], length: 32);
    if (p == null ||
        mine == null ||
        a is! String ||
        seedBytes == null ||
        p.members.contains(_n(a)) ||
        !p.members.contains(sender)) {
      return;
    }
    final LedgerKeyPair theirs = await LedgerKeyPair.fromSeed(seedBytes);
    if (theirs.id.compareTo(mine.id) >= 0) {
      return; // ours stays; they will switch when ours reaches them
    }
    final FlatProfile? next = await _verifiedProfile(theirs.id, b['p']);
    if (next == null) {
      return;
    }
    final String own = _n(host.ownAddress());
    for (final NeighborFlat f in _neighbors.values) {
      final Map<String, dynamic> payload = await _envelopeWith(
        mine,
        FlatTypes.newKey,
        f.key,
        <String, dynamic>{'p': next.toJson()},
      );
      for (final String m in f.profile.members.toSet()) {
        if (m != own) {
          await _send(m, payload);
        }
      }
    }
    _seed = b64(seedBytes);
    _pair = theirs;
    _profile = next;
    final Object? door = b['door'];
    final Object? doorAt = b['doorAt'];
    if (door is String && doorAt is int) {
      _door = door;
      _doorAt = doorAt;
    }
    await _save();
  }

  /// A neighbour household has a new key: they removed a phone (§18.1).
  ///
  /// The notice is signed with the old key, which the removed phone holds
  /// too. So it must also carry the signature of the resident who made the
  /// new key and the signed votes of a majority of the others, checked with
  /// the residents' own keys this phone pinned while they were all in (at
  /// least [kResidentKeyTrust] ago). A notice made by the phone it names as
  /// removed, or without those votes, is ignored. When no resident key is
  /// known that long (a household met just now), a notice from a resident
  /// who stays counts.
  ///
  /// A second, different new key for the same old one never silently
  /// replaces the first: the same removal made twice at once (two
  /// housemates) ends on the lower key, as for the housemates; two
  /// different stories of who was removed raise [kFlatKeyConflict] — the
  /// one made by a phone the other names as removed loses, otherwise the
  /// first stays — and scanning the household's new door code settles it.
  Future<void> _onNewKey(
    String from,
    String sender,
    Map<String, dynamic> b,
  ) async {
    final FlatProfile? next = FlatProfile.fromJson(b['p']);
    if (next == null ||
        next.key == from ||
        next.key == _profile?.key ||
        _neighbors.containsKey(next.key) ||
        !await next.verify()) {
      return;
    }
    final int now = _now();
    final NeighborFlat? f = _neighbors[from];
    if (f != null) {
      final FlatKeySwitch? hop = _switchTo(from);
      if (hop != null &&
          now - hop.at < const Duration(days: 1).inMilliseconds &&
          next.key.compareTo(from) < 0 &&
          setEquals(next.members.toSet(), f.profile.members.toSet()) &&
          f.profile.members.contains(sender)) {
        // Two housemates made a new key at once: the household keeps the
        // lower one, and the key it leaves is one the removed phone never
        // had.
        _moveNeighbor(f, next);
        hop.newKey = next.key;
        await _save();
        await _syncHouse();
        return;
      }
      final (Set<String>, String)? claim = await _checkNewKey(
        from,
        f.profile.members,
        f.residents,
        next,
        sender,
        b,
      );
      if (claim == null) {
        return;
      }
      _switches[from] = FlatKeySwitch(
        oldKey: from,
        name: f.profile.name,
        members: List<String>.of(f.profile.members),
        pins: Map<String, FlatPin>.of(f.residents),
        newKey: next.key,
        removed: claim.$1,
        by: claim.$2,
        at: now,
      );
      _moveNeighbor(f, next);
      await _save();
      await _syncHouse();
      await host.notify(
        RuntimeSystemNotification(
          id: 'flat-newkey-${next.key.hashCode}',
          title: t('{name}: zmiana domowników', {'name': next.name}),
          body: t(
            'Odłączyli jeden telefon i mają nowy klucz. Lista sąsiadów jest '
            'aktualna.',
          ),
          createdAtMillis: now,
          category: RuntimeSystemNotificationCategory.social,
          slotKey: 'flat-newkey',
        ),
      );
      return;
    }
    // A notice for a key this phone already moved away from.
    final FlatKeySwitch? s = _switches[from];
    final NeighborFlat? current = s == null ? null : _neighbors[s.newKey];
    if (s == null || current == null || s.rival?.key == next.key) {
      return;
    }
    final (Set<String>, String)? claim = await _checkNewKey(
      from,
      s.members,
      s.pins,
      next,
      sender,
      b,
    );
    if (claim == null) {
      return;
    }
    if (setEquals(claim.$1, s.removed)) {
      // The same phone removed, two keys made at once.
      if (next.key.compareTo(s.newKey) < 0) {
        _moveNeighbor(current, next);
        s
          ..newKey = next.key
          ..by = claim.$2;
        await _save();
        await _syncHouse();
      }
      return;
    }
    // Two different stories of who was removed.
    final bool rivalMadeByRemoved = s.removed.contains(claim.$2);
    final bool currentMadeByRemoved = claim.$1.contains(s.by);
    if (currentMadeByRemoved && !rivalMadeByRemoved) {
      final FlatProfile was = current.profile;
      final Set<String> wasRemoved = s.removed;
      final String wasBy = s.by;
      _moveNeighbor(current, next);
      s
        ..newKey = next.key
        ..removed = claim.$1
        ..by = claim.$2
        ..rival = was
        ..rivalRemoved = wasRemoved
        ..rivalBy = wasBy;
    } else {
      s
        ..rival = next
        ..rivalRemoved = claim.$1
        ..rivalBy = claim.$2;
    }
    await _save();
    await _syncHouse();
    await host.notify(
      RuntimeSystemNotification(
        id: 'flat-newkey-conflict-${from.hashCode}',
        title: kFlatKeyConflict,
        body: t(
          '„{name}”: nie wiadomo, który telefon naprawdę odłączyli. '
          'Zeskanujcie ich nowy kod z drzwi.',
          <String, Object?>{'name': s.name},
        ),
        createdAtMillis: now,
        category: RuntimeSystemNotificationCategory.social,
        slotKey: 'flat-newkey',
      ),
    );
  }

  /// The switch that led to [key], if this phone followed one.
  FlatKeySwitch? _switchTo(String key) {
    for (final FlatKeySwitch s in _switches.values) {
      if (s.newKey == key) {
        return s;
      }
    }
    return null;
  }

  /// Checks a "new key" notice of the household that had the key [oldKey]
  /// with [members] and the residents' keys [pins]. Returns who it removes
  /// and who made it, or `null` when it does not hold up.
  Future<(Set<String>, String)?> _checkNewKey(
    String oldKey,
    List<String> members,
    Map<String, FlatPin> pins,
    FlatProfile next,
    String sender,
    Map<String, dynamic> b,
  ) async {
    final Set<String> removed = <String>{
      for (final String m in members)
        if (!next.members.contains(m)) m,
    };
    final int t = _now();
    final Set<String> trusted = <String>{
      for (final MapEntry<String, FlatPin> e in pins.entries)
        if (members.contains(e.key) &&
            t - e.value.since >= kResidentKeyTrust.inMilliseconds)
          e.key,
    };
    final Object? a = b['a'];
    final String? target = a is String ? _n(a) : null;
    // The residents whose votes can be checked: keys known long enough,
    // but not the one being removed.
    final List<String> voters = <String>[
      for (final String v in trusted)
        if (v != target) v,
    ];
    if (voters.isEmpty) {
      // Nothing to check the votes with (a household met just now): a
      // resident who stays.
      return members.contains(sender) && next.members.contains(sender)
          ? (removed, sender)
          : null;
    }
    final Object? by = b['by'];
    final Object? bySig = b['bs'];
    final Object? votes = b['v'];
    if (target == null || by is! String || bySig is! String || votes is! Map) {
      return null;
    }
    final String maker = _n(by);
    final FlatPin? makerPin = pins[maker];
    if (!removed.contains(target) ||
        maker == target ||
        !next.members.contains(maker) ||
        makerPin == null ||
        !await verifyLedgerSignature(
          publicKey: makerPin.key,
          message: flatNewKeyBytes(oldKey, next.key, target),
          signature: bySig,
        )) {
      return null;
    }
    // A majority of the other residents whose keys are known voted for it.
    int yes = 0;
    for (final String v in voters) {
      final Object? sig = votes[v];
      if (sig is String &&
          await verifyLedgerSignature(
            publicKey: pins[v]!.key,
            message: flatKickBytes(oldKey, target),
            signature: sig,
          )) {
        yes++;
      }
    }
    if (yes < voters.length ~/ 2 + 1) {
      return null;
    }
    return (removed, maker);
  }

  /// Moves the neighbour household [f] to its new key [next], with its
  /// messages, sign-ups, reveals and residents' keys.
  void _moveNeighbor(NeighborFlat f, FlatProfile next) {
    final String from = f.key;
    final int t = _now();
    _neighbors.remove(from);
    _removed[from] = t;
    _removed.remove(next.key);
    _neighbors[next.key] = NeighborFlat(
      profile: next,
      addedAt: t,
      weScanned: f.weScanned,
      scannedUs: f.scannedUs,
      following: f.following,
      seenItems: <String>{
        ...f.seenItems,
        ...next.items.map((FlatItem i) => i.id),
      },
      residents: Map<String, FlatPin>.of(f.residents),
    );
    for (final FlatMessage m in _messages.values.toList()) {
      if (m.flat == from) {
        _messages[m.id] = FlatMessage(
          id: m.id,
          flat: next.key,
          mine: m.mine,
          text: m.text,
          at: m.at,
          by: m.by,
          item: m.item,
        );
      }
    }
    final int? read = _lastRead.remove(from);
    if (read != null) {
      _lastRead[next.key] = read;
    }
    for (final Map<String, FlatSignup> list in _signups.values) {
      final FlatSignup? s = list.remove(from);
      if (s != null) {
        list[next.key] = FlatSignup(
          flat: next.key,
          name: s.name,
          count: s.count,
          at: s.at,
        );
      }
    }
    for (final String k in _mine.keys.toList()) {
      if (k.startsWith('$from|')) {
        _mine['${next.key}|${k.substring(from.length + 1)}'] = _mine.remove(k)!;
      }
    }
    final List<FlatReveal>? reveals = _reveals.remove(from);
    if (reveals != null) {
      _reveals[next.key] = <FlatReveal>[
        for (final FlatReveal r in reveals)
          if (next.members.contains(r.address))
            FlatReveal(
              flat: next.key,
              name: r.name,
              address: r.address,
              at: r.at,
            ),
      ];
    }
    if (_revealedTo.remove(from)) {
      _revealedTo.add(next.key);
    }
    pending.remove(from);
  }

  // ---- "Pokaż mój profil" (§18.1) ----

  /// Shows this resident's own account to the neighbour flat [key]: they
  /// see the name and can send a friend invitation. Only this phone's
  /// person is revealed, never the housemates.
  Future<bool> revealMyProfile(String key) async {
    final NeighborFlat? f = _neighbors[key];
    final String own = _n(host.ownAddress());
    if (f == null || !hasFlat || own.isEmpty) {
      return false;
    }
    _revealedTo.add(key);
    await _save();
    await _sendToFlat(
      f.profile.members,
      FlatTypes.reveal,
      key,
      <String, dynamic>{'n': _clip(host.ownName(), 60), 'a': own},
    );
    return true;
  }

  Future<void> _onReveal(
    String from,
    String sender,
    Map<String, dynamic> b,
  ) async {
    final NeighborFlat? f = _neighbors[from];
    final Object? a = b['a'];
    final Object? n = b['n'];
    // Only the phone itself reveals its own account.
    if (f == null ||
        a is! String ||
        _n(a) != sender ||
        n is! String ||
        n.trim().isEmpty ||
        !f.profile.members.contains(sender)) {
      return;
    }
    final FlatReveal r = FlatReveal(
      flat: from,
      name: _clip(n, 60),
      address: sender,
      at: _now(),
    );
    _reveals[from] = <FlatReveal>[
      ...(_reveals[from] ?? const <FlatReveal>[]).where(
        (FlatReveal x) => x.address != sender,
      ),
      r,
    ];
    await _save();
    await host.notify(
      RuntimeSystemNotification(
        id: 'flat-reveal-${from.hashCode}-${sender.hashCode}',
        title: t('{flat}: {name} pokazuje swój profil', {
          'flat': f.profile.name,
          'name': r.name,
        }),
        body: t('Możesz zaprosić do znajomych.'),
        createdAtMillis: _now(),
        category: RuntimeSystemNotificationCategory.social,
        slotKey: 'flat-reveal:$from',
      ),
    );
  }
}
