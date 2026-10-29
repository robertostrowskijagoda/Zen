import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:zen/src/core/ledger/ledger_codec.dart';
import 'package:zen/src/core/ledger/ledger_identity.dart';
import 'package:zen/src/core/logging/zen_log.dart';
import 'package:zen/src/features/pebbles/pebble_card.dart';
import 'package:zen/src/features/pebbles/pebble_store.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';

/// Frames of the pebbles, over the signal transport (direct, small; an
/// older Zen ignores frame types it does not know):
///
/// * `pbl_get {id, a, h, o?}`: "send me pebble id (author a)"; `h` 1 lets a
///   friend pass the question on to the author, the keepers it knows and
///   its own friends, who then answer the asker `o` directly;
/// * `pbl_design {c, d, k?}`: the card, the full design and the newest
///   keeper list known;
/// * `pbl_keep_ask {c, n}`: author → friend, "keep my pebble" (n bytes);
/// * `pbl_keep_yes {id}`, `pbl_keep_no {id}`: the friend's answer;
/// * `pbl_keep_quit {id}`: a keeper gives the role up;
/// * `pbl_keepers {k}`: author → keepers, a new signed keeper list (or the
///   pebble retired);
/// * `pbl_found {n}`: finder → author, a signed "znaleziono" note.
abstract final class PebbleFrames {
  static const String get = 'pbl_get';
  static const String design = 'pbl_design';
  static const String keepAsk = 'pbl_keep_ask';
  static const String keepYes = 'pbl_keep_yes';
  static const String keepNo = 'pbl_keep_no';
  static const String keepQuit = 'pbl_keep_quit';
  static const String keepers = 'pbl_keepers';
  static const String found = 'pbl_found';

  static const Set<String> all = <String>{
    get,
    design,
    keepAsk,
    keepYes,
    keepNo,
    keepQuit,
    keepers,
    found,
  };
}

/// A friend who could keep a pebble, as this device has seen them.
@immutable
final class PebbleKeeperCandidate {
  const PebbleKeeperCandidate({
    required this.address,
    this.desktop = false,
    this.quality = 0,
  });

  final String address;

  /// A computer (stays online).
  final bool desktop;

  /// 0-1: how reliably the device answers (the mailboxes' measure).
  final double quality;
}

/// What the pebbles need to know of the people around this device.
abstract interface class PebblePeers {
  /// Accepted friends' addresses.
  List<String> friends();

  bool isFriend(String address);

  /// Blocked here: nothing goes to them, nothing from them is taken.
  bool isBlocked(String address);

  /// The account of the device at [address], when known.
  String? accountOf(String address);

  /// Addresses this device can reach [account] at (a friend's devices),
  /// best first; empty when it does not know the account.
  List<String> addressesOfAccount(String account);

  /// Friends who could keep a pebble.
  List<PebbleKeeperCandidate> keeperCandidates();
}

/// Keeps pebbles moving between devices: publishing (drawing keepers,
/// asking them, replacing those who say no or leave, signing the keeper
/// list), serving copies (the author, keepers, collectors unless they opted
/// out), finding the full design of a pebble collected from its card
/// (the author, then its keepers, then friends and friends of friends,
/// a few at a time, again on every beat), and the "znaleziono" notes.
///
/// Nothing is taken from or sent to someone blocked; every sender has a
/// budget of frames per minute; a design is at most
/// [kPebbleDesignMaxBytes] and is only taken for a pebble this device wants
/// (its card must match it).
final class PebbleHosting {
  PebbleHosting({
    required this.transport,
    required this.store,
    required this.peers,
    required this.accountKey,
    required this.serveCollected,
    int Function()? clock,
    this.keeperTarget = 6,
    this.parallel = 3,
    this.askAgainAfter = const Duration(minutes: 30),
    this.askTimeout = const Duration(days: 2),
    this.batchWait = const Duration(seconds: 20),
    Random? random,
  }) : _clock = clock ?? (() => DateTime.now().millisecondsSinceEpoch),
       _random = random ?? Random.secure();

  final SignalTransport transport;
  final PebbleStore store;
  final PebblePeers peers;

