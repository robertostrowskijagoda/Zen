import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/core/ledger/ledger_codec.dart';
import 'package:zen/src/core/ledger/ledger_identity.dart';
import 'package:zen/src/core/logging/zen_log.dart';
import 'package:zen/src/features/account/account_recovery.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';

/// Messages of the recovery protocol, over the signal transport:
///
/// * `rc_store {piece, a, g, h?, at, cert, sig}`: owner → helper (a close
///   friend). Signed by a device of the owner's account (`a`), so the
///   helper keeps it under that account; `g` is its generation, `h` the
///   helper's account when the owner knows it. Unsigned (1.16.4 and
///   earlier): `{piece}` alone, kept under the sender's address.
/// * `rc_ack {account, created}`: helper → owner (`created`: the
///   generation kept);
/// * `rc_forget {a, g, cert, sig}` (1.16.5): owner → helper, signed by a
///   device of `a`: delete every piece of `a` older than generation `g`
///   (all of them, for someone who no longer holds one). Sent once the
///   new generation reached its threshold. Helpers on 1.16.4 and earlier
///   ignore it and keep their pieces;
/// * `rc_forgot {a, g}` (1.16.5): helper → owner, the pieces are gone;
/// * `rc_alarm {to, kind, due, o?}`: helper → owner's old devices, when the
///   helper agreed to release the piece to a new device (`o`: despite a
///   stop, see [RecoveryService.overrideRelease]);
/// * `rc_cancel {a?, at?, cert?, sig?}`: owner's old device → helper ("to
///   nie ja"). Counts only signed by a device the account has not cut off
///   (an unsigned one, from 1.16.4 and earlier, only for the pieces it
///   handed out, from an address not unlinked);
/// * `rc_piece {kind, half, more?, account}`: helper → new device, after
///   the delay. `more` holds the helper's previous generation, kept until
///   the new one is complete. `account` is the account the piece is for;
///   the account the pieces open must still be confirmed by its
///   fingerprint.
/// * `rc_help {}`: new device → helper, when the person names the helper
///   there: the helper's device tells its person that someone asks for
///   help (it holds pieces), with the new device's address ready.
///
/// The new device takes pieces only while a recovery is started on it
/// ([RecoveryService.beginRecovery]), only from its friends and the helpers
/// the person listed there ([RecoveryService.allowHelper]), at most two
/// of each kind per sender, and only with the Argon2 costs this app writes.
abstract final class RecoveryMessages {
  static const String store = 'rc_store';
  static const String ack = 'rc_ack';
  static const String forget = 'rc_forget';
  static const String forgot = 'rc_forgot';
  static const String alarm = 'rc_alarm';
  static const String cancel = 'rc_cancel';
  static const String piece = 'rc_piece';
  static const String help = 'rc_help';
}

/// How long an unanswered piece waits before it is sent again.
const Duration kPieceRetry = Duration(minutes: 30);

/// How often every holder is offered its piece again, answered or not: a
/// helper who lost it (a phone restored from the key alone) gets it back.
const Duration kPieceReoffer = Duration(days: 7);

/// How often a former holder is told again to forget, and for how long.
const Duration kForgetRetry = Duration(days: 1);
const Duration kForgetTold = Duration(days: 90);

/// How long a helper keeps the pieces of someone who is no longer a friend
/// there (a friendship that comes back within it changes nothing).
const Duration kPiecesAfterFriendship = Duration(days: 42);

/// How long a helper keeps the previous generation after a newer one
/// came, when nobody told it to forget it (the owner's phone may be gone
/// before the new generation was complete).
const Duration kPreviousPieceKept = Duration(days: 60);

/// How long a release stopped by the owner waits before the helper may
/// still give the piece, and how long a stopped one stays listed.
const Duration kOverrideDelay = Duration(days: 7);
const Duration kStoppedKept = Duration(days: 30);

/// This account as the recovery signs with it: a device it certified.
@immutable
final class RecoveryIdentity {
  const RecoveryIdentity({
    required this.account,
    required this.deviceKey,
    required this.certificate,
  });

  final String account;
  final LedgerKeyPair deviceKey;
  final DeviceCertificate certificate;

  String get device => certificate.device;
}

/// A new device asked this device (a helper) for help with a recovery.
@immutable
final class RecoveryHelpRequest {
  const RecoveryHelpRequest({required this.from, required this.at});

  /// The new device's address: where the piece would go.
  final String from;
  final int at;

  Map<String, dynamic> toJson() => <String, dynamic>{'from': from, 'at': at};

  static RecoveryHelpRequest? fromJson(Object? json) {
    if (json is! Map) {
      return null;
    }
    final Object? from = json['from'];
    final Object? at = json['at'];
    return from is String && from.isNotEmpty && at is int
        ? RecoveryHelpRequest(from: from, at: at)
        : null;
  }
}

/// The new device's address from what the person it helps passed on: its
/// invitation code, link, QR or plain address. Throws [FormatException]
/// with a message for the person when [input] is none of them.
String parseRecoveryDevice(String input) {
  try {
    final String address = PeerShareCodec.normalizeAddress(
      PeerShareCodec.parseTarget(input).address,
    );
    if (address.isNotEmpty) {
      return address;
    }
  } on FormatException {
    // Told below in the person's words.
  }
  throw FormatException(
    t(
      'To nie jest kod nowego urządzenia. Wklej kod albo link, który '
      'pokazuje jego ekran „Odzyskaj konto”, albo zeskanuj jego QR.',
    ),
  );
}

/// Which half of a piece is released.
enum RecoveryKind { normal, emergency }

/// A release the helper agreed to, waiting for its delay.
@immutable
final class PendingRelease {
  const PendingRelease({
    required this.owner,
    required this.to,
    required this.kind,
    required this.due,
    int? at,
    this.override = false,
    this.stopped,
  }) : at = at ?? due - 24 * 60 * 60 * 1000;

  /// Whose piece it is: the key it is kept under ([RecoveryService.heldFor]).
  final String owner;

  /// The new device's address.
  final String to;
  final RecoveryKind kind;
  final int due;

  /// When the helper agreed to it.
  final int at;

  /// Agreed again after the owner stopped it: a stop no longer counts.
  final bool override;

  /// When the owner stopped it (nothing goes out then), if they did.
  final int? stopped;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'owner': owner,
    'to': to,
    'kind': kind.name,
    'due': due,
    'at': at,
    if (override) 'o': true,
    'stopped': ?stopped,
  };

  static PendingRelease? fromJson(Object? json) {
    if (json is! Map) {
      return null;
    }
    final Object? owner = json['owner'];
    final Object? to = json['to'];
    final Object? due = json['due'];
    final Object? at = json['at'];
    final Object? stopped = json['stopped'];
    final RecoveryKind? kind = RecoveryKind.values
        .where((RecoveryKind k) => k.name == json['kind'])
        .firstOrNull;
    if (owner is! String || to is! String || due is! int || kind == null) {
      return null;
    }
    return PendingRelease(
      owner: owner,
      to: to,
      kind: kind,
      due: due,
      at: at is int ? at : null,
      override: json['o'] == true,
      stopped: stopped is int ? stopped : null,
    );
  }
}

/// An alarm on the owner's device: someone is about to release a piece.
@immutable
final class RecoveryAlarm {
  const RecoveryAlarm({
    required this.helper,
    required this.to,
    required this.kind,
    required this.due,
    this.override = false,
  });

  final String helper;
  final String to;
  final RecoveryKind kind;
  final int due;

  /// The helper gives the piece despite a stop: stopping again does not
  /// count, only talking to them does.
  final bool override;
}

/// One generation of this account's pieces: who holds them, how many must
/// agree and who confirmed. Kept the same on the account's devices (no
/// secret in it); the device that made it ([device]) hands it out.
@immutable
final class RecoveryGeneration {
  const RecoveryGeneration({
    required this.generation,
    required this.threshold,
    required this.device,
    required this.sealAt,
    required this.holders,
    this.acks = const <String, int>{},
    this.cleared = false,
  });

  /// When it was made (millis; each newer than the one before).
  final int generation;
  final int threshold;

  /// The device that made it and hands it out.
  final String device;

  /// The [RecoverySeal.at] of the seal it carries (a new password: a new
  /// generation).
  final int sealAt;

