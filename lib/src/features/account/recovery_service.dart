import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/core/logging/zen_log.dart';
import 'package:zen/src/features/account/account_recovery.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';

/// Messages of the recovery protocol (§6.3), over the signal transport:
///
/// * `rc_store {piece}`: owner → helper (a friend in the circle);
/// * `rc_ack {account, created}`: helper → owner;
/// * `rc_alarm {to, kind, due}`: helper → owner's old devices, when the
///   helper agreed to release the piece to a new device;
/// * `rc_cancel {}`: owner's old device → helper ("to nie ja");
/// * `rc_piece {kind, half, account}`: helper → new device, after the
///   delay. `account` is the account the piece is for; the account the
///   pieces open must still be confirmed by its fingerprint.
///
/// The new device takes pieces only while a recovery is started on it
/// ([RecoveryService.beginRecovery]), only from its friends and the helpers
/// the person listed there ([RecoveryService.allowHelper]), at most one of
/// each kind per sender, and only with the Argon2 costs this app writes.
abstract final class RecoveryMessages {
  static const String store = 'rc_store';
  static const String ack = 'rc_ack';
  static const String alarm = 'rc_alarm';
  static const String cancel = 'rc_cancel';
  static const String piece = 'rc_piece';
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
  });

  /// Owner's (old) address: whose piece it is.
  final String owner;

  /// The new device's address.
  final String to;
  final RecoveryKind kind;
  final int due;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'owner': owner,
    'to': to,
    'kind': kind.name,
    'due': due,
  };

  static PendingRelease? fromJson(Object? json) {
    if (json is! Map) {
      return null;
    }
    final Object? owner = json['owner'];
    final Object? to = json['to'];
    final Object? due = json['due'];
    final RecoveryKind? kind = RecoveryKind.values
        .where((RecoveryKind k) => k.name == json['kind'])
        .firstOrNull;
    if (owner is! String || to is! String || due is! int || kind == null) {
      return null;
    }
    return PendingRelease(owner: owner, to: to, kind: kind, due: due);
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
  });

  final String helper;
  final String to;
  final RecoveryKind kind;
  final int due;
}

/// Keeps the pieces this device holds for friends, the releases it agreed
/// to, the acknowledgements of its own pieces and the pieces received for
/// a recovery in progress.
final class RecoveryService {
  RecoveryService({
    required this.transport,
    required this.disk,
    required this.isFriend,
    int Function()? clock,
    this.tickInterval = const Duration(minutes: 1),
    this.acceptedCosts = kAcceptedRecoveryCosts,
  }) : _clock = clock ?? (() => DateTime.now().millisecondsSinceEpoch);

  static const String _heldKey = 'recovery/held';
  static const String _pendingKey = 'recovery/pending';
  static const String _acksKey = 'recovery/acks';
  static const String _receivedKey = 'recovery/received';
  static const String _collectingKey = 'recovery/collecting';

  /// Pieces kept for one recovery, at most.
  static const int maxReceived = 24;

  /// Helpers the person may list for one recovery, at most.
  static const int maxHelpers = 24;

  /// How long a started recovery takes pieces (the emergency delay with
  /// room for helpers who agree late).
  static const Duration collectWindow = Duration(days: 30);

  final SignalTransport transport;
  final LedgerDisk disk;
  final bool Function(String address) isFriend;
  final int Function() _clock;
  final Duration tickInterval;

  /// Argon2 costs a received `normal` half may ask for.
  final List<PasswordCost> acceptedCosts;

  /// When the recovery on this device was started (millis), if it was.
  int? _collectingSince;

  /// Addresses of the helpers the person listed for this recovery: with
  /// friends, the only senders whose pieces are taken.
  final Set<String> _helpers = <String>{};

  /// Owner address → piece.
  final Map<String, Map<String, dynamic>> _held =
      <String, Map<String, dynamic>>{};
  final List<PendingRelease> _pending = <PendingRelease>[];

  /// Helper address → `created` of the piece they confirmed.
  final Map<String, int> _acks = <String, int>{};

  /// Received halves: `normal` / `emergency` lists (one per sender, each
  /// share once), with the account they name and who sent them.
  final Map<RecoveryKind, List<Map<String, dynamic>>> _received =
      <RecoveryKind, List<Map<String, dynamic>>>{
        RecoveryKind.normal: <Map<String, dynamic>>[],
        RecoveryKind.emergency: <Map<String, dynamic>>[],
      };
  final List<RecoveryAlarm> _alarms = <RecoveryAlarm>[];
  final StreamController<void> _changes = StreamController<void>.broadcast();
  StreamSubscription<SignalTransportFrame>? _frames;
  Timer? _timer;
  Future<void>? _started;

