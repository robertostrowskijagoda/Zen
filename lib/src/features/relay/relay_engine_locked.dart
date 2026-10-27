part of 'relay_engine.dart';

// A phone that holds friends' mail while Zen is locked.
//
// An Android phone hands its node to the background service as soon as Zen
// locks, and a few minutes after it went to the background anyway. That
// service has no master key (`LockedReceiver`), but nothing a mailbox does
// needs one: envelopes are sealed for their recipients, and checking a
// sender's deposit token takes only the key the recipient sent this device.
// So friends who chose this phone as one of their six mailboxes keep their
// mailbox:
//
// * **App.** While unlocked it writes a [LockedMailboxKit]
//   ([RelayEngine.lockedMailboxKit]): whom this device serves (with their
//   mailboxes and deposit keys), the mail it holds and the receipts
//   (tombstones), and short tags of what this device itself already took
//   ([LockedMailboxKit.taken], so the locked receiver neither keeps nor
//   announces a copy of it again).
// * **Service.** [LockedMailbox] takes deposits, hands mail out when its
//   recipient asks (`rly_poll`) and right after a deposit, drops what the
//   recipient confirmed, and answers fellow mailboxes catching up — the
//   same rules as the app's own relay side. What it holds it writes back
//   (the "held" kit), never the app's kit.
// * **Back in the app.** [RelayEngine.takeLockedMailbox] adds what the
//   service took in and drops what it handed over. Taking the same held kit
//   twice changes nothing, so it is taken whenever the app gets the chance.

/// Tags of payloads this device already took, at most, in a kit.
const int kLockedMailboxMaxTaken = 1500;

/// What a mailbox needs to know about one friend it serves.
@immutable
final class LockedMailboxPeer {
  const LockedMailboxPeer({required this.relays, this.depositKey});

  /// The friend's mailboxes (this device among them).
  final List<String> relays;

  /// The key that checks the deposit tokens of the friend's senders.
  final Uint8List? depositKey;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'r': relays,
    if (depositKey != null) 'dk': base64Url.encode(depositKey!),
  };

  static LockedMailboxPeer? fromJson(Object? json) {
    if (json is! Map) {
      return null;
    }
    final Object? relays = json['r'];
    return LockedMailboxPeer(
      relays: <String>[
        if (relays is List)
          for (final Object? relay in relays.take(16))
            if (relay is String && relay.isNotEmpty)
              PeerShareCodec.normalizeAddress(relay),
      ],
      depositKey: decodeRelayKey(json['dk']),
    );
  }
}

/// What the locked Android service runs this device's mailbox with (see the
/// top of this file). Stored sealed with the background key, like the
/// outbox kit: it holds envelopes sealed for their recipients and where they
/// go, never anything that opens one.
@immutable
final class LockedMailboxKit {
  const LockedMailboxKit({
    required this.self,
    this.served = const <String, LockedMailboxPeer>{},
    this.held = const <String, Map<String, Map<String, dynamic>>>{},
    this.tombstones = const <String, int>{},
    this.taken = const <String>{},
    this.writtenAtMillis = 0,
  });

  /// This device's canonical address.
  final String self;

  /// The friends this device is a mailbox for, by canonical address.
  final Map<String, LockedMailboxPeer> served;

  /// Mail held: recipient → envelope id → envelope (as the relay keeps it).
  final Map<String, Map<String, Map<String, dynamic>>> held;

  /// `recipient|id` → until when it is known to be delivered.
  final Map<String, int> tombstones;

  /// [takenTag]s of what this device already received.
  final Set<String> taken;
  final int writtenAtMillis;

  bool get isEmpty => served.isEmpty && held.isEmpty;

  /// The tag of the payload [rid] from [sender] (both as the relay engine
  /// remembers them): only says whether it came, not who sent what.
  static String takenTag(String sender, String rid) {
    final List<int> digest = crypto.sha256
        .convert(utf8.encode('zen.locked.taken|$sender|$rid'))
        .bytes;
    return base64Url.encode(digest.sublist(0, 16));
  }

