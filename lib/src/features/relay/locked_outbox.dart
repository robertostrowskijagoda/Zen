import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:zen/src/core/logging/zen_log.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';

/// Most payloads the locked service keeps delivering.
const int kLockedOutboxMaxItems = 300;

/// Most bytes of sealed envelopes in the kit.
const int kLockedOutboxMaxBytes = 4 * 1024 * 1024;

/// One payload of this device's queue, as the locked service delivers it:
/// sealed end to end for its recipient (`RelayEnvelope` JSON) by the
/// unlocked app. The service never sees what is inside, only where it goes.
@immutable
final class LockedOutboxItem {
  const LockedOutboxItem({
    required this.id,
    required this.recipient,
    required this.envelope,
    required this.expiresAtMillis,
    this.mailboxes = const <String>[],
    this.token,
    this.direct = true,
  });

  /// The payload's reliable id (`_rid`), which the recipient confirms.
  final String id;

  /// Canonical address of the recipient.
  final String recipient;

  /// The sealed envelope, as relays hold it.
  final Map<String, dynamic> envelope;
  final int expiresAtMillis;

  /// The recipient's mailboxes that do not hold it yet.
  final List<String> mailboxes;

  /// This device's deposit token for the recipient's mailboxes.
  final String? token;

  /// Whether it also goes to the recipient itself (parts of a large
  /// payload go to the mailboxes only).
  final bool direct;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'to': recipient,
    'env': envelope,
    'x': expiresAtMillis,
    if (mailboxes.isNotEmpty) 'mb': mailboxes,
    'tk': ?token,
    if (!direct) 'dm': false,
  };

  static LockedOutboxItem? fromJson(Object? json) {
    if (json is! Map) {
      return null;
    }
    final Object? id = json['id'];
    final Object? to = json['to'];
    final Object? env = json['env'];
    final Object? expires = json['x'];
    final Object? token = json['tk'];
    final Object? mailboxes = json['mb'];
    if (id is! String ||
        id.isEmpty ||
        to is! String ||
        to.isEmpty ||
        env is! Map ||
        expires is! int) {
      return null;
    }
    return LockedOutboxItem(
      id: id,
      recipient: PeerShareCodec.normalizeAddress(to),
      envelope: Map<String, dynamic>.from(env),
      expiresAtMillis: expires,
      mailboxes: <String>[
        if (mailboxes is List)
          for (final Object? m in mailboxes.take(8))
            if (m is String && m.isNotEmpty) PeerShareCodec.normalizeAddress(m),
      ],
      token: token is String && token.isNotEmpty ? token : null,
      direct: json['dm'] != false,
    );
  }
}

/// What the unlocked app leaves for the Android background service so that
/// this device's queue keeps going out while Zen is locked: the pending
/// payloads, each already sealed for its recipient. Stored sealed with the
/// background key (`outboxKitFile` in `locked_outbox_writer.dart`); it holds
/// no plaintext and no key that opens anything.
@immutable
final class LockedOutboxKit {
  const LockedOutboxKit({
    this.items = const <LockedOutboxItem>[],
    this.writtenAtMillis = 0,
  });

  final List<LockedOutboxItem> items;
  final int writtenAtMillis;

  /// What the kit says, without the envelopes (sealed anew each time):
  /// unchanged means there is nothing to write again.
  String get signature => jsonEncode(<Object>[
    for (final LockedOutboxItem item in items)
      <Object>[item.id, item.recipient, item.mailboxes, item.direct],
  ]);

  Map<String, dynamic> toJson() => <String, dynamic>{
    'v': 1,
    'at': writtenAtMillis,
    'items': items.map((LockedOutboxItem i) => i.toJson()).toList(),
  };

  static LockedOutboxKit? fromJson(Object? json) {
    if (json is! Map || json['v'] != 1) {
      return null;
    }
    final Object? items = json['items'];
    return LockedOutboxKit(
      writtenAtMillis: (json['at'] as num?)?.toInt() ?? 0,
      items: <LockedOutboxItem>[
        if (items is List)
          for (final Object? item in items.take(kLockedOutboxMaxItems))
            ?LockedOutboxItem.fromJson(item),
      ],
    );
  }
}

/// Delivers a [LockedOutboxKit] from the locked Android service: each
/// payload goes to its recipient as mail (`rly_mail`, which the recipient
/// opens like mail from a mailbox) and to the recipient's mailboxes
/// (`rly_deposit`), on a backoff that spares the battery, and again at once
/// when the recipient shows a sign of life. A confirmation (`rly_ack`,
/// `rly_deposit_ack`) ends it; the app learns of those from the sealed
/// inbox after unlock and takes the queue over.
final class LockedOutbox {
  LockedOutbox({
    required SignalTransport transport,
    required LockedOutboxKit kit,
    int Function()? now,
    this.schedule = const <Duration>[
      Duration(seconds: 20),
      Duration(minutes: 2),
      Duration(minutes: 10),
      Duration(minutes: 30),
      Duration(hours: 1),
    ],
    this.sightingThrottle = const Duration(minutes: 1),
    this.maxMailBatchBytes = 6 * 1024,
  }) : _transport = transport,
       _now = now ?? (() => DateTime.now().millisecondsSinceEpoch) {
    for (final LockedOutboxItem item in kit.items) {
      _pending[item.id] = item;
      _depositedTo[item.id] = <String>{};
    }
  }