  /// Fires after anything shown in the UI changed.
  Stream<void> get changes => _changes.stream;

  /// Owners whose pieces this device keeps (addresses).
  Iterable<String> get heldFor => _held.keys;
  List<PendingRelease> get pending =>
      List<PendingRelease>.unmodifiable(_pending);
  Map<String, int> get acks => Map<String, int>.unmodifiable(_acks);
  List<RecoveryAlarm> get alarms => List<RecoveryAlarm>.unmodifiable(_alarms);
  int receivedCount(RecoveryKind kind) => _received[kind]!.length;
  List<Map<String, dynamic>> received(RecoveryKind kind) =>
      List<Map<String, dynamic>>.unmodifiable(_received[kind]!);

  /// The helpers the person listed for the recovery on this device.
  Set<String> get allowedHelpers => Set<String>.unmodifiable(_helpers);

  /// The friends who sent pieces (to greet after recovery).
  List<String> get helperAddresses => <String>{
    for (final List<Map<String, dynamic>> list in _received.values)
      for (final Map<String, dynamic> h in list)
        if (h['from'] is String) h['from'] as String,
  }.toList();

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

  /// The account of the piece kept for [owner] (to show its fingerprint
  /// to the person being helped), if any.
  String? heldAccount(String owner) => RecoveryPiece.fromJson(
    _held[PeerShareCodec.normalizeAddress(owner)],
  )?.account;

  Future<void> start() => _started ??= _start();

