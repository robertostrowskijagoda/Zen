import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:zen/src/core/ledger/blob_store.dart';
import 'package:zen/src/core/ledger/ledger_codec.dart';
import 'package:zen/src/core/ledger/ledger_identity.dart';
import 'package:zen/src/core/ledger/ledger_store.dart';
import 'package:zen/src/core/ledger/log_entry.dart';

typedef LedgerSend = void Function(String peer, Map<String, dynamic> message);

/// Message types on the wire.
abstract final class LedgerMessages {
  static const String heads = 'lg_heads';
  static const String want = 'lg_want';
  static const String entries = 'lg_entries';
  static const String revoke = 'lg_revoke';

  /// "Send me these devices' certificates": `items` [{a: account,
  /// d: device}], for entries that came without one known here.
  static const String certWant = 'lg_cert_want';

  /// The answer: `items` [DeviceCertificate].
  static const String certs = 'lg_certs';
  static const String blobWant = 'lg_blob_want';
  static const String blobManifest = 'lg_blob_manifest';
  static const String blobChunk = 'lg_blob_chunk';

  static const Set<String> all = <String>{
    heads,
    want,
    entries,
    revoke,
    certWant,
    certs,
    blobWant,
    blobManifest,
    blobChunk,
  };
}

/// Keeps this device's logs and files in step with its peers.
///
/// The protocol is "compare heads, send the difference":
///
/// 1. `lg_heads` lists, for some spaces, how far each log goes here.
/// 2. The other side answers with the entries the sender lacks
///    (`lg_entries`), and asks for what it lacks itself (`lg_want`).
/// 3. Equal heads → no reply, so gossip always comes to rest.
///
/// Entries travel without their device's certificate (the record that
/// publishes the device's ML-DSA key, about 10 KB): the receiver keeps the
/// certificates of the devices it holds entries of, and asks the sender
/// for one it lacks (`lg_cert_want` → `lg_certs`); until it comes, such
/// entries wait unchecked and are never taken.
///
/// It never trusts the peer: every entry goes through [LedgerStore]'s
/// checks, every file piece through its hash.
final class LedgerReplicator {
  LedgerReplicator({
    required this.store,
    required this.blobs,
    required this.send,
    required this.peers,
    this.acceptsFrom,
    this.servesTo,
    this.forwardsFrom,
    this.maxEntriesPerMessage = 100,
    this.maxBytesPerMessage = 256 * 1024,
    this.maxMessagesPerMinute = 3000,
  }) {
    _subscription = store.added.listen(
      (LogEntry e) => _scheduleAnnounce(e.space),
    );
  }

  final LedgerStore store;
  final BlobStore blobs;
  final LedgerSend send;

  /// Who to tell about news (online friends, in the app).
  final Iterable<String> Function() peers;

  /// Whether [peer] may hand us entries of [space]; default: any space we
  /// subscribe to. The app narrows this to "friends push, strangers only
  /// answer what we asked".
  final bool Function(String peer, String space)? acceptsFrom;

  /// Whether [peer] may get [space] (heads, entries) at all; everything
  /// when not set.
  final bool Function(String peer, String space)? servesTo;

  /// Whether [peer] may hand us entries of [space] only to be passed on
  /// (a space of a kind this build does not know): such a space is
  /// asked for and taken like a subscribed one, though not followed.
  final bool Function(String peer, String space)? forwardsFrom;

  bool _forwards(String peer, String space) =>
      forwardsFrom?.call(peer, space) ?? false;

  bool _serves(String peer, String space) =>
      servesTo?.call(peer, space) ?? true;
  final int maxEntriesPerMessage;
  final int maxBytesPerMessage;
  final int maxMessagesPerMinute;

  late final StreamSubscription<LogEntry> _subscription;

  /// Spaces this device keeps and follows.
  final Set<String> subscriptions = <String>{};

  final Set<String> _announcePending = <String>{};
  final Map<String, List<String>> _blobSources = <String, List<String>>{};
  final Map<String, int> _blobRound = <String, int>{};

