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

/// Thrown by [CircleBackupData.collect] when a part of the copy cannot be
/// read now (Zen is locked, its store does not open): no copy is made
/// then, so the holders keep the last whole one instead of one without
/// that part. Tried again at the next tick.
final class CircleBackupNotNow implements Exception {
  const CircleBackupNotNow(this.why);

  final String why;

  @override
  String toString() => 'CircleBackupNotNow($why)';
}

/// What the copy is made of and where it goes back to (the app's stores).
abstract interface class CircleBackupData {
  /// The account's data now; conversation text only when [chats]. Throws
  /// [CircleBackupNotNow] when a part cannot be read now.
  Future<CircleBackupContent> collect({required bool chats});

  /// Puts [content] back; [progress] counts what is done.
  Future<void> restore(
    CircleBackupContent content,
    void Function(int done, int total) progress,
  );
}

/// The last copy friends confirmed, as the settings show it.
@immutable
final class CircleBackupStatus {
  const CircleBackupStatus({
    this.lastAt,
    this.bytes = 0,
    this.holders = 0,
    this.includeChats = true,
    this.droppedMessages = 0,
    this.candidates = -1,
    this.blocked = 0,
  });

  /// How many holders have refused every new copy as older than the one
  /// they keep for more than [CircleBackupService.blockedAfter]: a copy
  /// dated ahead (a device whose clock ran ahead) stands in the way there.
  final int blocked;

  /// How many people the copy is offered to now (the circle and the chosen
  /// friends); 0: nobody can keep it (no friend yet); -1: not looked yet.
  final int candidates;

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
    int? candidates,
    int? blocked,
  }) => CircleBackupStatus(
    lastAt: lastAt ?? this.lastAt,
    bytes: bytes ?? this.bytes,
    holders: holders ?? this.holders,
    includeChats: includeChats ?? this.includeChats,
    droppedMessages: droppedMessages ?? this.droppedMessages,
    candidates: candidates ?? this.candidates,
    blocked: blocked ?? this.blocked,
  );
}

/// Where taking the copy back after a recovery is.
enum CircleBackupRestorePhase {
  idle,
  searching,
  downloading,
  applying,
  done,

  /// Nothing found within [CircleBackupService.restoreWindow]: still
  /// looked for, once in [CircleBackupService.lateAskInterval].
  failed,

  /// The newest copy found was made by a newer Zen: update the app; it is
  /// still looked for (and taken after the update).
  newer,
}

@immutable
final class CircleBackupRestore {
  const CircleBackupRestore(
    this.phase, {
    this.done = 0,
    this.total = 0,
    this.freshCopy = false,
  });

  static const CircleBackupRestore idle = CircleBackupRestore(
    CircleBackupRestorePhase.idle,
  );

  final CircleBackupRestorePhase phase;
  final int done;
  final int total;

  /// The person said this device may make its own copy while the old one
  /// is still looked for ([CircleBackupService.allowFreshCopy]).
  final bool freshCopy;
}

/// Makes this account's copy with friends, keeps the copies of others,
/// and takes the copy back after a recovery.
///
/// Who keeps it: the recovery circle's helpers ([holders]), if there is a
/// circle, and chosen friends ([friendHolders]: those that serve as this
/// person's mailboxes and the close friends, others only to reach two), up
/// to [kMaxCopyHolders] in all. No circle is needed: the copy is sealed
/// under the account's self key, so any way back to the account (paper,
/// key file, another device, the circle) opens it. A friend on a build
/// that keeps only circles' copies refuses (`cbk_no notInCircle`) and is
/// passed over for [refusedRest]; the next friend is asked instead.
///
/// The copy is made at most once a day ([interval]), and sooner after an
/// important change ([changed]: a friend, a group, a password, a note) but
/// not more often than [changeInterval]. Only the chunks a holder lacks
/// travel.
///
/// After a recovery the copy is asked for from the helpers the recovery
/// named and from friends ([restoreCandidates]); the manifests that come
/// within [gather] of the first are compared and the newest is taken, and
/// a download that stalls moves to another holder of the same copy (or
/// starts looking again).
final class CircleBackupService {
  CircleBackupService({
    required this.transport,
    required this.disk,
    required this.data,
    required this.identity,
    required this.holders,
    required bool Function(String account) isInCircle,
    required this.restoreCandidates,
    Iterable<String> Function()? friendHolders,
    bool Function(String account)? isFriend,
    bool Function(String account, String device)? isRevoked,
    int Function()? clock,
    this.interval = const Duration(days: 1),
    this.changeInterval = const Duration(hours: 1),
    this.tickInterval = const Duration(minutes: 15),
    this.maxBytes = kCircleBackupMaxBytes,
    this.gather = const Duration(seconds: 30),
    this.refusedRest = const Duration(days: 7),
  }) : _clock = clock ?? (() => DateTime.now().millisecondsSinceEpoch),
       friendHolders = friendHolders ?? _none,
       isRevoked = isRevoked ?? _notRevoked,
       holder = CircleBackupHolder(
         disk: disk,
         isInCircle: isInCircle,
         isFriend: isFriend,
         isRevoked: isRevoked,
         clock: clock,
       );

