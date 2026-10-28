part of 'relay_engine.dart';

// Attachments through mailboxes ("blobs").
//
// A payload too large for one relayed envelope — an inline photo or voice
// message, or a chat attachment of up to [RelayConfig.maxBlobBytes] — is cut
// into chunks sealed once under a fresh key ([RelayBlobCipher]):
//
// * **Sender.** Keeps the sealed chunks (`o/…` in the [RelayBlobStore]) and
//   hands them to those of the recipient's mailboxes that announced they hold
//   attachments (`rly_bput`, window by window, each chunk confirmed with
//   `rly_bput_ack`; `rly_bput_no` when over the mailbox's quota). The key goes
//   to the recipient in a small *manifest* ([kBlobManifestType]), queued like
//   any reliable payload, so it waits in the mailboxes too.
// * **Mailbox.** Holds the chunks (`h/…`) within a per-sender byte quota
//   ([RelayState.blobQuotaBytes]) and the message lifetime, only for friends
//   that chose it, only from senders it can vouch for (its own contacts or
//   holders of the recipient's deposit token). It hands them to the
//   recipient on request (`rly_bget` → `rly_bchunk` / `rly_bnone`) and drops
//   them once the recipient has everything (`rly_bdrop`).
// * **Recipient.** On the manifest it starts collecting — from whoever
//   delivered the manifest, then its mailboxes, then the sender — a window at
//   a time, and tells everyone when it is done (`rly_bdrop`, `rly_bdone`).
//   A payload blob is put back together and handed to the app as the
//   original reliable payload; an attachment blob is handed over chunk by
//   chunk as `message_placeholder` + `message_chunk` frames, exactly what a
//   live transfer produces, so the app assembles it and runs it through the
//   media guard as usual.
//
// Only a recipient that announced mailboxes holding attachments (`br`) is
// ever sent a manifest; a device running without a blob store announces none,
// so large payloads to it stay direct-only.

/// Payload type of a blob manifest (a reliable payload of the relay layer
/// itself; never reaches the app).
const String kBlobManifestType = 'blob_manifest';

/// Chunks asked for (or handed to a mailbox) and not answered yet.
final class _BlobWindow {
  _BlobWindow({
    required this.source,
    required this.indexes,
    required this.sinceMillis,
  });

  final String source;
  final Set<int> indexes;
  final int sinceMillis;
}

/// Collection progress of one incoming blob (memory only).
final class _BlobPull {
  /// Position in the blob's source list.
  int sourceIndex = 0;

  /// Sources asked in a row without getting anything.
  int misses = 0;
  _BlobWindow? window;
}

String _hexKey(String text) =>
    crypto.sha256.convert(utf8.encode(text)).toString().substring(0, 32);

/// A sealed chunk this device sends.
String _outChunkKey(String blobId, int index) =>
    'o/${_hexKey('o|$blobId')}/$index';

/// A sealed chunk held for [recipient].
String _heldChunkKey(
  String recipient,
  String sender,
  String blobId,
  int index,
) => 'h/${_hexKey('h|$recipient|$sender|$blobId')}/$index';

/// A decrypted chunk of a payload blob being collected here.
String _inChunkKey(String sender, String blobId, int index) =>
    'i/${_hexKey('i|$sender|$blobId')}/$index';

/// Keys of an attachment's metadata handed on to the recipient's app (the
/// fields of a `message_placeholder`); anything else is dropped.
const Set<String> _attachmentMetaKeys = <String>{
  'text',
  'createdAt',
  'messageType',
  'fileName',
  'mimeType',
  'attachmentSizeBytes',
  'durationMs',
  'senderName',
};

Map<String, dynamic> _attachmentMeta(Object? meta) {
  if (meta is! Map) {
    return <String, dynamic>{};
  }
  return <String, dynamic>{
    for (final MapEntry<Object?, Object?> e in meta.entries)
      if (e.key is String &&
          _attachmentMetaKeys.contains(e.key) &&
          (e.value is String || e.value is num || e.value is bool))
        e.key! as String: e.value,
  };
}

/// The `br` of an announcement: mailboxes that hold attachments, with their
/// quota — only among the peer's own [relays].
Map<String, int> _blobRelaysFrom(Object? raw, List<String> relays) {
  final Map<String, int> result = <String, int>{};
  if (raw is! Map) {
    return result;
  }
  raw.forEach((Object? key, Object? value) {
    if (key is! String || value is! num || value <= 0) {
      return;
    }
    final String relay = PeerShareCodec.normalizeAddress(key);
    if (relays.contains(relay)) {
      result[relay] = value.toInt();
    }
  });
  return result;
}

extension _RelayEngineBlobs on RelayEngine {
  // ---------------------------------------------------------------------------
  // Capabilities
  // ---------------------------------------------------------------------------

  /// What this device holds per sender for each friend it serves.
  int _blobQuota(RelayState state) => _blobs == null
      ? 0
      : max(0, state.blobQuotaBytes ?? config.defaultBlobQuotaBytes);

  /// This device's mailboxes that hold attachments, with their quota.
  Map<String, int> _blobRelaysOf(RelayState state) => <String, int>{
    for (final String relay in state.currentRelays)
      if ((state.peers[relay]?.blobQuotaBytes ?? 0) > 0)
        relay: state.peers[relay]!.blobQuotaBytes,
  };

