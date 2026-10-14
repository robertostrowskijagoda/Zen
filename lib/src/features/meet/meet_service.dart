import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/foundation.dart';
import 'package:zen/src/core/logging/zen_log.dart';
import 'package:zen/src/features/meet/meet_book.dart';
import 'package:zen/src/features/meet/nearby_crypto.dart';
import 'package:zen/src/features/runtime/runtime_system_notifications.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';
import 'package:zen/src/features/social/friend_display_name.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';

export 'package:zen/src/features/meet/nearby_crypto.dart'
    show AlarmWave, kAlarmWaveFreshFor, kAlarmWaveVersion;

/// Payload types of the meeting features on the mesh.
abstract final class MeetTypes {
  static const String intent = 'intent';
  static const String alarm = 'alarm';
  static const String alarmResponse = 'alarm_resp';

  /// Sound recorded during an alarm (§16.3).
  static const String alarmAudio = 'alarm_audio';

  /// A friend's phone confirms an alarm (§16.3): `k` is `got` (the phone
  /// has it) or `seen` (the friend opened it).
  static const String alarmAck = 'alarm_ack';
  static const String nearbyKey = 'nearby_key';
  static const String friendList = 'friend_list';

  /// A friend asks again for what got lost on the way (B1/B2): `w` lists
  /// `l` (the friend list), `k` (the nearby key), `s` (the status).
  static const String request = 'meet_req';

  static const Set<String> all = <String>{
    intent,
    alarm,
    alarmResponse,
    alarmAudio,
    alarmAck,
    nearbyKey,
    friendList,
    request,
  };

  /// Kinds that may come before the friendship is settled here (an accept
  /// still in the queue, the state not read yet): kept for a while and
  /// handled once the sender is a friend.
  static const Set<String> parkable = <String>{intent, nearbyKey, friendList};
}

/// Longest name taken from a friend's list.
const int kMaxFriendListName = 64;

/// Most entries taken from a friend's list.
const int kMaxFriendListEntries = 2000;

/// What an address on a friend's list may look like (a mesh address).
final RegExp _listAddress = RegExp(r'^[0-9A-Za-z:._-]{1,64}$');

/// A friend's alarm heard only over Bluetooth (§16.3) ends by itself after
/// this long, unless the network copy came meanwhile.
const Duration kNearbyAlarmLife = Duration(hours: 1);

/// Largest piece of alarm sound, in bytes.
const int kAlarmClipMaxBytes = 200 * 1024;

/// Pieces of sound per alarm.
const int kAlarmMaxClips = 6;

/// What [MeetService] needs from the app (or the Android background
/// service).
abstract interface class MeetHost {
  Future<void> send(String to, Map<String, dynamic> payload);

  /// Accepted friends (their app-side addresses).
  List<String> friends();

  /// Friends at the "przyjaciel" level.
  List<String> closeFriends();

  bool isFriend(String address);

  /// This device's own address (it appears in relayed alarm answers).
  bool isSelf(String address);

  String nameOf(String address);

  Future<void> notify(RuntimeSystemNotification notification);

  Future<void> dismissNotification(String slotKey);
}

/// What an alarm PIN turned out to be.
enum AlarmPinKind { normal, panic, wrong }

/// What happened on "Jestem bezpieczny". After [ended] the screen looks the
/// same for both PINs, so whoever watches cannot tell.
enum AlarmEndResult { ended, wrongPin, noAlarm }

/// Statuses ("Chcę pogadać", §16.2), alarms (§16.3) and nearby keys (§15)
/// between friends. The same code runs in the app and in the Android
/// background service; the state lives in [MeetStore].
final class MeetService extends ChangeNotifier {
  MeetService({
    required this.host,
    required this.store,
    int Function()? now,
    Random? random,
  }) : _now = now ?? (() => DateTime.now().millisecondsSinceEpoch),
       _random = random ?? Random.secure();

  final MeetHost host;
  final MeetStore store;
  final int Function() _now;
  final Random _random;

  MeetBook _book = MeetBook();

  /// Sends a wave over Bluetooth to phones nearby (set by the app when the
  /// nearby radio exists; `null` in the background service). Returns how
  /// many phones got it.
  Future<int> Function(Map<String, dynamic> wave)? nearbyBroadcast;

  /// The last alarm wave being sent nearby (tests wait for it).
  Future<int>? pendingNearbyWave;

  /// Alarm waves already handled (sender|id|ended → when), so a wave played
  /// back rings nothing. Kept a little longer than a wave stays fresh.
  final Map<String, int> _wavesSeen = <String, int>{};

  /// Most waves remembered at once.
  static const int _maxWavesSeen = 1000;

  /// Unchecked alarm waves (a stranger's, or one whose signature does not
  /// match) shown as a quiet note: at most one per sender in
  /// [unverifiedWaveEvery], and [maxUnverifiedWaves] in all (a phone can
  /// change its Bluetooth address).
  static const Duration unverifiedWaveEvery = Duration(minutes: 10);
  static const int maxUnverifiedWaves = 3;

  /// Sender → when its last unchecked wave was shown.
  final Map<String, int> _unverifiedAt = <String, int>{};

  /// The alarm id of the unchecked note on screen now.
  String? _unverifiedShown;

  /// This person's alarm when its last save failed (B10): it already went
  /// out and stays in memory; the next change of the book saves it too.
  AlarmRecord? _unsaved;

  /// Names of this person's friends, for sending the friend list again
  /// when a friend asks (set by the app and the background service).
  Map<String, String> Function()? friendNames;

  /// Frames from people who are not (yet) friends here: sender → frames
  /// with the time they came.
  final Map<String, List<(SignalTransportFrame, int)>> _parked =
      <String, List<(SignalTransportFrame, int)>>{};

  /// When this phone last asked a friend again / answered a friend's ask
  /// (friend|kind → time), so hellos never turn into a storm.
  final Map<String, int> _askedAt = <String, int>{};
  final Map<String, int> _answeredAt = <String, int>{};

  static const Duration _parkFor = Duration(minutes: 30);
  static const Duration _askEvery = Duration(minutes: 10);
  static const Duration _answerEvery = Duration(minutes: 2);

  /// New alarms one friend may raise here in an hour (each one rings): a
  /// person in trouble raises one, maybe again after a mistake — a broken
  /// or modified app cannot ring this phone without end.
  static const int maxNewAlarmsPerFriendPerHour = 5;

  /// When friends' new alarms came (friend → times), for the guard above.
  final Map<String, List<int>> _newAlarms = <String, List<int>>{};

  /// Friends' alarms this phone confirmed to their owner (once while it
  /// runs, and again whenever the owner asks).
  final Set<String> _confirmed = <String>{};