  /// The account key while it is at hand (signing keeper lists and
  /// "znaleziono" notes); `null` while locked.
  final LedgerKeyPair? Function() accountKey;

  /// Whether this person serves the pebbles they collected (on unless they
  /// opted out in the settings).
  final bool Function() serveCollected;
  final int Function() _clock;
  final Random _random;

  /// How many keepers a pebble should have.
  final int keeperTarget;

  /// How many devices are asked for a design at once.
  final int parallel;

  /// A keeper who has not answered is asked again this often.
  final Duration askAgainAfter;

  /// A keeper who never answers within this is replaced.
  final Duration askTimeout;

  /// How long the asked devices get before the next ones are asked.
  final Duration batchWait;

  /// A friend asked to keep a pebble (the app posts a notification).
  void Function(PebbleKeepRequest request)? onKeepRequest;

  /// A pebble's full design arrived.
  void Function(PebbleId id)? onDesign;

  StreamSubscription<SignalTransportFrame>? _frames;
  Future<void> _queue = Future<void>.value();

  final Map<PebbleId, _Fetch> _fetches = <PebbleId, _Fetch>{};
  final Map<PebbleId, int> _askedAt = <PebbleId, int>{};
  final Set<PebbleId> _listDirty = <PebbleId>{};
  final Map<String, int> _forwarded = <String, int>{};
  final _Budget _perSender = _Budget(30);
  final _Budget _served = _Budget(60);
  final _Budget _forwards = _Budget(10);

  /// Backoff between full rounds of asking for a design.
  static const List<Duration> _backoff = <Duration>[
    Duration(minutes: 1),
    Duration(minutes: 5),
    Duration(minutes: 15),
    Duration(hours: 1),
    Duration(hours: 3),
    Duration(hours: 6),
  ];

  int get _now => _clock();

  Future<void> start() async {
    await store.load();
    _frames ??= transport.frames.listen(
      (SignalTransportFrame f) => _enqueue(() => _onFrame(f)),
    );
  }

  Future<void> stop() async {
    await _frames?.cancel();
    _frames = null;
  }

  /// Waits for the work queued so far (tests).
  Future<void> get idle => _queue;

  void _enqueue(Future<void> Function() work) {
    _queue = _queue.then((_) async {
      try {
        await work();
      } on Object catch (error, stackTrace) {
        logZenError('Pebbles', error, stackTrace);
      }
    });
  }

  Future<T> _run<T>(Future<T> Function() work) {
    final Completer<T> done = Completer<T>();
    _enqueue(() async {
      try {
        done.complete(await work());
      } on Object catch (error, stackTrace) {
        done.completeError(error, stackTrace);
      }
    });
    return done.future;
  }

  Future<void> _send(String to, Map<String, dynamic> payload) async {
    if (peers.isBlocked(to)) {
      return;
    }
    try {
      await transport.send(remoteAddress: to, payload: payload);
    } on Object catch (error) {
      logZenWarning('Pebbles: sending failed: $error');
    }
  }

  // ---- the beat ----

  /// The periodic work (the app's wake beat): designs still missing are
  /// asked for, keepers who did not answer are asked again or replaced,
  /// keeper lists waiting for the account key are signed, "znaleziono"
  /// notes go out.
  Future<void> tick() => _run(_tick);

  Future<void> _tick() async {
    await store.load();
    for (final PebbleEntry e in store.created) {
      if (e.madeHere) {
        await _keepUp(e);
      }
    }
    for (final PebbleEntry e in store.lackingDesign.take(20)) {
      await _fetchStep(e);
    }
    for (final PebbleEntry e in store.collected) {
      if (!e.foundSent && !e.created) {
        await _sendFound(e);
      }
    }
  }

  // ---- as the author ----

  /// Publishes a pebble this account made: saved, then keepers are drawn
  /// and asked.
  Future<PebbleEntry> publish(PebbleCard card, Uint8List design) =>
      _run(() async {
        final PebbleEntry e = await store.addCreated(card, design);
        await _draw(e.id);
        return store.entry(e.id) ?? e;
      });

