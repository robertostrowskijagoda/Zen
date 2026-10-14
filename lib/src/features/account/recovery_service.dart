import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
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
/// * `rc_piece {kind, half}`: helper → new device, after the delay.
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
  }) : _clock = clock ?? (() => DateTime.now().millisecondsSinceEpoch);

  static const String _heldKey = 'recovery/held';
  static const String _pendingKey = 'recovery/pending';
  static const String _acksKey = 'recovery/acks';
  static const String _receivedKey = 'recovery/received';

  /// Pieces kept from strangers for one recovery, at most.
  static const int maxReceived = 24;

  final SignalTransport transport;
  final LedgerDisk disk;
  final bool Function(String address) isFriend;
  final int Function() _clock;
  final Duration tickInterval;

  /// Owner address → piece.
  final Map<String, Map<String, dynamic>> _held =
      <String, Map<String, dynamic>>{};
  final List<PendingRelease> _pending = <PendingRelease>[];

  /// Helper address → `created` of the piece they confirmed.
  final Map<String, int> _acks = <String, int>{};

  /// Received halves: `normal` / `emergency` lists (deduplicated by share).
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

  /// The friends who sent pieces (to greet after recovery).
  List<String> get helperAddresses => <String>{
    for (final List<Map<String, dynamic>> list in _received.values)
      for (final Map<String, dynamic> h in list)
        if (h['from'] is String) h['from'] as String,
  }.toList();

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
      throw StateError('Nie przechowujesz klucza tej osoby.');
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
      if (half != null) {
        await transport.send(
          remoteAddress: p.to,
          payload: <String, dynamic>{
            'type': RecoveryMessages.piece,
            'kind': p.kind.name,
            'half': half,
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
        final RecoveryKind? kind = RecoveryKind.values
            .where((RecoveryKind k) => k.name == frame.payload['kind'])
            .firstOrNull;
        final Object? half = frame.payload['half'];
        if (kind == null || half is! Map<String, dynamic>) {
          return;
        }
        final List<Map<String, dynamic>> list = _received[kind]!;
        if (list.length >= maxReceived ||
            list.any((Map<String, dynamic> h) => h['share'] == half['share'])) {
          return;
        }
        // Who sent it: after recovery they are greeted first, and they hold
        // the sealed backup of friends and groups (§6).
        list.add(<String, dynamic>{...half, 'from': from});
        await _saveReceived();
        _changed();
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
          _received[kind]!.addAll(list.whereType<Map<String, dynamic>>());
        }
      }
    }
  }

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