  /// Mailboxes of [recipient] (other than this device) that take
  /// [cipherBytes] of attachment.
  List<String> _blobTargets(
    RelayState state,
    String recipient,
    int cipherBytes,
  ) {
    final RelayPeerInfo? info = state.peers[recipient];
    if (info == null) {
      return const <String>[];
    }
    return info.blobRelays.entries
        .where(
          (MapEntry<String, int> e) =>
              e.value >= cipherBytes &&
              e.key != _self &&
              e.key != recipient &&
              info.relays.contains(e.key),
        )
        .map((MapEntry<String, int> e) => e.key)
        .toList(growable: false);
  }

  bool _canSendBlob(RelayState state, String recipient, int cipherBytes) {
    final RelayPeerInfo? info = state.peers[recipient];
    return _blobs != null &&
        state.identity != null &&
        info != null &&
        info.keys != null &&
        _blobTargets(state, recipient, cipherBytes).isNotEmpty;
  }

  int _heldBlobBytes(RelayState state) => state.heldBlobs.values.fold<int>(
    0,
    (int sum, Map<String, RelayHeldBlob> held) =>
        sum +
        held.values.fold<int>(0, (int s, RelayHeldBlob b) => s + b.cipherBytes),
  );

  String _newBlobId() => 'b${_newReliableId().substring(1)}';

  // ---------------------------------------------------------------------------
  // Sender
  // ---------------------------------------------------------------------------

  /// Seals [count] chunks under [key] into the blob store; returns their
  /// total size, or `null` (and leaves nothing behind) when a chunk could not
  /// be read or stored.
  Future<int?> _sealBlobChunks({
    required String blobId,
    required String recipient,
    required Uint8List key,
    required int count,
    required Future<Uint8List> Function(int index) chunkAt,
  }) async {
    final RelayBlobStore store = _blobs!;
    int total = 0;
    try {
      for (int i = 0; i < count; i++) {
        final Uint8List sealed = await RelayBlobCipher.sealChunk(
          key: key,
          index: i,
          plaintext: await chunkAt(i),
          associatedData: RelayBlobCipher.associatedDataFor(
            blobId: blobId,
            sender: _self,
            recipient: recipient,
            index: i,
            count: count,
          ),
        );
        await store.writeBlobChunk(_outChunkKey(blobId, i), sealed);
        total += sealed.length;
      }
      return total;
    } catch (error, stackTrace) {
      logZenError(
        'Preparing an attachment for mailboxes failed',
        error,
        stackTrace,
      );
      await _deleteChunks(count, (int i) => _outChunkKey(blobId, i));
      return null;
    }
  }

  Future<void> _deleteChunks(
    int count,
    String Function(int index) keyOf,
  ) async {
    final RelayBlobStore? store = _blobs;
    if (store == null) {
      return;
    }
    for (int i = 0; i < count; i++) {
      try {
        await store.deleteBlobChunk(keyOf(i));
      } catch (error) {
        logZenWarning('Deleting a blob chunk failed: $error');
      }
    }
  }

  /// Turns an outbox [entry] too large for one envelope into a payload blob
  /// for the recipient's mailboxes. False when the recipient (or its
  /// mailboxes) cannot take blobs: the entry stays direct-only.
  Future<bool> _cutIntoBlob(
    RelayState state,
    RelayOutboxEntry entry,
    int now,
  ) async {
    if (_blobs == null ||
        _directOnlyPayloadTypes.contains(entry.payload['type']) ||
        state.outBlobs.length >= config.maxOutgoingBlobs ||
        entry.expiresAtMillis <= now ||
        // Cheap test first: this runs whenever a peer shows up.
        !_canSendBlob(state, entry.recipient, 1)) {
      return false;
    }
    final Uint8List plain = Uint8List.fromList(
      utf8.encode(jsonEncode(entry.payload)),
    );
    if (plain.length > config.maxPayloadBlobBytes) {
      return false;
    }
    final int chunkSize = config.blobChunkBytes;
    final int count = (plain.length + chunkSize - 1) ~/ chunkSize;
    if (!_canSendBlob(
      state,
      entry.recipient,
      plain.length + count * RelayBlobCipher.overheadBytes,
    )) {
      return false;
    }
    final String blobId = _newBlobId();
    final Uint8List key = RelayBlobCipher.newKey();
    final int? cipherBytes = await _sealBlobChunks(
      blobId: blobId,
      recipient: entry.recipient,
      key: key,
      count: count,
      chunkAt: (int i) async => Uint8List.sublistView(
        plain,
        i * chunkSize,
        min(plain.length, (i + 1) * chunkSize),
      ),
    );
    if (cipherBytes == null) {
      return false;
    }
    final String manifestRid =
        await _enqueue(state, entry.recipient, <String, dynamic>{
          'type': kBlobManifestType,
          'b': blobId,
          'k': RelayBlobKind.payload.wire,
          'key': base64Url.encode(key),
          'n': count,
          'cs': chunkSize,
          'z': plain.length,
          'x': entry.expiresAtMillis,
          'h': base64Url.encode(crypto.sha256.convert(plain).bytes),
          'ref': entry.rid,
        }, now);
    state.outBlobs[blobId] = RelayBlobOut(
      blobId: blobId,
      recipient: entry.recipient,
      kind: RelayBlobKind.payload,
      manifestRid: manifestRid,
      ref: entry.rid,
      chunkCount: count,
      cipherBytes: cipherBytes,
      createdAtMillis: now,
      expiresAtMillis: entry.expiresAtMillis,
    );
    state.outbox[entry.rid] = entry.copyWith(blobId: blobId);
    await _depositBlobs(state, onlyBlob: blobId);
    return true;
  }

