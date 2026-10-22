import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/core/ledger/ledger_codec.dart';
import 'package:zen/src/core/ledger/ledger_identity.dart';
import 'package:zen/src/core/logging/zen_log.dart';
import 'package:zen/src/features/account/circle_backup.dart';
import 'package:zen/src/features/account/circle_backup_holder.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';

/// Messages of the circle copy, over the signal transport:
///
/// * `cbk_offer {m}`: owner → holder, a new manifest;
/// * `cbk_need {a, mid, ids}`: holder → owner, the chunks it lacks;
/// * `cbk_chunk {a, id, c}`: owner → holder, one chunk;
/// * `cbk_ok {a, at}`: holder → owner, the copy is complete there;
/// * `cbk_no {a, why}`: holder → owner, refused;
/// * `cbk_fetch {r}`: recovered device → holders, a signed request;
/// * `cbk_manifest {m}`: holder → recovered device, the copy kept;
/// * `cbk_get {r, ids}`: recovered device → holder, chunks to send;
/// * `cbk_part {a, id, c}`: holder → recovered device, one chunk.
abstract final class CircleBackupMessages {
  static const String offer = 'cbk_offer';
  static const String need = 'cbk_need';
  static const String chunk = 'cbk_chunk';
  static const String ok = 'cbk_ok';
  static const String no = 'cbk_no';
  static const String fetch = 'cbk_fetch';
  static const String manifest = 'cbk_manifest';
  static const String get = 'cbk_get';
  static const String part = 'cbk_part';

  static const Set<String> all = <String>{
    offer,
    need,
    chunk,
    ok,
    no,
    fetch,
    manifest,
    get,
    part,
  };
}

/// Whose copy this device makes and asks for: the account, its self key
/// (the copy's key comes from it), this device's key and certificate.
@immutable
final class CircleBackupIdentity {
  const CircleBackupIdentity({
    required this.account,
    required this.selfKey,
    required this.deviceKey,
    required this.certificate,
  });

  final String account;
  final Uint8List selfKey;
  final LedgerKeyPair deviceKey;
  final DeviceCertificate certificate;
}

/// What the copy is made of and where it goes back to (the app's stores).
abstract interface class CircleBackupData {
  /// The account's data now; conversation text only when [chats].
  Future<CircleBackupContent> collect({required bool chats});

  /// Puts [content] back; [progress] counts what is done.
  Future<void> restore(
    CircleBackupContent content,
    void Function(int done, int total) progress,
  );
}

/// The last copy the circle confirmed, as the settings show it.
@immutable
final class CircleBackupStatus {
  const CircleBackupStatus({
    this.lastAt,
    this.bytes = 0,
    this.holders = 0,
    this.includeChats = true,
    this.droppedMessages = 0,
  });

  /// When the newest copy some holder confirmed was made.
  final int? lastAt;
  final int bytes;

  /// How many holders confirmed it.
  final int holders;

  /// Whether conversation text goes into the copy (on by default).
  final bool includeChats;

  /// Oldest messages left out to stay under the cap.
  final int droppedMessages;

  CircleBackupStatus copyWith({
    int? lastAt,
    int? bytes,
    int? holders,
    bool? includeChats,
    int? droppedMessages,
  }) => CircleBackupStatus(
    lastAt: lastAt ?? this.lastAt,
    bytes: bytes ?? this.bytes,
    holders: holders ?? this.holders,
    includeChats: includeChats ?? this.includeChats,
    droppedMessages: droppedMessages ?? this.droppedMessages,
  );
}

/// Where taking the copy back after a recovery is.
enum CircleBackupRestorePhase {
  idle,
  searching,
  downloading,
  applying,
  done,
  failed,
}

@immutable
final class CircleBackupRestore {
  const CircleBackupRestore(this.phase, {this.done = 0, this.total = 0});

  static const CircleBackupRestore idle = CircleBackupRestore(
    CircleBackupRestorePhase.idle,
  );