  static Iterable<String> _none() => const <String>[];
  static bool _notRevoked(String _, String _) => false;

  /// The most people that keep the copy (the circle's size at most).
  static const int kMaxCopyHolders = 6;

  /// Friends asked to keep it, best first (the app: mailbox friends, close
  /// friends, then others); the circle's helpers come before them.
  final Iterable<String> Function() friendHolders;

  /// Whether a device of an account was cut off by the account (its
  /// requests for the copy are refused then).
  final bool Function(String account, String device) isRevoked;

  /// How long manifests are gathered after a recovery before the newest
  /// complete copy is taken.
  final Duration gather;

  /// How long a friend that refused the copy is passed over.
  final Duration refusedRest;

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

  /// How long after a recovery the copy is looked for at every tick; after
  /// that once in [lateAskInterval], until it comes. Nothing ends the
  /// search but the copy taken back: a device that gave up would make its
  /// own nearly empty copy, and the friends keep only the newest.
  static const Duration restoreWindow = Duration(days: 30);
  static const Duration lateAskInterval = Duration(days: 1);

  /// How long a holder may refuse every new copy as older than its own
  /// before the person is told ([CircleBackupStatus.blocked]).
  static const Duration blockedAfter = Duration(days: 3);

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

  /// Friend address → until when it is passed over (it refused).
  final Map<String, int> _refused = <String, int>{};

  /// Holder address → since when it refuses this account's copies as older
  /// than its own (cleared by its next confirmation).
  final Map<String, int> _staleSince = <String, int>{};

  // After a recovery.
  int? _restoreSince;

  /// The person allowed this device's own copy while the old one is still
  /// looked for ([allowFreshCopy]).
  bool _freshAllowed = false;

  /// The newest copy seen that this build cannot open (made by a newer
  /// Zen): nothing older is taken instead while it is there.
  int _newerAt = 0;
  final Set<String> _restoreHelpers = <String>{};
  CircleBackupManifest? _target;
  String? _targetFrom;
  final Map<String, Uint8List> _got = <String, Uint8List>{};
  int _askedAt = 0;

  /// Holder address → the newest verified manifest it offered.
  final Map<String, CircleBackupManifest> _offered =
      <String, CircleBackupManifest>{};

  /// Whom the copy was asked from (their answers are waited for).
  final Set<String> _askedFrom = <String>{};

  /// When the first manifest came (0: none yet).
  int _firstManifestAt = 0;