  /// Asks new keepers in place of those who have not agreed (the author's
  /// "Losuj ponownie").
  Future<void> redraw(PebbleId id) => _run(() async {
    for (final PebbleKeeperStatus k in store.keepersOf(id)) {
      if (k.state == PebbleKeeperState.asked) {
        await store.setKeeper(id, k.address, PebbleKeeperState.silent);
      }
    }
    await _draw(id);
  });

  /// The author takes the pebble back: keepers stop offering it, collectors
  /// keep their copy.
  Future<bool> retire(PebbleId id) => _run(() async {
    final PebbleEntry? e = store.entry(id);
    final LedgerKeyPair? key = accountKey();
    if (e == null || !e.madeHere || key == null) {
      return false;
    }
    final PebbleKeeperList list = await PebbleKeeperList.sign(
      key: key,
      id: id,
      version: _now,
      keepers: const <String>[],
      retired: true,
    );
    await store.putKeeperList(list);
    for (final PebbleKeeperStatus k in store.keepersOf(id)) {
      if (k.state == PebbleKeeperState.accepted) {
        await _send(k.address, <String, dynamic>{
          'type': PebbleFrames.keepers,
          'k': list.toJson(),
        });
      }
    }
    return true;
  });

  /// Keepers who have not answered are asked again, those who never did
  /// are replaced, a blocked keeper is dropped; a keeper list that waited
  /// for the key is signed.
  Future<void> _keepUp(PebbleEntry e) async {
    if (e.retired) {
      return;
    }
    bool changed = false;
    for (final PebbleKeeperStatus k in store.keepersOf(e.id)) {
      if (peers.isBlocked(k.address) &&
          (k.state == PebbleKeeperState.accepted ||
              k.state == PebbleKeeperState.asked)) {
        await store.setKeeper(e.id, k.address, PebbleKeeperState.resigned);
        _listDirty.add(e.id);
        changed = true;
        continue;
      }
      if (k.state != PebbleKeeperState.asked) {
        continue;
      }
      if (_now - k.atMillis >= askTimeout.inMilliseconds) {
        await store.setKeeper(e.id, k.address, PebbleKeeperState.silent);
        changed = true;
      }
    }
    if (changed) {
      await _draw(e.id);
    } else if ((_now - (_askedAt[e.id] ?? 0)) >= askAgainAfter.inMilliseconds) {
      _askedAt[e.id] = _now;
      for (final PebbleKeeperStatus k in store.keepersOf(e.id)) {
        if (k.state == PebbleKeeperState.asked) {
          await _ask(e, k.address);
        }
      }
    }
    if (_listDirty.contains(e.id)) {
      await _publishList(e.id);
    }
  }

  /// Draws keepers until [keeperTarget] have agreed or are being asked:
  /// friends whose devices answer best, computers first, phones mixed in;
  /// nobody asked before for this pebble.
  Future<void> _draw(PebbleId id) async {
    final PebbleEntry? e = store.entry(id);
    if (e == null || !e.madeHere || e.retired) {
      return;
    }
    final List<PebbleKeeperStatus> known = store.keepersOf(id);
    final int active = known
        .where(
          (PebbleKeeperStatus k) =>
              k.state == PebbleKeeperState.accepted ||
              k.state == PebbleKeeperState.asked,
        )
        .length;
    final int need = keeperTarget - active;
    if (need <= 0) {
      return;
    }
    final Set<String> asked = <String>{
      for (final PebbleKeeperStatus k in known) k.address,
    };
    final List<PebbleKeeperCandidate> pool = <PebbleKeeperCandidate>[
      for (final PebbleKeeperCandidate c in peers.keeperCandidates())
        if (!asked.contains(PeerShareCodec.normalizeAddress(c.address)) &&
            !peers.isBlocked(c.address))
          c,
    ];
    final List<PebbleKeeperCandidate> picked = pickKeepers(
      pool,
      need,
      random: _random,
    );
    _askedAt[id] = _now;
    for (final PebbleKeeperCandidate c in picked) {
      await store.setKeeper(id, c.address, PebbleKeeperState.asked);
      await _ask(e, PeerShareCodec.normalizeAddress(c.address));
    }
  }