  /// Friends' alarms whose owner was told they were opened here.
  final Set<String> _seenTold = <String>{};

  bool _takeNewAlarm(String friend) {
    final int t = _now();
    final List<int> recent = (_newAlarms[friend] ??= <int>[])
      ..removeWhere((int at) => t - at > 3600 * 1000);
    if (recent.length >= maxNewAlarmsPerFriendPerHour) {
      return false;
    }
    recent.add(t);
    return true;
  }

  /// The last state read or written (for the UI).
  MeetBook get book => _book;

  int get now => _now();

  Future<void> reload() async {
    try {
      final MeetBook loaded = await store.loadInTurn();
      _putUnsaved(loaded, _unsaved);
      _book = loaded;
    } on Object catch (error, stack) {
      // Keep what is in memory; the next reload (e.g. after unlocking) reads
      // again.
      logZenError('Odczyt spotkań', error, stack);
      return;
    }
    notifyListeners();
  }

  Future<T> _update<T>(T Function(MeetBook book) change) async {
    late T result;
    final AlarmRecord? unsaved = _unsaved;
    await store.update<void>((MeetBook b) {
      _putUnsaved(b, unsaved);
      result = change(b);
      _book = b;
    });
    if (identical(_unsaved, unsaved)) {
      _unsaved = null;
    }
    notifyListeners();
    return result;
  }

  /// Puts this person's alarm whose save failed ([unsaved]) into [b]: the
  /// whole record when [b] lacks it, else only its end.
  static void _putUnsaved(MeetBook b, AlarmRecord? unsaved) {
    if (unsaved == null) {
      return;
    }
    final AlarmRecord? stored = b.alarm(unsaved.id);
    if (stored == null) {
      b.putAlarm(unsaved);
    } else if (stored.isActive && !unsaved.isActive) {
      b.putAlarm(
        stored.copyWith(endedAt: unsaved.endedAt, duress: unsaved.duress),
      );
    }
  }

  static String alarmSlot(String id) => 'alarm:$id';

  String _key(String a) => PeerShareCodec.normalizeAddress(a);

  // ---- incoming ----

  /// Handles a frame of one of [MeetTypes]. Returns whether it was one.
  Future<bool> handle(SignalTransportFrame frame) async {
    final Object? type = frame.payload['type'];
    if (type == 'ping' || type == 'pong') {
      // Presence is handled elsewhere; the hello digests are read here.
      await onHello(frame.from, frame.payload);
      return false;
    }
    if (type is! String || !MeetTypes.all.contains(type)) {
      return false;
    }
    final String from = _key(frame.from);
    if (!host.isFriend(from)) {
      _park(from, type, frame);
      return true;
    }
    try {
      switch (type) {
        case MeetTypes.intent:
          await _onIntent(from, frame.payload);
        case MeetTypes.alarm:
          await _onAlarm(from, frame.payload);
        case MeetTypes.alarmResponse:
          await _onAlarmResponse(from, frame.payload);
        case MeetTypes.alarmAudio:
          await _onAlarmAudio(from, frame.payload);
        case MeetTypes.alarmAck:
          await _onAlarmAck(from, frame.payload);
        case MeetTypes.friendList:
          await _onFriendList(from, frame.payload);
        case MeetTypes.request:
          await _onRequest(from, frame.payload);
        case MeetTypes.nearbyKey:
          final Object? k = frame.payload['k'];
          if (k is String && k.length <= 64) {
            await _update<void>(
              (MeetBook b) => b.friendNearbySecrets[from] = k,
            );
          }
      }
    } on Object catch (error, stack) {
      logZenError('Spotkania: $type', error, stack);
    }
    return true;
  }

  /// Keeps a frame from someone who is not a friend here yet (see
  /// [MeetTypes.parkable]); alarms and everything else are never kept.
  void _park(String from, String type, SignalTransportFrame frame) {
    if (!MeetTypes.parkable.contains(type)) {
      return;
    }
    final int t = _now();
    _parked.removeWhere(
      (String _, List<(SignalTransportFrame, int)> l) => l.every(
        ((SignalTransportFrame, int) e) => t - e.$2 > _parkFor.inMilliseconds,
      ),
    );
    if (!_parked.containsKey(from) && _parked.length >= 200) {
      return;
    }
    final List<(SignalTransportFrame, int)> list = _parked[from] ??=
        <(SignalTransportFrame, int)>[];
    // One of each kind is enough: the newest wins.
    list.removeWhere(
      ((SignalTransportFrame, int) e) => e.$1.payload['type'] == type,
    );
    list.add((frame, t));
  }

  /// Handles what [address] sent before they were a friend here (call when
  /// they become one, or once the state is read).
  Future<void> replayParked(String address) async {
    final List<(SignalTransportFrame, int)>? list = _parked.remove(
      _key(address),
    );
    if (list == null || !host.isFriend(address)) {
      return;
    }
    final int t = _now();
    for (final (SignalTransportFrame, int) e in list) {
      if (t - e.$2 <= _parkFor.inMilliseconds) {
        await handle(e.$1);
      }
    }
  }

  // ---- hello: what got lost is asked for again (B1/B2) ----

  static String _short(String digest) =>
      digest.length > 16 ? digest.substring(0, 16) : digest;

  static String _secretDigest(String? secret) => secret == null
      ? ''
      : _short(crypto.sha256.convert(utf8.encode(secret)).toString());

  /// Fields for a ping or pong to [friend]: short digests of what this
  /// phone gave them (its friend list, nearby key and status). The friend
  /// compares them with what it holds and asks again for what is missing.
  Map<String, dynamic> helloFor(String friend) {
    final IntentStatus? mine = _book.myIntent;
    final bool showsStatus =
        mine != null &&
        mine.activeAt(_now()) &&
        (!mine.onlyClose ||
            host.closeFriends().any(
              (String f) => PeerShareCodec.addressesEqual(f, friend),
            ));
    return <String, dynamic>{
      // A friend who may not see the list holds the empty one (§24.1).
      if (_book.friendListSent.isNotEmpty)
        'mf': _short(
          _book.showsFriendListTo(friend)
              ? _book.friendListSent
              : emptyFriendListDigest,
        ),
      if (_book.nearbySecret != null) 'mk': _secretDigest(_book.nearbySecret),
      'ms': showsStatus ? mine.setAt : 0,
    };
  }