  /// Sources that answered for a blob (a manifest or a piece): pieces are
  /// asked from them, not from someone who may be offline.
  final Map<String, Set<String>> _answered = <String, Set<String>>{};

  /// Chunks asked for and not received yet, per blob. The next batch goes
  /// out when this empties, so a source that answers only part of a
  /// request (a stranger's limit) does not stall the download.
  final Map<String, Set<String>> _pendingChunks = <String, Set<String>>{};

  /// Chunks asked from one source in one message.
  static const int chunksPerRequest = 4;
  final Map<String, (int, int)> _budget = <String, (int, int)>{};

  /// `peer|account|device` → when its certificate was last asked of the
  /// peer (asked again after [certificateRetryMs], or in the next sync
  /// with the peer).
  final Map<String, int> _certAsked = <String, int>{};

  static const int certificateRetryMs = 30 * 1000;

  /// Most certificates asked for or handed out in one message.
  static const int certificatesPerMessage = 32;

  /// Called whenever a blob became complete here.
  void Function(String blobId)? onBlobComplete;

  void subscribe(String space) => subscriptions.add(space);

  void unsubscribe(String space) => subscriptions.remove(space);

  Map<String, dynamic> _headsMessage(Iterable<String> spaces) =>
      <String, dynamic>{
        'type': LedgerMessages.heads,
        'spaces': <String, dynamic>{
          for (final String s in spaces) s: store.heads(s),
        },
      };

  /// Starts a sync with [peer] for every subscribed space (and [extra]).
  /// With [only], syncs just those spaces and sends no revocations (for
  /// peers that are not friends, e.g. an account being followed).
  void syncWith(
    String peer, {
    Iterable<String> extra = const <String>[],
    Iterable<String>? only,
  }) {
    final Set<String> spaces =
        (only != null ? only.toSet() : <String>{...subscriptions, ...extra})
          ..removeWhere((String s) => !_serves(peer, s));
    if (spaces.isEmpty) {
      return;
    }
    // A new round: certificates still missing may be asked of it again.
    _certAsked.removeWhere((String key, int _) => key.startsWith('$peer|'));
    send(peer, _headsMessage(spaces));
    if (only != null) {
      return;
    }
    final List<DeviceRevocation> revocations = store.directory.revocations
        .toList();
    if (revocations.isNotEmpty) {
      send(peer, <String, dynamic>{
        'type': LedgerMessages.revoke,
        'items': <Map<String, dynamic>>[
          for (final DeviceRevocation r in revocations) r.toJson(),
        ],
      });
    }
  }

  void _scheduleAnnounce(String space) {
    if (!_announcePending.add(space)) {
      return;
    }
    scheduleMicrotask(() {
      if (!_announcePending.remove(space)) {
        return;
      }
      final Map<String, dynamic> message = _headsMessage(<String>[space]);
      for (final String peer in peers()) {
        if (_serves(peer, space)) {
          send(peer, message);
        }
      }
    });
  }

  /// Tells every peer about a revocation.
  Future<bool> publishRevocation(DeviceRevocation revocation) async {
    if (await store.applyRevocation(revocation) < 0) {
      return false;
    }
    final Map<String, dynamic> message = <String, dynamic>{
      'type': LedgerMessages.revoke,
      'items': <Map<String, dynamic>>[revocation.toJson()],
    };
    for (final String peer in peers()) {
      send(peer, message);
    }
    return true;
  }

  bool _withinBudget(String peer) {
    final int minute = store.clock.wallMillis() ~/ 60000;
    final (int, int) current = _budget[peer] ?? (minute, 0);
    final int count = current.$1 == minute ? current.$2 + 1 : 1;
    _budget[peer] = (minute, count);
    return count <= maxMessagesPerMinute;
  }