  final SignalTransport _transport;
  final int Function() _now;

  /// Waits between rounds; the last one repeats.
  final List<Duration> schedule;

  /// A recipient that shows up gets its mail at most this often.
  final Duration sightingThrottle;
  final int maxMailBatchBytes;

  final Map<String, LockedOutboxItem> _pending = <String, LockedOutboxItem>{};
  final Map<String, Set<String>> _depositedTo = <String, Set<String>>{};
  final Map<String, int> _lastSentTo = <String, int>{};
  StreamSubscription<SignalTransportFrame>? _subscription;
  Timer? _timer;
  int _round = 0;
  bool _running = false;

  /// Payloads not confirmed by their recipient yet.
  int get pendingCount => _pending.length;

  /// Ids not confirmed yet (tests, logs).
  Iterable<String> get pendingIds => _pending.keys;

  Future<void> start() async {
    if (_running || _pending.isEmpty) {
      return;
    }
    _running = true;
    _subscription = _transport.frames.listen(handleFrame);
    _schedule();
    logZenMessage('Locked outbox: ${_pending.length} queued payloads.');
  }

  Future<void> stop() async {
    _running = false;
    _timer?.cancel();
    _timer = null;
    await _subscription?.cancel();
    _subscription = null;
  }

  void _schedule() {
    if (!_running || _pending.isEmpty) {
      return;
    }
    final Duration wait = schedule.isEmpty
        ? const Duration(hours: 1)
        : schedule[min(_round, schedule.length - 1)];
    _timer?.cancel();
    _timer = Timer(wait, () {
      _round++;
      unawaitedLogged(
        runRound().whenComplete(_schedule),
        context: 'Locked outbox round failed',
      );
    });
  }

  /// One round: every payload to its recipient and to the mailboxes that
  /// did not confirm it.
  @visibleForTesting
  Future<void> runRound() async {
    _dropExpired();
    final Set<String> recipients = <String>{
      for (final LockedOutboxItem item in _pending.values) item.recipient,
    };
    for (final String recipient in recipients) {
      await _sendTo(recipient);
    }
    for (final LockedOutboxItem item in _pending.values.toList()) {
      await _deposit(item);
    }
  }

  /// A frame the node received.
  @visibleForTesting
  void handleFrame(SignalTransportFrame frame) {
    if (!_running) {
      return;
    }
    final String from = PeerShareCodec.normalizeAddress(frame.from);
    final Object? type = frame.payload['type'];
    if (type == 'rly_ack') {
      final LockedOutboxItem? item = _pending[frame.payload['rid']];
      if (item != null && item.recipient == from) {
        _pending.remove(item.id);
        _depositedTo.remove(item.id);
        if (_pending.isEmpty) {
          _timer?.cancel();
        }
      }
      return;
    }
    if (type == 'rly_deposit_ack') {
      final LockedOutboxItem? item = _pending[frame.payload['id']];
      if (item != null && item.mailboxes.contains(from)) {
        _depositedTo[item.id]?.add(from);
      }
      return;
    }
    // Any other sign of life from a recipient: its mail goes out now.
    final int now = _now();
    final int? last = _lastSentTo[from];
    if (_pending.values.any((LockedOutboxItem i) => i.recipient == from) &&
        (last == null || now - last >= sightingThrottle.inMilliseconds)) {
      unawaitedLogged(_sendTo(from), context: 'Locked outbox send failed');
    }
  }

  void _dropExpired() {
    final int now = _now();
    _pending.removeWhere(
      (String _, LockedOutboxItem item) => item.expiresAtMillis <= now,
    );
    _depositedTo.removeWhere(
      (String id, Set<String> _) => !_pending.containsKey(id),
    );
  }

  Future<void> _sendTo(String recipient) async {
    _lastSentTo[recipient] = _now();
    List<Map<String, dynamic>> batch = <Map<String, dynamic>>[];
    int bytes = 0;
    for (final LockedOutboxItem item in _pending.values.toList()) {
      if (item.recipient != recipient || !item.direct) {
        continue;
      }
      final int size = utf8.encode(jsonEncode(item.envelope)).length;
      if (batch.isNotEmpty && bytes + size > maxMailBatchBytes) {
        await _send(recipient, <String, dynamic>{
          'type': 'rly_mail',
          'items': batch,
        });
        batch = <Map<String, dynamic>>[];
        bytes = 0;
      }
      batch.add(item.envelope);
      bytes += size;
    }
    if (batch.isNotEmpty) {
      await _send(recipient, <String, dynamic>{
        'type': 'rly_mail',
        'items': batch,
      });
    }
  }

  Future<void> _deposit(LockedOutboxItem item) async {
    final Set<String> done = _depositedTo[item.id] ?? <String>{};
    for (final String mailbox in item.mailboxes) {
      if (done.contains(mailbox) || mailbox == item.recipient) {
        continue;
      }
      await _send(mailbox, <String, dynamic>{
        'type': 'rly_deposit',
        'env': <String, dynamic>{...item.envelope, 'tk': ?item.token},
      });
    }
  }

  Future<void> _send(String to, Map<String, dynamic> payload) async {
    try {
      await _transport.send(remoteAddress: to, payload: payload);
    } on Object catch (error) {
      // Unreachable peers are the normal case; the next round tries again.
      logZenWarning('Locked outbox "${payload['type']}" to $to: $error');
    }
  }
}