  /// Hands chunks to the mailboxes that do not hold them yet: the next
  /// window to each, unless one is still unanswered. A mailbox that did not
  /// answer is tried again after [RelayConfig.depositRetryInterval], or as
  /// soon as it shows up ([onlyRelay]).
  /// Hands the mailboxes the next window of each outgoing blob. A sighting
  /// of one mailbox ([onlyRelay]) sends at once unless that mailbox left a
  /// window unanswered: then only when it is back after a silence
  /// ([cameBack]) or the growing wait is over ([_blobDepositSpacing]). A
  /// mailbox that is around but never confirms (a node of another engine
  /// answering for its phone) used to get half a megabyte at every
  /// sighting past the window's timeout.
  Future<void> _depositBlobs(
    RelayState state, {
    String? onlyRelay,
    String? onlyBlob,
    bool cameBack = false,
  }) async {
    if (_blobs == null || state.outBlobs.isEmpty) {
      return;
    }
    final int now = _now();
    for (final RelayBlobOut blob in state.outBlobs.values.toList()) {
      if ((onlyBlob != null && blob.blobId != onlyBlob) ||
          blob.expiresAtMillis <= now) {
        continue;
      }
      for (final String relay in _depositTargets(state, blob, now)) {
        if (onlyRelay != null && relay != onlyRelay) {
          continue;
        }
        final String slot = '${blob.blobId}|$relay';
        final _BlobWindow? window = _blobDeposits[slot];
        if (window != null &&
            window.indexes.isNotEmpty &&
            now - window.sinceMillis <
                config.blobRequestTimeout.inMilliseconds) {
          continue;
        }
        if (window != null && window.indexes.isNotEmpty) {
          // Unanswered within its time: counted once.
          _blobDepositMisses[slot] = (_blobDepositMisses[slot] ?? 0) + 1;
        }
        _blobDeposits.remove(slot);
        final int misses = _blobDepositMisses[slot] ?? 0;
        final int? last = _blobDepositAt[slot];
        final bool waited =
            last == null ||
            now - last >= _blobDepositSpacing(misses).inMilliseconds;
        final bool send;
        if (onlyBlob != null) {
          send = true;
        } else if (onlyRelay != null) {
          send = cameBack || misses == 0 || waited;
        } else {
          send = waited;
        }
        if (!send) {
          continue;
        }
        await _sendBlobWindow(state, blob, relay, now);
      }
    }
  }

  /// The wait before the next window to a mailbox that left [misses]
  /// windows in a row unanswered: the deposit retry interval, doubling
  /// from the second miss on, up to the longest deposit wait.
  Duration _blobDepositSpacing(int misses) {
    final Duration base = config.depositRetryInterval;
    if (misses <= 1) {
      return base;
    }
    final Duration grown = base * (1 << min(misses - 1, 10));
    return grown > config.depositRetryMaxInterval
        ? config.depositRetryMaxInterval
        : grown;
  }

  /// The mailboxes that still need a copy of [blob]: at most
  /// [RelayConfig.maxBlobCopies] hold one, preferring those already part
  /// way through, then those seen lately (likely online).
  List<String> _depositTargets(RelayState state, RelayBlobOut blob, int now) {
    final List<String> candidates = _blobTargets(
      state,
      blob.recipient,
      blob.cipherBytes,
    ).where((String r) => !blob.refused.contains(r)).toList(growable: false);
    final int complete = candidates.where(blob.isCompleteAt).length;
    if (complete >= config.maxBlobCopies) {
      return const <String>[];
    }
    int score(String relay) {
      final int? seen = _lastSeenHandledAt[relay];
      return ((blob.stored[relay]?.isNotEmpty ?? false) ? 2 : 0) +
          (seen != null && now - seen < config.pollInterval.inMilliseconds
              ? 1
              : 0);
    }

    final List<String> pending =
        candidates
            .where((String r) => !blob.isCompleteAt(r))
            .toList(growable: true)
          ..sort((String a, String b) {
            final int byScore = score(b).compareTo(score(a));
            return byScore != 0
                ? byScore
                : candidates.indexOf(a).compareTo(candidates.indexOf(b));
          });
    return pending
        .take(config.maxBlobCopies - complete)
        .toList(growable: false);
  }

  Future<void> _sendBlobWindow(
    RelayState state,
    RelayBlobOut blob,
    String relay,
    int now,
  ) async {
    final Set<int> stored = (blob.stored[relay] ?? const <int>[]).toSet();
    final List<int> next = <int>[
      for (int i = 0; i < blob.chunkCount; i++)
        if (!stored.contains(i)) i,
    ].take(config.blobWindow).toList(growable: false);
    if (next.isEmpty) {
      return;
    }
    final String slot = '${blob.blobId}|$relay';
    _blobDepositAt[slot] = now;
    _blobDeposits[slot] = _BlobWindow(
      source: relay,
      indexes: next.toSet(),
      sinceMillis: now,
    );
    final String? token = state.peers[blob.recipient]?.depositToken;
    for (final int i in next) {
      final Uint8List? sealed = await _readChunk(_outChunkKey(blob.blobId, i));
      if (sealed == null) {
        return; // our copy is gone; expiry cleans up
      }
      await _sendQuietly(relay, <String, dynamic>{
        'type': 'rly_bput',
        'b': blob.blobId,
        'r': blob.recipient,
        'n': blob.chunkCount,
        'z': blob.cipherBytes,
        'x': blob.expiresAtMillis,
        'i': i,
        'tk': ?token,
        // Named like the app's own chunks: the transport does not try to
        // compress ciphertext.
        'chunkData': base64Encode(sealed),
      });
    }
  }

