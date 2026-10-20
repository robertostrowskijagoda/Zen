import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/core/ledger/ledger_codec.dart';
import 'package:zen/src/core/ledger/ledger_identity.dart';
import 'package:zen/src/core/logging/zen_log.dart';
import 'package:zen/src/features/ledger/ledger_identity_store.dart';
import 'package:zen/src/features/meet/events/event_service.dart';
import 'package:zen/src/features/meet/meet_book.dart';
import 'package:zen/src/features/meet/meet_service.dart';
import 'package:zen/src/features/runtime/runtime_system_notifications.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';
import 'package:zen/src/features/social/friend_display_name.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';

/// Frames of the contact economy without money (§24.1). Every one goes
/// between two accepted friends: X → F → Y and back.
abstract final class IntroTypes {
  /// X asks a friend F: an introduction to Y, a letter for Y, or F's
  /// friend list.
  static const String ask = 'intro_ask';

  /// F passes an introduction or a letter on to Y.
  static const String forward = 'intro_fwd';

  /// Y tells F whether they accept.
  static const String answer = 'intro_ans';

  /// F tells X how it went.
  static const String result = 'intro_res';

  static const Set<String> all = <String>{ask, forward, answer, result};
}

/// How long a case is kept, open or not.
const Duration kIntroLife = Duration(days: 30);

/// Longest note to an introduction (the asker's or the middle friend's).
const int kIntroNoteMaxChars = 300;

/// Longest letter to a stranger.
const int kLetterMaxChars = 1000;

/// Letters one person may send through one friend in a week (the sender's
/// app counts, the friend's app checks again).
const int kLettersPerWeek = 3;

/// Letters one phone passes on in a week, from all senders together.
const int kLettersRelayedPerWeek = 10;

/// Requests (introductions, letters, lists) taken from one friend a day.
const int kIntroAsksPerFriendPerDay = 10;

/// Introductions and letters passed on to this phone by one friend a day.
const int kIntroForwardsPerFriendPerDay = 10;

/// Cases waiting for this person's answer, at most.
const int kIntroMaxOpen = 50;

/// Cases kept at most.
const int kIntroMaxCases = 300;

/// Longest string field taken from a frame before it is even cleaned.
const int _maxRawField = 8000;

const int _day = 24 * 3600 * 1000;
const int _week = 7 * _day;

final RegExp _introId = RegExp(r'^[0-9a-z]{8,24}$');

/// A mesh address (as on friend lists).
final RegExp _introAddress = RegExp(r'^[0-9A-Za-z:._-]{1,64}$');

/// Control and direction-changing characters (new lines stay).
final RegExp _textControl = RegExp(
  r'[\u0000-\u0009\u000b-\u001f\u007f-\u009f\u200b-\u200f\u202a-\u202e\u2066-\u2069]',
);
final RegExp _manyLines = RegExp(r'\n{3,}');

/// A note or a letter as a peer sent it: no control characters, at most
/// one empty line in a row, clipped to [max] (never half an emoji).
String introText(Object? value, int max) {
  if (value is! String) {
    return '';
  }
  final String clean = value
      .replaceAll('\r\n', '\n')
      .replaceAll(_textControl, ' ')
      .replaceAll(_manyLines, '\n\n')
      .trim();
  if (clean.length <= max) {
    return clean;
  }
  String cut = clean.substring(0, max);
  final int last = cut.codeUnitAt(cut.length - 1);
  if (last >= 0xD800 && last <= 0xDBFF) {
    cut = cut.substring(0, cut.length - 1);
  }
  return cut.trim();
}

/// The mark on an introduction or a letter that came without the asker's
/// signature (from an older app): the middle friend could have changed it.
String introUnverifiedLabel() =>
    t('Niezweryfikowane — pośrednik mógł zmienić treść');

/// What the asker signs with their device key (S-17): the case, their own
/// address, the one it is for, the words and their own name. The middle
/// friend passes the signature on with the case and cannot change any of
/// it without the signature failing.
Uint8List introSignedBytes({
  required String id,
  required IntroKind kind,
  required String asker,
  required String target,
  required String text,
  required String name,
}) => canonicalJsonBytes(<String, dynamic>{
  't': 'zen_intro_v1',
  'id': id,
  'k': kind.name,
  'a': asker,
  'y': target,
  'txt': text,
  'n': name,
});

/// The asker's signature as it travels (`sg` in a frame): the device
/// certificate (`d`), the signature (`s`), the asker's own address (`a`),
/// the target (`y`) and the asker's own name (`n`). `null` for anything
/// malformed.
Map<String, dynamic>? introProofFromJson(Object? json) {
  if (json is! Map) {
    return null;
  }
  final DeviceCertificate? cert = DeviceCertificate.fromJson(json['d']);
  final Object? s = json['s'];
  final Object? a = json['a'];
  final Object? y = json['y'];
  final Object? n = json['n'];
  if (cert == null ||
      s is! String ||
      s.length > 200 ||
      a is! String ||
      !_introAddress.hasMatch(a) ||
      y is! String ||
      !_introAddress.hasMatch(y) ||
      n is! String ||
      n.length > 200) {
    return null;
  }
  return <String, dynamic>{'d': cert.toJson(), 's': s, 'a': a, 'y': y, 'n': n};
}