  /// When the last chunk came (a download that stalls moves on).
  int _lastPartAt = 0;
  Timer? _gatherTimer;

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
    _gatherTimer?.cancel();
    await _frames?.cancel();
  }

  /// Lets go of [status] and [restore] (after [stop], for good).
  void dispose() {
    status.dispose();
    restore.dispose();
  }

  /// Waits for the work queued so far (tests).
  Future<void> get idle => _queue;

  void _enqueue(Future<void> Function() work) {
    _queue = _queue.then((_) async {
      try {
        await work();
      } on Object catch (error, stackTrace) {
        logZenError('Circle backup', error, stackTrace);
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

  /// Whether the person allowed this device's own copy while the old one
  /// is still looked for.
  bool get freshCopyAllowed => _freshAllowed;

  /// The person's word, while the copy is still looked for after a
  /// recovery: this device makes its own copy now, and the friends' copy
  /// is replaced by it (each keeps the whole one before it for
  /// [kCircleBackupPreviousKept] when the new one is much smaller). The old
  /// copy is still looked for, its own copies passed over, and taken in
  /// when it comes.
  Future<void> allowFreshCopy() async {
    final int? since = _restoreSince;
    if (since == null || _freshAllowed) {
      return;
    }
    _freshAllowed = true;
    await _saveRestore();
    final CircleBackupRestore r = restore.value;
    restore.value = CircleBackupRestore(
      r.phase,
      done: r.done,
      total: r.total,
      freshCopy: true,
    );
    _enqueue(() => refresh(force: true));
  }

  Future<void> _saveRestore() => disk.write(
    _restoreKey,
    Uint8List.fromList(
      utf8.encode(
        jsonEncode(<String, dynamic>{
          'since': _restoreSince,
          'helpers': _restoreHelpers.toList(),
          if (_freshAllowed) 'fresh': true,
        }),
      ),
    ),
  );

  /// The periodic work: the kept copies of those who left, the restore
  /// after a recovery, this account's own copy.
  Future<void> tick() async {
    await holder.prune();
    if (restoring) {
      await _askForCopy();
      if (!_freshAllowed) {
        return;
      }
    }
    await refresh();
  }

  /// Who is offered the copy now: the circle's helpers, then the chosen
  /// friends not passed over, up to [kMaxCopyHolders].
  List<String> targets() {
    final int now = _clock();
    final Set<String> out = <String>{
      for (final String h in holders()) PeerShareCodec.normalizeAddress(h),
    };
    for (final String f in friendHolders()) {
      if (out.length >= kMaxCopyHolders) {
        break;
      }
      final String a = PeerShareCodec.normalizeAddress(f);
      if ((_refused[a] ?? 0) <= now) {
        out.add(a);
      }
    }
    return out.toList();
  }

  /// Makes and offers a new copy when one is due ([force]: now).
  Future<void> refresh({bool force = false}) async {
    final CircleBackupIdentity? id = identity();
    final List<String> circle = targets();
    if (status.value.candidates != circle.length) {
      status.value = status.value.copyWith(candidates: circle.length);
    }
    final int staleBefore = _staleSince.length;
    _staleSince.removeWhere((String h, int _) => !circle.contains(h));
    if (_staleSince.length != staleBefore ||
        status.value.blocked != _blockedNow()) {
      await _updateBlocked();
    }
    if (id == null || circle.isEmpty || (restoring && !_freshAllowed)) {
      // While the copy is looked for after a recovery, none is made unless
      // the person said so: an emptier one would replace the friends'
      // whole copy.
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
    final CircleBackupContent content;
    try {
      content = await data.collect(chats: status.value.includeChats);
    } on CircleBackupNotNow {
      return;
    }
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
    _offeredTo.clear();
    status.value = status.value.copyWith(
      droppedMessages: build.droppedMessages,
    );
    for (final String h in circle) {
      _offeredTo.add(h);
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
      logZenWarning('Circle backup: sending failed: $error');
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
        await _onNo(from, p);
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
    final DeviceCertificate? signer = DeviceCertificate.fromJson(
      m.json['cert'],
    );
    if (signer == null || isRevoked(signer.account, signer.device)) {
      // A device the account cut off makes no copy of it any more.
      await _send(from, <String, dynamic>{
        'type': CircleBackupMessages.no,
        'a': m.account,
        'why': CircleBackupOfferResult.badSignature.name,
      });
      return;
    }
    final CircleBackupOfferResult result = await holder.offer(m);
    if (result != CircleBackupOfferResult.accepted) {
      await _send(from, <String, dynamic>{
        'type': CircleBackupMessages.no,
        'a': m.account,
        'why': result.name,
        if (result == CircleBackupOfferResult.stale)
          'at': ?holder.manifestOf(m.account)?.createdAt,
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
    if (account == null) {
      return;
    }
    // The kept copy, then the one kept before it (a much bigger one that a
    // new phone's own copy replaced): a build before 1.17.0 takes only the
    // newest of what one holder sends.
    for (final CircleBackupManifest m in <CircleBackupManifest>[
      ?holder.manifestOf(account),
      ?holder.previousOf(account),
    ]) {
      await _send(from, <String, dynamic>{
        'type': CircleBackupMessages.manifest,
        'm': m.json,
      });
    }
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
        isRevoked(cert.account, cert.device) ||
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

  /// A friend refused the copy: an older build that keeps only circles'
  /// copies, no room there, or not a friend there. Passed over for
  /// [refusedRest] (not a helper of the circle: its refusal is only
  /// logged); the next friend is offered the copy at once.
  ///
  /// A copy refused as older than the holder's own is not passed over (a
  /// newer one from another device of the account is kept there), but a
  /// holder that keeps refusing for [blockedAfter] is counted in
  /// [CircleBackupStatus.blocked]: a copy dated ahead is in the way there.
  Future<void> _onNo(String from, Map<String, dynamic> p) async {
    final Object? why = p['why'];
    logZenWarning('Circle backup refused: $why');
    final CircleBackupBuild? build = _build;
    if (build == null || p['a'] != build.manifest.account) {
      return;
    }
    if (why == CircleBackupOfferResult.stale.name) {
      final Object? at = p['at'];
      final int now = _clock();
      // The holder's copy is dated ahead of this clock: it is in the way
      // at once, not only after a while.
      final bool ahead =
          at is int && at > now + kCircleBackupClockSlack.inMilliseconds;
      final int since = _staleSince[from] ?? now;
      _staleSince[from] = ahead && since > now - blockedAfter.inMilliseconds
          ? now - blockedAfter.inMilliseconds
          : since;
      if (status.value.blocked != _blockedNow() || since == now) {
        await _updateBlocked();
      }
      return;
    }
    final bool helper = holders()
        .map(PeerShareCodec.normalizeAddress)
        .contains(from);
    if (helper) {
      return;
    }
    _refused[from] = _clock() + refusedRest.inMilliseconds;
    _confirmed.remove(from);
    for (final String h in targets()) {
      if (_confirmed[h] != build.manifest.createdAt &&
          !_offeredTo.contains(h)) {
        _offeredTo.add(h);
        await _offer(h, build.manifest);
      }
    }
  }

  /// Holders offered the current build since it was made.
  final Set<String> _offeredTo = <String>{};

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
    _staleSince.remove(from);
    status.value = status.value.copyWith(
      lastAt: at,
      bytes: build.manifest.totalBytes,
      holders: _confirmed.values.where((int x) => x == at).length,
      blocked: _blockedNow(),
    );
    await _saveStatus();
  }

  /// Holders that have refused every copy as older for [blockedAfter].
  int _blockedNow() {
    final int now = _clock();
    return _staleSince.values
        .where((int since) => now - since >= blockedAfter.inMilliseconds)
        .length;
  }

  Future<void> _updateBlocked() async {
    status.value = status.value.copyWith(blocked: _blockedNow());
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
    final CircleBackupManifest? target = _target;
    final String? from = _targetFrom;
    if (target != null && from != null) {
      if (now - _lastPartAt >= tickInterval.inMilliseconds) {
        // Nothing came for a while: another holder of the same copy, or
        // the newest another one offered; none: look again.
        final String? other = _otherHolderOf(target, from);
        if (other != null) {
          _targetFrom = other;
          _lastPartAt = now;
          await _requestChunks(other, target);
          return;
        }
        if (now - _lastPartAt >= 4 * tickInterval.inMilliseconds) {
          _offered.remove(from);
          _target = null;
          _targetFrom = null;
          _pickNewest();
          if (_target != null) {
            await _requestChunks(_targetFrom!, _target!);
            return;
          }
        } else {
          await _requestChunks(from, target);
          return;
        }
      } else {
        // Asked again for what has not come (every tick).
        await _requestChunks(from, target);
        return;
      }
    }
    if (now - since > restoreWindow.inMilliseconds) {
      // Not found in the window (the friends who keep it may be away for
      // long): said so, and still asked for, less often. Never given up.
      if (restore.value.phase != CircleBackupRestorePhase.newer &&
          restore.value.phase != CircleBackupRestorePhase.failed) {
        _setPhase(CircleBackupRestorePhase.failed);
      }
      if (now - _askedAt < lateAskInterval.inMilliseconds) {
        return;
      }
    } else if (restore.value.phase == CircleBackupRestorePhase.idle) {
      _setPhase(CircleBackupRestorePhase.searching);
    }
    _askedAt = now;
    final Map<String, dynamic> request = await _request(id);
    for (final String to in <String>{
      ..._restoreHelpers,
      for (final String c in restoreCandidates())
        PeerShareCodec.normalizeAddress(c),
    }) {
      _askedFrom.add(to);
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
    final CircleBackupManifest? before = _offered[from];
    if (before != null && before.createdAt >= m.createdAt) {
      return;
    }
    if (!await m.verify(account: id.account)) {
      return;
    }
    final DeviceCertificate? signer = DeviceCertificate.fromJson(
      m.json['cert'],
    );
    if (signer == null ||
        isRevoked(signer.account, signer.device) ||
        signer.device == id.certificate.device) {
      // This device's own copy (made after the person allowed it) holds
      // nothing of what is looked for.
      return;
    }
    if (m.version > kCircleBackupVersion) {
      // Made by a newer Zen: this build cannot open it. Said so, instead
      // of a download that ends in "damaged"; still looked for, so the
      // update takes it, and nothing older is taken meanwhile.
      if (m.createdAt > _newerAt) {
        _newerAt = m.createdAt;
      }
      final CircleBackupManifest? had = _target;
      if (had == null || had.createdAt < m.createdAt) {
        _setPhase(CircleBackupRestorePhase.newer);
      }
      return;
    }
    _offered[from] = m;
    if (_firstManifestAt == 0) {
      _firstManifestAt = _clock();
      // The others' answers are waited for: the newest copy is taken, not
      // the first to come whole.
      _gatherTimer?.cancel();
      _gatherTimer = Timer(gather, () => _enqueue(_afterGather));
    }
    final CircleBackupManifest? had = _target;
    if (had != null && had.createdAt >= m.createdAt) {
      // Perhaps the last answer waited for: the copy may be taken now.
      await _afterGather();
      return;
    }
    _target = m;
    _targetFrom = from;
    _lastPartAt = _clock();
    _got.removeWhere((String k, Uint8List _) => !m.chunks.containsKey(k));
    _setPhase(
      CircleBackupRestorePhase.downloading,
      done: _got.length,
      total: m.chunks.length,
    );
    await _requestChunks(from, m);
  }

  void _setPhase(
    CircleBackupRestorePhase phase, {
    int done = 0,
    int total = 0,
  }) {
    restore.value = CircleBackupRestore(
      phase,
      done: done,
      total: total,
      freshCopy: _freshAllowed,
    );
  }

  /// The gathering is over: a copy that came whole meanwhile is taken.
  Future<void> _afterGather() async {
    final CircleBackupManifest? m = _target;
    if (restoring &&
        m != null &&
        m.chunks.keys.every((String c) => _got.containsKey(c))) {
      await _finishRestore();
    }
  }

  /// Another holder that offered [m] itself (the same copy), not [from].
  String? _otherHolderOf(CircleBackupManifest m, String from) {
    for (final MapEntry<String, CircleBackupManifest> e in _offered.entries) {
      if (e.key != from && e.value.id == m.id) {
        return e.key;
      }
    }
    return null;
  }

  /// Takes the newest copy offered as the one to download.
  void _pickNewest() {
    MapEntry<String, CircleBackupManifest>? best;
    for (final MapEntry<String, CircleBackupManifest> e in _offered.entries) {
      if (best == null || e.value.createdAt > best.value.createdAt) {
        best = e;
      }
    }
    if (best != null) {
      _target = best.value;
      _targetFrom = best.key;
      _lastPartAt = _clock();
      _got.removeWhere(
        (String k, Uint8List _) => !best!.value.chunks.containsKey(k),
      );
    }
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
    _lastPartAt = _clock();
    _setPhase(
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
    if (!_askedFrom.every(_offered.containsKey) &&
        _clock() - _firstManifestAt < gather.inMilliseconds) {
      // Whole, but holders asked may still answer with a newer copy: taken
      // when they all did or the gathering is over ([_afterGather]).
      return;
    }
    if (_newerAt > m.createdAt) {
      // A newer copy is there that only an update opens: this older one
      // would end the search without it.
      _setPhase(CircleBackupRestorePhase.newer);
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
      logZenWarning('Circle backup does not open: ${opened.error}');
      // Another holder's copy may open: the newest of the others, or look
      // again.
      _offered.removeWhere((String _, CircleBackupManifest x) => x.id == m.id);
      _target = null;
      _targetFrom = null;
      _got.clear();
      _pickNewest();
      return;
    }
    _setPhase(CircleBackupRestorePhase.applying);
    await data.restore(content, (int done, int total) {
      _setPhase(CircleBackupRestorePhase.applying, done: done, total: total);
    });
    await _endRestore(CircleBackupRestorePhase.done);
  }

  /// The copy was taken back: the search ends (the only way it ends).
  Future<void> _endRestore(CircleBackupRestorePhase phase) async {
    _restoreSince = null;
    _freshAllowed = false;
    _newerAt = 0;
    _restoreHelpers.clear();
    _target = null;
    _targetFrom = null;
    _got.clear();
    _offered.clear();
    _askedFrom.clear();
    _firstManifestAt = 0;
    _gatherTimer?.cancel();
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
      final Object? stale = s['stale'];
      if (stale is Map) {
        for (final MapEntry<Object?, Object?> e in stale.entries.take(64)) {
          if (e.key is String && e.value is int) {
            _staleSince[e.key! as String] = e.value! as int;
          }
        }
      }
      status.value = status.value.copyWith(blocked: _blockedNow());
    }
    final Object? r = await _read(_restoreKey);
    if (r is Map && r['since'] is int) {
      _restoreSince = r['since'] as int;
      _freshAllowed = r['fresh'] == true;
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
          if (_staleSince.isNotEmpty) 'stale': _staleSince,
        }),
      ),
    ),
  );
}