  /// A ping or pong from [from]: asks again for what does not match.
  Future<void> onHello(String from, Map<String, dynamic> payload) async {
    final String friend = _key(from);
    if (!host.isFriend(friend)) {
      return;
    }
    final List<String> want = <String>[];
    final Object? mf = payload['mf'];
    if (mf is String &&
        mf.isNotEmpty &&
        mf != _short(_book.friendListDigests[friend] ?? '')) {
      want.add('l');
    }
    final Object? mk = payload['mk'];
    if (mk is String &&
        mk.isNotEmpty &&
        mk != _secretDigest(_book.friendNearbySecrets[friend])) {
      want.add('k');
    }
    final Object? ms = payload['ms'];
    if (ms is int && ms != (_book.friendIntents[friend]?.setAt ?? 0)) {
      want.add('s');
    }
    final int t = _now();
    want.removeWhere((String w) {
      final int? at = _askedAt['$friend|$w'];
      return at != null && t - at < _askEvery.inMilliseconds;
    });
    if (want.isEmpty) {
      return;
    }
    for (final String w in want) {
      _askedAt['$friend|$w'] = t;
    }
    await _send(friend, <String, dynamic>{
      'type': MeetTypes.request,
      'w': want,
    });
  }

  Future<void> _onRequest(String from, Map<String, dynamic> payload) async {
    final Object? w = payload['w'];
    if (w is! List) {
      return;
    }
    final int t = _now();
    for (final Object? kind in w.take(3)) {
      if (kind is! String) {
        continue;
      }
      final int? at = _answeredAt['$from|$kind'];
      if (at != null && t - at < _answerEvery.inMilliseconds) {
        continue;
      }
      _answeredAt['$from|$kind'] = t;
      switch (kind) {
        case 'l':
          final Map<String, String>? names = friendNames?.call();
          if (names != null && names.isNotEmpty) {
            await shareFriendList(names, only: <String>[from], force: true);
          }
        case 'k':
          await shareNearbySecret(from);
        case 's':
          final Map<String, dynamic> hello = helloFor(from);
          final IntentStatus? mine = _book.myIntent;
          await _send(from, <String, dynamic>{
            'type': MeetTypes.intent,
            's': hello['ms'] == 0 ? null : mine?.toJson(),
          });
      }
    }
  }

  /// A friend's friend list, with limits (a list is at most
  /// [kMaxFriendListEntries] people with short names), kept in its own file.
  Future<void> _onFriendList(String from, Map<String, dynamic> payload) async {
    final Object? l = payload['l'];
    final Map<String, String> list = <String, String>{};
    if (l is List) {
      for (final Object? item in l.take(kMaxFriendListEntries)) {
        if (item is! Map) {
          continue;
        }
        final Object? a = item['a'];
        if (a is! String || !_listAddress.hasMatch(a)) {
          continue;
        }
        final Object? n = item['n'];
        list[_key(a)] = n is String ? sanitizePeerName(n) : '';
      }
    }
    list
      ..remove(from)
      ..removeWhere((String a, String _) => host.isSelf(a));
    final Object? d = payload['d'];
    final String digest = d is String && d.length <= 64 && d.isNotEmpty
        ? d
        : crypto.sha256.convert(utf8.encode(jsonEncode(list))).toString();
    _book = await store.setFriendList(from, list, digest);
    notifyListeners();
  }

  Future<void> _onIntent(String from, Map<String, dynamic> payload) async {
    final IntentStatus? status = IntentStatus.fromJson(payload['s']);
    final IntentStatus? before = _book.intentOf(from, _now());
    await _update<void>((MeetBook b) => b.setFriendIntent(from, status));
    final bool asks =
        status != null &&
        (status.kind == IntentKind.help || status.kind == IntentKind.urgent);
    if (asks && before?.kind != status.kind && status.activeAt(_now())) {
      final bool urgent = status.kind == IntentKind.urgent;
      await host.notify(
        RuntimeSystemNotification(
          id: 'intent-$from-${status.setAt}',
          title: urgent
              ? '🆘 ${host.nameOf(from)} pilnie potrzebuje pomocy'
              : '${host.nameOf(from)} potrzebuje pomocy',
          body: status.note.isEmpty ? 'Zajrzyj do Zen.' : status.note,
          createdAtMillis: _now(),
          // Urgent: as loud as a message (heads-up), still not the alarm.
          category: urgent
              ? RuntimeSystemNotificationCategory.message
              : RuntimeSystemNotificationCategory.social,
          slotKey: 'intent:$from',
        ),
      );
    }
  }

  Future<void> _onAlarm(String from, Map<String, dynamic> payload) async {
    final AlarmRecord? got = AlarmRecord.fromJson(<String, dynamic>{
      ...payload,
      'from': from,
    });
    if (got == null) {
      return;
    }
    final AlarmRecord? had = _book.alarm(got.id);
    if (had != null && had.from != from) {
      return; // someone else's alarm id: not theirs to change
    }
    if (had == null && !_takeNewAlarm(from)) {
      return;
    }
    // Our own answer stays ours ('self'); the owner relays everyone's,
    // ours among them under our address.
    final Map<String, AlarmResponse> responses = <String, AlarmResponse>{
      for (final MapEntry<String, AlarmResponse> e in got.responses.entries)
        if (!host.isSelf(e.key) && e.key != 'self') e.key: e.value,
      if (had?.responses['self'] != null) 'self': had!.responses['self']!,
    };
    // Sound pieces: only the ones this phone really has.
    final AlarmRecord merged = got.copyWith(
      responses: responses,
      clips: had?.clips ?? const <AlarmClip>[],
      nearby: false,
      // Whom it went to and who confirmed it is only the owner's business.
      sentTo: const <String>[],
      deliveries: const <String, AlarmDelivery>{},
    );
    if (!await _putFriendAlarm(merged)) {
      return; // too many of theirs already going on
    }
    // The owner learns at once that this phone has it (§16.3): the first
    // copy, and any copy they ask about (they have no confirmation yet).
    if (_confirmed.add(merged.id) || payload['cf'] == true) {
      await _confirmAlarm(from, merged.id);
    }
    final String name = host.nameOf(from);
    if (merged.isActive && (had == null || !had.isActive)) {
      await host.notify(
        RuntimeSystemNotification(
          id: 'alarm-${merged.id}',
          title: '🚨 ALARM: $name potrzebuje pomocy',
          body: merged.hasLocation
              ? 'Otwórz, żeby zobaczyć, gdzie jest, i odpowiedzieć.'
              : 'Otwórz i odpowiedz.',
          createdAtMillis: _now(),
          category: RuntimeSystemNotificationCategory.alarm,
          slotKey: alarmSlot(merged.id),
          isRingingCall: true,
        ),
      );
    } else if (!merged.isActive && (had == null || had.isActive)) {
      await host.dismissNotification(alarmSlot(merged.id));
      await host.notify(
        RuntimeSystemNotification(
          id: 'alarm-end-${merged.id}',
          title: merged.duress
              ? '⚠️ $name odwołał(a) alarm PIN-em panicznym'
              : '$name jest bezpieczny(-a)',
          body: merged.duress
              ? 'Może być do tego zmuszony(-a). Sprawdź, co się dzieje.'
              : 'Alarm odwołany.',
          createdAtMillis: _now(),
          category: merged.duress
              ? RuntimeSystemNotificationCategory.alarm
              : RuntimeSystemNotificationCategory.social,
          slotKey: 'alarm-end:${merged.id}',
        ),
      );
    }
  }