  Future<void> _ask(PebbleEntry e, String to) async {
    final Uint8List? design = await store.design(e.id);
    if (design == null) {
      return;
    }
    await _send(to, <String, dynamic>{
      'type': PebbleFrames.keepAsk,
      'c': e.card.text,
      'n': design.length,
    });
  }

  /// Signs and sends the keeper list (the accepted keepers) to every
  /// keeper; waits for the next beat while the account key is locked.
  Future<void> _publishList(PebbleId id) async {
    final PebbleEntry? e = store.entry(id);
    final LedgerKeyPair? key = accountKey();
    if (e == null || e.retired) {
      _listDirty.remove(id);
      return;
    }
    if (key == null) {
      _listDirty.add(id);
      return;
    }
    _listDirty.remove(id);
    final List<String> keepers = <String>[
      for (final PebbleKeeperStatus k in store.keepersOf(id))
        if (k.state == PebbleKeeperState.accepted) k.address,
    ];
    final PebbleKeeperList list = await PebbleKeeperList.sign(
      key: key,
      id: id,
      version: max(_now, (e.keepers?.version ?? 0) + 1),
      keepers: keepers,
    );
    await store.putKeeperList(list);
    for (final String k in keepers) {
      await _send(k, <String, dynamic>{
        'type': PebbleFrames.keepers,
        'k': list.toJson(),
      });
    }
  }

  Future<void> _onKeepAnswer(
    String from,
    Map<String, dynamic> p,
    String type,
  ) async {
    final PebbleId? id = PebbleId.parse(p['id']);
    final PebbleEntry? e = id == null ? null : store.entry(id);
    if (id == null || e == null || !e.created) {
      return;
    }
    final PebbleKeeperStatus? status = store.keeperStatus(id, from);
    if (status == null) {
      return;
    }
    switch (type) {
      case PebbleFrames.keepYes:
        if (status.state != PebbleKeeperState.accepted) {
          await store.setKeeper(id, from, PebbleKeeperState.accepted);
          _listDirty.add(id);
        }
        await _serve(from, e);
        await _publishList(id);
      case PebbleFrames.keepNo:
        if (status.state == PebbleKeeperState.asked ||
            status.state == PebbleKeeperState.silent) {
          await store.setKeeper(id, from, PebbleKeeperState.declined);
          await _draw(id);
        }
      case PebbleFrames.keepQuit:
        if (status.state == PebbleKeeperState.accepted) {
          await store.setKeeper(id, from, PebbleKeeperState.resigned);
          await _publishList(id);
          await _draw(id);
        }
    }
  }

  Future<void> _onFound(String from, Map<String, dynamic> p) async {
    final PebbleFoundNote? note = PebbleFoundNote.fromJson(p['n']);
    if (note == null) {
      return;
    }
    final PebbleEntry? e = store.entry(note.id);
    if (e == null || !e.created || !await note.verify()) {
      return;
    }
    await store.addFinder(note.id, note.finder);
  }

  // ---- as a keeper ----

  Future<void> _onKeepAsk(String from, Map<String, dynamic> p) async {
    if (!peers.isFriend(from)) {
      return;
    }
    final Object? c = p['c'];
    final Object? n = p['n'];
    final PebbleCard? card = c is String ? PebbleCard.fromText(c) : null;
    if (card == null ||
        n is! int ||
        n <= 0 ||
        n > kPebbleDesignMaxBytes ||
        !await card.verify()) {
      return;
    }
    // Only the author asks for their pebble.
    final String? account = peers.accountOf(from);
    if (account != null && account != card.authorAccount) {
      return;
    }
    final PebbleEntry? had = store.entry(card.id);
    if (had != null && had.kept) {
      await _send(from, <String, dynamic>{
        'type': PebbleFrames.keepYes,
        'id': card.id.text,
      });
      return;
    }
    final bool known = store.keepRequest(card.id) != null;
    final PebbleKeepRequest request = PebbleKeepRequest(
      card: card,
      from: from,
      sizeBytes: n,
      askedAtMillis: store.keepRequest(card.id)?.askedAtMillis ?? _now,
    );
    if (await store.addKeepRequest(request) && !known) {
      onKeepRequest?.call(request);
    }
  }