/// What a case is about (§24.1).
enum IntroKind {
  /// X asks F to introduce them to Y.
  intro,

  /// One letter from X to Y, passed on by F.
  letter,

  /// X asks F to see F's friend list.
  list;

  static IntroKind? byName(Object? name) =>
      IntroKind.values.where((IntroKind k) => k.name == name).firstOrNull;
}

/// This phone's part in a case.
enum IntroRole {
  /// This person asked (X).
  asker,

  /// It goes through this person, who decides (F).
  middle,

  /// It is for this person (Y).
  target;

  static IntroRole? byName(Object? name) =>
      IntroRole.values.where((IntroRole r) => r.name == name).firstOrNull;
}

enum IntroStatus {
  /// Waiting: for this person's decision (middle, target) or for others
  /// (asker).
  open,

  /// The middle friend passed it on.
  forwarded,

  /// Accepted: a friend request is on its way (or the list is visible).
  accepted,

  /// Declined by the middle friend.
  declined,

  /// Declined or ignored by the one it was for. The asker is not told.
  refused;

  static IntroStatus? byName(Object? name) =>
      IntroStatus.values.where((IntroStatus s) => s.name == name).firstOrNull;
}

/// One introduction, letter or friend-list request as this phone sees it.
/// Addresses are normalised; '' stands for this person.
final class IntroCase {
  IntroCase({
    required this.id,
    required this.kind,
    required this.role,
    required this.at,
    this.asker = '',
    this.askerName = '',
    this.middle = '',
    this.target = '',
    this.targetName = '',
    this.text = '',
    this.note = '',
    this.status = IntroStatus.open,
    int? changedAt,
    this.befriendDue = false,
    this.proof,
    this.signed = false,
  }) : changedAt = changedAt ?? at;

  final String id;
  final IntroKind kind;
  final IntroRole role;
  final int at;

  /// X, who asked.
  final String asker;

  /// X's name as the middle friend gave it (for Y, who does not know X).
  final String askerName;

  /// F, through whom it goes.
  final String middle;

  /// Y, whom it is for ('' for a friend list).
  final String target;

  /// Y's name from F's friend list (for X).
  final String targetName;

  /// X's note, or the letter.
  final String text;

  /// F's note to Y.
  String note;

  IntroStatus status;
  int changedAt;

  /// A friend request still has to be made here (the answer came while the
  /// app was away).
  bool befriendDue;

  /// The asker's signature ([introProofFromJson]) the middle friend keeps
  /// to pass on with the case.
  final Map<String, dynamic>? proof;

  /// For this person (target): the asker's signature checked out, so the
  /// words, the kind and the asker's address and name are theirs. `false`
  /// for a case from an older app (no signature) or under an address the
  /// signature does not cover: shown as unverified.
  final bool signed;

  bool get isOpen => status == IntroStatus.open;

  /// Waits for this person's decision.
  bool get needsMe => isOpen && role != IntroRole.asker;

  /// Still going: nobody said no and it is not done.
  bool get isPending =>
      status == IntroStatus.open || status == IntroStatus.forwarded;

  bool aliveAt(int now) => now - at < kIntroLife.inMilliseconds;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'k': kind.name,
    'r': role.name,
    'at': at,
    if (asker.isNotEmpty) 'x': asker,
    if (askerName.isNotEmpty) 'xn': askerName,
    if (middle.isNotEmpty) 'f': middle,
    if (target.isNotEmpty) 'y': target,
    if (targetName.isNotEmpty) 'yn': targetName,
    if (text.isNotEmpty) 't': text,
    if (note.isNotEmpty) 'm': note,
    's': status.name,
    'ch': changedAt,
    if (befriendDue) 'bf': true,
    if (proof != null) 'sg': proof,
    if (signed) 'sd': true,
  };

  static String _address(Object? v) =>
      v is String && _introAddress.hasMatch(v) ? v : '';

  static IntroCase? fromJson(Object? json) {
    if (json is! Map) {
      return null;
    }
    final Object? id = json['id'];
    final IntroKind? kind = IntroKind.byName(json['k']);
    final IntroRole? role = IntroRole.byName(json['r']);
    final IntroStatus? status = IntroStatus.byName(json['s']);
    final Object? at = json['at'];
    if (id is! String ||
        !_introId.hasMatch(id) ||
        kind == null ||
        role == null ||
        status == null ||
        at is! int) {
      return null;
    }
    final Object? xn = json['xn'];
    final Object? yn = json['yn'];
    final Object? ch = json['ch'];
    return IntroCase(
      id: id,
      kind: kind,
      role: role,
      at: at,
      asker: _address(json['x']),
      askerName: sanitizePeerName(xn is String ? xn : null),
      middle: _address(json['f']),
      target: _address(json['y']),
      targetName: sanitizePeerName(yn is String ? yn : null),
      text: introText(
        json['t'],
        kind == IntroKind.letter ? kLetterMaxChars : kIntroNoteMaxChars,
      ),
      note: introText(json['m'], kIntroNoteMaxChars),
      status: status,
      changedAt: ch is int ? ch : at,
      befriendDue: json['bf'] == true,
      proof: introProofFromJson(json['sg']),
      signed: json['sd'] == true,
    );
  }
}

