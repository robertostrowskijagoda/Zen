import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/foundation.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/core/ledger/ledger_codec.dart';
import 'package:zen/src/core/ledger/ledger_identity.dart';
import 'package:zen/src/core/logging/zen_log.dart';
import 'package:zen/src/features/ledger/audience_keys.dart';
import 'package:zen/src/features/ledger/ledger_identity_store.dart';
import 'package:zen/src/features/meet/alarm_kit.dart';
import 'package:zen/src/features/meet/alarm_sms.dart';
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

  /// Sound recorded during an alarm.
  static const String alarmAudio = 'alarm_audio';

  /// A friend's phone confirms an alarm: `k` is `got` (the phone
  /// has it) or `seen` (the friend opened it).
  static const String alarmAck = 'alarm_ack';

  /// A friend's alarm key, certified by their device key (`c`).
  static const String alarmKey = 'alarm_key';

  /// This person's own alarm as the locked Android service raised or
  /// carried on with it (`a`), and a piece of its sound: records the
  /// service leaves in the sealed inbox, taken over by the app after
  /// unlock. Taken only from this device's own address.
  static const String ownAlarm = 'alarm_own';
  static const String ownAlarmAudio = 'alarm_own_audio';

  /// A friend's alarm wave the locked service heard over Bluetooth (and
  /// checked with the friend's key): `f` the friend, `id`, `at` when heard.
  /// Left in the sealed inbox like [ownAlarm]; taken only from this
  /// device's own address.
  static const String ownNearbyAlarm = 'alarm_own_near';
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
    alarmKey,
    ownAlarm,
    ownAlarmAudio,
    ownNearbyAlarm,
    nearbyKey,
    friendList,
    request,
  };

  /// Kinds that may come before the friendship is settled here (an accept
  /// still in the queue, the state not read yet): kept for a while and
  /// handled once the sender is a friend.
  static const Set<String> parkable = <String>{
    intent,
    nearbyKey,
    friendList,
    alarmKey,
  };
}

/// Longest name taken from a friend's list.
const int kMaxFriendListName = 64;

/// Most entries taken from a friend's list.
const int kMaxFriendListEntries = 2000;

/// What an address on a friend's list may look like (a mesh address).
final RegExp _listAddress = RegExp(r'^[0-9A-Za-z:._-]{1,64}$');

/// A device key fingerprint (SHA-256, lower-case hex).
final RegExp _sessionKeyPattern = RegExp(r'^[0-9a-f]{64}$');

/// A friend's alarm heard only over Bluetooth ends by itself after
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