  /// What the kit says, without when it was written: unchanged means there
  /// is nothing to write again.
  String get signature => jsonEncode(<String, dynamic>{...toJson(), 'at': 0});

  Map<String, dynamic> toJson() => <String, dynamic>{
    'v': 1,
    'at': writtenAtMillis,
    'me': self,
    'srv': <String, dynamic>{
      for (final MapEntry<String, LockedMailboxPeer> e in served.entries)
        e.key: e.value.toJson(),
    },
    'held': held,
    'tomb': tombstones,
    'tk': taken.toList(),
  };

  static LockedMailboxKit? fromJson(Object? json) {
    if (json is! Map || json['v'] != 1) {
      return null;
    }
    final Object? me = json['me'];
    final Object? served = json['srv'];
    final Object? held = json['held'];
    final Object? tombstones = json['tomb'];
    final Object? taken = json['tk'];
    return LockedMailboxKit(
      self: me is String ? PeerShareCodec.normalizeAddress(me) : '',
      writtenAtMillis: (json['at'] as num?)?.toInt() ?? 0,
      served: <String, LockedMailboxPeer>{
        if (served is Map)
          for (final MapEntry<dynamic, dynamic> e in served.entries.take(256))
            if (e.key is String && LockedMailboxPeer.fromJson(e.value) != null)
              PeerShareCodec.normalizeAddress(e.key as String):
                  LockedMailboxPeer.fromJson(e.value)!,
      },
      held: <String, Map<String, Map<String, dynamic>>>{
        if (held is Map)
          for (final MapEntry<dynamic, dynamic> r in held.entries.take(256))
            if (r.key is String && r.value is Map)
              PeerShareCodec.normalizeAddress(
                r.key as String,
              ): <String, Map<String, dynamic>>{
                for (final MapEntry<dynamic, dynamic> e
                    in (r.value as Map).entries)
                  if (e.key is String && e.value is Map)
                    e.key as String: Map<String, dynamic>.from(e.value as Map),
              },
      },
      tombstones: <String, int>{
        if (tombstones is Map)
          for (final MapEntry<dynamic, dynamic> e in tombstones.entries)
            if (e.key is String && e.value is int)
              e.key as String: e.value as int,
      },
      taken: <String>{
        if (taken is List)
          for (final Object? tag in taken.take(kLockedMailboxMaxTaken))
            if (tag is String && tag.isNotEmpty) tag,
      },
    );
  }

  /// The app's kit [app] with what the service held since [held] (both may
  /// be missing): whom it serves and what it took from the app's (the
  /// newer word on them), every envelope either holds unless either knows
  /// it was delivered, and the receipts of both.
  static LockedMailboxKit? merge(
    LockedMailboxKit? app,
    LockedMailboxKit? held,
  ) {
    if (app == null || held == null) {
      return app ?? held;
    }
    if (app.self.isNotEmpty && held.self.isNotEmpty && app.self != held.self) {
      return app; // another account's mailbox
    }
    final Map<String, int> tombstones = <String, int>{...held.tombstones};
    app.tombstones.forEach((String key, int until) {
      tombstones[key] = max(tombstones[key] ?? 0, until);
    });
    final Map<String, Map<String, Map<String, dynamic>>> mail =
        <String, Map<String, Map<String, dynamic>>>{};
    for (final LockedMailboxKit kit in <LockedMailboxKit>[app, held]) {
      kit.held.forEach((String recipient, Map<String, Map<String, dynamic>> m) {
        m.forEach((String id, Map<String, dynamic> envelope) {
          if (!tombstones.containsKey('$recipient|$id')) {
            (mail[recipient] ??= <String, Map<String, dynamic>>{})[id] ??=
                envelope;
          }
        });
      });
    }
    return LockedMailboxKit(
      self: app.self.isNotEmpty ? app.self : held.self,
      served: app.served,
      held: mail,
      tombstones: tombstones,
      taken: app.taken,
      writtenAtMillis: max(app.writtenAtMillis, held.writtenAtMillis),
    );
  }
}