  Future<void> _onAlarmResponse(
    String from,
    Map<String, dynamic> payload,
  ) async {
    final Object? id = payload['id'];
    final AlarmResponse? r = AlarmResponse.byName(payload['r']);
    if (id is! String || !kAlarmIdPattern.hasMatch(id) || r == null) {
      return;
    }
    final AlarmRecord? own = _book.alarm(id);
    if (own == null || !own.isOwn) {
      return;
    }
    final AlarmRecord? updated = await _changeAlarm(
      id,
      (AlarmRecord a) =>
          a.responses.containsKey(from) ||
              a.responses.length < AlarmRecord.maxResponses
          ? a.copyWith(
              responses: <String, AlarmResponse>{...a.responses, from: r},
            )
          : a,
    );
    if (updated == null) {
      return;
    }
    await host.notify(
      RuntimeSystemNotification(
        id: 'alarm-resp-$id-$from',
        title: '${host.nameOf(from)}: ${r.label}',
        body: 'Odpowiedź na Twój alarm.',
        createdAtMillis: _now(),
        category: RuntimeSystemNotificationCategory.social,
        slotKey: 'alarm-resp:$id',
      ),
    );
    if (updated.isActive) {
      await _broadcastAlarm(updated);
    }
  }

  /// A friend's phone confirmed this person's alarm (§16.3). Only for this
  /// person's own alarm, only from a friend it went to; read from the store
  /// (the background service may hold an older copy).
  Future<void> _onAlarmAck(String from, Map<String, dynamic> payload) async {
    final Object? id = payload['id'];
    final Object? k = payload['k'];
    final Object? t = payload['t'];
    if (id is! String ||
        !kAlarmIdPattern.hasMatch(id) ||
        (k != 'got' && k != 'seen')) {
      return;
    }
    final bool seen = k == 'seen';
    final int now = _now();
    await _update<void>((MeetBook b) {
      // Not in the store yet: the alarm goes out before it is saved (B10).
      final AlarmRecord? own = b.alarm(id) ?? _ownInMemory(id);
      if (own == null || !own.isOwn || !own.sentTo.contains(from)) {
        return;
      }
      // Their clock may be off: their time only when it makes sense.
      final int when = t is int && t >= own.at && t <= now ? t : now;
      final AlarmDelivery had = own.deliveries[from] ?? const AlarmDelivery();
      if (had.got != null && (!seen || had.seen != null)) {
        return; // nothing new
      }
      b.putAlarm(
        own.copyWith(
          deliveries: <String, AlarmDelivery>{
            ...own.deliveries,
            from: AlarmDelivery(
              got: had.got ?? when,
              seen: seen ? when : had.seen,
            ),
          },
        ),
      );
    });
  }

  /// Tells [owner] this phone has their alarm [id] (or, [seen], that it
  /// was opened).
  Future<void> _confirmAlarm(String owner, String id, {bool seen = false}) =>
      _send(owner, <String, dynamic>{
        'type': MeetTypes.alarmAck,
        'id': id,
        'k': seen ? 'seen' : 'got',
        't': _now(),
      });

  /// A friend's alarm [alarmId] is on screen here: its owner learns it was
  /// seen (once).
  Future<void> markAlarmSeen(String alarmId) async {
    final AlarmRecord? a = _book.alarm(alarmId);
    if (a == null ||
        a.isOwn ||
        !a.isActive ||
        !host.isFriend(a.from) ||
        !_seenTold.add(a.id)) {
      return;
    }
    _confirmed.add(a.id);
    await _confirmAlarm(a.from, a.id, seen: true);
  }

  /// Changes alarm [id] as it is in the store now, so answers and delivery
  /// notes that came meanwhile stay. Returns the new record (`null`: gone).
  Future<AlarmRecord?> _changeAlarm(
    String id,
    AlarmRecord Function(AlarmRecord a) change,
  ) => _update<AlarmRecord?>((MeetBook b) {
    final AlarmRecord? current = b.alarm(id) ?? _ownInMemory(id);
    if (current == null) {
      return null;
    }
    final AlarmRecord next = change(current);
    b.putAlarm(next);
    return next;
  });

  /// Keeps a friend's [alarm]. `false` when it is not kept (too many of
  /// theirs going on). A failed save never silences it (B10): it is kept
  /// in memory and still rings.
  Future<bool> _putFriendAlarm(AlarmRecord alarm) async {
    try {
      return await _update<bool>((MeetBook b) => b.putAlarm(alarm));
    } on Object catch (error, stack) {
      logZenError('Zapis alarmu znajomego', error, stack);
      final bool kept = _book.putAlarm(alarm);
      notifyListeners();
      return kept;
    }
  }

  /// This person's alarm [id] as held in memory (sent, maybe not saved yet).
  AlarmRecord? _ownInMemory(String id) {
    final AlarmRecord? a = _book.alarm(id);
    return a != null && a.isOwn ? a : null;
  }

  /// Keeps [alarm] (this person's, just changed) in memory before it goes
  /// out: the screen and the answers see it at once, whatever the store
  /// does.
  void _keepInMemory(AlarmRecord alarm) {
    _book.putAlarm(alarm);
    notifyListeners();
  }

  /// Saves this person's [alarm] after it went out ([merge]: how it goes
  /// onto the copy in the store). A failed save never stops an alarm (B10):
  /// it stays in memory and is saved with the next change.
  Future<void> _saveOwnAlarm(
    AlarmRecord alarm,
    AlarmRecord Function(AlarmRecord stored) merge,
  ) async {
    try {
      await _update<void>((MeetBook b) {
        final AlarmRecord? stored = b.alarm(alarm.id);
        b.putAlarm(stored == null ? alarm : merge(stored));
      });
    } on Object catch (error, stack) {
      logZenError('Zapis alarmu', error, stack);
      _unsaved = alarm;
    }
  }

  // ---- statuses ----

