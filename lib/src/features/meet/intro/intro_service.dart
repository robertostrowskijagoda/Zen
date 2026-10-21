import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/foundation.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/core/crypto/hybrid_signature.dart';
import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/core/ledger/ledger_codec.dart';
import 'package:zen/src/core/ledger/ledger_identity.dart';
import 'package:zen/src/core/logging/zen_log.dart';
import 'package:zen/src/features/ledger/ledger_identity_store.dart';
import 'package:zen/src/features/meet/events/event_service.dart';
import 'package:zen/src/features/meet/intro/gate_route.dart';
import 'package:zen/src/features/meet/intro/gate_terms.dart';
import 'package:zen/src/features/meet/meet_book.dart';
import 'package:zen/src/features/meet/meet_service.dart';
import 'package:zen/src/features/runtime/runtime_system_notifications.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';
import 'package:zen/src/features/social/friend_display_name.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';

/// Frames of the contact economy. Requests, introductions and gate terms
/// go between accepted friends (X → F → Y and back); a person introduced
/// through a gate may also ask the one they were introduced to for the
/// next gate, and answers and payments go back to whoever asked.
abstract final class IntroTypes {
  /// X asks a friend F: an introduction to Y (a gate), a letter for Y, or
  /// F's friend list.
  static const String ask = 'intro_ask';

  /// F passes an introduction or a letter on to Y.
  static const String forward = 'intro_fwd';

  /// Y tells F whether they accept.
  static const String answer = 'intro_ans';

  /// F tells X how it went (and Y tells X that the introduction came).
  static const String result = 'intro_res';

  /// A friend's gate terms for this person ([GateCard]).
  static const String gate = 'intro_gate';

  /// X tells a gatekeeper how the whole way ended: their payment is kept
  /// or returned.
  static const String end = 'intro_end';

  /// A payment for a first message, and the answer to it.
  static const String pay = 'intro_pay';
  static const String paid = 'intro_paid';

  static const Set<String> all = <String>{
    ask,
    forward,
    answer,
    result,
    gate,
    end,
    pay,
    paid,
  };
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

/// Payments for a first message taken from one person a day.
const int kIntroPaysPerDay = 5;

/// Cases waiting for this person's answer, at most.
const int kIntroMaxOpen = 50;

/// Cases kept at most.
const int kIntroMaxCases = 300;

/// Ways through gates and first-message payments kept at most.
const int kIntroMaxRuns = 50;
const int kIntroMaxMessagePays = 100;

/// Longest string field taken from a frame before it is even cleaned.
const int _maxRawField = 8000;

const int _day = 24 * 3600 * 1000;
const int _week = 7 * _day;

final RegExp _introId = RegExp(r'^[0-9a-z]{8,24}$');

/// A mesh address (as on friend lists).
final RegExp _introAddress = RegExp(r'^[0-9A-Za-z:._-]{1,64}$');

/// A pyramid payment's id as it travels.
final RegExp _paymentId = RegExp(r'^[0-9A-Za-z_-]{1,64}$');

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

/// What the asker signs with their device key: the case, their own
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
      !isHybridSignatureText(s) ||
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

/// What a case is about.
enum IntroKind {
  /// X asks F to introduce them to Y: to open the gate to F's friend.
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

  /// The middle friend passed it on: for an introduction, the gate is open.
  forwarded,

  /// Accepted: a friend request is on its way (or the list is visible).
  accepted,

  /// Declined by the middle friend (or the price was not paid).
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
    this.payment,
    this.price = 0,
    this.settleAt,
    this.settled = false,
    this.reached = false,
    this.waitPay = false,
    this.route,
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

  /// A paid gate: the payment put aside for the middle friend.
  final String? payment;

  /// A paid gate: its price (hundredths). For the asker of a gate that was
  /// not opened for lack of payment: the price the middle friend asks.
  int price;

  /// The middle friend keeps the payment from then on: set when the gate
  /// opens, tried again until the pyramid takes it.
  int? settleAt;

  /// The middle friend kept or returned the payment.
  bool settled;

  /// The asker heard from the one it is for: the introduction came, the
  /// asker may write to them and ask them for the next gate.
  bool reached;

  /// The middle friend waits for the payment to reach the pyramid here.
  bool waitPay;

  /// The asker's way through gates this case is a step of.
  final String? route;

  bool get isOpen => status == IntroStatus.open;

  /// Waits for this person's decision.
  bool get needsMe => isOpen && role != IntroRole.asker && !waitPay;

  /// Still going: nobody said no and it is not done.
  bool get isPending =>
      status == IntroStatus.open || status == IntroStatus.forwarded;

  /// A gate that is open: passed on by the middle friend.
  bool get isOpened =>
      status == IntroStatus.forwarded ||
      status == IntroStatus.accepted ||
      status == IntroStatus.refused;

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
    'pay': ?payment,
    if (price > 0) 'pr': price,
    'sa': ?settleAt,
    if (settled) 'sd': true,
    if (reached) 'rc': true,
    if (waitPay) 'wp': true,
    'ro': ?route,
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
    final Object? pay = json['pay'];
    final Object? pr = json['pr'];
    final Object? sa = json['sa'];
    final Object? ro = json['ro'];
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
      payment: pay is String && _paymentId.hasMatch(pay) ? pay : null,
      price: pr is int && pr > 0 && pr <= kGateMaxPrice ? pr : 0,
      settleAt: sa is int ? sa : null,
      settled: json['sd'] == true,
      reached: json['rc'] == true,
      waitPay: json['wp'] == true,
      route: ro is String && _introId.hasMatch(ro) ? ro : null,
    );
  }
}

/// Where a payment for a first message stands (the payer's side).
enum MessagePayState {
  /// Waiting for the pyramid's treasurers.
  paying,

  /// Sent; waiting for the other side's app.
  sent,

  /// Taken: this person may write first.
  ok,

  /// Not taken (the money comes back).
  failed;

  static MessagePayState byName(Object? name) => MessagePayState.values
      .firstWhere((MessagePayState s) => s.name == name, orElse: () => failed);
}

/// A payment for a first message to someone who is not a friend.
final class MessagePay {
  MessagePay({
    required this.payment,
    required this.price,
    required this.at,
    this.state = MessagePayState.paying,
  });

  final String payment;
  final int price;
  final int at;
  MessagePayState state;