  Future<Uint8List?> _readChunk(String key) async {
    try {
      return await _blobs?.readBlobChunk(key);
    } catch (error) {
      logZenWarning('Reading a blob chunk failed: $error');
      return null;
    }
  }

  Future<bool> _handleBlobPutAck(
    RelayState state,
    String from,
    Map<String, dynamic> payload,
  ) async {
    final RelayBlobOut? blob = state.outBlobs[payload['b']];
    final int index = RelayEngine._intOf(payload['i']);
    if (blob == null ||
        index < 0 ||
        index >= blob.chunkCount ||
        !_blobTargets(state, blob.recipient, blob.cipherBytes).contains(from)) {
      return false;
    }
    bool changed = false;
    final List<int> stored = blob.stored.putIfAbsent(from, () => <int>[]);
    if (!stored.contains(index)) {
      stored.add(index);
      changed = true;
    }
    final String slot = '${blob.blobId}|$from';
    // The mailbox answers: its next windows come without a wait.
    _blobDepositMisses.remove(slot);
    final _BlobWindow? window = _blobDeposits[slot];
    if (window != null) {
      window.indexes.remove(index);
      if (window.indexes.isEmpty) {
        // The mailbox keeps up: straight on with the next window.
        _blobDeposits.remove(slot);
        await _sendBlobWindow(state, blob, from, _now());
      }
    }
    if (blob.isCompleteAt(from)) {
      changed = _noteBlobHeldBy(state, blob, from) || changed;
      changed = await _maybeRetireOutBlob(state, blob) || changed;
    }
    return changed;
  }

  /// [relay] holds all of [blob]: the payload it carries counts as waiting
  /// there (for the chat's delivery status).
  bool _noteBlobHeldBy(RelayState state, RelayBlobOut blob, String relay) {
    final String? rid = blob.kind == RelayBlobKind.payload
        ? blob.ref
        : blob.manifestRid;
    final RelayOutboxEntry? entry = rid == null ? null : state.outbox[rid];
    if (entry == null || entry.blobHeldBy.contains(relay)) {
      return false;
    }
    state.outbox[entry.rid] = entry.copyWith(
      blobHeldBy: <String>[...entry.blobHeldBy, relay],
    );
    return true;
  }

  Future<bool> _handleBlobRefused(
    RelayState state,
    String from,
    Map<String, dynamic> payload,
  ) async {
    final RelayBlobOut? blob = state.outBlobs[payload['b']];
    if (blob == null ||
        blob.refused.contains(from) ||
        !_blobTargets(state, blob.recipient, blob.cipherBytes).contains(from)) {
      return false;
    }
    blob.refused.add(from);
    _blobDeposits.remove('${blob.blobId}|$from');
    // Another mailbox may have room.
    await _depositBlobs(state, onlyBlob: blob.blobId);
    return true;
  }

  /// The recipient has it: nothing more to hand out.
  Future<bool> _handleBlobDone(
    RelayState state,
    String from,
    Map<String, dynamic> payload,
  ) async {
    final RelayBlobOut? blob = state.outBlobs[payload['b']];
    if (blob == null || blob.recipient != from) {
      return false;
    }
    await _dropOutBlob(state, blob);
    return true;
  }

  /// Drops this device's own copy once enough mailboxes hold it
  /// ([RelayConfig.maxBlobCopies], or all that take it) — unless this device
  /// is itself one of the recipient's mailboxes, where its copy is what the
  /// recipient collects from.
  Future<bool> _maybeRetireOutBlob(RelayState state, RelayBlobOut blob) async {
    if (state.peers[blob.recipient]?.relays.contains(_self) ?? false) {
      return false;
    }
    final List<String> targets = _blobTargets(
      state,
      blob.recipient,
      blob.cipherBytes,
    ).where((String r) => !blob.refused.contains(r)).toList(growable: false);
    final int needed = min(config.maxBlobCopies, targets.length);
    if (needed == 0 || targets.where(blob.isCompleteAt).length < needed) {
      return false;
    }
    await _dropOutBlob(state, blob);
    return true;
  }

  Future<void> _dropOutBlob(RelayState state, RelayBlobOut blob) async {
    state.outBlobs.remove(blob.blobId);
    _blobDeposits.removeWhere(
      (String slot, _BlobWindow _) => slot.startsWith('${blob.blobId}|'),
    );
    _blobDepositAt.removeWhere(
      (String slot, int _) => slot.startsWith('${blob.blobId}|'),
    );
    _blobDepositMisses.removeWhere(
      (String slot, int _) => slot.startsWith('${blob.blobId}|'),
    );
    await _deleteChunks(
      blob.chunkCount,
      (int i) => _outChunkKey(blob.blobId, i),
    );
  }

  // ---------------------------------------------------------------------------
  // Mailbox
  // ---------------------------------------------------------------------------