  /// Who holds a piece (addresses), in the order of the pieces.
  final List<String> holders;

  /// Holder → the generation it confirmed.
  final Map<String, int> acks;

  /// Whether the older generations were told to forget (it was complete).
  final bool cleared;

  /// Holders who confirmed this generation.
  int get acked => holders.where((String h) => acks[h] == generation).length;

  /// Whether enough holders confirmed it for a recovery.
  bool get complete =>
      holders.length >= kRecoveryCircleMinimum && acked >= threshold;

  RecoveryGeneration copyWith({Map<String, int>? acks, bool? cleared}) =>
      RecoveryGeneration(
        generation: generation,
        threshold: threshold,
        device: device,
        sealAt: sealAt,
        holders: holders,
        acks: acks ?? this.acks,
        cleared: cleared ?? this.cleared,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
    'g': generation,
    't': threshold,
    'd': device,
    's': sealAt,
    'holders': holders,
    'acks': acks,
    if (cleared) 'cleared': true,
  };

  static RecoveryGeneration? fromJson(Object? json) {
    if (json is! Map) {
      return null;
    }
    final Object? g = json['g'];
    final Object? t = json['t'];
    final Object? d = json['d'];
    final Object? s = json['s'];
    final Object? holders = json['holders'];
    final Object? acks = json['acks'];
    if (g is! int || t is! int || d is! String || s is! int) {
      return null;
    }
    return RecoveryGeneration(
      generation: g,
      threshold: t,
      device: d,
      sealAt: s,
      holders: holders is List
          ? holders.whereType<String>().take(255).toList()
          : const <String>[],
      acks: <String, int>{
        if (acks is Map)
          for (final MapEntry<Object?, Object?> e in acks.entries)
            if (e.key is String && e.value is int)
              e.key! as String: e.value! as int,
      },
      cleared: json['cleared'] == true,
    );
  }
}

/// How well the account is kept by its friends, as the settings show it.
@immutable
final class RecoveryProtection {
  const RecoveryProtection({
    this.sealed = false,
    this.holders = 0,
    this.threshold = 0,
    this.acked = 0,
    this.legacy = 0,
    this.legacyAcked = 0,
  });

  /// Whether pieces can be made (an account password was set for them
  /// here, or another device of the account hands them out).
  final bool sealed;
  final int holders;
  final int threshold;
  final int acked;

  /// The circle handed out by 1.16.4 or earlier, still valid until the new
  /// pieces are complete: its people and how many confirmed.
  final int legacy;
  final int legacyAcked;

  /// Enough holders confirmed the current pieces (or the old circle's)
  /// for a recovery.
  bool get secured =>
      (holders >= kRecoveryCircleMinimum && acked >= threshold) ||
      legacyAcked >= kNormalThreshold;
}

/// The pieces this device keeps for one account (a helper's side).
final class _Held {
  _Held({
    required this.account,
    required this.from,
    required this.pieces,
    required this.at,
    this.gone,
    this.signed = true,
  });

  /// The account they belong to (proved by its signature; for unsigned
  /// pieces of 1.16.4 and earlier only claimed).
  final String account;

  /// The owner's address they came from (last).
  String from;

  /// Newest generation first, at most two.
  List<Map<String, dynamic>> pieces;

  /// When the newest came.
  int at;

  /// Since when the owner is no longer a friend here.
  int? gone;
  final bool signed;

  int get newest => RecoveryPiece.fromJson(pieces.first)?.generation ?? 0;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'account': account,
    'from': from,
    'pieces': pieces,
    'at': at,
    'gone': ?gone,
    if (!signed) 'unsigned': true,
  };

  static _Held? fromJson(Object? json) {
    if (json is! Map) {
      return null;
    }
    final Object? account = json['account'];
    final Object? from = json['from'];
    final Object? pieces = json['pieces'];
    final Object? at = json['at'];
    final Object? gone = json['gone'];
    if (account is! String ||
        from is! String ||
        pieces is! List ||
        at is! int) {
      return null;
    }
    final List<Map<String, dynamic>> kept = <Map<String, dynamic>>[
      for (final Object? p in pieces.take(2))
        if (RecoveryPiece.fromJson(p) != null) p! as Map<String, dynamic>,
    ];
    if (kept.isEmpty) {
      return null;
    }
    return _Held(
      account: account,
      from: from,
      pieces: kept,
      at: at,
      gone: gone is int ? gone : null,
      signed: json['unsigned'] != true,
    );
  }
}

/// Keeps the pieces this device holds for friends, the releases it agreed
/// to, this account's own pieces with its close friends, and the pieces
/// received for a recovery in progress.
///
/// As the owner: once the person set the account password for the pieces
/// ([setSeal]), the device hands a generation of pieces to the close
/// friends ([holders]) by itself, and a new one whenever they change: sent
/// again until confirmed, offered again every [kPieceReoffer]. Once enough
/// confirmed it, everyone who held an older generation (the circle of
/// 1.16.4 too) is told to forget it. Only the device whose seal is the
/// newest hands pieces out; the others show the same state
/// ([syncState]).
///
/// As a helper: pieces are kept under the owner's account (proved by the
/// device signature that came with them), the newest generation and the
/// one before it, and they travel to this account's other devices
/// ([syncState]) and into its moves and full copies. They go when the
/// owner says to forget them, [kPiecesAfterFriendship] after the
/// friendship ended, and (the one before) [kPreviousPieceKept] after a
/// newer came.
final class RecoveryService {
  RecoveryService({
    required this.transport,
    required this.disk,
    required this.isFriend,
    RecoveryIdentity? Function()? identity,
    List<String>? Function()? holders,
    String? Function(String address)? accountOf,
    Iterable<String> Function(String account)? addressesOf,
    bool? Function(String account)? isFriendAccount,
    bool Function(String account, String device)? isRevoked,
    bool Function(String address)? isUnlinkedAddress,
    int Function()? clock,
    this.tickInterval = const Duration(minutes: 1),
    this.acceptedCosts = kAcceptedRecoveryCosts,
  }) : _clock = clock ?? (() => DateTime.now().millisecondsSinceEpoch),
       identity = identity ?? _noIdentity,
       holders = holders ?? _noHolders,
       accountOf = accountOf ?? _unknown,
       addressesOf = addressesOf ?? _noAddresses,
       isFriendAccount = isFriendAccount ?? _unknownFriend,
       isRevoked = isRevoked ?? _notRevoked,
       isUnlinkedAddress = isUnlinkedAddress ?? _notUnlinked;

  static RecoveryIdentity? _noIdentity() => null;
  static List<String>? _noHolders() => null;
  static String? _unknown(String _) => null;
  static Iterable<String> _noAddresses(String _) => const <String>[];
  static bool? _unknownFriend(String _) => null;
  static bool _notRevoked(String _, String _) => false;
  static bool _notUnlinked(String _) => false;

  /// Pieces of 1.16.4 and earlier, by owner address (read once, moved
  /// into [_piecesKey]).
  static const String _heldKey = 'recovery/held';
  static const String _piecesKey = 'recovery/pieces';
  static const String _pendingKey = 'recovery/pending';
  static const String _acksKey = 'recovery/acks';
  static const String _receivedKey = 'recovery/received';
  static const String _collectingKey = 'recovery/collecting';
  static const String _circleKey = 'recovery/circle';
  static const String _requestsKey = 'recovery/requests';
  static const String _sealKey = 'recovery/sealed';
  static const String _generationKey = 'recovery/gen';
  static const String _outKey = 'recovery/out';

  /// The key of the pieces of [address] kept unsigned (from 1.16.4 and
  /// earlier).
  static String _unsignedKey(String address) => 'legacy|$address';

  /// Help requests kept at most, and for how long.
  static const int maxRequests = 8;
  static const Duration requestLifetime = Duration(days: 30);

  /// Pieces kept for one recovery, at most.
  static const int maxReceived = 48;

  /// Helpers the person may list for one recovery, at most.
  static const int maxHelpers = 24;

  /// Accounts whose pieces this device keeps, at most.
  static const int maxHeld = 200;

  /// How long a started recovery takes pieces (the emergency delay with
  /// room for helpers who agree late).
  static const Duration collectWindow = Duration(days: 30);