/// This device's mailbox for friends, run by the locked Android service from
/// a [LockedMailboxKit] (see the top of this file). Takes the frames
/// [dutyTypes] lists; [save] gets the held kit after every change.
final class LockedMailbox {
  LockedMailbox({
    required SignalTransport transport,
    required LockedMailboxKit kit,
    required bool Function(String address) isFriend,
    required bool Function(String address) isContact,
    required Future<void> Function(LockedMailboxKit kit) save,
    this.config = const RelayConfig(),
    int Function()? now,
  }) : _transport = transport,
       _self = kit.self,
       _served = kit.served,
       _isFriend = isFriend,
       _isContact = isContact,
       _save = save,
       _now = now ?? (() => DateTime.now().millisecondsSinceEpoch) {
    kit.held.forEach((String recipient, Map<String, Map<String, dynamic>> m) {
      _held[recipient] = <String, Map<String, dynamic>>{...m};
    });
    _tombstones.addAll(kit.tombstones);
  }

  /// Mailbox duties: what friends' senders, the friends themselves and
  /// fellow mailboxes send a mailbox.
  static const Set<String> dutyTypes = <String>{
    'rly_deposit',
    'rly_poll',
    'rly_mail_ack',
    'rly_purge',
    'rly_sync',
    'rly_sync_want',
  };

  final RelayConfig config;
  final SignalTransport _transport;
  final String _self;
  final Map<String, LockedMailboxPeer> _served;
  final bool Function(String address) _isFriend;
  final bool Function(String address) _isContact;
  final Future<void> Function(LockedMailboxKit kit) _save;
  final int Function() _now;
  final Map<String, Map<String, Map<String, dynamic>>> _held =
      <String, Map<String, Map<String, dynamic>>>{};
  final Map<String, int> _tombstones = <String, int>{};

  /// One frame at a time, and one write after another.
  Future<void> _queue = Future<void>.value();

  /// Envelopes held for [recipient] (tests, logs).
  Iterable<String> heldFor(String recipient) =>
      _held[recipient]?.keys ?? const <String>[];

  /// All envelopes held.
  int get heldCount => _held.values.fold<int>(
    0,
    (int sum, Map<String, Map<String, dynamic>> m) => sum + m.length,
  );

  /// What this mailbox holds now, as a kit (what [save] gets).
  LockedMailboxKit get kit => LockedMailboxKit(
    self: _self,
    served: _served,
    held: <String, Map<String, Map<String, dynamic>>>{
      for (final MapEntry<String, Map<String, Map<String, dynamic>>> e
          in _held.entries)
        if (e.value.isNotEmpty) e.key: e.value,
    },
    tombstones: _tombstones,
    writtenAtMillis: _now(),
  );

  /// Handles one duty frame (see [dutyTypes]); anything else is ignored.
  Future<void> handle(SignalTransportFrame frame) {
    final Completer<void> done = Completer<void>();
    _queue = _queue.then((_) async {
      try {
        if (await _handle(frame)) {
          await _save(kit);
        }
      } on Object catch (error, stackTrace) {
        logZenError('A mailbox duty failed while locked', error, stackTrace);
      } finally {
        done.complete();
      }
    });
    return done.future;
  }

  Future<bool> _handle(SignalTransportFrame frame) async {
    final String from = PeerShareCodec.normalizeAddress(frame.from);
    final Map<String, dynamic> payload = frame.payload;
    if (from.isEmpty || from == _self) {
      return false;
    }
    bool changed = _expire();
    switch (payload['type']) {
      case 'rly_deposit':
        changed = await _deposit(from, payload['env']) || changed;
      case 'rly_poll':
        // A friend checking whether its mailbox is there: nothing to hand
        // over, so a word that it is (see `RelayReach`).
        if (!await _push(from) &&
            payload[kRelayProbeKey] == true &&
            _isFriend(from)) {
          await _send(from, const <String, dynamic>{'type': kRelayHereType});
        }
      case 'rly_mail_ack':
      case 'rly_purge':
        changed = _dropDelivered(from, payload['ids']) || changed;
      case 'rly_sync':
        changed = await _sync(from, payload) || changed;
      case 'rly_sync_want':
        final String recipient = PeerShareCodec.normalizeAddress(
          payload['r'] as String? ?? '',
        );
        if (_isCoRelay(recipient, from)) {
          await _sendHeld(
            from,
            recipient,
            RelayEngine._stringList(
              payload['ids'],
              limit: config.maxIdsPerFrame,
            ),
          );
        }
    }
    return changed;
  }