  Future<bool> _handleBlobPut(
    RelayState state,
    String from,
    Map<String, dynamic> payload,
  ) async {
    final RelayBlobStore? store = _blobs;
    final Object? blobId = payload['b'];
    final Object? rawRecipient = payload['r'];
    final Object? data = payload['chunkData'];
    final int count = RelayEngine._intOf(payload['n']);
    final int cipherBytes = RelayEngine._intOf(payload['z']);
    final int index = RelayEngine._intOf(payload['i']);
    final int expires = RelayEngine._intOf(payload['x']);
    final int now = _now();
    if (store == null ||
        blobId is! String ||
        blobId.isEmpty ||
        blobId.length > _maxReliableIdLength ||
        rawRecipient is! String ||
        data is! String ||
        count <= 0 ||
        index < 0 ||
        index >= count ||
        cipherBytes < count ||
        expires <= now) {
      return false;
    }
    final String recipient = PeerShareCodec.normalizeAddress(rawRecipient);
    if (!_servesRecipient(state, recipient)) {
      return false;
    }
    Future<bool> refuse() async {
      await _sendQuietly(from, <String, dynamic>{
        'type': 'rly_bput_no',
        'b': blobId,
        'r': recipient,
      });
      return false;
    }

    final int quota = _blobQuota(state);
    final bool vouched =
        _isContact(from) || _tokenValid(state, recipient, from, payload['tk']);
    if (!vouched ||
        cipherBytes > quota ||
        count * (config.maxBlobChunkBytes + RelayBlobCipher.overheadBytes) <
            cipherBytes) {
      return refuse();
    }
    final String scope = '$from|$blobId';
    final Map<String, dynamic> ack = <String, dynamic>{
      'type': 'rly_bput_ack',
      'b': blobId,
      'r': recipient,
      'i': index,
    };
    if (state.tombstones.containsKey('$recipient|blob:$scope')) {
      await _sendQuietly(from, ack); // collected already: stop handing it in
      return false;
    }
    bool changed = false;
    RelayHeldBlob? blob = state.heldBlobs[recipient]?[scope];
    if (blob == null) {
      // The whole announced size is reserved up front, so a sender can never
      // hold more than its quota, however its chunks arrive.
      final int senderUse =
          (state.heldBlobs[recipient]?.values ?? const <RelayHeldBlob>[])
              .where((RelayHeldBlob b) => b.sender == from)
              .fold<int>(0, (int sum, RelayHeldBlob b) => sum + b.cipherBytes);
      if (senderUse + cipherBytes > quota ||
          _heldBlobBytes(state) + cipherBytes > config.maxHeldBlobBytesTotal) {
        return refuse();
      }
      blob = RelayHeldBlob(
        blobId: blobId,
        sender: from,
        chunkCount: count,
        cipherBytes: cipherBytes,
        arrivedAtMillis: now,
        holdUntilMillis: min(expires, now + config.messageTtl.inMilliseconds),
      );
      state.heldBlobs.putIfAbsent(
        recipient,
        () => <String, RelayHeldBlob>{},
      )[scope] = blob;
      changed = true;
    } else if (blob.chunkCount != count || blob.cipherBytes != cipherBytes) {
      return false; // not the blob announced under this id
    }
    if (!blob.have.contains(index)) {
      final Uint8List bytes;
      try {
        bytes = base64Decode(data);
      } on FormatException {
        return changed;
      }
      if (bytes.length >
              config.maxBlobChunkBytes + RelayBlobCipher.overheadBytes ||
          blob.storedBytes + bytes.length > blob.cipherBytes) {
        return changed;
      }
      try {
        await store.writeBlobChunk(
          _heldChunkKey(recipient, from, blobId, index),
          bytes,
        );
      } catch (error, stackTrace) {
        logZenError('Storing an attachment chunk failed', error, stackTrace);
        return changed;
      }
      blob.have.add(index);
      blob.storedBytes += bytes.length;
      changed = true;
    }
    await _sendQuietly(from, ack);
    return changed;
  }

  /// The recipient asks for chunks: what is held for it here — or, for a
  /// blob this device sent itself, its own copy.
  Future<void> _handleBlobGet(
    RelayState state,
    String from,
    Map<String, dynamic> payload,
  ) async {
    final Object? blobId = payload['b'];
    final Object? rawSender = payload['s'];
    if (_blobs == null || blobId is! String || rawSender is! String) {
      return;
    }
    final String sender = PeerShareCodec.normalizeAddress(rawSender);
    final List<int> wanted = RelayEngine._intListOf(
      payload['i'],
      limit: config.blobWindow * 2,
    );
    final RelayHeldBlob? held = state.heldBlobs[from]?['$sender|$blobId'];
    final RelayBlobOut? own = held == null && sender == _self
        ? state.outBlobs[blobId]
        : null;
    final List<int> missing = <int>[];
    if (held == null && (own == null || own.recipient != from)) {
      missing.addAll(wanted);
    } else {
      for (final int i in wanted) {
        final bool has = held != null
            ? held.have.contains(i)
            : i >= 0 && i < own!.chunkCount;
        final Uint8List? sealed = !has
            ? null
            : await _readChunk(
                held != null
                    ? _heldChunkKey(from, sender, blobId, i)
                    : _outChunkKey(blobId, i),
              );
        if (sealed == null) {
          missing.add(i);
          continue;
        }
        await _sendQuietly(from, <String, dynamic>{
          'type': 'rly_bchunk',
          'b': blobId,
          's': sender,
          'i': i,
          'chunkData': base64Encode(sealed),
        });
      }
    }
    if (missing.isNotEmpty || wanted.isEmpty) {
      await _sendQuietly(from, <String, dynamic>{
        'type': 'rly_bnone',
        'b': blobId,
        's': sender,
        'i': missing,
      });
    }
  }