  final SignalTransport transport;
  final LedgerDisk disk;
  final bool Function(String address) isFriend;
  final int Function() _clock;
  final Duration tickInterval;

  /// This account and device, to sign with; null while not known.
  final RecoveryIdentity? Function() identity;

  /// Who should hold this account's pieces now (the close friends'
  /// addresses, see `pieceHolders`); null while that is not known yet
  /// (nothing is changed then).
  final List<String>? Function() holders;

  /// The account of a friend's address, when known.
  final String? Function(String address) accountOf;

  /// Where an account's devices are reached (its alarm goes to all).
  final Iterable<String> Function(String account) addressesOf;

  /// Whether [account] is a friend here; null while not known.
  final bool? Function(String account) isFriendAccount;

  /// Whether the account cut off one of its devices.
  final bool Function(String account, String device) isRevoked;

  /// Whether the device at an address was unlinked by its owner.
  final bool Function(String address) isUnlinkedAddress;

  /// Argon2 costs a received `normal` half may ask for.
  final List<PasswordCost> acceptedCosts;

  /// When the recovery on this device was started (millis), if it was.
  int? _collectingSince;

  /// Addresses of the helpers the person listed for this recovery: with
  /// friends, the only senders whose pieces are taken.
  final Set<String> _helpers = <String>{};

  /// Account (or [_unsignedKey]) → the pieces kept for it.
  final Map<String, _Held> _held = <String, _Held>{};
  final List<PendingRelease> _pending = <PendingRelease>[];

  /// The circle of 1.16.4 and earlier: helper address → `created` of the
  /// piece they confirmed.
  final Map<String, int> _acks = <String, int>{};

  /// Received halves: `normal` / `emergency` lists (at most two per
  /// sender, each share once), with the account they name and who sent
  /// them.
  final Map<RecoveryKind, List<Map<String, dynamic>>> _received =
      <RecoveryKind, List<Map<String, dynamic>>>{
        RecoveryKind.normal: <Map<String, dynamic>>[],
        RecoveryKind.emergency: <Map<String, dynamic>>[],
      };
  final List<RecoveryAlarm> _alarms = <RecoveryAlarm>[];

  /// Who the pieces of the circle of 1.16.4 and earlier went to (in the
  /// order of the pieces); empty once the new pieces are complete.
  final List<String> _circle = <String>[];

  /// New devices that asked this device for help (see [RecoveryHelpRequest]).
  final List<RecoveryHelpRequest> _requests = <RecoveryHelpRequest>[];

  // ---- this account's own pieces ----

  RecoverySeal? _seal;
  RecoveryGeneration? _generation;

  /// Holder → its piece of [_generation] (only on the device handing out).
  final Map<String, Map<String, dynamic>> _out =
      <String, Map<String, dynamic>>{};

  /// Holder → when its piece was last sent.
  final Map<String, int> _sent = <String, int>{};
  int _reofferAt = 0;

  /// Former holder → when it stopped holding.
  final Map<String, int> _retired = <String, int>{};

  /// Former (or current) holder → when it was last told to forget.
  final Map<String, int> _told = <String, int>{};
  bool _reconciling = false;
  bool _reconcileAgain = false;

  /// Told when a new device asks for help (the app posts a notification).
  void Function(RecoveryHelpRequest request)? onHelpRequested;

  /// Told when a friend is about to release this account's piece to a new
  /// device (the app posts a notification on the old devices).
  void Function(RecoveryAlarm alarm)? onAlarm;
  final StreamController<void> _changes = StreamController<void>.broadcast();
  StreamSubscription<SignalTransportFrame>? _frames;
  Timer? _timer;
  Future<void>? _started;

  /// Fires after anything shown in the UI changed.
  Stream<void> get changes => _changes.stream;

  /// Whose pieces this device keeps: the keys [startHelping] and
  /// [heldAccount] take (an account, or an address for pieces of 1.16.4
  /// and earlier).
  Iterable<String> get heldFor => _held.keys;

  /// The accounts whose pieces this device keeps: the recovery circles it
  /// is in (it keeps their circle copies too).
  Set<String> get heldAccounts => <String>{
    for (final _Held h in _held.values) h.account,
  };
  List<PendingRelease> get pending =>
      List<PendingRelease>.unmodifiable(_pending);

  /// Who confirmed the pieces of the circle of 1.16.4 and earlier.
  Map<String, int> get acks => Map<String, int>.unmodifiable(_acks);
  List<RecoveryAlarm> get alarms => List<RecoveryAlarm>.unmodifiable(_alarms);
  int receivedCount(RecoveryKind kind) => _received[kind]!.length;
  List<Map<String, dynamic>> received(RecoveryKind kind) =>
      List<Map<String, dynamic>>.unmodifiable(_received[kind]!);

  /// The helpers the person listed for the recovery on this device.
  Set<String> get allowedHelpers => Set<String>.unmodifiable(_helpers);

  /// Who keeps the pieces of the circle of 1.16.4 and earlier (addresses);
  /// [acks] tells who confirmed. Empty once the new pieces are complete.
  List<String> get circle => List<String>.unmodifiable(_circle);

  /// This account's current generation of pieces, if any.
  RecoveryGeneration? get generation => _generation;

  /// Whether an account password for the pieces was set on this device.
  bool get hasSeal => _seal != null;

  /// Whether this device hands this account's pieces out.
  bool get handsOut {
    final RecoveryGeneration? g = _generation;
    final RecoverySeal? seal = _seal;
    final RecoveryIdentity? id = identity();
    // The device with the newest seal; one the account cut off hands
    // nothing out any more.
    return seal != null &&
        id != null &&
        (g == null ||
            g.device == id.device ||
            g.sealAt < seal.at ||
            isRevoked(id.account, g.device));
  }

  /// How the account is kept by its friends now.
  RecoveryProtection get protection {
    final RecoveryGeneration? g = _generation;
    return RecoveryProtection(
      sealed: _seal != null || g != null,
      holders: g?.holders.length ?? 0,
      threshold: g?.threshold ?? 0,
      acked: g?.acked ?? 0,
      legacy: _circle.length,
      legacyAcked: _circle.where((String a) => _acks.containsKey(a)).length,
    );
  }

  /// New devices that asked for help and were not answered yet.
  List<RecoveryHelpRequest> get helpRequests {
    final int now = _clock();
    return List<RecoveryHelpRequest>.unmodifiable(
      _requests.where(
        (RecoveryHelpRequest r) => now - r.at < requestLifetime.inMilliseconds,
      ),
    );
  }

  /// Forgets the help request from [from] (answered or turned down).
  Future<void> dismissHelpRequest(String from) async {
    final String a = PeerShareCodec.normalizeAddress(from);
    final int before = _requests.length;
    _requests.removeWhere((RecoveryHelpRequest r) => r.from == a);
    if (_requests.length != before) {
      await _saveRequests();
      _changed();
    }
  }

  /// The friends who sent pieces (to greet after recovery).
  List<String> get helperAddresses => <String>{
    for (final List<Map<String, dynamic>> list in _received.values)
      for (final Map<String, dynamic> h in list)
        if (h['from'] is String) h['from'] as String,
  }.toList();

  /// The set of received `normal` halves closest to opening: how many it
  /// has and how many its generation needs (2 before any came).
  ({int got, int needed}) get receivedProgress {
    final Map<String, List<Map<String, dynamic>>> sets =
        <String, List<Map<String, dynamic>>>{};
    for (final Map<String, dynamic> h in _received[RecoveryKind.normal]!) {
      (sets[jsonEncode(<Object?>[h['box'], h['salt'], h['t']])] ??=
              <Map<String, dynamic>>[])
          .add(h);
    }
    ({int got, int needed}) best = (got: 0, needed: kNormalThreshold);
    for (final List<Map<String, dynamic>> set in sets.values) {
      final int needed = recoveryHalfThreshold(set.first);
      if (best.got == 0 ||
          set.length * best.needed > best.got * needed ||
          (set.length >= needed && best.got < best.needed)) {
        best = (got: set.length, needed: needed);
      }
    }
    return best;
  }

  /// Whether this device is recovering an account: only then it takes
  /// pieces ([beginRecovery], [endRecovery]).
  bool get collecting {
    final int? since = _collectingSince;
    return since != null && _clock() - since < collectWindow.inMilliseconds;
  }