  Future<void> _start() async {
    await _load();
    _frames = transport.frames.listen(
      (SignalTransportFrame f) => unawaitedLogged(
        _onFrame(f),
        context: 'Obsługa wiadomości odzyskiwania nie udała się',
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

  /// Sends one piece to each helper (their order matches [helpers]).
  Future<void> distribute(
    List<String> helpers,
    List<RecoveryPiece> pieces,
  ) async {
    await start();
    _acks.clear();
    await _saveAcks();
    for (int i = 0; i < helpers.length && i < pieces.length; i++) {
      await transport.send(
        remoteAddress: helpers[i],
        payload: <String, dynamic>{
          'type': RecoveryMessages.store,
          'piece': pieces[i].toJson(),
        },
      );
    }
  }

  /// This device (a helper) agrees to give [owner]'s piece to the new
  /// device at [to]. The owner's devices get an alarm right away.
  Future<void> startHelping(
    String owner,
    String to, {
    RecoveryKind kind = RecoveryKind.normal,
  }) async {
    await start();
    final String o = PeerShareCodec.normalizeAddress(owner);
    if (!_held.containsKey(o)) {
      throw StateError(t('Nie przechowujesz klucza tej osoby.'));
    }
    final int due =
        _clock() +
        (kind == RecoveryKind.normal ? kNormalDelay : kEmergencyDelay)
            .inMilliseconds;
    final PendingRelease release = PendingRelease(
      owner: o,
      to: PeerShareCodec.normalizeAddress(to),
      kind: kind,
      due: due,
    );
    _pending
      ..removeWhere(
        (PendingRelease p) =>
            p.owner == o && p.to == release.to && p.kind == kind,
      )
      ..add(release);
    await _savePending();
    await transport.send(
      remoteAddress: o,
      payload: <String, dynamic>{
        'type': RecoveryMessages.alarm,
        'to': release.to,
        'kind': kind.name,
        'due': due,
      },
    );
    _changed();
  }

  /// On the owner's old device: tells [helper] to stop.
  Future<void> cancelAlarm(RecoveryAlarm alarm) async {
    _alarms.remove(alarm);
    await transport.send(
      remoteAddress: alarm.helper,
      payload: const <String, dynamic>{'type': RecoveryMessages.cancel},
    );
    _changed();
  }

  /// Sends what is due.
  Future<void> tick() async {
    final int now = _clock();
    final List<PendingRelease> due = _pending
        .where((PendingRelease p) => p.due <= now)
        .toList();
    if (due.isEmpty) {
      return;
    }
    for (final PendingRelease p in due) {
      final Map<String, dynamic>? piece = _held[p.owner];
      final Object? half = piece?[p.kind.name];
      final Object? account = piece?['account'];
      if (half != null) {
        await transport.send(
          remoteAddress: p.to,
          payload: <String, dynamic>{
            'type': RecoveryMessages.piece,
            'kind': p.kind.name,
            'half': half,
            // Whose key it is: the new device checks the seed against it.
            'account': account,
          },
        );
      }
      _pending.remove(p);
    }
    await _savePending();
    _changed();
  }

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

  Future<void> _onFrame(SignalTransportFrame frame) async {
    final Object? type = frame.payload['type'];
    final String from = PeerShareCodec.normalizeAddress(frame.from);
    switch (type) {
      case RecoveryMessages.store:
        if (!isFriend(from)) {
          return;
        }
        final RecoveryPiece? piece = RecoveryPiece.fromJson(
          frame.payload['piece'],
        );
        if (piece == null) {
          return;
        }
        final int? had = RecoveryPiece.fromJson(_held[from])?.created;
        if (had == null || piece.created >= had) {
          _held[from] = piece.toJson();
          await _saveHeld();
        }
        await transport.send(
          remoteAddress: from,
          payload: <String, dynamic>{
            'type': RecoveryMessages.ack,
            'account': piece.account,
            'created': piece.created,
          },
        );
        _changed();
      case RecoveryMessages.ack:
        final Object? created = frame.payload['created'];
        if (isFriend(from) && created is int) {
          _acks[from] = created;
          await _saveAcks();
          _changed();
        }
      case RecoveryMessages.alarm:
        final Object? to = frame.payload['to'];
        final Object? due = frame.payload['due'];
        final RecoveryKind? kind = RecoveryKind.values
            .where((RecoveryKind k) => k.name == frame.payload['kind'])
            .firstOrNull;
        if (isFriend(from) && to is String && due is int && kind != null) {
          _alarms.add(
            RecoveryAlarm(helper: from, to: to, kind: kind, due: due),
          );
          logZenWarning(
            'Ktoś z kręgu chce wydać klucz odzyskiwania Twojego konta.',
          );
          _changed();
        }
      case RecoveryMessages.cancel:
        // Only the owner (their old address) can stop a release.
        final int before = _pending.length;
        _pending.removeWhere((PendingRelease p) => p.owner == from);
        if (_pending.length != before) {
          await _savePending();
          _changed();
        }
      case RecoveryMessages.piece:
        await _onPiece(from, frame.payload);
    }
  }

  /// A half for the recovery on this device.
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
    final Map<String, dynamic>? half = _receivedHalf(
      kind,
      payload['half'],
      account: payload['account'],
      from: from,
    );
    if (half == null) {
      return;
    }
    final List<Map<String, dynamic>> list = _received[kind]!;
    // One half of each kind per sender, so one helper cannot crowd out
    // the others.
    if (list.length >= maxReceived ||
        list.any(
          (Map<String, dynamic> h) =>
              h['from'] == from || h['share'] == half['share'],
        )) {
      return;
    }
    list.add(half);
    await _saveReceived();
    _changed();
  }

  /// [half] as kept: the fields recovery uses, the account it names and
  /// who sent it — after recovery they are greeted first, and they
  /// hold the sealed backup of friends and groups (§6). `null` for a
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
      logZenWarning('Dane odzyskiwania ($key) są uszkodzone.');
      return null;
    }
  }

  Future<void> _write(String key, Object? json) =>
      disk.write(key, Uint8List.fromList(utf8.encode(jsonEncode(json))));

  Future<void> _load() async {
    final Object? held = await _read(_heldKey);
    if (held is Map) {
      held.forEach((Object? k, Object? v) {
        if (k is String && v is Map<String, dynamic>) {
          _held[k] = v;
        }
      });
    }
    final Object? pending = await _read(_pendingKey);
    if (pending is List) {
      _pending.addAll(<PendingRelease>[
        for (final Object? p in pending) ?PendingRelease.fromJson(p),
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
                in list.whereType<Map<String, dynamic>>())
              ?_receivedHalf(kind, h, account: h['account'], from: h['from']),
          ]);
        }
      }
    }
    final Object? collecting = await _read(_collectingKey);
    if (collecting is Map && collecting['since'] is int) {
      _collectingSince = collecting['since'] as int;
      final Object? helpers = collecting['helpers'];
      if (helpers is List) {
        _helpers.addAll(helpers.whereType<String>().take(maxHelpers));
      }
    }
  }

  Future<void> _saveCollecting() => _write(_collectingKey, <String, dynamic>{
    'since': _collectingSince,
    'helpers': _helpers.toList(),
  });

  Future<void> _saveHeld() => _write(_heldKey, _held);

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