/// What the contact economy needs from the friends list beyond
/// [EventHost]. Only the app has it; the background service leaves it out
/// and the friend requests are made when the app opens.
abstract interface class IntroFriending {
  bool isBlocked(String address);

  /// Sends [address] a friend request, or accepts theirs.
  Future<void> befriend(
    String address, {
    required String name,
    required String note,
  });
}

/// The contact economy without money (§24.1): consent is the currency.
///
/// - X asks a friend F to see F's friend list; F decides (or their setting
///   does, see [FriendListAudience]) and can take it back.
/// - X asks F for an introduction to Y (F's friend). F passes it on with
///   a note, or not; Y accepts or declines. On yes both send each other a
///   friend request, which meet and become a friendship.
/// - X sends Y one letter through F: F's phone passes it on within limits
///   ([kLettersPerWeek] per sender, [kLettersRelayedPerWeek] in all), and
///   Y can only accept (a friend request) or ignore it.
///
/// Every frame goes between accepted friends; Y never learns X's address
/// from anyone but F, and X never learns that Y said no.
final class IntroService extends ChangeNotifier {
  IntroService({
    required this.host,
    required this.disk,
    required this.meet,
    this.friending,
    int Function()? now,
    Random? random,
  }) : _now = now ?? (() => DateTime.now().millisecondsSinceEpoch),
       _random = random ?? Random.secure();

  final EventHost host;
  final LedgerDisk disk;

  /// Friend lists and who may see this person's (§24.1).
  final MeetService Function() meet;
  final IntroFriending? friending;
  final int Function() _now;
  final Random _random;
  static const String _key = 'meet/intros';

  final Map<String, IntroCase> _cases = <String, IntroCase>{};

  /// Letters this phone passed on: who sent them and when.
  final List<(String, int)> _relayed = <(String, int)>[];

  bool _relayLetters = true;

  /// Requests and passed-on cases taken per friend (flood guard, a day).
  final Map<String, List<int>> _asksFrom = <String, List<int>>{};
  final Map<String, List<int>> _forwardsFrom = <String, List<int>>{};

  /// The store could not be read: nothing is written until it can.
  bool _diskUnreadable = false;
  Future<void>? _loading;

  /// This installation's ledger identity (device key and certificate) for
  /// signing what this person asks; read from the store when first needed.
  LedgerIdentity? _identity;

  int get now => _now();

  /// Whether this phone passes friends' letters on to its friends.
  bool get relayLetters => _relayLetters;

  String _n(String a) => PeerShareCodec.normalizeAddress(a);

  String _address(Object? v) =>
      v is String && _introAddress.hasMatch(v) ? _n(v) : '';

  bool _isSelf(String address) {
    final String own = host.ownAddress();
    return own.isNotEmpty && PeerShareCodec.addressesEqual(own, address);
  }

  List<IntroCase> _sorted(bool Function(IntroCase c) where) {
    final int t = _now();
    return _cases.values
        .where((IntroCase c) => where(c) && c.aliveAt(t))
        .toList()
      ..sort((IntroCase a, IntroCase b) => b.changedAt.compareTo(a.changedAt));
  }

  /// Waiting for this person's decision, newest first.
  List<IntroCase> get needsMe => _sorted((IntroCase c) => c.needsMe);

  /// What this person asked for, newest first.
  List<IntroCase> get mine =>
      _sorted((IntroCase c) => c.role == IntroRole.asker);

  /// What went through this person or was for them, decided, newest first.
  List<IntroCase> get handled =>
      _sorted((IntroCase c) => c.role != IntroRole.asker && !c.isOpen);

  IntroCase? caseOf(String id) => _cases[id];

  /// This person's request of [kind] to [middle] (about [target]) that is
  /// still going.
  IntroCase? pending(IntroKind kind, String middle, {String target = ''}) {
    final String f = _n(middle);
    final String y = target.isEmpty ? '' : _n(target);
    final int t = _now();
    for (final IntroCase c in _cases.values) {
      if (c.role == IntroRole.asker &&
          c.kind == kind &&
          c.middle == f &&
          c.target == y &&
          c.isPending &&
          c.aliveAt(t)) {
        return c;
      }
    }
    return null;
  }

  /// Letters this person may still send through [middle] this week.
  int lettersLeft(String middle) {
    final String f = _n(middle);
    final int t = _now();
    final int sent = _cases.values
        .where(
          (IntroCase c) =>
              c.role == IntroRole.asker &&
              c.kind == IntroKind.letter &&
              c.middle == f &&
              t - c.at < _week,
        )
        .length;
    return max(0, kLettersPerWeek - sent);
  }

  // ---- store ----

  /// Reads the cases (again: the background service may have written).
  Future<void> load() => _loading = _read();

  Future<void> _ready() => _loading ?? load();