  /// Until when pieces are taken (millis), while [collecting].
  int? get collectingUntil {
    final int? since = _collectingSince;
    return collecting && since != null
        ? since + collectWindow.inMilliseconds
        : null;
  }

  /// The account of the pieces kept for [owner] (a key of [heldFor]; an
  /// address of 1.16.4 and earlier works too), to show its fingerprint to
  /// the person being helped.
  String? heldAccount(String owner) => _heldOf(owner)?.account;

  /// The address [owner]'s pieces came from (to name the person).
  String? heldFrom(String owner) => _heldOf(owner)?.from;

  _Held? _heldOf(String owner) =>
      _held[owner] ??
      _held[_unsignedKey(PeerShareCodec.normalizeAddress(owner))];

  String? _keyOf(String owner) {
    if (_held.containsKey(owner)) {
      return owner;
    }
    final String legacy = _unsignedKey(PeerShareCodec.normalizeAddress(owner));
    return _held.containsKey(legacy) ? legacy : null;
  }

  Future<void> start() => _started ??= _start();

  Future<void> _start() async {
    await _load();
    _frames = transport.frames.listen(
      (SignalTransportFrame f) => unawaitedLogged(
        _onFrame(f),
        context: 'Handling a recovery message failed',
      ),
    );
    _timer = Timer.periodic(tickInterval, (_) {
      unawaitedLogged(tick(), context: 'Wydanie klucza odzyskiwania');
    });
    await tick();
  }

  Future<void> stop() async {
    _timer?.cancel();
    await _frames?.cancel();
    await _changes.close();
  }

  // ---- as the owner ----

  /// Keeps [seal] (made when the person set the account password) and
  /// hands a new generation of pieces out from it.
  Future<void> setSeal(RecoverySeal seal) async {
    await start();
    _seal = seal;
    await _write(_sealKey, seal.toJson());
    _changed();
    await reconcile();
  }

  /// Hands out a new generation when the holders or the seal changed,
  /// sends what is unanswered or due again, and once the generation is
  /// complete tells the older holders to forget. Called on every tick and
  /// when the close friends may have changed.
  Future<void> reconcile() async {
    if (_reconciling) {
      _reconcileAgain = true;
      return;
    }
    _reconciling = true;
    try {
      do {
        _reconcileAgain = false;
        await _reconcileOnce();
      } while (_reconcileAgain);
    } finally {
      _reconciling = false;
    }
  }

  Future<void> _reconcileOnce() async {
    final RecoveryIdentity? id = identity();
    final RecoverySeal? seal = _seal;
    if (id == null) {
      return;
    }
    if (seal == null || !handsOut) {
      // Another device hands the pieces out. A circle of 1.16.4 set up on
      // this one goes once their generation is complete.
      final RecoveryGeneration? g = _generation;
      if (g != null && g.complete) {
        await _retireLegacy(g);
        if (await _remindRetired(id, g)) {
          await _saveOut();
        }
      }
      return;
    }
    final List<String>? wanted = holders();
    if (wanted == null) {
      return;
    }
    // One close friend cannot hold a piece alone: then nobody holds one.
    final List<String> next = wanted.length < kRecoveryCircleMinimum
        ? const <String>[]
        : <String>[
            for (final String h in wanted) PeerShareCodec.normalizeAddress(h),
          ];
    final RecoveryGeneration? g = _generation;
    if (g == null
        ? next.isNotEmpty
        : g.device != id.device ||
              g.sealAt != seal.at ||
              !setEquals(g.holders.toSet(), next.toSet())) {
      await _newGeneration(id, seal, next, g);
    }
    await _sendDue(id);
  }

  Future<void> _newGeneration(
    RecoveryIdentity id,
    RecoverySeal seal,
    List<String> next,
    RecoveryGeneration? before,
  ) async {
    final int now = _clock();
    final int g = before == null || before.generation < now
        ? now
        : before.generation + 1;
    for (final String h in before?.holders ?? const <String>[]) {
      if (!next.contains(h)) {
        _retired[h] = now;
      }
    }
    for (final String h in next) {
      _retired.remove(h);
    }
    _out.clear();
    _sent.clear();
    _reofferAt = now;
    if (next.isEmpty) {
      // Too few close friends: no piece is handed out, and those who held
      // one are told to forget it (the circle of 1.16.4 stays).
      _generation = RecoveryGeneration(
        generation: g,
        threshold: 0,
        device: id.device,
        sealAt: seal.at,
        holders: const <String>[],
      );
    } else {
      final List<RecoveryPiece> pieces = await createGenerationPieces(
        account: id.account,
        seal: seal,
        holders: next.length,
        generation: g,
      );
      for (int i = 0; i < next.length; i++) {
        _out[next[i]] = pieces[i].toJson();
      }
      _generation = RecoveryGeneration(
        generation: g,
        threshold: pieceThreshold(next.length),
        device: id.device,
        sealAt: seal.at,
        holders: next,
      );
    }
    await _saveGeneration();
    await _saveOut();
    _changed();
  }

  /// Sends the pieces not confirmed yet (and all of them every
  /// [kPieceReoffer]); once the generation is complete, tells everyone
  /// who held an older one to forget it.
  Future<void> _sendDue(RecoveryIdentity id) async {
    final RecoveryGeneration? g = _generation;
    if (g == null) {
      return;
    }
    final int now = _clock();
    final bool reoffer = now - _reofferAt >= kPieceReoffer.inMilliseconds;
    bool changed = false;
    for (final String h in g.holders) {
      final Map<String, dynamic>? piece = _out[h];
      if (piece == null) {
        continue;
      }
      final int? sent = _sent[h];
      final bool due =
          g.acks[h] != g.generation &&
          (sent == null || now - sent >= kPieceRetry.inMilliseconds);
      if (!due && !reoffer) {
        continue;
      }
      _sent[h] = now;
      changed = true;
      await _sendStore(id, h, piece, g.generation);
    }
    if (reoffer) {
      _reofferAt = now;
      changed = true;
    }
    // Confirmations came while the pieces went out: the generation as it
    // is now.
    final RecoveryGeneration? latest = _generation;
    if (latest != null &&
        latest.generation == g.generation &&
        (latest.holders.isEmpty || latest.complete)) {
      changed = await _tellToForget(id, latest) || changed;
    }
    if (changed) {
      await _saveOut();
    }
  }

  Future<bool> _tellToForget(RecoveryIdentity id, RecoveryGeneration g) async {
    bool changed = false;
    if (!g.cleared) {
      if (g.complete) {
        await _retireLegacy(g);
        // The holders drop the generation before this one.
        for (final String h in g.holders) {
          await _sendForget(id, h, g.generation);
        }
      }
      // As it is after the messages above (more confirmations may have
      // come meanwhile).
      final RecoveryGeneration? now = _generation;
      if (now != null && now.generation == g.generation) {
        _generation = now.copyWith(cleared: true);
      }
      await _saveGeneration();
      _changed();
      changed = true;
    }
    return await _remindRetired(id, g) || changed;
  }

  /// The circle of 1.16.4 and earlier is replaced by [g], complete: its
  /// people are told to forget their pieces too (those on 1.16.4 keep
  /// them: they ignore it). On whichever device of the account kept it.
  Future<void> _retireLegacy(RecoveryGeneration g) async {
    if (_circle.isEmpty) {
      return;
    }
    final int now = _clock();
    for (final String a in _circle) {
      if (!g.holders.contains(a)) {
        _retired[a] = now;
      }
    }
    _circle.clear();
    _acks.clear();
    await disk.delete(_circleKey);
    await disk.delete(_acksKey);
    await _saveOut();
    _changed();
  }

  /// Tells the former holders (again, every [kForgetRetry], for
  /// [kForgetTold]) to forget everything older than [g].
  Future<bool> _remindRetired(RecoveryIdentity id, RecoveryGeneration g) async {
    final int now = _clock();
    bool changed = false;
    for (final String a in _retired.keys.toList()) {
      if (now - _retired[a]! >= kForgetTold.inMilliseconds) {
        _retired.remove(a);
        _told.remove(a);
        changed = true;
        continue;
      }
      final int? told = _told[a];
      if (told != null && now - told < kForgetRetry.inMilliseconds) {
        continue;
      }
      _told[a] = now;
      changed = true;
      await _sendForget(id, a, g.generation);
    }
    return changed;
  }