  /// Handles one message from [peer]. Unknown or malformed input is
  /// ignored.
  Future<void> handle(String peer, Map<String, dynamic> message) async {
    if (!_withinBudget(peer)) {
      return;
    }
    try {
      switch (message['type']) {
        case LedgerMessages.heads:
          _onHeads(peer, message['spaces']);
        case LedgerMessages.want:
          _onWant(peer, message['space'], message['from']);
        case LedgerMessages.entries:
          await _onEntries(peer, message['entries']);
        case LedgerMessages.revoke:
          await _onRevoke(peer, message['items']);
        case LedgerMessages.certWant:
          answerCertificates(peer, message['items']);
        case LedgerMessages.certs:
          await _onCertificates(message['items']);
        case LedgerMessages.blobWant:
          await _onBlobWant(peer, message['id'], message['chunks']);
        case LedgerMessages.blobManifest:
          _onBlobManifest(peer, message['id'], message['manifest']);
        case LedgerMessages.blobChunk:
          await _onBlobChunk(peer, message['h'], message['d']);
      }
    } on Object catch (_) {
      // A peer's garbage must never break our side.
    }
  }

  void _onHeads(String peer, Object? spaces) {
    if (spaces is! Map) {
      return;
    }
    for (final MapEntry<dynamic, dynamic> e in spaces.entries) {
      final Object? space = e.key;
      final Object? theirs = e.value;
      if (space is! String || theirs is! Map || !_serves(peer, space)) {
        continue;
      }
      final Map<String, int> their = <String, int>{
        for (final MapEntry<dynamic, dynamic> h in theirs.entries)
          if (h.key is String && h.value is int)
            h.key as String: h.value as int,
      };
      final Map<String, int> mine = store.heads(space);
      // What they lack: send it.
      final Map<String, int> theyLack = <String, int>{
        for (final MapEntry<String, int> m in mine.entries)
          if ((their[m.key] ?? 0) < m.value) m.key: their[m.key] ?? 0,
      };
      if (theyLack.isNotEmpty) {
        _sendEntries(peer, space, theyLack);
      }
      // What we lack: ask for it.
      if (subscriptions.contains(space) || _forwards(peer, space)) {
        final Map<String, int> weLack = <String, int>{
          for (final MapEntry<String, int> t in their.entries)
            if ((mine[t.key] ?? 0) < t.value && !store.isForked(space, t.key))
              t.key: mine[t.key] ?? 0,
        };
        if (weLack.isNotEmpty) {
          send(peer, <String, dynamic>{
            'type': LedgerMessages.want,
            'space': space,
            'from': weLack,
          });
        }
      }
    }
  }

  void _onWant(String peer, Object? space, Object? from) {
    if (space is! String || from is! Map || !_serves(peer, space)) {
      return;
    }
    _sendEntries(peer, space, <String, int>{
      for (final MapEntry<dynamic, dynamic> f in from.entries)
        if (f.key is String && f.value is int) f.key as String: f.value as int,
    });
  }

  void _sendEntries(String peer, String space, Map<String, int> fromSeq) {
    final List<Map<String, dynamic>> batch = <Map<String, dynamic>>[];
    int bytes = 0;
    void flush() {
      if (batch.isEmpty) {
        return;
      }
      send(peer, <String, dynamic>{
        'type': LedgerMessages.entries,
        'entries': List<Map<String, dynamic>>.of(batch),
      });
      batch.clear();
      bytes = 0;
    }

    for (final MapEntry<String, int> f in fromSeq.entries) {
      for (final LogEntry e in store.entriesAfter(space, f.key, f.value)) {
        if (batch.length >= maxEntriesPerMessage ||
            bytes + e.encodedLength > maxBytesPerMessage) {
          flush();
        }
        batch.add(e.toJson());
        bytes += e.encodedLength;
      }
    }
    flush();
  }