  Future<void> _read() async {
    try {
      _diskUnreadable = true;
      final List<int>? raw = await disk.read(_key);
      final Object? json = raw == null ? null : jsonDecode(utf8.decode(raw));
      if (json != null && (json is! Map || json['v'] != 1)) {
        // A newer app's file (or damage): never written over.
        logZenWarning('Przedstawienia: nieznany zapis');
        return;
      }
      _cases.clear();
      _relayed.clear();
      _relayLetters = true;
      if (json is Map) {
        final Object? cases = json['cases'];
        if (cases is List) {
          for (final Object? item in cases.take(kIntroMaxCases)) {
            final IntroCase? c = IntroCase.fromJson(item);
            if (c != null) {
              _cases[c.id] = c;
            }
          }
        }
        final Object? relayed = json['relayed'];
        if (relayed is List) {
          for (final Object? r in relayed.take(kLettersRelayedPerWeek * 4)) {
            if (r is List && r.length == 2 && r[0] is String && r[1] is int) {
              _relayed.add((r[0] as String, r[1] as int));
            }
          }
        }
        _relayLetters = json['relay'] != false;
      }
      _diskUnreadable = false;
      notifyListeners();
    } on Object catch (error, stack) {
      logZenError('Odczyt przedstawień', error, stack);
    }
  }

  Future<void> _save() async {
    if (_diskUnreadable) {
      notifyListeners();
      return;
    }
    final int t = _now();
    _cases.removeWhere((String _, IntroCase c) => !c.aliveAt(t));
    _relayed.removeWhere(((String, int) r) => t - r.$2 > _week);
    final int over = _cases.length - kIntroMaxCases;
    if (over > 0) {
      // Decided ones go first, oldest first.
      final List<IntroCase> old = _cases.values.toList()
        ..sort((IntroCase a, IntroCase b) {
          if (a.isOpen != b.isOpen) {
            return a.isOpen ? 1 : -1;
          }
          return a.changedAt.compareTo(b.changedAt);
        });
      for (final IntroCase c in old.take(over)) {
        _cases.remove(c.id);
      }
    }
    await disk.write(
      _key,
      utf8.encode(
        jsonEncode(<String, dynamic>{
          'v': 1,
          'cases': <Map<String, dynamic>>[
            for (final IntroCase c in _cases.values) c.toJson(),
          ],
          'relayed': <List<Object>>[
            for (final (String, int) r in _relayed) <Object>[r.$1, r.$2],
          ],
          if (!_relayLetters) 'relay': false,
        }),
      ),
    );
    notifyListeners();
  }

  String _newId() => List<String>.generate(
    14,
    (_) => _random.nextInt(36).toRadixString(36),
  ).join();

  // ---- this person asks (X) ----

  /// Asks [middle] (a friend) to introduce this person to [target], one of
  /// their friends. Returns the case (the one already going, if any), or
  /// `null` when it cannot be asked.
  Future<IntroCase?> askIntro({
    required String middle,
    required String target,
    required String targetName,
    String note = '',
  }) async {
    await _ready();
    final IntroCase? had = pending(IntroKind.intro, middle, target: target);
    if (had != null) {
      return had;
    }
    return _askAbout(
      IntroKind.intro,
      middle,
      target,
      targetName,
      introText(note, kIntroNoteMaxChars),
    );
  }

  /// Sends [target] one letter through [middle] (a friend who knows them).
  /// Returns `null` when it cannot go (empty, or no letters left this week
  /// through [middle]).
  Future<IntroCase?> sendLetter({
    required String middle,
    required String target,
    required String targetName,
    required String text,
  }) async {
    await _ready();
    final String body = introText(text, kLetterMaxChars);
    if (body.isEmpty || lettersLeft(middle) <= 0) {
      return null;
    }
    return _askAbout(IntroKind.letter, middle, target, targetName, body);
  }

  Future<IntroCase?> _askAbout(
    IntroKind kind,
    String middle,
    String target,
    String targetName,
    String text,
  ) async {
    final String f = _n(middle);
    final String y = _address(target);
    if (!host.isFriend(f) ||
        y.isEmpty ||
        y == f ||
        _isSelf(y) ||
        host.isFriend(y)) {
      return null;
    }
    final IntroCase c = IntroCase(
      id: _newId(),
      kind: kind,
      role: IntroRole.asker,
      at: _now(),
      middle: f,
      target: y,
      targetName: sanitizePeerName(targetName),
      text: text,
    );
    _cases[c.id] = c;
    await _save();
    final Map<String, dynamic>? proof = await _sign(c);
    await _send(f, <String, dynamic>{
      'type': IntroTypes.ask,
      'id': c.id,
      'k': kind.name,
      'a': y,
      if (text.isNotEmpty) 't': text,
      'sg': ?proof,
    });
    return c;
  }