  Future<void> _sendStore(
    RecoveryIdentity id,
    String holder,
    Map<String, dynamic> piece,
    int generation,
  ) async {
    final String helperAccount = accountOf(holder) ?? '';
    final int at = _clock();
    final RecoveryPiece? p = RecoveryPiece.fromJson(piece);
    if (p == null) {
      return;
    }
    await _send(holder, <String, dynamic>{
      'type': RecoveryMessages.store,
      'piece': piece,
      'a': id.account,
      'g': generation,
      if (helperAccount.isNotEmpty) 'h': helperAccount,
      'at': at,
      'cert': id.certificate.toJson(),
      'sig': b64(
        await id.deviceKey.sign(
          _storeBytes(id.account, generation, helperAccount, p.normal),
        ),
      ),
    });
  }

  Future<void> _sendForget(RecoveryIdentity id, String to, int g) async =>
      _send(to, <String, dynamic>{
        'type': RecoveryMessages.forget,
        'a': id.account,
        'g': g,
        'cert': id.certificate.toJson(),
        'sig': b64(await id.deviceKey.sign(_forgetBytes(id.account, g))),
      });

  static List<int> _storeBytes(
    String account,
    int g,
    String holder,
    Map<String, dynamic> normal,
  ) {
    final Object? box = normal['box'];
    return utf8.encode(
      <Object?>[
        'zen-recovery-store',
        account,
        g,
        holder,
        normal['share'],
        if (box is Map) box['n'],
        if (box is Map) box['c'],
        normal['salt'],
        normal['t'],
      ].join('|'),
    );
  }

  static List<int> _forgetBytes(String account, int g) =>
      utf8.encode('zen-recovery-forget|$account|$g');

  static List<int> _cancelBytes(String account, int at) =>
      utf8.encode('zen-recovery-cancel|$account|$at');

  /// Sends one piece to each helper (their order matches [helpers]), as
  /// 1.16.4 and earlier did: unsigned, the circle chosen by hand. Kept for
  /// the transition's tests.
  @visibleForTesting
  Future<void> distribute(
    List<String> helpers,
    List<RecoveryPiece> pieces,
  ) async {
    await start();
    _acks.clear();
    await _saveAcks();
    _circle
      ..clear()
      ..addAll(<String>[
        for (int i = 0; i < helpers.length && i < pieces.length; i++)
          PeerShareCodec.normalizeAddress(helpers[i]),
      ]);
    await _write(_circleKey, _circle);
    _changed();
    for (int i = 0; i < helpers.length && i < pieces.length; i++) {
      await _send(helpers[i], <String, dynamic>{
        'type': RecoveryMessages.store,
        'piece': pieces[i].toJson(),
      });
    }
  }

  /// On the owner's old device: tells [alarm]'s helper to stop, signed by
  /// this device (a device the account cut off is not listened to).
  Future<void> cancelAlarm(RecoveryAlarm alarm) async {
    _alarms.remove(alarm);
    final RecoveryIdentity? id = identity();
    final int at = _clock();
    await _send(alarm.helper, <String, dynamic>{
      'type': RecoveryMessages.cancel,
      if (id != null) ...<String, dynamic>{
        'a': id.account,
        'at': at,
        'cert': id.certificate.toJson(),
        'sig': b64(await id.deviceKey.sign(_cancelBytes(id.account, at))),
      },
    });
    _changed();
  }

  // ---- as a helper ----

  /// This device (a helper) agrees to give [owner]'s piece to the new
  /// device at [to] (its invitation code, link or address; a
  /// [FormatException] when it is none). The owner's devices get an alarm
  /// right away.
  Future<void> startHelping(
    String owner,
    String to, {
    RecoveryKind kind = RecoveryKind.normal,
  }) async {
    await start();
    final String? key = _keyOf(owner);
    if (key == null) {
      throw StateError(t('Nie przechowujesz klucza tej osoby.'));
    }
    if (kind != RecoveryKind.normal) {
      // No recovery without the password any more (1.15.4).
      throw StateError(t('Konto odzyskuje się tylko z hasłem.'));
    }
    final int now = _clock();
    final PendingRelease release = PendingRelease(
      owner: key,
      to: parseRecoveryDevice(to),
      kind: kind,
      due: now + kNormalDelay.inMilliseconds,
      at: now,
    );
    await _agree(release);
  }

  /// A release the owner stopped ([PendingRelease.stopped]) goes out after
  /// all, [kOverrideDelay] from now, with a new alarm; stopping it again
  /// does not count. For a phone the person lost to someone who keeps
  /// stopping every release: the helper talked to the person and is sure.
  Future<void> overrideRelease(PendingRelease release) async {
    await start();
    if (release.stopped == null || !_pending.contains(release)) {
      return;
    }
    final int now = _clock();
    await _agree(
      PendingRelease(
        owner: release.owner,
        to: release.to,
        kind: release.kind,
        due: now + kOverrideDelay.inMilliseconds,
        at: now,
        override: true,
      ),
    );
  }

  /// The helper changed their mind: [release] does not go out.
  Future<void> withdrawRelease(PendingRelease release) async {
    if (_pending.remove(release)) {
      await _savePending();
      _changed();
    }
  }

  Future<void> _agree(PendingRelease release) async {
    _requests.removeWhere((RecoveryHelpRequest r) => r.from == release.to);
    await _saveRequests();
    _pending
      ..removeWhere(
        (PendingRelease p) =>
            p.owner == release.owner &&
            p.to == release.to &&
            p.kind == release.kind,
      )
      ..add(release);
    await _savePending();
    final _Held? held = _held[release.owner];
    for (final String a in <String>{
      ?held?.from,
      if (held != null && held.signed)
        for (final String d in addressesOf(held.account))
          PeerShareCodec.normalizeAddress(d),
    }) {
      await _send(a, <String, dynamic>{
        'type': RecoveryMessages.alarm,
        'to': release.to,
        'kind': release.kind.name,
        'due': release.due,
        if (release.override) 'o': true,
      });
    }
    _changed();
  }

  /// Sends what is due; drops what the rules say goes; as the owner, hands
  /// out and repeats ([reconcile]).
  Future<void> tick() async {
    final int now = _clock();
    final List<PendingRelease> due = _pending
        .where((PendingRelease p) => p.stopped == null && p.due <= now)
        .toList();
    final List<PendingRelease> expired = _pending
        .where(
          (PendingRelease p) =>
              p.stopped != null &&
              now - p.stopped! >= kStoppedKept.inMilliseconds,
        )
        .toList();
    for (final PendingRelease p in due) {
      final _Held? held = _held[p.owner];
      // A passwordless release agreed to before 1.15.4 never goes out.
      final List<Object?> halves = p.kind == RecoveryKind.normal
          ? <Object?>[
              for (final Map<String, dynamic> piece
                  in held?.pieces ?? const <Map<String, dynamic>>[])
                piece['normal'],
            ]
          : const <Object?>[];
      if (held != null && halves.isNotEmpty) {
        await _send(p.to, <String, dynamic>{
          'type': RecoveryMessages.piece,
          'kind': p.kind.name,
          'half': halves.first,
          if (halves.length > 1) 'more': halves.sublist(1),
          // Whose key it is: the new device checks the seed against it.
          'account': held.account,
        });
      }
      _pending.remove(p);
    }
    _pending.removeWhere(expired.contains);
    if (due.isNotEmpty || expired.isNotEmpty) {
      await _savePending();
      _changed();
    }
    await _keepHeld(now);
    await reconcile();
  }

  /// Drops the pieces of people who are no longer friends here (after
  /// [kPiecesAfterFriendship]) and previous generations kept longer than
  /// [kPreviousPieceKept].
  Future<void> _keepHeld(int now) async {
    bool changed = false;
    for (final String key in _held.keys.toList()) {
      final _Held h = _held[key]!;
      // Not known yet (the friends still loading): nothing changes.
      final bool? byAccount = isFriendAccount(h.account);
      final bool? friend = byAccount == null
          ? null
          : byAccount || isFriend(h.from);
      if (friend == true && h.gone != null) {
        h.gone = null;
        changed = true;
      } else if (friend == false) {
        if (h.gone == null) {
          h.gone = now;
          changed = true;
        }
        if (now - h.gone! >= kPiecesAfterFriendship.inMilliseconds) {
          await _dropHeld(key);
          changed = true;
          continue;
        }
      }
      if (h.pieces.length > 1 &&
          now - h.at >= kPreviousPieceKept.inMilliseconds) {
        h.pieces = <Map<String, dynamic>>[h.pieces.first];
        changed = true;
      }
    }
    if (changed) {
      await _savePieces();
    }
  }