/// Statuses ("Chcę pogadać"), alarms and nearby keys
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

  /// This person's private level for a friend (set by the app and the
  /// background service). Without it (or `null`: the ledger is not up)
  /// every friend counts as "Znajomy".
  FriendLevel? Function(String address)? levelOf;

  /// This device's own address (set by the app): it goes into the alarm
  /// key's certificate and the alarm kit.
  String Function()? ownAddress;

  /// The account this phone knows for [address] (set by the app from the
  /// ledger): a friend's alarm key must be certified by that account.
  String? Function(String address)? accountOf;

  /// The post-quantum device key (fingerprint, hex) a friend's address
  /// proved in a hybrid-signed hello (set by the app from the ledger), or
  /// null. It goes along in the friend list, so friends of friends know
  /// it before they ever talk (pq_session.go pins it).
  String? Function(String address)? sessionKeyOf;

  /// Device keys a friend's friend list names (address → fingerprint): the
  /// app pins them in the bridge (set by the app).
  void Function(Map<String, String> keys)? onVouchedKeys;

  /// The alarm key while it is read ([alarmKey]).
  LedgerKeyPair? _alarmKeyPair;

  /// Its certificate, once made ([_alarmCertificate]).
  AlarmKeyCertificate? _alarmCert;

  /// Whether [friend] is only a weak acquaintance ("Słaby znajomy"):
  /// no friend list and no statuses but "Nie przeszkadzać" by default.
  bool isWeak(String friend) => levelOf?.call(friend) == FriendLevel.weak;

  /// Whether [friend] may see the friend list now.
  bool friendListVisibleTo(String friend) => _book.showsFriendListTo(
    friend,
    weak:
        _book.friendListAudience == FriendListAudience.friends &&
        isWeak(friend),
    close:
        _book.friendListAudience == FriendListAudience.close &&
        host.closeFriends().any(
          (String f) => PeerShareCodec.addressesEqual(f, friend),
        ),
  );

  /// Whether [friend] may see [status]: "przyjaciele" only when
  /// [IntentStatus.onlyClose]; "Nie przeszkadzać" every friend; the rest
  /// friends at level "Znajomy" and up.
  bool statusVisibleTo(IntentStatus status, String friend) {
    if (status.onlyClose) {
      return host.closeFriends().any(
        (String f) => PeerShareCodec.addressesEqual(f, friend),
      );
    }
    return status.kind == IntentKind.dnd || !isWeak(friend);
  }

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
    if (type == MeetTypes.ownAlarm ||
        type == MeetTypes.ownAlarmAudio ||
        type == MeetTypes.ownNearbyAlarm) {
      // Only what this device's own service left in the sealed inbox.
      if (host.isSelf(from)) {
        try {
          if (type == MeetTypes.ownAlarm) {
            await _onOwnAlarm(frame.payload);
          } else if (type == MeetTypes.ownNearbyAlarm) {
            await _onKeptNearbyAlarm(frame.payload);
          } else {
            await _onOwnAlarmAudio(frame.payload);
          }
        } on Object catch (error, stack) {
          logZenError('Spotkania: $type', error, stack);
        }
      }
      return true;
    }
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
        case MeetTypes.alarmKey:
          await _onAlarmKey(from, frame.payload);
        case MeetTypes.friendList:
          await _onFriendList(from, frame.payload);
        case MeetTypes.request:
          await _onRequest(from, frame.payload);
        case MeetTypes.nearbyKey:
          // `z`: the friend's keys for this phone alone.
          final Object? z = frame.payload['z'];
          if (z is String && FriendNearbyKey.parse(z) != null) {
            await _update<void>(
              (MeetBook b) => b.friendNearbySecrets[from] = z,
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
        mine != null && mine.activeAt(_now()) && statusVisibleTo(mine, friend);
    return <String, dynamic>{
      // A friend who may not see the list holds the empty one.
      if (_book.friendListSent.isNotEmpty)
        'mf': _short(
          friendListVisibleTo(friend)
              ? _book.friendListSent
              : emptyFriendListDigest,
        ),
      // What this friend holds of this phone's per-friend keys.
      if (nearbyKeysFor(friend) case final String keys)
        'mz': _secretDigest(keys),
      'ms': showsStatus ? mine.setAt : 0,
      // The alarm key friends should hold.
      if (_alarmKeyPair case final LedgerKeyPair key)
        'ma': _secretDigest(key.hybridId),
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
    final Object? mz = payload['mz'];
    if (mz is String &&
        mz.isNotEmpty &&
        mz != _secretDigest(_book.friendNearbySecrets[friend])) {
      want.add('k');
    }
    final Object? ms = payload['ms'];
    if (ms is int && ms != (_book.friendIntents[friend]?.setAt ?? 0)) {
      want.add('s');
    }
    final Object? ma = payload['ma'];
    if (ma is String &&
        ma.isNotEmpty &&
        !(_book.friendAlarmKeys[friend] ?? const <String>[]).any(
          (String k) => _secretDigest(k) == ma,
        )) {
      want.add('a');
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
    for (final Object? kind in w.take(4)) {
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
        case 'a':
          await shareAlarmKey(from);
      }
    }
  }

  /// A friend's friend list, with limits (a list is at most
  /// [kMaxFriendListEntries] people with short names), kept in its own file.
  Future<void> _onFriendList(String from, Map<String, dynamic> payload) async {
    final Object? l = payload['l'];
    final Map<String, String> list = <String, String>{};
    // Their friends' device keys, as their own hellos proved them.
    final Map<String, String> keys = <String, String>{};
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
        final Object? k = item['k'];
        if (k is String && _sessionKeyPattern.hasMatch(k)) {
          keys[_key(a)] = k;
        }
      }
    }
    list
      ..remove(from)
      ..removeWhere((String a, String _) => host.isSelf(a));
    keys.removeWhere((String a, String _) => !list.containsKey(a));
    if (keys.isNotEmpty) {
      onVouchedKeys?.call(keys);
    }
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
              ? t('🆘 {name} pilnie potrzebuje pomocy', {
                  'name': host.nameOf(from),
                })
              : t('{name} potrzebuje pomocy', {'name': host.nameOf(from)}),
          body: status.note.isEmpty ? t('Zajrzyj do Zen.') : status.note,
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
    if (!await _alarmSignatureHolds(from, payload)) {
      logZenWarning('Spotkania: alarm ze złym podpisem od $from odrzucony.');
      return;
    }
    // The copy a friend's locked phone sealed in advance for the mailboxes
    // (the alarm kit): its time is when the kit was made, so the time it
    // came stands in; a copy of the alarm itself always wins.
    final bool fromKit = payload['kit'] == true;
    if (fromKit && _book.alarm(payload['id']?.toString() ?? '') != null) {
      return;
    }
    final AlarmRecord? got = AlarmRecord.fromJson(<String, dynamic>{
      ...payload,
      'from': from,
      if (fromKit) 'at': _now(),
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
    // The owner learns at once that this phone has it: the first
    // copy, and any copy they ask about (they have no confirmation yet).
    if (_confirmed.add(merged.id) || payload['cf'] == true) {
      await _confirmAlarm(from, merged.id);
    }
    final String name = host.nameOf(from);
    if (merged.isActive && (had == null || !had.isActive)) {
      await host.notify(
        RuntimeSystemNotification(
          id: 'alarm-${merged.id}',
          title: t('🚨 ALARM: {name} potrzebuje pomocy', {'name': name}),
          body: merged.hasLocation
              ? t('Otwórz, żeby zobaczyć, gdzie jest, i odpowiedzieć.')
              : t('Otwórz i odpowiedz.'),
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
              ? t('⚠️ {name} odwołał(a) alarm PIN-em panicznym', {'name': name})
              : t('{name} jest bezpieczny(-a)', {'name': name}),
          body: merged.duress
              ? t('Może być do tego zmuszony(-a). Sprawdź, co się dzieje.')
              : t('Alarm odwołany.'),
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
        body: t('Odpowiedź na Twój alarm.'),
        createdAtMillis: _now(),
        category: RuntimeSystemNotificationCategory.social,
        slotKey: 'alarm-resp:$id',
      ),
    );
    if (updated.isActive) {
      await _broadcastAlarm(updated);
    }
  }

  /// A friend's phone confirmed this person's alarm. Only for this
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
  /// is hidden from never see „Randkuję”).
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
    for (final String friend in to) {
      final bool sees =
          status != null &&
          !except.contains(_key(friend)) &&
          statusVisibleTo(status, friend);
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

  /// Both PINs are set.
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
      id: _newAlarmId(),
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

  /// The power-button shortcut (Android).
  Future<void> setAlarmPowerButton(bool on) =>
      _update<void>((MeetBook b) => b.alarmPowerButton = on);

  /// The numbers of the alarm's backup SMS; invalid ones and
  /// repeats are dropped.
  Future<void> setAlarmSmsNumbers(Iterable<String> numbers) {
    final List<String> clean = <String>[];
    for (final String raw in numbers) {
      final String? n = normalizeSmsNumber(raw);
      if (n != null &&
          !clean.contains(n) &&
          clean.length < kAlarmSmsMaxNumbers) {
        clean.add(n);
      }
    }
    return _update<void>((MeetBook b) => b.alarmSmsNumbers = clean);
  }

  /// Sends this person's running alarm to the same friends again — after
  /// the Android background service took the network over (the shortcut
  /// fires just as the screen goes off, while the app hands the network
  /// over, so the first copy may have left from the side that was letting
  /// go). Friends who already have it see nothing new.
  ///
  /// With [to]: only to those of them (friends it already went to) — e.g.
  /// the ones whose phone did not confirm it.
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

  String _newAlarmId() {
    final int t = _now();
    return '${t.toRadixString(36)}${_random.nextInt(1 << 30).toRadixString(36)}';
  }

  // ---- alarm: the alarm key and the alarm kit ----

  /// This person's alarm key, made (and saved) on first use. It signs alarm
  /// frames and nothing else; the alarm kit gives it to the locked Android
  /// service, so no other key of this person ever has to go there. Friends
  /// get its public part, certified by the device key, when it is made
  /// and whenever their hello shows they lack it.
  Future<LedgerKeyPair> alarmKey() async {
    final String? seed = _book.alarmKeySeed;
    final LedgerKeyPair? had = _alarmKeyPair;
    if (seed != null && had != null && b64(had.seed) == seed) {
      return had;
    }
    final bool made = seed == null;
    final String stored =
        seed ??
        await _update<String>(
          (MeetBook b) => b.alarmKeySeed ??= b64(_seed32()),
        );
    final Uint8List? bytes = unb64(stored, length: 32);
    if (bytes == null) {
      throw const FormatException('meet/state: damaged alarm key');
    }
    final LedgerKeyPair key = await LedgerKeyPair.fromSeed(bytes);
    _alarmKeyPair = key;
    _alarmCert = null;
    if (made) {
      try {
        for (final String friend in host.friends()) {
          await shareAlarmKey(friend);
        }
      } on Object catch (error, stack) {
        // Friends ask for it again with the next hello.
        logZenError('Klucz alarmu dla znajomych', error, stack);
      }
    }
    return key;
  }

  Uint8List _seed32() =>
      Uint8List.fromList(List<int>.generate(32, (_) => _random.nextInt(256)));

  /// The certificate of [alarmKey] (signed by this device's key); `null`
  /// before the ledger made the device key or while the own address is not
  /// known.
  Future<AlarmKeyCertificate?> _alarmCertificate() async {
    final String self = _key(ownAddress?.call() ?? '');
    if (self.isEmpty) {
      return null;
    }
    final LedgerKeyPair key = await alarmKey();
    final AlarmKeyCertificate? had = _alarmCert;
    if (had != null && had.key == key.hybridId && had.address == self) {
      return had;
    }
    final LedgerIdentity? me = await LedgerIdentity.read(store.disk);
    if (me == null) {
      return null;
    }
    return _alarmCert = await AlarmKeyCertificate.issue(
      deviceKey: me.deviceKey,
      certificate: me.certificate,
      address: self,
      alarmKey: key.hybridId,
      issued: _now(),
    );
  }

  /// Gives [friend] the certified alarm key (once there is one).
  Future<void> shareAlarmKey(String friend) async {
    if (_book.alarmKeySeed == null) {
      return;
    }
    final AlarmKeyCertificate? cert = await _alarmCertificate();
    if (cert == null) {
      return;
    }
    await _send(friend, <String, dynamic>{
      'type': MeetTypes.alarmKey,
      'c': cert.toJson(),
    });
  }

  /// A friend's certified alarm key: kept when the certificate checks out
  /// for them (and their account, when known here).
  Future<void> _onAlarmKey(String from, Map<String, dynamic> payload) async {
    final AlarmKeyCertificate? cert = AlarmKeyCertificate.fromJson(
      payload['c'],
    );
    if (cert == null ||
        !await cert.verify(from: from, account: accountOf?.call(from))) {
      logZenWarning('Spotkania: niesprawdzony klucz alarmu od $from.');
      return;
    }
    final List<String> had = _book.friendAlarmKeys[from] ?? const <String>[];
    if (had.isNotEmpty && had.last == cert.key) {
      return;
    }
    await _update<void>((MeetBook b) {
      final List<String> keys = b.friendAlarmKeys.putIfAbsent(
        from,
        () => <String>[],
      );
      keys
        ..remove(cert.key)
        ..add(cert.key);
      while (keys.length > MeetBook.maxAlarmKeysPerFriend) {
        keys.removeAt(0);
      }
    });
  }

  /// Whether [payload] (an alarm from [from]) may be taken: a frame signed
  /// with an alarm key this phone holds for [from] must check out. One
  /// signed with a key not known here, or not signed, is taken as before
  /// (it came over the mesh from the friend's own address) and the key is
  /// asked for with the next hello.
  Future<bool> _alarmSignatureHolds(
    String from,
    Map<String, dynamic> payload,
  ) async {
    final Object? sk = payload['sk'];
    final List<String> keys = _book.friendAlarmKeys[from] ?? const <String>[];
    if (sk is! String || !keys.contains(sk)) {
      return true;
    }
    return verifyAlarmFrame(sk, payload);
  }

  /// What the alarm kit holds of this person's setup now: the
  /// alarm key, the id the kit's alarm will carry (a new one once the last
  /// one was used), who gets it (with this phone's Bluetooth keys for
  /// them), the settings, and the alarm already going on. Without devices
  /// and mailbox copies: [AlarmKitKeeper] adds those. `null` while the own
  /// address is not known.
  Future<AlarmKit?> prepareAlarmKit() async {
    final String self = _key(ownAddress?.call() ?? '');
    if (self.isEmpty) {
      return null;
    }
    final LedgerKeyPair key = await alarmKey();
    final AlarmRecord? running = _book.ownActiveAlarm;
    String? kitId = _book.alarmKitId;
    if (running == null && (kitId == null || _book.alarm(kitId) != null)) {
      final String made = _newAlarmId();
      kitId = await _update<String>((MeetBook b) {
        final String? id = b.alarmKitId;
        if (id == null || b.alarm(id) != null) {
          b.alarmKitId = made;
        }
        return b.alarmKitId!;
      });
    }
    NearbyOwnKeys? own;
    final String? private = _book.nearbyPrivate;
    if (private != null) {
      try {
        own = NearbyOwnKeys(private);
      } on FormatException {
        own = null;
      }
    }
    final List<AlarmKitRecipient> recipients = <AlarmKitRecipient>[];
    for (final String f in alarmRecipients()) {
      final String a = _key(f);
      if (a.isEmpty ||
          recipients.any((AlarmKitRecipient r) => r.address == a)) {
        continue;
      }
      recipients.add(
        AlarmKitRecipient(
          address: a,
          pairKey: own == null ? null : b64(own.pairKey(a)),
          nearbyKey: _book.friendNearbySecrets[a],
        ),
      );
      if (recipients.length >= kAlarmKitMaxRecipients) {
        break;
      }
    }
    return AlarmKit(
      createdAt: _now(),
      self: self,
      alarmId: running?.id ?? kitId!,
      alarmKeySeed: b64(key.seed),
      recipients: recipients,
      shortcut: _book.alarmPowerButton && hasAlarmPin,
      recordAudio: _book.alarmRecordAudio,
      nearby: _book.alarmNearby,
      running: running,
    );
  }

  /// The alarm of [kit] as its mailbox copies carry it: signed with the
  /// alarm key now, marked as made in advance (`kit`), so the friend takes
  /// the time it came for when it was raised.
  Future<Map<String, dynamic>> alarmKitTemplate(AlarmKit kit) async =>
      signAlarmFrame(await alarmKey(), <String, dynamic>{
        'type': MeetTypes.alarm,
        'id': kit.alarmId,
        'at': kit.createdAt,
        if (kit.note.isNotEmpty) 'note': kit.note,
        'resp': const <String, String>{},
        'kit': true,
      });

  /// This person's alarm as the locked service had it: taken over
  /// here — the screen, answers and delivery notes that come after it in
  /// the inbox, the position and sound from now on (`AlarmWatcher`) — and
  /// sent once more through the mailboxes to whoever has not confirmed it.
  /// An alarm already called off here is not brought back.
  Future<void> _onOwnAlarm(Map<String, dynamic> payload) async {
    final Object? a = payload['a'];
    final AlarmRecord? got = a is Map
        ? AlarmRecord.fromJson(<String, dynamic>{
            ...Map<String, dynamic>.from(a),
            'from': 'self',
          })
        : null;
    if (got == null || !got.isActive) {
      return;
    }
    final AlarmRecord? had = _book.alarm(got.id);
    if (had != null && (!had.isOwn || !had.isActive)) {
      return;
    }
    final AlarmRecord? running = _book.ownActiveAlarm;
    if (had == null && running != null) {
      return; // another alarm of this person goes on here already
    }
    AlarmRecord merge(AlarmRecord base) {
      final bool newer = (got.locatedAt ?? 0) > (base.locatedAt ?? 0);
      return base.copyWith(
        lat: newer ? got.lat : null,
        lon: newer ? got.lon : null,
        accuracy: newer ? got.accuracy : null,
        locatedAt: newer ? got.locatedAt : null,
        responses: <String, AlarmResponse>{...got.responses, ...base.responses},
        sentTo: <String>{
          ...base.sentTo,
          ...got.sentTo,
        }.take(AlarmRecord.maxRecipients).toList(),
        deliveries: <String, AlarmDelivery>{
          ...got.deliveries,
          ...base.deliveries,
        },
      );
    }

    // In memory first: what follows in the inbox (answers, confirmations)
    // finds it at once.
    final AlarmRecord adopted = merge(
      had ?? got.copyWith(clips: const <AlarmClip>[]),
    );
    _keepInMemory(adopted);
    await _saveOwnAlarm(adopted, merge);
    if (had == null) {
      logZenMessage('Alarm z zablokowanego telefonu przejęty.');
      await _broadcastAlarm(adopted);
    }
  }

  /// A piece of sound the locked service recorded for this person's alarm.
  Future<void> _onOwnAlarmAudio(Map<String, dynamic> payload) async {
    final Object? id = payload['id'];
    final Object? n = payload['n'];
    final Object? at = payload['at'];
    final Object? ms = payload['ms'];
    final Object? d = payload['d'];
    final AlarmRecord? own = id is String ? _ownInMemory(id) : null;
    if (own == null ||
        n is! int ||
        n < 0 ||
        n >= kAlarmMaxClips ||
        d is! String ||
        d.length > kAlarmClipMaxBytes * 4 ~/ 3 + 8 ||
        own.clips.any((AlarmClip c) => c.n == n)) {
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
    await store.disk.write(MeetStore.audioKey(own.id, n), data);
    final AlarmClip clip = AlarmClip(
      n: n,
      at: at is int ? at : _now(),
      ms: ms is int ? ms.clamp(0, 600000) : 0,
    );
    await _changeAlarm(
      own.id,
      (AlarmRecord a) => a.copyWith(
        clips: <AlarmClip>[...a.clips.where((AlarmClip c) => c.n != n), clip]
          ..sort((AlarmClip x, AlarmClip y) => x.n.compareTo(y.n)),
      ),
    );
  }

  // ---- alarm: sound ----

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
        title: t('🎙 Nagranie z alarmu: {name}', {'name': host.nameOf(from)}),
        body: t('Otwórz alarm, żeby odsłuchać.'),
        createdAtMillis: _now(),
        category: RuntimeSystemNotificationCategory.social,
        slotKey: 'alarm-audio:${alarm.id}',
      ),
    );
  }

  // ---- alarm: Bluetooth nearby ----

  /// The wave that tells phones nearby about [alarm]: its id, the time and
  /// whether it ended. Unsigned, it makes phones around show only an
  /// unchecked note.
  ///
  /// With [to] (a friend who has this phone's per-friend keys) the wave is
  /// signed with the key of that pair ([AlarmWave.buildPair]): only
  /// that friend can check it and knows whose it is. `NearbyService.waveAll`
  /// does the same per phone, for friends recognised by their own
  /// per-friend keys.
  Map<String, dynamic> alarmWave(AlarmRecord alarm, {String? to}) {
    final String? private = _book.nearbyPrivate;
    if (to != null && private != null) {
      try {
        return AlarmWave.buildPair(
          id: alarm.id,
          at: _now(),
          ended: !alarm.isActive,
          pairKey: NearbyOwnKeys(private).pairKey(_key(to)),
        );
      } on FormatException {
        // a damaged key: the wave for everyone below
      }
    }
    return _alarmWaveForAll(alarm);
  }

  Map<String, dynamic> _alarmWaveForAll(AlarmRecord alarm) =>
      AlarmWave.build(id: alarm.id, at: _now(), ended: !alarm.isActive);

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

  /// An alarm wave heard over Bluetooth. [friend]: the friend whose
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
    final int nowMs = _now();
    if (wave == null || !wave.isFreshAt(nowMs)) {
      return; // damaged, too old or from the future: played back?
    }
    final String who = _signedBy(wave, friend);
    if (!_rememberWave('$who|${wave.id}|${wave.ended}', nowMs)) {
      return; // heard already
    }
    if (who.isEmpty) {
      await _onUncheckedWave(wave, source, nowMs);
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
      at: nowMs,
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
        title: t('🚨 ALARM: {name} potrzebuje pomocy', {
          'name': host.nameOf(who),
        }),
        body: t('Jest gdzieś blisko Ciebie (Bluetooth). Otwórz i odpowiedz.'),
        createdAtMillis: nowMs,
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
  Future<void> _onUncheckedWave(
    AlarmWave wave,
    String source,
    int nowMs,
  ) async {
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
          (nowMs - at).abs() >= unverifiedWaveEvery.inMilliseconds,
    );
    if (_unverifiedAt.containsKey(from) ||
        _unverifiedAt.length >= maxUnverifiedWaves) {
      return;
    }
    _unverifiedAt[from] = nowMs;
    _unverifiedShown = wave.id;
    await host.notify(
      RuntimeSystemNotification(
        id: 'alarm-near-${wave.id}',
        title: t('Niesprawdzone: ktoś obok prosi o pomoc'),
        body: t(
          'Telefon w pobliżu wysłał przez Bluetooth prośbę o pomoc. '
          'Nie wiadomo, kto to, i nie da się tego sprawdzić — może to być '
          'pomyłka albo żart. Jeśli możesz bezpiecznie, rozejrzyj się. '
          'W razie zagrożenia: 112.',
        ),
        createdAtMillis: nowMs,
        category: RuntimeSystemNotificationCategory.social,
        slotKey: unverifiedWaveSlot,
      ),
    );
  }

  /// A friend's alarm wave the locked service heard and checked
  /// ([MeetTypes.ownNearbyAlarm]): taken like one heard here, from when it
  /// was heard. It already rang there; after unlock the alarm screen opens
  /// for it (`AlarmWatcher`), so nothing rings again.
  Future<void> _onKeptNearbyAlarm(Map<String, dynamic> p) async {
    final Object? f = p['f'];
    final Object? id = p['id'];
    final Object? at = p['at'];
    if (f is! String || id is! String || !kAlarmIdPattern.hasMatch(id)) {
      return;
    }
    if (at is! int) {
      return;
    }
    final String friend = _key(f);
    final int t = _now();
    if (!host.isFriend(friend) ||
        _book.alarm(id) != null ||
        t - at >= kNearbyAlarmLife.inMilliseconds ||
        at - t > kAlarmWaveFreshFor.inMilliseconds ||
        !_takeNewAlarm(friend)) {
      return;
    }
    final AlarmRecord alarm = AlarmRecord(
      id: id,
      from: friend,
      at: min(at, t),
      nearby: true,
    );
    if (await _putFriendAlarm(alarm) && _confirmed.add(id)) {
      await _confirmAlarm(friend, id);
    }
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
    Map<String, dynamic> json = alarm.toJson()
      ..remove('from')
      ..remove('clips')
      ..remove('near')
      ..remove('to')
      ..remove('dlv')
      ..['type'] = MeetTypes.alarm;
    if (alarm.isOwn && _book.alarmKeySeed != null) {
      try {
        json = await signAlarmFrame(await alarmKey(), json);
      } on Object catch (error, stack) {
        // Unsigned it still goes (friends take it as before).
        logZenError('Podpis alarmu', error, stack);
      }
    }
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

  /// This person's private nearby key, made on first use; never sent.
  Future<String> nearbyPrivateKey() async {
    final String? had = _book.nearbyPrivate;
    if (had != null) {
      return had;
    }
    final String made = newNearbyPrivateKey(_random);
    return _update<String>((MeetBook b) => b.nearbyPrivate ??= made);
  }

  /// What [friend] gets of this phone's per-friend keys now
  /// ([NearbyOwnKeys.materialFor]); `null` before there is a private key.
  String? nearbyKeysFor(String friend) {
    final String? private = _book.nearbyPrivate;
    if (private == null) {
      return null;
    }
    try {
      return NearbyOwnKeys(private).materialFor(_key(friend), _now());
    } on FormatException {
      return null;
    }
  }

  /// Gives [friend] what recognises this phone: their own per-friend keys
  /// (`z`).
  Future<void> shareNearbySecret(String friend) async {
    await nearbyPrivateKey();
    await _send(friend, <String, dynamic>{
      'type': MeetTypes.nearbyKey,
      if (nearbyKeysFor(friend) case final String keys) 'z': keys,
    });
    await _update<void>((MeetBook b) => b.nearbyGivenTo.add(_key(friend)));
  }

  /// New keys (after removing a friend: they can no longer recognise this
  /// phone), given to the remaining friends.
  Future<void> rotateNearbySecret() async {
    final String private = newNearbyPrivateKey(_random);
    await _update<void>((MeetBook b) {
      b.nearbyPrivate = private;
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
          <String, String>{
            'a': _key(e.key),
            'n': e.value,
            if (_sessionKeyFor(e.key) case final String k) 'k': k,
          },
    ];
    final String digest = crypto.sha256
        .convert(utf8.encode(jsonEncode(list)))
        .toString();
    if (!force && only == null && digest == _book.friendListSent) {
      return;
    }
    for (final String friend in only ?? friendsWithNames.keys) {
      // Who may not see it gets an empty list and forgets theirs.
      final bool sees = friendListVisibleTo(friend);
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

  String? _sessionKeyFor(String address) {
    final String? key = sessionKeyOf?.call(address)?.toLowerCase();
    return key != null && _sessionKeyPattern.hasMatch(key) ? key : null;
  }

  /// The digest of an empty friend list (what someone who may not see the
  /// list gets).
  static final String emptyFriendListDigest = crypto.sha256
      .convert(utf8.encode(jsonEncode(const <Object>[])))
      .toString();

  Future<void> setShareFriendList(bool on) => setFriendListAudience(
    on ? FriendListAudience.all : FriendListAudience.nobody,
  );

  /// Who sees this person's friend list. Send the list again after
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

  /// Sends [friend] the current status again, or "none" when they may not
  /// see it (after their level changed).
  Future<void> resendStatus(String friend) async {
    final IntentStatus? mine = _book.myIntent;
    final bool sees =
        mine != null && mine.activeAt(_now()) && statusVisibleTo(mine, friend);
    await _send(friend, <String, dynamic>{
      'type': MeetTypes.intent,
      if (sees) 's': mine.toJson(),
    });
  }

  /// A friend's level changed: what they may see is sent again.
  Future<void> levelChanged(String friend) async {
    if (!host.isFriend(friend)) {
      return;
    }
    await resendFriendList(friend);
    await resendStatus(friend);
  }

  /// Friends who also know [address] (from shared friend lists).
  List<String> mutualFriends(String address) => <String>[
    for (final String f in host.friends())
      if (_book.friendsOf(f).containsKey(_key(address))) f,
  ];

  /// Blocks [address] in "W pobliżu" for good.
  Future<void> blockNearby(String address) => _update<void>((MeetBook b) {
    if (b.nearbyBlocked.length < 1000) {
      b.nearbyBlocked.add(_key(address));
    }
  });

  /// Lets everyone blocked in "W pobliżu" write again.
  Future<void> unblockNearby() =>
      _update<void>((MeetBook b) => b.nearbyBlocked.clear());

  Future<void> setNearbyVisible(bool on) =>
      _update<void>((MeetBook b) => b.nearbyVisible = on);

  /// The short look around every few minutes.
  Future<void> setNearbyBackgroundScan(bool on) =>
      _update<void>((MeetBook b) => b.nearbyBackgroundScan = on);

  Future<void> _send(String to, Map<String, dynamic> payload) async {
    try {
      await host.send(to, payload);
    } on Object catch (error) {
      logZenWarning('Spotkania: wysłanie ${payload['type']} do $to: $error');
    }
  }
}