  /// This person's signature on [c] ([introSignedBytes]) with the device
  /// key, for the one it is for to check; `null` before the ledger made
  /// the keys (the case then goes unsigned, as from an older app).
  Future<Map<String, dynamic>?> _sign(IntroCase c) async {
    final String own = host.ownAddress();
    if (own.isEmpty) {
      return null;
    }
    try {
      final LedgerIdentity? me = _identity ??= await LedgerIdentity.read(disk);
      if (me == null) {
        return null;
      }
      final String asker = _n(own);
      final String name = sanitizePeerName(host.ownName());
      final Uint8List sig = await me.deviceKey.sign(
        introSignedBytes(
          id: c.id,
          kind: c.kind,
          asker: asker,
          target: c.target,
          text: c.text,
          name: name,
        ),
      );
      return <String, dynamic>{
        'd': me.certificate.toJson(),
        's': b64(sig),
        'a': asker,
        'y': c.target,
        'n': name,
      };
    } on Object catch (error, stack) {
      logZenError('Przedstawienia: podpis', error, stack);
      return null;
    }
  }

  /// Checks the asker's signature ([proof], as the middle friend passed it
  /// on) over what came, with the asker's own name:
  ///  - `true`: signed by the device in its certificate, for this very
  ///    case, its words, from [asker] to this person;
  ///  - `false` (dropped): malformed, not matching what came, or signed
  ///    for someone else;
  ///  - `null` (shown as unverified): no signature (an older app on the
  ///    way), or a sound one from another address than [asker] — the
  ///    middle friend knows the asker by the address of another of their
  ///    devices (§6), which this phone cannot tell from a swapped one.
  Future<({bool? valid, String name})> _checkSigned(
    Object? proof, {
    required String id,
    required IntroKind kind,
    required String asker,
    required String text,
  }) async {
    if (proof == null) {
      return (valid: null, name: '');
    }
    final Map<String, dynamic>? p = introProofFromJson(proof);
    if (p == null) {
      return (valid: false, name: '');
    }
    final String signedAsker = p['a'] as String;
    final String target = p['y'] as String;
    final String own = host.ownAddress();
    if (own.isNotEmpty && !PeerShareCodec.addressesEqual(own, target)) {
      // Signed for someone else: passed on to the wrong person.
      return (valid: false, name: '');
    }
    final DeviceCertificate cert = DeviceCertificate.fromJson(p['d'])!;
    final String name = p['n'] as String;
    final bool sound =
        await cert.verify() &&
        await verifyLedgerSignature(
          publicKey: cert.device,
          message: introSignedBytes(
            id: id,
            kind: kind,
            asker: signedAsker,
            target: target,
            text: text,
            name: name,
          ),
          signature: p['s'] as String,
        );
    if (!sound) {
      return (valid: false, name: '');
    }
    if (!PeerShareCodec.addressesEqual(signedAsker, asker)) {
      return (valid: null, name: '');
    }
    return (valid: true, name: name);
  }

  /// Asks [friend] to see their friend list. Returns the case (the one
  /// already going, if any), or `null` for someone who is not a friend.
  Future<IntroCase?> askList(String friend) async {
    await _ready();
    final String f = _n(friend);
    if (!host.isFriend(f)) {
      return null;
    }
    final IntroCase? had = pending(IntroKind.list, f);
    if (had != null) {
      return had;
    }
    final IntroCase c = IntroCase(
      id: _newId(),
      kind: IntroKind.list,
      role: IntroRole.asker,
      at: _now(),
      middle: f,
    );
    _cases[c.id] = c;
    await _save();
    await _send(f, <String, dynamic>{
      'type': IntroTypes.ask,
      'id': c.id,
      'k': IntroKind.list.name,
    });
    return c;
  }

  /// Removes a case from this phone's list (only one that is not waiting
  /// for this person).
  Future<void> forget(String id) async {
    await _ready();
    final IntroCase? c = _cases[id];
    if (c == null || c.needsMe) {
      return;
    }
    _cases.remove(id);
    await _save();
  }

  Future<void> setRelayLetters(bool on) async {
    await _ready();
    _relayLetters = on;
    await _save();
  }

  // ---- in the middle (F) ----

  IntroCase? _mineToDecide(String id, IntroRole role) {
    final IntroCase? c = _cases[id];
    return c != null && c.role == role && c.isOpen ? c : null;
  }

  /// Passes introduction [id] on to the one it is for, with this person's
  /// [note].
  Future<bool> forward(String id, {String note = ''}) async {
    await _ready();
    final IntroCase? c = _mineToDecide(id, IntroRole.middle);
    if (c == null || c.kind != IntroKind.intro || !host.isFriend(c.target)) {
      return false;
    }
    c
      ..note = introText(note, kIntroNoteMaxChars)
      ..status = IntroStatus.forwarded
      ..changedAt = _now();
    await _save();
    await _sendForward(c);
    await _result(c.asker, c.id, 'fwd');
    return true;
  }

  /// Declines request [id] (an introduction or the friend list).
  Future<bool> decline(String id) async {
    await _ready();
    final IntroCase? c = _mineToDecide(id, IntroRole.middle);
    if (c == null) {
      return false;
    }
    c
      ..status = IntroStatus.declined
      ..changedAt = _now();
    await _save();
    await _result(c.asker, c.id, 'no');
    return true;
  }

  /// Lets the friend who asked ([id]) see this person's friend list; it can
  /// be taken back later (`MeetService.allowFriendList`).
  Future<bool> approveList(String id) async {
    await _ready();
    final IntroCase? c = _mineToDecide(id, IntroRole.middle);
    if (c == null || c.kind != IntroKind.list || !host.isFriend(c.asker)) {
      return false;
    }
    c
      ..status = IntroStatus.accepted
      ..changedAt = _now();
    await _save();
    await meet().allowFriendList(c.asker, allow: true);
    await _result(c.asker, c.id, 'ok');
    return true;
  }