  /// The recipient has the whole blob: the copy here can go.
  Future<bool> _handleBlobDrop(
    RelayState state,
    String from,
    Map<String, dynamic> payload,
  ) async {
    final Object? blobId = payload['b'];
    final Object? rawSender = payload['s'];
    if (blobId is! String || rawSender is! String) {
      return false;
    }
    final String scope =
        '${PeerShareCodec.normalizeAddress(rawSender)}|$blobId';
    final Map<String, RelayHeldBlob>? held = state.heldBlobs[from];
    final RelayHeldBlob? blob = held?.remove(scope);
    if (blob == null) {
      return false; // only what is actually held leaves a tombstone
    }
    if (held!.isEmpty) {
      state.heldBlobs.remove(from);
    }
    state.tombstones['$from|blob:$scope'] = blob.holdUntilMillis;
    _capTombstones(state);
    await _deleteHeld(from, blob);
    return true;
  }

  Future<void> _deleteHeld(String recipient, RelayHeldBlob blob) =>
      _deleteChunks(
        blob.chunkCount,
        (int i) => _heldChunkKey(recipient, blob.sender, blob.blobId, i),
      );

  // ---------------------------------------------------------------------------
  // Recipient
  // ---------------------------------------------------------------------------

  /// Starts collecting the blob a manifest announces. [via] delivered the
  /// manifest (the sender, or a mailbox) and is asked first: it is online.
  Future<bool> _acceptBlobManifest(
    RelayState state,
    SignalTransportFrame frame,
    List<SignalTransportFrame> forward, {
    required String via,
  }) async {
    final String sender = PeerShareCodec.normalizeAddress(frame.from);
    final Map<String, dynamic> p = frame.payload;
    final RelayBlobKind? kind = RelayBlobKind.fromWire(p['k']);
    final Object? blobId = p['b'];
    final Uint8List? key = decodeRelayKey(p['key']);
    final int count = RelayEngine._intOf(p['n']);
    final int chunkSize = RelayEngine._intOf(p['cs']);
    final int size = RelayEngine._intOf(p['z']);
    final int expires = RelayEngine._intOf(p['x']);
    final int now = _now();
    if (_blobs == null ||
        kind == null ||
        blobId is! String ||
        blobId.isEmpty ||
        blobId.length > _maxReliableIdLength ||
        key == null ||
        chunkSize <= 0 ||
        chunkSize > config.maxBlobChunkBytes ||
        size <= 0 ||
        size >
            (kind == RelayBlobKind.payload
                ? config.maxPayloadBlobBytes
                : config.maxBlobBytes) ||
        count != (size + chunkSize - 1) ~/ chunkSize ||
        expires <= now ||
        expires >
            now +
                config.messageTtl.inMilliseconds +
                config.maxClockSkew.inMilliseconds ||
        !_isContact(sender)) {
      return false;
    }
    final String scope = '$sender|$blobId';
    if (state.inBlobs.containsKey(scope)) {
      return false;
    }
    final Object? ref = p['ref'];
    final Object? messageId = p['msgId'];
    final Object? digest = p['h'];
    if (kind == RelayBlobKind.payload) {
      if (ref is! String ||
          ref.isEmpty ||
          ref.length > _maxReliableIdLength ||
          digest is! String) {
        return false;
      }
      if (state.seen.containsKey('$sender|$ref')) {
        // Arrived directly in the meantime: the copies can go.
        await _announceBlobCollected(state, sender, blobId);
        return false;
      }
    } else if (messageId is! String ||
        messageId.isEmpty ||
        messageId.length > 256) {
      return false;
    }
    if (state.inBlobs.length >= config.maxIncomingBlobs) {
      logZenWarning('Too many attachments being collected; one is skipped.');
      return false;
    }
    final RelayBlobIn blob = RelayBlobIn(
      blobId: blobId,
      sender: sender,
      kind: kind,
      key: key,
      chunkCount: count,
      chunkSize: chunkSize,
      plainBytes: size,
      createdAtMillis: now,
      expiresAtMillis: expires,
      digest: kind == RelayBlobKind.payload ? digest as String : null,
      ref: kind == RelayBlobKind.payload ? ref as String : null,
      messageId: kind == RelayBlobKind.attachment ? messageId as String : null,
      meta: kind == RelayBlobKind.attachment
          ? _attachmentMeta(p['meta'])
          : null,
    );
    state.inBlobs[scope] = blob;
    if (kind == RelayBlobKind.attachment) {
      // The chat shows it (as on its way) before the first chunk is in.
      forward.add(_attachmentFrame(blob));
    }
    await _requestBlobChunks(state, blob, now, prefer: via);
    return true;
  }

  /// What the app gets for an attachment blob: its placeholder, or one of
  /// its chunks — the frames of the sender's own live transfer.
  SignalTransportFrame _attachmentFrame(
    RelayBlobIn blob, {
    int? index,
    Uint8List? data,
  }) {
    return SignalTransportFrame(
      from: blob.sender,
      payload: <String, dynamic>{
        ...blob.meta,
        'type': index == null ? 'message_placeholder' : 'message_chunk',
        'msgId': blob.messageId,
        'attachmentTransferBytes': blob.plainBytes,
        'chunkCount': blob.chunkCount,
        'chunkIndex': ?index,
        if (data != null) 'chunkData': base64Encode(data),
      },
      receivedAtMillis: _now(),
    );
  }

  /// Where a blob can be collected from, in order: this device's mailboxes
  /// that hold attachments, then the sender itself.
  List<String> _blobSources(RelayState state, RelayBlobIn blob) {
    return <String>[
      for (final String relay in state.currentRelays)
        if (relay != blob.sender &&
            (state.peers[relay]?.blobQuotaBytes ?? 0) > 0)
          relay,
      blob.sender,
    ];
  }