  Future<void> _dropHeld(String key) async {
    if (_held.remove(key) == null) {
      return;
    }
    _pending.removeWhere((PendingRelease p) => p.owner == key);
    await _savePending();
    _changed();
  }

  // ---- as the new device ----

  /// Forgets received halves (after a recovery, or to start over).
  Future<void> clearReceived() async {
    for (final List<Map<String, dynamic>> l in _received.values) {
      l.clear();
    }
    await _saveReceived();
    _changed();
  }

  /// Starts (or extends) a recovery on this device: from now on, for
  /// [collectWindow], it takes pieces sent to it. A fresh start forgets
  /// halves left from an earlier attempt.
  Future<void> beginRecovery() async {
    await start();
    if (!collecting) {
      for (final List<Map<String, dynamic>> l in _received.values) {
        l.clear();
      }
      _helpers.clear();
      await _saveReceived();
    }
    _collectingSince = _clock();
    await _saveCollecting();
    _changed();
  }

  /// Lists [address] (a helper's address or invitation code, as given by
  /// the person) as a helper of the recovery on this device: their pieces
  /// are taken. False when no recovery is started, the address is not
  /// valid or the list is full.
  Future<bool> allowHelper(String address) async {
    await start();
    final String a;
    try {
      a = PeerShareCodec.normalizeAddress(
        PeerShareCodec.parseTarget(address).address,
      );
    } on FormatException {
      return false;
    }
    if (!collecting ||
        a.isEmpty ||
        (_helpers.length >= maxHelpers && !_helpers.contains(a))) {
      return false;
    }
    if (_helpers.add(a)) {
      await _saveCollecting();
      _changed();
    }
    // The helper's device tells its person that someone asks for help,
    // with this device's address ready to use.
    try {
      await transport.send(
        remoteAddress: a,
        payload: const <String, dynamic>{'type': RecoveryMessages.help},
      );
    } on Object catch (error) {
      logZenWarning('Asking for recovery help was not sent: $error');
    }
    return true;
  }

  /// Takes [address] off the helpers of this recovery.
  Future<void> removeHelper(String address) async {
    await start();
    if (_helpers.remove(PeerShareCodec.normalizeAddress(address))) {
      await _saveCollecting();
      _changed();
    }
  }

  /// Ends the recovery (done or given up): pieces are no longer taken and
  /// the received ones are forgotten.
  Future<void> endRecovery() async {
    await start();
    _collectingSince = null;
    _helpers.clear();
    await disk.delete(_collectingKey);
    await clearReceived();
  }

  // ---- messages ----

  Future<void> _onFrame(SignalTransportFrame frame) async {
    final Object? type = frame.payload['type'];
    final String from = PeerShareCodec.normalizeAddress(frame.from);
    switch (type) {
      case RecoveryMessages.store:
        await _onStore(from, frame.payload);
      case RecoveryMessages.ack:
        await _onAck(from, frame.payload);
      case RecoveryMessages.forget:
        await _onForget(from, frame.payload);
      case RecoveryMessages.forgot:
        final Object? g = frame.payload['g'];
        final RecoveryIdentity? id = identity();
        if (g is int &&
            id != null &&
            frame.payload['a'] == id.account &&
            _retired.remove(from) != null) {
          _told.remove(from);
          await _saveOut();
        }
      case RecoveryMessages.alarm:
        final Object? to = frame.payload['to'];
        final Object? due = frame.payload['due'];
        final RecoveryKind? kind = RecoveryKind.values
            .where((RecoveryKind k) => k.name == frame.payload['kind'])
            .firstOrNull;
        if (isFriend(from) && to is String && due is int && kind != null) {
          final RecoveryAlarm alarm = RecoveryAlarm(
            helper: from,
            to: to,
            kind: kind,
            due: due,
            override: frame.payload['o'] == true,
          );
          _alarms
            ..removeWhere(
              (RecoveryAlarm a) => a.helper == from && a.to == alarm.to,
            )
            ..add(alarm);
          logZenWarning(
            'Someone in the circle wants to release the recovery key of this account.',
          );
          onAlarm?.call(alarm);
          _changed();
        }
      case RecoveryMessages.help:
        await _onHelpRequest(from);
      case RecoveryMessages.cancel:
        await _onCancel(from, frame.payload);
      case RecoveryMessages.piece:
        await _onPiece(from, frame.payload);
    }
  }

  /// The account a message [p] is signed for (`a`), when a device the
  /// account certified and did not cut off signed [bytes] of it; null
  /// otherwise.
  Future<String?> _signedBy(
    Map<String, dynamic> p,
    List<int> Function(String account) bytes,
  ) async {
    final Object? account = p['a'];
    final Object? sig = p['sig'];
    final DeviceCertificate? cert = DeviceCertificate.fromJson(p['cert']);
    if (account is! String ||
        sig is! String ||
        cert == null ||
        cert.account != account ||
        isRevoked(cert.account, cert.device)) {
      return null;
    }
    try {
      if (!await cert.verify() ||
          !await cert.verifyByDevice(bytes(account), sig)) {
        return null;
      }
    } on Object {
      return null;
    }
    return account;
  }

  Future<void> _onStore(String from, Map<String, dynamic> p) async {
    if (!isFriend(from)) {
      return;
    }
    final RecoveryPiece? piece = RecoveryPiece.fromJson(p['piece']);
    if (piece == null) {
      return;
    }
    final int now = _clock();
    if (p['sig'] == null) {
      // From 1.16.4 and earlier: kept under the sender's address, as then.
      final String key = _unsignedKey(from);
      final _Held? had = _held[key];
      if (had == null || piece.created >= had.newest) {
        if (had == null && _held.length >= maxHeld) {
          return;
        }
        _held[key] = _Held(
          account: piece.account,
          from: from,
          pieces: <Map<String, dynamic>>[piece.toJson()],
          at: now,
          signed: false,
        );
        await _savePieces();
      }
      await _ack(from, piece.account, piece.created);
      return;
    }
    final Object? g = p['g'];
    final Object? h = p['h'];
    final String own = identity()?.account ?? '';
    if (g is! int ||
        g != piece.generation ||
        (h is String && own.isNotEmpty && h != own)) {
      return; // meant for someone else, or not what was signed
    }
    final String? account = await _signedBy(
      p,
      (String a) => _storeBytes(a, g, h is String ? h : '', piece.normal),
    );
    final String? sender = accountOf(from);
    if (account == null ||
        piece.account != account ||
        (sender != null && sender != account)) {
      return;
    }
    final _Held held =
        _held[account] ??
        _Held(
          account: account,
          from: from,
          pieces: <Map<String, dynamic>>[],
          at: now,
        );
    if (!_held.containsKey(account) && _held.length >= maxHeld) {
      return;
    }
    // The pieces of 1.16.4 the same person handed out before: kept as the
    // previous generation until the new one is complete.
    for (final String key in _held.keys.toList()) {
      final _Held old = _held[key]!;
      if (!old.signed &&
          old.account == account &&
          (old.from == from || accountOf(old.from) == account)) {
        held.pieces.addAll(old.pieces);
        _held.remove(key);
        for (int i = 0; i < _pending.length; i++) {
          final PendingRelease r = _pending[i];
          if (r.owner == key) {
            _pending[i] = PendingRelease(
              owner: account,
              to: r.to,
              kind: r.kind,
              due: r.due,
              at: r.at,
              override: r.override,
              stopped: r.stopped,
            );
          }
        }
        await _savePending();
      }
    }
    final int newest = held.pieces.isEmpty ? 0 : held.newest;
    held.pieces.removeWhere(
      (Map<String, dynamic> x) =>
          RecoveryPiece.fromJson(x)?.generation == piece.generation,
    );
    held.pieces
      ..add(piece.toJson())
      ..sort(
        (Map<String, dynamic> a, Map<String, dynamic> b) =>
            (RecoveryPiece.fromJson(b)?.generation ?? 0).compareTo(
              RecoveryPiece.fromJson(a)?.generation ?? 0,
            ),
      );
    if (held.pieces.length > 2) {
      held.pieces = held.pieces.sublist(0, 2);
    }
    held
      ..from = from
      ..gone = null;
    if (piece.generation > newest) {
      held.at = now;
    }
    _held[account] = held;
    await _savePieces();
    await _ack(from, account, held.newest);
    _changed();
  }