  // ---- for this person (Y) ----

  /// Accepts introduction or letter [id]: a friend request goes to the one
  /// who asked, and the middle friend tells them.
  Future<bool> accept(String id) async {
    await _ready();
    final IntroCase? c = _mineToDecide(id, IntroRole.target);
    if (c == null) {
      return false;
    }
    c
      ..status = IntroStatus.accepted
      ..changedAt = _now()
      ..befriendDue = true;
    await _save();
    await _befriend(c);
    await _send(c.middle, <String, dynamic>{
      'type': IntroTypes.answer,
      'id': c.id,
      'ok': true,
    });
    return true;
  }

  /// Declines (or, for a letter, ignores) [id]. Only the middle friend
  /// learns it; the one who asked does not.
  Future<bool> refuse(String id) async {
    await _ready();
    final IntroCase? c = _mineToDecide(id, IntroRole.target);
    if (c == null) {
      return false;
    }
    c
      ..status = IntroStatus.refused
      ..changedAt = _now();
    await _save();
    await _send(c.middle, <String, dynamic>{
      'type': IntroTypes.answer,
      'id': c.id,
      'ok': false,
    });
    return true;
  }

  /// Makes the friend requests still due here (answers that came while the
  /// app was away).
  Future<void> settle() async {
    if (friending == null) {
      return;
    }
    await _ready();
    final List<IntroCase> due = _cases.values
        .where((IntroCase x) => x.befriendDue)
        .toList();
    for (final IntroCase c in due) {
      await _befriend(c);
    }
  }

  Future<void> _befriend(IntroCase c) async {
    final IntroFriending? f = friending;
    if (f == null || !c.befriendDue) {
      return;
    }
    final bool asked = c.role == IntroRole.asker;
    try {
      await f.befriend(
        asked ? c.target : c.asker,
        name: asked ? c.targetName : c.askerName,
        note: t('Poznaliśmy się przez: {name}', {
          'name': host.nameOf(c.middle),
        }),
      );
      c.befriendDue = false;
      await _save();
    } on Object catch (error, stack) {
      logZenError('Przedstawienie: zaproszenie', error, stack);
    }
  }

  // ---- incoming ----

  /// Handles a frame of one of [IntroTypes]. Returns whether it was one.
  Future<bool> handle(SignalTransportFrame frame) async {
    final Object? type = frame.payload['type'];
    if (type is! String || !IntroTypes.all.contains(type)) {
      return false;
    }
    final String from = _n(frame.from);
    // Only accepted friends: a letter travels friend to friend at each step.
    if (!host.isFriend(from) || _tooBig(frame.payload)) {
      return true;
    }
    try {
      await _ready();
      switch (type) {
        case IntroTypes.ask:
          await _onAsk(from, frame.payload);
        case IntroTypes.forward:
          await _onForward(from, frame.payload);
        case IntroTypes.answer:
          await _onAnswer(from, frame.payload);
        case IntroTypes.result:
          await _onResult(from, frame.payload);
      }
    } on Object catch (error, stack) {
      logZenError('Przedstawienia: $type', error, stack);
    }
    return true;
  }

  static bool _tooBig(Map<String, dynamic> p) =>
      p.values.any((Object? v) => v is String && v.length > _maxRawField);

  bool _take(Map<String, List<int>> log, String who, int limit) {
    final int t = _now();
    final List<int> recent = (log[who] ??= <int>[])
      ..removeWhere((int at) => t - at > _day);
    if (recent.length >= limit) {
      return false;
    }
    recent.add(t);
    return true;
  }

  bool _letterAllowed(String from) {
    final int t = _now();
    final List<(String, int)> week = <(String, int)>[
      for (final (String, int) r in _relayed)
        if (t - r.$2 < _week) r,
    ];
    return week.length < kLettersRelayedPerWeek &&
        week.where(((String, int) r) => r.$1 == from).length < kLettersPerWeek;
  }