  Future<void> _onEntries(String peer, Object? raw) async {
    if (raw is! List) {
      return;
    }
    final List<LogEntry> entries = <LogEntry>[
      for (final Object? json in raw) ?LogEntry.fromJson(json),
    ];
    // Oldest first per log, so successors do not wait needlessly.
    entries.sort((LogEntry a, LogEntry b) {
      final int byLog = '${a.space}|${a.writer}'.compareTo(
        '${b.space}|${b.writer}',
      );
      return byLog != 0 ? byLog : a.seq.compareTo(b.seq);
    });
    final Set<(String, String)> missing = <(String, String)>{};
    for (final LogEntry entry in entries) {
      final bool allowed =
          (acceptsFrom?.call(peer, entry.space) ??
              subscriptions.contains(entry.space)) ||
          _forwards(peer, entry.space);
      if (!allowed) {
        continue;
      }
      final IngestResult result = await store.ingest(entry);
      if (result.status == IngestStatus.awaitingCertificate) {
        missing.add((entry.account, entry.device));
      }
    }
    _askCertificates(peer, missing);
  }

  /// Asks [peer], which sent entries of [devices], for their certificates.
  void _askCertificates(String peer, Set<(String, String)> devices) {
    if (devices.isEmpty) {
      return;
    }
    final int now = store.clock.wallMillis();
    if (_certAsked.length > 4096) {
      _certAsked.removeWhere(
        (String _, int at) => now - at >= certificateRetryMs,
      );
    }
    final List<Map<String, String>> items = <Map<String, String>>[];
    for (final (String account, String device) in devices) {
      final String key = '$peer|$account|$device';
      final int? at = _certAsked[key];
      if (at != null && now - at < certificateRetryMs) {
        continue;
      }
      _certAsked[key] = now;
      items.add(<String, String>{'a': account, 'd': device});
      if (items.length >= certificatesPerMessage) {
        break;
      }
    }
    if (items.isNotEmpty) {
      send(peer, <String, dynamic>{
        'type': LedgerMessages.certWant,
        'items': items,
      });
    }
  }

  /// Answers [peer]'s `lg_cert_want`: the certificates of the devices
  /// whose entries this store holds in a space [peer] may get ([inSpace]
  /// narrows that further, e.g. to what a stranger may read).
  void answerCertificates(
    String peer,
    Object? items, {
    bool Function(String space)? inSpace,
  }) {
    if (items is! List) {
      return;
    }
    final List<Map<String, dynamic>> certs = <Map<String, dynamic>>[];
    for (final Object? item in items.take(certificatesPerMessage)) {
      if (item is! Map || item['a'] is! String || item['d'] is! String) {
        continue;
      }
      final String account = item['a'] as String;
      final String device = item['d'] as String;
      final DeviceCertificate? cert = store.directory.certificateOf(
        account,
        device,
      );
      if (cert != null &&
          store.holdsLogOf(
            account,
            device,
            inSpace: (String space) =>
                _serves(peer, space) && (inSpace?.call(space) ?? true),
          )) {
        certs.add(cert.toJson());
      }
    }
    if (certs.isNotEmpty) {
      send(peer, <String, dynamic>{
        'type': LedgerMessages.certs,
        'items': certs,
      });
    }
  }

  /// Certificates a peer sent: only those of devices whose entries wait
  /// here are taken (and checked), then those entries.
  Future<void> _onCertificates(Object? items) async {
    if (items is! List) {
      return;
    }
    for (final Object? json in items.take(certificatesPerMessage)) {
      final DeviceCertificate? cert = DeviceCertificate.fromJson(json);
      if (cert != null && store.awaitsCertificate(cert.account, cert.device)) {
        await store.addCertificate(cert);
      }
    }
  }

  Future<void> _onRevoke(String peer, Object? items) async {
    if (items is! List) {
      return;
    }
    for (final Object? json in items.take(64)) {
      final DeviceRevocation? revocation = DeviceRevocation.fromJson(json);
      if (revocation == null) {
        continue;
      }
      final bool known = store.directory.revocations.any(
        (DeviceRevocation r) => r.signature == revocation.signature,
      );
      if (known) {
        continue;
      }
      if (await store.applyRevocation(revocation) >= 0) {
        // Pass it on: a cut-off must reach everyone.
        for (final String other in peers()) {
          if (other != peer) {
            send(other, <String, dynamic>{
              'type': LedgerMessages.revoke,
              'items': <Map<String, dynamic>>[revocation.toJson()],
            });
          }
        }
      }
    }
  }

  // ---- files ----