  final CircleBackupRestorePhase phase;
  final int done;
  final int total;
}

/// Makes this account's copy for its recovery circle, keeps the copies of
/// the people whose circle this device is in, and takes the copy back
/// after a recovery.
///
/// The copy is made at most once a day ([interval]), and sooner after an
/// important change ([changed]: a friend, a group) but not more often
/// than [changeInterval]. Only the chunks a holder lacks travel.
final class CircleBackupService {
  CircleBackupService({
    required this.transport,
    required this.disk,
    required this.data,
    required this.identity,
    required this.holders,
    required bool Function(String account) isInCircle,
    required this.restoreCandidates,
    int Function()? clock,
    this.interval = const Duration(days: 1),
    this.changeInterval = const Duration(hours: 1),
    this.tickInterval = const Duration(minutes: 15),
    this.maxBytes = kCircleBackupMaxBytes,
  }) : _clock = clock ?? (() => DateTime.now().millisecondsSinceEpoch),
       holder = CircleBackupHolder(disk: disk, isInCircle: isInCircle);

  final SignalTransport transport;
  final LedgerDisk disk;
  final CircleBackupData data;
  final CircleBackupIdentity? Function() identity;

  /// The circle's addresses (the helpers who confirmed a recovery key).
  final Iterable<String> Function() holders;

  /// Whom to ask for the copy after a recovery, besides the helpers the
  /// recovery named (friends, the account's other devices).
  final Iterable<String> Function() restoreCandidates;
  final int Function() _clock;
  final Duration interval;
  final Duration changeInterval;
  final Duration tickInterval;
  final int maxBytes;

  /// The copies kept here for others.
  final CircleBackupHolder holder;

  final ValueNotifier<CircleBackupStatus> status =
      ValueNotifier<CircleBackupStatus>(const CircleBackupStatus());
  final ValueNotifier<CircleBackupRestore> restore =
      ValueNotifier<CircleBackupRestore>(CircleBackupRestore.idle);

  static const String _statusKey = 'circle-backup/status';
  static const String _restoreKey = 'circle-backup/restore';

  /// How long after a recovery the copy is looked for.
  static const Duration restoreWindow = Duration(days: 30);

  StreamSubscription<SignalTransportFrame>? _frames;
  Timer? _timer;
  Future<void>? _started;
  Future<void> _queue = Future<void>.value();

  /// The last copy built here (its chunks answer the holders).
  CircleBackupBuild? _build;
  int _builtAt = 0;
  int _changedAt = 0;

  /// Holder address → the copy (`at`) it confirmed.
  final Map<String, int> _confirmed = <String, int>{};

  // After a recovery.
  int? _restoreSince;
  final Set<String> _restoreHelpers = <String>{};
  CircleBackupManifest? _target;
  String? _targetFrom;
  final Map<String, Uint8List> _got = <String, Uint8List>{};
  int _askedAt = 0;

  Future<void> start() => _started ??= _start();

  Future<void> _start() async {
    await _load();
    await holder.load();
    _frames = transport.frames.listen(
      (SignalTransportFrame f) => _enqueue(() => _onFrame(f)),
    );
    _timer = Timer.periodic(tickInterval, (_) => _enqueue(tick));
    _enqueue(tick);
  }

  Future<void> stop() async {
    _timer?.cancel();
    await _frames?.cancel();
  }

  /// Waits for the work queued so far (tests).
  Future<void> get idle => _queue;

  void _enqueue(Future<void> Function() work) {
    _queue = _queue.then((_) async {
      try {
        await work();
      } on Object catch (error, stackTrace) {
        logZenError('Kopia u kręgu', error, stackTrace);
      }
    });
  }

  /// Something important changed (a friend, a group): a copy goes out
  /// soon, at most once in [changeInterval].
  void changed() {
    _changedAt = _clock();
  }