  /// X (a friend) asks this person (F).
  Future<void> _onAsk(String from, Map<String, dynamic> p) async {
    final Object? id = p['id'];
    final IntroKind? kind = IntroKind.byName(p['k']);
    if (id is! String ||
        !_introId.hasMatch(id) ||
        kind == null ||
        _cases.containsKey(id) ||
        !_take(_asksFrom, from, kIntroAsksPerFriendPerDay)) {
      return;
    }
    if (kind == IntroKind.list) {
      await _onListAsk(from, id);
      return;
    }
    final String target = _address(p['a']);
    final String text = introText(
      p['t'],
      kind == IntroKind.letter ? kLetterMaxChars : kIntroNoteMaxChars,
    );
    if (target.isEmpty ||
        target == from ||
        _isSelf(target) ||
        !host.isFriend(target) ||
        (kind == IntroKind.letter && text.isEmpty)) {
      await _result(from, id, 'no');
      return;
    }
    final IntroCase c = IntroCase(
      id: id,
      kind: kind,
      role: IntroRole.middle,
      at: _now(),
      asker: from,
      target: target,
      text: text,
      // Passed on as it came: only the one it is for can check it.
      proof: introProofFromJson(p['sg']),
    );
    if (kind == IntroKind.letter) {
      if (!_relayLetters || !_letterAllowed(from)) {
        await _result(from, id, 'no');
        return;
      }
      _relayed.add((from, _now()));
      c.status = IntroStatus.forwarded;
      _cases[id] = c;
      await _save();
      await _sendForward(c);
      await _result(from, id, 'fwd');
      return;
    }
    final bool asking = _cases.values.any(
      (IntroCase o) =>
          o.role == IntroRole.middle &&
          o.isOpen &&
          o.asker == from &&
          o.target == target,
    );
    if (asking || needsMe.length >= kIntroMaxOpen) {
      return;
    }
    _cases[id] = c;
    await _save();
    await _tell(
      '$id-ask',
      t('{name} prosi o przedstawienie', {'name': host.nameOf(from)}),
      t('Komu: {name}', {'name': host.nameOf(target)}) +
          (text.isEmpty ? '' : ' — $text'),
    );
  }

  /// X asks to see this person's friend list.
  Future<void> _onListAsk(String from, String id) async {
    final MeetService m = meet();
    switch (m.book.friendListAudience) {
      case FriendListAudience.all:
        await m.resendFriendList(from);
        await _result(from, id, 'ok');
      case FriendListAudience.nobody:
        await _result(from, id, 'no');
      // A weak acquaintance asks like everybody does "on request" (§8).
      case FriendListAudience.onRequest || FriendListAudience.friends:
        if (m.friendListVisibleTo(from)) {
          await m.resendFriendList(from);
          await _result(from, id, 'ok');
          return;
        }
        final bool asking = _cases.values.any(
          (IntroCase o) =>
              o.role == IntroRole.middle &&
              o.kind == IntroKind.list &&
              o.isOpen &&
              o.asker == from,
        );
        if (asking || needsMe.length >= kIntroMaxOpen) {
          return;
        }
        _cases[id] = IntroCase(
          id: id,
          kind: IntroKind.list,
          role: IntroRole.middle,
          at: _now(),
          asker: from,
        );
        await _save();
        await _tell(
          '$id-list',
          t('{name} prosi o Twoją listę znajomych', {
            'name': host.nameOf(from),
          }),
          t('Zdecyduj w Skrzynce. Zgodę możesz potem cofnąć.'),
        );
    }
  }

  /// F (a friend) passes on an introduction or a letter to this person (Y).
  Future<void> _onForward(String from, Map<String, dynamic> p) async {
    final Object? id = p['id'];
    final IntroKind? kind = IntroKind.byName(p['k']);
    if (id is! String ||
        !_introId.hasMatch(id) ||
        kind == null ||
        kind == IntroKind.list ||
        _cases.containsKey(id)) {
      return;
    }
    final String asker = _address(p['a']);
    if (asker.isEmpty ||
        asker == from ||
        _isSelf(asker) ||
        (friending?.isBlocked(asker) ?? false)) {
      return;
    }
    if (host.isFriend(asker)) {
      // Already friends: nothing to decide.
      await _send(from, <String, dynamic>{
        'type': IntroTypes.answer,
        'id': id,
        'ok': true,
      });
      return;
    }
    final String text = introText(
      p['t'],
      kind == IntroKind.letter ? kLetterMaxChars : kIntroNoteMaxChars,
    );
    final bool waiting = _cases.values.any(
      (IntroCase o) =>
          o.role == IntroRole.target && o.isOpen && o.asker == asker,
    );
    if ((kind == IntroKind.letter && text.isEmpty) ||
        waiting ||
        needsMe.length >= kIntroMaxOpen ||
        !_take(_forwardsFrom, from, kIntroForwardsPerFriendPerDay)) {
      return;
    }
    // The asker's signature (S-17): the middle friend may not change the
    // words, the address or the name. A case without one comes from an
    // older app and is shown marked as unverified; a broken one is dropped.
    final ({bool? valid, String name}) check = await _checkSigned(
      p['sg'],
      id: id,
      kind: kind,
      asker: asker,
      text: text,
    );
    if (check.valid == false || _cases.containsKey(id)) {
      if (check.valid == false) {
        logZenWarning('Przedstawienia: podpis nadawcy się nie zgadza');
      }
      return;
    }
    final bool signed = check.valid == true;
    final Object? n = p['n'];
    final String signedName = sanitizePeerName(check.name);
    final String name = signedName.isNotEmpty
        ? signedName
        : sanitizePeerName(n is String ? n : null);
    final IntroCase c = IntroCase(
      id: id,
      kind: kind,
      role: IntroRole.target,
      at: _now(),
      asker: asker,
      askerName: name.isEmpty ? t('Ktoś') : name,
      middle: from,
      text: text,
      note: kind == IntroKind.intro
          ? introText(p['m'], kIntroNoteMaxChars)
          : '',
      signed: signed,
    );
    _cases[id] = c;
    await _save();
    final String via = host.nameOf(from);
    final String body;
    final String title;
    if (kind == IntroKind.intro) {
      title = t('{via} przedstawia Ci: {name}', {
        'via': via,
        'name': c.askerName,
      });
      body = c.note.isNotEmpty
          ? c.note
          : c.text.isNotEmpty
          ? c.text
          : t('Przyjmij albo odrzuć w Skrzynce.');
    } else {
      title = t('List od: {name} (przez: {via})', {
        'name': c.askerName,
        'via': via,
      });
      body = c.text;
    }
    await _tell(
      '$id-fwd',
      title,
      signed ? body : '${introUnverifiedLabel()}\n$body',
    );
  }