  /// Starts fetching blob [id] from [sources] (e.g. whoever gave us the
  /// post, then the author's circle).
  ///
  /// With [firstChunks] only the manifest and that many pieces from the
  /// start are fetched (the beginning of a film, ready to play at once);
  /// the blob then stops being wanted, so nothing else of it is fetched
  /// until someone asks for all of it. It never narrows a whole fetch
  /// already under way.
  void fetchBlob(String id, List<String> sources, {int? firstChunks}) {
    if (blobs.isComplete(id) || blobs.refused.contains(id) || sources.isEmpty) {
      return;
    }
    if (firstChunks == null) {
      _headOnly.remove(id);
    } else if (!blobs.wanted.contains(id) || _headOnly.containsKey(id)) {
      if (_headHere(id, firstChunks)) {
        return;
      }
      _headOnly[id] = firstChunks;
    }
    blobs.want(id);
    final List<String> known = _blobSources[id] ??= <String>[];
    for (final String s in sources) {
      if (!known.contains(s)) {
        known.add(s);
      }
    }
    _requestBlob(id);
  }

  /// [peer] just showed up: it may hold files we are still missing (say,
  /// a friend who got a post's photos before its author went offline), so
  /// ask it too — at most [limit] files at a time.
  void offerSource(String peer, {int limit = 32}) {
    int asked = 0;
    for (final String id in blobs.wanted.toList()) {
      if (asked >= limit) {
        break;
      }
      final List<String> known = _blobSources[id] ??= <String>[];
      if (known.contains(peer)) {
        continue;
      }
      known.add(peer);
      asked++;
      // A batch may be waiting on a source that went offline: ask anew.
      _pendingChunks.remove(id);
      _requestBlob(id);
    }
  }

  /// Stops fetching blob [id] for now (a film scrolled past): the pieces
  /// already here stay, and [fetchBlob] picks up where it stopped.
  void pauseBlob(String id) {
    _headOnly.remove(id);
    _pendingChunks.remove(id);
    blobs.markDone(id);
  }

  /// Asks again for whatever is still missing (call periodically).
  void retryBlobs() {
    for (final String id in blobs.wanted.toList()) {
      _blobRound[id] = (_blobRound[id] ?? 0) + 1;
      _pendingChunks.remove(id);
      _requestBlob(id);
    }
  }

  void _requestBlob(String id) {
    final List<String> sources = _blobSources[id] ?? const <String>[];
    if (sources.isEmpty) {
      return;
    }
    final int round = _blobRound[id] ?? 0;
    if (!blobs.hasManifest(id)) {
      for (int i = 0; i < sources.length && i < 3; i++) {
        send(sources[(round + i) % sources.length], <String, dynamic>{
          'type': LedgerMessages.blobWant,
          'id': id,
          'chunks': const <String>[],
        });
      }
      return;
    }
    final Set<String> pending = _pendingChunks[id] ??= <String>{};
    if (pending.isNotEmpty) {
      return; // the current batch is still on its way
    }
    final Set<String> answered = _answered[id] ?? const <String>{};
    final List<String> active = <String>[
      for (final String s in sources)
        if (answered.contains(s)) s,
    ];
    final List<String> use = active.isEmpty ? sources : active;
    final int? head = _headOnly[id];
    if (head != null && _headHere(id, head)) {
      _finishHead(id);
      return;
    }
    final List<String> missing = blobs
        .missingChunks(id)
        .where(
          (String c) =>
              head == null || blobs.manifest(id)!.chunks.indexOf(c) < head,
        )
        .take(chunksPerRequest * use.length)
        .toList();
    final Map<String, List<String>> perSource = <String, List<String>>{};
    for (int i = 0; i < missing.length; i++) {
      final String source = use[(round + i) % use.length];
      (perSource[source] ??= <String>[]).add(missing[i]);
    }
    pending.addAll(missing);
    perSource.forEach((String source, List<String> chunks) {
      send(source, <String, dynamic>{
        'type': LedgerMessages.blobWant,
        'id': id,
        'chunks': chunks,
      });
    });
  }