  /// Sets (or with `null` clears) what this person is up for, and tells
  /// friends ("przyjaciele" only when [IntentStatus.onlyClose]). Friends in
  /// [except] are told there is no status (e.g. people the dating profile
  /// is hidden from never see „Randkuję”, §16.2).
  Future<void> setMyIntent(
    IntentStatus? status, {
    Set<String> except = const <String>{},
  }) async {
    final IntentStatus? before = _book.myIntent;
    await _update<void>((MeetBook b) => b.myIntent = status);
    final Set<String> to = <String>{
      ...(status?.onlyClose ?? false) ? host.closeFriends() : host.friends(),
    };
    if (before != null && before.onlyClose != (status?.onlyClose ?? false)) {
      // Those who saw the old one must hear it is gone.
      to.addAll(host.friends());
    }
    final List<String> close = host.closeFriends().map(_key).toList();
    for (final String friend in to) {
      final bool sees =
          status != null &&
          !except.contains(_key(friend)) &&
          (!status.onlyClose || close.contains(_key(friend)));
      await _send(friend, <String, dynamic>{
        'type': MeetTypes.intent,
        if (sees) 's': status.toJson(),
      });
    }
  }

  /// Friends who are up for [kind] right now, newest first.
  List<(String, IntentStatus)> friendsWith(IntentKind kind) {
    final int t = _now();
    final List<(String, IntentStatus)> out = <(String, IntentStatus)>[
      for (final MapEntry<String, IntentStatus> e
          in _book.friendIntents.entries)
        if (e.value.kind == kind && e.value.activeAt(t) && host.isFriend(e.key))
          (e.key, e.value),
    ]..sort((a, b) => b.$2.setAt.compareTo(a.$2.setAt));
    return out;
  }

  // ---- alarm ----

  /// Who gets this person's alarm: "przyjaciele", or every friend when
  /// none is marked as one.
  List<String> alarmRecipients() {
    final List<String> close = host.closeFriends();
    return close.isNotEmpty ? close : host.friends();
  }

  /// Both PINs are set (an older single PIN must be set up again).
  bool get hasAlarmPin =>
      _book.alarmPinHash != null && _book.alarmPanicHash != null;

  static String _hashPin(String salt, String pin) =>
      crypto.sha256.convert(utf8.encode('zen-alarm|$salt|$pin')).toString();

  /// Sets the normal [pin] and the [panicPin] (they must differ). Returns
  /// `false` when they are the same.
  Future<bool> setAlarmPin(String pin, String panicPin) async {
    if (pin == panicPin) {
      return false;
    }
    final String salt = base64Url.encode(
      List<int>.generate(16, (_) => _random.nextInt(256)),
    );
    await _update<void>((MeetBook b) {
      b.alarmPinSalt = salt;
      b.alarmPinHash = _hashPin(salt, pin);
      b.alarmPanicHash = _hashPin(salt, panicPin);
    });
    return true;
  }

  /// Which of the two PINs [pin] is.
  AlarmPinKind checkAlarmPin(String pin) {
    final String? salt = _book.alarmPinSalt;
    if (salt == null) {
      return AlarmPinKind.wrong;
    }
    final String h = _hashPin(salt, pin);
    if (h == _book.alarmPinHash) {
      return AlarmPinKind.normal;
    }
    if (h == _book.alarmPanicHash) {
      return AlarmPinKind.panic;
    }
    return AlarmPinKind.wrong;
  }

  /// Raises the alarm. Returns it.
  ///
  /// It goes out first (Bluetooth, then the network) and is saved after:
  /// a store that cannot be written (too big, locked) never stops an alarm
  /// (B10).
  Future<AlarmRecord> raiseAlarm({
    String note = '',
    double? lat,
    double? lon,
    double? accuracy,
  }) async {
    final AlarmRecord? running = _book.ownActiveAlarm;
    if (running != null) {
      return running;
    }
    final int t = _now();
    final AlarmRecord alarm = AlarmRecord(
      id: '${t.toRadixString(36)}${_random.nextInt(1 << 30).toRadixString(36)}',
      from: 'self',
      at: t,
      lat: lat,
      lon: lon,
      accuracy: accuracy,
      locatedAt: lat == null ? null : t,
      note: note.length > AlarmRecord.maxNoteChars
          ? note.substring(0, AlarmRecord.maxNoteChars)
          : note,
      sentTo: <String>{
        for (final String f in alarmRecipients()) _key(f),
      }.take(AlarmRecord.maxRecipients).toList(),
    );
    _keepInMemory(alarm);
    _startNearbyWave(alarm);
    await _broadcastAlarm(alarm);
    await _saveOwnAlarm(alarm, (AlarmRecord stored) => stored);
    return alarm;
  }

  /// Tells phones nearby about [alarm] when the person chose that (it
  /// takes a few seconds: not waited for).
  void _startNearbyWave(AlarmRecord alarm) {
    if (!_book.alarmNearby) {
      return;
    }
    final Future<int> wave = _waveNearby(alarm);
    pendingNearbyWave = wave;
    unawaitedLogged(wave.then<void>((int _) {}), context: 'Alarm w pobliżu');
  }

  /// A fresh position for this person's running alarm (sent first, saved
  /// after, like the alarm itself).
  Future<void> updateAlarmLocation(
    double lat,
    double lon, {
    double? accuracy,
  }) async {
    final AlarmRecord? own = _book.ownActiveAlarm;
    if (own == null) {
      return;
    }
    final int t = _now();
    AlarmRecord located(AlarmRecord a) =>
        a.copyWith(lat: lat, lon: lon, accuracy: accuracy, locatedAt: t);
    final AlarmRecord updated = located(own);
    _keepInMemory(updated);
    await _broadcastAlarm(updated);
    await _saveOwnAlarm(updated, located);
  }

  /// "Jestem bezpieczny". The normal PIN ends the alarm; the panic PIN
  /// looks exactly the same here, but friends learn the person may be
  /// forced. A mistyped PIN changes nothing and may be tried again.
  Future<AlarmEndResult> endAlarm(String pin) async {
    final AlarmRecord? own = _book.ownActiveAlarm;
    if (own == null) {
      return AlarmEndResult.noAlarm;
    }
    final AlarmPinKind kind = hasAlarmPin
        ? checkAlarmPin(pin)
        : AlarmPinKind.normal;
    if (kind == AlarmPinKind.wrong) {
      return AlarmEndResult.wrongPin;
    }
    final int t = _now();
    final bool duress = kind == AlarmPinKind.panic;
    final AlarmRecord ended = own.copyWith(endedAt: t, duress: duress);
    // Like raising it: out first, saved after (B10).
    _keepInMemory(ended);
    _startNearbyWave(ended);
    await _broadcastAlarm(ended);
    await _saveOwnAlarm(
      ended,
      (AlarmRecord stored) => stored.copyWith(endedAt: t, duress: duress),
    );
    return AlarmEndResult.ended;
  }

  Future<void> setAlarmRecordAudio(bool on) =>
      _update<void>((MeetBook b) => b.alarmRecordAudio = on);