  /// Turns conversation text in the copy on or off (a new copy follows).
  Future<void> setIncludeChats(bool include) async {
    status.value = status.value.copyWith(includeChats: include);
    await _saveStatus();
    changed();
    _builtAt = 0;
  }

  /// Marks [disk] as the new device of a recovered account: at the next
  /// start the copy is asked for from [helpers] (the recovery circle that
  /// gave the key, if known) and from friends.
  static Future<void> markRestore(
    LedgerDisk disk, {
    Iterable<String> helpers = const <String>[],
    int? at,
  }) => disk.write(
    _restoreKey,
    Uint8List.fromList(
      utf8.encode(
        jsonEncode(<String, dynamic>{
          'since': at ?? DateTime.now().millisecondsSinceEpoch,
          'helpers': <String>[
            for (final String h in helpers) PeerShareCodec.normalizeAddress(h),
          ],
        }),
      ),
    ),
  );

  /// Whether this device is still looking for its copy after a recovery.
  bool get restoring => _restoreSince != null;

  /// The periodic work: the kept copies of those who left, the restore
  /// after a recovery, this account's own copy.
  Future<void> tick() async {
    await holder.prune();
    if (restoring) {
      await _askForCopy();
      return;
    }
    await refresh();
  }

  /// Makes and offers a new copy when one is due ([force]: now).
  Future<void> refresh({bool force = false}) async {
    final CircleBackupIdentity? id = identity();
    final List<String> circle = <String>{
      for (final String h in holders()) PeerShareCodec.normalizeAddress(h),
    }.toList();
    if (id == null || circle.isEmpty) {
      return;
    }
    final int now = _clock();
    // Never rebuilt sooner than [changeInterval] (holders away: the same
    // copy is offered again instead).
    final bool due =
        force ||
        (now - _builtAt >= changeInterval.inMilliseconds &&
            (now - (status.value.lastAt ?? 0) >= interval.inMilliseconds ||
                _changedAt > _builtAt));
    if (!due) {
      // Holders that have not confirmed the last copy get it again.
      final CircleBackupBuild? build = _build;
      if (build != null) {
        for (final String h in circle) {
          if (_confirmed[h] != build.manifest.createdAt) {
            await _offer(h, build.manifest);
          }
        }
      }
      return;
    }
    final CircleBackupContent content = await data.collect(
      chats: status.value.includeChats,
    );
    final CircleBackupBuild build = await buildCircleBackup(
      content: content,
      account: id.account,
      selfKey: id.selfKey,
      deviceKey: id.deviceKey,
      certificate: id.certificate,
      at: now,
      maxBytes: maxBytes,
    );
    // Unchanged pieces give the same chunks: a holder is sent only what
    // changed (and the index, which carries the time).
    _builtAt = now;
    _build = build;
    status.value = status.value.copyWith(
      droppedMessages: build.droppedMessages,
    );
    for (final String h in circle) {
      await _offer(h, build.manifest);
    }
  }

  Future<void> _offer(String to, CircleBackupManifest manifest) => _send(
    to,
    <String, dynamic>{'type': CircleBackupMessages.offer, 'm': manifest.json},
  );

  Future<void> _send(String to, Map<String, dynamic> payload) async {
    try {
      await transport.send(remoteAddress: to, payload: payload);
    } on Object catch (error) {
      logZenWarning('Kopia u kręgu: wysyłka nie powiodła się: $error');
    }
  }