  /// The person agreed to keep the pebble [id]: it is kept here, the author
  /// is told (and sends the design).
  Future<bool> acceptKeep(PebbleId id) => _run(() async {
    final PebbleKeepRequest? request = store.keepRequest(id);
    if (request == null) {
      return false;
    }
    await store.removeKeepRequest(id);
    if (!await store.addKept(request.card, from: request.from)) {
      return false;
    }
    await _send(request.from, <String, dynamic>{
      'type': PebbleFrames.keepYes,
      'id': id.text,
    });
    _fetches.remove(id);
    return true;
  });

  /// The person said no.
  Future<void> declineKeep(PebbleId id) => _run(() async {
    final PebbleKeepRequest? request = store.keepRequest(id);
    if (request == null) {
      return;
    }
    await store.removeKeepRequest(id);
    await _send(request.from, <String, dynamic>{
      'type': PebbleFrames.keepNo,
      'id': id.text,
    });
  });

  /// The keeper gives the role up: the copy goes (unless collected too),
  /// the author is told and draws someone else.
  Future<void> resign(PebbleId id) => _run(() async {
    final PebbleEntry? e = store.entry(id);
    if (e == null || !e.kept) {
      return;
    }
    final List<String> to = <String>{
      ?e.keptFrom,
      ...peers.addressesOfAccount(e.card.authorAccount),
    }.toList();
    await store.drop(id, PebbleRole.kept);
    for (final String a in to) {
      await _send(a, <String, dynamic>{
        'type': PebbleFrames.keepQuit,
        'id': id.text,
      });
    }
  });

  Future<void> _onKeepers(String from, Map<String, dynamic> p) async {
    final PebbleKeeperList? list = PebbleKeeperList.fromJson(p['k']);
    final PebbleEntry? e = list == null ? null : store.entry(list.id);
    if (list == null || e == null || !await list.verifyFor(e.card)) {
      return;
    }
    await store.putKeeperList(list);
    if (list.retired && e.kept) {
      await store.drop(e.id, PebbleRole.kept);
    }
  }

  // ---- serving ----

  /// Whether this device hands [e] out: the author always, a keeper while
  /// the pebble is not retired, a collector unless they opted out.
  bool _serves(PebbleEntry e) =>
      e.hasDesign &&
      (e.created ||
          (e.kept && !e.retired) ||
          (e.collected && serveCollected()));

  Future<void> _serve(String to, PebbleEntry e) async {
    if (!_served.take('all', _now)) {
      return;
    }
    final Uint8List? design = await store.design(e.id);
    if (design == null) {
      return;
    }
    await _send(to, <String, dynamic>{
      'type': PebbleFrames.design,
      'c': e.card.text,
      'd': b64(design),
      if (e.keepers != null) 'k': e.keepers!.toJson(),
    });
  }

  Future<void> _onGet(String from, Map<String, dynamic> p) async {
    final PebbleId? id = PebbleId.parse(p['id']);
    if (id == null) {
      return;
    }
    // Passed on by a friend: the answer goes to the one who asked.
    final Object? o = p['o'];
    final String asker = o is String && o.isNotEmpty && peers.isFriend(from)
        ? PeerShareCodec.normalizeAddress(o)
        : from;
    if (peers.isBlocked(asker)) {
      return;
    }
    final PebbleEntry? e = store.entry(id);
    if (e != null && _serves(e)) {
      await _serve(asker, e);
      return;
    }
    // A friend's own question may go one step further.
    if (asker != from || p['h'] != 1 || !peers.isFriend(from)) {
      return;
    }
    final String key = '${id.text}|$from';
    final int? at = _forwarded[key];
    if (at != null && _now - at < const Duration(minutes: 2).inMilliseconds) {
      return;
    }
    if (!_forwards.take(from, _now)) {
      return;
    }
    _forwarded[key] = _now;
    if (_forwarded.length > 2000) {
      _forwarded.remove(_forwarded.keys.first);
    }
    final Object? a = p['a'];
    final List<String> targets = <String>{
      if (a is String) ...peers.addressesOfAccount(a),
      ...?e?.keepers?.keepers,
      ...peers.friends().map(PeerShareCodec.normalizeAddress),
    }.where((String t) => t != from && !peers.isBlocked(t)).take(8).toList();
    for (final String t in targets) {
      await _send(t, <String, dynamic>{
        'type': PebbleFrames.get,
        'id': id.text,
        if (a is String) 'a': a,
        'h': 0,
        'o': from,
      });
    }
  }