  Future<void> _ack(String to, String account, int created) async {
    await _send(to, <String, dynamic>{
      'type': RecoveryMessages.ack,
      'account': account,
      'created': created,
    });
    _changed();
  }

  Future<void> _onAck(String from, Map<String, dynamic> p) async {
    final Object? created = p['created'];
    if (!isFriend(from) || created is! int) {
      return;
    }
    final RecoveryGeneration? g = _generation;
    if (g != null &&
        g.holders.contains(from) &&
        created == g.generation &&
        g.acks[from] != created) {
      _generation = g.copyWith(acks: <String, int>{...g.acks, from: created});
      await _saveGeneration();
      _changed();
      final RecoveryIdentity? id = identity();
      if (_generation!.cleared && id != null) {
        // Confirmed after the older generations were cleared: this holder
        // drops the one before too.
        await _sendForget(id, from, created);
      } else if (_generation!.complete) {
        // Complete now: the older holders hear at once.
        await reconcile();
      }
      return;
    }
    if (_circle.contains(from)) {
      _acks[from] = created;
      await _saveAcks();
      _changed();
    }
  }

  /// The owner says to forget everything of theirs older than generation
  /// `g`: done at once (the owner sends it only once the new generation
  /// is complete), and answered.
  Future<void> _onForget(String from, Map<String, dynamic> p) async {
    final Object? g = p['g'];
    if (g is! int) {
      return;
    }
    final String? account = await _signedBy(
      p,
      (String a) => _forgetBytes(a, g),
    );
    if (account == null) {
      return;
    }
    bool changed = false;
    for (final String key in _held.keys.toList()) {
      final _Held h = _held[key]!;
      if (h.account != account) {
        continue;
      }
      final int before = h.pieces.length;
      // Pieces of 1.16.4 and earlier (unsigned, or kept as the one before)
      // are older than any generation, whatever their time says.
      h.pieces.removeWhere((Map<String, dynamic> x) {
        final RecoveryPiece? piece = RecoveryPiece.fromJson(x);
        return !h.signed ||
            piece == null ||
            piece.normal['v'] != kSealedPieceVersion ||
            piece.generation < g;
      });
      if (h.pieces.isEmpty) {
        await _dropHeld(key);
        changed = true;
      } else if (h.pieces.length != before) {
        changed = true;
      }
    }
    if (changed) {
      await _savePieces();
      _changed();
    }
    await _send(from, <String, dynamic>{
      'type': RecoveryMessages.forgot,
      'a': account,
      'g': g,
    });
  }

  /// The owner's device stops releases of its pieces: signed by a device
  /// the account did not cut off, and newer than the release; unsigned
  /// only from the address an unsigned piece came from, not unlinked. A
  /// release agreed to again after a stop ([overrideRelease]) is not
  /// stopped.
  Future<void> _onCancel(String from, Map<String, dynamic> p) async {
    final int now = _clock();
    final Object? at = p['at'];
    final String? account = p['sig'] == null || at is! int
        ? null
        : await _signedBy(p, (String a) => _cancelBytes(a, at));
    bool stops(PendingRelease r) {
      if (r.override || r.stopped != null) {
        return false;
      }
      final _Held? held = _held[r.owner];
      if (held == null) {
        return false;
      }
      if (account != null) {
        const int slack = 60 * 60 * 1000;
        return held.signed &&
            held.account == account &&
            (at! as int) >= r.at - slack &&
            (at as int) <= now + slack;
      }
      return !held.signed && held.from == from && !isUnlinkedAddress(from);
    }

    bool changed = false;
    for (int i = 0; i < _pending.length; i++) {
      final PendingRelease r = _pending[i];
      if (stops(r)) {
        _pending[i] = PendingRelease(
          owner: r.owner,
          to: r.to,
          kind: r.kind,
          due: r.due,
          at: r.at,
          stopped: now,
        );
        changed = true;
      }
    }
    if (changed) {
      await _savePending();
      _changed();
    }
  }

  /// A new device named this device as a helper. Only a device that keeps
  /// someone's piece listens; each new device is told once (until answered
  /// or dismissed), and only [maxRequests] are kept, so a stranger with
  /// this person's invitation code cannot flood them.
  Future<void> _onHelpRequest(String from) async {
    if (_held.isEmpty || from.isEmpty || isFriend(from)) {
      // A friend's own device is no new device of someone recovering.
      return;
    }
    final int now = _clock();
    _requests.removeWhere(
      (RecoveryHelpRequest r) => now - r.at >= requestLifetime.inMilliseconds,
    );
    if (_requests.any((RecoveryHelpRequest r) => r.from == from) ||
        _requests.length >= maxRequests) {
      return;
    }
    final RecoveryHelpRequest request = RecoveryHelpRequest(
      from: from,
      at: now,
    );
    _requests.add(request);
    await _saveRequests();
    onHelpRequested?.call(request);
    _changed();
  }

  /// Halves for the recovery on this device.
  Future<void> _onPiece(String from, Map<String, dynamic> payload) async {
    if (!collecting) {
      return; // nobody started a recovery here: nothing is taken
    }
    if (!_helpers.contains(from) && !isFriend(from)) {
      // Not someone the person named: fresh addresses cost nothing, so they
      // must not take the places of the real helpers.
      return;
    }
    final RecoveryKind? kind = RecoveryKind.values
        .where((RecoveryKind k) => k.name == payload['kind'])
        .firstOrNull;
    if (kind == null) {
      return;
    }
    final Object? more = payload['more'];
    bool changed = false;
    for (final Object? raw in <Object?>[
      payload['half'],
      if (more is List) ...more.take(1),
    ]) {
      final Map<String, dynamic>? half = _receivedHalf(
        kind,
        raw,
        account: payload['account'],
        from: from,
      );
      if (half == null) {
        continue;
      }
      final List<Map<String, dynamic>> list = _received[kind]!;
      // At most two halves of each kind per sender (its newest generation
      // and the one before), so one helper cannot crowd out the others.
      if (list.length >= maxReceived ||
          list.where((Map<String, dynamic> h) => h['from'] == from).length >=
              2 ||
          list.any(
            (Map<String, dynamic> h) =>
                h['share'] == half['share'] ||
                (h['from'] == from &&
                    jsonEncode(h['box']) == jsonEncode(half['box'])),
          )) {
        continue;
      }
      list.add(half);
      changed = true;
    }
    if (changed) {
      await _saveReceived();
      _changed();
    }
  }

  /// [half] as kept: the fields recovery uses, the account it names and
  /// who sent it — after recovery they are greeted first, and they
  /// hold the sealed backup of friends and groups. `null` for a
  /// malformed half, a bad account or an Argon2 cost not accepted.
  Map<String, dynamic>? _receivedHalf(
    RecoveryKind kind,
    Object? half, {
    required Object? account,
    required Object? from,
  }) {
    final Map<String, dynamic>? fields = recoveryHalfFields(
      half,
      normal: kind == RecoveryKind.normal,
      acceptedCosts: acceptedCosts,
    );
    if (fields == null ||
        from is! String ||
        from.isEmpty ||
        account is! String ||
        !isRecoveryAccountId(account)) {
      return null;
    }
    return <String, dynamic>{...fields, 'account': account, 'from': from};
  }

  // ---- the account's other devices ----

  /// What the account's other devices keep the same: the pieces kept for
  /// others (each account's as one unit) and this account's generation.
  Map<String, Object?> syncState() => <String, Object?>{
    'held': <String, Object?>{
      for (final MapEntry<String, _Held> e in _held.entries)
        e.key: e.value.toJson(),
    },
    'own': ?_generation?.toJson(),
  };