  /// Y (a friend) answers what this person (F) passed on.
  Future<void> _onAnswer(String from, Map<String, dynamic> p) async {
    final Object? id = p['id'];
    final IntroCase? c = id is String ? _cases[id] : null;
    if (c == null ||
        c.role != IntroRole.middle ||
        c.kind == IntroKind.list ||
        c.status != IntroStatus.forwarded ||
        c.target != from) {
      return;
    }
    final bool ok = p['ok'] == true;
    c
      ..status = ok ? IntroStatus.accepted : IntroStatus.refused
      ..changedAt = _now();
    await _save();
    if (!ok) {
      return;
    }
    await _result(c.asker, c.id, 'ok');
    if (c.kind == IntroKind.intro) {
      await _tell(
        '${c.id}-done',
        t('Przedstawienie przyjęte'),
        t('{name} i {other} zapraszają się do znajomych.', {
          'name': host.nameOf(from),
          'other': host.nameOf(c.asker),
        }),
      );
    }
  }

  /// F (a friend) tells this person (X) how their request went.
  Future<void> _onResult(String from, Map<String, dynamic> p) async {
    final Object? id = p['id'];
    final IntroCase? c = id is String ? _cases[id] : null;
    if (c == null || c.role != IntroRole.asker || c.middle != from) {
      return;
    }
    final String via = host.nameOf(from);
    final String title;
    final String body;
    switch (p['s']) {
      case 'fwd':
        if (c.status != IntroStatus.open || c.kind == IntroKind.list) {
          return;
        }
        c.status = IntroStatus.forwarded;
        title = c.kind == IntroKind.letter
            ? t('List poszedł dalej')
            : t('Prośba przekazana');
        body = t('Przez: {via}. Teraz decyduje: {name}.', {
          'via': via,
          'name': c.targetName,
        });
      case 'no':
        if (c.status != IntroStatus.open) {
          return;
        }
        c.status = IntroStatus.declined;
        title = switch (c.kind) {
          IntroKind.list => t('Lista znajomych niedostępna'),
          IntroKind.intro => t('Bez przedstawienia'),
          IntroKind.letter => t('List nie poszedł'),
        };
        body = switch (c.kind) {
          IntroKind.list => t('{via} nie pokazuje teraz swojej listy.', {
            'via': via,
          }),
          IntroKind.intro => t('{via} nie przekaże tej prośby.', {'via': via}),
          IntroKind.letter => t(
            '{via} nie przekazuje teraz listów albo skończył się limit '
            'na ten tydzień.',
            {'via': via},
          ),
        };
      case 'ok':
        if (!c.isPending) {
          return;
        }
        c.status = IntroStatus.accepted;
        c.befriendDue = c.kind != IntroKind.list;
        title = c.kind == IntroKind.list
            ? t('Widzisz listę znajomych: {via}', {'via': via})
            : t('Możecie się poznać: {name}', {'name': c.targetName});
        body = c.kind == IntroKind.list
            ? t('Ta lista pojawi się w Twoim grafie.')
            : t('Zaproszenie do znajomych idzie samo.');
      default:
        return;
    }
    c.changedAt = _now();
    await _save();
    await _befriend(c);
    await _tell('${c.id}-${c.status.name}', title, body);
  }

  Future<void> _sendForward(IntroCase c) => _send(c.target, <String, dynamic>{
    'type': IntroTypes.forward,
    'id': c.id,
    'k': c.kind.name,
    'a': c.asker,
    // X's own name (from their profile), never a nickname given here.
    'n': host.nameOf(c.asker),
    if (c.text.isNotEmpty) 't': c.text,
    if (c.note.isNotEmpty) 'm': c.note,
    // X's signature over all of it but this person's note (S-17).
    if (c.proof != null) 'sg': c.proof,
  });

  Future<void> _result(String to, String id, String status) => _send(
    to,
    <String, dynamic>{'type': IntroTypes.result, 'id': id, 's': status},
  );

  Future<void> _tell(String id, String title, String body) => host.notify(
    RuntimeSystemNotification(
      id: 'intro-$id',
      title: title,
      body: body,
      createdAtMillis: _now(),
      category: RuntimeSystemNotificationCategory.social,
      slotKey: 'intro',
    ),
  );

  Future<void> _send(String to, Map<String, dynamic> payload) async {
    try {
      await host.send(to, payload);
    } on Object catch (error) {
      logZenWarning('Przedstawienia: ${payload['type']} do $to: $error');
    }
  }
}