  Future<void> setAlarmNearby(bool on) =>
      _update<void>((MeetBook b) => b.alarmNearby = on);

  /// The power-button shortcut (§16.3, Android).
  Future<void> setAlarmPowerButton(bool on) =>
      _update<void>((MeetBook b) => b.alarmPowerButton = on);

  /// Sends this person's running alarm to the same friends again — after
  /// the Android background service took the network over (the shortcut
  /// fires just as the screen goes off, while the app hands the network
  /// over, so the first copy may have left from the side that was letting
  /// go). Friends who already have it see nothing new.
  ///
  /// With [to]: only to those of them (friends it already went to) — e.g.
  /// the ones whose phone did not confirm it (§16.3).
  Future<void> resendOwnAlarm({Iterable<String>? to}) async {
    final AlarmRecord? own = _book.ownActiveAlarm;
    if (own == null) {
      return;
    }
    if (to == null) {
      await _broadcastAlarm(own);
      return;
    }
    final Set<String> wanted = <String>{for (final String f in to) _key(f)};
    final List<String> friends = host.friends();
    final List<String> targets = <String>[
      for (final String f in own.sentTo)
        if (wanted.contains(f))
          friends.where((String a) => _key(a) == f).firstOrNull ?? f,
    ];
    if (targets.isNotEmpty) {
      await _broadcastAlarm(own, only: targets);
    }
  }

  // ---- alarm: sound (§16.3) ----

  /// Adds a piece of sound recorded during this person's running alarm
  /// and sends it to the friends who got the alarm. Returns the piece, or
  /// `null` (no alarm, too big, too many).
  Future<AlarmClip?> addAlarmAudio(Uint8List data, {int durationMs = 0}) async {
    final AlarmRecord? own = _book.ownActiveAlarm;
    if (own == null ||
        data.isEmpty ||
        data.length > kAlarmClipMaxBytes ||
        own.clips.length >= kAlarmMaxClips) {
      return null;
    }
    final AlarmClip clip = AlarmClip(
      n: own.clips.length,
      at: _now(),
      ms: durationMs,
    );
    await store.disk.write(MeetStore.audioKey(own.id, clip.n), data);
    await _update<void>(
      (MeetBook b) => b.putAlarm(
        (b.alarm(own.id) ?? own).copyWith(
          clips: <AlarmClip>[...own.clips, clip],
        ),
      ),
    );
    final String encoded = base64Encode(data);
    for (final String friend in alarmRecipients()) {
      await _send(friend, <String, dynamic>{
        'type': MeetTypes.alarmAudio,
        'id': own.id,
        'n': clip.n,
        'at': clip.at,
        'ms': clip.ms,
        'd': encoded,
      });
    }
    return clip;
  }

  /// The sound of piece [n] of alarm [alarmId], if this phone has it.
  Future<Uint8List?> alarmAudio(String alarmId, int n) async {
    try {
      return await store.disk.read(MeetStore.audioKey(alarmId, n));
    } on Object catch (error) {
      logZenWarning('Nagranie alarmu: $error');
      return null;
    }
  }

  Future<void> _onAlarmAudio(String from, Map<String, dynamic> payload) async {
    final Object? id = payload['id'];
    final Object? n = payload['n'];
    final Object? at = payload['at'];
    final Object? ms = payload['ms'];
    final Object? d = payload['d'];
    final AlarmRecord? alarm = id is String ? _book.alarm(id) : null;
    if (alarm == null ||
        alarm.isOwn ||
        alarm.from != from ||
        n is! int ||
        n < 0 ||
        n >= kAlarmMaxClips ||
        d is! String ||
        d.length > kAlarmClipMaxBytes * 4 ~/ 3 + 8 ||
        alarm.clips.any((AlarmClip c) => c.n == n)) {
      return;
    }
    final Uint8List data;
    try {
      data = base64Decode(d);
    } on FormatException {
      return;
    }
    if (data.isEmpty || data.length > kAlarmClipMaxBytes) {
      return;
    }
    await store.disk.write(MeetStore.audioKey(alarm.id, n), data);
    final AlarmClip clip = AlarmClip(
      n: n,
      at: at is int ? at : _now(),
      ms: ms is int ? ms.clamp(0, 600000) : 0,
    );
    await _update<void>((MeetBook b) {
      final AlarmRecord current = b.alarm(alarm.id) ?? alarm;
      b.putAlarm(
        current.copyWith(
          clips: <AlarmClip>[
            ...current.clips.where((AlarmClip c) => c.n != n),
            clip,
          ]..sort((AlarmClip x, AlarmClip y) => x.n.compareTo(y.n)),
        ),
      );
    });
    await host.notify(
      RuntimeSystemNotification(
        id: 'alarm-audio-${alarm.id}-$n',
        title: '🎙 Nagranie z alarmu: ${host.nameOf(from)}',
        body: 'Otwórz alarm, żeby odsłuchać.',
        createdAtMillis: _now(),
        category: RuntimeSystemNotificationCategory.social,
        slotKey: 'alarm-audio:${alarm.id}',
      ),
    );
  }

  // ---- alarm: Bluetooth nearby (§16.3) ----

  /// The wave that tells phones nearby about [alarm]: its id, the time and
  /// whether it ended, with this phone's nearby token and a signature made
  /// with the nearby secret ([AlarmWave]). Friends (who have the secret)
  /// know whose it is and that it is real; nobody else learns who it is.
  /// Without a secret yet it goes unsigned: phones around show only an
  /// unchecked note.
  Map<String, dynamic> alarmWave(AlarmRecord alarm) => AlarmWave.build(
    id: alarm.id,
    at: _now(),
    ended: !alarm.isActive,
    secret: _book.nearbySecret,
  );

  Future<int> _waveNearby(AlarmRecord alarm) async {
    final Future<int> Function(Map<String, dynamic>)? send = nearbyBroadcast;
    if (send == null) {
      return 0;
    }
    try {
      return await send(alarmWave(alarm));
    } on Object catch (error) {
      logZenWarning('Alarm w pobliżu: $error');
      return 0;
    }
  }

  /// Slot of the quiet note about an unchecked wave (one at a time).
  static const String unverifiedWaveSlot = 'alarm-near';