  Future<void> _onFrame(SignalTransportFrame frame) async {
    final Object? type = frame.payload['type'];
    if (type is! String || !CircleBackupMessages.all.contains(type)) {
      return;
    }
    final String from = PeerShareCodec.normalizeAddress(frame.from);
    final Map<String, dynamic> p = frame.payload;
    switch (type) {
      case CircleBackupMessages.offer:
        await _onOffer(from, p);
      case CircleBackupMessages.need:
        await _onNeed(from, p);
      case CircleBackupMessages.chunk:
        await _onChunk(from, p);
      case CircleBackupMessages.ok:
        await _onOk(from, p);
      case CircleBackupMessages.no:
        logZenWarning('Kopia u kręgu odrzucona: ${p['why']}');
      case CircleBackupMessages.fetch:
        await _onFetch(from, p);
      case CircleBackupMessages.manifest:
        await _onManifest(from, p);
      case CircleBackupMessages.get:
        await _onGet(from, p);
      case CircleBackupMessages.part:
        await _onPart(from, p);
    }
  }

  // ---- as a holder ----

  Future<void> _onOffer(String from, Map<String, dynamic> p) async {
    final CircleBackupManifest? m = CircleBackupManifest.parse(p['m']);
    if (m == null) {
      return;
    }
    final CircleBackupOfferResult result = await holder.offer(m);
    if (result != CircleBackupOfferResult.accepted) {
      await _send(from, <String, dynamic>{
        'type': CircleBackupMessages.no,
        'a': m.account,
        'why': result.name,
      });
      return;
    }
    final List<String> missing = await holder.missing(m.account);
    if (missing.isEmpty) {
      await holder.settle(m.account);
      await _send(from, <String, dynamic>{
        'type': CircleBackupMessages.ok,
        'a': m.account,
        'at': m.createdAt,
      });
      return;
    }
    await _send(from, <String, dynamic>{
      'type': CircleBackupMessages.need,
      'a': m.account,
      'mid': m.id,
      'ids': missing,
    });
  }

  Future<void> _onChunk(String from, Map<String, dynamic> p) async {
    final Object? account = p['a'];
    final Object? id = p['id'];
    final Uint8List? bytes = unb64(p['c']);
    if (account is! String || id is! String || bytes == null) {
      return;
    }
    if (await holder.putChunk(account, id, bytes)) {
      await _send(from, <String, dynamic>{
        'type': CircleBackupMessages.ok,
        'a': account,
        'at': holder.manifestOf(account)?.createdAt,
      });
    }
  }

  /// A recovered device asks for its copy: given when the request is
  /// signed by a device the account certified, and fresh.
  Future<void> _onFetch(String from, Map<String, dynamic> p) async {
    final String? account = await _checkRequest(p['r']);
    final CircleBackupManifest? m = account == null
        ? null
        : holder.manifestOf(account);
    if (m == null) {
      return;
    }
    await _send(from, <String, dynamic>{
      'type': CircleBackupMessages.manifest,
      'm': m.json,
    });
  }

  Future<void> _onGet(String from, Map<String, dynamic> p) async {
    final String? account = await _checkRequest(p['r']);
    final Object? ids = p['ids'];
    if (account == null || ids is! List) {
      return;
    }
    for (final String id in ids.whereType<String>().take(200)) {
      final Uint8List? chunk = await holder.chunk(account, id);
      if (chunk == null) {
        continue;
      }
      await _send(from, <String, dynamic>{
        'type': CircleBackupMessages.part,
        'a': account,
        'id': id,
        'c': b64(chunk),
      });
    }
  }

  /// The account a request is for, when it is signed by a device the
  /// account certified within the last hour; null otherwise.
  Future<String?> _checkRequest(Object? request) async {
    if (request is! Map<String, dynamic>) {
      return null;
    }
    final Object? account = request['a'];
    final Object? at = request['at'];
    final Object? sig = request['sig'];
    final DeviceCertificate? cert = DeviceCertificate.fromJson(request['cert']);
    if (account is! String ||
        at is! int ||
        sig is! String ||
        cert == null ||
        cert.account != account ||
        (_clock() - at).abs() > const Duration(hours: 1).inMilliseconds) {
      return null;
    }
    if (!await cert.verify() ||
        !await cert.verifyByDevice(_requestBytes(account, at), sig)) {
      return null;
    }
    return account;
  }