  bool get going =>
      state == MessagePayState.paying || state == MessagePayState.sent;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'x': payment,
    'p': price,
    'at': at,
    's': state.name,
  };

  static MessagePay? fromJson(Object? json) {
    if (json is! Map ||
        json['x'] is! String ||
        json['p'] is! int ||
        json['at'] is! int) {
      return null;
    }
    return MessagePay(
      payment: json['x'] as String,
      price: json['p'] as int,
      at: json['at'] as int,
      state: MessagePayState.byName(json['s']),
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

/// The contact economy: consent, and within the pyramid points.
///
/// - X asks a friend F to see F's friend list; F decides (or their setting
///   does, see [FriendListAudience]) and can take it back.
/// - A gate: X asks F for an introduction to Y (F's friend). F's terms for
///   X decide ([GateSettings]): free or for a price in pyramid points, with
///   F's consent or opened by F's app at once. Y gets the introduction
///   (may write back, may befriend) and X may write to Y and ask Y for the
///   next gate. A payment waits in the pyramid and is F's only once the
///   gate opened — and the whole way X was opening, see [openWay].
/// - X sends Y one letter through F: F's phone passes it on within limits
///   ([kLettersPerWeek] per sender, [kLettersRelayedPerWeek] in all), and
///   Y can only accept (a friend request) or ignore it.
/// - X pays Y's price for a first message ([payToWrite]).
///
/// Y never learns X's address from anyone but F, and X never learns that
/// Y said no to a friendship.
final class IntroService extends ChangeNotifier {
  IntroService({
    required this.host,
    required this.disk,
    required this.meet,
    this.friending,
    this.wallet,
    this.passes,
    int Function()? now,
    Random? random,
  }) : _now = now ?? (() => DateTime.now().millisecondsSinceEpoch),
       _random = random ?? Random.secure();

  final EventHost host;
  final LedgerDisk disk;

  /// Friend lists and who may see this person's.
  final MeetService Function() meet;
  final IntroFriending? friending;

  /// The pyramid's points (null: only free gates and messages).
  final GateWallet? wallet;

  /// Who may start a conversation with whom outside friends.
  final ContactPasses? passes;
  final int Function() _now;
  final Random _random;
  static const String _key = 'meet/intros';

  final Map<String, IntroCase> _cases = <String, IntroCase>{};

  /// Letters this phone passed on: who sent them and when.
  final List<(String, int)> _relayed = <(String, int)>[];

  bool _relayLetters = true;

  /// This person's gate terms.
  GateSettings _gates = GateSettings();

  /// Friends' gate terms for this person, by friend.
  final Map<String, GateCard> _cards = <String, GateCard>{};

  /// What was last sent to each friend as their card (a digest).
  final Map<String, String> _cardsSent = <String, String>{};
  int _cardsAt = 0;

  /// Gatekeepers friends passed on, merged: address → their terms and
  /// friends. Built when first needed after the cards change.
  Map<String, ({GateTerms terms, Map<String, String> friends})>? _relayIndex;

  /// Ways through gates this person opens.
  final Map<String, GateRun> _runs = <String, GateRun>{};

  /// Payments this person made that may have to come back by themselves
  /// (once their time is over): id → since when.
  final Map<String, int> _refunds = <String, int>{};

  /// Payments for a first message, by the one written to.
  final Map<String, MessagePay> _messagePays = <String, MessagePay>{};

  /// Payments for a first message to this person, not in the pyramid yet:
  /// id → who paid and since when.
  final Map<String, (String, int)> _paysIn = <String, (String, int)>{};

  /// Requests and passed-on cases taken per friend (flood guard, a day).
  final Map<String, List<int>> _asksFrom = <String, List<int>>{};
  final Map<String, List<int>> _forwardsFrom = <String, List<int>>{};
  final Map<String, List<int>> _paysFrom = <String, List<int>>{};

  /// The store could not be read: nothing is written until it can.
  bool _diskUnreadable = false;
  Future<void>? _loading;

  /// This installation's ledger identity (device key and certificate) for
  /// signing what this person asks; read from the store when first needed.
  LedgerIdentity? _identity;

  /// The wallet's changes this service listens to.
  Listenable? _watched;
  bool _walletBusy = false;
  bool _walletAgain = false;
  bool _runsBusy = false;
  bool _runsAgain = false;
  bool _disposed = false;

  int get now => _now();

  /// Whether this phone passes friends' letters on to its friends.
  bool get relayLetters => _relayLetters;

  /// This person's gate terms (read only; change them with the setters).
  GateSettings get gates => _gates;

  String _n(String a) => PeerShareCodec.normalizeAddress(a);

  String _address(Object? v) =>
      v is String && _introAddress.hasMatch(v) ? _n(v) : '';

  bool _isSelf(String address) {
    final String own = host.ownAddress();
    return own.isNotEmpty && PeerShareCodec.addressesEqual(own, address);
  }

  List<IntroCase> _sorted(bool Function(IntroCase c) where) {
    final int ms = _now();
    return _cases.values
        .where((IntroCase c) => where(c) && c.aliveAt(ms))
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
    final int ms = _now();
    for (final IntroCase c in _cases.values) {
      if (c.role == IntroRole.asker &&
          c.kind == kind &&
          c.middle == f &&
          c.target == y &&
          c.isPending &&
          c.aliveAt(ms)) {
        return c;
      }
    }
    return null;
  }

  /// Letters this person may still send through [middle] this week.
  int lettersLeft(String middle) {
    final String f = _n(middle);
    final int ms = _now();
    final int sent = _cases.values
        .where(
          (IntroCase c) =>
              c.role == IntroRole.asker &&
              c.kind == IntroKind.letter &&
              c.middle == f &&
              ms - c.at < _week,
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
      _gates = GateSettings();
      _cards.clear();
      _cardsSent.clear();
      _relayIndex = null;
      _runs.clear();
      _refunds.clear();
      _messagePays.clear();
      _paysIn.clear();
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
        _readGates(json);
      }
      _diskUnreadable = false;
      notifyListeners();
    } on Object catch (error, stack) {
      logZenError('Odczyt przedstawień', error, stack);
    }
    _watchWallet();
  }

  void _readGates(Map<dynamic, dynamic> json) {
    _gates = GateSettings.fromJson(json['gates']);
    final Object? cards = json['cards'];
    if (cards is Map) {
      for (final MapEntry<dynamic, dynamic> e in cards.entries.take(2000)) {
        final GateCard? card = GateCard.fromJson(e.value);
        if (e.key is String && card != null) {
          _cards[_n(e.key as String)] = card;
        }
      }
    }
    final Object? sent = json['cs'];
    if (sent is Map) {
      for (final MapEntry<dynamic, dynamic> e in sent.entries.take(2000)) {
        if (e.key is String && e.value is String) {
          _cardsSent[e.key as String] = e.value as String;
        }
      }
    }
    final Object? runs = json['runs'];
    if (runs is List) {
      for (final Object? r in runs.take(kIntroMaxRuns)) {
        final GateRun? run = GateRun.fromJson(r);
        if (run != null) {
          _runs[run.id] = run;
        }
      }
    }
    final Object? refunds = json['rf'];
    if (refunds is Map) {
      for (final MapEntry<dynamic, dynamic> e in refunds.entries.take(200)) {
        if (e.key is String && e.value is int) {
          _refunds[e.key as String] = e.value as int;
        }
      }
    }
    final Object? pays = json['mp'];
    if (pays is Map) {
      for (final MapEntry<dynamic, dynamic> e in pays.entries.take(
        kIntroMaxMessagePays,
      )) {
        final MessagePay? p = MessagePay.fromJson(e.value);
        if (e.key is String && p != null) {
          _messagePays[e.key as String] = p;
        }
      }
    }
    final Object? paysIn = json['pi'];
    if (paysIn is Map) {
      for (final MapEntry<dynamic, dynamic> e in paysIn.entries.take(200)) {
        final Object? v = e.value;
        if (e.key is String &&
            v is List &&
            v.length == 2 &&
            v[0] is String &&
            v[1] is int) {
          _paysIn[e.key as String] = (v[0] as String, v[1] as int);
        }
      }
    }
  }

  Future<void> _save() async {
    if (_diskUnreadable) {
      _notify();
      return;
    }
    final int ms = _now();
    _cases.removeWhere((String _, IntroCase c) => !c.aliveAt(ms));
    _relayed.removeWhere(((String, int) r) => ms - r.$2 > _week);
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
    _trimRuns();
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
          'gates': _gates.toJson(),
          if (_cards.isNotEmpty)
            'cards': <String, dynamic>{
              for (final MapEntry<String, GateCard> e in _cards.entries)
                e.key: e.value.toJson(),
            },
          if (_cardsSent.isNotEmpty) 'cs': _cardsSent,
          if (_runs.isNotEmpty)
            'runs': <Map<String, dynamic>>[
              for (final GateRun r in _runs.values) r.toJson(),
            ],
          if (_refunds.isNotEmpty) 'rf': _refunds,
          if (_messagePays.isNotEmpty)
            'mp': <String, dynamic>{
              for (final MapEntry<String, MessagePay> e in _messagePays.entries)
                e.key: e.value.toJson(),
            },
          if (_paysIn.isNotEmpty)
            'pi': <String, dynamic>{
              for (final MapEntry<String, (String, int)> e in _paysIn.entries)
                e.key: <Object>[e.value.$1, e.value.$2],
            },
        }),
      ),
    );
    _notify();
  }

  void _notify() {
    if (!_disposed) {
      notifyListeners();
    }
  }

  void _trimRuns() {
    final int ms = _now();
    _runs.removeWhere(
      (String _, GateRun r) =>
          !r.going && ms - r.changedAt > kIntroLife.inMilliseconds,
    );
    while (_runs.length > kIntroMaxRuns) {
      final GateRun oldest = _runs.values.reduce(
        (GateRun a, GateRun b) => (a.going ? 1 : 0) != (b.going ? 1 : 0)
            ? (a.going ? b : a)
            : (a.changedAt <= b.changedAt ? a : b),
      );
      _runs.remove(oldest.id);
    }
    while (_messagePays.length > kIntroMaxMessagePays) {
      final String oldest = _messagePays.entries
          .reduce(
            (MapEntry<String, MessagePay> a, MapEntry<String, MessagePay> b) =>
                a.value.at <= b.value.at ? a : b,
          )
          .key;
      _messagePays.remove(oldest);
    }
  }

  String _newId() => List<String>.generate(
    14,
    (_) => _random.nextInt(36).toRadixString(36),
  ).join();

  @override
  void dispose() {
    _disposed = true;
    _watched?.removeListener(_onWallet);
    _watched = null;
    super.dispose();
  }

  // ---- this person asks (X) ----

  /// Asks [middle] (a friend) to introduce this person to [target], one of
  /// their friends: a free gate (a paid one goes through [openWay]).
  /// Returns the case (the one already going, if any), or `null` when it
  /// cannot be asked.
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
    String text, {
    String? payment,
    int price = 0,
    String? route,
  }) async {
    final String f = _n(middle);
    final String y = _address(target);
    // Through a friend; a gate also through someone a gate opened to.
    final bool through =
        host.isFriend(f) || (kind == IntroKind.intro && reachedPerson(f));
    if (!through || y.isEmpty || y == f || _isSelf(y) || host.isFriend(y)) {
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
      payment: payment,
      price: payment == null ? 0 : price,
      route: route,
    );
    // A case nobody can check is not sent.
    final Map<String, dynamic>? proof = await _sign(c);
    if (proof == null) {
      return null;
    }
    _cases[c.id] = c;
    await _save();
    await _send(f, <String, dynamic>{
      'type': IntroTypes.ask,
      'id': c.id,
      'k': kind.name,
      'a': y,
      if (text.isNotEmpty) 't': text,
      'sg': proof,
      'x': ?payment,
    });
    return c;
  }

  /// This person's signature on [c] ([introSignedBytes]) with the device
  /// key, for the one it is for to check; `null` before the ledger made
  /// the keys.
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
  ///  - `valid`: signed by the device in its certificate, for this very
  ///    case, its words, from [asker] to this person;
  ///  - not valid (dropped): missing, malformed, not matching what came,
  ///    signed for someone else or by another address than [asker].
  Future<({bool valid, String name})> _checkSigned(
    Object? proof, {
    required String id,
    required IntroKind kind,
    required String asker,
    required String text,
  }) async {
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
        await cert.verifyByDevice(
          introSignedBytes(
            id: id,
            kind: kind,
            asker: signedAsker,
            target: target,
            text: text,
            name: name,
          ),
          p['s'] as String,
        );
    if (!sound) {
      return (valid: false, name: '');
    }
    if (!PeerShareCodec.addressesEqual(signedAsker, asker)) {
      return (valid: false, name: '');
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
  /// for this person nor for a payment).
  Future<void> forget(String id) async {
    await _ready();
    final IntroCase? c = _cases[id];
    if (c == null ||
        c.needsMe ||
        c.waitPay ||
        (c.payment != null && !c.settled && c.role == IntroRole.middle)) {
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

  /// Whether a gate opened to [person]: they got this person's
  /// introduction (this person may write to them and ask them for the next
  /// gate).
  bool reachedPerson(String person) {
    final String p = _n(person);
    final int ms = _now();
    return _cases.values.any(
      (IntroCase c) =>
          c.role == IntroRole.asker &&
          c.kind == IntroKind.intro &&
          c.target == p &&
          (c.reached || c.status == IntroStatus.accepted) &&
          c.aliveAt(ms),
    );
  }

  /// Whether [person] was introduced to this person through a friend's
  /// gate (and this person did not say no): they may ask for the next gate.
  bool _introducedHere(String person) {
    final int ms = _now();
    return _cases.values.any(
      (IntroCase c) =>
          c.role == IntroRole.target &&
          c.kind == IntroKind.intro &&
          c.asker == person &&
          (c.status == IntroStatus.open || c.status == IntroStatus.accepted) &&
          c.aliveAt(ms),
    );
  }

  // ---- gates: this person's terms (F) ----

  /// The terms for everyone without their own.
  Future<void> setGateDefaults(GateTerms terms) async {
    await _ready();
    _gates.defaults = terms;
    await _save();
    await shareGates();
  }

  /// [friend]'s own terms; null: the terms for everyone again.
  Future<void> setGateFor(String friend, GateTerms? terms) async {
    await _ready();
    final String a = _n(friend);
    if (terms == null) {
      _gates.perFriend.remove(a);
    } else if (_gates.perFriend.length < kGateMaxExceptions ||
        _gates.perFriend.containsKey(a)) {
      _gates.perFriend[a] = terms;
    }
    await _save();
    await shareGates();
  }

  /// Whether friends may pass this person's terms and friend list on.
  Future<void> setGateRelay(bool on) async {
    await _ready();
    _gates.relay = on;
    await _save();
    await shareGates();
  }

  /// What [friend] told this person about their gates.
  GateCard? cardOf(String friend) => _cards[_n(friend)];

  /// Sends each friend this person's terms for them (only when they
  /// changed, unless [force]); with the gatekeepers among friends that
  /// allow passing on, to friends who see this person's list.
  Future<void> shareGates({bool force = false}) async {
    await _ready();
    if (_diskUnreadable) {
      return;
    }
    _cardsAt = _now();
    final Set<String> friends = <String>{
      for (final String f in host.friends()) _n(f),
    };
    if (friends.isEmpty) {
      // Friends not read yet: nothing is forgotten meanwhile.
      return;
    }
    bool changed = false;
    for (final String f in friends) {
      final Map<String, dynamic> card = _cardFor(f);
      final String digest = _digest(card);
      if (!force && _cardsSent[f] == digest) {
        continue;
      }
      _cardsSent[f] = digest;
      changed = true;
      await _send(f, <String, dynamic>{'type': IntroTypes.gate, ...card});
    }
    final int sent = _cardsSent.length;
    final int had = _cards.length;
    _cardsSent.removeWhere((String k, String _) => !friends.contains(k));
    _cards.removeWhere((String k, GateCard _) => !friends.contains(k));
    if (_cards.length != had) {
      _relayIndex = null;
    }
    if (changed || sent != _cardsSent.length || had != _cards.length) {
      await _save();
    }
  }

  static String _digest(Map<String, dynamic> card) => crypto.sha256
      .convert(utf8.encode(jsonEncode(card)))
      .toString()
      .substring(0, 24);

  /// This person's card for friend [q].
  Map<String, dynamic> _cardFor(String q) {
    final List<RelayedGate> relayed = <RelayedGate>[];
    MeetService? m;
    try {
      m = meet();
    } on Object {
      m = null;
    }
    // Passing a friend on tells [q] who this person's friends are: only to
    // those who see the list anyway.
    if (m != null && m.friendListVisibleTo(q)) {
      int budget = kGateRelayEntries;
      for (final String f in host.friends()) {
        final String g = _n(f);
        final GateCard? card = _cards[g];
        final GateTerms? open = card?.open;
        if (g == q || card == null || !card.relay || open == null) {
          continue;
        }
        if (budget <= 0) {
          break;
        }
        final List<RelayedGate> below = card.relayed
            .where((RelayedGate r) => r.address != q)
            .take(budget - 1)
            .toList();
        budget -= 1 + below.length;
        final Map<String, String> list = m.book.friendsOf(g);
        relayed.add(
          RelayedGate(
            address: g,
            terms: open,
            friends: <String, String>{
              for (final MapEntry<String, String> e in list.entries.take(
                kGateRelayList,
              ))
                e.key: e.value,
            },
            relayed: below,
          ),
        );
      }
    }
    return GateCard(
      terms: _gates.termsFor(q),
      relay: _gates.relay,
      open: _gates.relay ? _gates.defaults : null,
      relayed: relayed,
    ).toJson();
  }

  Future<void> _onGate(String from, Map<String, dynamic> p) async {
    final GateCard? card = GateCard.fromJson(p);
    if (card == null) {
      return;
    }
    final GateCard? had = _cards[from];
    if (had != null && jsonEncode(had.toJson()) == jsonEncode(card.toJson())) {
      return;
    }
    _cards[from] = card;
    _relayIndex = null;
    await _save();
    // What this person passes on to the others may have changed with it.
    if (card.relay || (had?.relay ?? false)) {
      await shareGates();
    }
  }

  Map<String, ({GateTerms terms, Map<String, String> friends})> get _index =>
      _relayIndex ??= _buildIndex();

  Map<String, ({GateTerms terms, Map<String, String> friends})> _buildIndex() {
    final Map<String, ({GateTerms terms, Map<String, String> friends})> out =
        <String, ({GateTerms terms, Map<String, String> friends})>{};
    void add(RelayedGate g) {
      final ({GateTerms terms, Map<String, String> friends})? had =
          out[g.address];
      if (had == null) {
        out[g.address] = (
          terms: g.terms,
          friends: Map<String, String>.of(g.friends),
        );
      } else {
        had.friends.addAll(g.friends);
      }
      g.relayed.forEach(add);
    }

    for (final String f in host.friends()) {
      final GateCard? card = _cards[_n(f)];
      card?.relayed.forEach(add);
    }
    return out;
  }

  /// What [gatekeeper] asks of this person to open a gate: their own card
  /// when a friend, else their terms for people introduced to them as
  /// friends passed them on. Null: not known.
  GateTerms? gateTermsOf(String gatekeeper) {
    final String k = _n(gatekeeper);
    if (host.isFriend(k)) {
      return _cards[k]?.terms;
    }
    return _index[k]?.terms;
  }

  /// The friends of [person] this phone knows: a friend's shared list, or
  /// what friends passed on about a gatekeeper further away.
  Map<String, String> knownFriendsOf(String person) {
    final String p = _n(person);
    if (host.isFriend(p)) {
      try {
        return meet().book.friendsOf(p);
      } on Object {
        return const <String, String>{};
      }
    }
    return _index[p]?.friends ?? const <String, String>{};
  }

  /// Whether this person can pay [gatekeeper] (both in the pyramid).
  bool canPay(String gatekeeper) {
    final GateWallet? w = wallet;
    return w != null && w.myKey != null && w.keyOf(gatekeeper) != null;
  }

  /// Both ways to [target] and the cheaper one ([planReach]); [direct] is
  /// what writing to them takes, as this phone can tell.
  ReachPlan planTo(
    String target, {
    DirectTerms direct = const DirectTerms.unknown(),
  }) => planReach(
    target: target,
    friends: host.friends(),
    friendsOf: knownFriendsOf,
    termsOf: gateTermsOf,
    canPay: canPay,
    direct: direct,
    self: host.ownAddress(),
  );

  // ---- in the middle (F) ----

  IntroCase? _mineToDecide(String id, IntroRole role) {
    final IntroCase? c = _cases[id];
    return c != null && c.role == role && c.isOpen && !c.waitPay ? c : null;
  }

  /// Passes introduction [id] on to the one it is for, with this person's
  /// [note]: opens the gate.
  Future<bool> forward(String id, {String note = ''}) async {
    await _ready();
    final IntroCase? c = _mineToDecide(id, IntroRole.middle);
    if (c == null || c.kind != IntroKind.intro || !host.isFriend(c.target)) {
      return false;
    }
    await _open(c, note: note);
    return true;
  }

  /// Opens gate [c]: the introduction goes on, and a payment for it is
  /// kept now — the gate did what was paid for, whatever happens further
  /// on the way. The settlement this person signs in the pyramid is the
  /// proof; only a gate that did not open goes back.
  Future<void> _open(IntroCase c, {String note = ''}) async {
    c
      ..note = introText(note, kIntroNoteMaxChars)
      ..status = IntroStatus.forwarded
      ..changedAt = _now();
    if (c.payment != null) {
      // Kept again on every tick while the pyramid does not take it.
      c.settleAt = _now();
    }
    await _save();
    await _sendForward(c);
    await _result(c.asker, c.id, 'fwd');
    await _settleGate(c, keep: true);
  }

  /// Declines request [id] (an introduction or the friend list); a payment
  /// for it goes back.
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
    await _settleGate(c, keep: false);
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

  /// Whether [hold] pays this person [price] for [from]'s gate: exactly
  /// the price (more, e.g. after a friend's stale word about it, goes back
  /// and the asker learns the price — never kept).
  bool _pays(GateHold? hold, String from, int price) {
    final GateWallet? w = wallet;
    final String? me = w?.myKey;
    final String? fromKey = w?.keyOf(from);
    return hold != null &&
        me != null &&
        fromKey != null &&
        hold.to == me &&
        hold.condBy == me &&
        hold.from == fromKey &&
        hold.settled == null &&
        hold.amount == price &&
        hold.until >= _now() + kGateMinHold.inMilliseconds;
  }

  /// A paid gate whose payment this person waits for: once it is in the
  /// pyramid and pays the price, the gate goes on (to this person's
  /// decision, or open at once); not enough, or nothing in time — no.
  Future<void> _checkGatePayment(IntroCase c) async {
    final GateWallet? w = wallet;
    final String? x = c.payment;
    if (!c.waitPay || !c.isOpen || x == null) {
      return;
    }
    final GateHold? hold = w?.held(x);
    if (w == null || hold == null) {
      if (w == null || _now() - c.at > kGatePaymentWait.inMilliseconds) {
        c
          ..waitPay = false
          ..status = IntroStatus.declined
          ..settled = true
          ..changedAt = _now();
        await _save();
        await _result(c.asker, c.id, 'no');
      }
      return;
    }
    if (!_pays(hold, c.asker, c.price)) {
      c
        ..waitPay = false
        ..status = IntroStatus.declined
        ..changedAt = _now();
      await _save();
      await _settleGate(c, keep: false);
      await _priceResult(c.asker, c.id, c.price);
      return;
    }
    c.waitPay = false;
    await _admitGate(c, consent: _gates.termsFor(c.asker).consent);
  }

  /// A gate request that may go on: to this person's decision, or opened
  /// at once by this app (no consent asked).
  Future<void> _admitGate(IntroCase c, {required bool consent}) async {
    final String x = host.nameOf(c.asker);
    final String y = host.nameOf(c.target);
    if (consent) {
      await _save();
      await _tell(
        '${c.id}-ask',
        t('{name} prosi o przedstawienie', {'name': x}),
        t('Komu: {name}', {'name': y}) +
            (c.price > 0
                ? ' · ${t('zapłacono: {price}', {'price': formatPoints(c.price)})}'
                : '') +
            (c.text.isEmpty ? '' : ' — ${c.text}'),
      );
      return;
    }
    await _open(c);
    await _tell(
      '${c.id}-open',
      t('Otwarto bramę: {from} → {to}', {'from': x, 'to': y}),
      c.price > 0
          ? t('Zapłacono: {price}. Twoja aplikacja otworzyła ją sama.', {
              'price': formatPoints(c.price),
            })
          : t('Za darmo i bez pytania — tak ustawiono bramy.'),
    );
  }

  /// Keeps ([keep]) or returns the payment for gate [c], once.
  Future<void> _settleGate(IntroCase c, {required bool keep}) async {
    final GateWallet? w = wallet;
    final String? x = c.payment;
    if (x == null || c.settled) {
      return;
    }
    final GateHold? hold = w?.held(x);
    if (w == null ||
        hold == null ||
        hold.settled != null ||
        hold.condBy != w.myKey) {
      // Nothing (left) to settle here.
      c.settled = true;
      await _save();
      return;
    }
    if (await w.settle(x, keep: keep)) {
      c.settled = true;
      await _save();
    }
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

  // ---- a way through gates (X) ----

  /// Ways through gates, newest first.
  List<GateRun> get runs =>
      _runs.values.toList()
        ..sort((GateRun a, GateRun b) => b.changedAt.compareTo(a.changedAt));

  GateRun? runOf(String id) => _runs[id];

  /// The way to [target] being opened now, if any.
  GateRun? runTo(String target) {
    final String y = _n(target);
    for (final GateRun r in _runs.values) {
      if (r.going && r.target == y) {
        return r;
      }
    }
    return null;
  }

  /// Opens the way [plan] to [target], gate after gate: each gate is paid
  /// only when its turn comes (the payment waits in the pyramid for that
  /// gatekeeper), kept by the gatekeeper once the gate opens, and returned
  /// when that gate does not open — a later gate that does not open
  /// returns only its own. Null when it cannot start (no gates, not
  /// through a friend, a price without the pyramid).
  Future<GateRun?> openWay(
    GatePlan plan, {
    required String target,
    required String targetName,
    String note = '',
  }) async {
    await _ready();
    final GateRun? had = runTo(target);
    if (had != null) {
      return had;
    }
    if (plan.isEmpty ||
        plan.steps.length > kGateMaxSteps ||
        !host.isFriend(plan.steps.first.via) ||
        _n(plan.steps.last.to) != _n(target) ||
        (plan.price > 0 && wallet?.myKey == null)) {
      return null;
    }
    final int ms = _now();
    final GateRun run = GateRun(
      id: _newId(),
      target: _n(target),
      targetName: sanitizePeerName(targetName),
      steps: <GateRunStep>[
        for (final GateStepPlan s in plan.steps)
          GateRunStep(
            via: _n(s.via),
            to: _n(s.to),
            toName: sanitizePeerName(s.toName),
            price: s.price,
          ),
      ],
      at: ms,
      note: introText(note, kIntroNoteMaxChars),
    );
    _runs[run.id] = run;
    await _save();
    await _advanceRuns();
    return run;
  }

  /// Gives up the way [id]: its payments come back.
  Future<void> cancelWay(String id) async {
    await _ready();
    final GateRun? run = _runs[id];
    if (run == null || !run.going) {
      return;
    }
    await _failRun(run, t('Anulowano.'));
  }

  /// Forgets a way that is over.
  Future<void> forgetWay(String id) async {
    await _ready();
    final GateRun? run = _runs[id];
    if (run == null || run.going) {
      return;
    }
    _runs.remove(id);
    await _save();
  }

  Future<void> _advanceRuns() async {
    if (_runsBusy) {
      _runsAgain = true;
      return;
    }
    _runsBusy = true;
    try {
      do {
        _runsAgain = false;
        for (final GateRun run in _runs.values.toList()) {
          if (run.going) {
            await _advance(run);
          }
        }
      } while (_runsAgain);
    } on Object catch (error, stack) {
      logZenError('Bramy: droga', error, stack);
    } finally {
      _runsBusy = false;
    }
  }

  /// Takes [run] as far as it goes now: one gate at a time.
  Future<void> _advance(GateRun run) async {
    final int ms = _now();
    for (int i = 0; i < run.steps.length; i++) {
      final GateRunStep s = run.steps[i];
      if (s.state == GateStepState.open) {
        continue;
      }
      final bool last = i == run.steps.length - 1;
      final String via = _nameOn(run, i);
      if (s.state == GateStepState.waiting) {
        s.startedAt = ms;
        if (s.price > 0) {
          final GateWallet? w = wallet;
          final String? key = await w?.payeeKeyOf(s.via);
          if (w == null || w.myKey == null || key == null) {
            await _failRun(
              run,
              w?.keyOf(s.via) != null
                  ? t(
                      'Urządzenie nie potwierdziło, że należy do: {name}. '
                      'Punkty nie poszły.',
                      {'name': via},
                    )
                  : t('Płatna brama działa tylko w piramidzie: {name}.', {
                      'name': via,
                    }),
            );
            return;
          }
          if (w.balance < s.price) {
            await _failRun(run, t('Za mało punktów w portfelu.'));
            return;
          }
          // The memo is public in the pyramid: no names in it.
          final String? x = await w.hold(
            key,
            s.price,
            memo: t('Brama (przedstawienie)'),
          );
          if (x == null) {
            await _failRun(
              run,
              t('Płatność nie poszła (może czeka jeszcze poprzednia).'),
            );
            return;
          }
          s
            ..payment = x
            ..state = GateStepState.paying;
        } else {
          s.state = GateStepState.asking;
        }
        run.changedAt = ms;
        await _save();
      }
      if (ms - s.startedAt > kGateStepWait.inMilliseconds) {
        await _failRun(
          run,
          t('Brama się nie otworzyła na czas: {name}.', {'name': via}),
        );
        return;
      }
      if (s.state == GateStepState.paying) {
        final GateHold? hold = wallet?.held(s.payment!);
        if (hold == null) {
          // Waits for the pyramid's treasurers.
          return;
        }
        if (hold.settled != null) {
          await _failRun(run, t('Płatność była już rozliczona.'));
          return;
        }
        s.state = GateStepState.asking;
        await _save();
      }
      if (s.state != GateStepState.asking) {
        await _failRun(
          run,
          t('Brama się nie otworzyła: {name}.', {'name': via}),
        );
        return;
      }
      if (s.caseId == null) {
        final IntroCase? asked = await _askAbout(
          IntroKind.intro,
          s.via,
          s.to,
          s.toName,
          run.note,
          payment: s.payment,
          price: s.price,
          route: run.id,
        );
        if (asked == null) {
          await _failRun(run, t('Nie można poprosić: {name}.', {'name': via}));
          return;
        }
        s.caseId = asked.id;
        await _save();
      }
      final IntroCase? c = _cases[s.caseId!];
      if (c == null) {
        await _failRun(
          run,
          t('Brama się nie otworzyła: {name}.', {'name': via}),
        );
        return;
      }
      switch (c.status) {
        case IntroStatus.declined || IntroStatus.refused:
          await _failRun(
            run,
            c.price > s.price
                ? t('{name} chce teraz {price} za tę bramę.', {
                    'name': via,
                    'price': formatPoints(c.price),
                  })
                : t('{name} nie otworzył(a) bramy.', {'name': via}),
          );
          return;
        case IntroStatus.open:
          return;
        case IntroStatus.forwarded || IntroStatus.accepted:
          // The next gate is asked of the person this one opened to: they
          // must have the introduction first.
          if (!last && !c.reached && c.status != IntroStatus.accepted) {
            return;
          }
          s.state = GateStepState.open;
          run.changedAt = ms;
          await _save();
      }
    }
    await _finishRun(run);
  }

  /// The gatekeeper of step [i] of [run], by name.
  String _nameOn(GateRun run, int i) {
    if (i == 0) {
      return host.nameOf(run.steps.first.via);
    }
    final String name = run.steps[i - 1].toName;
    return name.isEmpty ? t('Ktoś') : name;
  }

  Future<void> _finishRun(GateRun run) async {
    run
      ..state = GateRunState.done
      ..changedAt = _now();
    await _save();
    // Every gate is open: the gatekeepers kept their payments (again, in
    // case one did not get to it).
    for (final GateRunStep s in run.steps) {
      if (s.payment != null && s.caseId != null) {
        await _send(s.via, <String, dynamic>{
          'type': IntroTypes.end,
          'id': s.caseId,
          'ok': true,
        });
      }
    }
    await passes?.mayWrite(run.target, paid: false);
    await _tell(
      '${run.id}-done',
      t('Droga otwarta: {name}', {'name': run.targetName}),
      t('Przedstawienie dotarło. Możesz napisać.'),
    );
  }

  Future<void> _failRun(GateRun run, String reason) async {
    run
      ..state = GateRunState.failed
      ..reason = reason
      ..changedAt = _now();
    for (final GateRunStep s in run.steps) {
      if (s.state == GateStepState.open) {
        // Opened: its gatekeeper keeps the payment.
        continue;
      }
      s.state = GateStepState.failed;
      final String? x = s.payment;
      if (x == null) {
        continue;
      }
      // Comes back by itself once its time is over, if nobody returns it.
      _refunds[x] = _now();
      if (s.caseId != null) {
        await _send(s.via, <String, dynamic>{
          'type': IntroTypes.end,
          'id': s.caseId,
          'ok': false,
        });
      }
    }
    await _save();
    await _tell(
      '${run.id}-failed',
      t('Nie udało się dotrzeć do: {name}', {'name': run.targetName}),
      reason,
    );
  }

  /// A gatekeeper hears how the way ended: a request still waiting for
  /// this person is withdrawn and its payment comes back; a gate that
  /// opened keeps its payment whatever the asker says.
  Future<void> _onEnd(String from, Map<String, dynamic> p) async {
    final Object? id = p['id'];
    final IntroCase? c = id is String ? _cases[id] : null;
    if (c == null ||
        c.role != IntroRole.middle ||
        c.asker != from ||
        c.payment == null ||
        c.settled) {
      return;
    }
    final bool ok = p['ok'] == true;
    if (c.isOpen) {
      if (!ok) {
        c
          ..waitPay = false
          ..status = IntroStatus.declined
          ..changedAt = _now();
        await _save();
        await _settleGate(c, keep: false);
      }
      return;
    }
    if (c.isOpened) {
      await _settleGate(c, keep: true);
    }
  }

  // ---- a first message for a price (X and Y) ----

  /// The payment for a first message to [address], if any.
  MessagePay? messagePayTo(String address) => _messagePays[_n(address)];

  /// Pays [address]'s [price] for a first message: put aside for them in
  /// the pyramid, taken by their app (then this person may write first) or
  /// returned. Whether the payment went out.
  Future<bool> payToWrite(String address, {required int price}) async {
    await _ready();
    final String a = _n(address);
    final GateWallet? w = wallet;
    final MessagePay? had = _messagePays[a];
    if (had != null && had.going) {
      return true;
    }
    final String? key = await w?.payeeKeyOf(a);
    if (price <= 0 ||
        w == null ||
        w.myKey == null ||
        key == null ||
        w.balance < price) {
      return false;
    }
    final String? x = await w.hold(key, price, memo: t('Pierwsza wiadomość'));
    if (x == null) {
      return false;
    }
    _messagePays[a] = MessagePay(payment: x, price: price, at: _now());
    await _save();
    await _checkMessagePays();
    return true;
  }

  Future<void> _checkMessagePays() async {
    final GateWallet? w = wallet;
    final int ms = _now();
    bool changed = false;
    for (final MapEntry<String, MessagePay> e
        in _messagePays.entries.toList()) {
      final MessagePay p = e.value;
      if (!p.going) {
        continue;
      }
      if (ms - p.at > kGateStepWait.inMilliseconds) {
        p.state = MessagePayState.failed;
        _refunds[p.payment] = ms;
        changed = true;
        continue;
      }
      if (p.state == MessagePayState.paying && w?.held(p.payment) != null) {
        p.state = MessagePayState.sent;
        changed = true;
        await _send(e.key, <String, dynamic>{
          'type': IntroTypes.pay,
          'x': p.payment,
        });
      }
    }
    for (final String x in _paysIn.keys.toList()) {
      changed = await _checkPayIn(x) || changed;
    }
    if (changed) {
      await _save();
    }
  }

  /// Someone (not a friend) paid this person's price for a first message.
  Future<void> _onPay(String from, Map<String, dynamic> p) async {
    final Object? x = p['x'];
    if (x is! String ||
        !_paymentId.hasMatch(x) ||
        _paymentTaken(x) ||
        _paysIn.length >= 200 ||
        !_take(_paysFrom, from, kIntroPaysPerDay)) {
      return;
    }
    _paysIn[x] = (from, _now());
    await _checkPayIn(x);
    await _save();
  }

  /// Takes (or returns) payment [x] for a first message once it is in the
  /// pyramid. Whether anything changed.
  Future<bool> _checkPayIn(String x) async {
    final (String, int)? waiting = _paysIn[x];
    if (waiting == null) {
      return false;
    }
    final (String from, int since) = waiting;
    final GateWallet? w = wallet;
    final String? me = w?.myKey;
    final GateHold? hold = w?.held(x);
    if (w == null || me == null || hold == null) {
      if (w == null ||
          me == null ||
          _now() - since > kGatePaymentWait.inMilliseconds) {
        _paysIn.remove(x);
        return true;
      }
      return false;
    }
    _paysIn.remove(x);
    if (hold.to != me || hold.condBy != me || hold.settled != null) {
      // Not this person's to decide.
      return true;
    }
    final String? fromKey = w.keyOf(from);
    final int? price = passes?.priceFrom(from);
    final int asked = price ?? 0;
    final bool ok =
        fromKey != null &&
        hold.from == fromKey &&
        price != null &&
        // The price exactly (free: in, and nothing kept); more goes back.
        (hold.amount == asked || asked == 0) &&
        hold.until >= _now() + kGateMinHold.inMilliseconds;
    if (ok) {
      await passes?.letIn(from, paid: asked > 0);
    }
    // Free after all: nothing to keep.
    await w.settle(x, keep: ok && asked > 0);
    await _send(from, <String, dynamic>{
      'type': IntroTypes.paid,
      'x': x,
      'ok': ok,
    });
    return true;
  }

  /// The answer to this person's payment for a first message.
  Future<void> _onPaid(String from, Map<String, dynamic> p) async {
    final MessagePay? pay = _messagePays[from];
    if (pay == null || !pay.going || p['x'] != pay.payment) {
      return;
    }
    final bool ok = p['ok'] == true;
    pay.state = ok ? MessagePayState.ok : MessagePayState.failed;
    if (ok) {
      await passes?.mayWrite(from, paid: true);
    } else {
      _refunds[pay.payment] = _now();
    }
    await _save();
    await _tell(
      '${pay.payment}-paid',
      ok
          ? t('Możesz napisać pierwszy(-a)')
          : t('Pierwsza wiadomość nie przeszła'),
      ok
          ? t('Zapłacono: {price}.', {'price': formatPoints(pay.price)})
          : t('Ta osoba nie przyjmuje teraz wiadomości. Punkty wrócą.'),
    );
  }

  /// Payments this person made that nobody returned: back once their time
  /// is over.
  Future<void> _checkRefunds() async {
    final GateWallet? w = wallet;
    if (w == null || _refunds.isEmpty) {
      return;
    }
    final int ms = _now();
    bool changed = false;
    for (final MapEntry<String, int> e in _refunds.entries.toList()) {
      final GateHold? hold = w.held(e.key);
      if (hold == null) {
        if (ms - e.value > 2 * kGateHoldTime.inMilliseconds) {
          _refunds.remove(e.key);
          changed = true;
        }
        continue;
      }
      if (hold.settled != null || hold.from != w.myKey) {
        _refunds.remove(e.key);
        changed = true;
        continue;
      }
      if (ms >= hold.until && await w.settle(e.key, keep: false)) {
        _refunds.remove(e.key);
        changed = true;
      }
    }
    if (changed) {
      await _save();
    }
  }

  // ---- time and the wallet ----

  /// Now and then (and when the app opens): payments kept after their
  /// time, ways that wait, money that should come back, terms friends
  /// have not heard yet.
  Future<void> tick() async {
    await _ready();
    _watchWallet();
    final int ms = _now();
    for (final IntroCase c in _cases.values.toList()) {
      if (c.role != IntroRole.middle || c.payment == null || c.settled) {
        continue;
      }
      if (c.waitPay) {
        await _checkGatePayment(c);
      } else if (c.isOpened && c.settleAt != null && ms >= c.settleAt!) {
        await _settleGate(c, keep: true);
      } else if (c.status == IntroStatus.declined) {
        await _settleGate(c, keep: false);
      }
    }
    await _advanceRuns();
    await _checkMessagePays();
    await _checkRefunds();
    if (ms - _cardsAt > const Duration(minutes: 30).inMilliseconds) {
      await shareGates();
    }
  }

  void _watchWallet() {
    if (_disposed) {
      return;
    }
    final Listenable? l = wallet?.changes;
    if (identical(l, _watched)) {
      return;
    }
    _watched?.removeListener(_onWallet);
    _watched = l;
    l?.addListener(_onWallet);
  }

  bool get _waitsForWallet =>
      _cases.values.any((IntroCase c) => c.waitPay) ||
      _runs.values.any(
        (GateRun r) =>
            r.going &&
            r.steps.any((GateRunStep s) => s.state == GateStepState.paying),
      ) ||
      _messagePays.values.any(
        (MessagePay p) => p.state == MessagePayState.paying,
      ) ||
      _paysIn.isNotEmpty;

  void _onWallet() {
    if (_disposed || !_waitsForWallet) {
      return;
    }
    if (_walletBusy) {
      _walletAgain = true;
      return;
    }
    unawaitedLogged(_walletPass(), context: 'Bramy: płatności');
  }

  Future<void> _walletPass() async {
    _walletBusy = true;
    try {
      do {
        _walletAgain = false;
        for (final IntroCase c in _cases.values.toList()) {
          if (c.waitPay) {
            await _checkGatePayment(c);
          }
        }
        await _advanceRuns();
        await _checkMessagePays();
      } while (_walletAgain && !_disposed);
    } finally {
      _walletBusy = false;
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
    if (_tooBig(frame.payload)) {
      return true;
    }
    try {
      await _ready();
      final bool friend = host.isFriend(from);
      // Requests, introductions and terms travel friend to friend; the one
      // a gate opened to may also be asked for the next gate. Answers and
      // payments are checked against what this phone holds.
      final bool allowed = switch (type) {
        IntroTypes.ask => friend || _introducedHere(from),
        IntroTypes.forward || IntroTypes.answer || IntroTypes.gate => friend,
        _ => true,
      };
      if (!allowed) {
        return true;
      }
      switch (type) {
        case IntroTypes.ask:
          await _onAsk(from, frame.payload, friend: friend);
        case IntroTypes.forward:
          await _onForward(from, frame.payload);
        case IntroTypes.answer:
          await _onAnswer(from, frame.payload);
        case IntroTypes.result:
          await _onResult(from, frame.payload);
        case IntroTypes.gate:
          await _onGate(from, frame.payload);
        case IntroTypes.end:
          await _onEnd(from, frame.payload);
        case IntroTypes.pay:
          await _onPay(from, frame.payload);
        case IntroTypes.paid:
          await _onPaid(from, frame.payload);
      }
    } on Object catch (error, stack) {
      logZenError('Przedstawienia: $type', error, stack);
    }
    return true;
  }

  static bool _tooBig(Map<String, dynamic> p) =>
      p.values.any((Object? v) => v is String && v.length > _maxRawField);

  bool _take(Map<String, List<int>> log, String who, int limit) {
    final int ms = _now();
    final List<int> recent = (log[who] ??= <int>[])
      ..removeWhere((int at) => ms - at > _day);
    if (recent.length >= limit) {
      return false;
    }
    recent.add(ms);
    return true;
  }

  bool _letterAllowed(String from) {
    final int ms = _now();
    final List<(String, int)> week = <(String, int)>[
      for (final (String, int) r in _relayed)
        if (ms - r.$2 < _week) r,
    ];
    return week.length < kLettersRelayedPerWeek &&
        week.where(((String, int) r) => r.$1 == from).length < kLettersPerWeek;
  }

  /// X (a friend, or someone a gate opened to) asks this person (F).
  Future<void> _onAsk(
    String from,
    Map<String, dynamic> p, {
    required bool friend,
  }) async {
    final Object? id = p['id'];
    final IntroKind? kind = IntroKind.byName(p['k']);
    if (id is! String ||
        !_introId.hasMatch(id) ||
        kind == null ||
        _cases.containsKey(id) ||
        // Someone introduced here (not a friend) asks only for a gate.
        (!friend && kind != IntroKind.intro) ||
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
    final Map<String, dynamic>? proof = introProofFromJson(p['sg']);
    if (target.isEmpty ||
        target == from ||
        _isSelf(target) ||
        !host.isFriend(target) ||
        proof == null ||
        (kind == IntroKind.letter && text.isEmpty)) {
      await _result(from, id, 'no');
      return;
    }
    final Object? x = p['x'];
    // A payment pays for one gate (or one first message) only: one already
    // attached to another request here counts as none.
    final String? payment =
        x is String && _paymentId.hasMatch(x) && !_paymentTaken(x) ? x : null;
    if (kind == IntroKind.letter) {
      final IntroCase c = IntroCase(
        id: id,
        kind: kind,
        role: IntroRole.middle,
        at: _now(),
        asker: from,
        target: target,
        text: text,
        // Passed on as it came: only the one it is for can check it.
        proof: proof,
      );
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
    final GateTerms terms = _gates.termsFor(from);
    if (!terms.free && payment == null) {
      // Not paid (an old card): the asker learns the price.
      await _priceResult(from, id, terms.price);
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
      proof: proof,
      payment: terms.free ? null : payment,
      price: terms.free ? 0 : terms.price,
      waitPay: !terms.free,
    );
    _cases[id] = c;
    if (terms.free) {
      if (payment != null) {
        await _returnStray(payment);
      }
      await _admitGate(c, consent: terms.consent);
      return;
    }
    await _save();
    await _checkGatePayment(c);
  }

  /// Whether payment [x] already pays for a gate request or a first
  /// message here (so it is not counted twice).
  bool _paymentTaken(String x) =>
      _paysIn.containsKey(x) ||
      _cases.values.any(
        (IntroCase c) => c.role == IntroRole.middle && c.payment == x,
      );

  /// A payment for a free gate: back to the payer, when it is here.
  Future<void> _returnStray(String x) async {
    final GateWallet? w = wallet;
    final GateHold? hold = w?.held(x);
    if (w != null &&
        hold != null &&
        hold.condBy == w.myKey &&
        hold.settled == null) {
      await w.settle(x, keep: false);
    }
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
      // A weak acquaintance asks like everybody does "on request".
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
    // The asker's signature: the middle friend may not change the
    // words, the address or the name. A case without a good one is dropped.
    final ({bool valid, String name}) check = await _checkSigned(
      p['sg'],
      id: id,
      kind: kind,
      asker: asker,
      text: text,
    );
    if (!check.valid || _cases.containsKey(id)) {
      if (!check.valid) {
        logZenWarning('Przedstawienia: podpis nadawcy się nie zgadza');
      }
      return;
    }
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
    );
    _cases[id] = c;
    await _save();
    if (kind == IntroKind.intro) {
      // The gate is open: the one introduced may write here, and hears
      // that the introduction came.
      await passes?.letIn(asker, paid: false, via: from);
      await _result(asker, id, 'in');
    }
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
    await _tell('$id-fwd', title, body);
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

  /// F tells this person (X) how their request went; Y tells X that the
  /// introduction came.
  Future<void> _onResult(String from, Map<String, dynamic> p) async {
    final Object? id = p['id'];
    final IntroCase? c = id is String ? _cases[id] : null;
    if (c == null || c.role != IntroRole.asker) {
      return;
    }
    final Object? s = p['s'];
    if (s == 'in') {
      if (c.kind != IntroKind.intro ||
          c.target != from ||
          c.reached ||
          c.status == IntroStatus.declined) {
        return;
      }
      c
        ..reached = true
        ..changedAt = _now();
      await _save();
      await passes?.mayWrite(c.target, paid: false);
      await _advanceRuns();
      return;
    }
    if (c.middle != from) {
      return;
    }
    final String via = host.nameOf(from);
    final String title;
    final String body;
    switch (s) {
      case 'fwd':
        if (c.status != IntroStatus.open || c.kind == IntroKind.list) {
          return;
        }
        c.status = IntroStatus.forwarded;
        title = c.kind == IntroKind.letter
            ? t('List poszedł dalej')
            : t('Brama otwarta');
        body = c.kind == IntroKind.letter
            ? t('Przez: {via}. Teraz decyduje: {name}.', {
                'via': via,
                'name': c.targetName,
              })
            : t('Przez: {via}. {name} dostaje Twoje przedstawienie.', {
                'via': via,
                'name': c.targetName,
              });
      case 'no' || 'price':
        if (c.status != IntroStatus.open) {
          return;
        }
        c.status = IntroStatus.declined;
        final Object? pr = p['pr'];
        if (s == 'price' && pr is int && pr > 0 && pr <= kGateMaxPrice) {
          c.price = pr;
        }
        title = switch (c.kind) {
          IntroKind.list => t('Lista znajomych niedostępna'),
          IntroKind.intro =>
            s == 'price' ? t('Ta brama jest płatna') : t('Bez przedstawienia'),
          IntroKind.letter => t('List nie poszedł'),
        };
        body = switch (c.kind) {
          IntroKind.list => t('{via} nie pokazuje teraz swojej listy.', {
            'via': via,
          }),
          IntroKind.intro =>
            s == 'price'
                ? t('{via} otwiera bramę do: {name} za {price}.', {
                    'via': via,
                    'name': c.targetName,
                    'price': formatPoints(c.price),
                  })
                : t('{via} nie przekaże tej prośby.', {'via': via}),
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
    // A step of a way: the way tells how it went, not each gate.
    if (c.route == null) {
      await _tell('${c.id}-${c.status.name}', title, body);
    }
    await _advanceRuns();
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
    // X's signature over all of it but this person's note.
    if (c.proof != null) 'sg': c.proof,
  });

  Future<void> _result(String to, String id, String status) => _send(
    to,
    <String, dynamic>{'type': IntroTypes.result, 'id': id, 's': status},
  );

  Future<void> _priceResult(String to, String id, int price) =>
      _send(to, <String, dynamic>{
        'type': IntroTypes.result,
        'id': id,
        's': 'price',
        'pr': price,
      });

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