  /// An alarm wave heard over Bluetooth (§16.3). [friend]: the friend whose
  /// nearby token it carried (`null`: nobody known); [source]: the
  /// Bluetooth address of the phone that wrote it.
  ///
  /// Only a fresh wave signed with that friend's nearby secret rings, like
  /// an alarm from the network. Anything else (a stranger, a played-back
  /// token, a bad signature) is never more than a quiet note marked as
  /// unchecked, at most one per sender in [unverifiedWaveEvery].
  Future<void> onAlarmWave(
    Map<dynamic, dynamic> json, {
    String? friend,
    String source = '',
  }) async {
    final AlarmWave? wave = AlarmWave.parse(json);
    final int t = _now();
    if (wave == null || !wave.isFreshAt(t)) {
      return; // damaged, too old or from the future: played back?
    }
    final String who = _signedBy(wave, friend);
    if (!_rememberWave('$who|${wave.id}|${wave.ended}', t)) {
      return; // heard already
    }
    if (who.isEmpty) {
      await _onUncheckedWave(wave, source, t);
      return;
    }
    if (wave.ended) {
      // Only the network copy (with the PIN's outcome) ends a friend's
      // alarm; Bluetooth cannot tell "safe" from "forced".
      return;
    }
    final AlarmRecord? had = _book.alarm(wave.id);
    if (had != null) {
      return; // already known from the network
    }
    if (!_takeNewAlarm(who)) {
      return;
    }
    final AlarmRecord alarm = AlarmRecord(
      id: wave.id,
      from: who,
      at: t,
      nearby: true,
    );
    if (!await _putFriendAlarm(alarm)) {
      return;
    }
    if (_confirmed.add(wave.id)) {
      await _confirmAlarm(who, wave.id);
    }
    await host.notify(
      RuntimeSystemNotification(
        id: 'alarm-${wave.id}',
        title: '🚨 ALARM: ${host.nameOf(who)} potrzebuje pomocy',
        body: 'Jest gdzieś blisko Ciebie (Bluetooth). Otwórz i odpowiedz.',
        createdAtMillis: t,
        category: RuntimeSystemNotificationCategory.alarm,
        slotKey: alarmSlot(wave.id),
        isRingingCall: true,
      ),
    );
  }

  /// The friend who signed [wave] ('' when nobody known did): [friend]
  /// (found by the token) must have given this phone the secret the
  /// signature checks against.
  String _signedBy(AlarmWave wave, String? friend) {
    if (friend == null || !wave.signed || !host.isFriend(friend)) {
      return '';
    }
    final String key = _key(friend);
    final String? secret = _book.friendNearbySecrets[key];
    return secret != null && wave.verify(secret) ? key : '';
  }

  /// Remembers [key] (a wave heard at [t]). `false` when it was heard
  /// already.
  bool _rememberWave(String key, int t) {
    final int keep = 2 * kAlarmWaveFreshFor.inMilliseconds;
    _wavesSeen.removeWhere((String _, int at) => (t - at).abs() > keep);
    if (_wavesSeen.containsKey(key)) {
      return false;
    }
    while (_wavesSeen.length >= _maxWavesSeen) {
      _wavesSeen.remove(_wavesSeen.keys.first);
    }
    _wavesSeen[key] = t;
    return true;
  }

  /// A wave nobody known signed: a quiet note, clearly unchecked, never
  /// ringing, at most one per [source] in [unverifiedWaveEvery] and
  /// [maxUnverifiedWaves] in all.
  Future<void> _onUncheckedWave(AlarmWave wave, String source, int t) async {
    if (wave.ended) {
      if (_unverifiedShown == wave.id) {
        _unverifiedShown = null;
        await host.dismissNotification(unverifiedWaveSlot);
      }
      return;
    }
    final String from = source.isNotEmpty
        ? source
        : wave.token.isNotEmpty
        ? wave.token
        : '?';
    _unverifiedAt.removeWhere(
      (String _, int at) =>
          (t - at).abs() >= unverifiedWaveEvery.inMilliseconds,
    );
    if (_unverifiedAt.containsKey(from) ||
        _unverifiedAt.length >= maxUnverifiedWaves) {
      return;
    }
    _unverifiedAt[from] = t;
    _unverifiedShown = wave.id;
    await host.notify(
      RuntimeSystemNotification(
        id: 'alarm-near-${wave.id}',
        title: 'Niesprawdzone: ktoś obok prosi o pomoc',
        body:
            'Telefon w pobliżu wysłał przez Bluetooth prośbę o pomoc. '
            'Nie wiadomo, kto to, i nie da się tego sprawdzić — może to być '
            'pomyłka albo żart. Jeśli możesz bezpiecznie, rozejrzyj się. '
            'W razie zagrożenia: 112.',
        createdAtMillis: t,
        category: RuntimeSystemNotificationCategory.social,
        slotKey: unverifiedWaveSlot,
      ),
    );
  }

  /// Friends' alarms heard only over Bluetooth end by themselves after
  /// [kNearbyAlarmLife] (the network copy never came: nothing more is
  /// known). Called now and then.
  Future<void> expireNearbyAlarms() async {
    final int t = _now();
    bool due(AlarmRecord a) =>
        !a.isOwn &&
        a.nearby &&
        a.isActive &&
        t - a.at >= kNearbyAlarmLife.inMilliseconds;
    final List<AlarmRecord> old = _book.alarms.where(due).toList();
    if (old.isEmpty) {
      return;
    }
    await _update<void>((MeetBook b) {
      for (final AlarmRecord a in b.alarms.where(due).toList()) {
        b.putAlarm(a.copyWith(endedAt: t));
      }
    });
    for (final AlarmRecord a in old) {
      await host.dismissNotification(alarmSlot(a.id));
    }
  }

  /// Sends [alarm] to the friends who get alarms (or [only] to these).
  /// Friends it reaches are kept in [AlarmRecord.sentTo] first, so their
  /// confirmations count; those who have not confirmed it are asked to.
  Future<void> _broadcastAlarm(AlarmRecord alarm, {List<String>? only}) async {
    final List<String> to = only ?? alarmRecipients();
    AlarmRecord current = _book.alarm(alarm.id) ?? alarm;
    if (alarm.isOwn) {
      final Set<String> known = current.sentTo.toSet();
      final List<String> added = <String>[
        for (final String f in to)
          if (!known.contains(_key(f))) _key(f),
      ];
      if (added.isNotEmpty) {
        // The stored copy may not have the end yet (it is saved after).
        AlarmRecord widen(AlarmRecord a) => a.copyWith(
          sentTo: <String>{
            ...a.sentTo,
            ...added,
          }.take(AlarmRecord.maxRecipients).toList(),
          endedAt: alarm.endedAt,
          duress: alarm.isActive ? null : alarm.duress,
        );
        final AlarmRecord before = current;
        try {
          current = await _update<AlarmRecord>((MeetBook b) {
            final AlarmRecord next = widen(b.alarm(alarm.id) ?? before);
            b.putAlarm(next);
            return next;
          });
        } on Object catch (error, stack) {
          // Not saved: it still goes out (B10).
          logZenError('Zapis alarmu', error, stack);
          current = widen(before);
          _keepInMemory(current);
          _unsaved = current;
        }
      }
    }
    final Map<String, dynamic> json = alarm.toJson()
      ..remove('from')
      ..remove('clips')
      ..remove('near')
      ..remove('to')
      ..remove('dlv')
      ..['type'] = MeetTypes.alarm;
    for (final String friend in to) {
      final bool ask =
          alarm.isOwn && current.reachOf(_key(friend)) == AlarmReach.sent;
      await _send(friend, ask ? <String, dynamic>{...json, 'cf': true} : json);
    }
  }