  static List<int> _requestBytes(String account, int at) =>
      utf8.encode('zen-circle-backup-request|$account|$at');

  // ---- as the owner ----

  Future<void> _onNeed(String from, Map<String, dynamic> p) async {
    final CircleBackupBuild? build = _build;
    final Object? ids = p['ids'];
    if (build == null || ids is! List) {
      return;
    }
    if (p['mid'] != build.manifest.id) {
      // It asks for an older copy: offer the newest instead.
      await _offer(from, build.manifest);
      return;
    }
    for (final String id in ids.whereType<String>()) {
      final Uint8List? chunk = build.chunks[id];
      if (chunk == null) {
        continue;
      }
      await _send(from, <String, dynamic>{
        'type': CircleBackupMessages.chunk,
        'a': build.manifest.account,
        'id': id,
        'c': b64(chunk),
      });
    }
  }

  Future<void> _onOk(String from, Map<String, dynamic> p) async {
    final CircleBackupBuild? build = _build;
    final Object? at = p['at'];
    if (build == null ||
        at != build.manifest.createdAt ||
        p['a'] != build.manifest.account) {
      return;
    }
    _confirmed[from] = at as int;
    status.value = status.value.copyWith(
      lastAt: at,
      bytes: build.manifest.totalBytes,
      holders: _confirmed.values.where((int x) => x == at).length,
    );
    await _saveStatus();
  }

  // ---- after a recovery ----

  Future<void> _askForCopy() async {
    final int? since = _restoreSince;
    final CircleBackupIdentity? id = identity();
    if (since == null || id == null) {
      return;
    }
    final int now = _clock();
    if (now - since > restoreWindow.inMilliseconds) {
      await _endRestore(CircleBackupRestorePhase.failed);
      return;
    }
    final CircleBackupManifest? target = _target;
    final String? from = _targetFrom;
    if (target != null && from != null) {
      // Asked again for what has not come (every tick).
      await _requestChunks(from, target);
      return;
    }
    if (restore.value.phase == CircleBackupRestorePhase.idle) {
      restore.value = const CircleBackupRestore(
        CircleBackupRestorePhase.searching,
      );
    }
    _askedAt = now;
    final Map<String, dynamic> request = await _request(id);
    for (final String to in <String>{
      ..._restoreHelpers,
      for (final String c in restoreCandidates())
        PeerShareCodec.normalizeAddress(c),
    }) {
      await _send(to, <String, dynamic>{
        'type': CircleBackupMessages.fetch,
        'r': request,
      });
    }
  }

  Future<Map<String, dynamic>> _request(CircleBackupIdentity id) async {
    final int at = _clock();
    return <String, dynamic>{
      'a': id.account,
      'at': at,
      'cert': id.certificate.toJson(),
      'sig': b64(await id.deviceKey.sign(_requestBytes(id.account, at))),
    };
  }

  Future<void> _onManifest(String from, Map<String, dynamic> p) async {
    final CircleBackupIdentity? id = identity();
    final CircleBackupManifest? m = CircleBackupManifest.parse(p['m']);
    if (!restoring || id == null || m == null || m.account != id.account) {
      return;
    }
    final CircleBackupManifest? had = _target;
    if (had != null && had.createdAt >= m.createdAt) {
      return;
    }
    if (!await m.verify(account: id.account)) {
      return;
    }
    _target = m;
    _targetFrom = from;
    _got.removeWhere((String k, Uint8List _) => !m.chunks.containsKey(k));
    restore.value = CircleBackupRestore(
      CircleBackupRestorePhase.downloading,
      done: _got.length,
      total: m.chunks.length,
    );
    await _requestChunks(from, m);
  }