  bool _serves(String recipient) =>
      recipient.isNotEmpty &&
      recipient != _self &&
      _served[recipient]?.relays.contains(_self) == true &&
      _isFriend(recipient);

  bool _isCoRelay(String recipient, String other) =>
      _serves(recipient) && _served[recipient]!.relays.contains(other);

  /// The same rules as the app's relay side (`_handleDeposit`).
  Future<bool> _deposit(String from, Object? raw) async {
    final RelayEnvelope? envelope = RelayEnvelope.tryParse(raw);
    if (envelope == null) {
      return false;
    }
    final String recipient = PeerShareCodec.normalizeAddress(
      envelope.recipient,
    );
    final String sender = PeerShareCodec.normalizeAddress(envelope.sender);
    final int now = _now();
    if (!_serves(recipient) ||
        envelope.expiresAtMillis <= now ||
        envelope.approximateBytes > config.maxRelayablePayloadBytes * 2) {
      return false;
    }
    if (from != sender && !_isCoRelay(recipient, from)) {
      return false;
    }
    final Object? token = raw is Map ? raw['tk'] : null;
    final Uint8List? depositKey = _served[recipient]?.depositKey;
    final bool tokenValid =
        depositKey != null &&
        token is String &&
        token ==
            RelayEngine._depositToken(
              depositKey,
              recipient: recipient,
              sender: sender,
            );
    await _send(from, <String, dynamic>{
      'type': 'rly_deposit_ack',
      'id': envelope.id,
      'r': recipient,
    });
    if (_tombstones.containsKey('$recipient|${envelope.id}')) {
      return false;
    }
    final Map<String, Map<String, dynamic>> held = _held.putIfAbsent(
      recipient,
      () => <String, Map<String, dynamic>>{},
    );
    if (held.containsKey(envelope.id)) {
      return false;
    }
    held[envelope.id] = <String, dynamic>{
      ...envelope.toJson(),
      if (tokenValid) 'tk': token,
      'hv': tokenValid || _isContact(sender),
      'ha': now,
      'hx': min(
        envelope.expiresAtMillis,
        now + config.messageTtl.inMilliseconds,
      ),
    };
    RelayEngine._enforceQuotaIn(config, held);
    if (held.containsKey(envelope.id)) {
      // The recipient may be online right now.
      await _push(recipient);
    }
    return true;
  }

  /// Everything held for [recipient], in size-bounded batches; false when
  /// there was nothing.
  Future<bool> _push(String recipient) async {
    final Map<String, Map<String, dynamic>>? held = _held[recipient];
    if (held == null || held.isEmpty) {
      return false;
    }
    List<Map<String, dynamic>> batch = <Map<String, dynamic>>[];
    int bytes = 0;
    for (final Map<String, dynamic> envelope in held.values.toList()) {
      final Map<String, dynamic> wire = RelayEngine._wireCopy(
        envelope,
        keepToken: false,
      );
      final int size = (wire['b'] as String?)?.length ?? 0;
      if (batch.isNotEmpty && bytes + size > config.maxMailBatchBytes) {
        await _send(recipient, <String, dynamic>{
          'type': 'rly_mail',
          'items': batch,
        });
        batch = <Map<String, dynamic>>[];
        bytes = 0;
      }
      batch.add(wire);
      bytes += size;
    }
    if (batch.isNotEmpty) {
      await _send(recipient, <String, dynamic>{
        'type': 'rly_mail',
        'items': batch,
      });
    }
    return true;
  }