  /// Asks one source for the next window of missing chunks ([prefer] if it
  /// is a source, else the current one in turn).
  Future<void> _requestBlobChunks(
    RelayState state,
    RelayBlobIn blob,
    int now, {
    String? prefer,
  }) async {
    final _BlobPull pull = _blobPulls.putIfAbsent(blob.scope, _BlobPull.new);
    final List<String> sources = _blobSources(state, blob);
    final List<int> missing = blob.missing(config.blobWindow);
    if (missing.isEmpty) {
      return;
    }
    final int preferred = prefer == null ? -1 : sources.indexOf(prefer);
    if (preferred >= 0) {
      pull.sourceIndex = preferred;
    }
    final String source = sources[pull.sourceIndex % sources.length];
    pull.window = _BlobWindow(
      source: source,
      indexes: missing.toSet(),
      sinceMillis: now,
    );
    await _sendQuietly(source, <String, dynamic>{
      'type': 'rly_bget',
      'b': blob.blobId,
      's': blob.sender,
      'i': missing,
    });
  }

  /// Keeps collections going: asks the next source when a window went
  /// unanswered. Once every source came up empty it waits a poll interval,
  /// or until one of them shows up ([onlySource]).
  Future<void> _resumeBlobPulls(
    RelayState state,
    int now, {
    String? onlySource,
  }) async {
    for (final RelayBlobIn blob in state.inBlobs.values.toList()) {
      if (blob.isComplete || blob.expiresAtMillis <= now) {
        continue;
      }
      final _BlobPull pull = _blobPulls.putIfAbsent(blob.scope, _BlobPull.new);
      final _BlobWindow? window = pull.window;
      final bool waiting =
          window != null &&
          window.indexes.isNotEmpty &&
          now - window.sinceMillis < config.blobRequestTimeout.inMilliseconds;
      if (onlySource != null) {
        if (waiting || !_blobSources(state, blob).contains(onlySource)) {
          continue;
        }
        pull.misses = 0;
        await _requestBlobChunks(state, blob, now, prefer: onlySource);
        continue;
      }
      if (waiting) {
        continue;
      }
      final int sourceCount = _blobSources(state, blob).length;
      if (window != null && window.indexes.isNotEmpty) {
        // Unanswered: that source is probably offline. Counted once.
        pull
          ..misses += 1
          ..sourceIndex += 1
          ..window = _BlobWindow(
            source: window.source,
            indexes: <int>{},
            sinceMillis: window.sinceMillis,
          );
      }
      final _BlobWindow? last = pull.window;
      if (pull.misses >= sourceCount) {
        if (last != null &&
            now - last.sinceMillis < config.pollInterval.inMilliseconds) {
          continue;
        }
        pull.misses = 0;
      }
      await _requestBlobChunks(state, blob, now);
    }
  }

  Future<bool> _handleBlobChunk(
    RelayState state,
    String from,
    Map<String, dynamic> payload,
    List<SignalTransportFrame> forward,
  ) async {
    final Object? blobId = payload['b'];
    final Object? rawSender = payload['s'];
    final Object? data = payload['chunkData'];
    final int index = RelayEngine._intOf(payload['i']);
    if (blobId is! String || rawSender is! String || data is! String) {
      return false;
    }
    final String sender = PeerShareCodec.normalizeAddress(rawSender);
    final RelayBlobIn? blob = state.inBlobs['$sender|$blobId'];
    if (blob == null ||
        index < 0 ||
        index >= blob.chunkCount ||
        !(from == blob.sender || state.currentRelays.contains(from))) {
      return false;
    }
    final _BlobPull? pull = _blobPulls[blob.scope];
    if (blob.received.contains(index)) {
      pull?.window?.indexes.remove(index);
      return false;
    }
    final Uint8List plain;
    try {
      plain = await RelayBlobCipher.openChunk(
        key: blob.key,
        index: index,
        sealed: base64Decode(data),
        associatedData: RelayBlobCipher.associatedDataFor(
          blobId: blob.blobId,
          sender: blob.sender,
          recipient: _self,
          index: index,
          count: blob.chunkCount,
        ),
      );
    } catch (error) {
      logZenWarning('Dropping an attachment chunk that failed to open: $error');
      return false;
    }
    final int expected = index < blob.chunkCount - 1
        ? blob.chunkSize
        : blob.plainBytes - blob.chunkSize * (blob.chunkCount - 1);
    if (plain.length != expected) {
      return false;
    }
    if (blob.kind == RelayBlobKind.payload) {
      try {
        await _blobs!.writeBlobChunk(
          _inChunkKey(blob.sender, blob.blobId, index),
          plain,
        );
      } catch (error, stackTrace) {
        logZenError('Storing a received chunk failed', error, stackTrace);
        return false;
      }
    } else {
      forward.add(_attachmentFrame(blob, index: index, data: plain));
    }
    blob.received.add(index);
    if (pull != null) {
      pull.misses = 0;
      pull.window?.indexes.remove(index);
    }
    if (blob.isComplete) {
      await _completeBlob(state, blob, forward);
      return true;
    }
    final _BlobWindow? window = pull?.window;
    if (window == null || window.indexes.isEmpty) {
      await _requestBlobChunks(state, blob, _now(), prefer: from);
    }
    return true;
  }