  /// Takes the state the account's devices agreed on ([syncState]): pieces
  /// that came to another device, or went from it (forgotten there); the
  /// newer generation of this account's pieces, with every confirmation.
  Future<void> takeSyncState(Map<String, Object?> state) async {
    await start();
    final Object? held = state['held'];
    final Map<String, _Held> incoming = <String, _Held>{
      if (held is Map)
        for (final MapEntry<Object?, Object?> e in held.entries)
          if (e.key is String && _Held.fromJson(e.value) != null)
            e.key! as String: _Held.fromJson(e.value)!,
    };
    bool piecesChanged = false;
    for (final String key in _held.keys.toList()) {
      if (!incoming.containsKey(key)) {
        await _dropHeld(key);
        piecesChanged = true;
      }
    }
    for (final MapEntry<String, _Held> e in incoming.entries) {
      final _Held? mine = _held[e.key];
      if (mine == null ||
          e.value.newest > mine.newest ||
          (e.value.newest == mine.newest &&
              e.value.pieces.length != mine.pieces.length)) {
        _held[e.key] = e.value;
        piecesChanged = true;
      }
    }
    if (piecesChanged) {
      await _savePieces();
    }
    final RecoveryGeneration? theirs = RecoveryGeneration.fromJson(
      state['own'],
    );
    final RecoveryGeneration? mine = _generation;
    if (theirs != null &&
        (mine == null || theirs.generation > mine.generation)) {
      _generation = theirs;
      await _saveGeneration();
      piecesChanged = true;
    } else if (theirs != null && theirs.generation == mine!.generation) {
      final Map<String, int> acks = <String, int>{...mine.acks, ...theirs.acks};
      if (acks.length != mine.acks.length ||
          (theirs.cleared && !mine.cleared)) {
        _generation = mine.copyWith(
          acks: acks,
          cleared: mine.cleared || theirs.cleared,
        );
        await _saveGeneration();
        piecesChanged = true;
      }
    }
    if (piecesChanged) {
      _changed();
    }
  }

  // ---- storage ----

  Future<void> _send(String to, Map<String, dynamic> payload) async {
    try {
      await transport.send(remoteAddress: to, payload: payload);
    } on Object catch (error) {
      logZenWarning('A recovery message was not sent: $error');
    }
  }

  void _changed() {
    if (!_changes.isClosed) {
      _changes.add(null);
    }
  }

  Future<Object?> _read(String key) async {
    final Uint8List? raw = await disk.read(key);
    if (raw == null) {
      return null;
    }
    try {
      return jsonDecode(utf8.decode(raw));
    } on FormatException {
      logZenWarning('Recovery data ($key) is damaged.');
      return null;
    }
  }

  Future<void> _write(String key, Object? json) =>
      disk.write(key, Uint8List.fromList(utf8.encode(jsonEncode(json))));

  Future<void> _load() async {
    final Object? pieces = await _read(_piecesKey);
    if (pieces is Map) {
      pieces.forEach((Object? k, Object? v) {
        final _Held? h = _Held.fromJson(v);
        if (k is String && h != null && _held.length < maxHeld) {
          _held[k] = h;
        }
      });
    }
    // Pieces kept by 1.16.4 and earlier (by owner address): moved over.
    final Object? old = await _read(_heldKey);
    if (old is Map) {
      final int now = _clock();
      old.forEach((Object? k, Object? v) {
        final RecoveryPiece? piece = RecoveryPiece.fromJson(v);
        if (k is String && piece != null && _held.length < maxHeld) {
          _held.putIfAbsent(
            _unsignedKey(k),
            () => _Held(
              account: piece.account,
              from: k,
              pieces: <Map<String, dynamic>>[piece.toJson()],
              at: now,
              signed: false,
            ),
          );
        }
      });
      await _savePieces();
      await disk.delete(_heldKey);
    }
    final Object? pending = await _read(_pendingKey);
    if (pending is List) {
      _pending.addAll(<PendingRelease>[
        for (final Object? p in pending)
          if (PendingRelease.fromJson(p) case final PendingRelease r)
            // Releases agreed to by 1.16.4 name the owner's address.
            _held.containsKey(r.owner) ||
                    !_held.containsKey(_unsignedKey(r.owner))
                ? r
                : PendingRelease(
                    owner: _unsignedKey(r.owner),
                    to: r.to,
                    kind: r.kind,
                    due: r.due,
                    at: r.at,
                    override: r.override,
                    stopped: r.stopped,
                  ),
      ]);
    }
    final Object? acks = await _read(_acksKey);
    if (acks is Map) {
      acks.forEach((Object? k, Object? v) {
        if (k is String && v is int) {
          _acks[k] = v;
        }
      });
    }
    final Object? received = await _read(_receivedKey);
    if (received is Map) {
      for (final RecoveryKind kind in RecoveryKind.values) {
        final Object? list = received[kind.name];
        if (list is List) {
          _received[kind]!.addAll(<Map<String, dynamic>>[
            for (final Map<String, dynamic> h
                in list.whereType<Map<String, dynamic>>().take(maxReceived))
              ?_receivedHalf(kind, h, account: h['account'], from: h['from']),
          ]);
        }
      }
    }
    final Object? circle = await _read(_circleKey);
    if (circle is List) {
      _circle.addAll(circle.whereType<String>().take(maxHelpers));
    }
    final Object? requests = await _read(_requestsKey);
    if (requests is List) {
      _requests.addAll(<RecoveryHelpRequest>[
        for (final Object? r in requests.take(maxRequests))
          ?RecoveryHelpRequest.fromJson(r),
      ]);
    }
    final Object? collecting = await _read(_collectingKey);
    if (collecting is Map && collecting['since'] is int) {
      _collectingSince = collecting['since'] as int;
      final Object? helpers = collecting['helpers'];
      if (helpers is List) {
        _helpers.addAll(helpers.whereType<String>().take(maxHelpers));
      }
    }
    _seal = RecoverySeal.fromJson(await _read(_sealKey));
    _generation = RecoveryGeneration.fromJson(await _read(_generationKey));
    final Object? out = await _read(_outKey);
    if (out is Map) {
      final Object? pieces = out['pieces'];
      if (pieces is Map) {
        pieces.forEach((Object? k, Object? v) {
          if (k is String && RecoveryPiece.fromJson(v) != null) {
            _out[k] = v! as Map<String, dynamic>;
          }
        });
      }
      void ints(Object? from, Map<String, int> into) {
        if (from is Map) {
          from.forEach((Object? k, Object? v) {
            if (k is String && v is int) {
              into[k] = v;
            }
          });
        }
      }

      ints(out['sent'], _sent);
      ints(out['retired'], _retired);
      ints(out['told'], _told);
      final Object? reoffer = out['reoffer'];
      _reofferAt = reoffer is int ? reoffer : 0;
    }
  }

  Future<void> _saveCollecting() => _write(_collectingKey, <String, dynamic>{
    'since': _collectingSince,
    'helpers': _helpers.toList(),
  });

  Future<void> _savePieces() => _write(_piecesKey, <String, dynamic>{
    for (final MapEntry<String, _Held> e in _held.entries)
      e.key: e.value.toJson(),
  });

  Future<void> _saveGeneration() async {
    final RecoveryGeneration? g = _generation;
    if (g == null) {
      await disk.delete(_generationKey);
    } else {
      await _write(_generationKey, g.toJson());
    }
  }

  Future<void> _saveOut() => _write(_outKey, <String, dynamic>{
    'pieces': _out,
    'sent': _sent,
    'reoffer': _reofferAt,
    'retired': _retired,
    'told': _told,
  });

  Future<void> _saveRequests() => _write(_requestsKey, <Map<String, dynamic>>[
    for (final RecoveryHelpRequest r in _requests) r.toJson(),
  ]);

  Future<void> _savePending() => _write(_pendingKey, <Map<String, dynamic>>[
    for (final PendingRelease p in _pending) p.toJson(),
  ]);

  Future<void> _saveAcks() => _write(_acksKey, _acks);

  Future<void> _saveReceived() => _write(_receivedKey, <String, dynamic>{
    for (final MapEntry<RecoveryKind, List<Map<String, dynamic>>> e
        in _received.entries)
      e.key.name: e.value,
  });
}