  /// Drops what [recipient] confirmed and remembers it as delivered; only
  /// envelopes actually held here count (see `_dropDelivered`).
  bool _dropDelivered(String recipient, Object? ids) {
    final Map<String, Map<String, dynamic>>? held = _held[recipient];
    if (held == null || held.isEmpty) {
      return false;
    }
    final int latest = _now() + config.messageTtl.inMilliseconds;
    bool changed = false;
    for (final String id in RelayEngine._stringList(
      ids,
      limit: config.maxIdsPerFrame,
    )) {
      final Map<String, dynamic>? envelope = held.remove(id);
      if (envelope == null) {
        continue;
      }
      _tombstones['$recipient|$id'] = min(
        RelayEngine._holdUntil(envelope),
        latest,
      );
      changed = true;
    }
    if (held.isEmpty) {
      _held.remove(recipient);
    }
    if (changed) {
      _capTombstones();
    }
    return changed;
  }

  /// A fellow mailbox catching up (see `_handleSync`).
  Future<bool> _sync(String from, Map<String, dynamic> payload) async {
    final String recipient = PeerShareCodec.normalizeAddress(
      payload['r'] as String? ?? '',
    );
    if (!_isCoRelay(recipient, from)) {
      return false;
    }
    final bool changed = _dropDelivered(recipient, payload['t']);
    final Set<String> theirs = RelayEngine._stringList(
      payload['ids'],
      limit: config.maxIdsPerFrame,
    ).toSet();
    final Map<String, Map<String, dynamic>> mine =
        _held[recipient] ?? const <String, Map<String, dynamic>>{};
    final List<String> wanted = theirs
        .where(
          (String id) =>
              !mine.containsKey(id) &&
              !_tombstones.containsKey('$recipient|$id'),
        )
        .toList(growable: false);
    if (wanted.isNotEmpty) {
      await _send(from, <String, dynamic>{
        'type': 'rly_sync_want',
        'r': recipient,
        'ids': wanted.take(config.maxIdsPerFrame).toList(),
      });
    }
    if (payload['all'] == true) {
      await _sendHeld(
        from,
        recipient,
        mine.keys.where((String id) => !theirs.contains(id)).toList(),
      );
    }
    return changed;
  }

  Future<void> _sendHeld(String to, String recipient, List<String> ids) async {
    final Map<String, Map<String, dynamic>>? held = _held[recipient];
    if (held == null) {
      return;
    }
    for (final String id in ids) {
      final Map<String, dynamic>? envelope = held[id];
      if (envelope != null) {
        await _send(to, <String, dynamic>{
          'type': 'rly_deposit',
          'env': RelayEngine._wireCopy(envelope, keepToken: true),
        });
      }
    }
  }

  /// Drops what outlived its hold and expired receipts.
  bool _expire() {
    final int now = _now();
    bool changed = false;
    for (final Map<String, Map<String, dynamic>> held in _held.values) {
      final int before = held.length;
      held.removeWhere(
        (String _, Map<String, dynamic> e) => RelayEngine._holdUntil(e) <= now,
      );
      changed = changed || held.length != before;
    }
    _held.removeWhere(
      (String _, Map<String, Map<String, dynamic>> held) => held.isEmpty,
    );
    final int tombstones = _tombstones.length;
    _tombstones.removeWhere((String _, int until) => until <= now);
    return changed || tombstones != _tombstones.length;
  }

  void _capTombstones() {
    final int excess = _tombstones.length - config.maxTombstones;
    if (excess <= 0) {
      return;
    }
    final List<MapEntry<String, int>> soonestFirst =
        _tombstones.entries.toList()..sort(
          (MapEntry<String, int> a, MapEntry<String, int> b) =>
              a.value.compareTo(b.value),
        );
    for (final MapEntry<String, int> entry in soonestFirst.take(excess)) {
      _tombstones.remove(entry.key);
    }
  }

  Future<void> _send(String to, Map<String, dynamic> payload) async {
    try {
      await _transport.send(remoteAddress: to, payload: payload);
    } on Object catch (error) {
      // Unreachable peers are the normal case; they ask again.
      logZenWarning('Locked mailbox "${payload['type']}" to $to: $error');
    }
  }
}