  // ---- finding a design ----

  /// Starts looking for the full design of [id] now (a pebble just
  /// collected, or kept).
  Future<void> want(PebbleId id) => _run(() async {
    _fetches.remove(id);
    final PebbleEntry? e = store.entry(id);
    if (e != null && !e.hasDesign) {
      await _fetchStep(e);
    }
  });

  /// Whom to ask for [e]'s design, in order: the author's devices, the
  /// author's device that asked this one to keep it, the keepers in the
  /// newest list, then friends (who may pass the question on).
  List<(String, int)> _targetsFor(PebbleEntry e) {
    final Set<String> seen = <String>{};
    final List<(String, int)> out = <(String, int)>[];
    void add(String address, int hops) {
      final String a = PeerShareCodec.normalizeAddress(address);
      if (a.isNotEmpty && !peers.isBlocked(a) && seen.add(a)) {
        out.add((a, hops));
      }
    }

    for (final String a in peers.addressesOfAccount(e.card.authorAccount)) {
      add(a, 0);
    }
    final String? from = e.keptFrom;
    if (from != null) {
      add(from, 0);
    }
    for (final String k in e.keepers?.keepers ?? const <String>[]) {
      add(k, 0);
    }
    for (final String f in peers.friends()) {
      add(f, 1);
    }
    return out;
  }

  Future<void> _fetchStep(PebbleEntry e) async {
    final _Fetch f = _fetches[e.id] ??= _Fetch();
    if (_now < f.nextAt) {
      return;
    }
    final List<(String, int)> targets = _targetsFor(e);
    if (targets.isEmpty) {
      f.nextAt = _now + _backoff.first.inMilliseconds;
      return;
    }
    if (f.cursor >= targets.length) {
      f.cursor = 0;
    }
    final int end = min(targets.length, f.cursor + parallel);
    for (final (String to, int hops) in targets.sublist(f.cursor, end)) {
      await _send(to, <String, dynamic>{
        'type': PebbleFrames.get,
        'id': e.id.text,
        'a': e.card.authorAccount,
        'h': hops,
      });
    }
    f.cursor = end;
    if (f.cursor >= targets.length) {
      f.cursor = 0;
      f.nextAt =
          _now + _backoff[min(f.round, _backoff.length - 1)].inMilliseconds;
      f.round += 1;
    } else {
      f.nextAt = _now + batchWait.inMilliseconds;
    }
  }

  Future<void> _onDesign(String from, Map<String, dynamic> p) async {
    final Object? c = p['c'];
    final Object? d = p['d'];
    if (c is! String || d is! String || d.length > kPebbleDesignMaxBytes * 2) {
      return;
    }
    final PebbleCard? card = PebbleCard.fromText(c);
    final PebbleEntry? e = card == null ? null : store.entry(card.id);
    // Only for a pebble this device wants: nobody fills its store.
    if (card == null || e == null || e.hasDesign || e.card != card) {
      return;
    }
    final Uint8List? design = unb64(d);
    if (design == null || !await store.putDesign(card.id, design)) {
      return;
    }
    _fetches.remove(card.id);
    final PebbleKeeperList? list = PebbleKeeperList.fromJson(p['k']);
    if (list != null && await list.verifyFor(card)) {
      await store.putKeeperList(list);
      if (list.retired && e.kept) {
        await store.drop(card.id, PebbleRole.kept);
      }
    }
    onDesign?.call(card.id);
  }

  // ---- "znaleziono" ----

  /// Tells the author of a collected pebble it was found, when the author
  /// can be reached and the account key is at hand (best effort, once).
  Future<void> _sendFound(PebbleEntry e) async {
    final LedgerKeyPair? key = accountKey();
    final List<String> to = peers.addressesOfAccount(e.card.authorAccount);
    if (key == null || to.isEmpty || key.id == e.card.authorAccount) {
      return;
    }
    final PebbleFoundNote note = await PebbleFoundNote.sign(
      key: key,
      id: e.id,
      atSeconds: (e.foundAtMillis ?? _now) ~/ 1000,
    );
    for (final String a in to.take(3)) {
      await _send(a, <String, dynamic>{
        'type': PebbleFrames.found,
        'n': note.toJson(),
      });
    }
    await store.markFoundSent(e.id);
  }