  Future<void> _requestChunks(String from, CircleBackupManifest m) async {
    final CircleBackupIdentity? id = identity();
    if (id == null) {
      return;
    }
    final List<String> missing = <String>[
      for (final String c in m.chunks.keys)
        if (!_got.containsKey(c)) c,
    ];
    if (missing.isEmpty) {
      await _finishRestore();
      return;
    }
    await _send(from, <String, dynamic>{
      'type': CircleBackupMessages.get,
      'r': await _request(id),
      'ids': missing,
    });
  }

  Future<void> _onPart(String from, Map<String, dynamic> p) async {
    final CircleBackupManifest? m = _target;
    final Object? chunkId = p['id'];
    final Uint8List? bytes = unb64(p['c']);
    if (m == null ||
        chunkId is! String ||
        bytes == null ||
        p['a'] != m.account ||
        m.chunks[chunkId] != bytes.length ||
        circleBackupChunkId(bytes) != chunkId) {
      return;
    }
    _got[chunkId] = bytes;
    restore.value = CircleBackupRestore(
      CircleBackupRestorePhase.downloading,
      done: _got.length,
      total: m.chunks.length,
    );
    if (_got.length == m.chunks.length) {
      await _finishRestore();
    }
  }

  Future<void> _finishRestore() async {
    final CircleBackupManifest? m = _target;
    final CircleBackupIdentity? id = identity();
    if (m == null || id == null) {
      return;
    }
    final CircleBackupOpened opened = await openCircleBackup(
      manifest: m,
      chunks: _got,
      account: id.account,
      selfKey: id.selfKey,
    );
    final CircleBackupContent? content = opened.content;
    if (content == null) {
      logZenWarning('Kopia u kręgu nie otwiera się: ${opened.error}');
      // Another holder's copy may open: start looking again.
      _target = null;
      _targetFrom = null;
      _got.clear();
      return;
    }
    restore.value = const CircleBackupRestore(
      CircleBackupRestorePhase.applying,
    );
    await data.restore(content, (int done, int total) {
      restore.value = CircleBackupRestore(
        CircleBackupRestorePhase.applying,
        done: done,
        total: total,
      );
    });
    await _endRestore(CircleBackupRestorePhase.done);
  }

  Future<void> _endRestore(CircleBackupRestorePhase phase) async {
    _restoreSince = null;
    _restoreHelpers.clear();
    _target = null;
    _targetFrom = null;
    _got.clear();
    await disk.delete(_restoreKey);
    restore.value = CircleBackupRestore(phase);
  }

  /// When the copy was last asked for after a recovery (diagnostics).
  int get lastAskedAt => _askedAt;

  // ---- storage ----

  Future<Object?> _read(String key) async {
    final Uint8List? raw = await disk.read(key);
    if (raw == null) {
      return null;
    }
    try {
      return jsonDecode(utf8.decode(raw));
    } on FormatException {
      return null;
    }
  }

  Future<void> _load() async {
    final Object? s = await _read(_statusKey);
    if (s is Map) {
      status.value = CircleBackupStatus(
        lastAt: s['at'] is int ? s['at'] as int : null,
        bytes: s['size'] is int ? s['size'] as int : 0,
        holders: s['h'] is int ? s['h'] as int : 0,
        includeChats: s['chats'] != false,
        droppedMessages: s['dropped'] is int ? s['dropped'] as int : 0,
      );
    }
    final Object? r = await _read(_restoreKey);
    if (r is Map && r['since'] is int) {
      _restoreSince = r['since'] as int;
      final Object? helpers = r['helpers'];
      if (helpers is List) {
        _restoreHelpers.addAll(helpers.whereType<String>().take(64));
      }
    }
  }

  Future<void> _saveStatus() => disk.write(
    _statusKey,
    Uint8List.fromList(
      utf8.encode(
        jsonEncode(<String, dynamic>{
          'at': ?status.value.lastAt,
          'size': status.value.bytes,
          'h': status.value.holders,
          'chats': status.value.includeChats,
          'dropped': status.value.droppedMessages,
        }),
      ),
    ),
  );
}