  Future<void> _onBlobWant(String peer, Object? id, Object? chunks) async {
    if (id is! String || chunks is! List || blobs.refused.contains(id)) {
      return;
    }
    final BlobManifest? manifest = blobs.manifest(id);
    if (manifest == null) {
      return;
    }
    if (chunks.isEmpty) {
      send(peer, <String, dynamic>{
        'type': LedgerMessages.blobManifest,
        'id': id,
        'manifest': manifest.toJson(),
      });
      return;
    }
    for (final Object? h in chunks.take(64)) {
      if (h is! String || !manifest.chunks.contains(h)) {
        continue;
      }
      final Uint8List? data = await blobs.chunk(h);
      if (data != null) {
        send(peer, <String, dynamic>{
          'type': LedgerMessages.blobChunk,
          'h': h,
          'd': base64.encode(data),
        });
      }
    }
  }

  void _onBlobManifest(String peer, Object? id, Object? manifest) {
    if (id is! String || !blobs.acceptManifest(id, manifest)) {
      return;
    }
    final List<String> sources = _blobSources[id] ??= <String>[];
    if (!sources.contains(peer)) {
      sources.insert(0, peer);
    }
    (_answered[id] ??= <String>{}).add(peer);
    _checkComplete(id);
    _requestBlob(id);
  }

  Future<void> _onBlobChunk(String peer, Object? hash, Object? data) async {
    if (hash is! String || data is! String) {
      return;
    }
    final Uint8List bytes;
    try {
      bytes = base64.decode(data);
    } on FormatException {
      return;
    }
    if (!await blobs.acceptChunk(hash, bytes)) {
      return;
    }
    for (final String id in blobs.wanted.toList()) {
      if (blobs.manifest(id)?.chunks.contains(hash) ?? false) {
        (_answered[id] ??= <String>{}).add(peer);
        final Set<String>? pending = _pendingChunks[id];
        pending?.remove(hash);
        _checkComplete(id);
        final int? head = _headOnly[id];
        if (head != null && _headHere(id, head)) {
          _finishHead(id);
        } else if (blobs.wanted.contains(id) && (pending?.isEmpty ?? true)) {
          _requestBlob(id);
        }
      }
    }
  }

  void _checkComplete(String id) {
    if (blobs.isComplete(id)) {
      blobs.markDone(id);
      _headOnly.remove(id);
      _blobSources.remove(id);
      _blobRound.remove(id);
      _pendingChunks.remove(id);
      _answered.remove(id);
      onBlobComplete?.call(id);
    }
  }

  /// Blobs fetched only up to a number of pieces ([fetchBlob]'s
  /// `firstChunks`).
  final Map<String, int> _headOnly = <String, int>{};

  /// Whether the manifest of [id] and its first [count] pieces are here.
  bool _headHere(String id, int count) {
    final BlobManifest? manifest = blobs.manifest(id);
    if (manifest == null) {
      return false;
    }
    final int n = count < manifest.chunks.length
        ? count
        : manifest.chunks.length;
    for (int i = 0; i < n; i++) {
      if (!blobs.backend.has(manifest.chunks[i])) {
        return false;
      }
    }
    return true;
  }

  /// The beginning of [id] is here: it is not wanted any more.
  void _finishHead(String id) {
    _headOnly.remove(id);
    _pendingChunks.remove(id);
    blobs.markDone(id);
    onBlobHead?.call(id);
  }

  /// Called when the beginning asked for with `firstChunks` arrived.
  void Function(String blobId)? onBlobHead;

  Future<void> dispose() => _subscription.cancel();
}

/// Size of [message] as it would travel, for budgeting in tests.
int ledgerMessageBytes(Map<String, dynamic> message) =>
    utf8.encode(jsonEncode(message)).length;

/// Whether [message] belongs to this protocol.
bool isLedgerMessage(Map<String, dynamic> message) =>
    LedgerMessages.all.contains(message['type']);

/// Stable hex id for anything JSON (e.g. a subscription key).
String ledgerHashOf(Object? json) => sha256Hex(canonicalJsonBytes(json));