  /// Sends the "znaleziono" note for [id] now, if it can go.
  Future<void> sendFound(PebbleId id) => _run(() async {
    final PebbleEntry? e = store.entry(id);
    if (e != null && e.collected && !e.foundSent && !e.created) {
      await _sendFound(e);
    }
  });

  // ---- frames ----

  Future<void> _onFrame(SignalTransportFrame frame) async {
    final Object? type = frame.payload['type'];
    if (type is! String || !PebbleFrames.all.contains(type)) {
      return;
    }
    final String from = PeerShareCodec.normalizeAddress(frame.from);
    if (peers.isBlocked(from) || !_perSender.take(from, _now)) {
      return;
    }
    await store.load();
    final Map<String, dynamic> p = frame.payload;
    switch (type) {
      case PebbleFrames.get:
        await _onGet(from, p);
      case PebbleFrames.design:
        await _onDesign(from, p);
      case PebbleFrames.keepAsk:
        await _onKeepAsk(from, p);
      case PebbleFrames.keepYes:
      case PebbleFrames.keepNo:
      case PebbleFrames.keepQuit:
        await _onKeepAnswer(from, p, type);
      case PebbleFrames.keepers:
        await _onKeepers(from, p);
      case PebbleFrames.found:
        await _onFound(from, p);
    }
  }
}

/// [need] keepers from [pool]: the devices that answer best first, about
/// half computers and half phones while both are there (a household's
/// power cut or one kind of device's trouble does not take all of them),
/// with a little chance among equals.
@visibleForTesting
List<PebbleKeeperCandidate> pickKeepers(
  List<PebbleKeeperCandidate> pool,
  int need, {
  Random? random,
}) {
  final Random r = random ?? Random.secure();
  double score(PebbleKeeperCandidate c) =>
      c.quality + (c.desktop ? 0.25 : 0) + r.nextDouble() * 0.1;
  final Map<PebbleKeeperCandidate, double> scores =
      <PebbleKeeperCandidate, double>{
        for (final PebbleKeeperCandidate c in pool) c: score(c),
      };
  int byScore(PebbleKeeperCandidate a, PebbleKeeperCandidate b) =>
      scores[b]!.compareTo(scores[a]!);
  final List<PebbleKeeperCandidate> desktops =
      pool.where((PebbleKeeperCandidate c) => c.desktop).toList()
        ..sort(byScore);
  final List<PebbleKeeperCandidate> phones =
      pool.where((PebbleKeeperCandidate c) => !c.desktop).toList()
        ..sort(byScore);
  final List<PebbleKeeperCandidate> out = <PebbleKeeperCandidate>[];
  int d = 0;
  int ph = 0;
  while (out.length < need && (d < desktops.length || ph < phones.length)) {
    final bool takeDesktop =
        d < desktops.length &&
        (ph >= phones.length ||
            out.where((PebbleKeeperCandidate c) => c.desktop).length <=
                out.where((PebbleKeeperCandidate c) => !c.desktop).length);
    out.add(takeDesktop ? desktops[d++] : phones[ph++]);
  }
  return out;
}

final class _Fetch {
  int nextAt = 0;
  int cursor = 0;
  int round = 0;
}

/// At most [perMinute] per key in a minute.
final class _Budget {
  _Budget(this.perMinute);

  final int perMinute;
  final Map<String, (int, int)> _used = <String, (int, int)>{};

  bool take(String key, int now) {
    final int minute = now ~/ 60000;
    final (int, int) had = _used[key] ?? (minute, 0);
    final int count = had.$1 == minute ? had.$2 : 0;
    if (count >= perMinute) {
      return false;
    }
    _used[key] = (minute, count + 1);
    if (_used.length > 5000) {
      _used.removeWhere((String _, (int, int) v) => v.$1 != minute);
    }
    return true;
  }
}