  /// Answers a friend's alarm.
  Future<void> respond(String alarmId, AlarmResponse response) async {
    final AlarmRecord? alarm = _book.alarm(alarmId);
    if (alarm == null || alarm.isOwn) {
      return;
    }
    AlarmRecord answered(AlarmRecord a) => a.copyWith(
      responses: <String, AlarmResponse>{...a.responses, 'self': response},
    );
    // The answer goes first; a failed save must not hold it back (B10).
    _book.putAlarm(answered(alarm));
    notifyListeners();
    await host.dismissNotification(alarmSlot(alarmId));
    await _send(alarm.from, <String, dynamic>{
      'type': MeetTypes.alarmResponse,
      'id': alarmId,
      'r': response.name,
    });
    try {
      await _update<void>(
        (MeetBook b) => b.putAlarm(answered(b.alarm(alarmId) ?? alarm)),
      );
    } on Object catch (error, stack) {
      logZenError('Zapis odpowiedzi na alarm', error, stack);
    }
  }

  // ---- nearby keys ----

  /// This person's nearby secret, made on first use.
  Future<String> nearbySecret() async {
    final String? had = _book.nearbySecret;
    if (had != null) {
      return had;
    }
    final String made = base64Url.encode(
      List<int>.generate(32, (_) => _random.nextInt(256)),
    );
    return _update<String>((MeetBook b) => b.nearbySecret ??= made);
  }

  /// Gives [friend] the nearby secret (so they recognise this phone).
  Future<void> shareNearbySecret(String friend) async {
    await _send(friend, <String, dynamic>{
      'type': MeetTypes.nearbyKey,
      'k': await nearbySecret(),
    });
    await _update<void>((MeetBook b) => b.nearbyGivenTo.add(_key(friend)));
  }

  /// New secret (after removing a friend: they can no longer recognise
  /// this phone), given to the remaining friends.
  Future<void> rotateNearbySecret() async {
    final String made = base64Url.encode(
      List<int>.generate(32, (_) => _random.nextInt(256)),
    );
    await _update<void>((MeetBook b) {
      b.nearbySecret = made;
      b.nearbyGivenTo.clear();
    });
    for (final String f in host.friends()) {
      await shareNearbySecret(f);
    }
  }

  /// Tells friends who this person's friends are (or, when sharing is
  /// off, that they should forget it). Sends only when something changed,
  /// unless [force] (a new friend).
  Future<void> shareFriendList(
    Map<String, String> friendsWithNames, {
    Iterable<String>? only,
    bool force = false,
  }) async {
    final bool share = _book.shareFriendList;
    final List<Map<String, String>> list = <Map<String, String>>[
      if (share)
        for (final MapEntry<String, String> e
            in (friendsWithNames.entries.toList()
              ..sort((a, b) => a.key.compareTo(b.key))))
          <String, String>{'a': _key(e.key), 'n': e.value},
    ];
    final String digest = crypto.sha256
        .convert(utf8.encode(jsonEncode(list)))
        .toString();
    if (!force && only == null && digest == _book.friendListSent) {
      return;
    }
    for (final String friend in only ?? friendsWithNames.keys) {
      // Who may not see it (§24.1) gets an empty list and forgets theirs.
      final bool sees = _book.showsFriendListTo(friend);
      await _send(friend, <String, dynamic>{
        'type': MeetTypes.friendList,
        'l': <Map<String, String>>[
          if (sees)
            for (final Map<String, String> item in list)
              if (item['a'] != _key(friend)) item,
        ],
        // What the whole list is now: the friend compares it with this
        // phone's hello and asks again when one got lost.
        'd': sees ? digest : emptyFriendListDigest,
      });
    }
    if (only == null) {
      await _update<void>((MeetBook b) => b.friendListSent = digest);
    }
  }

  /// The digest of an empty friend list (what someone who may not see the
  /// list gets).
  static final String emptyFriendListDigest = crypto.sha256
      .convert(utf8.encode(jsonEncode(const <Object>[])))
      .toString();

  Future<void> setShareFriendList(bool on) => setFriendListAudience(
    on ? FriendListAudience.all : FriendListAudience.nobody,
  );

  /// Who sees this person's friend list (§24.1). Send the list again after
  /// this (`shareFriendList(..., force: true)`).
  Future<void> setFriendListAudience(FriendListAudience audience) =>
      _update<void>((MeetBook b) {
        b.friendListAudience = audience;
        b.friendListSent = '';
      });

  /// Lets [friend] see the friend list while it is shown on request (or
  /// takes that back); they get the list, or an empty one, at once.
  Future<void> allowFriendList(String friend, {required bool allow}) async {
    await _update<void>((MeetBook b) {
      if (!allow) {
        b.friendListAllowed.remove(_key(friend));
      } else if (b.friendListAllowed.length < MeetBook.maxListAllowed) {
        b.friendListAllowed.add(_key(friend));
      }
    });
    await resendFriendList(friend);
  }

  /// Sends [friend] the friend list again (an empty one when they may not
  /// see it).
  Future<void> resendFriendList(String friend) async {
    final Map<String, String>? names = friendNames?.call();
    if (names != null && names.isNotEmpty) {
      await shareFriendList(names, only: <String>[friend], force: true);
    }
  }

  /// Friends who also know [address] (from shared friend lists).
  List<String> mutualFriends(String address) => <String>[
    for (final String f in host.friends())
      if (_book.friendsOf(f).containsKey(_key(address))) f,
  ];

  Future<void> setNearbyVisible(bool on) =>
      _update<void>((MeetBook b) => b.nearbyVisible = on);

  /// The short look around every few minutes (§15).
  Future<void> setNearbyBackgroundScan(bool on) =>
      _update<void>((MeetBook b) => b.nearbyBackgroundScan = on);

  Future<void> markMet(String friend) =>
      _update<void>((MeetBook b) => b.markMet(friend, _now()));

  Future<void> _send(String to, Map<String, dynamic> payload) async {
    try {
      await host.send(to, payload);
    } on Object catch (error) {
      logZenWarning('Spotkania: wysłanie ${payload['type']} do $to: $error');
    }
  }
}