  /// A source does not have (some of) the chunks asked for: on to the next.
  Future<void> _handleBlobNone(
    RelayState state,
    String from,
    Map<String, dynamic> payload,
  ) async {
    final Object? blobId = payload['b'];
    final Object? rawSender = payload['s'];
    if (blobId is! String || rawSender is! String) {
      return;
    }
    final String scope =
        '${PeerShareCodec.normalizeAddress(rawSender)}|$blobId';
    final RelayBlobIn? blob = state.inBlobs[scope];
    final _BlobPull? pull = _blobPulls[scope];
    final _BlobWindow? window = pull?.window;
    if (blob == null ||
        pull == null ||
        window == null ||
        window.source != from) {
      return;
    }
    pull
      ..window = null
      ..misses += 1
      ..sourceIndex += 1;
    if (pull.misses < _blobSources(state, blob).length) {
      await _requestBlobChunks(state, blob, _now());
    } else {
      // Nobody has the rest right now; the next sighting or poll retries.
      pull.window = _BlobWindow(
        source: from,
        indexes: <int>{},
        sinceMillis: _now(),
      );
    }
  }

  Future<void> _completeBlob(
    RelayState state,
    RelayBlobIn blob,
    List<SignalTransportFrame> forward,
  ) async {
    state.inBlobs.remove(blob.scope);
    _blobPulls.remove(blob.scope);
    if (blob.kind == RelayBlobKind.payload) {
      final Map<String, dynamic>? inner = await _assemblePayload(blob);
      await _deleteChunks(
        blob.chunkCount,
        (int i) => _inChunkKey(blob.sender, blob.blobId, i),
      );
      final String ref = blob.ref!;
      if (inner == null || inner[kReliableIdKey] != ref) {
        logZenWarning('Dropping a collected payload that does not check out.');
      } else {
        final String seenKey = '${blob.sender}|$ref';
        if (!state.seen.containsKey(seenKey)) {
          state.seen[seenKey] = max(
            blob.expiresAtMillis,
            _now() + config.messageTtl.inMilliseconds,
          );
          forward.add(
            SignalTransportFrame(
              from: blob.sender,
              payload: inner,
              receivedAtMillis: _now(),
            ),
          );
        }
        // The sender keeps retrying until it hears from us directly.
        await _sendQuietly(blob.sender, <String, dynamic>{
          'type': 'rly_ack',
          'rid': ref,
        });
      }
    }
    await _announceBlobCollected(state, blob.sender, blob.blobId);
  }

  Future<Map<String, dynamic>?> _assemblePayload(RelayBlobIn blob) async {
    final List<int> bytes = <int>[];
    for (int i = 0; i < blob.chunkCount; i++) {
      final Uint8List? chunk = await _readChunk(
        _inChunkKey(blob.sender, blob.blobId, i),
      );
      if (chunk == null) {
        return null;
      }
      bytes.addAll(chunk);
    }
    if (bytes.length != blob.plainBytes ||
        base64Url.encode(crypto.sha256.convert(bytes).bytes) != blob.digest) {
      return null;
    }
    try {
      final Object? decoded = jsonDecode(utf8.decode(bytes));
      return decoded is Map ? Map<String, dynamic>.from(decoded) : null;
    } on FormatException {
      return null;
    }
  }

  /// A manifest seen before: unless that blob is still being collected, the
  /// sender may drop its copy (the first `rly_bdone` may have been lost).
  Future<void> _remindBlobCollected(
    RelayState state,
    String sender,
    Object? blobId,
  ) async {
    if (blobId is! String || state.inBlobs.containsKey('$sender|$blobId')) {
      return;
    }
    await _sendQuietly(sender, <String, dynamic>{
      'type': 'rly_bdone',
      'b': blobId,
    });
  }

  /// Tells the mailboxes to drop their copies and the sender to stop.
  Future<void> _announceBlobCollected(
    RelayState state,
    String sender,
    String blobId,
  ) async {
    for (final String relay in state.currentRelays) {
      if (relay != sender) {
        await _sendQuietly(relay, <String, dynamic>{
          'type': 'rly_bdrop',
          'b': blobId,
          's': sender,
        });
      }
    }
    await _sendQuietly(sender, <String, dynamic>{
      'type': 'rly_bdone',
      'b': blobId,
    });
  }

  // ---------------------------------------------------------------------------
  // Housekeeping
  // ---------------------------------------------------------------------------

  /// Drops expired blobs everywhere, and what is held for people this device
  /// no longer serves. Returns whether the state changed.
  Future<bool> _blobHousekeeping(RelayState state, int now) async {
    bool changed = false;
    for (final RelayBlobOut blob in state.outBlobs.values.toList()) {
      if (blob.expiresAtMillis <= now) {
        await _dropOutBlob(state, blob);
        changed = true;
      }
    }
    for (final String recipient in state.heldBlobs.keys.toList()) {
      final Map<String, RelayHeldBlob> held = state.heldBlobs[recipient]!;
      // Unknown until the friend list is loaded: kept until then.
      final bool serves = !_peers.isReady || _servesRecipient(state, recipient);
      for (final RelayHeldBlob blob in held.values.toList()) {
        if (!serves || blob.holdUntilMillis <= now) {
          held.remove(blob.scope);
          await _deleteHeld(recipient, blob);
          changed = true;
        }
      }
      if (held.isEmpty) {
        state.heldBlobs.remove(recipient);
      }
    }
    for (final RelayBlobIn blob in state.inBlobs.values.toList()) {
      if (blob.expiresAtMillis <= now) {
        state.inBlobs.remove(blob.scope);
        _blobPulls.remove(blob.scope);
        if (blob.kind == RelayBlobKind.payload) {
          await _deleteChunks(
            blob.chunkCount,
            (int i) => _inChunkKey(blob.sender, blob.blobId, i),
          );
        }
        changed = true;
      }
    }
    return changed;
  }
}
